import Darwin
import Foundation
import XCTest
@testable import InbetweenCore

final class UnixDatagramEventReceiverTests: XCTestCase {
    func testReceivesOneDatagramWithoutPolling() throws {
        let path = "/tmp/inbetween-receiver-test-\(UUID().uuidString).sock"
        let received = expectation(description: "datagram received")
        let payload = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let receiver = UnixDatagramEventReceiver(socketPath: path) { data in
            XCTAssertEqual(data, payload)
            received.fulfill()
        }
        try receiver.start()
        defer { receiver.stop() }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }

        let sent = payload.withUnsafeBytes { payloadPointer in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(
                        descriptor,
                        payloadPointer.baseAddress,
                        payload.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
        }
        XCTAssertEqual(sent, payload.count)
        wait(for: [received], timeout: 1)
    }

    func testStartingSameReceiverTwiceStillDeliversOnce() throws {
        let path = "/tmp/inbetween-receiver-idempotence-test-\(UUID().uuidString).sock"
        let received = expectation(description: "one datagram received")
        received.expectedFulfillmentCount = 1
        received.assertForOverFulfill = true
        let payload = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let receiver = UnixDatagramEventReceiver(socketPath: path) { data in
            XCTAssertEqual(data, payload)
            received.fulfill()
        }
        try receiver.start()
        try receiver.start()
        defer { receiver.stop() }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }

        let sent = payload.withUnsafeBytes { payloadPointer in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(
                        descriptor,
                        payloadPointer.baseAddress,
                        payload.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
        }
        XCTAssertEqual(sent, payload.count)
        wait(for: [received], timeout: 1)
    }

    func testSecondReceiverCannotClaimSameListenerPath() throws {
        let path = "/tmp/inbetween-receiver-ownership-test-\(UUID().uuidString).sock"
        let first = UnixDatagramEventReceiver(socketPath: path) { _ in }
        let second = UnixDatagramEventReceiver(socketPath: path) { _ in }
        try first.start()
        defer { first.stop() }

        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? EventReceiverError, .alreadyRunning)
        }
    }
}
