import AppKit
import Combine
import ServiceManagement
import StreamDockCore
import SwiftUI

@main
struct StreamDockApplication: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("StreamDock", id: "editor") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Label(
                "StreamDock",
                systemImage: model.activeActions.isEmpty
                    ? "rectangle.grid.3x2.fill"
                    : "bolt.circle.fill"
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 560, height: 420)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.deviceStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Divider()
            Text("Active Actions")
                .font(.headline)
            if model.activeActions.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ForEach(model.sortedActiveActions) { action in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.label)
                                Text(action.detail(now: context.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop") { model.stopActiveAction(action.id) }
                        }
                    }
                }
                Button("Stop All Actions") { model.stopAllActiveActions() }
            }
            Divider()
            HStack {
                Button("Open Editor") {
                    openWindow(id: "editor")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Secrets…") {
                    openWindow(id: "editor")
                    NSApp.activate(ignoringOtherApps: true)
                    model.isShowingSecrets = true
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var settings = SettingsModel()

    var body: some View {
        Form {
            Section("Deck Settings") {
                LabeledContent("Brightness") {
                    HStack {
                        Slider(value: brightness, in: 0...100, step: 1)
                            .frame(width: 220)
                        Text("\(model.configuration.settings.brightness)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Picker("Screen Off", selection: screenOffSelection) {
                    ForEach(screenOffOptions, id: \.self) { option in
                        Text(screenOffLabel(for: option)).tag(option)
                    }
                }
                .help("Turn the deck displays off after this much inactivity")
                .accessibilityIdentifier("screen-off-picker")

                Button("Save Configuration") { model.save() }
                    .disabled(!model.isDirty)
                    .accessibilityIdentifier("settings-save-button")
            }

            Section("Application") {
                Toggle("Launch StreamDock at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            model.present(error)
                            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                LabeledContent("Configuration") {
                    Text(model.configurationURL.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh Login-Shell Environment") {
                    model.refreshExecutionEnvironment()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var brightness: Binding<Double> {
        Binding(
            get: { Double(model.configuration.settings.brightness) },
            set: {
                let brightness = Int($0)
                guard model.configuration.settings.brightness != brightness else { return }
                model.configuration.settings.brightness = brightness
                model.isDirty = true
            }
        )
    }

    private var screenOffSelection: Binding<Double?> {
        Binding(
            get: { model.configuration.settings.screenOffAfterSeconds },
            set: { newValue in
                guard model.configuration.settings.screenOffAfterSeconds != newValue else { return }
                model.configuration.settings.screenOffAfterSeconds = newValue
                model.isDirty = true
            }
        )
    }

    /// The preset intervals, plus whatever custom value a hand-edited
    /// configuration may carry so the picker never shows an empty selection.
    private var screenOffOptions: [Double?] {
        var options: [Double?] = [nil, 60, 300, 600, 1800, 3600]
        if let current = model.configuration.settings.screenOffAfterSeconds,
           !options.contains(current) {
            options.append(current)
            options.sort { ($0 ?? -1) < ($1 ?? -1) }
        }
        return options
    }

    private func screenOffLabel(for seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Never" }
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        let minutes = seconds / 60
        if minutes < 60 {
            let value = Int(minutes.rounded())
            return value == 1 ? "1 minute" : "\(value) minutes"
        }
        let hours = Int((minutes / 60).rounded())
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}

@MainActor
private final class SettingsModel: ObservableObject {
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
}
