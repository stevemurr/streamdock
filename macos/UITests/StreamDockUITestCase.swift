import XCTest

/// Base class for StreamDock UI tests. Launches the app against a scratch
/// configuration written to a per-test temporary directory (see
/// `STREAMDOCK_CONFIG_PATH` in AppModel), so tests never read or write the
/// user's real configuration, device, or Keychain.
///
/// The fixture puts "Terminal" at slot 0 and "Music" at slot 1; slots 2–14
/// start empty.
@MainActor
class StreamDockUITestCase: XCTestCase {
    private(set) var app: XCUIApplication!
    private var fixtureDirectory: URL!

    private let fixtureYAML = """
        version: 2
        settings:
          brightness: 70
        pages:
          - name: Main
            keys:
              - position: 0
                label: Terminal
                icon: play
                color: "#e74c3c"
              - position: 1
                label: Music
                icon: monitor
                color: "#3498db"
        """

    override func setUp() async throws {
        continueAfterFailure = false
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamDockUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let configurationURL = fixtureDirectory.appendingPathComponent("config.yaml")
        try fixtureYAML.write(to: configurationURL, atomically: true, encoding: .utf8)

        app = XCUIApplication()
        // The editor window is often closed when this menu-bar app last quit;
        // ignore saved window state so the test launch always presents it.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["STREAMDOCK_UI_TESTING"] = "1"
        app.launchEnvironment["STREAMDOCK_CONFIG_PATH"] = configurationURL.path
        app.launch()
        app.activate()

        XCTAssertTrue(
            slot(0).waitForExistence(timeout: 10),
            "Deck editor grid never appeared"
        )
        XCTAssertFalse(
            saveButton.isEnabled,
            "A freshly launched app must not have unsaved changes"
        )
    }

    override func tearDown() async throws {
        app?.terminate()
        if let fixtureDirectory {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
    }

    // MARK: - Shared queries and assertions

    func slot(_ position: Int) -> XCUIElement {
        app.windows.firstMatch.buttons["deck-slot-\(position)"]
    }

    var saveButton: XCUIElement {
        app.windows.firstMatch.toolbars.buttons["Save"]
    }

    func expectLabel(
        _ expected: String,
        onSlot position: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = slot(position)
        let deadline = Date().addingTimeInterval(5)
        while element.label != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertEqual(
            element.label, expected,
            "Slot \(position + 1) should read \"\(expected)\"",
            file: file, line: line
        )
    }

    /// Lets pending UI updates land before asserting on the absence of
    /// something.
    func pause(_ seconds: TimeInterval = 0.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
