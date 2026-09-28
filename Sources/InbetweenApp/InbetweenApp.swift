import AppKit
import InbetweenCore
import SwiftUI

enum ContextRuleSaveResult: Equatable {
    case saved
    case invalid
    case duplicate
}

@main
struct InbetweenApp: App {
    @StateObject private var model = LifecycleViewModel()

    var body: some Scene {
        MenuBarExtra("Inbetween", systemImage: model.menuBarSymbol) {
            LifecycleStatusView(model: model)
                .frame(width: 380, height: 580)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class LifecycleViewModel: ObservableObject {
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

    private var stateMachine = LifecycleStateMachine()
    private var sessionTracker: WaitSessionTracker
    private let sessionStore: WaitSessionStore
    private let contextRuleStore: ContextRuleStore
    private let latencyRecorder: StopLatencyRecorder
    private let lifecycleDiagnosticRecorder: LifecycleDiagnosticRecorder
    private let notificationService: LocalNotificationService
    private let launchAtLoginController: LaunchAtLoginController
    private let parser = LifecycleEventParser()
    private var receiver: UnixDatagramEventReceiver?
    private var activityMonitor: ForegroundActivityMonitor!
    private var systemLifecycleMonitor: SystemLifecycleMonitor!
    private var permissionAttentionTracker = DelayedPermissionAttentionTracker()
    private var permissionAttentionTask: Task<Void, Never>?

    init() {
        let latencyRecorder = StopLatencyRecorder()
        self.latencyRecorder = latencyRecorder
        lifecycleDiagnosticRecorder = LifecycleDiagnosticRecorder()
        notificationService = LocalNotificationService(latencyRecorder: latencyRecorder)
        launchAtLoginController = LaunchAtLoginController()

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

    var pendingClassificationReviews: [WaitSession] {
        WaitPresentationSupport.pendingReviews(from: sessions)
    }

    var pendingClassificationReviewUnits: [WaitClassificationReviewUnit] {
        WaitPresentationSupport.pendingReviewUnits(from: sessions)
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
    }

    func clearContextRulePrefill() {
        contextRulePrefill = nil
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

private struct LifecycleStatusView: View {
    @ObservedObject var model: LifecycleViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.userFacingWaitStatus == .listening {
                    CompactListeningStatus()
                } else {
                    StatusHero(
                        status: model.userFacingWaitStatus,
                        duration: model.currentWaitSession?.startTime
                    )
                }

                if let session = model.currentWaitSession {
                    CurrentWaitCard(session: session, systemStatus: model.systemStatus)
                }

                if let unit = model.pendingClassificationReviewUnits.first {
                    SliceNeedsReviewSection(
                        unit: unit,
                        count: model.pendingClassificationReviewUnits.count
                            + model.pendingClassificationReviews.count,
                        model: model
                    )
                } else if let session = model.pendingClassificationReviews.first {
                    LegacyNeedsReviewSection(
                        session: session,
                        count: model.pendingClassificationReviews.count,
                        model: model
                    )
                }

                Divider()

                LastSevenDaysSection(
                    insights: model.historyInsights,
                    sessions: model.sessions
                )

                Divider()

                HistorySection(
                    sessions: model.completedHistory,
                    model: model
                )

                Divider()

                AppStatusSection(model: model)

                Divider()

                Button(role: .destructive) {
                    model.quit()
                } label: {
                    Label("Quit Inbetween", systemImage: "power")
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Stops Inbetween and preserves any active wait conservatively.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshReliabilityStatus()
        }
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
        max(1, days.map(\.summary.totalCompletedDuration).max() ?? 0)
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
                ClassificationSummaryButton(
                    classification: .productive,
                    duration: summary.productiveDuration,
                    isSelected: selectedClassification == .productive,
                    action: { toggle(.productive) }
                )
                ClassificationSummaryButton(
                    classification: .distracted,
                    duration: summary.distractedDuration,
                    isSelected: selectedClassification == .distracted,
                    action: { toggle(.distracted) }
                )
                ClassificationSummaryButton(
                    classification: .unclassified,
                    duration: summary.unclassifiedDuration,
                    isSelected: selectedClassification == .unclassified,
                    action: { toggle(.unclassified) }
                )
                if summary.notRecordedDuration > 0 {
                    SummaryDurationRow(
                        title: "Not recorded",
                        duration: summary.notRecordedDuration,
                        appearance: .notRecorded
                    )
                }
            }

            if summary.notRecordedDuration > 0 {
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

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(days) { day in
                    DayStackedBar(
                        period: day,
                        maximumDailyDuration: maximumDailyDuration,
                        isToday: Calendar.current.isDateInToday(day.startDate)
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last 7 days of Codex wait time")
    }

    private func toggle(_ classification: WaitSessionClassification) {
        selectedClassification = selectedClassification == classification ? nil : classification
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
            duration("Productive", summary.productiveDuration)
            duration("Distracted", summary.distractedDuration)
            duration("Unclassified", summary.unclassifiedDuration)
            if summary.notRecordedDuration > 0 { duration("Not recorded", summary.notRecordedDuration) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func duration(_ label: String, _ value: TimeInterval) -> some View {
        Text("\(label) \(DisplayFormat.duration(value))")
    }
}

private struct SliceNeedsReviewSection: View {
    let unit: WaitClassificationReviewUnit
    let count: Int
    @ObservedObject var model: LifecycleViewModel

    var body: some View {
        SectionCard {
            HStack {
                Label("Needs Review\(count > 1 ? " · \(count)" : "")", systemImage: "questionmark.circle")
                    .font(.headline)
                Spacer()
                Text(DisplayFormat.duration(unit.totalDuration))
                    .font(.subheadline.monospacedDigit())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(unit.label) · \(unit.presenceState.reviewTitle)")
                    .font(.subheadline.weight(.medium))
                if let subtitle = unit.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(unit.presenceState.reviewTitle) \(DisplayFormat.duration(unit.totalDuration))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(unit.automaticReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Productive") {
                    model.setSliceClassificationOverride(.productive, for: unit)
                }
                .buttonStyle(.borderedProminent)
                Button("Distracted") {
                    model.setSliceClassificationOverride(.distracted, for: unit)
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 4)
                Button("Leave unclassified") {
                    model.markSliceReviewHandled(for: unit)
                }
                .buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs Review. \(unit.label), \(unit.presenceState.reviewTitle), \(DisplayFormat.spokenDuration(unit.totalDuration)). \(count) review \(count == 1 ? "item" : "items") remaining.")
    }
}

private struct LegacyNeedsReviewSection: View {
    let session: WaitSession
    let count: Int
    @ObservedObject var model: LifecycleViewModel

    var body: some View {
        SectionCard {
            HStack {
                Label("Needs Review\(count > 1 ? " · \(count)" : "")", systemImage: "questionmark.circle")
                    .font(.headline)
                Spacer()
                Text(session.duration.map(DisplayFormat.duration) ?? "—")
                    .font(.subheadline.monospacedDigit())
            }
            Text(WaitPresentationSupport.reviewExplanation(for: session))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Productive") {
                    model.setManualClassificationOverride(.productive, for: session.id)
                }
                .buttonStyle(.borderedProminent)
                Button("Distracted") { model.setManualClassificationOverride(.distracted, for: session.id) }
                    .buttonStyle(.bordered)
                Spacer(minLength: 4)
                Button("Leave unclassified") {
                    model.markClassificationReviewHandled(for: session.id)
                }
                .buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Needs Review. \(count) \(count == 1 ? "wait" : "waits") remaining.")
    }
}

private struct HistorySection: View {
    let sessions: [WaitSession]
    @ObservedObject var model: LifecycleViewModel
    @State private var showsOlderHistory = false

    private var visibleSessions: ArraySlice<WaitSession> {
        sessions.prefix(showsOlderHistory ? sessions.count : 5)
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
                        SessionHistoryRow(session: session, model: model)
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
                SliceClassificationUnitRow(unit: unit, model: model)
            }
            let durations = WaitHistoryInsights.classificationDurations(for: session)
            let observed = units.reduce(0) { $0 + $1.totalDuration }
            if durations.total > observed {
                Text("Unobserved · \(DisplayFormat.duration(durations.total - observed)) · Unclassified")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SliceClassificationUnitRow: View {
    let unit: WaitClassificationReviewUnit
    @ObservedObject var model: LifecycleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(unit.label) · \(unit.presenceState.reviewTitle)")
                        .font(.caption.weight(.medium))
                    if let subtitle = unit.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text(DisplayFormat.duration(unit.totalDuration))
                    .font(.caption.monospacedDigit())
                Text(unit.effectiveClassification?.title ?? "Mixed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("Productive") { model.setSliceClassificationOverride(.productive, for: unit) }
                Button("Distracted") { model.setSliceClassificationOverride(.distracted, for: unit) }
                Button("Unclassified") { model.setSliceClassificationOverride(.unclassified, for: unit) }
                if unit.sourceSliceIDs.count > 0 {
                    Button("Reset") { model.setSliceClassificationOverride(nil, for: unit) }
                        .buttonStyle(.borderless)
                }
                Spacer(minLength: 2)
                Button("Create rule") { model.prepareContextRule(from: unit.context) }
                    .buttonStyle(.borderless)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(unit.label), \(unit.presenceState.reviewTitle), \(DisplayFormat.spokenDuration(unit.totalDuration)), \(unit.effectiveClassification?.title ?? "mixed classification")")
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
                Button("Create rule") {
                    model.prepareContextRule(from: group.context)
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
            guard let duration = group.presenceDurations[state], duration > 0 else { return nil }
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
    @State private var isExpanded = false

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

private struct PersonalContextRulesSection: View {
    @ObservedObject var model: LifecycleViewModel
    @State private var isExpanded = false
    @State private var showsEditor = false
    @State private var scope: ContextRuleScope = .applicationName
    @State private var disposition: ContextRuleDisposition = .productive
    @State private var pattern = ""
    @State private var validationMessage: String?
    @State private var editingRuleID: UUID?

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
        model.clearContextRulePrefill()
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
