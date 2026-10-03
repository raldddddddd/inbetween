import Foundation

public enum WaitSessionState: String, Codable, Equatable, Sendable {
    case active
    case completed
    case interrupted
    case unfinished
}

public struct WaitSessionAttentionEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let permissionMode: PermissionMode?

    public init(timestamp: Date, permissionMode: PermissionMode?) {
        self.timestamp = timestamp
        self.permissionMode = permissionMode
    }
}

/// The durable automatic decision for one exact interval of a completed wait.
/// A nil source ID identifies a genuine interval that Inbetween did not observe.
public struct ActivityClassificationSlice: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceActivitySegmentID: UUID?
    public let startedAt: Date
    public let endedAt: Date
    public let duration: TimeInterval
    public let automaticClassificationResult: WaitSessionClassificationResult
    public var manualClassificationOverride: WaitSessionClassification?
    public var classificationReviewHandled: Bool

    public init(
        id: UUID = UUID(),
        sourceActivitySegmentID: UUID?,
        startedAt: Date,
        endedAt: Date,
        duration: TimeInterval,
        automaticClassificationResult: WaitSessionClassificationResult,
        manualClassificationOverride: WaitSessionClassification? = nil,
        classificationReviewHandled: Bool = false
    ) {
        self.id = id
        self.sourceActivitySegmentID = sourceActivitySegmentID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = max(0, duration)
        self.automaticClassificationResult = automaticClassificationResult
        self.manualClassificationOverride = manualClassificationOverride
        self.classificationReviewHandled = classificationReviewHandled
    }

    public var automaticClassification: WaitSessionClassification {
        automaticClassificationResult.classification
    }

    public var effectiveClassification: WaitSessionClassification {
        manualClassificationOverride ?? automaticClassification
    }

    public var isUnobservedGap: Bool { sourceActivitySegmentID == nil }
}

public enum WaitSessionIntentionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case focus
    case learn
    case move
    case other

    public var id: Self { self }

    public var title: String {
        rawValue.capitalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "focus", "admin", "plan":
            self = .focus
        case "learn", "read":
            self = .learn
        case "move":
            self = .move
        case "other", "custom":
            self = .other
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported wait-session intention"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct WaitSessionIntention: Codable, Equatable, Sendable {
    public static let maximumCustomLabelLength = 60

    public let kind: WaitSessionIntentionKind
    public let customLabel: String?

    public init?(
        kind: WaitSessionIntentionKind,
        customLabel: String? = nil
    ) {
        if kind == .other, let customLabel {
            let normalized = customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count <= Self.maximumCustomLabelLength else { return nil }
            self.customLabel = normalized.isEmpty ? nil : normalized
        } else {
            self.customLabel = nil
        }
        self.kind = kind
    }

    public var displayName: String {
        customLabel ?? kind.title
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case customLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(WaitSessionIntentionKind.self, forKey: .kind)
        let customLabel = try container.decodeIfPresent(String.self, forKey: .customLabel)
        guard let intention = Self(kind: kind, customLabel: customLabel) else {
            throw DecodingError.dataCorruptedError(
                forKey: .customLabel,
                in: container,
                debugDescription: "Invalid wait-session intention label"
            )
        }
        self = intention
    }
}

