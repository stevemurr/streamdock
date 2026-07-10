import Foundation

@MainActor
public final class DeckRuntimeController {
    public var onStatusChange: ((String) -> Void)?
    public var onExecutableAction: ((KeyConfiguration) -> Void)?

    private let device: StreamDockHIDDevice
    private var configuration = DeckConfiguration()
    private var activePageIndex = 0
    private var timer: Timer?
    private var asleep = false
    private var lastConnectAttempt = Date.distantPast

    public init(device: StreamDockHIDDevice = .init()) {
        self.device = device
    }

    public func start(configuration: DeckConfiguration) {
        self.configuration = configuration
        device.setButtonHandler { [weak self] position, isDown in
            Task { @MainActor in self?.handle(position: position, isDown: isDown) }
        }
        connectIfNeeded()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if configuration.settings.clearOnExit { try? device.clearAll() }
        device.disconnect()
        onStatusChange?("Stopped")
    }

    public func update(configuration: DeckConfiguration) {
        let previousName = activePage?.name
        self.configuration = configuration
        if let previousName,
           let preserved = configuration.pages.firstIndex(where: { $0.name == previousName }) {
            activePageIndex = preserved
        } else {
            activePageIndex = 0
        }
        guard device.isConnected, !asleep else { return }
        do {
            try device.setBrightness(configuration.settings.brightness)
            try renderActivePage()
        } catch {
            report(error)
        }
    }

    public func renderActivePage() throws {
        guard let page = activePage else { return }
        try device.clearAll()
        let base = configuration.settings.resourceRoot.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true)
        } ?? ConfigurationStore.defaultConfigurationURL.deletingLastPathComponent()
        for key in page.keys.sorted(by: { $0.position < $1.position }) {
            guard StreamDockProtocol.positionToSlot.indices.contains(key.position) else { continue }
            let jpeg = try KeyFaceRenderer.jpegData(for: key, baseDirectory: base)
            try device.setImage(position: key.position, jpeg: jpeg)
        }
        onStatusChange?("Connected · \(page.name) · \(page.keys.count) keys")
    }

    private var activePage: DeckPage? {
        guard configuration.pages.indices.contains(activePageIndex) else { return nil }
        return configuration.pages[activePageIndex]
    }

    private func tick() {
        if !device.isConnected {
            connectIfNeeded()
            return
        }
        do {
            try device.keepAlive()
        } catch {
            device.disconnect()
            report(error)
        }
    }

    private func connectIfNeeded() {
        guard !device.isConnected, Date().timeIntervalSince(lastConnectAttempt) >= 1.8 else { return }
        lastConnectAttempt = Date()
        do {
            try device.connect()
            try device.initialize(brightness: configuration.settings.brightness)
            asleep = false
            try renderActivePage()
        } catch HIDDeviceError.deviceNotFound {
            onStatusChange?("Device not connected · retrying")
        } catch {
            report(error)
            device.disconnect()
        }
    }

    private func handle(position: Int, isDown: Bool) {
        if asleep {
            guard isDown else { return }
            do {
                try device.wake()
                try device.setBrightness(configuration.settings.brightness)
                asleep = false
                try renderActivePage()
            } catch { report(error) }
            return
        }
        guard isDown, let key = activePage?.keys.first(where: { $0.position == position }) else { return }
        switch key.trigger {
        case .sleepDeck:
            do {
                try device.sleepDisplay()
                asleep = true
                onStatusChange?("Deck asleep · press any key to wake")
            } catch { report(error) }
        case let .switchPage(target):
            switchPage(target)
        case .none:
            break
        case .launchApplication, .shellCommand, .inlineScript, .scriptFile:
            onExecutableAction?(key)
        }
    }

    private func switchPage(_ target: String) {
        let count = configuration.pages.count
        guard count > 0 else { return }
        if target == "next" {
            activePageIndex = (activePageIndex + 1) % count
        } else if target == "prev" {
            activePageIndex = (activePageIndex - 1 + count) % count
        } else if let index = configuration.pages.firstIndex(where: { $0.name == target }) {
            activePageIndex = index
        } else {
            onStatusChange?("Unknown page: \(target)")
            return
        }
        do { try renderActivePage() } catch { report(error) }
    }

    private func report(_ error: Error) {
        onStatusChange?(error.localizedDescription)
    }
}
