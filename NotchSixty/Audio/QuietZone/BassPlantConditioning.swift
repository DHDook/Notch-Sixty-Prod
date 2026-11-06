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

extension BassPlantConditioning {
    /// E26 S6c: the conditioning of an N x 2 plant (rows: seats, columns: L and R). The singular values come from the
    /// Hermitian 2x2 Gram matrix [[a, b], [b*, d]]; the condition is 10 log10 of the eigenvalue ratio, which equals
    /// 20 log10 of the singular-value ratio and agrees with `conditionDB` for two rows. Non-finite input or fewer
    /// than two rows reads as fully rank one.
    static func assess(
        frequencyHz: Double, seats: [(left: ActiveQuietZoneComplex, right: ActiveQuietZoneComplex)]
    ) -> BassPlantConditioning {
        var a = 0.0
        var d = 0.0
        var b = ActiveQuietZoneComplex.zero
        for seat in seats {
            a += seat.left.magnitude * seat.left.magnitude
            d += seat.right.magnitude * seat.right.magnitude
            b = b + seat.left.conjugate * seat.right
        }
        let trace = a + d
        let det = a * d - b.magnitude * b.magnitude
        guard seats.count >= 2, trace.isFinite, trace > 0, det.isFinite, det > 1.0e-15 * trace * trace else {
            return BassPlantConditioning(frequencyHz: frequencyHz, conditionDB: .infinity, mode: .commonMode)
        }
        let root = max(trace * trace - 4 * det, 0).squareRoot()
        let largest = (trace + root) / 2
        let smallest = det / largest
        let db = 10 * log10(largest / smallest)
        return BassPlantConditioning(frequencyHz: frequencyHz, conditionDB: db, mode: mode(forConditionDB: db))
    }

    /// The stricter of two treatments (never looser): common mode, then Tikhonov with the larger scale, then free.
    static func stricter(_ x: BassPlantConditioningMode, _ y: BassPlantConditioningMode) -> BassPlantConditioningMode {
        switch (x, y) {
        case (.commonMode, _), (_, .commonMode): return .commonMode
        case (.tikhonov(let p), .tikhonov(let q)): return .tikhonov(lambdaScale: max(p, q))
        case (.tikhonov, .free): return x
        case (.free, _): return y
        }
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

// E26 S3b: the measured plant behind the conditioning. The feed-forward survey already measures the 2x2 plant at every
// band: both sources (L, R) to the seat (error point) and to the upstream reference microphone (the second point).

extension BassPlantConditioning {
    /// The conditioning of one survey band (rows: seat, reference microphone; columns: L, R).
    static func assess(band: QuietZoneVirtualSeatBand) -> BassPlantConditioning {
        assess(
            frequencyHz: band.frequencyHz,
            leftToFirst: band.leftSecondaryAtListener, rightToFirst: band.rightSecondaryAtListener,
            leftToSecond: band.leftLeakageAtReference, rightToSecond: band.rightLeakageAtReference
        )
    }
}

extension BassPlantConditioningSummary {
    /// One bin per survey band, lowest frequency first.
    init(bands: [QuietZoneVirtualSeatBand]) {
        self.init(bins: bands.sorted { $0.frequencyHz < $1.frequencyHz }.map { BassPlantConditioning.assess(band: $0) })
    }

    /// The treatment of a whole L/R filter pair that spans [lowHz, highHz] with one set of weights (the feed-forward
    /// shadow). All bins common mode: common mode. Any bin rank one or ill-conditioned: Tikhonov at the largest scale
    /// in the band (stricter, never looser, because the pair cannot be split by frequency). Otherwise free.
    func pairMode(lowHz: Double, highHz: Double) -> BassPlantConditioningMode {
        let inBand = bins.filter { $0.frequencyHz >= lowHz && $0.frequencyHz <= highHz }
        guard !inBand.isEmpty else { return .free }
        if inBand.allSatisfy({ $0.mode == .commonMode }) { return .commonMode }
        var scale = 1.0
        var any = false
        for bin in inBand {
            switch bin.mode {
            case .free: break
            case .tikhonov(let s): any = true; scale = max(scale, s)
            case .commonMode: any = true; scale = BassPlantConditioning.maximumLambdaScale
            }
        }
        return any ? .tikhonov(lambdaScale: scale) : .free
    }
}

/// The measured plant looked up by tone frequency (the tonal controller works at tones, the survey at third-octave
/// bands). A tone uses the nearest band within a third of an octave; further than that there is no measurement and the
/// lookup is nil, which the caller reads as free (readiness, S5, owns refusing a missing plant).
struct BassPlantMap: Equatable, Sendable {
    static let toleranceOctaves = 1.0 / 3.0

    private(set) var bands: [QuietZoneVirtualSeatBand]

    init(bands: [QuietZoneVirtualSeatBand]) {
        self.bands = bands.filter { $0.frequencyHz.isFinite && $0.frequencyHz > 0 }.sorted { $0.frequencyHz < $1.frequencyHz }
    }

    var isEmpty: Bool { bands.isEmpty }
    var summary: BassPlantConditioningSummary { BassPlantConditioningSummary(bands: bands) }

    func conditioning(atHz frequencyHz: Double) -> BassPlantConditioning? {
        guard frequencyHz > 0, let nearest = bands.min(by: {
            abs(log2($0.frequencyHz / frequencyHz)) < abs(log2($1.frequencyHz / frequencyHz))
        }), abs(log2(nearest.frequencyHz / frequencyHz)) <= Self.toleranceOctaves else { return nil }
        return BassPlantConditioning.assess(band: nearest)
    }

    func mode(atHz frequencyHz: Double) -> BassPlantConditioningMode {
        conditioning(atHz: frequencyHz)?.mode ?? .free
    }
}
