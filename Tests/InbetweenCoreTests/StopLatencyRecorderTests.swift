import Foundation
import Testing
@testable import InbetweenCore

struct StopLatencyRecorderTests {
    @Test func recordsOnlySafeStopCorrelationAndTimingMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-latency-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("latency.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recorder = StopLatencyRecorder(fileURL: fileURL)

        recorder.record(
            .notificationObserved,
            sessionID: "session-1",
            turnID: "turn-1",
            wallTime: 10,
            monotonicNanoseconds: 20,
            delivered: true,
            pending: false
        )

        let line = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(line.contains(#""stage":"notification_observed""#))
        #expect(line.contains(#""sessionID":"session-1""#))
        #expect(line.contains(#""turnID":"turn-1""#))
        #expect(line.contains(#""delivered":true"#))
        #expect(!line.contains("prompt"))
        #expect(!line.contains("title"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    }
}
