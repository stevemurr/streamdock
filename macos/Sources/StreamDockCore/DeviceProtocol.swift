import Foundation

public enum StreamDockProtocol {
    public static let vendorID = 0x5548
    public static let productID = 0x1000
    public static let usagePage = 0xFFA0
    public static let packetSize = 1024
    public static let keyPixelSize = 64
    public static let positionToSlot = [11, 12, 13, 14, 15, 6, 7, 8, 9, 10, 1, 2, 3, 4, 5]

    /// Key ids of the three screenless hardware buttons under the screen,
    /// left to right (captured on hardware). They map to positions 15/16/17,
    /// continuing reading order past the LCD grid.
    public static let bottomButtonKeyIDs: [UInt8] = [0x25, 0x30, 0x31]

    public static var bottomButtonPositions: Range<Int> {
        positionToSlot.count..<(positionToSlot.count + bottomButtonKeyIDs.count)
    }

    private static let commandPrefix = Data([0x43, 0x52, 0x54, 0x00, 0x00])

    public static func command(_ payload: Data, includeReportID: Bool = true) -> Data {
        packet(commandPrefix + payload, includeReportID: includeReportID)
    }

    public static func raw(_ payload: Data, includeReportID: Bool = true) -> Data {
        packet(payload, includeReportID: includeReportID)
    }

    public static func mode(_ value: UInt8 = 3) -> Data {
        command(Data([0x4d, 0x4f, 0x44, 0x00, 0x00, 0x30 + value]))
    }

    public static func wake() -> Data { command(Data([0x44, 0x49, 0x53, 0x00, 0x00])) }
    public static func sleep() -> Data { command(Data([0x48, 0x41, 0x4e, 0x00, 0x00])) }
    public static func keepAlive() -> Data { command(Data("CONNECT".utf8)) }
    public static func refresh() -> Data { command(Data([0x53, 0x54, 0x50, 0x00, 0x00])) }

    public static func brightness(_ value: Int) -> Data {
        command(Data([0x4c, 0x49, 0x47, 0x00, 0x00, UInt8(max(0, min(100, value)))]))
    }

    public static func clear(slot: UInt8 = 0xff) -> Data {
        command(Data([0x43, 0x4c, 0x45, 0x00, 0x00, 0x00, slot]))
    }

    public static func beginImage(slot: UInt8, byteCount: Int) -> Data {
        var length = UInt32(byteCount).bigEndian
        var payload = Data([0x42, 0x41, 0x54])
        withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
        payload.append(slot)
        return command(payload)
    }

    public static func parseButtonReport(_ data: Data) -> (position: Int, isDown: Bool)? {
        guard data.count >= 11,
              data[0] == 0x41, data[1] == 0x43, data[2] == 0x4b else { return nil }
        let keyID = Int(data[9])
        if keyID > 0 && keyID <= positionToSlot.count {
            return (keyID - 1, data[10] != 0)
        }
        if let index = bottomButtonKeyIDs.firstIndex(of: data[9]) {
            return (positionToSlot.count + index, data[10] != 0)
        }
        return nil
    }

    private static func packet(_ payload: Data, includeReportID: Bool) -> Data {
        precondition(payload.count <= packetSize)
        var result = Data(repeating: 0, count: packetSize + (includeReportID ? 1 : 0))
        let offset = includeReportID ? 1 : 0
        result.replaceSubrange(offset..<(offset + payload.count), with: payload)
        return result
    }
}
