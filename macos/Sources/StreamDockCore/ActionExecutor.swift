@preconcurrency import AppKit
@preconcurrency import Foundation

public struct ExecutionResult: Equatable, Sendable {
    public var startedAt: Date
    public var duration: TimeInterval
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public var launchedDescription: String

    public var succeeded: Bool { exitCode == 0 }

    public init(
        startedAt: Date,
        duration: TimeInterval,
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = "",
        launchedDescription: String
    ) {
        self.startedAt = startedAt
        self.duration = duration
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.launchedDescription = launchedDescription
    }
}

/// Where a press came from, threaded into the child process environment so
/// actions can talk back to the app (key references / macros) and so chained
/// presses carry a growing depth counter for loop protection.
public struct KeyExecutionContext: Sendable {
    /// Reading-order position of the key that launched the action.
    public var keyPosition: Int
    /// Name of the page the key lives on, if known.
    public var pageName: String?
    /// How many chained presses deep this action already is. The child sees
    /// `STREAMDOCK_PRESS_DEPTH` = `pressDepth + 1`.
    public var pressDepth: Int

    public init(keyPosition: Int, pageName: String? = nil, pressDepth: Int = 0) {
        self.keyPosition = keyPosition
        self.pageName = pageName
        self.pressDepth = pressDepth
    }
}

public enum ActionExecutionError: LocalizedError {
    case noAction
    case missingApplication(String)
    case emptySource
    case missingScript(String)
    case alreadyRunning
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noAction: "This key has no executable action."
        case let .missingApplication(name): "Application not found: \(name)"
        case .emptySource: "There is no code to run."
        case let .missingScript(path): "Script not found: \(path)"
        case .alreadyRunning: "This key is already running."
        case let .launchFailed(message): "Could not launch action: \(message)"
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 1_048_576

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(chunk.prefix(limit - data.count))
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public final class ActionExecutor: @unchecked Sendable {
    public let loginShellPath: String
    public private(set) var baseEnvironment: [String: String]
    private var fileEnvironment: [String: String] = [:]
    private var secretEnvironment: [String: String] = [:]

    private let lock = NSLock()
    private var running: [UUID: ProcessBox] = [:]
    private var _controlSocketPath: String?
    private var _toolDirectory: String?
    private var _pythonModuleDirectory: String?

    /// Path of the app's control socket, exported to actions as `STREAMDOCK_SOCKET`.
    public var controlSocketPath: String? {
        get { lock.lock(); defer { lock.unlock() }; return _controlSocketPath }
        set { lock.lock(); _controlSocketPath = newValue; lock.unlock() }
    }

    /// Directory containing the `streamdock` helper binary; prepended to `PATH`.
    public var toolDirectory: String? {
        get { lock.lock(); defer { lock.unlock() }; return _toolDirectory }
        set { lock.lock(); _toolDirectory = newValue; lock.unlock() }
    }

    /// Directory containing the `streamdock.py` module; prepended to `PYTHONPATH`.
    public var pythonModuleDirectory: String? {
        get { lock.lock(); defer { lock.unlock() }; return _pythonModuleDirectory }
        set { lock.lock(); _pythonModuleDirectory = newValue; lock.unlock() }
    }

    public init(
        loginShellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        baseEnvironment: [String: String]? = nil
    ) {
        self.loginShellPath = loginShellPath
        self.baseEnvironment = baseEnvironment ?? Self.captureLoginEnvironment(shellPath: loginShellPath)
    }

    public func refreshEnvironment() {
        let refreshed = Self.captureLoginEnvironment(shellPath: loginShellPath)
        lock.lock()
        baseEnvironment = refreshed
        lock.unlock()
    }

    /// Injects decrypted user secrets into every action's environment. Secrets
    /// override the captured login environment but can still be shadowed by an
    /// `env_file` entry or a per-action environment override.
    public func setSecrets(_ environment: [String: String]) {
        lock.lock()
        secretEnvironment = environment
        lock.unlock()
    }

    public func configureEnvironmentFile(path: String?, baseDirectory: URL) {
        var loaded: [String: String] = [:]
        if let path, !path.isEmpty {
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, relativeTo: baseDirectory)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                for rawLine in text.split(separator: "\n") {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    guard !line.isEmpty, !line.hasPrefix("#"), let split = line.firstIndex(of: "=") else { continue }
                    let key = line[..<split].trimmingCharacters(in: .whitespaces)
                    var value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
                    if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                        (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    loaded[key] = value
                }
            }
        }
        lock.lock()
        fileEnvironment = loaded
        lock.unlock()
    }

