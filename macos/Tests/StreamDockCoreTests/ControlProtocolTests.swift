import Foundation
import XCTest
@testable import StreamDockCore

final class ControlProtocolTests: XCTestCase {
    // MARK: - Wire round-trips

    func testRequestRoundTripsThroughJSONLines() throws {
        let request = ControlRequest(command: "press", key: "Amber", page: "main", depth: 3)
        let line = try ControlWire.encodeLine(request)
        XCTAssertEqual(line.last, 0x0A)
        let decoded = try ControlWire.decode(ControlRequest.self, from: line.dropLast())
        XCTAssertEqual(decoded, request)
    }

    func testResponseRoundTripsThroughJSONLines() throws {
        let response = ControlResponse(
            ok: true,
            detail: "2 keys",
            keys: [
                ControlKeyInfo(position: 0, label: "Term", page: "main"),
                ControlKeyInfo(position: 4, label: "Amber", page: "main"),
            ]
        )
        let line = try ControlWire.encodeLine(response)
        let decoded = try ControlWire.decode(ControlResponse.self, from: line)
        XCTAssertEqual(decoded, response)
    }

    func testRequestDecodesWithMissingOptionalFields() throws {
        let decoded = try ControlWire.decode(
            ControlRequest.self,
            from: Data(#"{"command":"status"}"#.utf8)
        )
        XCTAssertEqual(decoded.command, "status")
        XCTAssertNil(decoded.key)
        XCTAssertNil(decoded.page)
        XCTAssertNil(decoded.depth)
    }

    // MARK: - Key resolution

    private var configuration: DeckConfiguration {
        DeckConfiguration(pages: [
            DeckPage(name: "main", keys: [
                KeyConfiguration(position: 0, label: "Term"),
                KeyConfiguration(position: 4, label: "Amber"),
            ]),
            DeckPage(name: "media", keys: [
                KeyConfiguration(position: 0, label: "Play"),
            ]),
        ])
    }

    func testResolveByPositionOnFirstPageByDefault() {
        let match = ControlKeyResolver.resolve(reference: "4", in: configuration)
        XCTAssertEqual(match?.key.label, "Amber")
        XCTAssertEqual(match?.page.name, "main")
    }

    func testResolveByLabelIsCaseInsensitive() {
        let match = ControlKeyResolver.resolve(reference: "aMbEr", in: configuration)
        XCTAssertEqual(match?.key.position, 4)
    }

    func testResolveHonorsExplicitPageCaseInsensitively() {
        let match = ControlKeyResolver.resolve(reference: "play", page: "MEDIA", in: configuration)
        XCTAssertEqual(match?.key.position, 0)
        XCTAssertEqual(match?.page.name, "media")
    }

    func testResolveDefaultsToActivePage() {
        let match = ControlKeyResolver.resolve(reference: "0", activePage: "media", in: configuration)
        XCTAssertEqual(match?.key.label, "Play")
        XCTAssertEqual(match?.page.name, "media")
    }

    func testResolveFallsBackToFirstPageWhenActivePageIsGone() {
        let match = ControlKeyResolver.resolve(reference: "0", activePage: "deleted", in: configuration)
        XCTAssertEqual(match?.key.label, "Term")
    }

    func testResolveMissesReturnNil() {
        XCTAssertNil(ControlKeyResolver.resolve(reference: "nope", in: configuration))
        XCTAssertNil(ControlKeyResolver.resolve(reference: "9", in: configuration))
        XCTAssertNil(ControlKeyResolver.resolve(reference: "Play", in: configuration))
        XCTAssertNil(ControlKeyResolver.resolve(reference: "Amber", page: "missing", in: configuration))
        XCTAssertNil(ControlKeyResolver.resolve(reference: "  ", in: configuration))
    }

    // MARK: - CLI request building

    func testCLIBuildsPressRequestWithPage() throws {
        let request = try ControlCLI.makeRequest(arguments: ["press", "Amber", "--page", "main"], depth: 2)
        XCTAssertEqual(request, ControlRequest(command: "press", key: "Amber", page: "main", depth: 2))
    }

    func testCLIBuildsPressRequestByPosition() throws {
        let request = try ControlCLI.makeRequest(arguments: ["press", "4"], depth: 0)
        XCTAssertEqual(request, ControlRequest(command: "press", key: "4", depth: 0))
    }

    func testCLIBuildsPageListAndStatusRequests() throws {
        XCTAssertEqual(
            try ControlCLI.makeRequest(arguments: ["page", "next"], depth: 1),
            ControlRequest(command: "switch-page", page: "next", depth: 1)
        )
        XCTAssertEqual(
            try ControlCLI.makeRequest(arguments: ["list"], depth: 0),
            ControlRequest(command: "list", depth: 0)
        )
        XCTAssertEqual(
            try ControlCLI.makeRequest(arguments: ["status"], depth: 0),
            ControlRequest(command: "status", depth: 0)
        )
    }

    func testCLIRejectsBadArguments() {
        XCTAssertThrowsError(try ControlCLI.makeRequest(arguments: [], depth: 0))
        XCTAssertThrowsError(try ControlCLI.makeRequest(arguments: ["press"], depth: 0))
        XCTAssertThrowsError(try ControlCLI.makeRequest(arguments: ["press", "4", "--page"], depth: 0))
        XCTAssertThrowsError(try ControlCLI.makeRequest(arguments: ["press", "4", "extra"], depth: 0))
        XCTAssertThrowsError(try ControlCLI.makeRequest(arguments: ["page"], depth: 0))
        XCTAssertThrowsError(try ControlCLI.makeRequest(arguments: ["explode"], depth: 0)) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("unknown command"))
        }
    }
}
