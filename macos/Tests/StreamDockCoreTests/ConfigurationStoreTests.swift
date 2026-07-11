import Foundation
import XCTest
@testable import StreamDockCore

final class ConfigurationStoreTests: XCTestCase {
    func testScreenOffSettingRoundTripsAndDefaultsToNever() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.yaml")

        let store = ConfigurationStore()
        var configuration = DeckConfiguration()
        configuration.settings.screenOffAfterSeconds = 300
        try store.save(configuration, to: url)
        XCTAssertEqual(try store.load(from: url).settings.screenOffAfterSeconds, 300)

        // Never (nil) stays out of the file and decodes back as nil.
        configuration.settings.screenOffAfterSeconds = nil
        try store.save(configuration, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("screen_off_seconds"))
        XCTAssertNil(try store.load(from: url).settings.screenOffAfterSeconds)
    }

    func testImportsLegacyYAMLAndWritesTypedSchema() throws {
        let legacy = """
        settings:
          brightness: 65
          keepalive_seconds: 1.5
        pages:
          - name: main
            keys:
              - position: 0
                label: Terminal
                color: '#123456'
                app: Terminal
              - position: 1
                command: echo hello
              - position: 14
                action: page:next
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let input = directory.appendingPathComponent("legacy.yaml")
        let output = directory.appendingPathComponent("native.yaml")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try legacy.write(to: input, atomically: true, encoding: .utf8)

        let store = ConfigurationStore()
        let configuration = try store.load(from: input)
        XCTAssertEqual(configuration.version, 1)
        XCTAssertEqual(configuration.settings.brightness, 65)
        XCTAssertEqual(configuration.pages[0].keys[0].trigger.kind, .launchApplication)
        XCTAssertEqual(configuration.pages[0].keys[1].trigger.kind, .shellCommand)
        XCTAssertEqual(configuration.pages[0].keys[2].trigger, .switchPage("next"))

        try store.save(configuration, to: output)
        let saved = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(saved.contains("version: 2"))
        XCTAssertTrue(saved.contains("trigger:"))
        let reloaded = try store.load(from: output)
        XCTAssertEqual(reloaded.version, 2)
        XCTAssertEqual(reloaded.pages[0].keys.count, 3)
    }

    func testImportsLegacyTOML() throws {
        let legacy = """
        [settings]
        brightness = 72
        keepalive_seconds = 2.5

        [[keys]]
        position = 0
        label = "Build"
        color = "#336699"
        command = "make test"

        [[keys]]
        position = 14
        action = "sleep"
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try legacy.write(to: file, atomically: true, encoding: .utf8)
        let configuration = try ConfigurationStore().load(from: file)
        XCTAssertEqual(configuration.settings.brightness, 72)
        XCTAssertEqual(configuration.pages[0].keys.count, 2)
        XCTAssertEqual(configuration.pages[0].keys[0].trigger.kind, .shellCommand)
        XCTAssertEqual(configuration.pages[0].keys[1].trigger, .sleepDeck)
    }
}
