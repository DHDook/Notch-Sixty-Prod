import Foundation

// E26 S3: rank-one bass conditioning for the L/R design. When both feeds reach the room through one subwoofer the
// 2x2 plant (two sources, two error points) is nearly rank one below the crossover, and a free joint solve lets L and
// R fight and can double the sub's drive. The band comes from the measured plant's per-bin condition number, not from
// a declared crossover, so the same rule works through a receiver (design 4). Pure control-plane maths: no engine
// access, nothing realtime, nothing here arms anything.

/// How one bin of the L/R design is treated.
enum BassPlantConditioningMode: Equatable, Sendable {
    /// Condition number at or under 10 dB: today's solve, untouched.
    case free
    /// 10 to 20 dB: the Tikhonov term is multiplied by `lambdaScale` (1 at 10 dB, rising to `maximumLambdaScale`).
    case tikhonov(lambdaScale: Double)
    /// Over 20 dB: the solution is constrained to common mode (one weight driven equally into L and R).
    case commonMode
}

/// The per-bin assessment of a 2x2 plant.
struct BassPlantConditioning: Equatable, Sendable {
    static let tikhonovStartDB = 10.0
    static let commonModeStartDB = 20.0
    static let maximumLambdaScale = 10.0

    let frequencyHz: Double
    /// 20·log10 of sigma_max / sigma_min; `.infinity` for a singular plant.
    let conditionDB: Double
    let mode: BassPlantConditioningMode

    var sharesSubwoofer: Bool { mode == .commonMode }

    /// Classify a condition number in dB. Non-finite or negative values read as fully rank one.
    static func mode(forConditionDB db: Double) -> BassPlantConditioningMode {
        guard db.isFinite, db >= 0 else { return .commonMode }
        if db > commonModeStartDB { return .commonMode }
        if db > tikhonovStartDB {
            let t = (db - tikhonovStartDB) / (commonModeStartDB - tikhonovStartDB)
            return .tikhonov(lambdaScale: 1 + (maximumLambdaScale - 1) * t)
        }
        return .free
    }

    /// Condition number of [[a, b], [c, d]] (rows are error points, columns are the L and R sources), from the closed
    /// form sigma_max^2 = (F + sqrt(F^2 - 4|det|^2)) / 2 and kappa = sigma_max^2 / |det|.
    static func conditionDB(
        leftToFirst a: ActiveQuietZoneComplex, rightToFirst b: ActiveQuietZoneComplex,
        leftToSecond c: ActiveQuietZoneComplex, rightToSecond d: ActiveQuietZoneComplex
    ) -> Double {
        let ad = a * d
        let bc = b * c
        let detMagnitude = (ad - bc).magnitude
        let f = a.magnitude * a.magnitude + b.magnitude * b.magnitude
            + c.magnitude * c.magnitude + d.magnitude * d.magnitude
        guard f.isFinite, f > 0 else { return .infinity }
        guard detMagnitude.isFinite, detMagnitude > 1.0e-15 * f else { return .infinity }
        let root = max(f * f - 4 * detMagnitude * detMagnitude, 0).squareRoot()
        let sigmaMaxSquared = (f + root) / 2
        return 10 * log10(sigmaMaxSquared * sigmaMaxSquared / (detMagnitude * detMagnitude))
    }

    static func assess(
        frequencyHz: Double,
        leftToFirst: ActiveQuietZoneComplex, rightToFirst: ActiveQuietZoneComplex,
        leftToSecond: ActiveQuietZoneComplex, rightToSecond: ActiveQuietZoneComplex
    ) -> BassPlantConditioning {
        let db = conditionDB(
            leftToFirst: leftToFirst, rightToFirst: rightToFirst,
            leftToSecond: leftToSecond, rightToSecond: rightToSecond)
        return BassPlantConditioning(frequencyHz: frequencyHz, conditionDB: db, mode: mode(forConditionDB: db))
    }
}

/// The conditioning of a whole measurement, for the Quiet Zone card.
struct BassPlantConditioningSummary: Equatable, Sendable {
    let bins: [BassPlantConditioning]

    /// Highest frequency, in Hz, of the contiguous run of shared-sub bins starting at the lowest bin; nil when the
    /// lowest bin is not shared (no rank-one band).
    var sharedBandUpperHz: Double? {
        let sorted = bins.sorted { $0.frequencyHz < $1.frequencyHz }
        guard sorted.first?.sharesSubwoofer == true else { return nil }
        var upper = sorted[0].frequencyHz
        for bin in sorted {
            if !bin.sharesSubwoofer { break }
            upper = bin.frequencyHz
        }
        return upper
    }

    /// Card text, e.g. "Below 90 Hz both channels share your subwoofer.", rounded to the nearest 5 Hz.
    var cardReadout: String? {
        guard let hz = sharedBandUpperHz else { return nil }
        let rounded = Int((hz / 5).rounded() * 5)
        return "Below \(rounded) Hz both channels share your subwoofer."
    }
}