public struct WaitSession: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let codexSessionID: String
    public let codexTurnID: String
    public let startTime: Date
    public var endTime: Date?
    public var duration: TimeInterval?
    public var state: WaitSessionState
    public let hookSource: String
    public let hookVersion: Int
    public var attentionEvents: [WaitSessionAttentionEvent]
    public var intention: WaitSessionIntention?
    public var intentionPromptHandled: Bool?
    public var activitySegments: [ActivitySegment]
    public var classificationResult: WaitSessionClassificationResult?
    /// Nil identifies persisted sessions from the legacy whole-wait model.
    public var activityClassificationSlices: [ActivityClassificationSlice]?
    /// A user correction layered over, rather than replacing, the automatic result.
    public var manualClassificationOverride: WaitSessionClassification?
    /// Prevents repeatedly asking about the same completed ambiguous wait.
    public var classificationReviewHandled: Bool?
    /// Identifies development-only synthetic records. Real and legacy sessions are nil.
    public let syntheticDataSetID: String?

    public init(
        id: UUID = UUID(),
        codexSessionID: String,
        codexTurnID: String,
        startTime: Date,
        endTime: Date? = nil,
        duration: TimeInterval? = nil,
        state: WaitSessionState = .active,
        hookSource: String = "codex-lifecycle-hooks",
        hookVersion: Int = 1,
        attentionEvents: [WaitSessionAttentionEvent] = [],
        intention: WaitSessionIntention? = nil,
        intentionPromptHandled: Bool? = nil,
        activitySegments: [ActivitySegment] = [],
        classificationResult: WaitSessionClassificationResult? = nil,
        activityClassificationSlices: [ActivityClassificationSlice]? = nil,
        manualClassificationOverride: WaitSessionClassification? = nil,
        classificationReviewHandled: Bool? = nil,
        syntheticDataSetID: String? = nil
    ) {
        self.id = id
        self.codexSessionID = codexSessionID
        self.codexTurnID = codexTurnID
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.state = state
        self.hookSource = hookSource
        self.hookVersion = hookVersion
        self.attentionEvents = attentionEvents
        self.intention = intention
        self.intentionPromptHandled = intentionPromptHandled
        self.activitySegments = activitySegments
        self.classificationResult = classificationResult
        self.activityClassificationSlices = activityClassificationSlices
        self.manualClassificationOverride = manualClassificationOverride
        self.classificationReviewHandled = classificationReviewHandled
        self.syntheticDataSetID = syntheticDataSetID
    }

    public var isUnresolved: Bool {
        state == .active || state == .unfinished
    }

    public var automaticClassification: WaitSessionClassification? {
        classificationResult?.classification
    }

    public var effectiveClassification: WaitSessionClassification? {
        manualClassificationOverride ?? automaticClassification
    }

    public var shouldRequestClassificationReview: Bool {
        guard state == .completed else { return false }
        if let activityClassificationSlices {
            return activityClassificationSlices.contains {
                !$0.isUnobservedGap
                    && $0.effectiveClassification == .unclassified
                    && $0.automaticClassificationResult.reviewSuggested
                    && !$0.classificationReviewHandled
            }
        }
        return automaticClassification == .unclassified
            && classificationResult?.reviewSuggested == true
            && classificationReviewHandled != true
    }

    public var currentActivitySegment: ActivitySegment? {
        activitySegments.last { $0.endedAt == nil }
    }

    /// The observed duration of the current semantic activity, including
    /// adjacent presence-state segments without counting unobserved gaps.
    public func currentActivityObservedDuration(at date: Date) -> TimeInterval? {
        guard let currentSegment = currentActivitySegment,
              let currentIndex = activitySegments.firstIndex(where: {
                  $0.id == currentSegment.id
              }) else {
            return nil
        }

        var observedDuration = currentSegment.elapsed(at: date)
        for segment in activitySegments[..<currentIndex].reversed() {
            guard segment.context.representsSameActivity(as: currentSegment.context) else {
                break
            }
            observedDuration += max(0, segment.duration ?? 0)
        }
        return observedDuration
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case codexSessionID
        case codexTurnID
        case startTime
        case endTime
        case duration
        case state
        case hookSource
        case hookVersion
        case attentionEvents
        case intention
        case intentionPromptHandled
        case activitySegments
        case classificationResult
        case activityClassificationSlices
        case manualClassificationOverride
        case classificationReviewHandled
        case syntheticDataSetID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        codexSessionID = try container.decode(String.self, forKey: .codexSessionID)
        codexTurnID = try container.decode(String.self, forKey: .codexTurnID)
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        state = try container.decode(WaitSessionState.self, forKey: .state)
        hookSource = try container.decode(String.self, forKey: .hookSource)
        hookVersion = try container.decode(Int.self, forKey: .hookVersion)
        attentionEvents = try container.decodeIfPresent(
            [WaitSessionAttentionEvent].self,
            forKey: .attentionEvents
        ) ?? []
        intention = try container.decodeIfPresent(WaitSessionIntention.self, forKey: .intention)
        intentionPromptHandled = try container.decodeIfPresent(
            Bool.self,
            forKey: .intentionPromptHandled
        )
        activitySegments = try container.decodeIfPresent(
            [ActivitySegment].self,
            forKey: .activitySegments
        ) ?? []
        classificationResult = try container.decodeIfPresent(
            WaitSessionClassificationResult.self,
            forKey: .classificationResult
        )
        activityClassificationSlices = try container.decodeIfPresent(
            [ActivityClassificationSlice].self,
            forKey: .activityClassificationSlices
        )
        manualClassificationOverride = try container.decodeIfPresent(
            WaitSessionClassification.self,
            forKey: .manualClassificationOverride
        )
        classificationReviewHandled = try container.decodeIfPresent(
            Bool.self,
            forKey: .classificationReviewHandled
        )
        syntheticDataSetID = try container.decodeIfPresent(
            String.self,
            forKey: .syntheticDataSetID
        )
    }
}

