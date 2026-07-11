import Foundation

public enum ScriptLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case python
    case bash
    case zsh
    case appleScript

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .python: "Python"
        case .bash: "Bash"
        case .zsh: "Zsh"
        case .appleScript: "AppleScript"
        }
    }
}

public struct ExecutionOptions: Codable, Equatable, Sendable {
    public var workingDirectory: String?
    public var environment: [String: String]
    public var timeoutSeconds: Double?
    public var allowConcurrent: Bool

    public init(
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeoutSeconds: Double? = nil,
        allowConcurrent: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
        self.allowConcurrent = allowConcurrent
    }

    private enum CodingKeys: String, CodingKey {
        case workingDirectory, environment, timeoutSeconds, allowConcurrent
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        timeoutSeconds = try values.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        allowConcurrent = try values.decodeIfPresent(Bool.self, forKey: .allowConcurrent) ?? false
    }
}

public struct ApplicationReference: Codable, Equatable, Sendable {
    public var name: String
    public var bundleIdentifier: String?
    public var path: String?

    public init(name: String, bundleIdentifier: String? = nil, path: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }
}

public struct CommandAction: Codable, Equatable, Sendable {
    public var source: String
    public var shell: ScriptLanguage
    public var options: ExecutionOptions

    public init(
        source: String = "",
        shell: ScriptLanguage = .automatic,
        options: ExecutionOptions = .init()
    ) {
        self.source = source
        self.shell = shell
        self.options = options
    }
}

public struct InlineScriptAction: Codable, Equatable, Sendable {
    public var source: String
    public var language: ScriptLanguage
    public var options: ExecutionOptions

    public init(
        source: String = "",
        language: ScriptLanguage = .automatic,
        options: ExecutionOptions = .init()
    ) {
        self.source = source
        self.language = language
        self.options = options
    }
}

public struct ScriptFileAction: Codable, Equatable, Sendable {
    public var path: String
    public var language: ScriptLanguage
    public var arguments: [String]
    public var options: ExecutionOptions

    public init(
        path: String = "",
        language: ScriptLanguage = .automatic,
        arguments: [String] = [],
        options: ExecutionOptions = .init()
    ) {
        self.path = path
        self.language = language
        self.arguments = arguments
        self.options = options
    }
}

public enum KeyTrigger: Equatable, Sendable {
    case none
    case launchApplication(ApplicationReference)
    case shellCommand(CommandAction)
    case inlineScript(InlineScriptAction)
    case scriptFile(ScriptFileAction)
    case switchPage(String)
    case sleepDeck

    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case none
        case launchApplication
        case shellCommand
        case inlineScript
        case scriptFile
        case switchPage
        case sleepDeck

        public var id: Self { self }

        public var displayName: String {
            switch self {
            case .none: "No Action"
            case .launchApplication: "Open Application"
            case .shellCommand: "Shell Command"
            case .inlineScript: "Inline Code"
            case .scriptFile: "Script File"
            case .switchPage: "Switch Page"
            case .sleepDeck: "Sleep Deck"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .none: .none
        case .launchApplication: .launchApplication
        case .shellCommand: .shellCommand
        case .inlineScript: .inlineScript
        case .scriptFile: .scriptFile
        case .switchPage: .switchPage
        case .sleepDeck: .sleepDeck
        }
    }

    public static func blank(_ kind: Kind) -> KeyTrigger {
        switch kind {
        case .none: .none
        case .launchApplication: .launchApplication(.init(name: ""))
        case .shellCommand: .shellCommand(.init())
        case .inlineScript: .inlineScript(.init())
        case .scriptFile: .scriptFile(.init())
        case .switchPage: .switchPage("next")
        case .sleepDeck: .sleepDeck
        }
    }
}

extension KeyTrigger: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, application, command, script, file, target
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .type)
        switch kind {
        case .none:
            self = .none
        case .launchApplication:
            self = .launchApplication(try values.decode(ApplicationReference.self, forKey: .application))
        case .shellCommand:
            self = .shellCommand(try values.decode(CommandAction.self, forKey: .command))
        case .inlineScript:
            self = .inlineScript(try values.decode(InlineScriptAction.self, forKey: .script))
        case .scriptFile:
            self = .scriptFile(try values.decode(ScriptFileAction.self, forKey: .file))
        case .switchPage:
            self = .switchPage(try values.decode(String.self, forKey: .target))
        case .sleepDeck:
            self = .sleepDeck
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .type)
        switch self {
        case .none, .sleepDeck:
            break
        case let .launchApplication(value):
            try values.encode(value, forKey: .application)
        case let .shellCommand(value):
            try values.encode(value, forKey: .command)
        case let .inlineScript(value):
            try values.encode(value, forKey: .script)
        case let .scriptFile(value):
            try values.encode(value, forKey: .file)
        case let .switchPage(value):
            try values.encode(value, forKey: .target)
        }
    }
}

