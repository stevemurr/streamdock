import AppKit
import Foundation
import os

struct ButtonPressFilter {
    private var downPositions: Set<Int> = []

    mutating func accepts(position: Int, isDown: Bool) -> Bool {
        if isDown { return downPositions.insert(position).inserted }
        downPositions.remove(position)
        return false
    }

    mutating func reset() { downPositions.removeAll() }
}

struct HeartbeatPolicy {
    /// The firmware expects CONNECT at least every few seconds. Keep hand-edited
    /// values in a safe range instead of allowing a configuration typo to put
    /// the deck back into kiosk mode.
    static func normalizedInterval(_ interval: TimeInterval) -> TimeInterval {
        min(2, max(0.5, interval.isFinite ? interval : 1))
    }

    /// If the process was suspended long enough to approach the firmware's
    /// timeout, CONNECT alone is not sufficient: restore software mode and all
    /// key images instead.
    static func recoveryThreshold(for interval: TimeInterval) -> TimeInterval {
        min(3, max(2, normalizedInterval(interval) * 1.5))
    }

    static func requiresRecovery(elapsed: TimeInterval, interval: TimeInterval) -> Bool {
        elapsed >= recoveryThreshold(for: interval)
    }
}

private enum HeartbeatFailure: Sendable {
    case missedDeadline(TimeInterval)
    case writeFailed(String)
}

/// Sends firmware keepalives independently of AppKit's run-loop modes. The HID
/// transport serializes this with image uploads, so CONNECT can never split a
/// BAT/raw/STP transaction.
private final class DeviceHeartbeat: @unchecked Sendable {
    private let device: StreamDockHIDDevice
    private let queue = DispatchQueue(label: "com.streamdock.heartbeat", qos: .userInitiated)
    private let onSuccess: @MainActor @Sendable () -> Void
    private let onFailure: @MainActor @Sendable (HeartbeatFailure) -> Void
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval
    private var lastTickNanoseconds: UInt64 = 0
    private var paused = true
    private var awaitingRecovery = false
    private var activity: NSObjectProtocol?

    init(
        device: StreamDockHIDDevice,
        interval: TimeInterval,
        onSuccess: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable (HeartbeatFailure) -> Void
    ) {
        self.device = device
        self.interval = HeartbeatPolicy.normalizedInterval(interval)
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Maintain the Stream Dock hardware connection"
        )
        queue.sync {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            timer = source
            schedule(source)
            source.setEventHandler { [weak self] in self?.fire() }
            source.resume()
        }
    }

    func updateInterval(_ value: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            interval = HeartbeatPolicy.normalizedInterval(value)
            if let timer { schedule(timer) }
        }
    }

    func connected() {
        queue.async { [weak self] in
            self?.paused = false
            self?.awaitingRecovery = false
            self?.lastTickNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
    }

    func pause() {
        queue.async { [weak self] in
            self?.paused = true
            self?.awaitingRecovery = true
        }
    }

    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            paused = true
            awaitingRecovery = true
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func schedule(_ timer: DispatchSourceTimer) {
        let milliseconds = max(1, Int((interval * 1_000).rounded()))
        timer.schedule(
            deadline: .now() + .milliseconds(milliseconds),
            repeating: .milliseconds(milliseconds),
            leeway: .milliseconds(50)
        )
    }

    private func fire() {
        guard !paused, !awaitingRecovery else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastTickNanoseconds == 0
            ? interval
            : TimeInterval(now - lastTickNanoseconds) / 1_000_000_000

        if HeartbeatPolicy.requiresRecovery(elapsed: elapsed, interval: interval) {
            awaitingRecovery = true
            Task { @MainActor [onFailure] in onFailure(.missedDeadline(elapsed)) }
            return
        }
        do {
            try device.keepAlive()
            // Measure from the actual completed write. A key-image upload can
            // legitimately hold the transport lock while still generating HID
            // traffic that keeps the firmware alive.
            lastTickNanoseconds = DispatchTime.now().uptimeNanoseconds
            Task { @MainActor [onSuccess] in onSuccess() }
        } catch {
            awaitingRecovery = true
            let message = error.localizedDescription
            Task { @MainActor [onFailure] in onFailure(.writeFailed(message)) }
        }
    }
}

@MainActor
public final class DeckRuntimeController {
    public var onStatusChange: ((String) -> Void)?
    public var onExecutableAction: ((KeyConfiguration) -> Void)?

