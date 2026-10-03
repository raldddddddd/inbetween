import AppKit
import Charts
import InbetweenCore
import SwiftUI

enum ContextRuleSaveResult: Equatable {
    case saved
    case invalid
    case duplicate
}

enum AIUIState: Equatable {
    case unavailable
    case idle
    case loading
    case success
    case failure
}

enum DashboardDestination: String, CaseIterable, Identifiable {
    case overview
    case review
    case reflection
    case history
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .review: "Needs Review"
        case .reflection: "Reflection"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .review: "questionmark.circle"
        case .reflection: "sparkles"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

@main
struct InbetweenApp: App {
    @StateObject private var model = LifecycleViewModel()

    var body: some Scene {
        MenuBarExtra("Inbetween", systemImage: model.menuBarSymbol) {
            MenuBarStatusView(model: model)
                .frame(width: 360)
        }
        .menuBarExtraStyle(.window)

        Window("Inbetween", id: "dashboard") {
            DashboardView(model: model)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 820, height: 640)
    }
}

@MainActor
final class LifecycleViewModel: ObservableObject {
    private static let aiModelPreferenceKey = "featherless.model"
    private struct PermissionAttentionHandlingResult {
        let before: DelayedPermissionAttentionState
        let after: DelayedPermissionAttentionState
        let timerAction: String
        let boundaryID: PermissionBoundaryID?
    }

    @Published private(set) var snapshot = LifecycleSnapshot()
    @Published private(set) var receiverStatus = "Starting local receiver…"
    @Published private(set) var storageStatus = "Loading wait sessions…"
    @Published private(set) var rejectedEventCount = 0
    @Published private(set) var sessions: [WaitSession] = []
    @Published private(set) var currentWaitSession: WaitSession?
    @Published private(set) var notificationSmokeTestEnabled = false
    @Published private(set) var activityMetadataStatus = "App-only activity"
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatus = "Checking Launch at Login…"
    @Published private(set) var systemStatus = "Awake"
    @Published private(set) var permissionAttentionState: DelayedPermissionAttentionState = .inactive
    @Published private(set) var contextRules: [PersonalContextRule] = []
    @Published private(set) var contextRuleStatus = "Personal rules stay on this Mac"
    @Published private(set) var contextRulePrefill: PersonalContextRuleSuggestion?
    @Published private(set) var reflectionMessagesByScope: [ReflectionScope: [ReflectionChatMessage]] = [:]
    @Published private(set) var reflectionStatusByScope: [ReflectionScope: String] = [:]
    @Published private(set) var reflectionLoadingScopes: Set<ReflectionScope> = []
    @Published private(set) var aiConfigurationStatus = "Checking AI settings…"
    @Published private(set) var aiCredentialSource: FeatherlessCredentialSource?
    @Published private(set) var configuredAIModel = ""
    @Published var dashboardDestination: DashboardDestination = .overview

    private var stateMachine = LifecycleStateMachine()
    private var sessionTracker: WaitSessionTracker
    private let sessionStore: WaitSessionStore
    private let contextRuleStore: ContextRuleStore
    private let latencyRecorder: StopLatencyRecorder
    private let lifecycleDiagnosticRecorder: LifecycleDiagnosticRecorder
    private let notificationService: LocalNotificationService
    private let launchAtLoginController: LaunchAtLoginController
    private let aiCredentialStore: any AICredentialStoring
    private let aiPreferences: UserDefaults
    private let aiEnvironment: [String: String]
    private var reflectionCoordinator: ReflectionConversationCoordinator?
    private var displayedConversationKeys: [ReflectionScope: ReflectionConversationKey] = [:]
    private var activeReflectionScope: ReflectionScope = .today
    private let parser = LifecycleEventParser()
    private var receiver: UnixDatagramEventReceiver?
    private var activityMonitor: ForegroundActivityMonitor!
    private var systemLifecycleMonitor: SystemLifecycleMonitor!
    private var permissionAttentionTracker = DelayedPermissionAttentionTracker()
    private var permissionAttentionTask: Task<Void, Never>?

    init(
        aiCredentialStore: any AICredentialStoring = KeychainAICredentialStore(),
        aiPreferences: UserDefaults = .standard,
        aiEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let latencyRecorder = StopLatencyRecorder()
        self.latencyRecorder = latencyRecorder
        lifecycleDiagnosticRecorder = LifecycleDiagnosticRecorder()
        notificationService = LocalNotificationService(latencyRecorder: latencyRecorder)
        launchAtLoginController = LaunchAtLoginController()
        self.aiCredentialStore = aiCredentialStore
        self.aiPreferences = aiPreferences
        self.aiEnvironment = aiEnvironment

        let store = WaitSessionStore()
        sessionStore = store
        let ruleStore = ContextRuleStore()
        contextRuleStore = ruleStore

        let loadedSessions: [WaitSession]
        do {
            loadedSessions = try store.load()
            storageStatus = "Saved locally at \(store.fileURL.path)"
        } catch {
            loadedSessions = []
            storageStatus = "Could not load saved sessions: \(String(describing: error))"
        }

        let loadedContextRules: [PersonalContextRule]
        do {
            loadedContextRules = try ruleStore.load()
            contextRuleStatus = "Personal rules stay on this Mac"
        } catch {
            loadedContextRules = []
            contextRuleStatus = "Could not load personal rules: \(error.localizedDescription)"
        }
        contextRules = loadedContextRules

        let tracker = WaitSessionTracker(
            sessions: loadedSessions,
            classifier: WaitSessionClassifier(rules: WaitSessionClassificationRules(
                personalContextRules: loadedContextRules
            ))
        )
        sessionTracker = tracker
        sessions = tracker.sessions
        currentWaitSession = tracker.currentSession
        refreshAIConfiguration()
        if tracker.recoveredUnfinishedSessions {
            persistSessions()
        }

        activityMonitor = ForegroundActivityMonitor(
            onObservation: { [weak self] observation in
                self?.recordActivity(observation)
            },
            onStatusChange: { [weak self] status in
                self?.activityMetadataStatus = status
            }
        )
        activityMetadataStatus = activityMonitor.accessibilityStatus

        let receiver = UnixDatagramEventReceiver { [weak self] data in
            let receivedWallTime = Date().timeIntervalSince1970
            let receivedMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor [weak self] in
                self?.ingest(
                    data,
                    receivedWallTime: receivedWallTime,
                    receivedMonotonicNanoseconds: receivedMonotonicNanoseconds
                )
            }
        }
        self.receiver = receiver
        do {
            try receiver.start()
            receiverStatus = "Listening at \(UnixDatagramEventReceiver.defaultSocketPath)"
        } catch EventReceiverError.alreadyRunning {
            receiverStatus = "Another Inbetween instance already owns the lifecycle listener"
        } catch {
            receiverStatus = "Receiver unavailable: \(String(describing: error))"
        }

        systemLifecycleMonitor = SystemLifecycleMonitor(
            onSleep: { [weak self] date in
                self?.systemWillSleep(at: date)
            },
            onWake: { [weak self] date in
                self?.systemDidWake(at: date)
            },
            onTerminate: { [weak self] date in
                self?.prepareForTermination(at: date)
            }
        )
        refreshReliabilityStatus()

        if ProcessInfo.processInfo.arguments.contains("--notification-smoke-test") {
            notificationSmokeTestEnabled = true
            notificationService.sendSmokeTest()
        }
    }

    var menuBarSymbol: String {
        switch userFacingWaitStatus {
        case .listening: "circle"
        case .working: "bolt.circle"
        case .mayNeedAttention: "exclamationmark.circle"
        case .ready: "checkmark.circle"
        }
    }

    var userFacingWaitStatus: UserFacingWaitStatus {
        UserFacingWaitStatus(
            lifecycleState: snapshot.state,
            hasActiveWait: currentWaitSession != nil,
            permissionAttentionState: permissionAttentionState
        )
    }

    var completedHistory: [WaitSession] {
        WaitPresentationSupport.completedHistory(from: sessions)
    }

    var historyInsights: WaitHistoryInsights {
        WaitHistoryInsights(sessions: sessions)
    }

    func reflectionSnapshot(for scope: ReflectionScope) -> AIInsightPreparedSnapshot {
        AIInsightSnapshotBuilder.prepare(sessions: sessions, scope: scope)
    }

    var isReflectionConfigured: Bool { reflectionCoordinator != nil }

    func reflectionMessages(for scope: ReflectionScope) -> [ReflectionChatMessage] {
        let prepared = reflectionSnapshot(for: scope)
        guard displayedConversationKeys[scope]?.snapshotFingerprint == prepared.fingerprint else { return [] }
        return reflectionMessagesByScope[scope] ?? []
    }

    func reflectionStatus(for scope: ReflectionScope) -> String {
        reflectionStatusByScope[scope] ?? (isReflectionConfigured
            ? "Ask a question when you want an interpretation of these local facts."
            : aiConfigurationStatus)
    }

    func activateReflectionScope(_ scope: ReflectionScope) {
        let previousScope = activeReflectionScope
        if previousScope != scope, reflectionLoadingScopes.contains(previousScope) {
            Task { await reflectionCoordinator?.cancelPendingResponse(for: previousScope) }
        }
        activeReflectionScope = scope
        let prepared = reflectionSnapshot(for: scope)
        if displayedConversationKeys[scope]?.snapshotFingerprint != prepared.fingerprint {
            reflectionMessagesByScope[scope] = []
            let key = ReflectionConversationKey(
                scope: scope,
                snapshotFingerprint: prepared.fingerprint
            )
            displayedConversationKeys[scope] = key
            Task { await reflectionCoordinator?.newConversation(for: key) }
        }
    }

