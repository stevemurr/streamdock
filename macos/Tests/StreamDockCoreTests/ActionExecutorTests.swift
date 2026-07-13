import Foundation
import XCTest
@testable import StreamDockCore

final class ActionExecutorTests: XCTestCase {
    func testLegacyLongRunningActionStillRejectsConcurrentPress() async throws {
        let executor = ActionExecutor(baseEnvironment: ProcessInfo.processInfo.environment)
        let keyID = UUID()
        let action = KeyTrigger.shellCommand(.init(source: "sleep 30"))
        let first = Task { try await executor.execute(action, keyID: keyID) }
        try await Task.sleep(for: .milliseconds(150))

        do {
            _ = try await executor.execute(action, keyID: keyID)
            XCTFail("Expected the unchanged run-once behavior to reject a duplicate press")
        } catch let error as ActionExecutionError {
            XCTAssertEqual(error.localizedDescription, ActionExecutionError.alreadyRunning.localizedDescription)
        }
        executor.cancel(keyID: keyID)
        _ = try await first.value
    }

    func testCaffeinateActionCanBeCancelled() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = ActionExecutor(
            baseEnvironment: ProcessInfo.processInfo.environment,
            managedProcessDirectory: directory
        )
        let keyID = UUID()
        let task = Task {
            try await executor.execute(.caffeinate(.init()), keyID: keyID)
        }
        try await Task.sleep(for: .milliseconds(150))
        executor.cancel(keyID: keyID)
        let result = try await task.value
        XCTAssertEqual(result.launchedDescription, "Keep Mac Awake")
        XCTAssertLessThan(result.duration, 3)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [], [])
    }

    func testCleanupStopsOnlyRecordedCaffeinateProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caffeinate.arguments = ["-i"]
        try caffeinate.run()
        let pidFile = directory.appendingPathComponent("caffeinate-test.pid")
        try String(caffeinate.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)

        let executor = ActionExecutor(
            baseEnvironment: ProcessInfo.processInfo.environment,
            managedProcessDirectory: directory
        )
        executor.cleanupStaleManagedProcesses()
        caffeinate.waitUntilExit()

        XCTAssertFalse(caffeinate.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

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

    private func makeMacroExecutor() -> ActionExecutor {
        // A pinned PATH so /usr/bin/env still finds python3 while the
        // prepended tool directory stays observable.
        let executor = ActionExecutor(baseEnvironment: [
            "PATH": "/usr/bin:/bin",
            "PYTHONPATH": "/existing/pythonpath",
        ])
        executor.controlSocketPath = "/tmp/streamdock-test.sock"
        executor.toolDirectory = "/opt/streamdock-tools"
        executor.pythonModuleDirectory = "/opt/streamdock-python"
        return executor
    }

    private let environmentDumpScript = InlineScriptAction(
        source: """
        import os
        for name in ("STREAMDOCK_SOCKET", "STREAMDOCK_KEY", "STREAMDOCK_PAGE",
                     "STREAMDOCK_PRESS_DEPTH", "PATH", "PYTHONPATH"):
            print(name + "=" + os.environ.get(name, "<unset>"))
        """,
        language: .python
    )

    func testControlEnvironmentIsInjectedWithContext() async throws {
        let executor = makeMacroExecutor()
        let context = KeyExecutionContext(keyPosition: 4, pageName: "main", pressDepth: 2)
        let result = try await executor.execute(
            .inlineScript(environmentDumpScript),
            keyID: UUID(),
            context: context
        )
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let lines = result.standardOutput.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("STREAMDOCK_SOCKET=/tmp/streamdock-test.sock"))
        XCTAssertTrue(lines.contains("STREAMDOCK_KEY=4"))
        XCTAssertTrue(lines.contains("STREAMDOCK_PAGE=main"))
        XCTAssertTrue(lines.contains("STREAMDOCK_PRESS_DEPTH=3"), "children see context depth + 1")
        let path = lines.first { $0.hasPrefix("PATH=") } ?? ""
        XCTAssertTrue(
            path.hasPrefix("PATH=/opt/streamdock-tools:"),
            "PATH should start with the tool directory: \(path)"
        )
        let pythonPath = lines.first { $0.hasPrefix("PYTHONPATH=") } ?? ""
        XCTAssertTrue(
            pythonPath.hasPrefix("PYTHONPATH=/opt/streamdock-python:"),
            "PYTHONPATH should start with the module directory: \(pythonPath)"
        )
        XCTAssertTrue(pythonPath.contains("/existing/pythonpath"))
    }

    func testControlEnvironmentWithoutContextOmitsKeyFields() async throws {
        let executor = makeMacroExecutor()
        let result = try await executor.execute(.inlineScript(environmentDumpScript))
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("STREAMDOCK_SOCKET=/tmp/streamdock-test.sock"))
        XCTAssertTrue(result.standardOutput.contains("STREAMDOCK_KEY=<unset>"))
        XCTAssertTrue(result.standardOutput.contains("STREAMDOCK_PAGE=<unset>"))
        XCTAssertTrue(result.standardOutput.contains("STREAMDOCK_PRESS_DEPTH=<unset>"))
    }

    func testPerActionEnvironmentOverridesStillWin() async throws {
        let executor = makeMacroExecutor()
        var action = environmentDumpScript
        action.options.environment = [
            "STREAMDOCK_KEY": "overridden",
            "PATH": "/action/path:/usr/bin:/bin",
        ]
        let context = KeyExecutionContext(keyPosition: 4, pageName: "main", pressDepth: 0)
        let result = try await executor.execute(.inlineScript(action), keyID: UUID(), context: context)
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("STREAMDOCK_KEY=overridden"))
        XCTAssertTrue(result.standardOutput.contains("PATH=/action/path:/usr/bin:/bin\n"))
        XCTAssertFalse(result.standardOutput.contains("/opt/streamdock-tools"))
    }
}
