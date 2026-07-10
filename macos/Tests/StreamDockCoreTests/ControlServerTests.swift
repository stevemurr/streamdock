import Darwin
import Foundation
import XCTest
@testable import StreamDockCore

private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ControlRequest] = []

    func append(_ request: ControlRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var all: [ControlRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

final class ControlServerTests: XCTestCase {
    /// Unix socket paths are limited to ~104 bytes, so use the (short)
    /// per-user temporary directory rather than a nested scratch area.
    private func makeSocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sd-\(UUID().uuidString.prefix(8)).sock").path
    }

    /// Sends raw bytes to the socket and returns the raw reply line —
    /// used to poke the server with malformed input.
    private func rawRoundTrip(_ text: String, socketPath: String) throws -> Data {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw ControlSocketError.unreachable(socketPath, errno)
        }
        let payload = Array(text.utf8)
        XCTAssertEqual(send(descriptor, payload, payload.count, 0), payload.count)
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(0x0A) {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        return reply
    }

    func testPressRequestReachesHandlerAndResponseRoundTrips() throws {
        let received = RequestBox()
        let server = ControlServer { request in
            received.append(request)
            return ControlResponse(ok: true, detail: "pressed Amber on main")
        }
        let path = makeSocketPath()
        try server.start(socketPath: path)
        defer { server.stop() }

        let request = ControlRequest(command: "press", key: "Amber", page: "main", depth: 2)
        let response = try ControlClient.send(request, socketPath: path)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.detail, "pressed Amber on main")
        XCTAssertNil(response.error)
        XCTAssertEqual(received.all, [request])
    }

    func testSocketFileHasOwnerOnlyPermissions() throws {
        let server = ControlServer { _ in ControlResponse(ok: true) }
        let path = makeSocketPath()
        try server.start(socketPath: path)
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testMalformedJSONGetsOkFalseNotACrash() throws {
        let received = RequestBox()
        let server = ControlServer { request in
            received.append(request)
            return ControlResponse(ok: true)
        }
        let path = makeSocketPath()
        try server.start(socketPath: path)
        defer { server.stop() }

        let reply = try rawRoundTrip("this is not json\n", socketPath: path)
        let response = try ControlWire.decode(ControlResponse.self, from: reply)
        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.error)
        XCTAssertTrue(received.all.isEmpty)

        // The server must still be alive for well-formed requests.
        let ok = try ControlClient.send(ControlRequest(command: "status"), socketPath: path)
        XCTAssertTrue(ok.ok)
    }

    func testPressAtDepthLimitIsRefusedWithoutReachingHandler() throws {
        let received = RequestBox()
        let server = ControlServer { request in
            received.append(request)
            return ControlResponse(ok: true)
        }
        let path = makeSocketPath()
        try server.start(socketPath: path)
        defer { server.stop() }

        let request = ControlRequest(command: "press", key: "0", depth: maxPressDepth)
        let response = try ControlClient.send(request, socketPath: path)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.error?.contains("depth") == true, "error should mention depth: \(String(describing: response.error))")
        XCTAssertTrue(received.all.isEmpty)

        // One below the limit still goes through.
        let allowed = ControlRequest(command: "press", key: "0", depth: maxPressDepth - 1)
        XCTAssertTrue(try ControlClient.send(allowed, socketPath: path).ok)
        XCTAssertEqual(received.all, [allowed])
    }

    func testRestartOverStaleSocketFileWorks() throws {
        let path = makeSocketPath()
        // Simulate leftovers from a crashed instance.
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))

        let first = ControlServer { _ in ControlResponse(ok: true, detail: "first") }
        try first.start(socketPath: path)
        XCTAssertEqual(try ControlClient.send(.init(command: "status"), socketPath: path).detail, "first")
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        let second = ControlServer { _ in ControlResponse(ok: true, detail: "second") }
        try second.start(socketPath: path)
        defer { second.stop() }
        XCTAssertEqual(try ControlClient.send(.init(command: "status"), socketPath: path).detail, "second")
    }

    // MARK: - End-to-end bridges

    func testPythonModuleTalksToLiveServer() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw XCTSkip("python3 not available")
        }
        let moduleDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd-python-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try PythonBridge.install(into: moduleDirectory)
        defer { try? FileManager.default.removeItem(at: moduleDirectory) }

        let received = RequestBox()
        let server = ControlServer { request in
            received.append(request)
            switch request.command {
            case ControlCommand.status:
                return ControlResponse(ok: true, detail: "status-from-test")
            case ControlCommand.press:
                return ControlResponse(ok: true, detail: "pressed \(request.key ?? "?")")
            default:
                return .failure("boom")
            }
        }
        let path = makeSocketPath()
        try server.start(socketPath: path)
        defer { server.stop() }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import streamdock; print(streamdock.status()); print(streamdock.key(4).press())"]
        process.environment = [
            "PYTHONPATH": moduleDirectory.path,
            "STREAMDOCK_SOCKET": path,
            "STREAMDOCK_PRESS_DEPTH": "3",
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("status-from-test"), text)
        XCTAssertTrue(text.contains("pressed 4"), text)
        let press = received.all.first { $0.command == ControlCommand.press }
        XCTAssertEqual(press?.depth, 3, "python module should forward STREAMDOCK_PRESS_DEPTH")
    }

    func testBundledCLITalksToLiveServer() throws {
        // The `streamdock` executable lands next to the test bundle when the
        // whole package is built; skip when only the tests were compiled.
        let buildDirectory = Bundle(for: ControlServerTests.self).bundleURL.deletingLastPathComponent()
        let cli = buildDirectory.appendingPathComponent("streamdock")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw XCTSkip("streamdock CLI not present at \(cli.path)")
        }

        let server = ControlServer { request in
            request.command == ControlCommand.press
                ? ControlResponse(ok: true, detail: "pressed \(request.key ?? "?") at depth \(request.depth ?? -1)")
                : .failure("unexpected \(request.command)")
        }
        let path = makeSocketPath()
        try server.start(socketPath: path)
        defer { server.stop() }

        let process = Process()
        let output = Pipe()
        process.executableURL = cli
        process.arguments = ["press", "Amber", "--page", "main"]
        process.environment = ["STREAMDOCK_SOCKET": path, "STREAMDOCK_PRESS_DEPTH": "1"]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("pressed Amber at depth 1"), text)
    }
}