    func saveAIConfiguration(apiKey: String, model: String) -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !key.isEmpty { try aiCredentialStore.setAPIKey(key) }
            if model.isEmpty { aiPreferences.removeObject(forKey: Self.aiModelPreferenceKey) }
            else { aiPreferences.set(model, forKey: Self.aiModelPreferenceKey) }
            refreshAIConfiguration()
            return nil
        } catch {
            return "Could not save the API key: \(error.localizedDescription)"
        }
    }

    func removeSavedAIKey() -> String? {
        do {
            try aiCredentialStore.removeAPIKey()
            refreshAIConfiguration()
            return nil
        } catch {
            return "Could not remove the saved API key: \(error.localizedDescription)"
        }
    }

    func sendReflectionQuestion(_ question: String, scope: ReflectionScope) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !reflectionLoadingScopes.contains(scope) else { return }
        guard let coordinator = reflectionCoordinator else {
            reflectionStatusByScope[scope] = aiConfigurationStatus
            return
        }
        let prepared = reflectionSnapshot(for: scope)
        guard prepared.payload.completedSessionCount > 0, !prepared.evidenceLinks.isEmpty else {
            reflectionStatusByScope[scope] = "There isn’t enough completed activity in this scope yet."
            return
        }
        let expectedKey = ReflectionConversationKey(scope: scope, snapshotFingerprint: prepared.fingerprint)
        reflectionLoadingScopes.insert(scope)
        reflectionStatusByScope[scope] = "Thinking from the local \(scope.title.lowercased()) snapshot…"
        Task { [weak self] in
            do {
                let exchange = try await coordinator.send(question: question, prepared: prepared)
                guard let self else { return }
                let current = reflectionSnapshot(for: scope)
                guard activeReflectionScope == scope,
                      exchange.key == expectedKey,
                      current.fingerprint == expectedKey.snapshotFingerprint else {
                    reflectionLoadingScopes.remove(scope)
                    reflectionStatusByScope[scope] = "The activity changed, so the stale response was discarded. Ask again with the updated snapshot."
                    return
                }
                displayedConversationKeys[scope] = expectedKey
                reflectionMessagesByScope[scope] = exchange.messages
                reflectionStatusByScope[scope] = "Answer grounded in linked local evidence."
                reflectionLoadingScopes.remove(scope)
            } catch {
                guard let self else { return }
                reflectionStatusByScope[scope] = error.localizedDescription
                reflectionLoadingScopes.remove(scope)
            }
        }
    }

    func newReflectionConversation(scope: ReflectionScope) {
        let prepared = reflectionSnapshot(for: scope)
        let key = ReflectionConversationKey(scope: scope, snapshotFingerprint: prepared.fingerprint)
        reflectionMessagesByScope[scope] = []
        displayedConversationKeys[scope] = key
        reflectionStatusByScope[scope] = "New conversation. No activity was sent."
        Task { await reflectionCoordinator?.newConversation(for: key) }
    }

    func sendNotificationSmokeTest() {
        guard notificationSmokeTestEnabled else { return }
        notificationService.sendSmokeTest()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginController.setEnabled(enabled)
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginStatus = "Launch at Login change failed: \(error.localizedDescription)"
        }
    }

    func refreshReliabilityStatus() {
        refreshLaunchAtLoginStatus()
        activityMonitor.refreshAccessibilityStatus()
    }

    func quit() {
        prepareForTermination(at: Date())
        NSApplication.shared.terminate(nil)
    }

    func setManualClassificationOverride(
        _ classification: WaitSessionClassification?,
        for sessionID: UUID
    ) {
        guard case .updated = sessionTracker.setManualClassificationOverride(
            classification,
            for: sessionID
        ) else { return }
        sessions = sessionTracker.sessions
        currentWaitSession = sessionTracker.currentSession
        persistSessions()
    }

    func markClassificationReviewHandled(for sessionID: UUID) {
        guard case .updated = sessionTracker.markClassificationReviewHandled(for: sessionID) else { return }
        sessions = sessionTracker.sessions
        currentWaitSession = sessionTracker.currentSession
        persistSessions()
    }

    func setSliceClassificationOverride(
        _ classification: WaitSessionClassification?,
        for unit: WaitClassificationReviewUnit
    ) {
        guard case .updated = sessionTracker.setManualClassificationOverride(
            classification,
            forSliceIDs: Set(unit.sourceSliceIDs),
            in: unit.waitSessionID
        ) else { return }
        sessions = sessionTracker.sessions
        currentWaitSession = sessionTracker.currentSession
        persistSessions()
    }

    func markSliceReviewHandled(for unit: WaitClassificationReviewUnit) {
        guard case .updated = sessionTracker.markClassificationReviewHandled(
            forSliceIDs: Set(unit.sourceSliceIDs),
            in: unit.waitSessionID
        ) else { return }
        sessions = sessionTracker.sessions
        currentWaitSession = sessionTracker.currentSession
        persistSessions()
    }

    var pendingReviewItems: [WaitReviewItem] {
        WaitPresentationSupport.pendingReviewItems(from: sessions)
    }


    @discardableResult
    func saveContextRule(
        id: UUID? = nil,
        scope: ContextRuleScope,
        pattern: String,
        disposition: ContextRuleDisposition
    ) -> ContextRuleSaveResult {
        guard let rule = PersonalContextRule(
            id: id ?? UUID(),
            scope: scope,
            pattern: pattern,
            disposition: disposition
        ) else {
            return .invalid
        }

        guard !PersonalContextRule.duplicates(
            scope: rule.scope,
            pattern: rule.pattern,
            in: contextRules,
            excludingID: id
        ) else {
            return .duplicate
        }
        if let id, let index = contextRules.firstIndex(where: { $0.id == id }) {
            contextRules[index] = rule
        } else {
            contextRules.append(rule)
        }
        applyContextRules()
        persistContextRules()
        return .saved
    }

    func deleteContextRule(id: UUID) {
        guard contextRules.contains(where: { $0.id == id }) else { return }
        contextRules.removeAll { $0.id == id }
        applyContextRules()
        persistContextRules()
    }

    func prepareContextRule(from context: ActivityContext) {
        contextRulePrefill = PersonalContextRule.suggestions(for: context).first
        dashboardDestination = .settings
    }

    func clearContextRulePrefill() {
        contextRulePrefill = nil
    }

    private func refreshAIConfiguration() {
        let savedKey: String?
        do { savedKey = try aiCredentialStore.apiKey() }
        catch {
            reflectionCoordinator = nil
            aiCredentialSource = nil
            aiConfigurationStatus = "Keychain could not be read: \(error.localizedDescription)"
            return
        }
        let savedModel = aiPreferences.string(forKey: Self.aiModelPreferenceKey)
        let resolution = FeatherlessConfigurationResolver.resolve(
            storedAPIKey: savedKey,
            storedModel: savedModel,
            environment: aiEnvironment
        )
        aiCredentialSource = resolution.credentialSource
        configuredAIModel = savedModel
            ?? aiEnvironment[FeatherlessConfiguration.modelEnvironmentKey]
            ?? ""
        aiConfigurationStatus = resolution.status
        reflectionCoordinator = resolution.configuration.map {
            ReflectionConversationCoordinator(provider: FeatherlessReflectionChatProvider(configuration: $0))
        }
        reflectionMessagesByScope = [:]
        displayedConversationKeys = [:]
        reflectionStatusByScope = [:]
    }

    private func ingest(
        _ data: Data,
        receivedWallTime: TimeInterval,
        receivedMonotonicNanoseconds: UInt64
    ) {
        do {
            let event = try parser.parse(data)
            if event.name == .stop {
                latencyRecorder.record(
                    .appReceived,
                    sessionID: event.sessionID,
                    turnID: event.turnID,
                    wallTime: receivedWallTime,
                    monotonicNanoseconds: receivedMonotonicNanoseconds
                )
            }
            var candidateStateMachine = stateMachine
            var candidateSessionTracker = sessionTracker

            if candidateStateMachine.snapshot.activeTurn == nil,
               event.name != .userPromptSubmit,
               let unresolved = candidateSessionTracker.unresolvedSession(matching: event) {
                let lastObserved = unresolved.attentionEvents.last?.timestamp ?? unresolved.startTime
                candidateStateMachine.restoreActiveTurn(
                    sessionID: unresolved.codexSessionID,
                    turnID: unresolved.codexTurnID,
                    startedAt: unresolved.startTime,
                    lastEventAt: lastObserved
                )
            }

            let lifecycleResult = candidateStateMachine.apply(event)
            guard lifecycleResult != .duplicate,
                  lifecycleResult != .stale,
                  lifecycleResult != .outOfOrder
            else {
                recordLifecycleDiagnostic(
                    event: event,
                    lifecycleDisposition: lifecycleResult,
                    sessionUpdate: nil,
                    trackerBefore: permissionAttentionTracker.state,
                    trackerAfter: permissionAttentionTracker.state,
                    timerAction: "preserved",
                    boundaryID: permissionAttentionTracker.currentBoundaryID,
                    enteredMayNeedAttention: false,
                    attentionNotificationSent: false
                )
                rejectedEventCount += 1
                return
            }

            let sessionUpdate = candidateSessionTracker.apply(event)
            guard sessionUpdate != .ignored else {
                recordLifecycleDiagnostic(
                    event: event,
                    lifecycleDisposition: lifecycleResult,
                    sessionUpdate: sessionUpdate,
                    trackerBefore: permissionAttentionTracker.state,
                    trackerAfter: permissionAttentionTracker.state,
                    timerAction: "preserved",
                    boundaryID: permissionAttentionTracker.currentBoundaryID,
                    enteredMayNeedAttention: false,
                    attentionNotificationSent: false
                )
                rejectedEventCount += 1
                return
            }
            if event.name == .stop, case .completed = sessionUpdate {
                latencyRecorder.record(
                    .waitSessionCompleted,
                    sessionID: event.sessionID,
                    turnID: event.turnID
                )
            }

            stateMachine = candidateStateMachine
            sessionTracker = candidateSessionTracker
            snapshot = stateMachine.snapshot
            sessions = sessionTracker.sessions
            currentWaitSession = sessionTracker.currentSession
            persistSessions()
            let permissionHandling = handlePermissionAttention(
                for: event,
                receivedAt: Date(timeIntervalSince1970: receivedWallTime)
            )
            if let notification = WaitSessionNotificationPolicy.notification(
                forAcceptedSessionUpdate: sessionUpdate,
                event: event
            ) {
                notificationService.send(notification, for: event)
            }
            recordLifecycleDiagnostic(
                event: event,
                lifecycleDisposition: lifecycleResult,
                sessionUpdate: sessionUpdate,
                trackerBefore: permissionHandling.before,
                trackerAfter: permissionHandling.after,
                timerAction: permissionHandling.timerAction,
                boundaryID: permissionHandling.boundaryID,
                enteredMayNeedAttention: false,
                attentionNotificationSent: false
            )
            handleActivityCollection(for: sessionUpdate)
        } catch {
            rejectedEventCount += 1
        }
    }

    private func persistSessions() {
        do {
            try sessionStore.save(sessionTracker.sessions)
            storageStatus = "Saved locally at \(sessionStore.fileURL.path)"
        } catch {
            storageStatus = "Could not save sessions: \(String(describing: error))"
        }
    }

    private func applyContextRules() {
        sessionTracker.setClassificationRules(WaitSessionClassificationRules(
            personalContextRules: contextRules
        ))
    }

    private func persistContextRules() {
        do {
            try contextRuleStore.save(contextRules)
            contextRuleStatus = "Personal rules stay on this Mac"
        } catch {
            contextRuleStatus = "Could not save personal rules: \(error.localizedDescription)"
        }
    }

    private func handlePermissionAttention(
        for event: LifecycleEvent,
        receivedAt: Date
    ) -> PermissionAttentionHandlingResult {
        let before = permissionAttentionTracker.state
        let update = permissionAttentionTracker.observeAcceptedLifecycleEvent(
            event,
            receivedAt: receivedAt
        )
        permissionAttentionState = permissionAttentionTracker.state

        switch update {
        case let .pending(boundaryID, deadline):
            permissionAttentionTask?.cancel()
            permissionAttentionTask = Task { @MainActor [weak self] in
                let delay = max(0, deadline.timeIntervalSinceNow)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.permissionAttentionDeadlineReached(boundaryID: boundaryID)
            }
            return PermissionAttentionHandlingResult(
                before: before,
                after: permissionAttentionTracker.state,
                timerAction: "started",
                boundaryID: boundaryID
            )
        case .cleared:
            permissionAttentionTask?.cancel()
            permissionAttentionTask = nil
            return PermissionAttentionHandlingResult(
                before: before,
                after: permissionAttentionTracker.state,
                timerAction: "cleared",
                boundaryID: nil
            )
        case .becamePersistent, .unchanged:
            return PermissionAttentionHandlingResult(
                before: before,
                after: permissionAttentionTracker.state,
                timerAction: "preserved",
                boundaryID: permissionAttentionTracker.currentBoundaryID
            )
        }
    }

    private func permissionAttentionDeadlineReached(boundaryID: PermissionBoundaryID) {
        let before = permissionAttentionTracker.state
        let update = permissionAttentionTracker.evaluate(boundaryID: boundaryID, at: Date())
        permissionAttentionState = permissionAttentionTracker.state
        permissionAttentionTask = nil
        let dispatch = WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: update)
        if let dispatch {
            notificationService.send(dispatch.notification, for: dispatch.event)
        }
        let event: LifecycleEvent?
        if case let .becamePersistent(_, persistentEvent) = update {
            event = persistentEvent
        } else {
            event = nil
        }
        let enteredMayNeedAttention = before != .mayNeedAttention
            && permissionAttentionTracker.state == .mayNeedAttention
        lifecycleDiagnosticRecorder.record(LifecycleDiagnosticEntry(
            source: "delayed_permission_timer",
            lifecycleEvent: event?.name.rawValue ?? "DelayedPermissionTimer",
            eventObservedAt: event?.observedAt,
            sessionID: event?.sessionID,
            turnID: event?.turnID,
            boundaryID: boundaryID.diagnosticIdentifier,
            lifecycleDisposition: nil,
            sessionUpdate: nil,
            permissionAttentionBefore: before,
            permissionAttentionAfter: permissionAttentionTracker.state,
            timerAction: enteredMayNeedAttention ? "promoted" : "preserved",
            enteredMayNeedAttention: enteredMayNeedAttention,
            attentionNotificationSent: dispatch != nil
        ))
    }

    private func recordLifecycleDiagnostic(
        event: LifecycleEvent,
        lifecycleDisposition: EventDisposition,
        sessionUpdate: WaitSessionUpdate?,
        trackerBefore: DelayedPermissionAttentionState,
        trackerAfter: DelayedPermissionAttentionState,
        timerAction: String,
        boundaryID: PermissionBoundaryID?,
        enteredMayNeedAttention: Bool,
        attentionNotificationSent: Bool
    ) {
        lifecycleDiagnosticRecorder.record(LifecycleDiagnosticEntry(
            source: "lifecycle_event",
            lifecycleEvent: event.name.rawValue,
            eventObservedAt: event.observedAt,
            sessionID: event.sessionID,
            turnID: event.turnID,
            boundaryID: boundaryID?.diagnosticIdentifier,
            lifecycleDisposition: String(describing: lifecycleDisposition),
            sessionUpdate: sessionUpdate.map { String(describing: $0) },
            permissionAttentionBefore: trackerBefore,
            permissionAttentionAfter: trackerAfter,
            timerAction: timerAction,
            enteredMayNeedAttention: enteredMayNeedAttention,
            attentionNotificationSent: attentionNotificationSent
        ))
    }

    private func clearPermissionAttention() {
        permissionAttentionTask?.cancel()
        permissionAttentionTask = nil
        permissionAttentionTracker.clear()
        permissionAttentionState = permissionAttentionTracker.state
    }

    private func recordActivity(_ observation: ActivityObservation) {
        let update = sessionTracker.recordActivity(observation)
        guard update != .ignored else { return }
        sessions = sessionTracker.sessions
        currentWaitSession = sessionTracker.currentSession
        persistSessions()
    }

    private func handleActivityCollection(for update: WaitSessionUpdate) {
        switch update {
        case let .started(sessionID), let .resumed(sessionID), let .attentionRecorded(sessionID):
            activityMonitor.begin(sessionID: sessionID)
            activityMetadataStatus = activityMonitor.accessibilityStatus
        case let .completed(sessionID), let .interrupted(sessionID):
            activityMonitor.end(sessionID: sessionID)
        case .ignored:
            break
        }
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = launchAtLoginController.isEnabled
        launchAtLoginStatus = launchAtLoginController.statusText
    }

    private func systemWillSleep(at date: Date) {
        systemStatus = "Sleeping; activity collection paused"
        clearPermissionAttention()
        suspendActivityCollection(at: date)
    }

    private func systemDidWake(at date: Date) {
        systemStatus = "Awake"
        refreshReliabilityStatus()
        guard case let .resumed(sessionID) = sessionTracker.resumeActivityCollection(at: date) else {
            return
        }
        activityMonitor.begin(sessionID: sessionID)
        sessions = sessionTracker.sessions
        currentWaitSession = sessionTracker.currentSession
    }

    private func suspendActivityCollection(at date: Date) {
        guard case let .suspended(sessionID) = sessionTracker.suspendActivityCollection(at: date)
        else {
            return
        }
        activityMonitor.end(sessionID: sessionID)
        sessions = sessionTracker.sessions
        currentWaitSession = sessionTracker.currentSession
        persistSessions()
    }

    private func prepareForTermination(at date: Date) {
        clearPermissionAttention()
        suspendActivityCollection(at: date)
        receiver?.stop()
    }
}

