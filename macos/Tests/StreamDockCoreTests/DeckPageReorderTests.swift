import Foundation
import XCTest
@testable import StreamDockCore

final class DeckPageReorderTests: XCTestCase {
    private func makePage() -> DeckPage {
        DeckPage(
            name: "main",
            keys: [
                KeyConfiguration(position: 0, label: "Terminal"),
                KeyConfiguration(position: 3, label: "Build"),
                KeyConfiguration(position: 14, label: "Sleep"),
            ]
        )
    }

    private func label(at position: Int, in page: DeckPage) -> String? {
        page.keys.first(where: { $0.position == position })?.label
    }

    func testMoveToEmptySlotUpdatesPosition() {
        var page = makePage()
        page.moveKey(from: 3, to: 7)
        XCTAssertEqual(page.keys.count, 3)
        XCTAssertNil(label(at: 3, in: page))
        XCTAssertEqual(label(at: 7, in: page), "Build")
        XCTAssertEqual(label(at: 0, in: page), "Terminal")
        XCTAssertEqual(label(at: 14, in: page), "Sleep")
    }

    func testMoveToOccupiedSlotSwapsKeys() {
        var page = makePage()
        let terminalID = page.keys[0].id
        let sleepID = page.keys[2].id
        page.moveKey(from: 0, to: 14)
        XCTAssertEqual(page.keys.count, 3)
        XCTAssertEqual(label(at: 14, in: page), "Terminal")
        XCTAssertEqual(label(at: 0, in: page), "Sleep")
        XCTAssertEqual(page.keys.first(where: { $0.position == 14 })?.id, terminalID)
        XCTAssertEqual(page.keys.first(where: { $0.position == 0 })?.id, sleepID)
    }

    func testSwapPreservesKeyContents() {
        var page = DeckPage(keys: [
            KeyConfiguration(position: 1, label: "One", icon: "play", color: "#112233"),
            KeyConfiguration(position: 2, label: "Two", icon: "lock", color: "#445566"),
        ])
        page.moveKey(from: 2, to: 1)
        let one = page.keys.first(where: { $0.label == "One" })
        let two = page.keys.first(where: { $0.label == "Two" })
        XCTAssertEqual(one?.position, 2)
        XCTAssertEqual(one?.icon, "play")
        XCTAssertEqual(one?.color, "#112233")
        XCTAssertEqual(two?.position, 1)
        XCTAssertEqual(two?.icon, "lock")
        XCTAssertEqual(two?.color, "#445566")
    }

    func testSamePositionIsNoOp() {
        var page = makePage()
        let before = page
        page.moveKey(from: 3, to: 3)
        XCTAssertEqual(page, before)
    }

    func testEmptySourceIsNoOp() {
        var page = makePage()
        let before = page
        page.moveKey(from: 5, to: 0)
        XCTAssertEqual(page, before)
    }

    func testOutOfBoundsIndicesAreNoOps() {
        var page = makePage()
        let before = page
        page.moveKey(from: -1, to: 4)
        page.moveKey(from: 15, to: 4)
        page.moveKey(from: 0, to: -1)
        page.moveKey(from: 0, to: 15)
        XCTAssertEqual(page, before)
    }

    func testCustomSlotCountBoundsAreRespected() {
        var page = DeckPage(keys: [KeyConfiguration(position: 0, label: "Only")])
        let before = page
        page.moveKey(from: 0, to: 5, slotCount: 6)
        XCTAssertEqual(label(at: 5, in: page), "Only")
        page.moveKey(from: 5, to: 6, slotCount: 6)
        XCTAssertEqual(label(at: 5, in: page), "Only")
        XCTAssertNotEqual(page, before)
    }
}
