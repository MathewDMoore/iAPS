import SwiftUI
import UniformTypeIdentifiers

struct ExternalInsulinDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ExternalInsulinView: View {
    @ObservedObject private var store = ExternalInsulinStore.shared
    @ObservedObject private var reader = InPenBluetoothReader.shared
    let afrezzaStorage: AfrezzaDoseStorage?
    @State private var insulin = ExternalInsulinRecord.Insulin.toujeoU300
    @State private var units = ""
    @State private var date = Date()
    @State private var message: String?
    @State private var exporting = false
    @State private var importing = false
    @State private var document = ExternalInsulinDocument()

    var body: some View {
        Form {
            Section {
                Text("This history is for tracking and review. It does not change pump delivery or the insulin-on-board shown by iAPS.")
                    .font(.footnote)
                if let error = store.error { Text(error).foregroundStyle(.red) }
                if let message = message { Text(message).foregroundStyle(.orange) }
            }
            Section("Log an injection") {
                Picker("Insulin", selection: $insulin) {
                    Text("Toujeo U-300").tag(ExternalInsulinRecord.Insulin.toujeoU300)
                    Text("Fiasp U-100").tag(ExternalInsulinRecord.Insulin.fiaspU100)
                }
                TextField("Units shown on your pen", text: $units).keyboardType(.decimalPad)
                DatePicker("Taken", selection: $date, in: ...Date())
                Text("Enter the units on the pen dial. Toujeo U-300 needs no volume or concentration conversion.")
                    .font(.footnote)
                Button("Save injection") { saveInjection() }
                    .disabled(store.error != nil || dose == nil)
            }
            Section("InPen Bluetooth - experimental") {
                Text(reader.status)
                if let lastSync = reader.lastSync {
                    Text("Last completed sync: \(lastSync.formatted())").font(.footnote)
                }
                if reader.enabled {
                    Button("Sync now") { reader.sync() }
                    Button("Stop reading") { reader.stop() }
                } else {
                    Button("Find my InPen") { reader.start() }
                }
                ForEach(reader.nearby) { pen in
                    Button("Connect to \(pen.name)") { reader.connect(pen.id) }
                }
                Text("Reads history only if this iPhone is already authorized by the pen. New direct pairing is not available yet. Every positive dispense needs review as an injection or prime.")
                    .font(.footnote)
            }
            Section("MetabolicTwin / backup") {
                Button("Export shared insulin history") { exportHistory() }
                Button("Import shared insulin history") { importing = true }
                Text("Exports Toujeo, Fiasp, and available Afrezza entries with stable source identifiers. Importing the same unchanged archive twice does not duplicate records. MetabolicTwin still needs its matching import screen.")
                    .font(.footnote)
            }
            Section("History") {
                if store.records.isEmpty { Text("No external insulin records yet.") }
                ForEach(store.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(record.insulin.title): \(record.units.formatted()) U").font(.headline)
                        Text(record.date.formatted()).font(.caption)
                        Text("Source: \(record.origin.rawValue)").font(.caption)
                        if record.classification == .rewind {
                            Text("Rewind - not an injection").font(.caption)
                        } else {
                            Picker("Event type", selection: Binding(
                                get: { record.classification },
                                set: { classification in
                                    do { try store.classify(id: record.id, as: classification) }
                                    catch { message = error.localizedDescription }
                                }
                            )) {
                                Text("Needs review").tag(ExternalInsulinRecord.Classification.needsReview)
                                Text("Injection").tag(ExternalInsulinRecord.Classification.injection)
                                Text("Prime").tag(ExternalInsulinRecord.Classification.prime)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("External insulin")
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "External-Insulin-History") { result in
            if case let .failure(error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 10 * 1024 * 1024 else { throw ExternalInsulinError.invalidRecord }
                try store.importArchive(Data(contentsOf: url))
                message = "History imported. Pump dosing calculations are unchanged."
            } catch { message = error.localizedDescription }
        }
    }

    private var dose: Double? {
        let scanner = Scanner(string: units.trimmingCharacters(in: .whitespacesAndNewlines))
        scanner.locale = Locale.current
        guard let value = scanner.scanDouble(), scanner.isAtEnd, value.isFinite, value > 0 else { return nil }
        // Validate units against the selected pen's dial, not a concentration multiplier.
        let limit = insulin == .toujeoU300 ? 160.0 : 30.0
        let increment = insulin == .toujeoU300 ? 1.0 : 0.5
        guard value <= limit, abs(value / increment - (value / increment).rounded()) < 0.0001 else { return nil }
        return value
    }

    private func saveInjection() {
        guard let dose = dose else { return }
        let id = UUID().uuidString
        let record = ExternalInsulinRecord(
            id: "manual:\(id)", date: date, insulin: insulin, units: dose, origin: .manual,
            classification: .injection, sourceRecordID: id, deviceID: nil, rawPacketHex: nil, note: nil
        )
        do {
            try store.add(record)
            units = ""
            date = Date()
            message = "Injection saved."
        } catch { message = error.localizedDescription }
    }

    private func exportHistory() {
        do {
            let afrezza = (afrezzaStorage?.all() ?? []).map { dose in
                ExternalInsulinRecord(
                    id: "afrezza:\(dose.id)", date: dose.date, insulin: .afrezza,
                    units: Double(dose.cartridgeUnits), origin: .manual, classification: .injection,
                    sourceRecordID: "afrezza:\(dose.id)", deviceID: nil, rawPacketHex: nil,
                    note: "Labeled cartridge units; not equivalent to injected or pump units. \(dose.note ?? "")"
                )
            }
            let records = try ExternalInsulinArchive.merge(store.records, afrezza)
            document = ExternalInsulinDocument(data: try ExternalInsulinArchive(records: records).encoded())
            exporting = true
        } catch { message = error.localizedDescription }
    }
}
