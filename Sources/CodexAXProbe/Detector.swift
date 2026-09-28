import Foundation

enum State: String, Codable { case idle, working, needsUser, finished, unknown }

struct Signal: Codable, Equatable {
    let role: String
    let attribute: String
    let sha256: String
}

struct Rules: Codable {
    let scope: [Signal]
    let idle: [Signal]
    let working: [Signal]
    let needsUser: [Signal]

    func classify(_ signals: [Signal], complete: Bool) -> (State, [String]) {
        guard complete else { return (.unknown, ["incomplete_accessibility_snapshot"]) }
        guard !scope.isEmpty, scope.contains(where: signals.contains) else {
            return (.unknown, ["codex_scope_not_confirmed"])
        }
        let matches = [(State.idle, idle), (.working, working), (.needsUser, needsUser)]
            .filter { !$0.1.isEmpty && $0.1.contains(where: signals.contains) }
        guard matches.count == 1 else {
            return (.unknown, [matches.isEmpty ? "no_state_signal" : "conflicting_state_signals"])
        }
        return (matches[0].0, matches[0].1.filter(signals.contains).map {
            "\($0.role):\($0.attribute):\($0.sha256)"
        })
    }
}

struct Machine {
    private(set) var state: State = .unknown
    private var identity: String?
    private var active = false
    private var idleSince: Date?

    mutating func update(_ observed: State, identity newIdentity: String?, at time: Date) -> [State] {
        var events: [State] = []
        if identity != newIdentity {
            if state != .unknown { events.append(.unknown) }
            state = .unknown
            active = false
            idleSince = nil
            identity = newIdentity
        }
        if observed == .unknown {
            active = false // loss of evidence must never manufacture completion
            idleSince = nil
        } else if observed == .working {
            active = true
            idleSince = nil
        } else if observed == .needsUser {
            idleSince = nil
        } else if observed == .idle && active {
            if idleSince == nil { idleSince = time }
            guard time.timeIntervalSince(idleSince!) >= 2 else { return events }
            events.append(.finished)
            active = false
            idleSince = nil
        }
        if state != observed { events.append(observed); state = observed }
        return events
    }
}
