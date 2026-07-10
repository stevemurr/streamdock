import Foundation
import XCTest
@testable import StreamDockCore

final class LanguageDetectorTests: XCTestCase {
    func testDetectsLanguagesFromShebangAndExtension() {
        XCTAssertEqual(LanguageDetector.detect(source: "#!/usr/bin/env python3\nprint('ok')"), .python)
        XCTAssertEqual(LanguageDetector.detect(source: "#!/bin/zsh\necho ok"), .zsh)
        XCTAssertEqual(
            LanguageDetector.detect(source: "echo ok", fileURL: URL(fileURLWithPath: "run.bash")),
            .bash
        )
    }

    func testAmbiguousCodeUsesLoginShell() {
        XCTAssertEqual(
            LanguageDetector.effective(
                requested: .automatic,
                source: "echo hello",
                loginShell: .zsh
            ),
            .zsh
        )
    }

    func testDetectsAppleScriptFromShebang() {
        XCTAssertEqual(
            LanguageDetector.detect(source: "#!/usr/bin/osascript\nreturn 1"),
            .appleScript
        )
        XCTAssertEqual(
            LanguageDetector.detect(source: "#!/usr/bin/env osascript\nreturn 1"),
            .appleScript
        )
    }

    func testDetectsAppleScriptFromFileExtension() {
        XCTAssertEqual(
            LanguageDetector.detect(source: "return 1", fileURL: URL(fileURLWithPath: "run.applescript")),
            .appleScript
        )
        XCTAssertEqual(
            LanguageDetector.detect(source: "return 1", fileURL: URL(fileURLWithPath: "run.scpt")),
            .appleScript
        )
    }

    func testDetectsAppleScriptFromSourceSignals() {
        XCTAssertEqual(
            LanguageDetector.detect(source: "tell application \"Finder\"\n    activate\nend tell"),
            .appleScript
        )
        XCTAssertEqual(
            LanguageDetector.detect(source: "set greeting to \"hi\"\ndisplay dialog greeting"),
            .appleScript
        )
        XCTAssertEqual(
            LanguageDetector.detect(source: "on run\n    set marker to 1\n    return marker\nend run"),
            .appleScript
        )
    }

    func testSingleAppleScriptSignalStaysAutomatic() {
        XCTAssertEqual(LanguageDetector.detect(source: "activate"), .automatic)
    }

    func testAppleScriptSignalsDoNotAffectOtherLanguages() {
        XCTAssertEqual(
            LanguageDetector.detect(source: "import os\n\ndef main():\n    print(os.getcwd())"),
            .python
        )
        XCTAssertEqual(
            LanguageDetector.effective(
                requested: .automatic,
                source: "export PATH=/tmp\necho \"${PATH}\"",
                loginShell: .zsh
            ),
            .zsh
        )
    }

    func testAutomaticAppleScriptSourceResolvesToAppleScript() {
        XCTAssertEqual(
            LanguageDetector.effective(
                requested: .automatic,
                source: "display notification \"hi\"\ndisplay dialog \"there\"",
                loginShell: .zsh
            ),
            .appleScript
        )
    }
}
