import Foundation
import Testing
@testable import InbetweenCore

struct LifecycleStateMachineTests {
    private let now = Date(timeIntervalSince1970: 1_100)

    @Test func normalTurnBecomesActiveThenReady() {
        var machine = LifecycleStateMachine()
        let start = event(.userPromptSubmit, time: 1_000)
        let stop = event(.stop, time: 1_010)

        #expect(machine.apply(start, now: now) == .accepted)
        #expect(machine.snapshot.state == .active)
        #expect(machine.snapshot.activeTurn?.startedAt == start.date)
        #expect(machine.apply(stop, now: now) == .accepted)
        #expect(machine.snapshot.state == .ready)
        #expect(machine.snapshot.activeTurn == nil)
    }

    @Test func permissionIsAttentionAndLaterSameTurnProgressClearsIt() {
        var machine = LifecycleStateMachine()
        #expect(machine.apply(event(.userPromptSubmit, time: 1_000), now: now) == .accepted)
        #expect(machine.apply(event(.permissionRequest, time: 1_001), now: now) == .accepted)
        #expect(machine.snapshot.state == .attention)

        #expect(machine.apply(event(.userPromptSubmit, time: 1_002), now: now) == .accepted)
        #expect(machine.snapshot.state == .active)
        #expect(machine.snapshot.activeTurn?.startedAt == Date(timeIntervalSince1970: 1_000))
        #expect(machine.snapshot.mostRecentAttention?.name == .permissionRequest)
    }

    @Test func interruptTerminatesMatchingTurn() {
        var machine = LifecycleStateMachine()
        machine.apply(event(.userPromptSubmit, time: 1_000), now: now)

        #expect(machine.apply(event(.interrupt, time: 1_002), now: now) == .accepted)
        #expect(machine.snapshot.state == .ready)
        #expect(machine.snapshot.activeTurn == nil)
    }

    @Test func malformedSequencesAreConservative() {
        var machine = LifecycleStateMachine()
        let start = event(.userPromptSubmit, time: 1_000)
        #expect(machine.apply(start, now: now) == .accepted)
        #expect(machine.apply(start, now: now) == .duplicate)
        #expect(machine.apply(event(.stop, turn: "other", time: 1_001), now: now) == .unrelatedTurn)
        #expect(machine.apply(event(.permissionRequest, time: 999), now: now) == .outOfOrder)
        #expect(machine.snapshot.state == .active)
    }

    @Test func staleAndFutureEventsAreIgnored() {
        var machine = LifecycleStateMachine(maximumEventAge: 30, futureTolerance: 5)

        #expect(machine.apply(event(.userPromptSubmit, time: 1_000), now: Date(timeIntervalSince1970: 1_100)) == .stale)
        #expect(machine.apply(event(.userPromptSubmit, time: 1_110), now: Date(timeIntervalSince1970: 1_100)) == .stale)
        #expect(machine.snapshot.state == .idle)
    }

    private func event(
        _ name: LifecycleEventName,
        session: String = "session-1",
        turn: String = "turn-1",
        time: TimeInterval
    ) -> LifecycleEvent {
        LifecycleEvent(name: name, sessionID: session, turnID: turn, observedAt: time)
    }
}
