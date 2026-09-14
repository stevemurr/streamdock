import Foundation
import IOKit.hid
import os

public enum HIDDeviceError: LocalizedError {
    case deviceNotFound
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case invalidPosition(Int)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "Stream Dock data interface is not connected."
        case let .openFailed(code):
            "Could not open Stream Dock (IOKit \(code))."
        case let .writeFailed(code):
            "Could not write to Stream Dock (IOKit \(code))."
        case let .invalidPosition(position):
            "Invalid key position: \(position)."
        }
    }
}

public final class StreamDockHIDDevice: @unchecked Sendable {
    public typealias ButtonHandler = @Sendable (_ position: Int, _ isDown: Bool) -> Void
    public typealias RemovalHandler = @Sendable () -> Void

    private let ioLock = NSLock()
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var cancellationSemaphore: DispatchSemaphore?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    private var buttonHandler: ButtonHandler?
    private var removalHandler: RemovalHandler?
    private let callbackQueue = DispatchQueue(label: "com.streamdock.hid-input")
    private let logger = Logger(subsystem: "com.stevemurr.StreamDock", category: "HID")

    public init() {
        inputBuffer.initialize(repeating: 0, count: 512)
    }

    deinit {
        disconnect()
        inputBuffer.deinitialize(count: 512)
        inputBuffer.deallocate()
    }

