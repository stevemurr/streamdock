import XCTest

/// Exercises the two ways to delete a key: the hover "×" on a grid slot and
/// the Delete Key button in the inspector.
@MainActor
final class KeyDeletionUITests: StreamDockUITestCase {
    func testHoverRevealsDeleteButtonThatDeletesKey() throws {
        slot(0).hover()
        let deleteButton = app.windows.firstMatch.buttons["delete-key-0"]
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 3),
            "Hovering an occupied slot should reveal its delete button"
        )
        deleteButton.click()

        expectLabel("Unassigned key 1", onSlot: 0)
        expectLabel("Music", onSlot: 1)
        XCTAssertTrue(saveButton.isEnabled, "Deleting a key should mark the configuration dirty")
    }

    func testHoveringEmptySlotShowsNoDeleteButton() throws {
        slot(5).hover()
        pause()
        XCTAssertFalse(
            app.windows.firstMatch.buttons["delete-key-5"].exists,
            "An empty slot has nothing to delete"
        )
    }

    func testInspectorDeleteButtonDeletesSelectedKey() throws {
        slot(1).click()
        let deleteButton = app.windows.firstMatch.buttons["inspector-delete-key"]
        XCTAssertTrue(
            deleteButton.waitForExistence(timeout: 3),
            "Selecting a key should show the inspector with a Delete Key button"
        )
        deleteButton.click()

        expectLabel("Unassigned key 2", onSlot: 1)
        expectLabel("Terminal", onSlot: 0)
        XCTAssertTrue(saveButton.isEnabled, "Deleting a key should mark the configuration dirty")
        XCTAssertFalse(
            deleteButton.exists,
            "Deleting clears the selection, so the inspector shows the placeholder"
        )
    }

    func testDeletedKeyStaysGoneAfterSaveAndRelaunch() throws {
        slot(0).hover()
        let deleteButton = app.windows.firstMatch.buttons["delete-key-0"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        deleteButton.click()
        expectLabel("Unassigned key 1", onSlot: 0)

        saveButton.click()
        expectation(
            for: NSPredicate(format: "isEnabled == false"),
            evaluatedWith: saveButton
        )
        waitForExpectations(timeout: 5)

        app.terminate()
        app.launch()
        XCTAssertTrue(slot(0).waitForExistence(timeout: 10))
        expectLabel("Unassigned key 1", onSlot: 0)
        expectLabel("Music", onSlot: 1)
    }
}
