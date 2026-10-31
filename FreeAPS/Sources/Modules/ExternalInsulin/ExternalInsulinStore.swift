import Combine
import Foundation

/// Separate local history: no pump history, HealthKit writeback, or automated dosing side effects.
/// A storage failure is visible and blocks writes instead of silently replacing existing history.
@MainActor final class ExternalInsulinStore: ObservableObject {
    static let shared = ExternalInsulinStore()
    @Published private(set) var records: [ExternalInsulinRecord] = []
    @Published private(set) var error: String?
    private let url: URL
    private var loaded = false

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExternalInsulin", isDirectory: true)
        url = directory.appendingPathComponent("history-v1.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                records = try ExternalInsulinArchive.merge([], ExternalInsulinArchive.decode(Data(contentsOf: url)).records)
            }
            loaded = true
        } catch {
            self.error = "Insulin history could not be opened: \(error.localizedDescription)"
        }
    }

    func add(_ record: ExternalInsulinRecord) throws {
        try record.validate()
        // Reconnects may re-read the same packet with a slightly different clock estimate.
        if let old = records.first(where: { $0.id == record.id }) {
            guard old.rawPacketHex == record.rawPacketHex, old.units == record.units,
                  old.insulin == record.insulin, old.sourceRecordID == record.sourceRecordID
            else { throw ExternalInsulinError.conflictingRecord }
            return
        }
        try save(ExternalInsulinArchive.merge(records, [record]))
    }

    func classify(id: String, as classification: ExternalInsulinRecord.Classification) throws {
        var updated = records
        guard let i = updated.firstIndex(where: { $0.id == id }) else { return }
        // Rewind events are not injections or primes.
        guard updated[i].classification != .rewind, classification != .rewind else { return }
        updated[i].classification = classification
        try save(updated)
    }

    func importArchive(_ data: Data) throws {
        let archive = try ExternalInsulinArchive.decode(data)
        try save(ExternalInsulinArchive.merge(records, archive.records))
    }

    private func save(_ updated: [ExternalInsulinRecord]) throws {
        guard loaded else { throw CocoaError(.fileReadCorruptFile) }
        do {
            let data = try ExternalInsulinArchive(records: updated).encoded()
            try data.write(to: url, options: .atomic)
            #if os(iOS)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path
                )
            #endif
            records = updated
            error = nil
        } catch {
            self.error = "Insulin history could not be saved: \(error.localizedDescription)"
            throw error
        }
    }
}
