import Combine
import SwiftUI
import Swinject

struct AfrezzaSettingsView: View {
    @StateObject private var prefs: AfrezzaPreferences
    @State private var newSizeText = ""
    @State private var recentDoses: [AfrezzaDoseEvent] = []
    @State private var lastLoggedSize: Int?
    @State private var activityDate = Date()
    @State private var selectedDose: AfrezzaDoseEvent?

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
                if let dose = latestActiveDose,
                   let activity = latestActivity
                {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(
                                "\(dose.cartridgeUnits) U",
                                systemImage: "wind"
                            )
                            .font(.headline)

                            Spacer()

                            Text("\(activityPercent(activity))%")
                                .font(.headline)
                                .monospacedDigit()
                        }

                        ProgressView(
                            value: activity.activityFraction,
                            total: 1
                        )
                        .tint(.green)

                        HStack {
                            Text("\(durationText(activity.elapsed)) elapsed")
                            Spacer()
                            Text("\(durationText(activity.remaining)) remaining")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    Label("No active Afrezza", systemImage: "wind")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Active Afrezza")
            } footer: {
                Text(
                    "Estimated activity is display-only and does not alter " +
                        "IOB, glucose predictions, SMBs, or pump delivery."
                )
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
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedDose = dose
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
        .onAppear {
            reloadDoses()
            activityDate = Date()
        }
        .onReceive(
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
        ) { date in
            activityDate = date
        }
        .sheet(item: $selectedDose) { dose in
            NavigationStack {
                AfrezzaDoseDetailView(
                    dose: dose,
                    doseStorage: doseStorage
                ) {
                    reloadDoses()
                    activityDate = Date()
                }
            }
        }
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }

    private var latestActiveDose: AfrezzaDoseEvent? {
        recentDoses.first { event in
            AfrezzaModelPreset.activity(
                for: event,
                at: activityDate
            ).isActive
        }
    }

    private var latestActivity: AfrezzaActivity? {
        guard let dose = latestActiveDose else { return nil }

        return AfrezzaModelPreset.activity(
            for: dose,
            at: activityDate
        )
    }

    private func activityPercent(_ activity: AfrezzaActivity) -> Int {
        Int((activity.activityFraction * 100).rounded())
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = max(Int(interval / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
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

private struct AfrezzaDoseDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let dose: AfrezzaDoseEvent
    let doseStorage: AfrezzaDoseStorage
    let onChanged: () -> Void

    @State private var editedDate: Date

    init(
        dose: AfrezzaDoseEvent,
        doseStorage: AfrezzaDoseStorage,
        onChanged: @escaping () -> Void
    ) {
        self.dose = dose
        self.doseStorage = doseStorage
        self.onChanged = onChanged
        _editedDate = State(initialValue: dose.date)
    }

    var body: some View {
        Form {
            Section("Dose") {
                LabeledContent("Cartridge", value: "\(dose.cartridgeUnits) U")
                LabeledContent("Source", value: dose.source.rawValue.capitalized)
                LabeledContent("Event ID", value: dose.id)
            }

            Section("Date and time") {
                DatePicker(
                    "Dose time",
                    selection: $editedDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }

            if let note = dose.note, !note.isEmpty {
                Section("Note") {
                    Text(note)
                }
            }

            Section {
                Button("Save corrected time") {
                    let corrected = AfrezzaDoseEvent(
                        id: dose.id,
                        date: editedDate,
                        cartridgeUnits: dose.cartridgeUnits,
                        source: dose.source,
                        note: dose.note
                    )

                    doseStorage.store(corrected)
                    onChanged()
                    dismiss()
                }
                .disabled(editedDate == dose.date)
            } footer: {
                Text(
                    "Saving keeps the existing Afrezza event ID and updates its timestamp. "
                        + "The activity display is recalculated from the corrected time. "
                        + "This does not initiate or alter pump insulin delivery."
                )
            }

            Section {
                Button(role: .destructive) {
                    doseStorage.delete(id: dose.id)
                    onChanged()
                    dismiss()
                } label: {
                    Text("Delete Afrezza dose")
                }
            } footer: {
                Text(
                    "Deletes only this manually recorded Afrezza event. "
                        + "It does not initiate, cancel, or modify insulin delivery."
                )
            }
        }
        .navigationTitle("Afrezza Dose")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    dismiss()
                }
            }
        }
    }
}
