import Foundation
import XCTest
@testable import StreamDockCore

final class SyntaxHighlighterTests: XCTestCase {
    // MARK: Helpers

    private func tokens(_ source: String, _ language: ScriptLanguage) -> [SyntaxToken] {
        SyntaxHighlighter.tokens(for: source, language: language)
    }

    private func texts(of kind: SyntaxTokenKind, in source: String, _ tokens: [SyntaxToken]) -> [String] {
        let ns = source as NSString
        return tokens.filter { $0.kind == kind }.map { ns.substring(with: $0.range) }
    }

    // MARK: Region exclusivity (the two known regex-overlap bugs)

    func testHashInsideShellStringIsNotAComment() {
        let source = ##"echo "# not a comment""##
        let result = tokens(source, .bash)
        XCTAssertFalse(result.contains { $0.kind == .comment })
        XCTAssertEqual(texts(of: .string, in: source, result), [##""# not a comment""##])
    }

    func testQuotesInsideShellCommentStayComment() {
        let source = #"# comment with "quotes""#
        let result = tokens(source, .zsh)
        XCTAssertFalse(result.contains { $0.kind == .string })
        XCTAssertEqual(result.map(\.kind), [.comment])
        XCTAssertEqual(result.first?.range, NSRange(location: 0, length: (source as NSString).length))
    }

    func testShellHashInsideWordIsNotAComment() {
        let source = "echo foo#bar # real comment"
        let result = tokens(source, .bash)
        XCTAssertEqual(texts(of: .comment, in: source, result), ["# real comment"])
    }

    func testPythonStringWithHashIsNotComment() {
        let source = #"value = "keep # this""#
        let result = tokens(source, .python)
        XCTAssertFalse(result.contains { $0.kind == .comment })
        XCTAssertEqual(texts(of: .string, in: source, result), [#""keep # this""#])
    }

    func testEscapedQuotesStayInsideString() {
        let source = ##"echo "she said \"hi\" done""##
        let result = tokens(source, .bash)
        XCTAssertEqual(texts(of: .string, in: source, result), [##""she said \"hi\" done""##])
        XCTAssertFalse(
            result.contains { $0.kind == .keyword },
            "'done' inside the string must not be a keyword"
        )
    }

    // MARK: Python

    func testPythonTripleQuotedStringSpansLines() {
        let source = "doc = \"\"\"first line\n# not a comment\n'quoted' too\"\"\"\ncount = 3"
        let result = tokens(source, .python)
        XCTAssertFalse(result.contains { $0.kind == .comment })
        XCTAssertEqual(
            texts(of: .string, in: source, result),
            ["\"\"\"first line\n# not a comment\n'quoted' too\"\"\""]
        )
        XCTAssertEqual(texts(of: .number, in: source, result), ["3"])
    }

    func testPythonDecoratorAndDefinitionNames() {
        let source = "@cached_property\ndef total_price(self):\n    return 42"
        let result = tokens(source, .python)
        XCTAssertEqual(texts(of: .decorator, in: source, result), ["@cached_property"])
        XCTAssertEqual(texts(of: .functionName, in: source, result), ["total_price"])
        let keywords = texts(of: .keyword, in: source, result)
        XCTAssertTrue(keywords.contains("def"))
        XCTAssertTrue(keywords.contains("return"))
        XCTAssertEqual(texts(of: .number, in: source, result), ["42"])
    }

    func testPythonClassNameAndHexAndFloatNumbers() {
        let source = "class Renderer:\n    scale = 0x1F\n    ratio = 2.5"
        let result = tokens(source, .python)
        XCTAssertEqual(texts(of: .functionName, in: source, result), ["Renderer"])
        XCTAssertEqual(texts(of: .number, in: source, result), ["0x1F", "2.5"])
    }

    func testPythonFStringInterpolation() {
        let source = #"greeting = f"hello {name}!""#
        let result = tokens(source, .python)
        XCTAssertEqual(texts(of: .string, in: source, result), [#"f"hello {name}!""#])
        XCTAssertEqual(texts(of: .commandSubstitution, in: source, result), ["{name}"])
    }

    func testNumbersAreNotHighlightedInsideIdentifiers() {
        let source = "foo123 = 42"
        let result = tokens(source, .python)
        XCTAssertEqual(texts(of: .number, in: source, result), ["42"])
    }

    // MARK: Shell

    func testShellVariableInsideDoubleQuotedString() {
        let source = #"echo "hello $USER in ${HOME} today""#
        let result = tokens(source, .bash)
        XCTAssertEqual(texts(of: .string, in: source, result), [#""hello $USER in ${HOME} today""#])
        XCTAssertEqual(texts(of: .variable, in: source, result), ["$USER", "${HOME}"])
        XCTAssertFalse(
            result.contains { $0.kind == .keyword },
            "'in' inside a string must not be a keyword"
        )
        // Nested tokens follow their enclosing string so applying attributes
        // in array order produces correct nesting.
        let stringIndex = result.firstIndex { $0.kind == .string }
        let variableIndex = result.firstIndex { $0.kind == .variable }
        XCTAssertNotNil(stringIndex)
        XCTAssertNotNil(variableIndex)
        XCTAssertLessThan(stringIndex ?? 0, variableIndex ?? 0)
    }

    func testShellSingleQuotedStringHasNoVariables() {
        let source = #"echo 'price is $5 for $USER'"#
        let result = tokens(source, .zsh)
        XCTAssertEqual(texts(of: .string, in: source, result), [#"'price is $5 for $USER'"#])
        XCTAssertTrue(texts(of: .variable, in: source, result).isEmpty)
    }

    func testShellFlags() {
        let source = "ls -la --color=auto"
        let result = tokens(source, .bash)
        XCTAssertEqual(texts(of: .flag, in: source, result), ["-la", "--color"])
    }

    func testShellCommandSubstitution() {
        let source = "today=$(date +%Y) files=`ls`"
        let result = tokens(source, .bash)
        XCTAssertEqual(texts(of: .commandSubstitution, in: source, result), ["$(date +%Y)", "`ls`"])
    }

    func testShellNestedCommandSubstitutionIsOneRegion() {
        let source = #"x=$(basename "$(pwd)")"#
        let result = tokens(source, .bash)
        XCTAssertEqual(texts(of: .commandSubstitution, in: source, result), [#"$(basename "$(pwd)")"#])
    }

    func testShellVariablesAndKeywordsOutsideStrings() {
        let source = "if [ -n \"$NAME\" ]; then\n  export GREETING=hi\nfi"
        let result = tokens(source, .bash)
        let keywords = texts(of: .keyword, in: source, result)
        XCTAssertTrue(keywords.contains("if"))
        XCTAssertTrue(keywords.contains("then"))
        XCTAssertTrue(keywords.contains("export"))
        XCTAssertTrue(keywords.contains("fi"))
        XCTAssertEqual(texts(of: .variable, in: source, result), ["$NAME"])
    }

    // MARK: General behavior

    func testEmptySourceProducesNoTokens() {
        XCTAssertTrue(tokens("", .python).isEmpty)
        XCTAssertTrue(tokens("", .bash).isEmpty)
    }

    func testAutomaticUsesShellRulesAndTokensAreSorted() {
        let source = "for f in *.txt; do\n  echo \"$f\" # loop\ndone"
        let result = tokens(source, .automatic)
        XCTAssertTrue(texts(of: .keyword, in: source, result).contains("done"))
        XCTAssertEqual(texts(of: .comment, in: source, result), ["# loop"])
        let locations = result.map(\.range.location)
        XCTAssertEqual(locations, locations.sorted())
    }

    // MARK: AppleScript rule set (wired to ScriptLanguage at merge)

    func testAppleScriptRuleSet() {
        let source = """
        tell application "Finder" -- greet the user
        (* block
        comment *)
        set answer to 42
        """
        let result = SyntaxHighlighter.tokens(for: source, ruleSet: SyntaxHighlighter.appleScriptRuleSet)
        let keywords = texts(of: .keyword, in: source, result)
        XCTAssertTrue(keywords.contains("tell"))
        XCTAssertTrue(keywords.contains("set"))
        XCTAssertTrue(keywords.contains("to"))
        XCTAssertEqual(texts(of: .string, in: source, result), ["\"Finder\""])
        XCTAssertEqual(
            texts(of: .comment, in: source, result),
            ["-- greet the user", "(* block\ncomment *)"]
        )
        XCTAssertEqual(texts(of: .number, in: source, result), ["42"])
    }
}
