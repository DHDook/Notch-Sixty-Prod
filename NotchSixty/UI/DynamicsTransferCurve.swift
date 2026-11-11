import Foundation

/// E28 S5 (design 10): the static gain computer of a dynamics stage, drawn as an input-to-output curve with a
/// live dot. Plain Swift; no UI and no engine access. The compressor law is the soft-knee downward law of
/// Giannoulis, Massberg and Reiss, "Digital Dynamic Range Compressor Design", JAES 60(6), 2012, the same
/// arithmetic as the core stage (`compressor_target_gain_db`), and a test pins it to the core.
///
/// `gainDB(atInput:)` is the stage's gain at a steady input level, makeup included. The engine reports
/// reduction as max(0, -gain), so the live dot is placed by inverting the same law (`inputDB(forReductionDB:)`).
struct DynamicsTransferCurve: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Soft-knee downward compression (compressor, multiband band, de-esser).
        case compressor
        /// Downward expansion below the threshold, floored at `floorDB` (the expander's range).
        case expander
        /// Brick-wall: nothing above `thresholdDB` (the ceiling).
        case limiter
    }

    var kind: Kind
    var thresholdDB: Double
    var ratio: Double = 1
    var kneeDB: Double = 0
    var makeupDB: Double = 0
    /// The lowest gain the stage applies (negative dB), nil for none. The expander range and the de-esser range.
    var floorDB: Double? = nil

    /// The knee of the de-esser's law (core: soft knee 3 dB).
    static let deEsserKneeDB = 3.0

    // MARK: Factories from the stage configurations

    init(kind: Kind, thresholdDB: Double, ratio: Double = 1, kneeDB: Double = 0, makeupDB: Double = 0, floorDB: Double? = nil) {
        self.kind = kind
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.kneeDB = kneeDB
        self.makeupDB = makeupDB
        self.floorDB = floorDB
    }

    init(_ compressor: CompressorConfiguration) {
        self.init(kind: .compressor, thresholdDB: compressor.thresholdDB, ratio: compressor.ratio,
                  kneeDB: compressor.kneeWidthDB, makeupDB: compressor.makeupGainDB)
    }

    init(_ expander: ExpanderConfiguration) {
        self.init(kind: .expander, thresholdDB: expander.thresholdDB, ratio: expander.ratio,
                  kneeDB: expander.kneeDB ?? 0, floorDB: expander.rangeDB)
    }

    init(_ limiter: LimiterConfiguration) {
        self.init(kind: .limiter, thresholdDB: limiter.ceilingDB)
    }

    init(_ deEsser: DeEsserConfiguration) {
        self.init(kind: .compressor, thresholdDB: deEsser.thresholdDB, ratio: deEsser.ratio,
                  kneeDB: Self.deEsserKneeDB, floorDB: deEsser.rangeDB)
    }

    /// One band of the multiband compressor: 0 low, 1 mid, 2 high.
    init(_ multiband: MultibandCompressorConfiguration, band: Int) {
        switch band {
        case 0:
            self.init(kind: .compressor, thresholdDB: multiband.lowThresholdDB, ratio: multiband.lowRatio,
                      kneeDB: multiband.lowKneeDB, makeupDB: multiband.lowMakeupGainDB)
        case 1:
            self.init(kind: .compressor, thresholdDB: multiband.midThresholdDB, ratio: multiband.midRatio,
                      kneeDB: multiband.midKneeDB, makeupDB: multiband.midMakeupGainDB)
        default:
            self.init(kind: .compressor, thresholdDB: multiband.highThresholdDB, ratio: multiband.highRatio,
                      kneeDB: multiband.highKneeDB, makeupDB: multiband.highMakeupGainDB)
        }
    }

    // MARK: The law

    /// Gain in dB at a steady input level (negative is reduction), makeup included.
    func gainDB(atInput input: Double) -> Double {
        guard input.isFinite else { return makeupDB }
        switch kind {
        case .limiter:
            return min(0, thresholdDB - input)
        case .expander:
            return max(expansionDB(atInput: input), floorDB ?? -.infinity)
        case .compressor:
            let compression = max(compressionDB(atInput: input), floorDB ?? -.infinity)
            return compression + makeupDB
        }
    }

    func outputDB(atInput input: Double) -> Double { input + gainDB(atInput: input) }

    /// What the engine reports: max(0, -gain).
    func reductionDB(atInput input: Double) -> Double { max(0, -gainDB(atInput: input)) }

    /// Expansion gain (zero or negative) before the floor: (ratio - 1) dB per dB below the threshold, with a quadratic knee
    /// centred on the threshold, the compressor's law mirrored (E28 S7b; core `expTargetDb`). Knee 0 is the hard law.
    private func expansionDB(atInput input: Double) -> Double {
        let over = input - thresholdDB
        let slope = ratio - 1
        if kneeDB <= 0 { return over >= 0 ? 0 : slope * over }
        let half = kneeDB / 2
        if over >= half { return 0 }
        if over > -half {
            let position = over - half
            return -slope * position * position / (2 * kneeDB)
        }
        return slope * over
    }

    /// Compression below 0 dB before makeup and floor.
    private func compressionDB(atInput input: Double) -> Double {
        let over = input - thresholdDB
        let slope = 1 / max(ratio, 1) - 1
        if kneeDB <= 0 { return over > 0 ? slope * over : 0 }
        let half = kneeDB / 2
        if over >= half { return slope * over }
        if over > -half {
            let position = over + half
            return slope * position * position / (2 * kneeDB)
        }
        return 0
    }

    // MARK: Inversion for the live dot

    /// The input level at which the curve's reduction equals `reduction` (dB, > 0), or nil when no input
    /// produces it (no reduction, a ratio of 1, or more than the floor allows: the dot is then not drawn
    /// rather than guessed). Exact: the law is monotonic, so each branch inverts in closed form.
    func inputDB(forReductionDB reduction: Double) -> Double? {
        guard reduction.isFinite, reduction > 0 else { return nil }
        switch kind {
        case .limiter:
            return thresholdDB + reduction
        case .expander:
            guard ratio > 1 else { return nil }
            let limit = floorDB.map { -$0 } ?? .infinity
            guard reduction <= limit else { return nil }
            let slope = ratio - 1
            if kneeDB <= 0 { return thresholdDB - reduction / slope }
            let half = kneeDB / 2
            if reduction >= slope * half { return thresholdDB - reduction / slope }
            // Inside the knee: reduction = slope * (half - over)^2 / (2 * knee).
            return thresholdDB + half - (2 * kneeDB * reduction / slope).squareRoot()
        case .compressor:
            guard ratio > 1 else { return nil }
            // Compression (before makeup) that gives this reduction: gain = compression + makeup = -reduction.
            let compression = reduction + makeupDB
            guard compression > 0 else { return nil }
            if let floorDB, compression > -floorDB { return nil }
            let k = 1 - 1 / ratio
            if kneeDB <= 0 { return thresholdDB + compression / k }
            let half = kneeDB / 2
            if compression >= k * half { return thresholdDB + compression / k }
            // Inside the knee: compression = k * (over + half)^2 / (2 * knee).
            return thresholdDB + (2 * kneeDB * compression / k).squareRoot() - half
        }
    }

    /// The point to draw the live dot at for a readback of `reduction` dB: (input, output). Nil at 0 dB.
    func livePoint(reductionDB reduction: Double) -> (input: Double, output: Double)? {
        guard let input = inputDB(forReductionDB: reduction) else { return nil }
        return (input, outputDB(atInput: input))
    }

    // MARK: Drawing

    /// Samples (input, output) over `range` for the path of the curve.
    func points(over range: ClosedRange<Double>, count: Int = 121) -> [(input: Double, output: Double)] {
        let n = max(count, 2)
        return (0..<n).map { index in
            let input = range.lowerBound + (range.upperBound - range.lowerBound) * Double(index) / Double(n - 1)
            return (input, outputDB(atInput: input))
        }
    }

    /// Text for the accessibility value of the curve.
    var accessibilityDescription: String {
        let threshold = ValueParser.spokenText(thresholdDB, unit: .dbfs, digits: 1)
        switch kind {
        case .limiter: return "Ceiling \(threshold)"
        case .expander:
            let ratioText = ValueParser.spokenText(ratio, unit: .ratio, digits: 1)
            if kneeDB > 0 {
                return "Threshold \(threshold), ratio \(ratioText), knee \(ValueParser.spokenText(kneeDB, unit: .decibels, digits: 1))"
            }
            return "Threshold \(threshold), ratio \(ratioText)"
        case .compressor:
            let ratioText = ValueParser.spokenText(ratio, unit: .ratio, digits: 1)
            return "Threshold \(threshold), ratio \(ratioText), knee \(ValueParser.spokenText(kneeDB, unit: .decibels, digits: 1))"
        }
    }
}
