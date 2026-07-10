import Foundation

/// Classification of a highlighted span of source code.
public enum SyntaxTokenKind: String, CaseIterable, Hashable, Sendable {
    case keyword
    case string
    case comment
    case number
    case variable
    case functionName
    case decorator
    /// Shell option flags such as `-x` or `--long-option`.
    case flag
    /// Command substitution (`$(…)`, backticks) and string interpolation
    /// fields (`{…}` inside Python f-strings).
    case commandSubstitution
}

/// A classified span of source code. Ranges are expressed in UTF-16 units so
/// AppKit (`NSTextStorage`/`NSAttributedString`) can consume them directly.
public struct SyntaxToken: Equatable, Sendable {
    public let range: NSRange
    public let kind: SyntaxTokenKind

    public init(range: NSRange, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// A rule-table driven source tokenizer.
///
/// The tokenizer scans left-to-right and consumes *exclusive regions* first
/// (comments, strings, command substitutions), so a `#` inside a string is
/// never a comment and a quote inside a comment never opens a string. The
/// remaining gaps of plain code are then matched against regex token
/// patterns (keywords, numbers, variables, flags, …). Strings may declare
/// nested interior highlighting (shell `$VAR` inside double quotes, Python
/// f-string `{fields}`).
///
/// Languages are defined purely as data (`RuleSet`); adding a language is one
/// more table entry plus a one-line case in `tokens(for:language:)`.
public enum SyntaxHighlighter {
    // MARK: - Rule model

    /// A line comment such as `# …` or `-- …`.
    public struct LineCommentRule: Sendable {
        public var prefix: String
        /// When true, the prefix only opens a comment at the start of a line
        /// or after whitespace/`;`/`|`/`&`/`(` (shell semantics: `foo#bar` is
        /// not a comment, `echo foo # bar` is).
        public var requiresLeadingBoundary: Bool

        public init(prefix: String, requiresLeadingBoundary: Bool = false) {
            self.prefix = prefix
            self.requiresLeadingBoundary = requiresLeadingBoundary
        }
    }

    /// A block comment such as AppleScript `(* … *)`.
    public struct BlockCommentRule: Sendable {
        public var open: String
        public var close: String
        public var nestable: Bool

        public init(open: String, close: String, nestable: Bool = false) {
            self.open = open
            self.close = close
            self.nestable = nestable
        }
    }

    /// What to additionally highlight inside a string region.
    public enum StringInterior: Equatable, Sendable {
        case none
        /// `$VAR` / `${VAR}` become `.variable` tokens (shell double quotes).
        case shellVariables
        /// `{field}` spans become `.commandSubstitution` tokens when the
        /// string carried an `f`/`F` prefix (Python f-strings).
        case formatFieldsWhenFPrefixed
    }

    /// A string literal delimiter pair. Rules are tried in order, so put
    /// longer delimiters (`"""`) before shorter ones (`"`).
    public struct StringRule: Sendable {
        public var open: String
        public var close: String
        public var spansLines: Bool
        /// Escape character honored inside the string (`\` usually; `nil`
        /// for shell single quotes, which have no escapes).
        public var escape: Character?
        /// Allow Python-style prefix letters (`r`, `b`, `u`, `f` and pairs)
        /// immediately before the opening delimiter.
        public var allowsPrefixLetters: Bool
        public var interior: StringInterior

        public init(
            open: String,
            close: String,
            spansLines: Bool,
            escape: Character? = "\\",
            allowsPrefixLetters: Bool = false,
            interior: StringInterior = .none
        ) {
            self.open = open
            self.close = close
            self.spansLines = spansLines
            self.escape = escape
            self.allowsPrefixLetters = allowsPrefixLetters
            self.interior = interior
        }
    }

    /// A command substitution region such as `$(…)` or backticks.
    public struct SubstitutionRule: Sendable {
        public var open: String
        public var close: String
        /// Track nesting of the close delimiter's counterpart (the last
        /// character of `open`), so `$(a $(b) c)` is one region.
        public var balanced: Bool
        public var escape: Character?

        public init(open: String, close: String, balanced: Bool, escape: Character? = "\\") {
            self.open = open
            self.close = close
            self.balanced = balanced
            self.escape = escape
        }
    }

    /// A regex applied only to code *outside* strings/comments/substitutions.
    /// Patterns run in order; earlier matches claim their range and later
    /// patterns cannot overlap them. Keywords always run last.
    public struct TokenPattern: Sendable {
        public var pattern: String
        public var kind: SyntaxTokenKind
        /// Regex capture group that becomes the token (0 = whole match).
        public var captureGroup: Int

        public init(pattern: String, kind: SyntaxTokenKind, captureGroup: Int = 0) {
            self.pattern = pattern
            self.kind = kind
            self.captureGroup = captureGroup
        }
    }

    /// Everything the tokenizer needs to know about one language.
    public struct RuleSet: Sendable {
        public var lineComments: [LineCommentRule]
        public var blockComments: [BlockCommentRule]
        public var strings: [StringRule]
        public var substitutions: [SubstitutionRule]
        public var keywords: Set<String>
        public var caseInsensitiveKeywords: Bool
        public var patterns: [TokenPattern]

        public init(
            lineComments: [LineCommentRule] = [],
            blockComments: [BlockCommentRule] = [],
            strings: [StringRule] = [],
            substitutions: [SubstitutionRule] = [],
            keywords: Set<String> = [],
            caseInsensitiveKeywords: Bool = false,
            patterns: [TokenPattern] = []
        ) {
            self.lineComments = lineComments
            self.blockComments = blockComments
            self.strings = strings
            self.substitutions = substitutions
            self.keywords = keywords
            self.caseInsensitiveKeywords = caseInsensitiveKeywords
            self.patterns = patterns
        }
    }

    // MARK: - Shared patterns

    /// Word-bounded numbers: `foo123` yields no number token.
    static let numberPattern =
        #"\b(?:0[xX][0-9A-Fa-f_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#

    /// `$VAR`, `${VAR…}`, and special parameters (`$?`, `$#`, `$0`…`$9`, …).
    static let shellVariablePattern =
        #"(?<!\\)(?:\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?!*$-])"#

    /// `{field}` inside f-strings; `{{` / `}}` escapes are skipped.
    static let formatFieldPattern = #"(?<!\{)\{(?!\{)[^{}\n]*\}"#

    // MARK: - Language tables

    public static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "case", "class",
        "continue", "def", "del", "elif", "else", "except", "False",
        "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "match", "None", "nonlocal", "not", "or", "pass", "raise",
        "return", "True", "try", "while", "with", "yield",
    ]

    public static let shellKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for",
        "function", "if", "in", "local", "readonly", "select", "then",
        "typeset", "until", "while",
    ]

