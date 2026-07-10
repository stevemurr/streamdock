import CryptoKit
import Foundation

/// A single named secret that is injected into the environment of every action
/// the deck runs (e.g. `HA_TOKEN`, `OPENAI_API_KEY`).
public struct SecretItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

public enum SecretsError: LocalizedError {
    case keychain(OSStatus)
    case decryptionFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        case .decryptionFailed:
            return "The secrets store could not be decrypted. The encryption key may have changed."
        case .encodingFailed:
            return "The secrets could not be encoded."
        }
    }
}

/// Supplies the symmetric key used to encrypt the secrets file. The default
/// implementation persists the key in the login Keychain; tests inject a fixed
/// key so they never touch the Keychain.
public protocol SecretsKeyProviding: Sendable {
    func loadOrCreateKey() throws -> SymmetricKey
}

/// A 256-bit key stored as a generic-password item in the login Keychain. The
/// key is created on first use and reused thereafter, so the encrypted secrets
/// file is worthless without access to this user's unlocked Keychain.
public struct KeychainSecretsKeyProvider: SecretsKeyProviding {
    private let service: String
    private let account: String

    public init(
        service: String = "com.stevemurr.StreamDock",
        account: String = "secrets-master-key"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try read() {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try store(data)
        return key
    }

    private func read() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SecretsError.keychain(status)
        }
        return data
    }

    private func store(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw SecretsError.keychain(status)
        }
    }
}

/// A key provider backed by an in-memory value. Used by tests and previews so
/// they exercise the real AES-GCM path without depending on the Keychain.
public struct StaticSecretsKeyProvider: SecretsKeyProviding {
    private let keyData: Data

    public init(keyData: Data) {
        self.keyData = keyData
    }

    public init(seed: String) {
        keyData = Data(SHA256.hash(data: Data(seed.utf8)))
    }

    public func loadOrCreateKey() throws -> SymmetricKey {
        SymmetricKey(data: keyData)
    }
}

/// Persists user secrets as an AES-GCM encrypted blob on disk. The plaintext
/// (a list of name/value pairs) never touches the config YAML, and the file is
/// unreadable without the Keychain-held key.
public final class SecretsStore: @unchecked Sendable {
    private let fileURL: URL
    private let keyProvider: SecretsKeyProviding

    public init(
        fileURL: URL = SecretsStore.defaultFileURL,
        keyProvider: SecretsKeyProviding = KeychainSecretsKeyProvider()
    ) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
    }

    public static var defaultFileURL: URL {
        ConfigurationStore.applicationSupportURL.appendingPathComponent("secrets.dat")
    }

    public var hasStoredSecrets: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    private struct Record: Codable {
        var name: String
        var value: String
    }

    public func load() throws -> [SecretItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let blob = try Data(contentsOf: fileURL)
        let key = try keyProvider.loadOrCreateKey()
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: blob)
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            throw SecretsError.decryptionFailed
        }
        let records = try JSONDecoder().decode([Record].self, from: plaintext)
        return records.map { SecretItem(name: $0.name, value: $0.value) }
    }

    public func save(_ items: [SecretItem]) throws {
        let records = normalized(items).map { Record(name: $0.name, value: $0.value) }
        let plaintext = try JSONEncoder().encode(records)
        let key = try keyProvider.loadOrCreateKey()
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw SecretsError.encodingFailed }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try combined.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    /// Decrypts the store and returns a name→value dictionary, or an empty map
    /// if the file is absent or unreadable. Used to seed the action environment.
    public func environment() -> [String: String] {
        guard let items = try? load() else { return [:] }
        var result: [String: String] = [:]
        for item in items where !item.name.isEmpty {
            result[item.name] = item.value
        }
        return result
    }

    /// Trims names, drops nameless rows, and keeps the last value for duplicate
    /// names so the encrypted store and the injected environment always agree.
    public func normalized(_ items: [SecretItem]) -> [SecretItem] {
        var seen: [String: Int] = [:]
        var result: [SecretItem] = []
        for item in items {
            let name = item.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let cleaned = SecretItem(id: item.id, name: name, value: item.value)
            if let index = seen[name] {
                result[index] = cleaned
            } else {
                seen[name] = result.count
                result.append(cleaned)
            }
        }
        return result
    }

    // MARK: - .env interchange

    /// Parses `KEY=VALUE` lines (optionally `export`-prefixed, `#`-commented, or
    /// quoted) so a user can pull an existing dotenv file into the store.
    public static func parseEnvFile(_ text: String) -> [SecretItem] {
        var items: [SecretItem] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !name.isEmpty else { continue }
            items.append(SecretItem(name: name, value: value))
        }
        return items
    }

    /// Renders the store back to dotenv text so it can be exported and sourced
    /// into a shell (`set -a; source secrets.env`).
    public func envFileText(for items: [SecretItem]) -> String {
        let lines = normalized(items).map { item -> String in
            "\(item.name)=\(Self.quoteIfNeeded(item.value))"
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let needsQuoting = value.contains(where: { " \t\"'$#=\\".contains($0) }) || value.isEmpty
        guard needsQuoting else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
