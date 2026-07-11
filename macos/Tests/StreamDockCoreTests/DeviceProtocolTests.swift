import Foundation
import XCTest
@testable import StreamDockCore

final class DeviceProtocolTests: XCTestCase {
    func testCommandPacketsHaveReportIDAndExactProtocolLength() {
        let packet = StreamDockProtocol.mode()
        XCTAssertEqual(packet.count, 1025)
        XCTAssertEqual(packet[0], 0)
        XCTAssertEqual(Array(packet[1...5]), [0x43, 0x52, 0x54, 0x00, 0x00])
        XCTAssertEqual(Array(packet[6...11]), [0x4d, 0x4f, 0x44, 0x00, 0x00, 0x33])
    }

    func testButtonReportsMapToReadingOrder() {
        var report = Data(repeating: 0, count: 11)
        report.replaceSubrange(0..<3, with: Data("ACK".utf8))
        report[9] = 15
        report[10] = 1
        let event = StreamDockProtocol.parseButtonReport(report)
        XCTAssertEqual(event?.position, 14)
        XCTAssertEqual(event?.isDown, true)
    }

    func testBottomButtonsMapToPositionsPastTheGrid() {
        // ids captured on hardware: left/middle/right under the screen
        for (index, keyID) in [UInt8(0x25), 0x30, 0x31].enumerated() {
            var report = Data(repeating: 0, count: 11)
            report.replaceSubrange(0..<3, with: Data("ACK".utf8))
            report[9] = keyID
            report[10] = 1
            let event = StreamDockProtocol.parseButtonReport(report)
            XCTAssertEqual(event?.position, 15 + index)
            XCTAssertEqual(event?.isDown, true)
        }
    }

    func testUnknownKeyIDsAreDropped() {
        for keyID in [UInt8(0), 16, 0x24, 0x32] {
            var report = Data(repeating: 0, count: 11)
            report.replaceSubrange(0..<3, with: Data("ACK".utf8))
            report[9] = keyID
            report[10] = 1
            XCTAssertNil(StreamDockProtocol.parseButtonReport(report))
        }
    }

    func testSlotMapMatchesPhysicalDeck() {
        XCTAssertEqual(
            StreamDockProtocol.positionToSlot,
            [11, 12, 13, 14, 15, 6, 7, 8, 9, 10, 1, 2, 3, 4, 5]
        )
    }
}
