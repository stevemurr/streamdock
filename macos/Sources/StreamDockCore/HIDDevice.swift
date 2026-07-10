import Foundation
import IOKit.hid

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

    private let manager: IOHIDManager
    private let ioLock = NSLock()
    private var device: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
    private var buttonHandler: ButtonHandler?
    private let callbackQueue = DispatchQueue(label: "com.streamdock.hid-input")

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: StreamDockProtocol.vendorID,
            kIOHIDProductIDKey as String: StreamDockProtocol.productID,
            kIOHIDPrimaryUsagePageKey as String: StreamDockProtocol.usagePage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
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

    public func connect() throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard device == nil else { return }
        let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard managerResult == kIOReturnSuccess else { throw HIDDeviceError.openFailed(managerResult) }
        guard let devices = IOHIDManagerCopyDevices(manager), CFSetGetCount(devices) > 0 else {
            throw HIDDeviceError.deviceNotFound
        }
        let count = CFSetGetCount(devices)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(devices, &values)
        guard let pointer = values.first ?? nil else { throw HIDDeviceError.deviceNotFound }
        let selected = Unmanaged<IOHIDDevice>.fromOpaque(pointer).takeUnretainedValue()
        let result = IOHIDDeviceOpen(selected, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw HIDDeviceError.openFailed(result) }
        device = selected

        IOHIDDeviceRegisterInputReportCallback(
            selected,
            inputBuffer,
            512,
            streamDockInputCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceSetDispatchQueue(selected, callbackQueue)
        IOHIDDeviceActivate(selected)
    }

    public func disconnect() {
        ioLock.lock()
        defer { ioLock.unlock() }
        if let device {
            IOHIDDeviceCancel(device)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func initialize(brightness: Int) throws {
        try send(StreamDockProtocol.mode())
        Thread.sleep(forTimeInterval: 0.05)
        try send(StreamDockProtocol.wake())
        try send(StreamDockProtocol.brightness(brightness))
    }

    public func keepAlive() throws { try send(StreamDockProtocol.keepAlive()) }
    public func wake() throws { try send(StreamDockProtocol.wake()) }
    public func sleepDisplay() throws { try send(StreamDockProtocol.sleep()) }
    public func setBrightness(_ value: Int) throws { try send(StreamDockProtocol.brightness(value)) }
    public func clearAll() throws { try send(StreamDockProtocol.clear()) }

    public func setImage(position: Int, jpeg: Data) throws {
        guard StreamDockProtocol.positionToSlot.indices.contains(position) else {
            throw HIDDeviceError.invalidPosition(position)
        }
        let slot = UInt8(StreamDockProtocol.positionToSlot[position])
        try send(StreamDockProtocol.beginImage(slot: slot, byteCount: jpeg.count))
        for offset in stride(from: 0, to: jpeg.count, by: StreamDockProtocol.packetSize) {
            let end = min(offset + StreamDockProtocol.packetSize, jpeg.count)
            try send(StreamDockProtocol.raw(jpeg.subdata(in: offset..<end)))
        }
        try send(StreamDockProtocol.refresh())
    }

    fileprivate func receive(_ bytes: UnsafePointer<UInt8>, length: Int) {
        guard let event = StreamDockProtocol.parseButtonReport(Data(bytes: bytes, count: length)) else { return }
        ioLock.lock()
        let handler = buttonHandler
        ioLock.unlock()
        handler?(event.position, event.isDown)
    }

    private func send(_ packet: Data) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let device else { throw HIDDeviceError.deviceNotFound }
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
        guard result == kIOReturnSuccess else { throw HIDDeviceError.writeFailed(result) }
    }
}

private let streamDockInputCallback: IOHIDReportCallback = {
    context, _, _, _, _, report, reportLength in
    guard let context else { return }
    let owner = Unmanaged<StreamDockHIDDevice>.fromOpaque(context).takeUnretainedValue()
    owner.receive(report, length: reportLength)
}