public enum WaitSessionNotification: Equatable, Sendable {
    case ready
    case permissionMayNeedAttention
}

public enum WaitSessionUpdate: Equatable, Sendable {
    case started(UUID)
    case resumed(UUID)
    case attentionRecorded(UUID)
    case completed(UUID)
    case interrupted(UUID)
    case ignored

    public var notification: WaitSessionNotification? {
        switch self {
        case .completed:
            return .ready
        case .started, .resumed, .attentionRecorded, .interrupted, .ignored:
            return nil
        }
    }
}

public enum ClassificationReviewUpdate: Equatable, Sendable {
    case updated(UUID)
    case unchanged
    case ignored
}

public struct WaitSessionTracker: Sendable {
    public private(set) var sessions: [WaitSession]
    public private(set) var currentSessionID: UUID?
    public let recoveredUnfinishedSessions: Bool
    private var activityCollectionStartedAt: Date?
    private var classifier: WaitSessionClassifier

    public init(
        sessions: [WaitSession] = [],
        classifier: WaitSessionClassifier = WaitSessionClassifier()
    ) {
        var recovered = false
        self.sessions = sessions.map { session in
            guard session.state == .active else { return session }
            var unfinished = session
            unfinished.state = .unfinished
            unfinished.endTime = nil
            unfinished.duration = nil
            recovered = true
            return unfinished
        }
        currentSessionID = nil
        recoveredUnfinishedSessions = recovered
        activityCollectionStartedAt = nil
        self.classifier = classifier
    }

    public var currentSession: WaitSession? {
        guard let currentSessionID else { return nil }
        return sessions.first { $0.id == currentSessionID && $0.state == .active }
    }

    public mutating func setClassificationRules(_ rules: WaitSessionClassificationRules) {
        classifier = WaitSessionClassifier(rules: rules)
    }

    public func unresolvedSession(matching event: LifecycleEvent) -> WaitSession? {
        sessions.last {
            $0.isUnresolved
                && $0.codexSessionID == event.sessionID
                && $0.codexTurnID == event.turnID
        }
    }

    /// Pauses foreground activity collection without changing Codex lifecycle state.
    /// Used when the Mac sleeps or Inbetween terminates so an activity segment never
    /// fabricates coverage for time the app could not observe.
    @discardableResult
    public mutating func suspendActivityCollection(at date: Date) -> ActivityCollectionTransition {
        guard let currentSessionID,
              activityCollectionStartedAt != nil,
              let index = sessions.firstIndex(where: {
                  $0.id == currentSessionID && $0.state == .active
              }),
              date >= latestObservedTime(for: sessions[index])
        else {
            return .ignored
        }

        closeLatestActivitySegment(forSessionAt: index, at: date)
        activityCollectionStartedAt = nil
        return .suspended(currentSessionID)
    }

    /// Restarts collection from a known observation boundary. This does not create
    /// activity by itself; a subsequent foreground observation starts a new segment.
    @discardableResult
    public mutating func resumeActivityCollection(at date: Date) -> ActivityCollectionTransition {
        guard let currentSessionID,
              activityCollectionStartedAt == nil,
              let session = sessions.first(where: {
                  $0.id == currentSessionID && $0.state == .active
              }),
              date >= latestObservedTime(for: session)
        else {
            return .ignored
        }

        activityCollectionStartedAt = date
        return .resumed(currentSessionID)
    }

    @discardableResult
    public mutating func recordActivity(_ observation: ActivityObservation) -> ActivityUpdate {
        guard let currentSessionID,
              let collectionStartedAt = activityCollectionStartedAt,
              observation.observedAt >= collectionStartedAt,
              let index = sessions.firstIndex(where: {
                  $0.id == currentSessionID && $0.state == .active
              })
        else {
            return .ignored
        }

        if let lastIndex = sessions[index].activitySegments.indices.last,
           sessions[index].activitySegments[lastIndex].endedAt == nil,
           sessions[index].activitySegments[lastIndex].startedAt >= collectionStartedAt {
            let segment = sessions[index].activitySegments[lastIndex]
            guard observation.observedAt >= segment.lastObservedAt else { return .ignored }

            if segment.context == observation.context {
                sessions[index].activitySegments[lastIndex].lastObservedAt = observation.observedAt
                return .coalesced(segment.id)
            }

            closeActivitySegment(sessionIndex: index, segmentIndex: lastIndex, at: observation.observedAt)
            let newSegment = ActivitySegment(
                waitSessionID: currentSessionID,
                context: observation.context,
                startedAt: observation.observedAt
            )
            sessions[index].activitySegments.append(newSegment)
            return .transitioned(newSegment.id)
        }

        let newSegment = ActivitySegment(
            waitSessionID: currentSessionID,
            context: observation.context,
            startedAt: observation.observedAt
        )
        sessions[index].activitySegments.append(newSegment)
        return .started(newSegment.id)
    }

