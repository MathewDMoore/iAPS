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
    static let baselineVersion = "baseline-v1"

    /// Display-only baseline model.
    ///
    /// This is an initial population-level approximation and is not yet
    /// personalized or validated for automated dosing.
    static let timeToPeak: TimeInterval = 40 * 60

    public static let afrezza = SimpleInsulinModelPreset(
        id: "afrezza-\(baselineVersion)",
        name: "Inhaled (Afrezza) — \(baselineVersion)",
        onset: 12 * 60,
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
        let peak = timeToPeak

        guard elapsed < duration else {
            return AfrezzaActivity(
                elapsed: elapsed,
                remaining: 0,
                activityFraction: 0,
                isActive: false
            )
        }

        let fraction: Double

        if elapsed <= onset {
            fraction = 0
        } else if elapsed <= peak {
            let progress = (elapsed - onset) / (peak - onset)

            // Smooth rise: zero slope at onset and peak.
            fraction = progress * progress * (3 - 2 * progress)
        } else {
            let progress = (elapsed - peak) / (duration - peak)

            // Smooth decline: one at peak, zero at modeled duration.
            let smooth = progress * progress * (3 - 2 * progress)
            fraction = 1 - smooth
        }

        return AfrezzaActivity(
            elapsed: elapsed,
            remaining: max(duration - elapsed, 0),
            activityFraction: min(max(fraction, 0), 1),
            isActive: true
        )
    }
}
