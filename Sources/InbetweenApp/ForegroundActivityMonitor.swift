import AppKit
import ApplicationServices
import InbetweenCore

private func foregroundActivityAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<ForegroundActivityMonitor>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    Task { @MainActor in
        monitor.handleAccessibilityChange()
    }
}

protocol UserIdleTimeProviding: Sendable {
    func secondsSinceLastInput() -> TimeInterval?
}

struct QuartzUserIdleTimeProvider: UserIdleTimeProviding {
    func secondsSinceLastInput() -> TimeInterval? {
        let eventType = CGEventType(rawValue: UInt32.max)!
        let value = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: eventType
        )
        return value.isFinite && value >= 0 ? value : nil
    }
}

struct ForegroundEnrichmentRequest: Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let applicationName: String
    let applicationCategoryIdentifier: String?
    let windowTitle: String?
    let windowDocument: String?
}

protocol ForegroundActivityEnriching: Sendable {
    var pollingInterval: TimeInterval? { get }

    func enrichment(
        for request: ForegroundEnrichmentRequest
    ) async -> ActivityContextEnrichment?
}

struct NativeApplicationEnricher: ForegroundActivityEnriching {
    let pollingInterval: TimeInterval? = nil

    func enrichment(
        for request: ForegroundEnrichmentRequest
    ) async -> ActivityContextEnrichment? {
        ActivityEnrichmentParser.nativeApplication(
            bundleIdentifier: request.bundleIdentifier,
            windowTitle: request.windowTitle,
            documentURLString: request.windowDocument
        )
    }
}

private struct BrowserScriptResult: Sendable {
    let url: String?
    let title: String?
}

