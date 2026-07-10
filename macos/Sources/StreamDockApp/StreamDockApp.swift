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

        MenuBarExtra("StreamDock", systemImage: "rectangle.grid.3x2.fill") {
            MenuBarContent()
                .environmentObject(model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 280)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.deviceStatus)
        Divider()
        Button("Open Editor") {
            openWindow(id: "editor")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Manage Secrets…") {
            openWindow(id: "editor")
            NSApp.activate(ignoringOtherApps: true)
            model.isShowingSecrets = true
        }
        Button("Save") { model.save() }
            .disabled(!model.isDirty)
        Divider()
        Button("Quit StreamDock") { NSApp.terminate(nil) }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var settings = SettingsModel()

    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .padding()
    }
}

@MainActor
private final class SettingsModel: ObservableObject {
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
}
