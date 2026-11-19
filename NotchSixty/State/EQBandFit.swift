import Foundation

/// E33 S21 (G40): proposes EQ bands that bring a reference curve (S19) to a target. The maths is the core's
/// `n60_eqfit_fit` (deterministic, off the audio thread); this file only prepares its input and reads its output.
/// Nothing here changes the EQ: the page keeps a proposal only when the user says so, as one undo step.
enum EQFitTarget: String, CaseIterable, Identifiable, Sendable {
    case flat
    case correctionTarget

    var id: String { rawValue }
    var displayName: String { self == .flat ? "Flat" : "Correction target" }
}

struct EQFitRequest: Equatable, Sendable {
    /// Which saved curve is corrected: the measurement before correction, or after.
    var source: EQReferenceCurveKind = .measurement
    var target: EQFitTarget = .flat
    var lowHz = 20.0
    var highHz = 500.0
    var bandCount = 8
    var maximumBoostDB = 3.0
    var maximumCutDB = 12.0

    static let bandCountRange = 1...16
    static let maximumBoostRange = 0.0...12.0
}

/// Why a fit did not run. Each case reads as a sentence on the page.
enum EQFitRefusal: Error, Equatable, LocalizedError {
    case noMeasurement
    case staleMeasurement(String)
    case noTarget
    case badRange
    case core(Int32)

    var errorDescription: String? {
        switch self {
        case .noMeasurement: "There is no saved measurement to fit. Measure the room first."
        case .staleMeasurement(let label): "\(label) is out of date. Measure the room again before fitting."
        case .noTarget: "There is no saved correction target. Choose Flat, or set a target in Room Correction."
        case .badRange: "The range is too narrow to fit."
        case .core: "The curve could not be fitted."
        }
    }
}

struct EQBandFitProposal: Equatable, Sendable {
    var bands: [EQBand]
    var frequenciesHz: [Double]
    var measuredDB: [Double]
    var targetDB: [Double]
    /// The measurement with the proposed bands applied, at the same frequencies.
    var predictedDB: [Double]
    var rmsBeforeDB: Double
    var rmsAfterDB: Double
    var fittedRangeHz: ClosedRange<Double>
}

enum EQBandFitter {
    /// Fits `curves` per `request` at `sampleRate`. Refuses a missing or out-of-date curve by name; never runs on one.
    static func fit(
        _ request: EQFitRequest, curves: [EQReferenceCurve], sampleRate: Double
    ) throws -> EQBandFitProposal {
        guard let curve = curves.first(where: { $0.kind == request.source }),
              curve.frequenciesHz.count >= Int(N60_EQFIT_MIN_POINTS),
              curve.frequenciesHz.count == curve.gainDB.count else { throw EQFitRefusal.noMeasurement }
        if curve.isOutOfDate { throw EQFitRefusal.staleMeasurement(curve.label) }
        let frequencies = curve.frequenciesHz
        let target: [Double]
        switch request.target {
        case .flat:
            target = Array(repeating: 0, count: frequencies.count)
        case .correctionTarget:
            guard let reference = curves.first(where: { $0.kind == .target }), reference.frequenciesHz.count > 1 else {
                throw EQFitRefusal.noTarget
            }
            target = frequencies.map { interpolate(reference.frequenciesHz, reference.gainDB, at: $0) }
        }
        guard request.highHz > request.lowHz * 1.5 else { throw EQFitRefusal.badRange }

        var problem = n60_eqfit_problem()
        problem.struct_size = UInt32(MemoryLayout<n60_eqfit_problem>.size)
        problem.sample_rate = sampleRate
        problem.point_count = UInt32(frequencies.count)
        problem.low_hz = max(request.lowHz, EQBandRules.minimumFrequency)
        problem.high_hz = request.highHz
        problem.max_bands = UInt32(request.bandCount)
        problem.max_boost_db = request.maximumBoostDB
        problem.max_cut_db = request.maximumCutDB
        var coreBands = [n60_eqfit_band](repeating: n60_eqfit_band(), count: request.bandCount)
        var predicted = [Double](repeating: 0, count: frequencies.count)
        var result = n60_eqfit_result()
        result.struct_size = UInt32(MemoryLayout<n60_eqfit_result>.size)
        let status: Int32 = frequencies.withUnsafeBufferPointer { f in
            curve.gainDB.withUnsafeBufferPointer { m in
                target.withUnsafeBufferPointer { t in
                    coreBands.withUnsafeMutableBufferPointer { b in
                        predicted.withUnsafeMutableBufferPointer { p in
                            problem.frequencies_hz = f.baseAddress
                            problem.measured_db = m.baseAddress
                            problem.target_db = t.baseAddress
                            result.bands = b.baseAddress
                            result.predicted_db = p.baseAddress
                            return n60_eqfit_fit(&problem, &result)
                        }
                    }
                }
            }
        }
        guard status == N60_EQFIT_OK else {
            throw status == N60_EQFIT_ERR_DATA ? EQFitRefusal.badRange : EQFitRefusal.core(status)
        }
        let bands = coreBands.prefix(Int(result.band_count)).map { band -> EQBand in
            let type: EQFilterType = band.type == N60_EQFIT_BAND_LOW_SHELF ? .lowShelf
                : band.type == N60_EQFIT_BAND_HIGH_SHELF ? .highShelf : .peaking
            return EQBandRules.sanitized(
                EQBand(type: type, frequencyHz: band.frequency_hz, gainDB: band.gain_db, q: band.q),
                sampleRate: sampleRate)
        }
        // The fit leaves the overall level to the preamp, so the pictures line up on the target's level in the range.
        let inRange = frequencies.indices.filter { frequencies[$0] >= result.low_hz && frequencies[$0] <= result.high_hz }
        let offset = inRange.isEmpty ? 0 : inRange.map { target[$0] - curve.gainDB[$0] }.reduce(0, +) / Double(inRange.count)
        return EQBandFitProposal(
            bands: bands, frequenciesHz: frequencies, measuredDB: curve.gainDB.map { $0 + offset }, targetDB: target,
            predictedDB: predicted.map { $0 + offset }, rmsBeforeDB: result.rms_before_db, rmsAfterDB: result.rms_after_db,
            fittedRangeHz: result.low_hz...max(result.high_hz, result.low_hz))
    }

    /// Linear in log frequency, held at the ends.
    static func interpolate(_ frequencies: [Double], _ values: [Double], at hz: Double) -> Double {
        let order = frequencies.indices.sorted { frequencies[$0] < frequencies[$1] }
        guard let first = order.first, let last = order.last else { return 0 }
        if hz <= frequencies[first] { return values[first] }
        if hz >= frequencies[last] { return values[last] }
        for (a, b) in zip(order, order.dropFirst()) where hz <= frequencies[b] {
            let span = log(frequencies[b]) - log(frequencies[a])
            guard span > 0 else { return values[a] }
            let t = (log(hz) - log(frequencies[a])) / span
            return values[a] + t * (values[b] - values[a])
        }
        return values[last]
    }
}
