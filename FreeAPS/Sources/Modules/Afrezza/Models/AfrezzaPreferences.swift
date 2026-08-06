import Foundation
import SwiftUI

@MainActor final class AfrezzaPreferences: ObservableObject {
    // Toggle to enable/disable Afrezza features in the UI
    @AppStorage("afrezzaEnabled") var enabled: Bool = true

    // Persisted cartridge sizes and last-used size
    @AppStorage("afrezzaCartridgeSizes") private var sizesData = Data()
    @AppStorage("afrezzaLastUsedSize") var lastUsedSize: Int = 8

    // In-memory representation of cartridge sizes
    @Published var cartridgeSizes: [Int] = [4, 8] {
        didSet { persistSizes() }
    }

    init() {
        // Load persisted sizes if available
        if let sizes = try? JSONDecoder().decode([Int].self, from: sizesData), !sizes.isEmpty {
            cartridgeSizes = sizes
        }
        // Ensure lastUsedSize is valid
        if !cartridgeSizes.contains(lastUsedSize) {
            lastUsedSize = cartridgeSizes.sorted().first ?? 8
        }
    }

    private func persistSizes() {
        let sanitized = Array(Set(cartridgeSizes.filter { $0 > 0 })).sorted()
        if let data = try? JSONEncoder().encode(sanitized) {
            sizesData = data
        }
        if !sanitized.contains(lastUsedSize) {
            lastUsedSize = sanitized.first ?? 8
        }
        if cartridgeSizes != sanitized {
            cartridgeSizes = sanitized
        }
    }

    func nearestCartridge(for units: Double) -> Int {
        let sizes = cartridgeSizes.sorted()
        guard let first = sizes.first else { return lastUsedSize }
        let best = sizes.min(by: { abs(Double($0) - units) < abs(Double($1) - units) }) ?? first
        return best
    }
}
