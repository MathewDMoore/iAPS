import Foundation

/// Wire format independently checked against xDrip+'s InPen RecordRx/TimeRx.
/// This decoder never creates a pump bolus and never assumes a dispense was injected.
enum InPenRecordDecoder {
    static func epoch(penTime: Data, sampledAt: Date) throws -> Date {
        let b = Array(penTime)
        guard b.count == 4 else { throw ExternalInsulinError.invalidClock }
        let seconds = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        let epoch = sampledAt.addingTimeInterval(-Double(seconds))
        guard epoch >= Date(timeIntervalSince1970: 1462628838), epoch <= sampledAt else {
            throw ExternalInsulinError.invalidClock
        }
        return epoch
    }

    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000) == 0 ? crc &<< 1 : (crc &<< 1) ^ 0x8005
            }
        }
        return crc
    }

    static func decode(_ data: Data, epoch: Date, deviceID: String, now: Date = Date()) throws
        -> ExternalInsulinRecord
    {
        let b = Array(data)
        guard b.count == 16 else { throw ExternalInsulinError.invalidPacket }
        func u16(_ n: Int) -> UInt16 { UInt16(b[n]) << 8 | UInt16(b[n + 1]) }
        guard crc16(b[0 ..< 14]) == u16(14), b[11] < 20 else {
            throw ExternalInsulinError.invalidPacket
        }
        let seconds = UInt32(b[3]) << 24 | UInt32(b[4]) << 16 | UInt32(b[5]) << 8 | UInt32(b[6])
        let halfUnits = Int16(bitPattern: u16(7))
        // InPen's supported dose range is 0.5-30 U; negative values represent rewinds.
        guard halfUnits != 0, abs(Int(halfUnits)) <= 60 else { throw ExternalInsulinError.invalidPacket }
        let date = epoch.addingTimeInterval(Double(seconds) + Double(b[11]) / 20)
        let hex = b.map { String(format: "%02x", $0) }.joined()
        let sourceID = "\(u16(0)):\(seconds):\(b[11])"
        let record = ExternalInsulinRecord(
            id: "inpen:\(deviceID):\(sourceID)", date: date, insulin: .fiaspU100,
            units: Double(abs(Int(halfUnits))) / 2, origin: .inPenBluetooth,
            classification: halfUnits < 0 ? .rewind : .needsReview,
            sourceRecordID: sourceID, deviceID: deviceID, rawPacketHex: hex,
            note: "InPen dispense; injection versus prime requires review. Flags: \(b[2])"
        )
        try record.validate(now: now)
        return record
    }
}
