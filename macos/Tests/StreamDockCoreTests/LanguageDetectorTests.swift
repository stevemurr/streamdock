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
}
