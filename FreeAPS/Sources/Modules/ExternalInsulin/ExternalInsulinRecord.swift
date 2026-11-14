import Foundation

/// Shared, observation-only history. Never feed these records to pump history or oref0.
struct ExternalInsulinRecord: Codable, Identifiable, Equatable {
    enum Insulin: String, Codable, CaseIterable {
        case toujeoU300
        case fiaspU100
        case afrezza

        var title: String {
            switch self {
            case .toujeoU300: return "Toujeo U-300"
            case .fiaspU100: return "Fiasp U-100"
            case .afrezza: return "Afrezza (labeled cartridge units)"
            }
        }
    }

    enum Origin: String, Codable { case manual, inPenBluetooth, report }
    enum Classification: String, Codable, CaseIterable {
        case needsReview, injection, prime, rewind
    }

    let id: String
    let date: Date
    let insulin: Insulin
    let units: Double
    let origin: Origin
    var classification: Classification
    let sourceRecordID: String
    let deviceID: String?
    let rawPacketHex: String?
    let note: String?

    init(id: String, date: Date, insulin: Insulin, units: Double, origin: Origin,
         classification: Classification, sourceRecordID: String, deviceID: String?,
         rawPacketHex: String?, note: String?) {
        self.id = id
        // Exchange timestamps have one-second precision; packet bytes preserve the pen's finer timing.
        self.date = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        self.insulin = insulin
        self.units = units
        self.origin = origin
        self.classification = classification
        self.sourceRecordID = sourceRecordID
        self.deviceID = deviceID
        self.rawPacketHex = rawPacketHex
        self.note = note
    }

    func validate(now: Date = Date()) throws {
        guard !id.isEmpty, !sourceRecordID.isEmpty,
              units.isFinite, units > 0,
              date.timeIntervalSince1970.isFinite,
              date <= now.addingTimeInterval(300),
              date >= Date(timeIntervalSince1970: 946684800)
        else { throw ExternalInsulinError.invalidRecord }
        if origin == .inPenBluetooth {
            guard insulin == .fiaspU100, let deviceID = deviceID, !deviceID.isEmpty,
                  let rawPacketHex = rawPacketHex, rawPacketHex.count == 32
            else { throw ExternalInsulinError.invalidRecord }
        }
    }
}

enum ExternalInsulinError: LocalizedError {
    case invalidRecord, unsupportedSchema, conflictingRecord, invalidPacket, invalidClock

    var errorDescription: String? {
        switch self {
        case .invalidRecord: return "The insulin record has invalid or incomplete values."
        case .unsupportedSchema: return "This insulin history format is not supported."
        case .conflictingRecord: return "A source identifier has conflicting records. Nothing was imported."
        case .invalidPacket: return "The InPen record failed its length, checksum, or value check."
        case .invalidClock: return "The InPen clock could not be verified."
        }
    }
}

/// Versioned exchange with MetabolicTwin. IDs survive repeated exports/imports.
struct ExternalInsulinArchive: Codable {
    let schema: String
    let version: Int
    let exportedAt: Date
    let records: [ExternalInsulinRecord]

    init(records: [ExternalInsulinRecord], exportedAt: Date = Date()) {
        schema = "org.metabolictwin.external-insulin-history"
        version = 1
        self.exportedAt = exportedAt
        self.records = records
    }

    static func decode(_ data: Data) throws -> ExternalInsulinArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Self.self, from: data)
        guard archive.schema == "org.metabolictwin.external-insulin-history", archive.version == 1 else {
            throw ExternalInsulinError.unsupportedSchema
        }
        for record in archive.records { try record.validate() }
        return archive
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func merge(_ existing: [ExternalInsulinRecord], _ incoming: [ExternalInsulinRecord]) throws
        -> [ExternalInsulinRecord]
    {
        var byID = [String: ExternalInsulinRecord]()
        var bySource = [String: ExternalInsulinRecord]()
        for record in existing + incoming {
            try record.validate()
            let key = "\(record.origin.rawValue)|\(record.deviceID ?? "")|\(record.sourceRecordID)"
            if let old = byID[record.id], old != record { throw ExternalInsulinError.conflictingRecord }
            if let old = bySource[key], old != record { throw ExternalInsulinError.conflictingRecord }
            byID[record.id] = record
            bySource[key] = record
        }
        return byID.values.sorted { $0.date > $1.date }
    }
}
