import StreamDockCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.legacyAgentInstalled {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("The legacy Python runner is installed and may compete for the device.")
                    Spacer()
                    Button("Disable Legacy Runner") { model.disableLegacyAgent() }
                }
                .padding(10)
                .background(.yellow.opacity(0.12))
                Divider()
            }
            NavigationSplitView {
                PageSidebar()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } content: {
                DeckEditorView()
                    .navigationSplitViewColumnWidth(min: 430, ideal: 560)
            } detail: {
                KeyInspectorView()
                    .navigationSplitViewColumnWidth(min: 330, ideal: 430)
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                DeviceStatusPill(status: model.deviceStatus)
            }
            ToolbarItemGroup {
                Button("Secrets", systemImage: "key.horizontal") {
                    model.isShowingSecrets = true
                }
                .help("Manage encrypted environment secrets")
                Button("Save", systemImage: "square.and.arrow.down") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.isDirty)
            }
        }
        .sheet(isPresented: $model.isShowingSecrets) {
            SecretsView()
                .environmentObject(model)
        }
        .onAppear {
            // UI tests synthesize real mouse drags, which miss when the saved
            // window frame is on a secondary display; center on the primary.
            guard ProcessInfo.processInfo.environment["STREAMDOCK_UI_TESTING"] == "1",
                  let screen = NSScreen.screens.first else { return }
            DispatchQueue.main.async {
                guard let window = NSApp.windows.first(where: \.isVisible) else { return }
                let size = window.frame.size
                window.setFrame(
                    CGRect(
                        x: screen.frame.midX - size.width / 2,
                        y: screen.frame.midY - size.height / 2,
                        width: size.width,
                        height: size.height
                    ),
                    display: true
                )
            }
        }
        .alert(
            "StreamDock",
            isPresented: Binding(
                get: { model.executionError != nil },
                set: { if !$0 { model.executionError = nil } }
            )
        ) {
            Button("OK") { model.executionError = nil }
        } message: {
            Text(model.executionError ?? "Unknown error")
        }
    }
}

/// Compact connection indicator: a colored dot plus the runtime's status line,
/// colored by whether the deck is connected, sleeping, or searching.
struct DeviceStatusPill: View {
    let status: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .help(status)
    }

    private var tint: Color {
        let lowered = status.lowercased()
        if lowered.contains("connected") { return .green }
        if lowered.contains("asleep") { return .blue }
        if lowered.contains("not connected") || lowered.contains("retry")
            || lowered.contains("starting") { return .orange }
        if lowered.contains("stopped") || lowered.contains("error") { return .red }
        return .secondary
    }
}

private struct PageSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            List(model.configuration.pages, selection: $model.selectedPageID) { page in
                Label(page.name, systemImage: "square.grid.3x2")
                    .tag(page.id)
            }
            HStack {
                Button(action: model.addPage) { Image(systemName: "plus") }
                Button(action: model.deleteSelectedPage) { Image(systemName: "minus") }
                    .disabled(model.configuration.pages.count <= 1)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }
}

private struct DeckEditorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                TextField(
                    "Page Name",
                    text: Binding(
                        get: { model.selectedPage?.name ?? "" },
                        set: model.updateSelectedPageName
                    )
                )
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                Spacer()
                Text("3 × 5")
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 5), spacing: 14) {
                ForEach(0..<15, id: \.self) { position in
                    DeckKeySlot(position: position)
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color(nsColor: .black).opacity(0.55))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            )
            Spacer()
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// One slot in the deck editor grid. Tap selects the slot; occupied key faces
/// can be dragged onto any other slot to move the key (or swap with the key
/// already there). The slot highlights while a drag hovers over it.
private struct DeckKeySlot: View {
    @EnvironmentObject private var model: AppModel
    let position: Int
    @State private var isDropTargeted = false
    @State private var isHovering = false

    var body: some View {
        slotButton(for: model.key(at: position))
            .buttonStyle(.plain)
            .accessibilityIdentifier("deck-slot-\(position)")
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        model.selectedPosition == position ? Color.accentColor : .clear,
                        lineWidth: 3
                    )
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor.opacity(0.2))
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, dash: [7, 5])
                        )
                }
            }
            .overlay(alignment: .topTrailing) {
                if isHovering, !isDropTargeted, let key = model.key(at: position) {
                    Button {
                        model.deleteKey(at: position)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help("Delete this key")
                    .accessibilityLabel(
                        "Delete \(key.label.isEmpty ? "key \(position + 1)" : key.label)"
                    )
                    .accessibilityIdentifier("delete-key-\(position)")
                }
            }
            .onHover { isHovering = $0 }
            .shadow(
                color: model.selectedPosition == position
                    ? Color.accentColor.opacity(0.35) : .clear,
                radius: 6
            )
            .scaleEffect(isDropTargeted ? 1.05 : 1)
            .animation(.easeOut(duration: 0.12), value: isDropTargeted)
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first, let source = Int(payload) else { return false }
                model.moveKey(from: source, to: position)
                return true
            } isTargeted: { targeting in
                isDropTargeted = targeting
            }
    }

    /// The tappable key face; occupied faces also act as drag sources carrying
    /// their slot index as the payload.
    @ViewBuilder
    private func slotButton(for key: KeyConfiguration?) -> some View {
        let button = Button {
            model.select(position: position)
        } label: {
            KeyFaceView(key: key, position: position)
        }
        if key != nil {
            button.draggable(String(position))
        } else {
            button
        }
    }
}

struct KeyFaceView: View {
    let key: KeyConfiguration?
    let position: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: key?.color ?? "#20242b").opacity(0.96),
                                 Color(hex: key?.color ?? "#20242b").opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
            if let key {
                VStack(spacing: 6) {
                    Image(systemName: symbol(for: key.icon))
                        .font(.system(size: 25, weight: .medium))
                    Text(key.label.isEmpty ? "Key \(position + 1)" : key.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(8)
            } else {
                Text("\(position + 1)")
                    .foregroundStyle(.white.opacity(0.28))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        guard let key else { return "Unassigned key \(position + 1)" }
        return key.label.isEmpty ? "Key \(position + 1)" : key.label
    }

    private func symbol(for icon: String?) -> String {
        switch icon {
        case "play": "play.fill"
        case "monitor": "display"
        case "gear": "gearshape.fill"
        case "lock": "lock.fill"
        case "moon": "moon.fill"
        case "plus": "plus"
        case "minus": "minus"
        case "power": "power"
        case "refresh": "arrow.clockwise"
        case "sun", "brightness": "sun.max.fill"
        case "cycle": "arrow.triangle.2.circlepath"
        default: "circle.fill"
        }
    }
}

private extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let number = UInt64(value, radix: 16) ?? 0x2c3e50
        self.init(
            red: Double((number >> 16) & 0xff) / 255,
            green: Double((number >> 8) & 0xff) / 255,
            blue: Double(number & 0xff) / 255
        )
    }
}
