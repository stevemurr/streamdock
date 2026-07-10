import Foundation
import XCTest
@testable import StreamDockCore

final class ActionExecutorTests: XCTestCase {
    func testInlineShellRunsInConfiguredDirectoryAndCapturesOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let action = InlineScriptAction(
            source: "pwd\nprintf '%s' \"$STREAMDOCK_TEST\"",
            language: .zsh,
            options: .init(
                workingDirectory: directory.path,
                environment: ["STREAMDOCK_TEST": "environment-ok"]
            )
        )
        let executor = ActionExecutor(baseEnvironment: ProcessInfo.processInfo.environment)
        let result = try await executor.execute(.inlineScript(action))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains(directory.path))
        XCTAssertTrue(result.standardOutput.contains("environment-ok"))
    }

    func testInlineAppleScriptRunsViaOsascript() async throws {
        let action = InlineScriptAction(
            source: "return \"streamdock-applescript\"",
            language: .appleScript
        )
        let executor = ActionExecutor(baseEnvironment: ProcessInfo.processInfo.environment)
        let result = try await executor.execute(.inlineScript(action))
        XCTAssertEqual(result.exitCode, 0)
        // osascript prints the script's result to standard output.
        XCTAssertTrue(result.standardOutput.contains("streamdock-applescript"))
    }

    func testAutomaticInlineScriptDetectsAppleScript() async throws {
        let action = InlineScriptAction(
            source: "on run\n    set marker to \"streamdock-auto-applescript\"\n    return marker\nend run",
            language: .automatic
        )
        let executor = ActionExecutor(baseEnvironment: ProcessInfo.processInfo.environment)
        let result = try await executor.execute(.inlineScript(action))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("streamdock-auto-applescript"))
    }

    func testShellCommandDetectedAsAppleScriptRunsViaOsascript() async throws {
        let action = CommandAction(
            source: "on run\n    set marker to \"streamdock-shell-applescript\"\n    return marker\nend run",
            shell: .automatic
        )
        let executor = ActionExecutor(baseEnvironment: ProcessInfo.processInfo.environment)
        let result = try await executor.execute(.shellCommand(action))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("streamdock-shell-applescript"))
    }
}