    public static let appleScriptKeywords: Set<String> = [
        "tell", "end", "set", "to", "of", "on", "if", "then", "else",
        "repeat", "return", "activate", "property", "script", "try", "error",
        "display",
    ]

    public static let pythonRuleSet = RuleSet(
        lineComments: [LineCommentRule(prefix: "#")],
        strings: [
            StringRule(
                open: "\"\"\"", close: "\"\"\"", spansLines: true,
                allowsPrefixLetters: true, interior: .formatFieldsWhenFPrefixed
            ),
            StringRule(
                open: "'''", close: "'''", spansLines: true,
                allowsPrefixLetters: true, interior: .formatFieldsWhenFPrefixed
            ),
            StringRule(
                open: "\"", close: "\"", spansLines: false,
                allowsPrefixLetters: true, interior: .formatFieldsWhenFPrefixed
            ),
            StringRule(
                open: "'", close: "'", spansLines: false,
                allowsPrefixLetters: true, interior: .formatFieldsWhenFPrefixed
            ),
        ],
        keywords: pythonKeywords,
        patterns: [
            TokenPattern(
                pattern: #"^[ \t]*(@[A-Za-z_][A-Za-z0-9_.]*)"#,
                kind: .decorator, captureGroup: 1
            ),
            TokenPattern(
                pattern: #"\b(?:def|class)[ \t]+([A-Za-z_][A-Za-z0-9_]*)"#,
                kind: .functionName, captureGroup: 1
            ),
            TokenPattern(pattern: numberPattern, kind: .number),
        ]
    )

