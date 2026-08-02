import Foundation

/// A manually recorded Afrezza inhalation.
///
/// `cartridgeUnits` are the labeled Afrezza cartridge units.
/// They must never be treated as pump-bolus units without an explicit,
/// separately validated conversion model.
struct AfrezzaDoseEvent: JSON, Identifiable, Equatable {
    enum Source: String, Codable, Sendable {
        case manual
        case quickAction
        case imported
    }

    let id: String
    let date: Date
    let cartridgeUnits: Int
    let source: Source
    let note: String?

    init(
        id: String = UUID().uuidString,
        date: Date = .now,
        cartridgeUnits: Int,
        source: Source = .manual,
        note: String? = nil
    ) {
        precondition(cartridgeUnits > 0, "Afrezza cartridge units must be greater than zero")

        self.id = id
        self.date = date
        self.cartridgeUnits = cartridgeUnits
        self.source = source
        self.note = note
    }
}
