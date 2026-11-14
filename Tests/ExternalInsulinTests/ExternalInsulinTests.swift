import Foundation
import XCTest
@testable import ExternalInsulinCore

final class ExternalInsulinTests: XCTestCase {
    // Synthetic record: index 1, seconds 3600, 2.5 U, 250 ms fraction.
    private func packet(halfUnits: Int16 = 5) -> Data {
        var b: [UInt8] = [0, 1, 0, 0, 0, 14, 16, 0, 5, 22, 90, 5, 0, 20]
        let value = UInt16(bitPattern: halfUnits)
        b[7] = UInt8(value >> 8)
        b[8] = UInt8(value & 0xFF)
        let crc = InPenRecordDecoder.crc16(b[...])
        b += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        return Data(b)
    }

    private func record(id: String = "a", units: Double = 3) -> ExternalInsulinRecord {
        ExternalInsulinRecord(id: id, date: Date().addingTimeInterval(-100), insulin: .toujeoU300,
                              units: units, origin: .manual, classification: .injection,
                              sourceRecordID: id, deviceID: nil, rawPacketHex: nil, note: nil)
    }

    func testKnownCRCVectorAndCorruptRecord() throws {
        XCTAssertEqual(InPenRecordDecoder.crc16(Array("123456789".utf8)[...]), 0xAEE7)
        var bad = packet()
        bad[8] ^= 1
        XCTAssertThrowsError(try InPenRecordDecoder.decode(bad, epoch: Date().addingTimeInterval(-4000), deviceID: "pen"))
        XCTAssertThrowsError(try InPenRecordDecoder.decode(Data([0]), epoch: Date(), deviceID: "pen"))
    }

    func testMixedEndianClockAndDose() throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let epoch = try InPenRecordDecoder.epoch(penTime: Data([0x10, 0x0E, 0, 0]), sampledAt: now)
        XCTAssertEqual(now.timeIntervalSince(epoch), 3600)
        let decoded = try InPenRecordDecoder.decode(packet(), epoch: epoch, deviceID: "pen", now: now)
        XCTAssertEqual(decoded.units, 2.5)
        XCTAssertEqual(decoded.classification, .needsReview)
        XCTAssertEqual(decoded.date, now)
        let rewind = try InPenRecordDecoder.decode(packet(halfUnits: -5), epoch: epoch, deviceID: "pen", now: now)
        XCTAssertEqual(rewind.classification, .rewind)
        XCTAssertEqual(rewind.units, 2.5)
    }

    func testRejectFutureInvalidClockAndInvalidDose() throws {
        XCTAssertThrowsError(try InPenRecordDecoder.epoch(penTime: Data([0xFF, 0xFF, 0xFF, 0xFF]), sampledAt: Date()))
        XCTAssertThrowsError(try InPenRecordDecoder.decode(packet(halfUnits: 61), epoch: Date(), deviceID: "pen"))
        XCTAssertThrowsError(try InPenRecordDecoder.decode(packet(), epoch: Date(), deviceID: "pen"))
        XCTAssertThrowsError(try record(units: .nan).validate())
        XCTAssertThrowsError(try record(units: 0).validate())
    }

    func testArchiveRoundTripDuplicateAndConflict() throws {
        let original = record()
        let archive = ExternalInsulinArchive(records: [original])
        let decoded = try ExternalInsulinArchive.decode(archive.encoded())
        XCTAssertEqual(decoded.records, [original])
        XCTAssertEqual(try ExternalInsulinArchive.merge([original], decoded.records).count, 1)
        let conflict = ExternalInsulinRecord(id: original.id, date: original.date, insulin: original.insulin,
                                           units: 4, origin: original.origin, classification: .injection,
                                           sourceRecordID: original.sourceRecordID, deviceID: nil,
                                           rawPacketHex: nil, note: nil)
        XCTAssertThrowsError(try ExternalInsulinArchive.merge([original], [conflict]))
        var json = try JSONSerialization.jsonObject(with: archive.encoded()) as! [String: Any]
        json["version"] = 99
        XCTAssertThrowsError(try ExternalInsulinArchive.decode(JSONSerialization.data(withJSONObject: json)))
    }

    @MainActor func testStorageRestartAndRepeatedBluetoothPacketKeepsClassification() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ExternalInsulinStore(directory: dir)
        let raw = packet()
        let first = try InPenRecordDecoder.decode(raw, epoch: Date().addingTimeInterval(-4000), deviceID: "pen")
        try store.add(first)
        try store.classify(id: first.id, as: .prime)
        let repeated = try InPenRecordDecoder.decode(raw, epoch: Date().addingTimeInterval(-3998), deviceID: "pen")
        try store.add(repeated)
        let reopened = ExternalInsulinStore(directory: dir)
        XCTAssertEqual(reopened.records.count, 1)
        XCTAssertEqual(reopened.records.first?.classification, .prime)
        XCTAssertEqual(reopened.records.first?.date, first.date)
    }

    @MainActor func testCorruptStoreCannotBeOverwritten() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history-v1.json")
        let original = Data("not JSON".utf8)
        try original.write(to: file)
        let store = ExternalInsulinStore(directory: dir)
        XCTAssertNotNil(store.error)
        XCTAssertThrowsError(try store.add(record()))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
