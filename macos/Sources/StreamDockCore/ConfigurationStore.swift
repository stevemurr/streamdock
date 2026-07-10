import Foundation
import Yams

public enum ConfigurationError: LocalizedError {
    case unsupportedFormat(String)
    case malformedLegacyTOML(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(ext):
            "Unsupported configuration format: \(ext)"
        case let .malformedLegacyTOML(message):
            "Malformed legacy TOML: \(message)"
        }
    }
}

public struct ConfigurationStore: Sendable {
    public init() {}

    public static var applicationSupportURL: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return root.appendingPathComponent("StreamDock", isDirectory: true)
    }

    public static var defaultConfigurationURL: URL {
        applicationSupportURL.appendingPathComponent("config.yaml")
    }

    public static var legacyConfigurationURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".config/streamdock/config.yaml"),
            home.appendingPathComponent(".config/streamdock/config.yml"),
            home.appendingPathComponent(".config/streamdock/config.toml"),
        ]
    }

    public func load(from url: URL) throws -> DeckConfiguration {
        switch url.pathExtension.lowercased() {
        case "yaml", "yml":
            let text = try String(contentsOf: url, encoding: .utf8)
            return try YAMLDecoder().decode(DeckConfiguration.self, from: text)
        case "toml":
            let text = try String(contentsOf: url, encoding: .utf8)
            return try LegacyTOMLDecoder.decode(text)
        default:
            throw ConfigurationError.unsupportedFormat(url.pathExtension)
        }
    }

    public func loadInitial() throws -> (configuration: DeckConfiguration, source: URL?) {
        let candidates = [Self.defaultConfigurationURL] + Self.legacyConfigurationURLs
        if let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            var configuration = try load(from: source)
            if source != Self.defaultConfigurationURL, configuration.settings.resourceRoot == nil {
                configuration.settings.resourceRoot = source.deletingLastPathComponent().path
            }
            return (configuration, source)
        }
        return (.init(), nil)
    }

    public func save(_ configuration: DeckConfiguration, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = YAMLEncoder()
        let text = try encoder.encode(configuration.upgraded())
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: .atomic)
    }
}

private enum LegacyTOMLDecoder {
    private enum Section { case root, settings, key }

    static func decode(_ text: String) throws -> DeckConfiguration {
        var section = Section.root
        var settings = DeckSettings()
        var keys: [KeyConfiguration] = []
        var current: [String: Any] = [:]

        func makeKey(_ values: [String: Any]) throws -> KeyConfiguration {
            guard let position = values["position"] as? Int else {
                throw ConfigurationError.malformedLegacyTOML("a [[keys]] entry has no position")
            }
            let trigger: KeyTrigger
            if let command = values["command"] as? String {
                trigger = .shellCommand(.init(source: command))
            } else if let app = values["app"] as? String {
                trigger = .launchApplication(.init(name: app))
            } else if let action = values["action"] as? String, action == "sleep" {
                trigger = .sleepDeck
            } else if let action = values["action"] as? String, action.hasPrefix("page:") {
                trigger = .switchPage(String(action.dropFirst(5)))
            } else {
                trigger = .none
            }
            return KeyConfiguration(
                position: position,
                label: values["label"] as? String ?? "",
                icon: values["icon"] as? String,
                image: values["image"] as? String,
                color: values["color"] as? String ?? "#2c3e50",
                level: values["level"] as? Double,
                trigger: trigger
            )
        }

        for (lineNumber, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line == "[settings]" {
                if section == .key, !current.isEmpty { keys.append(try makeKey(current)) }
                current = [:]
                section = .settings
                continue
            }
            if line == "[[keys]]" {
                if section == .key, !current.isEmpty { keys.append(try makeKey(current)) }
                current = [:]
                section = .key
                continue
            }
            guard let split = splitAssignment(line) else {
                throw ConfigurationError.malformedLegacyTOML("line \(lineNumber + 1): \(line)")
            }
            let value = parseScalar(split.value)
            if section == .settings {
                switch split.key {
                case "brightness": settings.brightness = value as? Int ?? settings.brightness
                case "keepalive_seconds": settings.keepaliveSeconds = numeric(value) ?? settings.keepaliveSeconds
                case "clear_on_exit": settings.clearOnExit = value as? Bool ?? settings.clearOnExit
                case "env_file": settings.environmentFile = value as? String
                default: break
                }
            } else if section == .key {
                current[split.key] = value
            }
        }
        if section == .key, !current.isEmpty { keys.append(try makeKey(current)) }
        return DeckConfiguration(version: 1, settings: settings, pages: [.init(name: "main", keys: keys)])
    }

    private static func numeric(_ value: Any) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    private static func splitAssignment(_ line: String) -> (key: String, value: String)? {
        guard let index = line.firstIndex(of: "=") else { return nil }
        let key = line[..<index].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\", quote == "\"" { escaped = true; continue }
            if character == "\"" || character == "'" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func parseScalar(_ raw: String) -> Any {
        if raw == "true" { return true }
        if raw == "false" { return false }
        if let integer = Int(raw) { return integer }
        if let number = Double(raw) { return number }
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") {
            if let data = raw.data(using: .utf8),
               let value = try? JSONDecoder().decode(String.self, from: data) {
                return value
            }
        }
        if raw.hasPrefix("'") && raw.hasSuffix("'") { return String(raw.dropFirst().dropLast()) }
        return raw
    }
}