    public static let shellRuleSet = RuleSet(
        lineComments: [LineCommentRule(prefix: "#", requiresLeadingBoundary: true)],
        strings: [
            StringRule(open: "\"", close: "\"", spansLines: true, interior: .shellVariables),
            StringRule(open: "'", close: "'", spansLines: true, escape: nil),
        ],
        substitutions: [
            SubstitutionRule(open: "$(", close: ")", balanced: true),
            SubstitutionRule(open: "`", close: "`", balanced: false),
        ],
        keywords: shellKeywords,
        patterns: [
            TokenPattern(pattern: shellVariablePattern, kind: .variable),
            TokenPattern(
                pattern: #"(?:^|[\s;|&(])(--?[A-Za-z0-9][A-Za-z0-9._-]*)"#,
                kind: .flag, captureGroup: 1
            ),
            TokenPattern(
                pattern: #"\bfunction[ \t]+([A-Za-z_][A-Za-z0-9_]*)"#,
                kind: .functionName, captureGroup: 1
            ),
            TokenPattern(
                pattern: #"^[ \t]*([A-Za-z_][A-Za-z0-9_]*)(?=[ \t]*\(\))"#,
                kind: .functionName, captureGroup: 1
            ),
            TokenPattern(pattern: numberPattern, kind: .number),
        ]
    )

    /// AppleScript is not yet a `ScriptLanguage` case; this rule set is ready
    /// so wiring it up is a one-line `tokens(for:ruleSet:)` call at merge.
    public static let appleScriptRuleSet = RuleSet(
        lineComments: [LineCommentRule(prefix: "--")],
        blockComments: [BlockCommentRule(open: "(*", close: "*)", nestable: true)],
        strings: [StringRule(open: "\"", close: "\"", spansLines: false)],
        keywords: appleScriptKeywords,
        caseInsensitiveKeywords: true,
        patterns: [TokenPattern(pattern: numberPattern, kind: .number)]
    )

    // MARK: - Tokenizing

    /// Tokenizes `source` using the rule set for `language`.
    ///
    /// The result is sorted by location; when ranges nest (a `$VAR` inside a
    /// double-quoted string), the enclosing token precedes the nested one, so
    /// applying attributes in array order yields correct nesting.
    public static func tokens(for source: String, language: ScriptLanguage) -> [SyntaxToken] {
        switch language {
        case .python:
            return tokens(for: source, ruleSet: pythonRuleSet)
        case .bash, .zsh, .automatic:
            return tokens(for: source, ruleSet: shellRuleSet)
        case .appleScript:
            return tokens(for: source, ruleSet: appleScriptRuleSet)
        }
    }

    /// Tokenizes `source` with an explicit rule set (e.g. `appleScriptRuleSet`).
    public static func tokens(for source: String, ruleSet: RuleSet) -> [SyntaxToken] {
        var tokenizer = Tokenizer(source: source, ruleSet: ruleSet)
        return tokenizer.run()
    }
}

// MARK: - Implementation

private struct Tokenizer {
    private let sourceString: String
    private let text: [UInt16]
    private let lineComments: [(prefix: [UInt16], requiresLeadingBoundary: Bool)]
    private let blockComments: [(open: [UInt16], close: [UInt16], nestable: Bool)]
    private let strings: [(
        open: [UInt16], close: [UInt16], spansLines: Bool, escape: UInt16?,
        allowsPrefixLetters: Bool, interior: SyntaxHighlighter.StringInterior
    )]
    private let substitutions: [(open: [UInt16], close: [UInt16], balanced: Bool, escape: UInt16?)]
    private let codePatterns: [(regex: NSRegularExpression, kind: SyntaxTokenKind, captureGroup: Int)]
    private let shellVariableRegex: NSRegularExpression?
    private let formatFieldRegex: NSRegularExpression?
    private let anyPrefixLetters: Bool
    private var tokens: [SyntaxToken] = []

    init(source: String, ruleSet: SyntaxHighlighter.RuleSet) {
        sourceString = source
        text = Array(source.utf16)
        lineComments = ruleSet.lineComments.map {
            (Array($0.prefix.utf16), $0.requiresLeadingBoundary)
        }
        blockComments = ruleSet.blockComments.map {
            (Array($0.open.utf16), Array($0.close.utf16), $0.nestable)
        }
        strings = ruleSet.strings.map { rule in
            (
                Array(rule.open.utf16), Array(rule.close.utf16), rule.spansLines,
                rule.escape.flatMap { String($0).utf16.first },
                rule.allowsPrefixLetters, rule.interior
            )
        }
        substitutions = ruleSet.substitutions.map {
            (
                Array($0.open.utf16), Array($0.close.utf16), $0.balanced,
                $0.escape.flatMap { String($0).utf16.first }
            )
        }
        anyPrefixLetters = ruleSet.strings.contains(where: \.allowsPrefixLetters)

        var patterns: [(NSRegularExpression, SyntaxTokenKind, Int)] = []
        for pattern in ruleSet.patterns {
            if let regex = try? NSRegularExpression(pattern: pattern.pattern, options: [.anchorsMatchLines]) {
                patterns.append((regex, pattern.kind, pattern.captureGroup))
            }
        }
        if !ruleSet.keywords.isEmpty {
            let words = ruleSet.keywords
                .map(NSRegularExpression.escapedPattern(for:))
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            var options: NSRegularExpression.Options = [.anchorsMatchLines]
            if ruleSet.caseInsensitiveKeywords { options.insert(.caseInsensitive) }
            let pattern = #"\b(?:"# + words.joined(separator: "|") + #")\b"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
                patterns.append((regex, .keyword, 0))
            }
        }
        codePatterns = patterns

