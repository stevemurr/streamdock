import AppKit
import StreamDockCore
@preconcurrency import SwiftUI
import UniformTypeIdentifiers

struct KeyInspectorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let binding = model.bindingForSelectedKey() {
                InspectorForm(key: binding)
            } else {
                ContentUnavailableView(
                    "Select a Key",
                    systemImage: "square.grid.3x2",
                    description: Text("Choose a square on the deck to configure it.")
                )
            }
        }
    }
}

private struct InspectorForm: View {
    @EnvironmentObject private var model: AppModel
    @Binding var key: KeyConfiguration

    private let icons = [
        "brightness", "bulb", "contrast", "cycle", "dot", "droplet", "gear",
        "lock", "meter", "minus", "monitor", "moon", "play", "plus", "power",
        "refresh", "sun",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Appearance") {
                    TextField("Label", text: $key.label)
                    Picker("Icon", selection: $key.icon) {
                        Text("None").tag(String?.none)
                        ForEach(icons, id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                    }
                    ColorRow(colorHex: $key.color)
                }

                Section("On Press") {
                    Picker("Action", selection: triggerKind) {
                        ForEach(KeyTrigger.Kind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    ActionEditor(key: $key)
                }
            }
            .formStyle(.grouped)

            Divider()
            executionPanel
        }
    }

    private var triggerKind: Binding<KeyTrigger.Kind> {
        Binding(
            get: { key.trigger.kind },
            set: { key.trigger = .blank($0) }
        )
    }

    @ViewBuilder
    private var executionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.isExecuting ? "Running…" : "Test Run", systemImage: "play.fill") {
                    model.runSelectedAction()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isExecuting || !isExecutable)
                if model.isExecuting {
                    Button("Stop", systemImage: "stop.fill") { model.stopSelectedAction() }
                        .keyboardShortcut(".", modifiers: .command)
                }
                Spacer()
                if let result = model.executionResult {
                    Text("Exit \(result.exitCode) · \(result.duration, format: .number.precision(.fractionLength(2)))s")
                        .foregroundStyle(result.succeeded ? .green : .red)
                }
            }
            if let result = model.executionResult,
               !result.standardOutput.isEmpty || !result.standardError.isEmpty {
                ScrollView {
                    Text(result.standardOutput + result.standardError)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80, maxHeight: 160)
                .padding(8)
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.white)
            }
        }
        .padding(12)
    }

    private var isExecutable: Bool {
        switch key.trigger {
        case .launchApplication, .shellCommand, .inlineScript, .scriptFile: true
        default: false
        }
    }
}

/// A color picker paired with a monospaced hex field, both backed by the
/// key's `#rrggbb` color string.
private struct ColorRow: View {
    @Binding var colorHex: String
    @State private var draft = ""
    @FocusState private var hexFieldFocused: Bool

    var body: some View {
        LabeledContent("Color") {
            HStack(spacing: 8) {
                ColorPicker("Color", selection: pickerColor, supportsOpacity: false)
                    .labelsHidden()
                TextField("#rrggbb", text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .focused($hexFieldFocused)
                    .onSubmit(commitDraft)
                    .frame(maxWidth: 120)
            }
        }
        .onAppear { draft = colorHex }
        .onChange(of: colorHex) { _, newValue in draft = newValue }
        .onChange(of: hexFieldFocused) { _, focused in
            if !focused { commitDraft() }
        }
    }

    /// SwiftUI `Color` view of the stored hex string; writes back as
    /// canonical lowercase `#rrggbb`.
    private var pickerColor: Binding<Color> {
        Binding(
            get: {
                MainActor.assumeIsolated {
                    guard let components = ColorHex.parse(colorHex) else {
                        return Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
                    }
                    return Color(
                        .sRGB,
                        red: components.red,
                        green: components.green,
                        blue: components.blue,
                        opacity: 1
                    )
                }
            },
            set: { newColor in
                MainActor.assumeIsolated {
                    guard let converted = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                    colorHex = ColorHex.format(
                        red: converted.redComponent,
                        green: converted.greenComponent,
                        blue: converted.blueComponent
                    )
                }
            }
        )
    }

    /// Applies the typed hex value if valid (normalizing it); otherwise
    /// restores the field to the stored value without touching the key.
    private func commitDraft() {
        if let components = ColorHex.parse(draft) {
            colorHex = ColorHex.format(
                red: components.red,
                green: components.green,
                blue: components.blue
            )
        }
        draft = colorHex
    }
}

private struct ActionEditor: View {
    @Binding var key: KeyConfiguration

