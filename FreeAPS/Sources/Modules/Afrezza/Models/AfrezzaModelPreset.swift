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

struct AfrezzaActivity {
    let elapsed: TimeInterval
    let remaining: TimeInterval
    let activityFraction: Double
    let isActive: Bool
}

extension AfrezzaModelPreset {
    static func activity(
        for event: AfrezzaDoseEvent,
        at date: Date = .now
    ) -> AfrezzaActivity {
        let rawElapsed = date.timeIntervalSince(event.date)
        let duration = afrezza.duration

        guard rawElapsed >= 0 else {
            return AfrezzaActivity(
                elapsed: 0,
                remaining: duration,
                activityFraction: 0,
                isActive: false
            )
        }

        let elapsed = rawElapsed
        let onset = afrezza.onset
        let peak = 35 * 60.0

        guard elapsed < duration else {
            return AfrezzaActivity(
                elapsed: elapsed,
                remaining: 0,
                activityFraction: 0,
                isActive: false
            )
        }

        let fraction: Double

        if elapsed < onset {
            fraction = 0
        } else if elapsed <= peak {
            fraction = (elapsed - onset) / (peak - onset)
        } else {
            fraction = (duration - elapsed) / (duration - peak)
        }

        return AfrezzaActivity(
            elapsed: elapsed,
            remaining: max(duration - elapsed, 0),
            activityFraction: min(max(fraction, 0), 1),
            isActive: true
        )
    }
}
