import SwiftUI

struct AfrezzaSettingsView: View {
    @StateObject private var prefs: AfrezzaPreferences
    @State private var newSizeText = ""

    init(prefs: AfrezzaPreferences = AfrezzaPreferences()) {
        _prefs = StateObject(wrappedValue: prefs)
    }

    var body: some View {
        Form {
            Section("Afrezza") {
                Toggle("Enable Afrezza", isOn: $prefs.enabled)
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
                Text("These values are Afrezza cartridge-label units and are not pump-bolus equivalents.")
            }
        }
        .navigationTitle("Afrezza")
    }

    private var canAddSize: Bool {
        guard let value = Int(newSizeText) else { return false }
        return value > 0 && !prefs.cartridgeSizes.contains(value)
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

#Preview {
    NavigationStack {
        AfrezzaSettingsView()
    }
}