    public func execute(
        _ trigger: KeyTrigger,
        keyID: UUID = UUID(),
        context: KeyExecutionContext? = nil
    ) async throws -> ExecutionResult {
        if case let .launchApplication(reference) = trigger {
            return try await MainActor.run { try self.launchApplication(reference) }
        }
        return try await Task.detached(priority: .userInitiated) {
            try self.executeBlocking(trigger, keyID: keyID, context: context)
        }.value
    }

    public func cancel(keyID: UUID) {
        lock.lock()
        let process = running[keyID]?.process
        lock.unlock()
        process?.terminate()
    }

    public static func captureLoginEnvironment(shellPath: String) -> [String: String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-c", "printf '\\0'; /usr/bin/env -0"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let sentinel = data.firstIndex(of: 0) else {
                return ProcessInfo.processInfo.environment
            }
            let bytes = data[data.index(after: sentinel)...]
                .split(separator: 0, omittingEmptySubsequences: true)
            var result: [String: String] = [:]
            for item in bytes {
                let entry = String(decoding: item, as: UTF8.self)
                guard let split = entry.firstIndex(of: "=") else { continue }
                result[String(entry[..<split])] = String(entry[entry.index(after: split)...])
            }
            if !result.isEmpty { return result }
        } catch {}
        return ProcessInfo.processInfo.environment
    }

    private var loginShellLanguage: ScriptLanguage {
        loginShellPath.hasSuffix("bash") ? .bash : .zsh
    }

    private func executeBlocking(
        _ trigger: KeyTrigger,
        keyID: UUID,
        context: KeyExecutionContext?
    ) throws -> ExecutionResult {
        switch trigger {
        case .none, .sleepDeck, .switchPage:
            throw ActionExecutionError.noAction
        case .launchApplication:
            preconditionFailure("Application launches are dispatched on the main actor")
        case let .shellCommand(action):
            guard !action.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionExecutionError.emptySource
            }
            let language = LanguageDetector.effective(
                requested: action.shell,
                source: action.source,
                loginShell: loginShellLanguage
            )
            if language == .appleScript {
                // AppleScript source cannot be handed to a POSIX shell; run it
                // through osascript via a temp file like an inline script.
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("streamdock-\(UUID().uuidString).applescript")
                try action.source.write(to: file, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(at: file) }
                return try runScript(
                    file: file,
                    language: language,
                    arguments: [],
                    options: action.options,
                    keyID: keyID,
                    context: context,
                    description: "\(language.displayName) command"
                )
            }
            let shell = language == .bash ? "/bin/bash" : "/bin/zsh"
            return try runProcess(
                executable: shell,
                arguments: ["-l", "-c", action.source],
                options: action.options,
                keyID: keyID,
                context: context,
                description: "\(language.displayName) command"
            )
        case let .inlineScript(action):
            guard !action.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionExecutionError.emptySource
            }
            let language = LanguageDetector.effective(
                requested: action.language,
                source: action.source,
                loginShell: loginShellLanguage
            )
            let ext = Self.temporaryFileExtension(for: language)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("streamdock-\(UUID().uuidString).\(ext)")
            try action.source.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            return try runScript(
                file: file,
                language: language,
                arguments: [],
                options: action.options,
                keyID: keyID,
                context: context,
                description: "inline \(language.displayName)"
            )
        case let .scriptFile(action):
            let file = URL(fileURLWithPath: NSString(string: action.path).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw ActionExecutionError.missingScript(file.path)
            }
            let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let language = LanguageDetector.effective(
                requested: action.language,
                source: source,
                fileURL: file,
                loginShell: loginShellLanguage
            )
            return try runScript(
                file: file,
                language: language,
                arguments: action.arguments,
                options: action.options,
                keyID: keyID,
                context: context,
                description: file.lastPathComponent
            )
        }
    }

    private static func temporaryFileExtension(for language: ScriptLanguage) -> String {
        switch language {
        case .python: "py"
        case .appleScript: "applescript"
        case .automatic, .bash, .zsh: language.rawValue
        }
    }

    private func runScript(
        file: URL,
        language: ScriptLanguage,
        arguments: [String],
        options: ExecutionOptions,
        keyID: UUID,
        context: KeyExecutionContext?,
        description: String
    ) throws -> ExecutionResult {
        let command: String
        switch language {
        case .python: command = "python3"
        case .appleScript: command = "osascript"
        case .bash: command = "bash"
        case .zsh, .automatic: command = "zsh"
        }
        return try runProcess(
            executable: "/usr/bin/env",
            arguments: [command, file.path] + arguments,
            options: options,
            keyID: keyID,
            context: context,
            description: description
        )
    }

    @MainActor
    private func launchApplication(_ reference: ApplicationReference) throws -> ExecutionResult {
        let started = Date()
        let workspace = NSWorkspace.shared
        let url: URL?
        if let path = reference.path, !path.isEmpty {
            url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        } else if let identifier = reference.bundleIdentifier, !identifier.isEmpty {
            url = workspace.urlForApplication(withBundleIdentifier: identifier)
        } else {
            url = Self.findApplication(named: reference.name)
        }
        guard let url else { throw ActionExecutionError.missingApplication(reference.name) }
        guard workspace.open(url) else { throw ActionExecutionError.launchFailed(reference.name) }
        return ExecutionResult(
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            exitCode: 0,
            launchedDescription: reference.name
        )
    }

    private static func findApplication(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
        let bundleName = name.hasSuffix(".app") ? name : "\(name).app"
        for root in roots {
            let candidate = root.appendingPathComponent(bundleName, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        options: ExecutionOptions,
        keyID: UUID,
        context: KeyExecutionContext? = nil,
        description: String
    ) throws -> ExecutionResult {
        lock.lock()
        let alreadyRunning = running[keyID] != nil
        lock.unlock()
        if alreadyRunning && !options.allowConcurrent { throw ActionExecutionError.alreadyRunning }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutData = LockedData()
        let stderrData = LockedData()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory(for: options)
        lock.lock()
        var environment = baseEnvironment
            .merging(secretEnvironment) { _, secretValue in secretValue }
            .merging(fileEnvironment) { _, fileValue in fileValue }
        let socketPath = _controlSocketPath
        let toolDirectory = _toolDirectory
        let pythonModuleDirectory = _pythonModuleDirectory
        lock.unlock()
        // Key-reference (macro) plumbing: tell the child how to reach the app
        // and where it is in a press chain. Per-action overrides still win —
        // they are merged last.
        if let socketPath {
            environment["STREAMDOCK_SOCKET"] = socketPath
        }
        if let context {
            environment["STREAMDOCK_KEY"] = String(context.keyPosition)
            if let pageName = context.pageName {
                environment["STREAMDOCK_PAGE"] = pageName
            }
            environment["STREAMDOCK_PRESS_DEPTH"] = String(context.pressDepth + 1)
        }
        if let toolDirectory {
            environment["PATH"] = environment["PATH"].map { "\(toolDirectory):\($0)" } ?? toolDirectory
        }
        if let pythonModuleDirectory {
            environment["PYTHONPATH"] = environment["PYTHONPATH"]
                .map { "\(pythonModuleDirectory):\($0)" } ?? pythonModuleDirectory
        }
        environment.merge(options.environment) { _, actionValue in actionValue }
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutData.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrData.append(handle.availableData)
        }

        let box = ProcessBox(process)
        lock.lock()
        running[keyID] = box
        lock.unlock()
        defer {
            lock.lock()
            running[keyID] = nil
            lock.unlock()
        }

        let started = Date()
        do {
            try process.run()
        } catch {
            throw ActionExecutionError.launchFailed(error.localizedDescription)
        }

        if let timeout = options.timeoutSeconds, timeout > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if box.process.isRunning { box.process.terminate() }
            }
        }
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        stdoutData.append(stdout.fileHandleForReading.readDataToEndOfFile())
        stderrData.append(stderr.fileHandleForReading.readDataToEndOfFile())
        return ExecutionResult(
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            exitCode: process.terminationStatus,
            standardOutput: stdoutData.string(),
            standardError: stderrData.string(),
            launchedDescription: description
        )
    }

    private func workingDirectory(for options: ExecutionOptions) -> URL {
        guard let raw = options.workingDirectory, !raw.isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: NSString(string: raw).expandingTildeInPath, isDirectory: true)
    }
}
