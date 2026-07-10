import Foundation

/// How many chained key presses the control server allows before assuming a
/// macro loop (key A presses key B presses key A …) and refusing the request.
public let maxPressDepth = 8

/// The commands understood by the control socket. Kept as plain strings so
/// unknown commands decode fine and get a clean `ok:false` response.
public enum ControlCommand {
    public static let press = "press"
    public static let switchPage = "switch-page"
    public static let list = "list"
    public static let status = "status"
}

/// One request line sent to the control socket (JSON-lines: a single JSON
/// object terminated by `\n`).
public struct ControlRequest: Codable, Equatable, Sendable {
    /// "press" | "switch-page" | "list" | "status"
    public var command: String
    /// Key reference: position digits ("4") or a label ("Amber").
    public var key: String?
    /// Page name for `switch-page`, or the page a `press` key lives on.
    public var page: String?
    /// Press-chain depth of the requesting action (loop guard).
    public var depth: Int?

    public init(command: String, key: String? = nil, page: String? = nil, depth: Int? = nil) {
        self.command = command
        self.key = key
        self.page = page
        self.depth = depth
    }
}

/// One key in a `list` response payload.
public struct ControlKeyInfo: Codable, Equatable, Sendable {
    public var position: Int
    public var label: String
    public var page: String

    public init(position: Int, label: String, page: String) {
        self.position = position
        self.label = label
        self.page = page
    }
}

/// One response line sent back over the control socket.
public struct ControlResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var detail: String?
    public var error: String?
    /// Payload for the `list` command.
    public var keys: [ControlKeyInfo]?

    public init(ok: Bool, detail: String? = nil, error: String? = nil, keys: [ControlKeyInfo]? = nil) {
        self.ok = ok
        self.detail = detail
        self.error = error
        self.keys = keys
    }

    public static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

/// JSON-lines encoding shared by the app, the CLI, and the tests.
public enum ControlWire {
    public static func encodeLine<Value: Encodable>(_ value: Value) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from line: Data) throws -> Value {
        try JSONDecoder().decode(type, from: line)
    }
}

/// Pure key-reference resolution: turns "4" / "Amber" (+ optional page) into a
/// concrete key on a concrete page of a configuration.
public enum ControlKeyResolver {
    /// - Parameters:
    ///   - reference: position digits ("4") or a case-insensitive label.
    ///   - requestedPage: explicit page name from the request (case-insensitive),
    ///     or nil to use `activePage`, falling back to the first page.
    ///   - activePage: the runtime's currently displayed page name, if any.
    /// - Returns: the matching key and the page it lives on, or nil on a miss.
    public static func resolve(
        reference: String,
        page requestedPage: String? = nil,
        activePage: String? = nil,
        in configuration: DeckConfiguration
    ) -> (key: KeyConfiguration, page: DeckPage)? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let targetPage: DeckPage?
        if let requestedPage {
            targetPage = configuration.pages.first {
                $0.name.caseInsensitiveCompare(requestedPage) == .orderedSame
            }
        } else if let activePage {
            targetPage = configuration.pages.first { $0.name == activePage } ?? configuration.pages.first
        } else {
            targetPage = configuration.pages.first
        }
        guard let page = targetPage else { return nil }

        if let position = Int(trimmed) {
            guard let key = page.keys.first(where: { $0.position == position }) else { return nil }
            return (key, page)
        }
        guard let key = page.keys.first(where: {
            $0.label.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return nil }
        return (key, page)
    }
}

// MARK: - CLI request building

public enum ControlCLIError: LocalizedError, Equatable {
    case usage(String)

    public var errorDescription: String? {
        switch self {
        case let .usage(message): message
        }
    }
}

/// Builds `ControlRequest`s from `streamdock` command-line arguments. Lives in
/// the core module (not the executable) so it is unit-testable.
public enum ControlCLI {
    public static let usageText = """
    usage: streamdock press <key> [--page NAME]   press a key by position or label
           streamdock page <name|next|prev>       switch the active page
           streamdock list                        list every key (page, position, label)
           streamdock status                      show the device status line
    """

    public static func makeRequest(arguments: [String], depth: Int) throws -> ControlRequest {
        guard let command = arguments.first else {
            throw ControlCLIError.usage(usageText)
        }
        switch command {
        case "press":
            var key: String?
            var page: String?
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--page" {
                    guard index + 1 < arguments.count else {
                        throw ControlCLIError.usage("--page requires a page name")
                    }
                    page = arguments[index + 1]
                    index += 2
                } else if key == nil {
                    key = argument
                    index += 1
                } else {
                    throw ControlCLIError.usage("unexpected argument: \(argument)\n\(usageText)")
                }
            }
            guard let key, !key.isEmpty else {
                throw ControlCLIError.usage("press requires a key position or label\n\(usageText)")
            }
            return ControlRequest(command: ControlCommand.press, key: key, page: page, depth: depth)
        case "page":
            guard arguments.count == 2, !arguments[1].isEmpty else {
                throw ControlCLIError.usage("page requires a target: a page name, next, or prev\n\(usageText)")
            }
            return ControlRequest(command: ControlCommand.switchPage, page: arguments[1], depth: depth)
        case "list":
            guard arguments.count == 1 else {
                throw ControlCLIError.usage("list takes no arguments\n\(usageText)")
            }
            return ControlRequest(command: ControlCommand.list, depth: depth)
        case "status":
            guard arguments.count == 1 else {
                throw ControlCLIError.usage("status takes no arguments\n\(usageText)")
            }
            return ControlRequest(command: ControlCommand.status, depth: depth)
        default:
            throw ControlCLIError.usage("unknown command: \(command)\n\(usageText)")
        }
    }
}
