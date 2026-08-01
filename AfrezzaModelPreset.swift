import Foundation

/// A minimal protocol describing an insulin model preset.
public protocol InsulinModelPresetLike {
    var id: String { get }
    var name: String { get }
    var onset: TimeInterval { get } // seconds
    var duration: TimeInterval { get } // seconds
}

public struct SimpleInsulinModelPreset: InsulinModelPresetLike {
    public let id: String
    public let name: String
    public let onset: TimeInterval
    public let duration: TimeInterval

    public init(id: String, name: String, onset: TimeInterval, duration: TimeInterval) {
        self.id = id
        self.name = name
        self.onset = onset
        self.duration = duration
    }
}

public enum AfrezzaModelPreset {
    /// Approximate values: onset ~14 minutes, duration ~90 minutes
    public static let afrezza = SimpleInsulinModelPreset(
        id: "afrezza",
        name: "Inhaled (Afrezza)",
        onset: 14 * 60,
        duration: 90 * 60
    )
}