    @discardableResult
    public mutating func setManualClassificationOverride(
        _ classification: WaitSessionClassification?,
        for sessionID: UUID
    ) -> ClassificationReviewUpdate {
        guard let index = sessions.firstIndex(where: {
            $0.id == sessionID
                && $0.state == .completed
                && $0.activityClassificationSlices == nil
        }) else { return .ignored }
        let changed = sessions[index].manualClassificationOverride != classification
            || sessions[index].classificationReviewHandled != true
        sessions[index].manualClassificationOverride = classification
        sessions[index].classificationReviewHandled = true
        return changed ? .updated(sessionID) : .unchanged
    }

    @discardableResult
    public mutating func markClassificationReviewHandled(for sessionID: UUID) -> ClassificationReviewUpdate {
        guard let index = sessions.firstIndex(where: {
            $0.id == sessionID
                && $0.state == .completed
                && $0.activityClassificationSlices == nil
                && $0.classificationResult != nil
        }) else { return .ignored }
        guard sessions[index].classificationReviewHandled != true else { return .unchanged }
        sessions[index].classificationReviewHandled = true
        return .updated(sessionID)
    }

    @discardableResult
    public mutating func setManualClassificationOverride(
        _ classification: WaitSessionClassification?,
        forSliceIDs sliceIDs: Set<UUID>,
        in sessionID: UUID
    ) -> ClassificationReviewUpdate {
        guard !sliceIDs.isEmpty,
              let sessionIndex = sessions.firstIndex(where: {
                  $0.id == sessionID
                      && $0.state == .completed
                      && $0.activityClassificationSlices != nil
              }),
              var slices = sessions[sessionIndex].activityClassificationSlices
        else { return .ignored }

        var matched = false
        var changed = false
        for index in slices.indices where sliceIDs.contains(slices[index].id) {
            matched = true
            let handled = classification == nil ? false : true
            changed = changed
                || slices[index].manualClassificationOverride != classification
                || slices[index].classificationReviewHandled != handled
            slices[index].manualClassificationOverride = classification
            slices[index].classificationReviewHandled = handled
        }
        guard matched else { return .ignored }
        sessions[sessionIndex].activityClassificationSlices = slices
        return changed ? .updated(sessionID) : .unchanged
    }

    @discardableResult
    public mutating func markClassificationReviewHandled(
        forSliceIDs sliceIDs: Set<UUID>,
        in sessionID: UUID
    ) -> ClassificationReviewUpdate {
        guard !sliceIDs.isEmpty,
              let sessionIndex = sessions.firstIndex(where: {
                  $0.id == sessionID
                      && $0.state == .completed
                      && $0.activityClassificationSlices != nil
              }),
              var slices = sessions[sessionIndex].activityClassificationSlices
        else { return .ignored }

        var matched = false
        var changed = false
        for index in slices.indices where sliceIDs.contains(slices[index].id) {
            matched = true
            changed = changed || !slices[index].classificationReviewHandled
            slices[index].classificationReviewHandled = true
        }
        guard matched else { return .ignored }
        sessions[sessionIndex].activityClassificationSlices = slices
        return changed ? .updated(sessionID) : .unchanged
    }

    @discardableResult
    public mutating func apply(_ event: LifecycleEvent) -> WaitSessionUpdate {
        switch event.name {
        case .userPromptSubmit:
            return startSession(for: event)
        case .permissionRequest:
            return recordAttention(for: event)
        case .stop:
            return finishSession(for: event, as: .completed)
        case .interrupt:
            return finishSession(for: event, as: .interrupted)
        }
    }

