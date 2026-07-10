import Foundation
import StreamDockCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        if case let .failed(message) = self { return message }
        return "check failed"
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

@main
struct StreamDockCoreChecks {
    @MainActor
    static func main() async throws {
        try require(
            LanguageDetector.detect(source: "#!/usr/bin/env python3\nprint('ok')") == .python,
            "Python shebang detection"
        )
        try require(
            LanguageDetector.detect(source: "#!/bin/zsh\necho ok") == .zsh,
            "Zsh shebang detection"
        )

        let packet = StreamDockProtocol.mode()
        try require(packet.count == 1025, "HID packet length")
        try require(Array(packet[1...5]) == [0x43, 0x52, 0x54, 0, 0], "HID command prefix")

        let legacy = """
        settings:
          brightness: 65
        pages:
          - name: main
            keys:
              - position: 0
                app: Terminal
              - position: 1
                color: [30, 110, 160]
                command: echo hello
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("legacy.yaml")
        let nativeURL = directory.appendingPathComponent("native.yaml")
        try legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
        let store = ConfigurationStore()
        let configuration = try store.load(from: legacyURL)
        try require(configuration.pages[0].keys[0].trigger.kind == .launchApplication, "Legacy app migration")
        try require(configuration.pages[0].keys[1].trigger.kind == .shellCommand, "Legacy command migration")
        try require(configuration.pages[0].keys[1].color == "#1e6ea0", "Legacy RGB color migration")
        try store.save(configuration, to: nativeURL)
        let roundTripped = try store.load(from: nativeURL)
        try require(roundTripped.version == 2, "Versioned YAML round trip")

        let toml = """
        [settings]
        brightness = 72
        [[keys]]
        position = 4
        label = "Build"
        command = "make test"
        """
        let tomlURL = directory.appendingPathComponent("legacy.toml")
        try toml.write(to: tomlURL, atomically: true, encoding: .utf8)
        let tomlConfiguration = try store.load(from: tomlURL)
        try require(tomlConfiguration.settings.brightness == 72, "Legacy TOML settings")
        try require(tomlConfiguration.pages[0].keys[0].trigger.kind == .shellCommand, "Legacy TOML action")

        let jpeg = try KeyFaceRenderer.jpegData(
            for: KeyConfiguration(position: 0, label: "Run", icon: "play", color: "#336699")
        )
        try require(jpeg.starts(with: [0xff, 0xd8]), "Hardware key-face JPEG rendering")

        let action = InlineScriptAction(
            source: "pwd\nprintf '%s' \"$STREAMDOCK_CHECK\"",
            language: .zsh,
            options: .init(
                workingDirectory: directory.path,
                environment: ["STREAMDOCK_CHECK": "ok"]
            )
        )
        let result = try await ActionExecutor(
            baseEnvironment: ProcessInfo.processInfo.environment
        ).execute(.inlineScript(action))
        try require(result.succeeded, "Inline Zsh execution")
        try require(result.standardOutput.contains(directory.path), "Explicit working directory")
        try require(result.standardOutput.contains("ok"), "Environment merge")

        // Encrypted secrets round-trip and injection into a real process.
        let secretsURL = directory.appendingPathComponent("secrets.dat")
        let secretsStore = SecretsStore(
            fileURL: secretsURL,
            keyProvider: StaticSecretsKeyProvider(seed: "checks")
        )
        try secretsStore.save([SecretItem(name: "STREAMDOCK_SECRET", value: "top-secret")])
        let encrypted = try Data(contentsOf: secretsURL)
        try require(
            !String(decoding: encrypted, as: UTF8.self).contains("top-secret"),
            "Secrets encrypted at rest"
        )
        let reloaded = SecretsStore(
            fileURL: secretsURL,
            keyProvider: StaticSecretsKeyProvider(seed: "checks")
        )
        try require(reloaded.environment()["STREAMDOCK_SECRET"] == "top-secret", "Secrets decrypt round trip")

        let secretExecutor = ActionExecutor(baseEnvironment: ProcessInfo.processInfo.environment)
        secretExecutor.setSecrets(reloaded.environment())
        let secretResult = try await secretExecutor.execute(
            .inlineScript(InlineScriptAction(source: "printf '%s' \"$STREAMDOCK_SECRET\"", language: .zsh))
        )
        try require(secretResult.standardOutput.contains("top-secret"), "Secret injected into action environment")

        print("StreamDockCore checks passed")
    }
}
