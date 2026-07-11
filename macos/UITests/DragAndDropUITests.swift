import XCTest

/// Drives the real app and exercises drag-and-drop key reordering in the deck
/// editor grid.
@MainActor
final class DragAndDropUITests: StreamDockUITestCase {
    func testDragKeyToEmptySlotMovesIt() throws {
        drag(fromSlot: 0, toSlot: 7)

        expectLabel("Terminal", onSlot: 7)
        expectLabel("Unassigned key 1", onSlot: 0)
        XCTAssertTrue(saveButton.isEnabled, "Moving a key should mark the configuration dirty")
    }

    func testDragKeyOntoOccupiedSlotSwapsBoth() throws {
        drag(fromSlot: 0, toSlot: 1)

        expectLabel("Music", onSlot: 0)
        expectLabel("Terminal", onSlot: 1)
        XCTAssertTrue(saveButton.isEnabled, "Swapping keys should mark the configuration dirty")
    }

    func testDragKeyOntoItselfChangesNothing() throws {
        drag(fromSlot: 0, toSlot: 0)

        expectLabel("Terminal", onSlot: 0)
        expectLabel("Music", onSlot: 1)
        XCTAssertFalse(saveButton.isEnabled, "A no-op drag must not dirty the configuration")
    }

    func testMovedLayoutSurvivesSaveAndRelaunch() throws {
        drag(fromSlot: 0, toSlot: 14)
        expectLabel("Terminal", onSlot: 14)

        saveButton.click()
        expectation(
            for: NSPredicate(format: "isEnabled == false"),
            evaluatedWith: saveButton
        )
        waitForExpectations(timeout: 5)

        app.terminate()
        app.launch()
        XCTAssertTrue(slot(0).waitForExistence(timeout: 10))
        expectLabel("Terminal", onSlot: 14)
        expectLabel("Unassigned key 1", onSlot: 0)
    }

    /// Performs a mouse drag from the center of one slot to another, slowly
    /// enough for SwiftUI's `.draggable`/`.dropDestination` session to start
    /// and register the target before release.
    private func drag(fromSlot source: Int, toSlot destination: Int) {
        slot(source).click(
            forDuration: 0.5,
            thenDragTo: slot(destination),
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
    }
}
