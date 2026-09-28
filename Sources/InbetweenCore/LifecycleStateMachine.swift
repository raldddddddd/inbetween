import Foundation

public enum ApplicationLifecycleState: String, Equatable, Sendable {
    case idle
    case active
    case attention
    case ready
}

public struct ActiveTurn: Equatable, Sendable {
    public let sessionID: String
    public let turnID: String
    public let startedAt: Date
    public var lastEventAt: Date
}

public struct LifecycleSnapshot: Equatable, Sendable {
    public var state: ApplicationLifecycleState = .idle
    public var activeTurn: ActiveTurn?
    public var mostRecentAttention: LifecycleEvent?
    public var lastEvent: LifecycleEvent?

    public init() {}
}

public enum EventDisposition: Equatable, Sendable {
    case accepted
    case duplicate
    case stale
    case outOfOrder
    case unrelatedTurn
}

public struct LifecycleStateMachine: Sendable {
    public private(set) var snapshot = LifecycleSnapshot()

    private var seen = Set<EventIdentity>()
    private var seenOrder: [EventIdentity] = []
    private let maximumEventAge: TimeInterval
    private let futureTolerance: TimeInterval
    private let maximumRememberedEvents: Int

    public init(
        maximumEventAge: TimeInterval = 300,
        futureTolerance: TimeInterval = 30,
        maximumRememberedEvents: Int = 256
    ) {
        self.maximumEventAge = maximumEventAge
        self.futureTolerance = futureTolerance
        self.maximumRememberedEvents = maximumRememberedEvents
    }

    public mutating func restoreActiveTurn(
        sessionID: String,
        turnID: String,
        startedAt: Date,
        lastEventAt: Date
    ) {
        guard snapshot.activeTurn == nil else { return }
        snapshot.activeTurn = ActiveTurn(
            sessionID: sessionID,
            turnID: turnID,
            startedAt: startedAt,
            lastEventAt: lastEventAt
        )
        snapshot.state = .active
    }

    @discardableResult
    public mutating func apply(_ event: LifecycleEvent, now: Date = Date()) -> EventDisposition {
        let identity = EventIdentity(event)
        if seen.contains(identity) { return .duplicate }

        let age = now.timeIntervalSince(event.date)
        guard age <= maximumEventAge, age >= -futureTolerance else { return .stale }

        if let lastEvent = snapshot.lastEvent, event.observedAt < lastEvent.observedAt {
            return .outOfOrder
        }

        let disposition: EventDisposition
        switch event.name {
        case .userPromptSubmit:
            if matchesActiveTurn(event), var activeTurn = snapshot.activeTurn {
                activeTurn.lastEventAt = event.date
                snapshot.activeTurn = activeTurn
            } else {
                snapshot.activeTurn = ActiveTurn(
                    sessionID: event.sessionID,
                    turnID: event.turnID,
                    startedAt: event.date,
                    lastEventAt: event.date
                )
            }
            snapshot.state = .active
            snapshot.lastEvent = event
            disposition = .accepted

        case .permissionRequest:
            guard matchesActiveTurn(event) else { return .unrelatedTurn }
            snapshot.activeTurn?.lastEventAt = event.date
            snapshot.mostRecentAttention = event
            snapshot.state = .attention
            snapshot.lastEvent = event
            disposition = .accepted

        case .stop, .interrupt:
            guard matchesActiveTurn(event) else { return .unrelatedTurn }
            snapshot.activeTurn = nil
            snapshot.state = .ready
            snapshot.lastEvent = event
            disposition = .accepted
        }

        remember(identity)
        return disposition
    }

    private func matchesActiveTurn(_ event: LifecycleEvent) -> Bool {
        snapshot.activeTurn?.sessionID == event.sessionID &&
            snapshot.activeTurn?.turnID == event.turnID
    }

    private mutating func remember(_ identity: EventIdentity) {
        seen.insert(identity)
        seenOrder.append(identity)
        while seenOrder.count > maximumRememberedEvents {
            seen.remove(seenOrder.removeFirst())
        }
    }
}

private struct EventIdentity: Hashable, Sendable {
    let name: LifecycleEventName
    let sessionID: String
    let turnID: String
    let observedAt: TimeInterval

    init(_ event: LifecycleEvent) {
        name = event.name
        sessionID = event.sessionID
        turnID = event.turnID
        observedAt = event.observedAt
    }
}
