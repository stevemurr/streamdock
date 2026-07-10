import Darwin
import Foundation

public enum ControlSocketError: LocalizedError {
    case pathTooLong(String)
    case systemCall(String, Int32)
    case unreachable(String, Int32)
    case noResponse

    public var errorDescription: String? {
        switch self {
        case let .pathTooLong(path):
            "socket path is too long for a Unix socket: \(path)"
        case let .systemCall(name, code):
            "\(name) failed: \(String(cString: strerror(code)))"
        case let .unreachable(path, code):
            "could not reach StreamDock at \(path): \(String(cString: strerror(code))) — is the app running?"
        case .noResponse:
            "no response from StreamDock"
        }
    }
}

/// Low-level Unix-domain-socket helpers shared by the server and the client.
enum ControlSocket {
    static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw ControlSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        return address
    }

    static func configure(descriptor: Int32) {
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads up to the first `\n` (exclusive) or EOF, capped at 64 KiB.
    static func readLine(from descriptor: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 65536 {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(0x0A) { break }
        }
        guard !data.isEmpty else { return nil }
        if let newline = data.firstIndex(of: 0x0A) {
            data = data.prefix(upTo: newline)
        }
        return data
    }

    static func sendAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let sent = send(descriptor, base.advanced(by: offset), raw.count - offset, 0)
                guard sent > 0 else { throw ControlSocketError.systemCall("send", errno) }
                offset += sent
            }
        }
    }
}

private final class ControlResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ControlResponse?

    func set(_ response: ControlResponse) {
        lock.lock()
        value = response
        lock.unlock()
    }

    func get() -> ControlResponse? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A tiny JSON-lines-over-Unix-socket server. It owns no application logic:
/// every decoded request is handed to the injected handler. One request per
/// connection; malformed input gets an `ok:false` response instead of a crash.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let handler: Handler
    private let lock = NSLock()
    private var listenDescriptor: Int32 = -1
    private var boundPath: String?
    private var stopRequested = false
    private var loopFinished: DispatchSemaphore?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Starts listening on `socketPath`. Any stale socket file is unlinked
    /// first, so restarting over a previous instance's leftovers is safe.
    public func start(socketPath: String) throws {
        stop()
        var address = try ControlSocket.makeAddress(path: socketPath)
        unlink(socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlSocketError.systemCall("socket", errno) }
        var started = false
        defer { if !started { close(descriptor) } }

        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw ControlSocketError.systemCall("bind", errno) }
        chmod(socketPath, 0o600)
        guard Darwin.listen(descriptor, 16) == 0 else {
            unlink(socketPath)
            throw ControlSocketError.systemCall("listen", errno)
        }

        let finished = DispatchSemaphore(value: 0)
        lock.lock()
        listenDescriptor = descriptor
        boundPath = socketPath
        stopRequested = false
        loopFinished = finished
        lock.unlock()
        started = true

        let thread = Thread { [weak self] in
            self?.acceptLoop(descriptor: descriptor)
            finished.signal()
        }
        thread.name = "streamdock-control-server"
        thread.start()
    }

    /// Stops accepting, closes the listening socket, and unlinks the path.
    public func stop() {
        lock.lock()
        let descriptor = listenDescriptor
        let path = boundPath
        let finished = loopFinished
        stopRequested = true
        listenDescriptor = -1
        boundPath = nil
        loopFinished = nil
        lock.unlock()
        guard descriptor >= 0 else { return }
        _ = finished?.wait(timeout: .now() + 2)
        close(descriptor)
        if let path { unlink(path) }
    }

    private func acceptLoop(descriptor: Int32) {
        while true {
            lock.lock()
            let stopping = stopRequested
            lock.unlock()
            if stopping { return }

            var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pending, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }

            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            let handler = self.handler
            let connection = Thread {
                ControlServer.handleConnection(descriptor: client, handler: handler)
            }
            connection.name = "streamdock-control-connection"
            connection.start()
        }
    }

    private static func handleConnection(descriptor: Int32, handler: @escaping Handler) {
        defer { close(descriptor) }
        ControlSocket.configure(descriptor: descriptor)
        let response: ControlResponse
        if let line = ControlSocket.readLine(from: descriptor) {
            do {
                let request = try ControlWire.decode(ControlRequest.self, from: line)
                response = respond(to: request, handler: handler)
            } catch {
                response = .failure("malformed request: expected one JSON object per line")
            }
        } else {
            response = .failure("empty request")
        }
        if let data = try? ControlWire.encodeLine(response) {
            try? ControlSocket.sendAll(data, to: descriptor)
        }
    }

    private static func respond(to request: ControlRequest, handler: @escaping Handler) -> ControlResponse {
        if request.command == ControlCommand.press, let depth = request.depth, depth >= maxPressDepth {
            return .failure("press depth limit reached (possible macro loop)")
        }
        let box = ControlResponseBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.set(await handler(request))
            semaphore.signal()
        }
        semaphore.wait()
        return box.get() ?? .failure("handler produced no response")
    }
}

/// Client side of the control socket, used by the `streamdock` CLI and tests.
public enum ControlClient {
    public static func send(_ request: ControlRequest, socketPath: String) throws -> ControlResponse {
        var address = try ControlSocket.makeAddress(path: socketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlSocketError.systemCall("socket", errno) }
        defer { close(descriptor) }
        ControlSocket.configure(descriptor: descriptor)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ControlSocketError.unreachable(socketPath, errno) }
        try ControlSocket.sendAll(try ControlWire.encodeLine(request), to: descriptor)
        guard let line = ControlSocket.readLine(from: descriptor) else {
            throw ControlSocketError.noResponse
        }
        return try ControlWire.decode(ControlResponse.self, from: line)
    }
}
