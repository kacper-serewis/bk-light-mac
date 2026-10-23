import CoreBluetooth
import Foundation

/// BK-Light ACT1026 (32x32, advertises as `LED_BLE_*`) wire protocol.
/// Mirrors `bk_light/display_session.py` from Bk-Light-AppBypass.
enum PanelProtocol {
    static let writeUUID = CBUUID(string: "FA02")   // 0000fa02-0000-1000-8000-00805f9b34fb
    static let notifyUUID = CBUUID(string: "FA03")  // 0000fa03-0000-1000-8000-00805f9b34fb

    static let namePrefix = "LED_BLE_"
    static let tileSize = 32

    static let handshakeFirst = Data([0x08, 0x00, 0x01, 0x80, 0x0E, 0x06, 0x32, 0x00])
    static let ackStageOne = [
        Data([0x0C, 0x00, 0x01, 0x80, 0x81, 0x06, 0x32, 0x00, 0x00, 0x01, 0x00, 0x01]),
        Data([0x0B, 0x00, 0x01, 0x80, 0x83, 0x06, 0x32, 0x00, 0x00, 0x01, 0x00]), // ACT1025 variant
    ]
    static let ackFrame = [Data([0x05, 0x00, 0x02, 0x00, 0x03])]
    static let frameValidation = Data([0x05, 0x00, 0x00, 0x01, 0x00])

    /// Wraps PNG bytes in the image upload frame.
    static func buildFrame(png: Data) -> Data {
        let dataLength = png.count
        let totalLength = dataLength + 15
        var frame = Data()
        frame.append(UInt8(totalLength & 0xFF))
        frame.append(UInt8((totalLength >> 8) & 0xFF))
        frame.append(0x02)
        frame.append(contentsOf: [0x00, 0x00])
        frame.append(UInt8(dataLength & 0xFF))
        frame.append(UInt8((dataLength >> 8) & 0xFF))
        frame.append(contentsOf: [0x00, 0x00])
        let crc = crc32(png)
        frame.append(UInt8(crc & 0xFF))
        frame.append(UInt8((crc >> 8) & 0xFF))
        frame.append(UInt8((crc >> 16) & 0xFF))
        frame.append(UInt8((crc >> 24) & 0xFF))
        frame.append(contentsOf: [0x00, 0x65])
        frame.append(png)
        return frame
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: "-") }
}
