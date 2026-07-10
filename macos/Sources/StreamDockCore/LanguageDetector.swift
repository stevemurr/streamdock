import Foundation

public enum LanguageDetector {
    public static func detect(source: String, fileURL: URL? = nil) -> ScriptLanguage {
        if let shebang = source.split(whereSeparator: \.isNewline).first,
           shebang.hasPrefix("#!") {
            let line = shebang.lowercased()
            if line.contains("osascript") { return .appleScript }
            if line.contains("python") { return .python }
            if line.contains("zsh") { return .zsh }
            if line.contains("bash") { return .bash }
        }

        if let ext = fileURL?.pathExtension.lowercased() {
            switch ext {
            case "py", "pyw": return .python
            case "applescript", "scpt": return .appleScript
            case "zsh": return .zsh
            case "bash": return .bash
            case "sh": return .automatic
            default: break
            }
        }

        let value = source.lowercased()
        let pythonSignals = ["def ", "import ", "from ", "print(", "elif ", "__name__"]
        let shellSignals = ["#!/bin/", "fi\n", "then\n", "echo ", "export ", "${", "$("]
        let appleScriptSignals = [
            "tell application", "end tell", "display dialog", "display notification",
            "on run", "activate",
        ]
        let pythonScore = pythonSignals.reduce(0) { $0 + (value.contains($1) ? 1 : 0) }
        let shellScore = shellSignals.reduce(0) { $0 + (value.contains($1) ? 1 : 0) }
        var appleScriptScore = appleScriptSignals.reduce(0) { $0 + (value.contains($1) ? 1 : 0) }
        if value.contains("set "), value.contains(" to ") { appleScriptScore += 1 }
        if appleScriptScore >= 2 && appleScriptScore > pythonScore && appleScriptScore > shellScore {
            return .appleScript
        }
        if pythonScore >= 2 && pythonScore > shellScore { return .python }
        if shellScore >= 2 && shellScore > pythonScore { return .automatic }
        return .automatic
    }

    public static func effective(
        requested: ScriptLanguage,
        source: String,
        fileURL: URL? = nil,
        loginShell: ScriptLanguage = .zsh
    ) -> ScriptLanguage {
        guard requested == .automatic else { return requested }
        let detected = detect(source: source, fileURL: fileURL)
        return detected == .automatic ? loginShell : detected
    }
}