/// NSAppleScript does not offer cooperative cancellation once execution has
/// begun. Keeping all browser automation on one actor prevents overlapping
/// queries; caller cancellation still suppresses queued work and stale results.
private actor BrowserScriptExecutor {
    func execute(_ source: String) -> BrowserScriptResult? {
        guard !Task.isCancelled, let script = NSAppleScript(source: source) else {
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard !Task.isCancelled, error == nil, result.numberOfItems >= 2 else {
            return nil
        }
        return BrowserScriptResult(
            url: Self.nonempty(result.atIndex(1)?.stringValue),
            title: Self.nonempty(result.atIndex(2)?.stringValue)
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ScriptableBrowserEnricher: ForegroundActivityEnriching {
    static let browserPollingInterval: TimeInterval = 15
    private static let scriptExecutor = BrowserScriptExecutor()

    enum Browser: Sendable {
        case chrome
        case safari

        var script: String {
            switch self {
            case .chrome:
                return #"""
                with timeout of 2 seconds
                    tell application id "com.google.Chrome"
                        if (count of windows) is 0 then return {"", ""}
                        set selectedTab to active tab of front window
                        return {URL of selectedTab, title of selectedTab}
                    end tell
                end timeout
                """#
            case .safari:
                return #"""
                with timeout of 2 seconds
                    tell application id "com.apple.Safari"
                        if (count of windows) is 0 then return {"", ""}
                        set selectedTab to current tab of front window
                        return {URL of selectedTab, name of selectedTab}
                    end tell
                end timeout
                """#
            }
        }
    }

    let browser: Browser
    let pollingInterval: TimeInterval? = Self.browserPollingInterval

    func enrichment(
        for request: ForegroundEnrichmentRequest
    ) async -> ActivityContextEnrichment? {
        if let accessibilityEnrichment = ActivityEnrichmentParser.browser(
            urlString: request.windowDocument,
            pageTitle: request.windowTitle,
            source: .accessibility
        ), accessibilityEnrichment.browserURL != nil {
            return accessibilityEnrichment
        }

        if let values = await Self.scriptExecutor.execute(browser.script),
           let enrichment = ActivityEnrichmentParser.browser(
               urlString: values.url,
               pageTitle: values.title,
               source: .browserAppleScript
           ) {
            return enrichment
        }

        // Some browser versions expose the current document URL directly on
        // the focused window. Use that cheap AX fallback before dropping back
        // to the generic application/window context.
        return ActivityEnrichmentParser.browser(
            urlString: request.windowDocument,
            pageTitle: request.windowTitle,
            source: .accessibility
        )
    }

}

private struct ForegroundEnrichmentCacheKey: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let windowTitle: String?
    let windowDocument: String?
}

private extension ForegroundEnrichmentRequest {
    var cacheKey: ForegroundEnrichmentCacheKey {
        ForegroundEnrichmentCacheKey(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            windowDocument: windowDocument
        )
    }
}

struct ForegroundActivityEnricherRegistry: Sendable {
    private let enrichers: [String: any ForegroundActivityEnriching]

    init(enrichers: [String: any ForegroundActivityEnriching] = [
        "com.apple.Safari": ScriptableBrowserEnricher(browser: .safari),
        "com.google.Chrome": ScriptableBrowserEnricher(browser: .chrome),
        "com.apple.dt.Xcode": NativeApplicationEnricher(),
        "com.microsoft.VSCode": NativeApplicationEnricher(),
        "com.apple.Terminal": NativeApplicationEnricher(),
        "com.googlecode.iterm2": NativeApplicationEnricher(),
        "com.apple.finder": NativeApplicationEnricher()
    ]) {
        self.enrichers = enrichers
    }

    func hasEnricher(for bundleIdentifier: String) -> Bool {
        enrichers[bundleIdentifier] != nil
    }

    func pollingInterval(for bundleIdentifier: String) -> TimeInterval? {
        enrichers[bundleIdentifier]?.pollingInterval
    }

    func enrichment(
        for request: ForegroundEnrichmentRequest
    ) async -> ActivityContextEnrichment? {
        await enrichers[request.bundleIdentifier]?.enrichment(for: request)
    }
}

@MainActor
final class ForegroundActivityMonitor: @unchecked Sendable {
    typealias ObservationHandler = @MainActor (ActivityObservation) -> Void
    typealias StatusHandler = @MainActor (String) -> Void

    static let samplingInterval: TimeInterval = 5
    private static let enrichmentFailureBackoff: TimeInterval = 30
    private static let enrichmentCacheLifetime: TimeInterval = 15

    private let workspace: NSWorkspace
    private let onObservation: ObservationHandler
    private let onStatusChange: StatusHandler
    private let idleTimeProvider: any UserIdleTimeProviding
    private let presencePolicy: UserPresencePolicy
    private let enricherRegistry: ForegroundActivityEnricherRegistry
    private var activationObserver: NSObjectProtocol?
    private var activeSessionID: UUID?
    private var activeApplication: NSRunningApplication?
    private var accessibilityObserver: AXObserver?
    private var accessibilityApplication: AXUIElement?
    private var accessibilityWindow: AXUIElement?
    private var samplingTimer: Timer?
    private var enrichmentTask: Task<Void, Never>?
    private var needsRefreshAfterEnrichment = false
    private var observationGeneration = 0
    private var lastEmittedContext: ActivityContext?
    private var lastKnownAccessibilityTrust = AXIsProcessTrusted()
    private var enrichmentRetryAfter = Date.distantPast
    private var cachedEnrichment: (
        key: ForegroundEnrichmentCacheKey,
        value: ActivityContextEnrichment,
        expiresAt: Date
    )?
    private var lastEnrichmentAttemptAt = Date.distantPast
    private var applicationCategoryCache: [String: String] = [:]
    private var attemptedApplicationCategoryLookups: Set<String> = []

    init(
        workspace: NSWorkspace = .shared,
        onObservation: @escaping ObservationHandler,
        onStatusChange: @escaping StatusHandler = { _ in },
        idleTimeProvider: any UserIdleTimeProviding = QuartzUserIdleTimeProvider(),
        presencePolicy: UserPresencePolicy = UserPresencePolicy(),
        enricherRegistry: ForegroundActivityEnricherRegistry = ForegroundActivityEnricherRegistry()
    ) {
        self.workspace = workspace
        self.onObservation = onObservation
        self.onStatusChange = onStatusChange
        self.idleTimeProvider = idleTimeProvider
        self.presencePolicy = presencePolicy
        self.enricherRegistry = enricherRegistry
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else {
                return
            }
            Task { @MainActor [weak self] in
                self?.activated(application)
            }
        }
    }

    isolated deinit {
        samplingTimer?.invalidate()
        enrichmentTask?.cancel()
        if let activationObserver {
            workspace.notificationCenter.removeObserver(activationObserver)
        }
    }

    var accessibilityStatus: String {
        AXIsProcessTrusted()
            ? "App, window, and presence context available; browser details when permitted"
            : "App and presence context available; Accessibility off; browser details when permitted"
    }

    func begin(sessionID: UUID) {
        refreshAccessibilityStatus(recoverIfAvailable: false)
        guard activeSessionID != sessionID else { return }
        activeSessionID = sessionID
        lastEmittedContext = nil
        startSampling()
        if let application = workspace.frontmostApplication {
            activated(application)
        }
    }

    func end(sessionID: UUID) {
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        activeApplication = nil
        stopSampling()
        invalidatePendingEnrichment()
        lastEmittedContext = nil
        tearDownAccessibilityObservation()
    }

    fileprivate func handleAccessibilityChange() {
        refreshAccessibilityStatus(recoverIfAvailable: false)
        guard activeSessionID != nil, let application = activeApplication else { return }
        attachToFocusedWindowIfAvailable()
        invalidatePendingEnrichment()
        invalidateEnrichmentCache()
        requestObservation(for: application, forceEnrichment: true)
    }

    private func activated(_ application: NSRunningApplication) {
        refreshAccessibilityStatus(recoverIfAvailable: false)
        guard activeSessionID != nil else { return }
        invalidatePendingEnrichment()
        invalidateEnrichmentCache()
        activeApplication = application
        configureAccessibilityObservation(for: application)
        requestObservation(for: application)
    }

    private func requestObservation(
        for application: NSRunningApplication,
        forceEnrichment: Bool = false
    ) {
        guard let sessionID = activeSessionID,
              activeApplication?.processIdentifier == application.processIdentifier,
              let bundleIdentifier = application.bundleIdentifier,
              let applicationName = application.localizedName
        else { return }

        let isAccessibilityTrusted = AXIsProcessTrusted()
        let trustChanged = applyAccessibilityTrustState(isAccessibilityTrusted)
        if trustChanged, isAccessibilityTrusted, accessibilityObserver == nil {
            configureAccessibilityObservation(for: application)
        }

        guard enrichmentTask == nil else {
            needsRefreshAfterEnrichment = true
            return
        }

        let observedAt = Date()
        let generation = observationGeneration
        let presence = presencePolicy.state(
            secondsSinceLastInput: idleTimeProvider.secondsSinceLastInput()
        )
        let windowSnapshot = focusedWindowSnapshot()
        let request = ForegroundEnrichmentRequest(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            applicationCategoryIdentifier: applicationCategoryIdentifier(
                for: application,
                bundleIdentifier: bundleIdentifier
            ),
            windowTitle: windowSnapshot?.title,
            windowDocument: windowSnapshot?.document
        )
        let cachedForCurrentContext = cachedEnrichment?.key == request.cacheKey
        let pollingIsDue = enricherRegistry.pollingInterval(for: bundleIdentifier).map {
            observedAt.timeIntervalSince(lastEnrichmentAttemptAt) >= $0
        } ?? false
        let shouldAttemptEnrichment = enricherRegistry.hasEnricher(for: bundleIdentifier)
            && observedAt >= enrichmentRetryAfter
            && (forceEnrichment || !cachedForCurrentContext || pollingIsDue)
        if shouldAttemptEnrichment {
            lastEnrichmentAttemptAt = observedAt
        }

        enrichmentTask = Task { [weak self] in
            guard let self else { return }
            let fetchedEnrichment = shouldAttemptEnrichment
                ? await enricherRegistry.enrichment(for: request)
                : nil
            guard !Task.isCancelled else { return }
            finishObservation(
                request: request,
                sessionID: sessionID,
                generation: generation,
                observedAt: observedAt,
                presence: presence,
                fetchedEnrichment: fetchedEnrichment,
                attemptedEnrichment: shouldAttemptEnrichment
            )
        }
    }

    private func finishObservation(
        request: ForegroundEnrichmentRequest,
        sessionID: UUID,
        generation: Int,
        observedAt: Date,
        presence: UserPresenceState?,
        fetchedEnrichment: ActivityContextEnrichment?,
        attemptedEnrichment: Bool
    ) {
        enrichmentTask = nil
        defer {
            if needsRefreshAfterEnrichment,
               let application = activeApplication,
               activeSessionID != nil {
                needsRefreshAfterEnrichment = false
                requestObservation(for: application)
            }
        }

        guard activeSessionID == sessionID,
              observationGeneration == generation,
              activeApplication?.processIdentifier == request.processIdentifier
        else { return }

        let now = Date()
        if let fetchedEnrichment {
            cachedEnrichment = (
                request.cacheKey,
                fetchedEnrichment,
                now.addingTimeInterval(Self.enrichmentCacheLifetime)
            )
            enrichmentRetryAfter = .distantPast
        } else if attemptedEnrichment {
            enrichmentRetryAfter = now.addingTimeInterval(Self.enrichmentFailureBackoff)
        }

        let enrichment: ActivityContextEnrichment?
        if let fetchedEnrichment {
            enrichment = fetchedEnrichment
        } else if let cachedEnrichment,
                  cachedEnrichment.key == request.cacheKey,
                  (!attemptedEnrichment || cachedEnrichment.expiresAt >= now) {
            enrichment = cachedEnrichment.value
        } else {
            enrichment = nil
        }

        guard let baseContext = ActivityContext(
            applicationBundleIdentifier: request.bundleIdentifier,
            applicationName: request.applicationName,
            applicationCategoryIdentifier: request.applicationCategoryIdentifier,
            windowTitle: request.windowTitle,
            provenance: ActivityContextProvenance(
                applicationIdentity: .foregroundApplication,
                applicationCategory: request.applicationCategoryIdentifier == nil ? nil : .applicationBundle,
                windowTitle: request.windowTitle == nil ? nil : .accessibility
            )
        ), let context = baseContext.enriching(
            with: enrichment,
            presenceState: presence
        ), context != lastEmittedContext else {
            return
        }

        lastEmittedContext = context
        onObservation(ActivityObservation(context: context, observedAt: observedAt))
    }

    func refreshAccessibilityStatus() {
        refreshAccessibilityStatus(recoverIfAvailable: true)
    }

    private func refreshAccessibilityStatus(recoverIfAvailable: Bool) {
        let isTrusted = AXIsProcessTrusted()
        let trustChanged = applyAccessibilityTrustState(isTrusted)
        if !isTrusted {
            tearDownAccessibilityObservation()
            if recoverIfAvailable,
               activeSessionID != nil,
               let application = activeApplication ?? workspace.frontmostApplication {
                activeApplication = application
                requestObservation(for: application, forceEnrichment: true)
            }
        } else if recoverIfAvailable,
                  activeSessionID != nil,
                  accessibilityObserver == nil,
                  let application = workspace.frontmostApplication {
            activeApplication = application
            configureAccessibilityObservation(for: application)
            invalidateEnrichmentCache()
            requestObservation(for: application, forceEnrichment: true)
        }
        if !trustChanged {
            onStatusChange(accessibilityStatus)
        }
    }

    private func configureAccessibilityObservation(for application: NSRunningApplication) {
        tearDownAccessibilityObservation()
        guard AXIsProcessTrusted() else { return }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var observer: AXObserver?
        guard AXObserverCreate(
            application.processIdentifier,
            foregroundActivityAXCallback,
            &observer
        ) == .success, let observer else {
            return
        }

        accessibilityApplication = applicationElement
        accessibilityObserver = observer
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(
            observer,
            applicationElement,
            kAXFocusedWindowChangedNotification as CFString,
            refcon
        )
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        attachToFocusedWindowIfAvailable()
    }

    private func attachToFocusedWindowIfAvailable() {
        guard let observer = accessibilityObserver,
              let applicationElement = accessibilityApplication
        else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let accessibilityWindow {
            AXObserverRemoveNotification(
                observer,
                accessibilityWindow,
                kAXTitleChangedNotification as CFString
            )
        }
        accessibilityWindow = copyElement(
            attribute: kAXFocusedWindowAttribute as CFString,
            from: applicationElement
        )
        if let accessibilityWindow {
            AXObserverAddNotification(
                observer,
                accessibilityWindow,
                kAXTitleChangedNotification as CFString,
                refcon
            )
        }
    }

    private func focusedWindowSnapshot() -> (title: String?, document: String?)? {
        guard AXIsProcessTrusted(),
              let applicationElement = accessibilityApplication,
              let window = copyElement(
                  attribute: kAXFocusedWindowAttribute as CFString,
                  from: applicationElement
              )
        else {
            return nil
        }

        return (
            copyString(attribute: kAXTitleAttribute as CFString, from: window),
            focusedWindowDocument(from: window)
        )
    }

    private func focusedWindowDocument(from window: AXUIElement) -> String? {
        for attribute in [
            kAXDocumentAttribute as CFString,
            kAXURLAttribute as CFString
        ] {
            if let value = copyAttribute(attribute, from: window) {
                if let string = value as? String { return string }
                if let url = value as? URL { return url.absoluteString }
            }
        }
        return nil
    }

    private func copyString(attribute: CFString, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private func copyAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private func startSampling() {
        guard samplingTimer == nil else { return }
        let timer = Timer(timeInterval: Self.samplingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let application = self.activeApplication else { return }
                self.requestObservation(for: application)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        samplingTimer = timer
    }

    private func stopSampling() {
        samplingTimer?.invalidate()
        samplingTimer = nil
    }

    private func invalidatePendingEnrichment() {
        observationGeneration += 1
        enrichmentTask?.cancel()
        enrichmentTask = nil
        needsRefreshAfterEnrichment = false
    }

    private func invalidateEnrichmentCache() {
        cachedEnrichment = nil
        enrichmentRetryAfter = .distantPast
        lastEnrichmentAttemptAt = .distantPast
    }

    private func applicationCategoryIdentifier(
        for application: NSRunningApplication,
        bundleIdentifier: String
    ) -> String? {
        if attemptedApplicationCategoryLookups.contains(bundleIdentifier) {
            return applicationCategoryCache[bundleIdentifier]
        }
        attemptedApplicationCategoryLookups.insert(bundleIdentifier)
        guard let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL),
              let category = bundle.object(
                forInfoDictionaryKey: "LSApplicationCategoryType"
              ) as? String,
              !category.isEmpty
        else { return nil }
        applicationCategoryCache[bundleIdentifier] = category
        return category
    }

    @discardableResult
    private func applyAccessibilityTrustState(_ isTrusted: Bool) -> Bool {
        guard lastKnownAccessibilityTrust != isTrusted else { return false }
        lastKnownAccessibilityTrust = isTrusted
        invalidatePendingEnrichment()
        invalidateEnrichmentCache()
        if !isTrusted {
            tearDownAccessibilityObservation()
        }
        onStatusChange(accessibilityStatus)
        return true
    }

    private func copyElement(attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func tearDownAccessibilityObservation() {
        guard let observer = accessibilityObserver else {
            accessibilityApplication = nil
            accessibilityWindow = nil
            return
        }

        if let accessibilityWindow {
            AXObserverRemoveNotification(
                observer,
                accessibilityWindow,
                kAXTitleChangedNotification as CFString
            )
        }
        if let accessibilityApplication {
            AXObserverRemoveNotification(
                observer,
                accessibilityApplication,
                kAXFocusedWindowChangedNotification as CFString
            )
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        accessibilityObserver = nil
        accessibilityApplication = nil
        accessibilityWindow = nil
    }
}