private struct MenuBarStatusView: View {
    @ObservedObject var model: LifecycleViewModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var hostWindowReference = MenuBarHostWindowReference()
    @State private var selectedReviewItemID: String?

    private var reviewItems: [WaitReviewItem] { model.pendingReviewItems }

    private var selectedReviewItem: WaitReviewItem? {
        guard let id = WaitReviewNavigation.resolvedSelectionID(
            preferredID: selectedReviewItemID,
            in: reviewItems
        ) else { return nil }
        return reviewItems.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuBarStatusHeader(
                status: model.userFacingWaitStatus,
                waitStartedAt: model.currentWaitSession?.startTime,
                reviewCount: reviewItems.count
            )

            if let item = selectedReviewItem,
               let position = WaitReviewNavigation.position(of: item.id, in: reviewItems) {
                CompactNeedsReviewCard(
                    item: item,
                    position: position,
                    canGoPrevious: position.current > 1,
                    canGoNext: position.current < position.total,
                    onPrevious: { moveReviewSelection(.previous) },
                    onNext: { moveReviewSelection(.next) },
                    onClassify: { classify(item, as: $0) },
                    onOpenDetails: { showDashboard(.review) }
                )
            } else if model.completedHistory.isEmpty {
                CompactEmptyState()
            }

            LastSevenDaysGlance(insights: model.historyInsights)

            Button {
                showDashboard(.overview)
            } label: {
                Label("Open Inbetween", systemImage: "rectangle.inset.filled")
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 14) {
                Button("Reflection", systemImage: "sparkles") {
                    showDashboard(.reflection)
                }
                Button("History", systemImage: "clock.arrow.circlepath") {
                    showDashboard(.history)
                }
                Spacer()
                Button {
                    showDashboard(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Open settings")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Divider()

            Button(role: .destructive) {
                model.quit()
            } label: {
                Label("Quit Inbetween", systemImage: "power")
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .accessibilityHint("Stops Inbetween and preserves any active wait conservatively.")
        }
        .padding(14)
        .background(.regularMaterial)
        .background {
            MenuBarHostWindowReader { window in
                hostWindowReference.window = window
            }
        }
        .onAppear {
            model.refreshReliabilityStatus()
            resolveReviewSelection()
        }
        .onChange(of: reviewItems.map(\.id)) { _ in resolveReviewSelection() }
    }

    private func showDashboard(_ destination: DashboardDestination) {
        model.dashboardDestination = destination
        openWindow(id: "dashboard")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func resolveReviewSelection() {
        selectedReviewItemID = WaitReviewNavigation.resolvedSelectionID(
            preferredID: selectedReviewItemID,
            in: reviewItems
        )
    }

    private func moveReviewSelection(_ direction: WaitReviewNavigation.Direction) {
        selectedReviewItemID = WaitReviewNavigation.adjacentSelectionID(
            from: selectedReviewItem?.id,
            direction: direction,
            in: reviewItems
        )
    }

    private func classify(_ item: WaitReviewItem, as classification: WaitSessionClassification) {
        let resolvesFinalReviewItem = reviewItems.count == 1
        WaitReviewResolutionOrder.perform(
            isFinalItem: resolvesFinalReviewItem,
            hidePresentation: {
                hostWindowReference.window?.orderOut(nil)
            },
            applyResolution: {
                selectedReviewItemID = WaitReviewNavigation.selectionIDAfterRemoving(
                    item.id,
                    from: reviewItems
                )
                switch item.source {
                case let .sliced(unit):
                    model.setSliceClassificationOverride(classification, for: unit)
                case let .legacy(sessionID):
                    model.setManualClassificationOverride(classification, for: sessionID)
                }
            }
        )
    }
}

private final class MenuBarHostWindowReference: ObservableObject {
    weak var window: NSWindow?
}

private struct MenuBarHostWindowReader: NSViewRepresentable {
    let onWindowChanged: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReadingView {
        WindowReadingView(onWindowChanged: onWindowChanged)
    }

    func updateNSView(_ nsView: WindowReadingView, context: Context) {
        nsView.onWindowChanged = onWindowChanged
    }

    final class WindowReadingView: NSView {
        var onWindowChanged: (NSWindow?) -> Void

        init(onWindowChanged: @escaping (NSWindow?) -> Void) {
            self.onWindowChanged = onWindowChanged
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged(window)
        }
    }
}

private struct MenuBarStatusHeader: View {
    let status: UserFacingWaitStatus
    let waitStartedAt: Date?
    let reviewCount: Int

    private var presentation: StatePresentation { StatePresentation(status: status) }
    private var reviewAccessibilitySummary: String {
        switch reviewCount {
        case 0: "Nothing needs review."
        case 1: "1 item needs review."
        default: "\(reviewCount) items need review."
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: presentation.symbol)
                .font(.headline.weight(.semibold))
                .foregroundStyle(presentation.tint)
                .frame(width: 34, height: 34)
                .background(presentation.tint.opacity(0.13), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(.headline)
                        .lineLimit(1)
                    if reviewCount > 0 {
                        Text("\(reviewCount)")
                            .font(.caption2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange, in: Capsule())
                            .accessibilityLabel("\(reviewCount) items need review")
                    }
                }
                if reviewCount > 0 {
                    Text("Review waiting")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)
            if let waitStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(DisplayFormat.duration(context.date.timeIntervalSince(waitStartedAt)))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.title). \(reviewAccessibilitySummary)")
    }
}

private struct CompactNeedsReviewCard: View {
    let item: WaitReviewItem
    let position: (current: Int, total: Int)
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClassify: (WaitSessionClassification) -> Void
    let onOpenDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Needs Review", systemImage: "questionmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text("\(position.current) of \(position.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.applicationName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.contextTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(DisplayFormat.duration(item.duration)) · \(item.startedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                classificationButton("Productive", symbol: "checkmark") {
                    onClassify(.productive)
                }
                classificationButton("Distracted", symbol: "pause.fill") {
                    onClassify(.distracted)
                }
            }

            HStack(spacing: 8) {
                Button(action: onPrevious) { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!canGoPrevious)
                    .accessibilityLabel("Previous review item")
                Button(action: onNext) { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!canGoNext)
                    .accessibilityLabel("Next review item")
                Spacer()
                Button("Review details…", action: onOpenDetails)
                    .buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func classificationButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .labelStyle(.titleOnly)
    }
}

private struct CompactEmptyState: View {
    var body: some View {
        Label("Your first completed Codex wait will appear here.", systemImage: "clock.badge.checkmark")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
    }
}

private struct LastSevenDaysGlance: View {
    let insights: WaitHistoryInsights

    private var summary: WaitHistoryInsights.Summary { insights.lastSevenDaysSummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label("Last 7 Days", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(DisplayFormat.duration(summary.totalCompletedDuration))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }

            if summary.completedSessionCount == 0 {
                Text("No completed waits yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
            } else {
                NonzeroClassificationLegend(summary: summary)
                LastSevenDaysChart(days: insights.lastSevenDays, height: 62)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DashboardView: View {
    @ObservedObject var model: LifecycleViewModel
    @State private var selectedReviewItemID: String?
    @State private var highlightedTimelineSessionID: UUID?
    @State private var highlightedTimelineReviewItemID: String?
    @State private var highlightedTimelineSliceIDs: Set<UUID> = []

    private var reviewItems: [WaitReviewItem] { model.pendingReviewItems }

    private var selectedReviewItem: WaitReviewItem? {
        guard let id = WaitReviewNavigation.resolvedSelectionID(
            preferredID: selectedReviewItemID,
            in: reviewItems
        ) else { return nil }
        return reviewItems.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            List(DashboardDestination.allCases, selection: $model.dashboardDestination) { destination in
                Label {
                    HStack {
                        Text(destination.title)
                        if destination == .review, !reviewItems.isEmpty {
                            Spacer()
                            Text("\(reviewItems.count)")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange, in: Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: destination.symbol)
                }
                .tag(destination)
            }
            .navigationTitle("Inbetween")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            detail
                .navigationTitle(model.dashboardDestination.title)
        }
        .onAppear {
            model.refreshReliabilityStatus()
            resolveReviewSelection()
        }
        .onChange(of: reviewItems.map(\.id)) { _ in resolveReviewSelection() }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.dashboardDestination {
        case .overview:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DashboardStatusSummary(model: model)
                    if !reviewItems.isEmpty {
                        Button {
                            model.dashboardDestination = .review
                        } label: {
                            HStack {
                                Label("\(reviewItems.count) item\(reviewItems.count == 1 ? "" : "s") need review", systemImage: "questionmark.circle.fill")
                                    .foregroundStyle(.orange)
                                Spacer()
                                Text("Review")
                                Image(systemName: "chevron.right")
                            }
                            .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.borderless)
                    }
                    LastSevenDaysSection(insights: model.historyInsights, sessions: model.sessions)
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        case .review:
            ScrollView {
                Group {
                    if let item = selectedReviewItem,
                       let position = WaitReviewNavigation.position(of: item.id, in: reviewItems) {
                        NeedsReviewSection(
                            item: item,
                            position: position,
                            canGoPrevious: position.current > 1,
                            canGoNext: position.current < position.total,
                            onPrevious: { moveReviewSelection(.previous) },
                            onNext: { moveReviewSelection(.next) },
                            onClassify: { classify(item, as: $0) },
                            onJumpToTimeline: { showInTimeline(item) }
                        )
                    } else {
                        DashboardEmptyState(
                            title: "Nothing needs review",
                            detail: "Local classification has no unresolved activity waiting for you.",
                            symbol: "checkmark.circle.fill",
                            tint: .green
                        )
                    }
                }
                .padding(24)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        case .reflection:
            ScrollView {
                ReflectionChatSection(model: model, onViewEvidence: showReflectionEvidence)
                .padding(24)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        case .history:
            historyDetail
        case .settings:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AppStatusSection(model: model, initiallyExpanded: true)
                    Divider()
                    Button(role: .destructive) {
                        model.quit()
                    } label: {
                        Label("Quit Inbetween", systemImage: "power")
                    }
                }
                .padding(24)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var historyDetail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HistorySection(
                    sessions: model.completedHistory,
                    highlightedSessionID: $highlightedTimelineSessionID,
                    highlightedReviewItemID: highlightedTimelineReviewItemID,
                    highlightedSliceIDs: highlightedTimelineSliceIDs,
                    model: model
                )
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { scrollToTimelineHighlight(using: proxy) }
            .onChange(of: highlightedTimelineSessionID) { _ in scrollToTimelineHighlight(using: proxy) }
        }
    }

    private func resolveReviewSelection() {
        selectedReviewItemID = WaitReviewNavigation.resolvedSelectionID(
            preferredID: selectedReviewItemID,
            in: reviewItems
        )
    }

    private func moveReviewSelection(_ direction: WaitReviewNavigation.Direction) {
        selectedReviewItemID = WaitReviewNavigation.adjacentSelectionID(
            from: selectedReviewItem?.id,
            direction: direction,
            in: reviewItems
        )
    }

    private func classify(_ item: WaitReviewItem, as classification: WaitSessionClassification) {
        selectedReviewItemID = WaitReviewNavigation.selectionIDAfterRemoving(item.id, from: reviewItems)
        switch item.source {
        case let .sliced(unit):
            model.setSliceClassificationOverride(classification, for: unit)
        case let .legacy(sessionID):
            model.setManualClassificationOverride(classification, for: sessionID)
        }
    }

    private func showInTimeline(_ item: WaitReviewItem) {
        highlightedTimelineSessionID = item.waitSessionID
        highlightedTimelineReviewItemID = item.id
        highlightedTimelineSliceIDs = []
        model.dashboardDestination = .history
    }

    private func showReflectionEvidence(_ evidenceID: String, scope: ReflectionScope) {
        let links = model.reflectionSnapshot(for: scope).evidenceLinks
        guard let link = links[evidenceID] else { return }
        highlightedTimelineSessionID = link.waitSessionID
        highlightedTimelineReviewItemID = nil
        highlightedTimelineSliceIDs = Set(link.sourceSliceIDs)
        model.dashboardDestination = .history
    }

    private func scrollToTimelineHighlight(using proxy: ScrollViewProxy) {
        guard let sessionID = highlightedTimelineSessionID else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation { proxy.scrollTo(sessionID, anchor: .center) }
        }
    }
}

private struct DashboardStatusSummary: View {
    @ObservedObject var model: LifecycleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHero(status: model.userFacingWaitStatus, duration: model.currentWaitSession?.startTime)
            if let session = model.currentWaitSession {
                CurrentWaitCard(session: session, systemStatus: model.systemStatus)
            }
        }
    }
}

private struct DashboardEmptyState: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(tint)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .accessibilityElement(children: .combine)
    }
}

private struct CompactListeningStatus: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Listening for Codex")
                    .font(.subheadline.weight(.semibold))
                Text("A wait begins when Codex starts working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Inbetween is listening for Codex. A wait begins when Codex starts working.")
    }
}

