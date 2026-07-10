import AppKit
import StreamDockCore
import SwiftUI

struct SourceEditorView: NSViewRepresentable {
    @Binding var text: String
    var language: ScriptLanguage

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let editor = CodeTextView(frame: .zero, textContainer: container)
        editor.delegate = context.coordinator
        editor.string = text
        editor.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textColor = NSColor.textColor
        editor.backgroundColor = NSColor.textBackgroundColor
        editor.insertionPointColor = NSColor.controlAccentColor
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [NSView.AutoresizingMask.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.allowsUndo = true
        editor.usesFindPanel = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = editor
        scroll.contentView.postsBoundsChangedNotifications = true
        let ruler = LineNumberRulerView(textView: editor, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.editor = editor
        context.coordinator.ruler = ruler
        context.coordinator.highlight(language: language)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: text.utf16.count)))
        }
        context.coordinator.highlight(language: language)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceEditorView
        weak var editor: NSTextView?
        fileprivate weak var ruler: LineNumberRulerView?
        private var applyingAttributes = false

        init(parent: SourceEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !applyingAttributes, let editor else { return }
            parent.text = editor.string
            highlight(language: parent.language)
            ruler?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            highlight(language: parent.language)
        }

        func highlight(language: ScriptLanguage) {
            guard let editor, let storage = editor.textStorage else { return }
            applyingAttributes = true
            defer { applyingAttributes = false }
            let full = NSRange(location: 0, length: storage.length)
            let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            storage.beginEditing()
            storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.textColor], range: full)
            apply(pattern: stringPattern, color: .systemRed, to: storage)
            apply(pattern: numberPattern, color: .systemPurple, to: storage)
            switch language {
            case .python:
                apply(pattern: pythonKeywordPattern, color: .systemPink, to: storage)
                apply(pattern: "(?m)#.*$", color: .secondaryLabelColor, to: storage)
            case .bash, .zsh, .automatic:
                apply(pattern: shellKeywordPattern, color: .systemPink, to: storage)
                apply(pattern: "\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?", color: .systemTeal, to: storage)
                apply(pattern: "(?m)#.*$", color: .secondaryLabelColor, to: storage)
            }
            let selection = editor.selectedRange()
            if selection.location <= storage.length {
                let line = (storage.string as NSString).lineRange(
                    for: NSRange(location: min(selection.location, storage.length), length: 0)
                )
                storage.addAttribute(.backgroundColor, value: NSColor.selectedContentBackgroundColor.withAlphaComponent(0.08), range: line)
            }
            storage.endEditing()
            editor.typingAttributes = [.font: baseFont, .foregroundColor: NSColor.textColor]
        }

        private func apply(pattern: String, color: NSColor, to storage: NSTextStorage) {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(location: 0, length: storage.length)
            expression.enumerateMatches(in: storage.string, range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        private let stringPattern = #"(?s)(\"\"\".*?\"\"\"|'''.*?'''|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')"#
        private let numberPattern = #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#
        private let pythonKeywordPattern = #"\b(?:and|as|assert|async|await|break|case|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|match|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield)\b"#
        private let shellKeywordPattern = #"\b(?:case|do|done|elif|else|esac|export|fi|for|function|if|in|local|readonly|select|then|typeset|until|while)\b"#
    }
}

private final class CodeTextView: NSTextView {
    override func insertNewline(_ sender: Any?) {
        let string = self.string as NSString
        let location = selectedRange().location
        let line = string.lineRange(for: NSRange(location: min(location, string.length), length: 0))
        let prefix = string.substring(with: NSRange(location: line.location, length: max(0, location - line.location)))
            .prefix { $0 == " " || $0 == "\t" }
        super.insertNewline(sender)
        insertText(String(prefix), replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]
        if let characters = event.characters, let close = pairs[characters], selectedRange().length == 0 {
            insertText(characters + close, replacementRange: selectedRange())
            moveLeft(nil)
            return
        }
        super.keyDown(with: event)
    }
}

private final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 42
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redraw),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer,
              let scrollView else { return }
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let visible = scrollView.contentView.bounds
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let string = textView.string as NSString
        var lineNumber = string.substring(to: min(charRange.location, string.length))
            .reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var index = charRange.location
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        while index <= NSMaxRange(charRange), index < string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            var lineRect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            lineRect.origin.y += textView.textContainerOrigin.y - visible.origin.y
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 7, y: lineRect.minY), withAttributes: attributes)
            index = NSMaxRange(lineRange)
            lineNumber += 1
        }
    }
}