    private let device: StreamDockHIDDevice
    private var configuration = DeckConfiguration()
    private var activePageIndex = 0
    private var heartbeat: DeviceHeartbeat?
    private var reconnectTask: Task<Void, Never>?
    private var powerObservers: [NSObjectProtocol] = []
    private var asleep = false
    private var restoreSleepAfterReconnect = false
    private var lastActivity = Date()
    private var activeKeyIDs: Set<UUID> = []
    private var pressFilter = ButtonPressFilter()
    private let logger = Logger(subsystem: "com.stevemurr.StreamDock", category: "Runtime")

    public init(device: StreamDockHIDDevice = .init()) {
        self.device = device
    }

    public func start(configuration: DeckConfiguration) {
        self.configuration = configuration
        device.setButtonHandler { [weak self] position, isDown in
            Task { @MainActor in self?.handle(position: position, isDown: isDown) }
        }
        device.setRemovalHandler { [weak self] in
            Task { @MainActor in self?.deviceWasRemoved() }
        }
        installPowerObservers()
        heartbeat?.stop()
        let heartbeat = DeviceHeartbeat(
            device: device,
            interval: configuration.settings.keepaliveSeconds,
            onSuccess: { [weak self] in self?.autoSleepIfIdle() },
            onFailure: { [weak self] failure in self?.heartbeatFailed(failure) }
        )
        self.heartbeat = heartbeat
        heartbeat.start()
        connectIfNeeded()
    }