private struct EmptyHistoryCard: View {
    var body: some View {
        SectionCard {
            Label("No completed activity yet", systemImage: "tray")
                .font(.headline)
            Text("When Codex completes a wait, Inbetween will classify the captured activity locally and show anything uncertain here for review.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ReviewQueueStatus: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nothing needs review")
                    .font(.subheadline.weight(.semibold))
                Text("Local classification has no unresolved activity waiting for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct StatusHero: View {
    let status: UserFacingWaitStatus
    let duration: Date?

    private var presentation: StatePresentation {
        StatePresentation(status: status)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: presentation.symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(presentation.tint)
                .frame(width: 44, height: 44)
                .background(presentation.tint.opacity(0.14), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.eyebrow)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(presentation.title)
                    .font(.title3.weight(.semibold))
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            if let duration {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(DisplayFormat.duration(context.date.timeIntervalSince(duration)))
                        .font(.title3.monospacedDigit().weight(.medium))
                        .accessibilityLabel("Current wait duration \(DisplayFormat.duration(context.date.timeIntervalSince(duration)))")
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(presentation.tint.opacity(0.09)))
        .accessibilityElement(children: .combine)
    }
}

private struct CurrentWaitCard: View {
    let session: WaitSession
    let systemStatus: String

    var body: some View {
        SectionCard {
            HStack {
                Label("Current wait", systemImage: "clock")
                    .font(.headline)
                Spacer()
                Text("Started \(session.startTime.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let segment = session.currentActivitySegment {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Current activity")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let duration = session.currentActivityObservedDuration(at: context.date)
                                ?? segment.elapsed(at: context.date)
                            Text(DisplayFormat.duration(duration))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(
                                    "Current activity duration \(DisplayFormat.duration(duration))"
                                )
                        }
                    }

                    Text(segment.context.compactDisplayComponents.joined(separator: " · "))
                        .font(.subheadline)
                        .lineLimit(2)

                    if let presence = segment.context.presenceState {
                        Label(presence.displayTitle, systemImage: presence.displaySymbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Label("Waiting for a foreground activity observation", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if systemStatus != "Awake" {
                Label(systemStatus, systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

}

private struct ReflectionChatSection: View {
    @ObservedObject var model: LifecycleViewModel
    let onViewEvidence: (String, ReflectionScope) -> Void
    @State private var scope: ReflectionScope = .today
    @State private var question = ""
    @FocusState private var composerFocused: Bool

    private var prepared: AIInsightPreparedSnapshot { model.reflectionSnapshot(for: scope) }
    private var messages: [ReflectionChatMessage] { model.reflectionMessages(for: scope) }
    private var isLoading: Bool { model.reflectionLoadingScopes.contains(scope) }
    private var metrics: AIInsightDurations { prepared.payload.durations }

    var body: some View {
        SectionCard {
            HStack {
                Label("Reflection", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Picker("Analysis scope", selection: $scope) {
                    ForEach(ReflectionScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
            }

            Text("Local calculations stay authoritative. Featherless only interprets the snapshot after you ask a question.")
                .font(.caption)
                .foregroundStyle(.secondary)

            localSummary

            if messages.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Try asking")
                        .font(.caption.weight(.semibold))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(scope.suggestedQuestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                question = suggestion
                                submit()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.role == .user ? "You" : "Reflection")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(message.text)
                                .font(.callout)
                                .textSelection(.enabled)
                            if message.role == .assistant, !message.evidenceIDs.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(message.evidenceIDs.prefix(3), id: \.self) { evidenceID in
                                        Button("View evidence", systemImage: "arrow.right.circle") {
                                            onViewEvidence(evidenceID, scope)
                                        }
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                        .disabled(prepared.evidenceLinks[evidenceID] == nil)
                                    }
                                }
                            }
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(message.role == .user ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about \(scope.title.lowercased())…", text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .onSubmit(submit)
                Button {
                    submit()
                } label: {
                    if isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.up.circle.fill") }
                }
                .buttonStyle(.bordered)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading || !model.isReflectionConfigured)
                .accessibilityLabel("Send reflection question")
            }

            HStack {
                AIStatusRow(
                    state: model.isReflectionConfigured ? (isLoading ? .loading : .idle) : .unavailable,
                    text: model.reflectionStatus(for: scope)
                )
                Spacer()
                if !messages.isEmpty {
                    Button("New Conversation", systemImage: "plus.bubble") {
                        model.newReflectionConversation(scope: scope)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                if !model.isReflectionConfigured {
                    Button("AI Settings…", systemImage: "gearshape") {
                        model.dashboardDestination = .settings
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

#if DEBUG
            SanitizedInsightSnapshotDisclosure(prepared: prepared, generationSource: nil)
#endif
        }
        .onChange(of: scope) { _ in
            question = ""
            model.activateReflectionScope(scope)
        }
        .onAppear { model.activateReflectionScope(scope) }
        .onChange(of: prepared.fingerprint) { _ in
            model.activateReflectionScope(scope)
        }
    }

    @ViewBuilder
    private var localSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                if metrics.productiveSeconds > 0 { metric("Productive", metrics.productiveSeconds) }
                if metrics.distractedSeconds > 0 { metric("Distracted", metrics.distractedSeconds) }
                if metrics.unclassifiedSeconds > 0 { metric("Unclassified", metrics.unclassifiedSeconds) }
                Spacer()
                Text("\(prepared.payload.contextSwitchCount) switches")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if scope == .lastSevenDays {
                HStack(spacing: 8) {
                    ForEach(prepared.payload.days) { day in
                        VStack(spacing: 1) {
                            Text(day.date.suffix(5)).font(.caption2)
                            Text(DisplayFormat.duration(TimeInterval(day.durations.productiveSeconds)))
                                .font(.caption2.monospacedDigit().weight(.medium))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityLabel("Daily productive time for the last seven days")
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ title: String, _ seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(DisplayFormat.duration(TimeInterval(seconds))).font(.caption.monospacedDigit().weight(.medium))
        }
    }

    private func submit() {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        question = ""
        model.sendReflectionQuestion(value, scope: scope)
    }
}

private struct ReflectionSection: View {
    let prepared: AIInsightPreparedSnapshot
    let insights: [AIInsight]
    let status: String
    let state: AIUIState
    let generationSource: AIInsightGenerationSource?
    let isConfigured: Bool
    let canGenerate: Bool
    let isGenerating: Bool
    let onGenerate: (Bool) -> Void
    let onViewEvidence: (AIInsight) -> Void
    let onOpenSettings: () -> Void

    private var metrics: AIInsightDurations { prepared.payload.durations }
    private var displayedStatus: String {
        guard isConfigured else { return status }
        if prepared.payload.completedSessionCount == 0 {
            return "Reflection becomes available after today’s first completed wait."
        }
        if !canGenerate {
            return "There isn’t enough classified activity today for an evidence-backed reflection."
        }
        return status
    }

    var body: some View {
        SectionCard {
            HStack(alignment: .firstTextBaseline) {
                Label("Reflection", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text("TODAY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Inbetween calculates the totals locally. AI only interprets the summary when you ask.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if prepared.payload.completedSessionCount == 0 {
                Label(
                    "Complete a Codex wait today to build a reflection.",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    metricLine(
                        "Classification",
                        values: [
                            metrics.productiveSeconds > 0
                                ? "\(DisplayFormat.duration(TimeInterval(metrics.productiveSeconds))) Productive" : nil,
                            metrics.distractedSeconds > 0
                                ? "\(DisplayFormat.duration(TimeInterval(metrics.distractedSeconds))) Distracted" : nil,
                            metrics.unclassifiedSeconds > 0
                                ? "\(DisplayFormat.duration(TimeInterval(metrics.unclassifiedSeconds))) Unclassified" : nil
                        ].compactMap { $0 }
                    )
                    metricLine(
                        "Presence",
                        values: [
                            metrics.activeSeconds > 0
                                ? "\(DisplayFormat.duration(TimeInterval(metrics.activeSeconds))) Active" : nil,
                            metrics.idleSeconds > 0
                                ? "\(DisplayFormat.duration(TimeInterval(metrics.idleSeconds))) Idle" : nil,
                            metrics.awaySeconds > 0
                                ? "\(DisplayFormat.duration(TimeInterval(metrics.awaySeconds))) Away" : nil
                        ].compactMap { $0 }
                    )
                    Text("\(prepared.payload.contextSwitchCount) context switches · \(prepared.payload.completedSessionCount) completed waits")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                ForEach(insights) { insight in
                    insightCard(insight)
                }

                if insights.isEmpty, canGenerate, state != .loading {
                    Text("Generate a concise reading of focus, distraction, and switching patterns, grounded in the timeline evidence below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                onGenerate(!insights.isEmpty)
            } label: {
                HStack(spacing: 7) {
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(
                        isGenerating
                            ? "Generating reflection…"
                            : (insights.isEmpty ? "Generate Reflection" : "Regenerate Reflection")
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGenerating || !isConfigured || !canGenerate)

            AIStatusRow(state: state, text: displayedStatus)

            if !isConfigured {
                Button("AI Settings…", systemImage: "gearshape", action: onOpenSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

#if DEBUG
            SanitizedInsightSnapshotDisclosure(
                prepared: prepared,
                generationSource: generationSource
            )
#endif
        }
    }

    @ViewBuilder
    private func metricLine(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(values.joined(separator: " · "))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func insightCard(_ insight: AIInsight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(insight.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let confidence = insight.confidence {
                    Text("\(Int((confidence * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(insight.observation)
                .font(.caption)
            if let suggestion = insight.suggestion {
                Text(suggestion)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(evidenceLabel(for: insight))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("View evidence", systemImage: "arrow.down.to.line") {
                onViewEvidence(insight)
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!insight.evidenceIDs.contains(where: { prepared.evidenceLinks[$0] != nil }))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func evidenceLabel(for insight: AIInsight) -> String {
        let values = insight.evidenceIDs.compactMap { id in
            prepared.payload.evidence.first(where: { $0.id == id }).map { evidence in
                let start = prepared.evidenceLinks[id]?.startedAt.formatted(date: .omitted, time: .shortened)
                let end = prepared.evidenceLinks[id]?.endedAt.formatted(date: .omitted, time: .shortened)
                let range = start.flatMap { start in end.map { "\(start)–\($0)" } }
                return [evidence.kind.rawValue.replacingOccurrences(of: "_", with: " "), range]
                    .compactMap { $0 }.joined(separator: " · ")
            }
        }
        return values.isEmpty ? "Evidence unavailable" : "Evidence: " + values.joined(separator: ", ")
    }
}

#if DEBUG
private struct SanitizedInsightSnapshotDisclosure: View {
    let prepared: AIInsightPreparedSnapshot
    let generationSource: AIInsightGenerationSource?

    var body: some View {
        DisclosureGroup("Developer · snapshot sent") {
            if let generationSource {
                Text("Insight source: \(generationSource.title)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(payloadText)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .font(.caption2)
    }

    private var payloadText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(prepared.payload),
              let value = String(data: data, encoding: .utf8)
        else { return "Sanitized snapshot unavailable" }
        return value
    }
}
#endif

private struct LastSevenDaysSection: View {
    let insights: WaitHistoryInsights
    let sessions: [WaitSession]
    @State private var showsTimeBreakdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if insights.lastSevenDaysSummary.completedSessionCount == 0 {
                Label("Last 7 Days", systemImage: "chart.bar.fill")
                    .font(.headline)
                Text("Insights will appear after Codex completes a wait.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LastSevenDaysDashboard(
                    days: insights.lastSevenDays,
                    summary: insights.lastSevenDaysSummary,
                    sessions: sessions
                )

                FullWidthDisclosure(isExpanded: $showsTimeBreakdown) {
                    Label("Recent weeks", systemImage: "calendar")
                        .font(.subheadline)
                } content: {
                    PeriodList(title: "Recent weeks", periods: insights.recentWeeks, style: .week)
                        .padding(.top, 8)
                }
                .accessibilityHint("Shows newest-first completed wait time by week.")
            }
        }
    }
}

private struct LastSevenDaysDashboard: View {
    let days: [WaitHistoryInsights.Period]
    let summary: WaitHistoryInsights.Summary
    let sessions: [WaitSession]
    @State private var selectedClassification: WaitSessionClassification?

    private var maximumDailyDuration: TimeInterval {
        max(3_600, days.map(\.summary.totalCompletedDuration).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Last 7 Days", systemImage: "chart.bar.fill")
                .font(.headline)

            HStack(spacing: 8) {
                Text("Total Codex wait time")
                Spacer(minLength: 12)
                Text(DisplayFormat.duration(summary.totalCompletedDuration))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 28)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Total Codex wait time \(DisplayFormat.spokenDuration(summary.totalCompletedDuration))")

            VStack(spacing: 2) {
                if summary.productiveDuration >= 1 {
                    ClassificationSummaryButton(
                        classification: .productive,
                        duration: summary.productiveDuration,
                        isSelected: selectedClassification == .productive,
                        action: { toggle(.productive) }
                    )
                }
                if summary.distractedDuration >= 1 {
                    ClassificationSummaryButton(
                        classification: .distracted,
                        duration: summary.distractedDuration,
                        isSelected: selectedClassification == .distracted,
                        action: { toggle(.distracted) }
                    )
                }
                if summary.unclassifiedDuration >= 1 {
                    ClassificationSummaryButton(
                        classification: .unclassified,
                        duration: summary.unclassifiedDuration,
                        isSelected: selectedClassification == .unclassified,
                        action: { toggle(.unclassified) }
                    )
                }
                if summary.notRecordedDuration >= 1 {
                    SummaryDurationRow(
                        title: "Not recorded",
                        duration: summary.notRecordedDuration,
                        appearance: .notRecorded
                    )
                }
            }

            if summary.notRecordedDuration >= 1 {
                Text("Not recorded means older waits saved before classification was available.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let selectedClassification {
                Divider()
                ContributorBreakdown(
                    classification: selectedClassification,
                    contributors: WaitHistoryContributorAggregator.contributors(
                        from: sessions,
                        classification: selectedClassification
                    )
                )
            }

            LastSevenDaysChart(days: days, height: 88)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last 7 days of Codex wait time")
    }

    private func toggle(_ classification: WaitSessionClassification) {
        selectedClassification = selectedClassification == classification ? nil : classification
    }
}

private struct NonzeroClassificationLegend: View {
    let summary: WaitHistoryInsights.Summary

    var body: some View {
        HStack(spacing: 12) {
            if summary.productiveDuration >= 1 {
                legendItem(.productive, duration: summary.productiveDuration)
            }
            if summary.distractedDuration >= 1 {
                legendItem(.distracted, duration: summary.distractedDuration)
            }
            if summary.unclassifiedDuration >= 1 {
                legendItem(.unclassified, duration: summary.unclassifiedDuration)
            }
            if summary.notRecordedDuration >= 1 {
                legendItem(.notRecorded, duration: summary.notRecordedDuration)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func legendItem(
        _ kind: ClassificationAppearance.Kind,
        duration: TimeInterval
    ) -> some View {
        let appearance = ClassificationAppearance(kind: kind)
        return HStack(spacing: 4) {
            Circle()
                .fill(appearance.tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(appearance.title)
                .lineLimit(1)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(appearance.title), \(DisplayFormat.spokenDuration(duration))")
    }
}

private struct LastSevenDaysChart: View {
    struct Segment: Identifiable {
        let id: String
        let date: Date
        let kind: ClassificationAppearance.Kind
        let duration: TimeInterval
        let category: String
    }

    let days: [WaitHistoryInsights.Period]
    let height: CGFloat

    private var maximumDailyDuration: TimeInterval {
        max(3_600, days.map(\.summary.totalCompletedDuration).max() ?? 0)
    }

    private var segments: [Segment] {
        days.flatMap { day in
            let values: [(ClassificationAppearance.Kind, TimeInterval)] = [
                (.productive, day.summary.productiveDuration),
                (.distracted, day.summary.distractedDuration),
                (.unclassified, day.summary.unclassifiedDuration),
                (.notRecorded, day.summary.notRecordedDuration)
            ]
            return values.compactMap { value -> Segment? in
                let (kind, duration) = value
                guard duration >= 1 else { return nil }
                return Segment(
                    id: "\(day.id)-\(ClassificationAppearance(kind: kind).title)",
                    date: day.startDate,
                    kind: kind,
                    duration: duration,
                    category: ClassificationAppearance(kind: kind).title
                )
            }
        }
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Baseline", 0))
                .foregroundStyle(Color.secondary.opacity(0.28))

            ForEach(segments) { segment in
                BarMark(
                    x: .value("Day", segment.date, unit: .day),
                    y: .value("Duration", segment.duration)
                )
                .foregroundStyle(by: .value("Classification", segment.category))
            }
        }
        .chartForegroundStyleScale([
            "Productive": ClassificationAppearance(kind: .productive).tint,
            "Distracted": ClassificationAppearance(kind: .distracted).tint,
            "Unclassified": ClassificationAppearance(kind: .unclassified).tint,
            "Not recorded": ClassificationAppearance(kind: .notRecorded).tint
        ])
        .chartXScale(domain: chartDomain)
        .chartYScale(domain: 0...(maximumDailyDuration * 1.06))
        .chartXAxis {
            AxisMarks(values: days.map(\.startDate)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Calendar.current.isDateInToday(date)
                            ? "Today"
                            : date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(Calendar.current.isDateInToday(date) ? .semibold : .regular))
                            .foregroundStyle(Calendar.current.isDateInToday(date) ? .primary : .secondary)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.clipped()
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last 7 days activity chart")
    }

    private var chartDomain: ClosedRange<Date> {
        let start = days.first?.startDate ?? Date()
        let endStart = days.last?.startDate ?? start
        let end = Calendar.current.date(byAdding: .day, value: 1, to: endStart) ?? endStart
        return start...end
    }
}

private struct ClassificationSummaryButton: View {
    let classification: WaitSessionClassification
    let duration: TimeInterval
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    private var appearance: ClassificationAppearance {
        ClassificationAppearance(classification: classification)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: appearance.symbol)
                    .foregroundStyle(duration > 0 ? appearance.tint : .secondary)
                    .accessibilityHidden(true)
                Text(appearance.title)
                    .fontWeight(duration > 0 ? .medium : .regular)
                Spacer(minLength: 12)
                Text(DisplayFormat.duration(duration))
                    .monospacedDigit()
                    .fontWeight(duration > 0 ? .semibold : .regular)
                Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(duration > 0 ? .subheadline : .caption)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: duration > 0 ? 32 : 24)
            .background(
                duration > 0 && (isSelected || isHovering)
                    ? appearance.tint.opacity(isSelected ? 0.12 : 0.06)
                    : .clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(appearance.title), \(DisplayFormat.spokenDuration(duration))")
        .accessibilityValue(isSelected ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows activity that contributed to this classification.")
    }
}

private struct ContributorBreakdown: View {
    let classification: WaitSessionClassification
    let contributors: [WaitHistoryContribution]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(classification.title) contributors")
                .font(.caption.weight(.semibold))
            if contributors.isEmpty {
                Text("No \(classification.title.lowercased()) time in the last 7 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(contributors) { contributor in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(contributor.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(DisplayFormat.duration(contributor.duration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(contributor.label), \(DisplayFormat.spokenDuration(contributor.duration))")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SummaryDurationRow: View {
    let title: String
    let duration: TimeInterval
    let appearance: ClassificationAppearance.Kind

    var body: some View {
        let classificationAppearance = ClassificationAppearance(kind: appearance)
        HStack(spacing: 5) {
            Image(systemName: classificationAppearance.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(DisplayFormat.duration(duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(DisplayFormat.spokenDuration(duration))")
    }
}

private struct DayStackedBar: View {
    let period: WaitHistoryInsights.Period
    let maximumDailyDuration: TimeInterval
    let isToday: Bool

    private var summary: WaitHistoryInsights.Summary { period.summary }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                VStack(spacing: 1) {
                    barSegment(.productive, duration: summary.productiveDuration, availableHeight: geometry.size.height)
                    barSegment(.distracted, duration: summary.distractedDuration, availableHeight: geometry.size.height)
                    barSegment(.unclassified, duration: summary.unclassifiedDuration, availableHeight: geometry.size.height)
                    barSegment(.notRecorded, duration: summary.notRecordedDuration, availableHeight: geometry.size.height)
                    if summary.totalCompletedDuration == 0 {
                        Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 2)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 54)

            Text(isToday ? "Today" : period.startDate.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2.weight(isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func barSegment(
        _ kind: ClassificationAppearance.Kind,
        duration: TimeInterval,
        availableHeight: CGFloat
    ) -> some View {
        if duration > 0 {
            Rectangle()
                .fill(ClassificationAppearance(kind: kind).tint)
                .frame(height: max(3, availableHeight * duration / maximumDailyDuration))
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        let date = isToday ? "Today" : period.startDate.formatted(.dateTime.weekday(.wide).month(.wide).day())
        return "\(date): total \(DisplayFormat.duration(summary.totalCompletedDuration)); Productive \(DisplayFormat.duration(summary.productiveDuration)); Distracted \(DisplayFormat.duration(summary.distractedDuration)); Unclassified \(DisplayFormat.duration(summary.unclassifiedDuration)); Not recorded \(DisplayFormat.duration(summary.notRecordedDuration))"
    }
}

private struct PeriodList: View {
    enum Style { case day, week }

    let title: String
    let periods: [WaitHistoryInsights.Period]
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(periods) { period in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                    Text(label(for: period))
                        .frame(width: 84, alignment: .leading)
                    Spacer()
                    Text(period.summary.totalCompletedDuration > 0
                        ? DisplayFormat.duration(period.summary.totalCompletedDuration)
                        : "—")
                        .monospacedDigit()
                    }
                    PeriodDurationBreakdown(summary: period.summary)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(label(for: period)): \(DisplayFormat.duration(period.summary.totalCompletedDuration)) total completed wait time")
            }
        }
    }

    private func label(for period: WaitHistoryInsights.Period) -> String {
        switch style {
        case .day:
            return period.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week:
            let end = Calendar.current.date(byAdding: .day, value: -1, to: period.endDate) ?? period.endDate
            return "\(period.startDate.formatted(.dateTime.month(.abbreviated).day()))–\(end.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }
}

private struct PeriodDurationBreakdown: View {
    let summary: WaitHistoryInsights.Summary

    var body: some View {
        HStack(spacing: 8) {
            if summary.productiveDuration >= 1 { duration("Productive", summary.productiveDuration) }
            if summary.distractedDuration >= 1 { duration("Distracted", summary.distractedDuration) }
            if summary.unclassifiedDuration >= 1 { duration("Unclassified", summary.unclassifiedDuration) }
            if summary.notRecordedDuration >= 1 { duration("Not recorded", summary.notRecordedDuration) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func duration(_ label: String, _ value: TimeInterval) -> some View {
        Text("\(label) \(DisplayFormat.duration(value))")
    }
}

private struct AIStatusRow: View {
    let state: AIUIState
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
    }

    private var symbol: String {
        switch state {
        case .unavailable: "lock"
        case .idle: "info.circle"
        case .loading: "clock"
        case .success: "checkmark.circle"
        case .failure: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch state {
        case .success: .green
        case .failure: .orange
        case .unavailable, .idle, .loading: .secondary
        }
    }
}

private struct NeedsReviewSection: View {
    let item: WaitReviewItem
    let position: (current: Int, total: Int)
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClassify: (WaitSessionClassification) -> Void
    let onJumpToTimeline: () -> Void

    var body: some View {
        SectionCard {
            HStack {
                Label("Needs Review", systemImage: "questionmark.circle")
                    .font(.headline)
                Spacer()
                Text("\(position.current) of \(position.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.applicationName)
                        .font(.subheadline.weight(.medium))
                    if case let .sliced(unit) = item.source {
                        Text("· \(unit.presenceState.reviewTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let location = item.contextLocation {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.contextTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(DisplayFormat.duration(item.duration))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                Text(item.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if item.before != nil || item.after != nil {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Surrounding activity")
                        .font(.caption.weight(.semibold))
                    if let before = item.before {
                        ReviewContextRow(label: "Before", context: before)
                    }
                    if let after = item.after {
                        ReviewContextRow(label: "After", context: after)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Manual decision needed")
                    .font(.caption.weight(.semibold))
                Text("Inbetween’s local rules could not resolve this activity confidently. It remains Unclassified until you choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.07))
            )

            HStack(spacing: 8) {
                Button("Previous", systemImage: "chevron.left", action: onPrevious)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!canGoPrevious)
                Spacer()
                Button("View in timeline", systemImage: "arrow.down.to.line", action: onJumpToTimeline)
                    .buttonStyle(.borderless)
                Spacer()
                Button("Next", systemImage: "chevron.right", action: onNext)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!canGoNext)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Confirm classification")
                .font(.caption.weight(.semibold))

            HStack(spacing: 8) {
                Button("Productive") {
                    onClassify(.productive)
                }
                .buttonStyle(.bordered)
                Button("Distracted") {
                    onClassify(.distracted)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs Review. \(item.applicationName), \(item.contextTitle), \(timeRange), \(DisplayFormat.spokenDuration(item.duration)). \(position.current) of \(position.total).")
    }

    private var timeRange: String {
        let start = item.startedAt.formatted(date: .omitted, time: .shortened)
        let end = item.endedAt.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(item.startedAt, inSameDayAs: item.endedAt) {
            return "\(start) – \(end)"
        }
        return "\(item.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(item.endedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct ReviewContextRow: View {
    let label: String
    let context: WaitReviewActivityContext

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(context.applicationName) · \(context.contextTitle)")
                    .font(.caption)
                    .lineLimit(1)
                Text("\(context.startedAt.formatted(date: .omitted, time: .shortened)) · \(DisplayFormat.duration(context.duration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HistorySection: View {
    let sessions: [WaitSession]
    @Binding var highlightedSessionID: UUID?
    let highlightedReviewItemID: String?
    let highlightedSliceIDs: Set<UUID>
    @ObservedObject var model: LifecycleViewModel
    @State private var showsOlderHistory = false

    private var visibleSessions: ArraySlice<WaitSession> {
        let highlightsOlderSession = highlightedSessionID.map { highlighted in
            !sessions.prefix(5).contains(where: { $0.id == highlighted })
        } ?? false
        return sessions.prefix(showsOlderHistory || highlightsOlderSession ? sessions.count : 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            if sessions.isEmpty {
                Text("Completed Codex waits will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(visibleSessions) { session in
                        SessionHistoryRow(
                            session: session,
                            isHighlighted: highlightedSessionID == session.id,
                            highlightedReviewItemID: highlightedReviewItemID,
                            highlightedSliceIDs: highlightedSliceIDs,
                            model: model
                        )
                        .id(session.id)
                    }
                }

                if sessions.count > 5 {
                    Button {
                        showsOlderHistory.toggle()
                    } label: {
                        HStack {
                            Text(showsOlderHistory ? "Show less" : "Show more · \(sessions.count - 5)")
                            Spacer()
                            Image(systemName: showsOlderHistory ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityValue(showsOlderHistory ? "Expanded" : "Collapsed")
                }
            }
        }
    }
}

private struct SessionHistoryRow: View {
    let session: WaitSession
    let isHighlighted: Bool
    let highlightedReviewItemID: String?
    let highlightedSliceIDs: Set<UUID>
    @ObservedObject var model: LifecycleViewModel
    @State private var isExpanded = false

    private var appearance: ClassificationAppearance {
        ClassificationAppearance(session: session)
    }

    private var isSliced: Bool { session.activityClassificationSlices != nil }

    private var slicedDurations: WaitHistoryInsights.ClassificationDurations {
        WaitHistoryInsights.classificationDurations(for: session)
    }

    private var headerTitle: String {
        guard isSliced else { return appearance.title }
        if slicedDurations.nonzeroClassificationCount > 1 { return "Mixed activity" }
        return slicedSingleClassification?.title ?? "Unclassified"
    }

    private var headerSymbol: String {
        guard isSliced else { return appearance.symbol }
        guard slicedDurations.nonzeroClassificationCount <= 1,
              let classification = slicedSingleClassification
        else { return "chart.bar.xaxis" }
        return ClassificationAppearance(classification: classification).symbol
    }

    private var headerTint: Color {
        guard isSliced else { return appearance.tint }
        guard slicedDurations.nonzeroClassificationCount <= 1,
              let classification = slicedSingleClassification
        else { return .secondary }
        return ClassificationAppearance(classification: classification).tint
    }

    private var slicedSingleClassification: WaitSessionClassification? {
        guard isSliced, slicedDurations.nonzeroClassificationCount <= 1 else { return nil }
        if slicedDurations.productive > 0 { return .productive }
        if slicedDurations.distracted > 0 { return .distracted }
        if slicedDurations.unclassified > 0 { return .unclassified }
        return nil
    }

    var body: some View {
        FullWidthDisclosure(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: headerSymbol)
                        .foregroundStyle(headerTint)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(headerTitle)
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 12)
                    Text(session.duration.map(DisplayFormat.duration) ?? "—")
                        .font(.subheadline.monospacedDigit().weight(.medium))
                }
                Text(contextSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let breakdown = WaitPresentationSupport.historyDurationBreakdown(for: session) {
                    Text(breakdown)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(completionLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } content: {
            VStack(alignment: .leading, spacing: 5) {
                if isSliced {
                    Text(WaitPresentationSupport.historyDurationBreakdown(for: session) ?? "No classified duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sliceClassificationDetails
                } else {
                    Text(appearance.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !session.activitySegments.isEmpty {
                        activityDetails
                    }
                    classificationSummary
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Change classification")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 6) {
                        classificationButton("Productive", value: .productive)
                        classificationButton("Distracted", value: .distracted)
                        classificationButton("Unclassified", value: .unclassified)
                    }
                    .controlSize(.small)
                    if session.manualClassificationOverride != nil {
                        Button("Reset correction") {
                            model.setManualClassificationOverride(nil, for: session.id)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .onChange(of: isHighlighted) { highlighted in
            if highlighted { isExpanded = true }
        }
        .accessibilityLabel("\(completionLabel), \(headerTitle), \(DisplayFormat.spokenDuration(session.duration ?? 0)), \(contextSummary)")
        .accessibilityHint("Expand for the local classification explanation and observed activity summary.")
    }

    private var completionLabel: String {
        let date = WaitPresentationSupport.completionDate(for: session)
        if Calendar.current.isDateInToday(date) {
            return "Today \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var contextSummary: String {
        WaitPresentationSupport.strongestContextLabel(for: session) ?? "No activity context recorded"
    }

    @ViewBuilder
    private var classificationSummary: some View {
        if let manual = session.manualClassificationOverride {
            if let automatic = session.automaticClassification {
                Text("Inbetween classified this as \(automatic.title). You changed it to \(manual.title).")
            } else {
                Text("No classification was recorded. You changed it to \(manual.title).")
            }
        } else if let automatic = session.automaticClassification {
            Text("Inbetween classified this as \(automatic.title).")
        } else {
            Text("No classification was recorded for this older wait.")
        }
    }

    private func classificationButton(
        _ title: String,
        value: WaitSessionClassification
    ) -> some View {
        Button(title) {
            model.setManualClassificationOverride(value, for: session.id)
        }
        .buttonStyle(.bordered)
        .disabled(session.manualClassificationOverride == value)
        .accessibilityLabel("Change classification to \(title)")
    }

    @ViewBuilder
    private var activityDetails: some View {
        let groups = ActivityHistoryGrouper.grouped(session.activitySegments)
        let visibleIndices = Array(groups.indices.suffix(5))

        VStack(alignment: .leading, spacing: 6) {
            Text("Observed activity")
                .font(.caption.weight(.semibold))
            ForEach(visibleIndices, id: \.self) { index in
                ActivityHistoryGroupRow(group: groups[index], model: model)
            }
            if groups.count > visibleIndices.count {
                Text("Showing the \(visibleIndices.count) most recent of \(groups.count) activity contexts.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sliceClassificationDetails: some View {
        let units = WaitPresentationSupport.classificationUnits(for: session)
        VStack(alignment: .leading, spacing: 7) {
            Text("Classified activity")
                .font(.caption.weight(.semibold))
            ForEach(units) { unit in
                SliceClassificationUnitRow(
                    unit: unit,
                    isHighlighted: highlightedReviewItemID == "slice:\(unit.id)"
                        || !highlightedSliceIDs.isDisjoint(with: unit.sourceSliceIDs),
                    model: model
                )
            }
            let durations = WaitHistoryInsights.classificationDurations(for: session)
            let observed = units.reduce(0) { $0 + $1.totalDuration }
            if durations.total - observed >= 1 {
                Text("Unobserved · \(DisplayFormat.duration(durations.total - observed)) · Unclassified")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SliceClassificationUnitRow: View {
    let unit: WaitClassificationReviewUnit
    let isHighlighted: Bool
    @ObservedObject var model: LifecycleViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(unit.label) · \(unit.presenceState.reviewTitle)")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = unit.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(DisplayFormat.duration(unit.totalDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Menu {
                Section("Classification") {
                    classificationAction(.productive)
                    classificationAction(.distracted)
                    classificationAction(.unclassified)
                }
                if !unit.sourceSliceIDs.isEmpty {
                    Button("Reset to Automatic", systemImage: "arrow.uturn.backward") {
                        model.setSliceClassificationOverride(nil, for: unit)
                    }
                }
                Divider()
                Button("Create Rule…", systemImage: "plus.circle") {
                    model.prepareContextRule(from: unit.context)
                }
            } label: {
                HStack(spacing: 4) {
                    let appearance = ClassificationAppearance(
                        classification: unit.effectiveClassification ?? .unclassified
                    )
                    Image(systemName: appearance.symbol)
                        .foregroundStyle(appearance.tint)
                    Text(unit.effectiveClassification?.title ?? "Mixed")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Edit classification for \(unit.label)")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(unit.label), \(unit.presenceState.reviewTitle), \(DisplayFormat.spokenDuration(unit.totalDuration)), \(unit.effectiveClassification?.title ?? "mixed classification")")
    }

    private func classificationAction(_ classification: WaitSessionClassification) -> some View {
        Button {
            model.setSliceClassificationOverride(classification, for: unit)
        } label: {
            let appearance = ClassificationAppearance(classification: classification)
            Label(appearance.title, systemImage: appearance.symbol)
        }
    }
}

private struct ActivityHistoryGroupRow: View {
    let group: ActivityHistoryGroup
    @ObservedObject var model: LifecycleViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(group.displayComponents.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(2)
                if let secondaryDetail {
                    Text(secondaryDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(durationLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    model.prepareContextRule(from: group.context)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .accessibilityLabel("Create personal rule from \(group.displayComponents.joined(separator: ", "))")
                .accessibilityHint("Prefills a new local rule using this observed activity context.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var durationLabel: String {
        guard group.knownDuration > 0 else {
            return group.hasIncompleteDuration ? "open" : DisplayFormat.duration(0)
        }
        let duration = DisplayFormat.duration(group.knownDuration)
        return group.hasIncompleteDuration ? "\(duration)+" : duration
    }

    private var secondaryDetail: String? {
        var details: [String] = []
        if group.segmentCount > 1 {
            details.append("\(group.segmentCount) observed intervals")
        }
        details.append(contentsOf: UserPresenceState.allCases.compactMap { state in
            guard let duration = group.presenceDurations[state], duration >= 1 else { return nil }
            return "\(state.displayTitle) \(DisplayFormat.duration(duration))"
        })
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = group.displayComponents
        if let secondaryDetail {
            parts.append(secondaryDetail)
        }
        parts.append("duration \(durationLabel)")
        return parts.joined(separator: ", ")
    }
}

private struct AppStatusSection: View {
    @ObservedObject var model: LifecycleViewModel
    @State private var isExpanded: Bool

    init(model: LifecycleViewModel, initiallyExpanded: Bool = false) {
        _model = ObservedObject(wrappedValue: model)
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        FullWidthDisclosure(isExpanded: $isExpanded) {
            Label("App settings & status", systemImage: "gearshape")
                .font(.subheadline.weight(.medium))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .accessibilityHint("Starts Inbetween after you sign in to your Mac.")

                Text(model.launchAtLoginStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                statusRow(
                    title: "Activity detail",
                    value: model.activityMetadataStatus,
                    symbol: model.activityMetadataStatus.contains("window")
                        ? "eye"
                        : "eye.slash"
                )
                AISettingsSection(model: model)
                PersonalContextRulesSection(model: model)
                statusRow(
                    title: "Lifecycle listener",
                    value: listenerStatus,
                    symbol: listenerSymbol
                )

                if model.systemStatus != "Awake" {
                    statusRow(title: "System", value: model.systemStatus, symbol: "moon.zzz")
                }
                if model.storageStatus.contains("Could not") {
                    statusRow(title: "Saved history", value: model.storageStatus, symbol: "exclamationmark.triangle")
                }
                if model.rejectedEventCount > 0 {
                    statusRow(
                        title: "Ignored events",
                        value: "\(model.rejectedEventCount) malformed, duplicate, stale, or unrelated",
                        symbol: "checkmark.shield"
                    )
                }
                if model.notificationSmokeTestEnabled {
                    Button("Send notification test") {
                        model.sendNotificationSmokeTest()
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 8)
        }
        .accessibilityHint("Contains Launch at Login, personal context rules, privacy, and local listener status.")
        .onChange(of: model.contextRulePrefill) { prefill in
            if prefill != nil { isExpanded = true }
        }
    }

    private var listenerStatus: String {
        model.receiverStatus.hasPrefix("Listening") ? "Listening locally" : model.receiverStatus
    }

    private var listenerSymbol: String {
        model.receiverStatus.hasPrefix("Listening") ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle"
    }

    private func statusRow(title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.medium))
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

private struct AISettingsSection: View {
    @ObservedObject var model: LifecycleViewModel
    @State private var apiKey = ""
    @State private var modelName = ""
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reflection AI", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
            HStack {
                Text("API key")
                    .font(.caption)
                Spacer()
                Text(model.aiCredentialSource?.rawValue ?? "Not configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SecureField("Paste a new Featherless API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityHint("The saved key is never displayed.")
            TextField("Featherless model", text: $modelName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Remove Saved Key") {
                    feedback = model.removeSavedAIKey()
                }
                .disabled(model.aiCredentialSource != .keychain)
                Spacer()
                Button("Save AI Settings") {
                    feedback = model.saveAIConfiguration(apiKey: apiKey, model: modelName)
                    if feedback == nil { apiKey = "" }
                }
                .buttonStyle(.bordered)
            }
            Text(feedback ?? model.aiConfigurationStatus)
                .font(.caption2)
                .foregroundStyle(feedback == nil ? Color.secondary : Color.red)
            Text("Environment variables remain a development fallback. Apps opened from Finder may not inherit shell exports.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(9)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { modelName = model.configuredAIModel }
        .onChange(of: model.configuredAIModel) { modelName = $0 }
    }
}

private struct PersonalContextRulesSection: View {
    @ObservedObject var model: LifecycleViewModel
    @State private var isExpanded = false
    @State private var showsEditor = false
    @State private var scope: ContextRuleScope = .applicationName
    @State private var disposition: ContextRuleDisposition = .productive
    @State private var pattern = ""
    @State private var validationMessage: String?
    @State private var editingRuleID: UUID?
    @FocusState private var isPatternFocused: Bool

    var body: some View {
        FullWidthDisclosure(isExpanded: $isExpanded) {
            HStack {
                Label("Personal Rules", systemImage: "slider.horizontal.3")
                Spacer()
                if !model.contextRules.isEmpty {
                    Text("\(model.contextRules.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.caption.weight(.medium))
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("More-specific rules take priority. Rules and activity stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if model.contextRules.isEmpty {
                    Text("Personal rules give Inbetween stronger evidence for contexts you already know how you want classified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.contextRules) { rule in
                        contextRuleRow(rule)
                    }
                }

                if !currentContextCandidates.isEmpty {
                    Menu {
                        ForEach(currentContextCandidates) { candidate in
                            Button(candidate.displayLabel) {
                                scope = candidate.scope
                                pattern = candidate.pattern
                                editingRuleID = nil
                                showsEditor = true
                                validationMessage = nil
                                focusPatternField()
                            }
                        }
                    } label: {
                        Label("Create rule from current activity", systemImage: "scope")
                    }
                    .font(.caption)
                    .accessibilityHint("Prefills a rule from the current foreground activity.")
                }

                if showsEditor {
                    Divider()
                    Picker("Treat matching activity as", selection: $disposition) {
                        ForEach(ContextRuleDisposition.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Match by", selection: $scope) {
                        ForEach(ContextRuleScope.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("Value or text to match", text: $pattern)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Rule value or text to match")
                        .focused($isPatternFocused)
                        .onSubmit(saveRule)

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Rule error: \(validationMessage)")
                    }

                    HStack {
                        Button("Cancel") {
                            resetEditor()
                        }
                        Spacer()
                        Button(editingRuleID == nil ? "Save rule" : "Save changes", action: saveRule)
                            .buttonStyle(.borderedProminent)
                            .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Button {
                        showsEditor = true
                        editingRuleID = nil
                        validationMessage = nil
                        focusPatternField()
                    } label: {
                        Label("Add personal rule", systemImage: "plus")
                    }
                    .font(.caption)
                    .accessibilityHint("Adds a local rule for an application, website, window, project, document, or folder.")
                }

                if model.contextRuleStatus.hasPrefix("Could not") {
                    Text(model.contextRuleStatus)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 6)
        }
        .accessibilityHint("Expands local rules that mark matching activity as productive, distracting, or context-dependent.")
        .onChange(of: model.contextRulePrefill) { prefill in
            applyPrefill(prefill)
        }
        .onAppear {
            applyPrefill(model.contextRulePrefill)
        }
    }

    private func contextRuleRow(_ rule: PersonalContextRule) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.pattern)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(rule.scope.title) · \(rule.disposition.title)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(rule.scope.title) rule \(rule.pattern), \(rule.disposition.title)")

            Spacer(minLength: 4)
            Button {
                scope = rule.scope
                pattern = rule.pattern
                disposition = rule.disposition
                editingRuleID = rule.id
                validationMessage = nil
                showsEditor = true
                focusPatternField()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Edit rule \(rule.pattern)")
            .accessibilityHint("Changes this rule's match value, scope, or classification.")
            Button(role: .destructive) {
                model.deleteContextRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete rule \(rule.pattern)")
            .accessibilityHint("Removes this personal context rule.")
        }
    }

    private var currentContextCandidates: [PersonalContextRuleSuggestion] {
        guard let context = model.currentWaitSession?.currentActivitySegment?.context else {
            return []
        }
        return PersonalContextRule.suggestions(for: context)
    }

    private func saveRule() {
        switch model.saveContextRule(
            id: editingRuleID,
            scope: scope,
            pattern: pattern,
            disposition: disposition
        ) {
        case .saved:
            resetEditor()
        case .duplicate:
            validationMessage = "A rule with this same match already exists. Edit it instead."
        case .invalid:
            validationMessage = "Enter a valid value for this match type (up to \(PersonalContextRule.maximumPatternLength) characters)."
        }
    }

    private func resetEditor() {
        pattern = ""
        validationMessage = nil
        showsEditor = false
        editingRuleID = nil
    }

    private func applyPrefill(_ prefill: PersonalContextRuleSuggestion?) {
        guard let prefill else { return }
        isExpanded = true
        scope = prefill.scope
        pattern = prefill.pattern
        editingRuleID = nil
        validationMessage = nil
        showsEditor = true
        focusPatternField()
        model.clearContextRulePrefill()
    }

    private func focusPatternField() {
        Task { @MainActor in
            await Task.yield()
            isPatternFocused = true
        }
    }
}

private struct FullWidthDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let label: Label
    @ViewBuilder let content: Content
    @State private var isHovering = false

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder label: () -> Label,
        @ViewBuilder content: () -> Content
    ) {
        _isExpanded = isExpanded
        self.label = label()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    label
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, 4)
                .background(
                    isHovering ? Color.primary.opacity(0.055) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

private struct StatePresentation {
    let eyebrow: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    init(status: UserFacingWaitStatus) {
        switch status {
        case .working:
            eyebrow = "ACTIVE WAIT"
            title = "Codex is working"
            detail = "Use the time however you intended."
            symbol = "bolt.fill"
            tint = .accentColor
        case .mayNeedAttention:
            eyebrow = "POSSIBLE PERMISSION WAIT"
            title = "Codex may need you"
            detail = "A permission request may still be waiting for your response."
            symbol = "exclamationmark.circle.fill"
            tint = .orange
        case .ready:
            eyebrow = "WAIT COMPLETE"
            title = "Codex is ready"
            detail = "The last supported turn stopped."
            symbol = "checkmark.circle.fill"
            tint = .green
        case .listening:
            eyebrow = "READY"
            title = "Listening for Codex"
            detail = "A wait begins when a supported lifecycle event arrives."
            symbol = "circle.dotted"
            tint = .secondary
        }
    }
}

private struct ClassificationAppearance {
    enum Kind {
        case productive
        case distracted
        case unclassified
        case notRecorded
    }

    let kind: Kind
    let title: String
    let symbol: String
    let tint: Color
    var explanation: String

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .productive:
            title = "Productive"
            symbol = "checkmark.circle"
            tint = .green
            explanation = "This completed wait was classified as Productive using local, inspectable evidence."
        case .distracted:
            title = "Distracted"
            symbol = "pause.circle"
            tint = .orange
            explanation = "This completed wait was classified as Distracted using a local user-marked rule."
        case .unclassified:
            title = "Unclassified"
            symbol = "questionmark.circle"
            tint = .secondary
            explanation = "The available local activity metadata were not strong enough to classify this wait."
        case .notRecorded:
            title = "Not recorded"
            symbol = "minus.circle"
            tint = .secondary
            explanation = "No classification was recorded for this older completed wait."
        }
    }

    init(session: WaitSession) {
        let kind: Kind
        switch session.effectiveClassification {
        case .productive: kind = .productive
        case .distracted: kind = .distracted
        case .unclassified: kind = .unclassified
        case nil: kind = .notRecorded
        }
        self.init(kind: kind)
        explanation = session.classificationResult?.explanation ?? explanation
    }

    init(classification: WaitSessionClassification) {
        switch classification {
        case .productive: self.init(kind: .productive)
        case .distracted: self.init(kind: .distracted)
        case .unclassified: self.init(kind: .unclassified)
        }
    }
}

private enum DisplayFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        WaitDurationFormat.compact(seconds)
    }

    static func spokenDuration(_ seconds: TimeInterval) -> String {
        WaitDurationFormat.spoken(seconds)
    }
}

private extension UserPresenceState {
    var reviewTitle: String {
        switch self {
        case .active: "Active"
        case .idle: "Idle"
        case .away: "Away"
        }
    }

    var displayTitle: String {
        switch self {
        case .active: "Active"
        case .idle: "Briefly idle"
        case .away: "Away"
        }
    }

    var displaySymbol: String {
        switch self {
        case .active: "cursorarrow.motionlines"
        case .idle: "pause.circle"
        case .away: "figure.walk"
        }
    }
}
