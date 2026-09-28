import Darwin
import Foundation

private final class EventReceiverOwnershipRegistry: @unchecked Sendable {
    static let shared = EventReceiverOwnershipRegistry()

    private let lock = NSLock()
    private var paths: Set<String> = []

    func claim(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.insert(path).inserted
    }

    func release(_ path: String) {
        lock.lock()
        paths.remove(path)
        lock.unlock()
    }
}

public enum EventReceiverError: Error, Equatable {
    case invalidPath
    case alreadyRunning
    case socketCreation(Int32)
    case bind(Int32)
    case permissions(Int32)
}

public final class UnixDatagramEventReceiver: @unchecked Sendable {
    public static let defaultSocketPath = "/tmp/inbetween-lifecycle.sock"

    private let socketPath: String
    private let queue: DispatchQueue
    private let handler: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var fileDescriptor: Int32 = -1
    private var ownershipDescriptor: Int32 = -1
    private var source: DispatchSourceRead?

    public init(
        socketPath: String = UnixDatagramEventReceiver.defaultSocketPath,
        queue: DispatchQueue = DispatchQueue(label: "com.inbetween.lifecycle-events"),
        handler: @escaping @Sendable (Data) -> Void
    ) {
        self.socketPath = socketPath
        self.queue = queue
        self.handler = handler
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fileDescriptor == -1 else { return }
        guard EventReceiverOwnershipRegistry.shared.claim(socketPath) else {
            throw EventReceiverError.alreadyRunning
        }

        let ownershipPath = socketPath + ".lock"
        let owner = Darwin.open(ownershipPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard owner >= 0 else {
            EventReceiverOwnershipRegistry.shared.release(socketPath)
            throw EventReceiverError.socketCreation(errno)
        }
        guard Darwin.lockf(owner, F_TLOCK, 0) == 0 else {
            Darwin.close(owner)
            EventReceiverOwnershipRegistry.shared.release(socketPath)
            throw EventReceiverError.alreadyRunning
        }

        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            Darwin.lockf(owner, F_ULOCK, 0)
            Darwin.close(owner)
            EventReceiverOwnershipRegistry.shared.release(socketPath)
            throw EventReceiverError.invalidPath
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            let code = errno
            Darwin.lockf(owner, F_ULOCK, 0)
            Darwin.close(owner)
            EventReceiverOwnershipRegistry.shared.release(socketPath)
            throw EventReceiverError.socketCreation(code)
        }

        Darwin.unlink(socketPath)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            Darwin.lockf(owner, F_ULOCK, 0)
            Darwin.close(owner)
            EventReceiverOwnershipRegistry.shared.release(socketPath)
            throw EventReceiverError.bind(code)
        }
        guard Darwin.chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            Darwin.unlink(socketPath)
            Darwin.lockf(owner, F_ULOCK, 0)
            Darwin.close(owner)
            EventReceiverOwnershipRegistry.shared.release(socketPath)
            throw EventReceiverError.permissions(code)
        }

        fileDescriptor = descriptor
        ownershipDescriptor = owner
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { [weak self] in self?.receiveAvailableDatagrams() }
        readSource.setCancelHandler { [socketPath] in
            Darwin.close(descriptor)
            Darwin.unlink(socketPath)
            Darwin.lockf(owner, F_ULOCK, 0)
            Darwin.close(owner)
            EventReceiverOwnershipRegistry.shared.release(socketPath)
        }
        source = readSource
        readSource.resume()
    }

    public func stop() {
        lock.lock()
        let readSource = source
        source = nil
        fileDescriptor = -1
        ownershipDescriptor = -1
        lock.unlock()
        readSource?.cancel()
    }

    deinit { stop() }

    private func receiveAvailableDatagrams() {
        lock.lock()
        let descriptor = fileDescriptor
        lock.unlock()
        guard descriptor >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 8_192)
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return }
        handler(Data(buffer.prefix(Int(count))))
    }
}
