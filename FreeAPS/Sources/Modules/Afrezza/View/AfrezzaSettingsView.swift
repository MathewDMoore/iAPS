import SwiftUI
import Swinject

struct AfrezzaSettingsView: View {
    @StateObject private var prefs: AfrezzaPreferences
    @State private var newSizeText = ""
    @State private var recentDoses: [AfrezzaDoseEvent] = []
    @State private var lastLoggedSize: Int?

    private let doseStorage: AfrezzaDoseStorage

    init(
        resolver: Resolver,
        prefs: AfrezzaPreferences = AfrezzaPreferences()
    ) {
        doseStorage = resolver.resolve(AfrezzaDoseStorage.self)!
        _prefs = StateObject(wrappedValue: prefs)
    }

    var body: some View {
        Form {
            Section("Afrezza") {
                Toggle("Enable Afrezza", isOn: $prefs.enabled)
            }

            if prefs.enabled {
                Section {
                    HStack(spacing: 10) {
                        ForEach(prefs.cartridgeSizes.sorted(), id: \.self) { size in
                            Button {
                                logDose(size)
                            } label: {
                                Text("\(size) U")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Log \(size) unit Afrezza cartridge")
                        }
                    }

                    if let lastLoggedSize {
                        Label(
                            "Logged \(lastLoggedSize) U just now",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.green)
                    }
                } header: {
                    Text("Log inhalation")
                } footer: {
                    Text(
                        "Logs the labeled cartridge units only. " +
                            "This does not affect pump delivery, IOB, predictions, or automated dosing."
                    )
                }
            }

            Section {
                HStack {
                    TextField("Add cartridge size", text: $newSizeText)
                        .keyboardType(.numberPad)

                    Button("Add", action: addSize)
                        .disabled(!canAddSize)
                }

                ForEach(prefs.cartridgeSizes.sorted(), id: \.self) { size in
                    HStack {
                        Text("\(size) U cartridge")
                        Spacer()

                        if prefs.lastUsedSize == size {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        prefs.lastUsedSize = size
                    }
                }
                .onDelete(perform: deleteSizes)
            } header: {
                Text("Cartridge sizes")
            } footer: {
                Text(
                    "These values are Afrezza cartridge-label units " +
                        "and are not pump-bolus equivalents."
                )
            }

            Section {
                if recentDoses.isEmpty {
                    Text("No Afrezza doses recorded")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentDoses) { dose in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(dose.cartridgeUnits) U")
                                    .font(.headline)

                                Text(dose.source.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(dateFormatter.string(from: dose.date))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteDoses)
                }
            } header: {
                Text("Recent doses")
            } footer: {
                Text("Swipe left on an entry to remove an accidental log.")
            }
        }
        .navigationTitle("Afrezza")
        .toolbar {
            if !recentDoses.isEmpty {
                EditButton()
            }
        }
        .onAppear(perform: reloadDoses)
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }

    private var canAddSize: Bool {
        guard let value = Int(newSizeText) else { return false }
        return value > 0 && !prefs.cartridgeSizes.contains(value)
    }

    private func logDose(_ size: Int) {
        let event = AfrezzaDoseEvent(
            cartridgeUnits: size,
            source: .quickAction
        )

        doseStorage.store(event)
        prefs.lastUsedSize = size
        lastLoggedSize = size
        reloadDoses()

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func reloadDoses() {
        recentDoses = Array(doseStorage.all().prefix(20))
    }

    private func deleteDoses(at offsets: IndexSet) {
        let ids = offsets.map { recentDoses[$0].id }

        for id in ids {
            doseStorage.delete(id: id)
        }

        reloadDoses()
    }

    private func addSize() {
        guard canAddSize, let value = Int(newSizeText) else { return }
        prefs.cartridgeSizes.append(value)
        newSizeText = ""
    }

    private func deleteSizes(at offsets: IndexSet) {
        let sorted = prefs.cartridgeSizes.sorted()
        let valuesToDelete = offsets.map { sorted[$0] }

        guard prefs.cartridgeSizes.count - valuesToDelete.count >= 1 else {
            return
        }

        prefs.cartridgeSizes.removeAll { valuesToDelete.contains($0) }
    }
}
