import AppKit
import Combine
import StreamDockCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration: DeckConfiguration
    @Published var selectedPageID: UUID?
    @Published var selectedPosition: Int?
    @Published var isDirty = false
    @Published var executionResult: ExecutionResult?
    @Published var executionError: String?
    @Published var isExecuting = false
    @Published var deviceStatus = "Native device runtime starting"
    @Published var legacyAgentInstalled = FileManager.default.fileExists(
        atPath: NSString(string: "~/Library/LaunchAgents/com.streamdock.run.plist").expandingTildeInPath
    )
    @Published var secrets: [SecretItem] = []
    @Published var isShowingSecrets = false
    @Published var secretsError: String?

    let configurationURL: URL
    private let store = ConfigurationStore()
    private let executor = ActionExecutor()
    private let runtime = DeckRuntimeController()
    private let secretsStore = SecretsStore()
    private var importedFrom: URL?
    private var terminationObserver: NSObjectProtocol?

    init() {
        do {
            let initial = try store.loadInitial()
            configuration = initial.configuration
            importedFrom = initial.source
        } catch {
            configuration = .init()
            executionError = error.localizedDescription
        }
        configurationURL = ConfigurationStore.defaultConfigurationURL
        selectedPageID = configuration.pages.first?.id
        configureEnvironmentFile()
        loadSecrets()
        runtime.onStatusChange = { [weak self] status in self?.deviceStatus = status }
        runtime.onExecutableAction = { [weak self] key in self?.runHardwareAction(key) }
        runtime.start(configuration: configuration)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.runtime.stop() }
        }
    }

    var selectedPage: DeckPage? {
        guard let selectedPageID else { return nil }
        return configuration.pages.first(where: { $0.id == selectedPageID })
    }

    var selectedKey: KeyConfiguration? {
        get {
            guard let pageID = selectedPageID, let position = selectedPosition,
                  let page = configuration.pages.first(where: { $0.id == pageID }) else { return nil }
            return page.keys.first(where: { $0.position == position })
        }
        set {
            guard let pageID = selectedPageID, let position = selectedPosition,
                  let pageIndex = configuration.pages.firstIndex(where: { $0.id == pageID }) else { return }
            if let keyIndex = configuration.pages[pageIndex].keys.firstIndex(where: { $0.position == position }) {
                if let newValue {
                    configuration.pages[pageIndex].keys[keyIndex] = newValue
                } else {
                    configuration.pages[pageIndex].keys.remove(at: keyIndex)
                }
            } else if let newValue {
                configuration.pages[pageIndex].keys.append(newValue)
            }
            isDirty = true
        }
    }

    func select(position: Int) {
        selectedPosition = position
        if selectedKey == nil { selectedKey = KeyConfiguration(position: position) }
    }

    func key(at position: Int) -> KeyConfiguration? {
        selectedPage?.keys.first(where: { $0.position == position })
    }

    func bindingForSelectedKey() -> Binding<KeyConfiguration>? {
        guard selectedKey != nil else { return nil }
        return Binding(
            get: { self.selectedKey ?? KeyConfiguration(position: self.selectedPosition ?? 0) },
            set: { self.selectedKey = $0 }
        )
    }

    func addPage() {
        let page = DeckPage(name: "Page \(configuration.pages.count + 1)")
        configuration.pages.append(page)
        selectedPageID = page.id
        selectedPosition = nil
        isDirty = true
    }

    func deleteSelectedPage() {
        guard configuration.pages.count > 1, let selectedPageID,
              let index = configuration.pages.firstIndex(where: { $0.id == selectedPageID }) else { return }
        configuration.pages.remove(at: index)
        self.selectedPageID = configuration.pages[min(index, configuration.pages.count - 1)].id
        selectedPosition = nil
        isDirty = true
    }

    /// Moves (or swaps) keys on the selected page in response to a drag in the
    /// deck editor. Selection follows the moved key so the inspector keeps
    /// showing whatever the user dragged.
    func moveKey(from: Int, to: Int) {
        guard let selectedPageID,
              let pageIndex = configuration.pages.firstIndex(where: { $0.id == selectedPageID })
        else { return }
        let before = configuration.pages[pageIndex]
        var page = before
        page.moveKey(from: from, to: to)
        guard page != before else { return }
        let destinationWasOccupied = before.keys.contains { $0.position == to }
        configuration.pages[pageIndex] = page
        isDirty = true
        if selectedPosition == from {
            selectedPosition = to
        } else if selectedPosition == to, destinationWasOccupied {
            selectedPosition = from
        }
    }

    func updateSelectedPageName(_ name: String) {
        guard let selectedPageID,
              let index = configuration.pages.firstIndex(where: { $0.id == selectedPageID }) else { return }
        configuration.pages[index].name = name
        isDirty = true
    }

    func save() {
        do {
            try store.save(configuration, to: configurationURL)
            configuration = configuration.upgraded()
            isDirty = false
            importedFrom = nil
            configureEnvironmentFile()
            runtime.update(configuration: configuration)
        } catch {
            present(error)
        }
    }

    func runSelectedAction() {
        guard let key = selectedKey else { return }
        isExecuting = true
        executionError = nil
        executionResult = nil
        Task {
            do {
                executionResult = try await executor.execute(key.trigger, keyID: key.id)
            } catch {
                executionError = error.localizedDescription
            }
            isExecuting = false
        }
    }

    func stopSelectedAction() {
        guard let key = selectedKey else { return }
        executor.cancel(keyID: key.id)
    }

    func refreshExecutionEnvironment() {
        executor.refreshEnvironment()
        configureEnvironmentFile()
    }

    private func runHardwareAction(_ key: KeyConfiguration) {
        Task {
            do {
                let result = try await executor.execute(key.trigger, keyID: key.id)
                executionResult = result
                if !result.succeeded {
                    executionError = "\(key.label.isEmpty ? "Key \(key.position + 1)" : key.label) exited with status \(result.exitCode)."
                }
            } catch {
                executionError = error.localizedDescription
            }
        }
    }

    private func configureEnvironmentFile() {
        let base = configuration.settings.resourceRoot.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
        } ?? configurationURL.deletingLastPathComponent()
        executor.configureEnvironmentFile(
            path: configuration.settings.environmentFile,
            baseDirectory: base
        )
    }

    func present(_ error: Error) {
        executionError = error.localizedDescription
    }

    func disableLegacyAgent() {
        let path = NSString(
            string: "~/Library/LaunchAgents/com.streamdock.run.plist"
        ).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            legacyAgentInstalled = false
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", "-w", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            try FileManager.default.removeItem(atPath: path)
            legacyAgentInstalled = false
            deviceStatus = "Legacy runner disabled · connecting native runtime"
        } catch {
            present(error)
        }
    }

    // MARK: - Secrets

    func loadSecrets() {
        do {
            secrets = try secretsStore.load()
            secretsError = nil
        } catch {
            secrets = []
            secretsError = error.localizedDescription
        }
        pushSecretsToExecutor()
    }

    func addSecret() {
        secrets.append(SecretItem())
    }

    func deleteSecret(_ id: UUID) {
        secrets.removeAll { $0.id == id }
    }

    /// Encrypts the current secrets to disk and makes them live for the running
    /// deck. Rows with blank names are dropped and duplicates collapse.
    func commitSecrets() {
        do {
            secrets = secretsStore.normalized(secrets)
            try secretsStore.save(secrets)
            secretsError = nil
            pushSecretsToExecutor()
        } catch {
            secretsError = error.localizedDescription
        }
    }

    func importSecrets(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            secretsError = "Could not read \(url.lastPathComponent)."
            return
        }
        let imported = SecretsStore.parseEnvFile(text)
        guard !imported.isEmpty else {
            secretsError = "No KEY=VALUE lines found in \(url.lastPathComponent)."
            return
        }
        // Existing rows keep their position; an imported key updates the matching
        // row in place, otherwise it is appended. `normalized` drops blanks and
        // collapses any remaining duplicates.
        var merged = secrets
        for item in imported {
            if let index = merged.firstIndex(where: { $0.name == item.name }) {
                merged[index].value = item.value
            } else {
                merged.append(item)
            }
        }
        secrets = secretsStore.normalized(merged)
        secretsError = nil
    }

    func exportSecrets(to url: URL) {
        let text = secretsStore.envFileText(for: secrets)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            secretsError = nil
        } catch {
            secretsError = error.localizedDescription
        }
    }

    private func pushSecretsToExecutor() {
        var environment: [String: String] = [:]
        for secret in secretsStore.normalized(secrets) {
            environment[secret.name] = secret.value
        }
        executor.setSecrets(environment)
    }
}