    var body: some View {
        switch key.trigger {
        case .none:
            Text("This key only displays its face.")
                .foregroundStyle(.secondary)
        case .sleepDeck:
            Text("Turns off the deck displays until the next key press.")
                .foregroundStyle(.secondary)
        case .launchApplication:
            TextField("Application", text: applicationName)
            HStack {
                Text(applicationPath.wrappedValue.isEmpty ? "Choose an .app bundle" : applicationPath.wrappedValue)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…", action: chooseApplication)
            }
        case .shellCommand:
            Picker("Shell", selection: commandLanguage) {
                ForEach(ScriptLanguage.allCases.filter { $0 != .python }) { language in
                    Text(language.displayName).tag(language)
                }
            }
            SourceEditorView(text: commandSource, language: commandEffectiveLanguage)
                .frame(minHeight: 190)
            ExecutionOptionsEditor(options: commandOptions)
        case .inlineScript:
            Picker("Language", selection: scriptLanguage) {
                ForEach(ScriptLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            LabeledContent("Detected") { Text(scriptEffectiveLanguage.displayName) }
            SourceEditorView(text: scriptSource, language: scriptEffectiveLanguage)
                .frame(minHeight: 230)
            ExecutionOptionsEditor(options: scriptOptions)
        case .scriptFile:
            HStack {
                TextField("Script Path", text: filePath)
                Button("Choose…", action: chooseScript)
            }
            Picker("Language", selection: fileLanguage) {
                ForEach(ScriptLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            TextField("Arguments (one per line)", text: fileArgumentsText, axis: .vertical)
                .lineLimit(2...5)
                .font(.system(.body, design: .monospaced))
            ExecutionOptionsEditor(options: fileOptions)
        case .switchPage:
            TextField("Page name, next, or prev", text: pageTarget)
        }
    }

    private var applicationName: Binding<String> {
        binding(
            get: { if case let .launchApplication(value) = key.trigger { value.name } else { "" } },
            set: {
                guard case var .launchApplication(value) = key.trigger else { return }
                value.name = $0; key.trigger = .launchApplication(value)
            }
        )
    }

    private var applicationPath: Binding<String> {
        binding(
            get: { if case let .launchApplication(value) = key.trigger { value.path ?? "" } else { "" } },
            set: {
                guard case var .launchApplication(value) = key.trigger else { return }
                value.path = $0.isEmpty ? nil : $0; key.trigger = .launchApplication(value)
            }
        )
    }

    private var commandSource: Binding<String> {
        binding(
            get: { if case let .shellCommand(value) = key.trigger { value.source } else { "" } },
            set: {
                guard case var .shellCommand(value) = key.trigger else { return }
                value.source = $0; key.trigger = .shellCommand(value)
            }
        )
    }

    private var commandLanguage: Binding<ScriptLanguage> {
        binding(
            get: { if case let .shellCommand(value) = key.trigger { value.shell } else { .automatic } },
            set: {
                guard case var .shellCommand(value) = key.trigger else { return }
                value.shell = $0; key.trigger = .shellCommand(value)
            }
        )
    }

    private var commandEffectiveLanguage: ScriptLanguage {
        LanguageDetector.effective(requested: commandLanguage.wrappedValue, source: commandSource.wrappedValue)
    }

    private var commandOptions: Binding<ExecutionOptions> {
        binding(
            get: { if case let .shellCommand(value) = key.trigger { value.options } else { .init() } },
            set: {
                guard case var .shellCommand(value) = key.trigger else { return }
                value.options = $0; key.trigger = .shellCommand(value)
            }
        )
    }

    private var scriptSource: Binding<String> {
        binding(
            get: { if case let .inlineScript(value) = key.trigger { value.source } else { "" } },
            set: {
                guard case var .inlineScript(value) = key.trigger else { return }
                value.source = $0; key.trigger = .inlineScript(value)
            }
        )
    }

    private var scriptLanguage: Binding<ScriptLanguage> {
        binding(
            get: { if case let .inlineScript(value) = key.trigger { value.language } else { .automatic } },
            set: {
                guard case var .inlineScript(value) = key.trigger else { return }
                value.language = $0; key.trigger = .inlineScript(value)
            }
        )
    }

    private var scriptEffectiveLanguage: ScriptLanguage {
        LanguageDetector.effective(requested: scriptLanguage.wrappedValue, source: scriptSource.wrappedValue)
    }

    private var scriptOptions: Binding<ExecutionOptions> {
        binding(
            get: { if case let .inlineScript(value) = key.trigger { value.options } else { .init() } },
            set: {
                guard case var .inlineScript(value) = key.trigger else { return }
                value.options = $0; key.trigger = .inlineScript(value)
            }
        )
    }

    private var filePath: Binding<String> {
        binding(
            get: { if case let .scriptFile(value) = key.trigger { value.path } else { "" } },
            set: {
                guard case var .scriptFile(value) = key.trigger else { return }
                value.path = $0; key.trigger = .scriptFile(value)
            }
        )
    }

    private var fileLanguage: Binding<ScriptLanguage> {
        binding(
            get: { if case let .scriptFile(value) = key.trigger { value.language } else { .automatic } },
            set: {
                guard case var .scriptFile(value) = key.trigger else { return }
                value.language = $0; key.trigger = .scriptFile(value)
            }
        )
    }

    private var fileArgumentsText: Binding<String> {
        binding(
            get: { if case let .scriptFile(value) = key.trigger { value.arguments.joined(separator: "\n") } else { "" } },
            set: {
                guard case var .scriptFile(value) = key.trigger else { return }
                value.arguments = $0.split(separator: "\n").map(String.init)
                key.trigger = .scriptFile(value)
            }
        )
    }

    private var fileOptions: Binding<ExecutionOptions> {
        binding(
            get: { if case let .scriptFile(value) = key.trigger { value.options } else { .init() } },
            set: {
                guard case var .scriptFile(value) = key.trigger else { return }
                value.options = $0; key.trigger = .scriptFile(value)
            }
        )
    }

    private var pageTarget: Binding<String> {
        binding(
            get: { if case let .switchPage(value) = key.trigger { value } else { "next" } },
            set: { key.trigger = .switchPage($0) }
        )
    }

    private func binding<Value: Sendable>(
        get: @escaping @MainActor @Sendable () -> Value,
        set: @escaping @MainActor @Sendable (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { MainActor.assumeIsolated { get() } },
            set: { value in MainActor.assumeIsolated { set(value) } }
        )
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let applicationBundle = UTType(filenameExtension: "app") {
            panel.allowedContentTypes = [applicationBundle]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var reference = ApplicationReference(name: url.deletingPathExtension().lastPathComponent, path: url.path)
        reference.bundleIdentifier = Bundle(url: url)?.bundleIdentifier
        key.trigger = .launchApplication(reference)
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Script"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              case var .scriptFile(value) = key.trigger else { return }
        value.path = url.path
        key.trigger = .scriptFile(value)
    }
}

private struct ExecutionOptionsEditor: View {
    @Binding var options: ExecutionOptions

    var body: some View {
        DisclosureGroup("Execution Environment") {
            TextField(
                "Working directory (defaults to home)",
                text: Binding(
                    get: { options.workingDirectory ?? "" },
                    set: { options.workingDirectory = $0.isEmpty ? nil : $0 }
                )
            )
            Toggle("Allow concurrent runs", isOn: $options.allowConcurrent)
            Text("Commands inherit the login-shell environment and run in your home folder unless overridden here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
