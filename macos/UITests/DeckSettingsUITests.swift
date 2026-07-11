import XCTest

/// Exercises the sidebar's Deck Settings section.
@MainActor
final class DeckSettingsUITests: StreamDockUITestCase {
    func testScreenOffPickerPersistsSelection() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(
            window.staticTexts["Deck Settings"].exists,
            "Sidebar should show the Deck Settings header"
        )

        let picker = window.popUpButtons["screen-off-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Screen Off picker never appeared")
        XCTAssertEqual(picker.value as? String, "Never", "Screen off defaults to Never")

        picker.click()
        let option = app.menuItems["5 minutes"]
        XCTAssertTrue(option.waitForExistence(timeout: 3), "Picker menu should list 5 minutes")
        option.click()

        XCTAssertEqual(picker.value as? String, "5 minutes")
        XCTAssertTrue(
            saveButton.isEnabled,
            "Changing screen off should mark the configuration dirty"
        )

        saveButton.click()
        expectation(
            for: NSPredicate(format: "isEnabled == false"),
            evaluatedWith: saveButton
        )
        waitForExpectations(timeout: 5)

        app.terminate()
        app.launch()
        XCTAssertTrue(slot(0).waitForExistence(timeout: 10))
        XCTAssertEqual(
            window.popUpButtons["screen-off-picker"].value as? String, "5 minutes",
            "The saved screen-off interval should survive a relaunch"
        )
    }
}