        shellVariableRegex = ruleSet.strings.contains { $0.interior == .shellVariables }
            ? try? NSRegularExpression(pattern: SyntaxHighlighter.shellVariablePattern)
            : nil
        formatFieldRegex = ruleSet.strings.contains { $0.interior == .formatFieldsWhenFPrefixed }
            ? try? NSRegularExpression(pattern: SyntaxHighlighter.formatFieldPattern)
            : nil
    }

    mutating func run() -> [SyntaxToken] {
        let count = text.count
        var index = 0
        var gapStart = 0
        while index < count {
            guard let regionEnd = scanRegion(at: index) else {
                index += 1
                continue
            }
            flushGap(from: gapStart, to: index)
            index = regionEnd
            gapStart = regionEnd
        }
        flushGap(from: gapStart, to: count)
        tokens.sort { lhs, rhs in
            lhs.range.location != rhs.range.location
                ? lhs.range.location < rhs.range.location
                : lhs.range.length > rhs.range.length
        }
        return tokens
    }

    // MARK: Regions

    /// Consumes one exclusive region starting at `index`, appending its
    /// token(s) and returning the region end. Returns nil for plain code.
    private mutating func scanRegion(at index: Int) -> Int? {
        if let end = blockCommentEnd(at: index) {
            tokens.append(SyntaxToken(range: NSRange(location: index, length: end - index), kind: .comment))
            return end
        }
        if let end = lineCommentEnd(at: index) {
            tokens.append(SyntaxToken(range: NSRange(location: index, length: end - index), kind: .comment))
            return end
        }
        if let end = stringEnd(at: index) {
            return end
        }
        if let end = substitutionEnd(at: index) {
            tokens.append(SyntaxToken(
                range: NSRange(location: index, length: end - index),
                kind: .commandSubstitution
            ))
            return end
        }
        return nil
    }

    private func blockCommentEnd(at index: Int) -> Int? {
        for rule in blockComments where matches(rule.open, at: index) {
            var depth = 1
            var j = index + rule.open.count
            while j < text.count {
                if rule.nestable, matches(rule.open, at: j) {
                    depth += 1
                    j += rule.open.count
                    continue
                }
                if matches(rule.close, at: j) {
                    depth -= 1
                    j += rule.close.count
                    if depth == 0 { return j }
                    continue
                }
                j += 1
            }
            return text.count
        }
        return nil
    }

    private func lineCommentEnd(at index: Int) -> Int? {
        for rule in lineComments where matches(rule.prefix, at: index) {
            if rule.requiresLeadingBoundary, index > 0, !Self.boundaryUnits.contains(text[index - 1]) {
                continue
            }
            var j = index + rule.prefix.count
            while j < text.count, text[j] != Self.newline { j += 1 }
            return j
        }
        return nil
    }

    private mutating func stringEnd(at index: Int) -> Int? {
        guard let opening = stringOpening(at: index) else { return nil }
        let rule = strings[opening.ruleIndex]
        var j = opening.contentStart
        var contentEnd = text.count
        var end = text.count
        while j < text.count {
            let unit = text[j]
            if let escape = rule.escape, unit == escape {
                j = min(j + 2, text.count)
                continue
            }
            if !rule.spansLines, unit == Self.newline {
                contentEnd = j
                end = j
                break
            }
            if matches(rule.close, at: j) {
                contentEnd = j
                end = j + rule.close.count
                break
            }
            j += 1
        }
        tokens.append(SyntaxToken(range: NSRange(location: index, length: end - index), kind: .string))
        appendInteriorTokens(
            for: rule.interior,
            hasFPrefix: opening.hasFPrefix,
            contentRange: NSRange(location: opening.contentStart, length: contentEnd - opening.contentStart)
        )
        return end
    }

    private func stringOpening(at index: Int) -> (ruleIndex: Int, contentStart: Int, hasFPrefix: Bool)? {
        for (ruleIndex, rule) in strings.enumerated() where matches(rule.open, at: index) {
            return (ruleIndex, index + rule.open.count, false)
        }
        guard anyPrefixLetters,
              Self.prefixLetters.contains(text[index]),
              index == 0 || !Self.isWordUnit(text[index - 1])
        else { return nil }
        var j = index
        var hasF = false
        while j < text.count, j - index < 2, Self.prefixLetters.contains(text[j]) {
            if text[j] == UInt16(UInt8(ascii: "f")) || text[j] == UInt16(UInt8(ascii: "F")) {
                hasF = true
            }
            j += 1
        }
        for (ruleIndex, rule) in strings.enumerated()
        where rule.allowsPrefixLetters && matches(rule.open, at: j) {
            return (ruleIndex, j + rule.open.count, hasF)
        }
        return nil
    }

    private func substitutionEnd(at index: Int) -> Int? {
        for rule in substitutions where matches(rule.open, at: index) {
            var depth = 1
            var j = index + rule.open.count
            let nestOpen: UInt16? = rule.balanced ? rule.open.last : nil
            while j < text.count {
                let unit = text[j]
                if let escape = rule.escape, unit == escape {
                    j = min(j + 2, text.count)
                    continue
                }
                if unit == Self.singleQuote {
                    j += 1
                    while j < text.count, text[j] != Self.singleQuote { j += 1 }
                    j = min(j + 1, text.count)
                    continue
                }
                if unit == Self.doubleQuote {
                    j += 1
                    while j < text.count, text[j] != Self.doubleQuote {
                        j = text[j] == Self.backslash ? min(j + 2, text.count) : j + 1
                    }
                    j = min(j + 1, text.count)
                    continue
                }
                if let nestOpen, unit == nestOpen {
                    depth += 1
                    j += 1
                    continue
                }
                if matches(rule.close, at: j) {
                    depth -= 1
                    j += rule.close.count
                    if depth == 0 { return j }
                    continue
                }
                j += 1
            }
            return text.count
        }
        return nil
    }

    private mutating func appendInteriorTokens(
        for interior: SyntaxHighlighter.StringInterior,
        hasFPrefix: Bool,
        contentRange: NSRange
    ) {
        guard contentRange.length > 0 else { return }
        let regex: NSRegularExpression?
        let kind: SyntaxTokenKind
        switch interior {
        case .none:
            return
        case .shellVariables:
            regex = shellVariableRegex
            kind = .variable
        case .formatFieldsWhenFPrefixed:
            regex = hasFPrefix ? formatFieldRegex : nil
            kind = .commandSubstitution
        }
        guard let regex else { return }
        let matches = regex.matches(
            in: sourceString,
            options: [.withTransparentBounds, .withoutAnchoringBounds],
            range: contentRange
        )
        for match in matches where match.range.length > 0 {
            tokens.append(SyntaxToken(range: match.range, kind: kind))
        }
    }

    // MARK: Plain code gaps

    private mutating func flushGap(from start: Int, to end: Int) {
        guard end > start else { return }
        let gap = NSRange(location: start, length: end - start)
        var claimed = IndexSet()
        for (regex, kind, captureGroup) in codePatterns {
            let matches = regex.matches(
                in: sourceString,
                options: [.withTransparentBounds, .withoutAnchoringBounds],
                range: gap
            )
            for match in matches {
                let range = captureGroup == 0 ? match.range : match.range(at: captureGroup)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                let indices = range.location ..< range.location + range.length
                guard !claimed.intersects(integersIn: indices) else { continue }
                claimed.insert(integersIn: indices)
                tokens.append(SyntaxToken(range: range, kind: kind))
            }
        }
    }

    // MARK: Utilities

    private func matches(_ literal: [UInt16], at index: Int) -> Bool {
        guard !literal.isEmpty, index + literal.count <= text.count else { return false }
        for offset in 0 ..< literal.count where text[index + offset] != literal[offset] {
            return false
        }
        return true
    }

    private static let newline: UInt16 = 0x0A
    private static let backslash: UInt16 = 0x5C
    private static let singleQuote: UInt16 = 0x27
    private static let doubleQuote: UInt16 = 0x22
    private static let boundaryUnits = Set(" \t\r\n;|&(".utf16)
    private static let prefixLetters = Set("rbufRBUF".utf16)

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        (0x30 ... 0x39).contains(unit)
            || (0x41 ... 0x5A).contains(unit)
            || (0x61 ... 0x7A).contains(unit)
            || unit == 0x5F
    }
}
