import XCTest

/// Exercises the Deck Settings section in the standard macOS Settings window.
@MainActor
final class DeckSettingsUITests: StreamDockUITestCase {
    func testScreenOffPickerPersistsSelection() throws {
        XCTAssertFalse(
            app.windows.firstMatch.staticTexts["Deck Settings"].exists,
            "Deck Settings should no longer appear in the editor sidebar"
        )

        openSettings()
        XCTAssertTrue(
            app.staticTexts["Deck Settings"].waitForExistence(timeout: 5),
            "Settings should show the Deck Settings header"
        )

        let picker = app.popUpButtons["screen-off-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Screen Off picker never appeared")
        XCTAssertEqual(picker.value as? String, "Never", "Screen off defaults to Never")

        picker.click()
        let option = app.menuItems["5 minutes"]
        XCTAssertTrue(option.waitForExistence(timeout: 3), "Picker menu should list 5 minutes")
        option.click()

        XCTAssertEqual(picker.value as? String, "5 minutes")
        let settingsSaveButton = app.buttons["settings-save-button"]
        XCTAssertTrue(
            settingsSaveButton.isEnabled,
            "Changing screen off should mark the configuration dirty"
        )

        settingsSaveButton.click()
        expectation(
            for: NSPredicate(format: "isEnabled == false"),
            evaluatedWith: settingsSaveButton
        )
        waitForExpectations(timeout: 5)

        app.typeKey("w", modifierFlags: .command)
        app.terminate()
        app.launch()
        XCTAssertTrue(slot(0).waitForExistence(timeout: 10))
        openSettings()
        XCTAssertEqual(
            app.popUpButtons["screen-off-picker"].value as? String, "5 minutes",
            "The saved screen-off interval should survive a relaunch"
        )
    }

    private func openSettings() {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(
            app.popUpButtons["screen-off-picker"].waitForExistence(timeout: 5),
            "Settings window did not open"
        )
    }
}