    public var isConnected: Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        return device != nil
    }

    public func setButtonHandler(_ handler: ButtonHandler?) {
        ioLock.lock()
        buttonHandler = handler
        ioLock.unlock()
    }

    public func setRemovalHandler(_ handler: RemovalHandler?) {
        ioLock.lock()
        removalHandler = handler
        ioLock.unlock()
    }

    public func connect() throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard device == nil else { return }

        // A dispatch-backed IOHIDDevice is single-use after cancellation. Build
        // a fresh manager/device graph for every connection instead of trying to
        // reactivate a device object that a previous session cancelled.
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: StreamDockProtocol.vendorID,
            kIOHIDProductIDKey as String: StreamDockProtocol.productID,
            kIOHIDPrimaryUsagePageKey as String: StreamDockProtocol.usagePage,
        ]
        IOHIDManagerSetDeviceMatching(newManager, matching as CFDictionary)
        let managerResult = IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard managerResult == kIOReturnSuccess else { throw HIDDeviceError.openFailed(managerResult) }
        guard let devices = IOHIDManagerCopyDevices(newManager), CFSetGetCount(devices) > 0 else {
            IOHIDManagerClose(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDDeviceError.deviceNotFound
        }
        let count = CFSetGetCount(devices)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(devices, &values)
        guard let pointer = values.first ?? nil else {
            IOHIDManagerClose(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDDeviceError.deviceNotFound
        }
        let selected = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
        let result = IOHIDDeviceOpen(selected, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerClose(newManager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDDeviceError.openFailed(result)
        }

        let cancelled = DispatchSemaphore(value: 0)
        manager = newManager
        device = selected
        cancellationSemaphore = cancelled

        IOHIDDeviceRegisterInputReportCallback(
            selected,
            inputBuffer,
            512,
            streamDockInputCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceRegisterRemovalCallback(
            selected,
            streamDockRemovalCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceSetDispatchQueue(selected, callbackQueue)
        IOHIDDeviceSetCancelHandler(selected) { cancelled.signal() }
        IOHIDDeviceActivate(selected)
        logger.info("HID device connected")
    }

    public func disconnect() {
        // Detach state before cancellation so sends fail promptly and a removal
        // callback caused by teardown cannot start a second recovery.
        ioLock.lock()
        let oldDevice = device
        let oldManager = manager
        let cancelled = cancellationSemaphore
        device = nil
        manager = nil
        cancellationSemaphore = nil
        ioLock.unlock()

        if let oldDevice {
            IOHIDDeviceCancel(oldDevice)
            if cancelled?.wait(timeout: .now() + 2) == .timedOut {
                logger.error("Timed out waiting for HID cancellation")
            }
            IOHIDDeviceClose(oldDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let oldManager {
            IOHIDManagerClose(oldManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if oldDevice != nil { logger.info("HID device disconnected") }
    }

    public func initialize(brightness: Int) throws {
        try withOpenDevice { device in
            try send(StreamDockProtocol.mode(), to: device)
            Thread.sleep(forTimeInterval: 0.05)
            try send(StreamDockProtocol.wake(), to: device)
            try send(StreamDockProtocol.brightness(brightness), to: device)
        }
    }

    public func keepAlive() throws { try sendSingle(StreamDockProtocol.keepAlive()) }
    public func wake() throws { try sendSingle(StreamDockProtocol.wake()) }
    public func sleepDisplay() throws { try sendSingle(StreamDockProtocol.sleep()) }
    public func setBrightness(_ value: Int) throws { try sendSingle(StreamDockProtocol.brightness(value)) }
    public func clearAll() throws { try sendSingle(StreamDockProtocol.clear()) }

    public func setImage(position: Int, jpeg: Data) throws {
        guard StreamDockProtocol.positionToSlot.indices.contains(position) else {
            throw HIDDeviceError.invalidPosition(position)
        }
        let slot = UInt8(StreamDockProtocol.positionToSlot[position])
        // Keep the whole image transaction under one lock. A background
        // keepalive inserted between BAT and its raw chunks corrupts the frame.
        try withOpenDevice { device in
            try send(StreamDockProtocol.beginImage(slot: slot, byteCount: jpeg.count), to: device)
            for offset in stride(from: 0, to: jpeg.count, by: StreamDockProtocol.packetSize) {
                let end = min(offset + StreamDockProtocol.packetSize, jpeg.count)
                try send(StreamDockProtocol.raw(jpeg.subdata(in: offset..<end)), to: device)
            }
            try send(StreamDockProtocol.refresh(), to: device)
        }
    }

    fileprivate func receive(_ bytes: UnsafePointer<UInt8>, length: Int) {
        guard let event = StreamDockProtocol.parseButtonReport(Data(bytes: bytes, count: length)) else { return }
        ioLock.lock()
        let handler = buttonHandler
        ioLock.unlock()
        handler?(event.position, event.isDown)
    }

    fileprivate func removed(_ removedDevice: IOHIDDevice, result: IOReturn) {
        ioLock.lock()
        let isCurrent = device.map { $0 === removedDevice } ?? false
        let handler = isCurrent ? removalHandler : nil
        ioLock.unlock()
        guard isCurrent else { return }
        logger.error("HID device removal reported (IOKit \(result))")
        handler?()
    }

    private func sendSingle(_ packet: Data) throws {
        try withOpenDevice { try send(packet, to: $0) }
    }

    private func withOpenDevice<Value>(_ operation: (IOHIDDevice) throws -> Value) throws -> Value {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let device else { throw HIDDeviceError.deviceNotFound }
        return try operation(device)
    }

    /// Caller holds `ioLock`, including across multi-packet transactions.
    private func send(_ packet: Data, to device: IOHIDDevice) throws {
        let result = packet.dropFirst().withUnsafeBytes { bytes -> IOReturn in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(0),
                base,
                bytes.count
            )
        }
        guard result == kIOReturnSuccess else {
            logger.error("HID write failed (IOKit \(result))")
            throw HIDDeviceError.writeFailed(result)
        }
    }
}

private let streamDockInputCallback: IOHIDReportCallback = {
    context, _, _, _, _, report, reportLength in
    guard let context else { return }
    let owner = Unmanaged<StreamDockHIDDevice>.fromOpaque(context).takeUnretainedValue()
    owner.receive(report, length: reportLength)
}

private let streamDockRemovalCallback: IOHIDCallback = { context, result, sender in
    guard let context, let sender else { return }
    let owner = Unmanaged<StreamDockHIDDevice>.fromOpaque(context).takeUnretainedValue()
    let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
    owner.removed(device, result: result)
}