    public func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeat?.stop()
        heartbeat = nil
        removePowerObservers()
        if configuration.settings.clearOnExit { try? device.clearAll() }
        device.disconnect()
        device.setButtonHandler(nil)
        device.setRemovalHandler(nil)
        pressFilter.reset()
        asleep = false
        restoreSleepAfterReconnect = false
        onStatusChange?("Stopped")
    }

    public func update(configuration: DeckConfiguration) {
        let previousName = activePage?.name
        self.configuration = configuration
        heartbeat?.updateInterval(configuration.settings.keepaliveSeconds)
        lastActivity = Date()
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
            handleOperationalError(error)
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
            let jpeg = try KeyFaceRenderer.jpegData(
                for: key,
                baseDirectory: base,
                isActive: activeKeyIDs.contains(key.id)
            )
            try device.setImage(position: key.position, jpeg: jpeg)
        }
        onStatusChange?("Connected · \(page.name) · \(page.keys.count) keys")
    }

    private var activePage: DeckPage? {
        guard configuration.pages.indices.contains(activePageIndex) else { return nil }
        return configuration.pages[activePageIndex]
    }

    /// Name of the page currently shown on the deck, if any.
    public var activePageName: String? { activePage?.name }

    public func updateActiveKeyIDs(_ keyIDs: Set<UUID>) {
        guard activeKeyIDs != keyIDs else { return }
        activeKeyIDs = keyIDs
        guard device.isConnected, !asleep else { return }
        do { try renderActivePage() } catch { handleOperationalError(error) }
    }

    /// Puts the deck's displays to sleep; the next hardware press wakes it.
    public func sleepDeck() {
        guard device.isConnected, !asleep else { return }
        do {
            try device.sleepDisplay()
            asleep = true
            onStatusChange?("Deck asleep · press any key to wake")
        } catch { handleOperationalError(error) }
    }

    /// Puts the deck to sleep once it has been idle past the configured
    /// screen-off interval (`screen_off_seconds`; nil never sleeps).
    private func autoSleepIfIdle() {
        guard !asleep,
              let limit = configuration.settings.screenOffAfterSeconds, limit > 0,
              Date().timeIntervalSince(lastActivity) >= limit
        else { return }
        sleepDeck()
    }

    private func connectIfNeeded() {
        reconnectTask?.cancel()
        reconnectTask = nil
        guard !device.isConnected else {
            heartbeat?.connected()
            return
        }
        do {
            try device.connect()
            try device.initialize(brightness: configuration.settings.brightness)
            pressFilter.reset()
            asleep = false
            lastActivity = Date()
            try renderActivePage()
            if restoreSleepAfterReconnect {
                try device.sleepDisplay()
                asleep = true
                onStatusChange?("Deck asleep · press any key to wake")
            }
            restoreSleepAfterReconnect = false
            heartbeat?.connected()
            logger.info("Runtime connection initialized")
        } catch HIDDeviceError.deviceNotFound {
            heartbeat?.pause()
            device.disconnect()
            onStatusChange?("Device not connected · retrying")
            scheduleReconnect(after: 2)
        } catch {
            heartbeat?.pause()
            device.disconnect()
            report(error)
            scheduleReconnect(after: 2)
        }
    }

    private func handle(position: Int, isDown: Bool) {
        lastActivity = Date()
        guard pressFilter.accepts(position: position, isDown: isDown) else { return }
        if asleep {
            do {
                try device.wake()
                try device.setBrightness(configuration.settings.brightness)
                asleep = false
                try renderActivePage()
            } catch { handleOperationalError(error) }
            return
        }
        guard let key = activePage?.keys.first(where: { $0.position == position }) else {
            if let target = Self.bottomButtonTargets[position] { switchPage(target) }
            return
        }
        switch key.trigger {
        case .sleepDeck:
            sleepDeck()
        case let .switchPage(target):
            switchPage(target)
        case .none:
            break
        case .launchApplication, .shellCommand, .inlineScript, .scriptFile, .caffeinate:
            onExecutableAction?(key)
        }
    }

    /// Built-in bindings for the screenless bottom buttons (left/middle/right
    /// -> previous page / first page / next page). A configured key at the
    /// same position overrides these.
    private static let bottomButtonTargets: [Int: String] = Dictionary(
        uniqueKeysWithValues: zip(StreamDockProtocol.bottomButtonPositions, ["prev", "first", "next"])
    )

    /// Switches to a page by name (case-insensitive) or to "next"/"prev"/"first".
    /// Works without a connected device — the page change simply takes effect
    /// on screen once the deck is connected and awake.
    @discardableResult
    public func switchPage(_ target: String) -> Bool {
        let count = configuration.pages.count
        guard count > 0 else { return false }
        if target == "next" {
            activePageIndex = (activePageIndex + 1) % count
        } else if target == "prev" {
            activePageIndex = (activePageIndex - 1 + count) % count
        } else if target == "first" {
            activePageIndex = 0
        } else if let index = configuration.pages.firstIndex(where: {
            $0.name.caseInsensitiveCompare(target) == .orderedSame
        }) {
            activePageIndex = index
        } else {
            onStatusChange?("Unknown page: \(target)")
            return false
        }
        if device.isConnected, !asleep {
            do { try renderActivePage() } catch { handleOperationalError(error) }
        }
        return true
    }

    private func heartbeatFailed(_ failure: HeartbeatFailure) {
        switch failure {
        case let .missedDeadline(elapsed):
            logger.error("Missed firmware keepalive window after \(elapsed, format: .fixed(precision: 2)) seconds")
            beginRecovery(status: "Keepalive delayed · restoring deck", reconnectAfter: 0)
        case let .writeFailed(message):
            logger.error("Keepalive failed: \(message, privacy: .public)")
            beginRecovery(status: "Connection lost · reconnecting", reconnectAfter: 0.5)
        }
    }

    private func deviceWasRemoved() {
        logger.error("HID removal callback received")
        beginRecovery(status: "Device disconnected · retrying", reconnectAfter: 1)
    }

    private func beginRecovery(status: String, reconnectAfter delay: TimeInterval) {
        restoreSleepAfterReconnect = restoreSleepAfterReconnect || asleep
        asleep = false
        heartbeat?.pause()
        reconnectTask?.cancel()
        reconnectTask = nil
        device.disconnect()
        pressFilter.reset()
        onStatusChange?(status)
        scheduleReconnect(after: delay)
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            reconnectTask = nil
            connectIfNeeded()
        }
    }

    private func handleOperationalError(_ error: Error) {
        switch error {
        case HIDDeviceError.deviceNotFound, HIDDeviceError.openFailed, HIDDeviceError.writeFailed:
            logger.error("HID operation failed: \(error.localizedDescription, privacy: .public)")
            beginRecovery(status: "Connection lost · reconnecting", reconnectAfter: 0.5)
        default:
            report(error)
        }
    }

    private func installPowerObservers() {
        guard powerObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        powerObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        })
    }

    private func removePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.forEach(center.removeObserver)
        powerObservers.removeAll()
    }

    private func systemWillSleep() {
        logger.info("System sleep: closing HID session")
        restoreSleepAfterReconnect = restoreSleepAfterReconnect || asleep
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeat?.pause()
        device.disconnect()
        asleep = false
        pressFilter.reset()
        onStatusChange?("Mac asleep · reconnecting after wake")
    }

    private func systemDidWake() {
        logger.info("System wake: scheduling fresh HID session")
        onStatusChange?("Mac woke · reconnecting deck")
        scheduleReconnect(after: 1)
    }

    private func report(_ error: Error) {
        onStatusChange?(error.localizedDescription)
    }
}
