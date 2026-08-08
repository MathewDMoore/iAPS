import Foundation

struct AfrezzaSession: Identifiable, Equatable {
    let id: String
    let dose: AfrezzaDoseEvent

    let glucoseAtDose: Int?
    let glucose30: Int?
    let glucose60: Int?
    let glucose90: Int?

    let nadirGlucose: Int?
    let nadirDate: Date?

    let peakGlucose: Int?
    let peakDate: Date?

    let deltaToNadir: Int?
    let minutesToNadir: Int?

    let isComplete: Bool

    init(
        dose: AfrezzaDoseEvent,
        glucoseAtDose: Int?,
        glucose30: Int?,
        glucose60: Int?,
        glucose90: Int?,
        nadirGlucose: Int?,
        nadirDate: Date?,
        peakGlucose: Int?,
        peakDate: Date?,
        deltaToNadir: Int?,
        minutesToNadir: Int?,
        isComplete: Bool
    ) {
        id = dose.id
        self.dose = dose
        self.glucoseAtDose = glucoseAtDose
        self.glucose30 = glucose30
        self.glucose60 = glucose60
        self.glucose90 = glucose90
        self.nadirGlucose = nadirGlucose
        self.nadirDate = nadirDate
        self.peakGlucose = peakGlucose
        self.peakDate = peakDate
        self.deltaToNadir = deltaToNadir
        self.minutesToNadir = minutesToNadir
        self.isComplete = isComplete
    }
}