public struct KeyConfiguration: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var position: Int
    public var label: String
    public var icon: String?
    public var image: String?
    public var color: String
    public var level: Double?
    public var trigger: KeyTrigger

    public init(
        id: UUID = UUID(),
        position: Int,
        label: String = "",
        icon: String? = nil,
        image: String? = nil,
        color: String = "#2c3e50",
        level: Double? = nil,
        trigger: KeyTrigger = .none
    ) {
        self.id = id
        self.position = position
        self.label = label
        self.icon = icon
        self.image = image
        self.color = color
        self.level = level
        self.trigger = trigger
    }

    private enum CodingKeys: String, CodingKey {
        case id, position, label, icon, image, color, level, trigger
        case app, command, action
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        position = try values.decode(Int.self, forKey: .position)
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
        icon = try values.decodeIfPresent(String.self, forKey: .icon)
        image = try values.decodeIfPresent(String.self, forKey: .image)
        if let colorString = try? values.decode(String.self, forKey: .color) {
            color = colorString
        } else if let components = try? values.decode([Int].self, forKey: .color), components.count == 3 {
            color = String(format: "#%02x%02x%02x", components[0], components[1], components[2])
        } else {
            color = "#2c3e50"
        }
        level = try values.decodeIfPresent(Double.self, forKey: .level)

        if let typed = try values.decodeIfPresent(KeyTrigger.self, forKey: .trigger) {
            trigger = typed
        } else if let command = try values.decodeIfPresent(String.self, forKey: .command) {
            trigger = .shellCommand(.init(source: command))
        } else if let app = try values.decodeIfPresent(String.self, forKey: .app) {
            trigger = .launchApplication(.init(name: app))
        } else if let action = try values.decodeIfPresent(String.self, forKey: .action) {
            if action == "sleep" {
                trigger = .sleepDeck
            } else if action.hasPrefix("page:") {
                trigger = .switchPage(String(action.dropFirst("page:".count)))
            } else {
                trigger = .none
            }
        } else {
            trigger = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(position, forKey: .position)
        if !label.isEmpty { try values.encode(label, forKey: .label) }
        try values.encodeIfPresent(icon, forKey: .icon)
        try values.encodeIfPresent(image, forKey: .image)
        try values.encode(color, forKey: .color)
        try values.encodeIfPresent(level, forKey: .level)
        if trigger != .none { try values.encode(trigger, forKey: .trigger) }
    }
}

public struct DeckPage: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var keys: [KeyConfiguration]

    public init(id: UUID = UUID(), name: String = "main", keys: [KeyConfiguration] = []) {
        self.id = id
        self.name = name
        self.keys = keys
    }

    private enum CodingKeys: String, CodingKey { case id, name, keys }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "main"
        keys = try values.decodeIfPresent([KeyConfiguration].self, forKey: .keys) ?? []
    }
}

public struct DeckSettings: Codable, Equatable, Sendable {
    public var brightness: Int
    public var keepaliveSeconds: Double
    public var clearOnExit: Bool
    public var environmentFile: String?
    public var resourceRoot: String?
    /// Idle time before the deck displays turn off automatically; nil never
    /// sleeps. Any hardware key press counts as activity and wakes the deck.
    public var screenOffAfterSeconds: Double?

    public init(
        brightness: Int = 80,
        keepaliveSeconds: Double = 2,
        clearOnExit: Bool = true,
        environmentFile: String? = nil,
        resourceRoot: String? = nil,
        screenOffAfterSeconds: Double? = nil
    ) {
        self.brightness = brightness
        self.keepaliveSeconds = keepaliveSeconds
        self.clearOnExit = clearOnExit
        self.environmentFile = environmentFile
        self.resourceRoot = resourceRoot
        self.screenOffAfterSeconds = screenOffAfterSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case brightness
        case keepaliveSeconds = "keepalive_seconds"
        case clearOnExit = "clear_on_exit"
        case environmentFile = "env_file"
        case resourceRoot = "resource_root"
        case screenOffAfterSeconds = "screen_off_seconds"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        brightness = try values.decodeIfPresent(Int.self, forKey: .brightness) ?? 80
        keepaliveSeconds = try values.decodeIfPresent(Double.self, forKey: .keepaliveSeconds) ?? 2
        clearOnExit = try values.decodeIfPresent(Bool.self, forKey: .clearOnExit) ?? true
        environmentFile = try values.decodeIfPresent(String.self, forKey: .environmentFile)
        resourceRoot = try values.decodeIfPresent(String.self, forKey: .resourceRoot)
        screenOffAfterSeconds = try values.decodeIfPresent(Double.self, forKey: .screenOffAfterSeconds)
    }
}

public struct DeckConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var settings: DeckSettings
    public var pages: [DeckPage]

    public init(
        version: Int = currentVersion,
        settings: DeckSettings = .init(),
        pages: [DeckPage] = [.init()]
    ) {
        self.version = version
        self.settings = settings
        self.pages = pages.isEmpty ? [.init()] : pages
    }

    private enum CodingKeys: String, CodingKey { case version, settings, pages }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        settings = try values.decodeIfPresent(DeckSettings.self, forKey: .settings) ?? .init()
        pages = try values.decodeIfPresent([DeckPage].self, forKey: .pages) ?? [.init()]
        if pages.isEmpty { pages = [.init()] }
    }

    public func upgraded() -> DeckConfiguration {
        var copy = self
        copy.version = Self.currentVersion
        return copy
    }
}
