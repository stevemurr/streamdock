import Darwin
import Foundation
import XCTest
@testable import StreamDockCore

private final class WebRequestBox: @unchecked Sendable {
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

final class WebControlServerTests: XCTestCase {
    private func roundTrip(_ request: String, port: UInt16) throws -> Data {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        ControlSocket.configure(descriptor: descriptor)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        XCTAssertEqual(inet_pton(AF_INET, "127.0.0.1", &address.sin_addr), 1)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        try ControlSocket.sendAll(Data(request.utf8), to: descriptor)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            response.append(contentsOf: buffer[0..<count])
        }
        return response
    }

    private func body(of response: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        let range = try XCTUnwrap(response.range(of: separator))
        return response[range.upperBound...]
    }

    func testServesButtonOnlyInterfaceAndDeckState() throws {
        let state = WebDeckState(
            activePage: "main",
            pages: [.init(name: "main", keys: [
                .init(position: 0, label: "Lights", icon: "sun", color: "#cc9900")
            ])]
        )
        let server = WebControlServer(stateProvider: { state }, actionHandler: { _ in .init(ok: true) })
        let port = try server.start(port: 0)
        defer { server.stop() }

        let pageResponse = try roundTrip("GET / HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n", port: port)
        let pageText = String(decoding: pageResponse, as: UTF8.self)
        XCTAssertTrue(pageText.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(pageText.contains("StreamDock buttons"))
        XCTAssertFalse(pageText.contains("Environment Secrets"))

        let stateResponse = try roundTrip("GET /api/state HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n", port: port)
        let decoded = try JSONDecoder().decode(WebDeckState.self, from: body(of: stateResponse))
        XCTAssertEqual(decoded, state)
    }

    func testPressRoutesThroughControlHandler() throws {
        let received = WebRequestBox()
        let server = WebControlServer(
            stateProvider: { .init(activePage: "main", pages: []) },
            actionHandler: { request in
                received.append(request)
                return .init(ok: true, detail: "pressed")
            }
        )
        let port = try server.start(port: 0)
        defer { server.stop() }
        let payload = #"{"position":4,"page":"main"}"#
        let request = """
        POST /api/press HTTP/1.1\r
        Host: localhost:\(port)\r
        Origin: http://localhost:\(port)\r
        Content-Type: application/json\r
        Content-Length: \(payload.utf8.count)\r
        \r
        \(payload)
        """

        let response = try roundTrip(request, port: port)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(received.all, [
            .init(command: ControlCommand.press, key: "4", page: "main", depth: 0)
        ])
    }

    func testCrossOriginPressIsRejected() throws {
        let received = WebRequestBox()
        let server = WebControlServer(
            stateProvider: { .init(activePage: "main", pages: []) },
            actionHandler: { request in received.append(request); return .init(ok: true) }
        )
        let port = try server.start(port: 0)
        defer { server.stop() }
        let payload = #"{"position":0}"#
        let request = """
        POST /api/press HTTP/1.1\r
        Host: localhost:\(port)\r
        Origin: https://example.com\r
        Content-Type: application/json\r
        Content-Length: \(payload.utf8.count)\r
        \r
        \(payload)
        """

        let response = try roundTrip(request, port: port)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 403 Forbidden"))
        XCTAssertTrue(received.all.isEmpty)
    }
}
