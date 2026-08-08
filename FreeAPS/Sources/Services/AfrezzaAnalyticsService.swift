import Foundation

final class AfrezzaAnalyticsService {
    private let checkpointTolerance: TimeInterval = 7.5 * 60

    func session(
        for dose: AfrezzaDoseEvent,
        glucose: [BloodGlucose],
        at now: Date = .now
    ) -> AfrezzaSession {
        let duration = AfrezzaModelPreset.afrezza.duration
        let endDate = dose.date.addingTimeInterval(duration)

        let readings = glucose
            .filter { $0.glucose != nil }
            .sorted { $0.dateString < $1.dateString }

        let glucoseAtDose = nearestReading(
            to: dose.date,
            in: readings,
            tolerance: checkpointTolerance
        )

        let glucose30 = checkpoint(
            minutes: 30,
            after: dose.date,
            readings: readings,
            now: now
        )

        let glucose60 = checkpoint(
            minutes: 60,
            after: dose.date,
            readings: readings,
            now: now
        )

        let glucose90 = checkpoint(
            minutes: 90,
            after: dose.date,
            readings: readings,
            now: now
        )

        let observedWindowEnd = min(now, endDate)

        let windowReadings = readings.filter {
            $0.dateString >= dose.date &&
                $0.dateString <= observedWindowEnd
        }

        let nadirReading = windowReadings.min {
            ($0.glucose ?? Int.max) < ($1.glucose ?? Int.max)
        }

        let peakReading = windowReadings.max {
            ($0.glucose ?? Int.min) < ($1.glucose ?? Int.min)
        }

        let startValue = glucoseAtDose?.glucose
        let nadirValue = nadirReading?.glucose

        let deltaToNadir: Int? = {
            guard let startValue, let nadirValue else { return nil }
            return nadirValue - startValue
        }()

        let minutesToNadir: Int? = {
            guard let nadirReading else { return nil }
            return max(
                0,
                Int(nadirReading.dateString.timeIntervalSince(dose.date) / 60)
            )
        }()

        return AfrezzaSession(
            dose: dose,
            glucoseAtDose: glucoseAtDose?.glucose,
            glucose30: glucose30?.glucose,
            glucose60: glucose60?.glucose,
            glucose90: glucose90?.glucose,
            nadirGlucose: nadirReading?.glucose,
            nadirDate: nadirReading?.dateString,
            peakGlucose: peakReading?.glucose,
            peakDate: peakReading?.dateString,
            deltaToNadir: deltaToNadir,
            minutesToNadir: minutesToNadir,
            isComplete: now >= endDate
        )
    }

    private func checkpoint(
        minutes: Int,
        after doseDate: Date,
        readings: [BloodGlucose],
        now: Date
    ) -> BloodGlucose? {
        let target = doseDate.addingTimeInterval(TimeInterval(minutes) * 60)

        guard now >= target else {
            return nil
        }

        return nearestReading(
            to: target,
            in: readings,
            tolerance: checkpointTolerance
        )
    }

    private func nearestReading(
        to target: Date,
        in readings: [BloodGlucose],
        tolerance: TimeInterval
    ) -> BloodGlucose? {
        guard let reading = readings.min(by: {
            abs($0.dateString.timeIntervalSince(target)) <
                abs($1.dateString.timeIntervalSince(target))
        }) else {
            return nil
        }

        let distance = abs(reading.dateString.timeIntervalSince(target))

        guard distance <= tolerance else {
            return nil
        }

        return reading
    }
}
