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
}