    private mutating func startSession(for event: LifecycleEvent) -> WaitSessionUpdate {
        if let existingIndex = unresolvedIndex(matching: event) {
            guard event.date >= sessions[existingIndex].startTime else { return .ignored }
            let isContinuingCurrentCollection = currentSessionID == sessions[existingIndex].id
                && activityCollectionStartedAt != nil
            markOtherActiveSessionsUnfinished(except: sessions[existingIndex].id)
            sessions[existingIndex].state = .active
            currentSessionID = sessions[existingIndex].id
            if !isContinuingCurrentCollection {
                activityCollectionStartedAt = event.date
            }
            return .resumed(sessions[existingIndex].id)
        }

        markOtherActiveSessionsUnfinished(except: nil)
        let session = WaitSession(
            codexSessionID: event.sessionID,
            codexTurnID: event.turnID,
            startTime: event.date
        )
        sessions.append(session)
        currentSessionID = session.id
        activityCollectionStartedAt = event.date
        return .started(session.id)
    }

    private mutating func recordAttention(for event: LifecycleEvent) -> WaitSessionUpdate {
        guard let index = unresolvedIndex(matching: event),
              event.date >= latestObservedTime(for: sessions[index]),
              !sessions[index].attentionEvents.contains(where: { $0.timestamp == event.date })
        else {
            return .ignored
        }

        markOtherActiveSessionsUnfinished(except: sessions[index].id)
        sessions[index].state = .active
        sessions[index].attentionEvents.append(
            WaitSessionAttentionEvent(timestamp: event.date, permissionMode: event.permissionMode)
        )
        currentSessionID = sessions[index].id
        if activityCollectionStartedAt == nil {
            activityCollectionStartedAt = event.date
        }
        return .attentionRecorded(sessions[index].id)
    }

    private mutating func finishSession(
        for event: LifecycleEvent,
        as finalState: WaitSessionState
    ) -> WaitSessionUpdate {
        guard let index = unresolvedIndex(matching: event),
              event.date >= latestObservedTime(for: sessions[index])
        else {
            return .ignored
        }

        sessions[index].endTime = event.date
        sessions[index].duration = event.date.timeIntervalSince(sessions[index].startTime)
        closeLatestActivitySegment(forSessionAt: index, at: event.date)
        sessions[index].state = finalState
        if finalState == .completed {
            let slices = classifier.classificationSlices(for: sessions[index])
            sessions[index].activityClassificationSlices = slices
            sessions[index].classificationResult = classifier.summary(for: slices)
        }
        if currentSessionID == sessions[index].id {
            currentSessionID = nil
            activityCollectionStartedAt = nil
        }

        if finalState == .completed {
            return .completed(sessions[index].id)
        }
        return .interrupted(sessions[index].id)
    }

    private func unresolvedIndex(matching event: LifecycleEvent) -> Int? {
        sessions.indices.last {
            sessions[$0].isUnresolved
                && sessions[$0].codexSessionID == event.sessionID
                && sessions[$0].codexTurnID == event.turnID
        }
    }

    private func latestObservedTime(for session: WaitSession) -> Date {
        let latestAttention = session.attentionEvents.reduce(session.startTime) { latest, attention in
            max(latest, attention.timestamp)
        }
        return session.activitySegments.reduce(latestAttention) { latest, segment in
            max(latest, segment.lastObservedAt)
        }
    }

    private mutating func markOtherActiveSessionsUnfinished(except retainedID: UUID?) {
        for index in sessions.indices
        where sessions[index].state == .active && sessions[index].id != retainedID {
            sessions[index].state = .unfinished
            sessions[index].endTime = nil
            sessions[index].duration = nil
        }
        if currentSessionID != retainedID {
            currentSessionID = nil
            activityCollectionStartedAt = nil
        }
    }

    private mutating func closeLatestActivitySegment(forSessionAt sessionIndex: Int, at date: Date) {
        guard let activityCollectionStartedAt,
              let segmentIndex = sessions[sessionIndex].activitySegments.indices.last,
              sessions[sessionIndex].activitySegments[segmentIndex].endedAt == nil,
              sessions[sessionIndex].activitySegments[segmentIndex].startedAt
                >= activityCollectionStartedAt
        else {
            return
        }
        closeActivitySegment(sessionIndex: sessionIndex, segmentIndex: segmentIndex, at: date)
    }

    private mutating func closeActivitySegment(
        sessionIndex: Int,
        segmentIndex: Int,
        at date: Date
    ) {
        let startedAt = sessions[sessionIndex].activitySegments[segmentIndex].startedAt
        guard date >= startedAt else { return }
        sessions[sessionIndex].activitySegments[segmentIndex].endedAt = date
        sessions[sessionIndex].activitySegments[segmentIndex].duration = date.timeIntervalSince(startedAt)
        sessions[sessionIndex].activitySegments[segmentIndex].lastObservedAt = max(
            sessions[sessionIndex].activitySegments[segmentIndex].lastObservedAt,
            date
        )
    }
}
