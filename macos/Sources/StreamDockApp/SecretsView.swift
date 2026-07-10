import StreamDockCore
import SwiftUI
import UniformTypeIdentifiers

/// Editor for encrypted environment secrets. Values are stored with AES-GCM
/// (key in the Keychain) and injected into every action the deck runs.
struct SecretsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var revealValues = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.horizontal.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Environment Secrets")
                    .font(.headline)
                Text("Stored encrypted (AES-GCM, key in your Keychain) and exposed to every command, script, and app your keys run — reference them as $NAME.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if model.secrets.isEmpty {
            ContentUnavailableView {
                Label("No Secrets", systemImage: "lock.rectangle")
            } description: {
                Text("Add a key, or import an existing .env file.")
            } actions: {
                Button("Add Secret", action: model.addSecret)
                Button("Import .env…", action: importEnv)
            }
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    HStack {
                        Text("NAME").frame(width: 170, alignment: .leading)
                        Text("VALUE").frame(maxWidth: .infinity, alignment: .leading)
                        Spacer().frame(width: 22)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                    ForEach($model.secrets) { $secret in
                        SecretRow(secret: $secret, reveal: revealValues) {
                            model.deleteSecret(secret.id)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: model.addSecret) {
                Label("Add", systemImage: "plus")
            }
            Menu {
                Button("Import .env…", action: importEnv)
                Button("Export .env…", action: exportEnv)
                    .disabled(model.secrets.allSatisfy { $0.name.isEmpty })
            } label: {
                Label("Import / Export", systemImage: "square.and.arrow.up.on.square")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Toggle("Reveal", isOn: $revealValues)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()

            if let error = model.secretsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Cancel") {
                model.loadSecrets()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                model.commitSecrets()
                if model.secretsError == nil { dismiss() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func importEnv() {
        let panel = NSOpenPanel()
        panel.title = "Import Secrets from .env"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        if let envType = UTType(filenameExtension: "env") {
            panel.allowedContentTypes = [envType, .text, .plainText, .data]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importSecrets(from: url)
    }

    private func exportEnv() {
        let panel = NSSavePanel()
        panel.title = "Export Secrets to .env"
        panel.nameFieldStringValue = "secrets.env"
        panel.message = "Exported values are written in plain text. Keep this file safe."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportSecrets(to: url)
    }
}

private struct SecretRow: View {
    @Binding var secret: SecretItem
    let reveal: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("NAME", text: $secret.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 170)
                .autocorrectionDisabled()

            Group {
                if reveal {
                    TextField("value", text: $secret.value)
                } else {
                    SecureField("value", text: $secret.value)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }
}
