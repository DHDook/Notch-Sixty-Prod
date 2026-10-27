import Foundation

/// Swift face of the portable crossover filter library (`n60/xover.h`, E8 S1).
///
/// Offline only: designs and evaluates crossover filters on a control or UI thread, never from an
/// audio callback. The graph stages added in later E8 slices run the same core code, so what the
/// editor predicts is what renders.
enum CrossoverCore {
    enum CoreError: Error, Equatable {
        case status(Int32)
    }

    enum Family: UInt32, CaseIterable, Codable, Sendable {
        case butterworth = 0
        case bessel = 1
        case linkwitzRiley = 2

        /// Orders the library designs: Butterworth and Bessel 1-8, Linkwitz-Riley 2, 4, 6, 8 (6 to 48 dB/oct).
        var orders: [Int] {
            self == .linkwitzRiley ? [2, 4, 6, 8] : Array(1...8)
        }
    }

    /// One filter: family, order and corner. High-pass and low-pass are specified independently.
    struct FilterSpec: Equatable, Hashable, Codable, Sendable {
        var family: Family
        var order: Int
        var cornerHz: Double

        var slopeDBPerOctave: Int { 6 * order }

        fileprivate var raw: n60_xover_spec {
            var spec = n60_xover_spec()
            spec.struct_size = UInt32(MemoryLayout<n60_xover_spec>.size)
            spec.family = family.rawValue
            spec.order = UInt32(order)
            spec.corner_hz = cornerHz
            return spec
        }
    }

    struct Biquad: Equatable, Sendable {
        var b0, b1, b2, a1, a2: Double
    }

    /// A designed cascade of biquads at one sample rate.
    struct Cascade: Equatable, Sendable {
        var sections: [Biquad]
        var sampleRate: Double

        fileprivate init(_ raw: n60_xover_cascade, sampleRate: Double) {
            var list: [Biquad] = []
            withUnsafeBytes(of: raw.sections) { buffer in
                let sections = buffer.bindMemory(to: n60_xover_biquad.self)
                for index in 0..<Int(raw.count) {
                    let s = sections[index]
                    list.append(Biquad(b0: s.b0, b1: s.b1, b2: s.b2, a1: s.a1, a2: s.a2))
                }
            }
            self.sections = list
            self.sampleRate = sampleRate
        }

        fileprivate var raw: n60_xover_cascade {
            var cascade = n60_xover_cascade()
            cascade.count = UInt32(sections.count)
            withUnsafeMutableBytes(of: &cascade.sections) { buffer in
                let out = buffer.bindMemory(to: n60_xover_biquad.self)
                for (index, s) in sections.enumerated() {
                    out[index] = n60_xover_biquad(b0: s.b0, b1: s.b1, b2: s.b2, a1: s.a1, a2: s.a2)
                }
            }
            return cascade
        }

        func response(atHz hz: Double) throws -> (re: Double, im: Double) {
            var cascade = raw
            var re = 0.0, im = 0.0
            let status = n60_xover_response(&cascade, sampleRate, hz, &re, &im)
            guard status == N60_XOVER_OK else { throw CoreError.status(status) }
            return (re, im)
        }

        func magnitudeDB(atHz hz: Double) throws -> Double {
            var cascade = raw
            var db = 0.0
            let status = n60_xover_magnitude_db(&cascade, sampleRate, hz, &db)
            guard status == N60_XOVER_OK else { throw CoreError.status(status) }
            return db
        }

        /// Largest pole radius; stable when below 1.
        var maxPoleRadius: Double {
            var cascade = raw
            return n60_xover_max_pole_radius(&cascade)
        }
    }

    static var abiVersion: UInt32 { n60_xover_abi_version() }

    static func design(_ spec: FilterSpec, highPass: Bool, sampleRate: Double) throws -> Cascade {
        var raw = spec.raw
        var out = n60_xover_cascade()
        let status = n60_xover_design(&raw, highPass ? 1 : 0, sampleRate, &out)
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        return Cascade(out, sampleRate: sampleRate)
    }

    /// Linkwitz transform from a closed-box response (f0, q0) to (fp, qp).
    static func linkwitzTransform(
        f0: Double, q0: Double, fp: Double, qp: Double, sampleRate: Double
    ) throws -> Cascade {
        var out = n60_xover_cascade()
        let status = n60_xover_linkwitz(f0, q0, fp, qp, sampleRate, &out)
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        return Cascade(out, sampleRate: sampleRate)
    }

    /// True when a Linkwitz-Riley pair of this order needs its high-pass inverted to sum flat.
    static func linkwitzRileyInvertsHighPass(order: Int) -> Bool {
        n60_xover_lr_inverts_hp(UInt32(order)) != 0
    }

    /// Peak-to-peak ripple (dB) of the summed low-pass and high-pass, 20 Hz to min(20 kHz, 0.45 fs).
    static func summedRippleDB(
        lowPass: FilterSpec, highPass: FilterSpec, invertHighPass: Bool, sampleRate: Double
    ) throws -> Double {
        var lp = lowPass.raw, hp = highPass.raw
        var ripple = 0.0
        let status = n60_xover_sum_ripple_db(&lp, &hp, invertHighPass ? 1 : 0, sampleRate, &ripple)
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        return ripple
    }

    /// E8 S7: sizes and latency of a linear-phase realisation, from `n60_xover_fir_plan`.
    struct LinearPhasePlan: Equatable, Sendable {
        var twoBand: Bool
        var decimation: Int
        var extraDelayFrames: Int
        var fullTapCount: Int
        var lowTapCount: Int
        /// The stage's declared group delay (its `capacityFrames`).
        var groupDelayFrames: Int
        /// What the stage adds to the graph latency, the group delay included.
        var latencyFrames: Int

        fileprivate init(_ r: n60_xover_fir_report) {
            twoBand = r.two_band != 0
            decimation = Int(r.decimation)
            extraDelayFrames = Int(r.extra_delay_frames)
            fullTapCount = Int(r.full_tap_count)
            lowTapCount = Int(r.low_tap_count)
            groupDelayFrames = Int(r.group_delay_frames)
            latencyFrames = Int(r.latency_frames)
        }
    }

    /// A designed linear-phase way: the stage kind, its `capacityFrames` and its parameters.
    struct LinearPhaseDesign: Equatable, Sendable {
        var plan: LinearPhasePlan
        var fullTaps: [Float]
        var lowTaps: [Float]

        /// `N60_STAGE_DRIVER_FIR` parameters (the taps), or for the two-band stage `[D, N, M, E]` then both tap sets.
        var stageParameters: [Float] {
            guard plan.twoBand else { return fullTaps }
            return [Float(plan.decimation), Float(plan.fullTapCount), Float(plan.lowTapCount), Float(plan.extraDelayFrames)]
                + fullTaps + lowTaps
        }
        var stageKind: UInt32 {
            plan.twoBand ? N60_STAGE_DRIVER_FIR_TWO_BAND.rawValue : N60_STAGE_DRIVER_FIR.rawValue
        }
    }

    private static func withFIRParams<T>(
        highPass: FilterSpec?, lowPass: FilterSpec?, sampleRate: Double, groupDelayFrames: Int,
        _ body: (inout n60_xover_fir_params) -> T
    ) -> T {
        var hp = highPass?.raw ?? n60_xover_spec()
        var lp = lowPass?.raw ?? n60_xover_spec()
        let hasHP = highPass != nil, hasLP = lowPass != nil
        return withUnsafePointer(to: &hp) { hpPointer in
            withUnsafePointer(to: &lp) { lpPointer in
                var params = n60_xover_fir_params()
                params.struct_size = UInt32(MemoryLayout<n60_xover_fir_params>.size)
                params.sample_rate = sampleRate
                params.group_delay_frames = UInt32(max(0, groupDelayFrames))
                params.highpass = hasHP ? hpPointer : nil
                params.lowpass = hasLP ? lpPointer : nil
                return body(&params)
            }
        }
    }

    /// Sizes and latency of the linear-phase FIR for a way. `groupDelayFrames` 0 lets the core choose (five periods of the
    /// lowest corner); a speaker's ways pass the largest of their automatic delays so their windows match.
    static func linearPhasePlan(
        highPass: FilterSpec?, lowPass: FilterSpec?, sampleRate: Double, groupDelayFrames: Int = 0
    ) throws -> LinearPhasePlan {
        var report = n60_xover_fir_report()
        let status = withFIRParams(highPass: highPass, lowPass: lowPass, sampleRate: sampleRate,
                                   groupDelayFrames: groupDelayFrames) { n60_xover_fir_plan(&$0, &report) }
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        return LinearPhasePlan(report)
    }

    /// Synthesises the linear-phase FIR of a way (offline; the same code the Speaker Optimizer's linear-phase window
    /// uses: zero-phase magnitude of the IIR cascade, delayed by the group delay, Blackman-windowed).
    static func linearPhaseDesign(
        highPass: FilterSpec?, lowPass: FilterSpec?, sampleRate: Double, groupDelayFrames: Int = 0
    ) throws -> LinearPhaseDesign {
        let plan = try linearPhasePlan(highPass: highPass, lowPass: lowPass, sampleRate: sampleRate,
                                       groupDelayFrames: groupDelayFrames)
        var full = [Float](repeating: 0, count: plan.fullTapCount)
        var low = [Float](repeating: 0, count: max(1, plan.lowTapCount))
        var report = n60_xover_fir_report()
        let fullCount = UInt64(full.count), lowCount = UInt64(low.count)
        let status = withFIRParams(highPass: highPass, lowPass: lowPass, sampleRate: sampleRate,
                                   groupDelayFrames: groupDelayFrames) { params in
            full.withUnsafeMutableBufferPointer { f in
                low.withUnsafeMutableBufferPointer { l in
                    n60_xover_fir_synthesize(&params, f.baseAddress, fullCount, l.baseAddress, lowCount, &report)
                }
            }
        }
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        return LinearPhaseDesign(plan: LinearPhasePlan(report), fullTaps: full, lowTaps: Array(low.prefix(plan.lowTapCount)))
    }
}

// MARK: - E8 S8 near-field driver linearisation

extension CrossoverCore {
    /// A frequency response capture: ascending frequencies in Hz and levels in dB.
    struct ResponseCapture: Codable, Equatable, Sendable {
        var frequenciesHz: [Double]
        var levelsDB: [Double]
    }

    /// The designed correction of one driver, from `n60_xover_linearise_design`.
    struct DriverLinearisation: Equatable, Sendable {
        /// The fixed safety limits (E8 owner decision 6): at most +6 dB of boost, none below the way's high-pass corner.
        static let maximumBoostDB = 6.0

        var gridHz: [Double]
        var correctionDB: [Double]
        /// Smoothed measurement plus correction: the driver as it will sound, before the crossover.
        var predictedDB: [Double]
        var referenceDB: Double
        var rippleBeforeDB: Double
        var rippleAfterDB: Double
        var maxBoostDB: Double
        var maxCutDB: Double
        var boostLimited: Bool
        var linearPhase: Bool
    }

    /// Designs the correction. `farField` (gated, valid above `mergeHz`) is optional. Offline.
    static func linearise(
        nearField: ResponseCapture, farField: ResponseCapture? = nil, mergeHz: Double = 0,
        highPass: FilterSpec?, lowPass: FilterSpec?, sampleRate: Double, linearPhase: Bool
    ) throws -> DriverLinearisation {
        guard nearField.frequenciesHz.count == nearField.levelsDB.count,
              farField.map({ $0.frequenciesHz.count == $0.levelsDB.count }) ?? true else {
            throw CoreError.status(N60_XOVER_ERR_ARGUMENT)
        }
        var grid = [Double](repeating: 0, count: Int(N60_XOVER_LIN_MAX_POINTS))
        var correction = grid, predicted = grid
        var report = n60_xover_lin_report()
        let far = farField ?? ResponseCapture(frequenciesHz: [], levelsDB: [])
        let status = withLinParams(highPass: highPass, lowPass: lowPass, sampleRate: sampleRate,
                                   linearPhase: linearPhase, mergeHz: farField == nil ? 0 : mergeHz) { params in
            nearField.frequenciesHz.withUnsafeBufferPointer { nf in
                nearField.levelsDB.withUnsafeBufferPointer { nl in
                    far.frequenciesHz.withUnsafeBufferPointer { ff in
                        far.levelsDB.withUnsafeBufferPointer { fl in
                            n60_xover_linearise_design(
                                &params, nf.baseAddress, nl.baseAddress, UInt32(nf.count),
                                ff.baseAddress, fl.baseAddress, UInt32(ff.count),
                                &grid, &correction, &predicted, UInt32(grid.count), &report)
                        }
                    }
                }
            }
        }
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        let n = Int(report.point_count)
        return DriverLinearisation(
            gridHz: Array(grid.prefix(n)), correctionDB: Array(correction.prefix(n)),
            predictedDB: Array(predicted.prefix(n)), referenceDB: report.reference_db,
            rippleBeforeDB: report.ripple_before_db, rippleAfterDB: report.ripple_after_db,
            maxBoostDB: report.max_boost_db, maxCutDB: report.max_cut_db,
            boostLimited: report.boost_capped != 0, linearPhase: linearPhase)
    }

    /// The correction merged into DRIVER_FIR content. Linear phase folds in the way's crossover (so the way then drops
    /// its IIR high-pass and low-pass); minimum phase carries the correction alone.
    static func linearisedDriverFIR(
        _ design: DriverLinearisation, highPass: FilterSpec?, lowPass: FilterSpec?, sampleRate: Double,
        groupDelayFrames: Int = 0
    ) throws -> LinearPhaseDesign {
        var full = [Float](repeating: 0, count: 32_768)
        var low = [Float](repeating: 0, count: 32_768)
        var report = n60_xover_fir_report()
        let status = withLinParams(highPass: highPass, lowPass: lowPass, sampleRate: sampleRate,
                                   linearPhase: design.linearPhase, mergeHz: 0) { params in
            full.withUnsafeMutableBufferPointer { f in
                low.withUnsafeMutableBufferPointer { l in
                    n60_xover_linearise_synthesize(
                        &params, design.gridHz, design.correctionDB, UInt32(design.gridHz.count),
                        UInt32(max(0, groupDelayFrames)), f.baseAddress, UInt64(f.count), l.baseAddress, UInt64(l.count),
                        &report)
                }
            }
        }
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        let plan = LinearPhasePlan(report)
        return LinearPhaseDesign(plan: plan, fullTaps: Array(full.prefix(plan.fullTapCount)),
                                 lowTaps: Array(low.prefix(plan.lowTapCount)))
    }

    /// Magnitude (dB) of designed DRIVER_FIR content at the frequencies, the declared delay removed: the verifier input.
    static func firMagnitudeDB(_ design: LinearPhaseDesign, sampleRate: Double, atHz frequencies: [Double]) throws -> [Double] {
        var report = n60_xover_fir_report()
        report.two_band = design.plan.twoBand ? 1 : 0
        report.decimation = UInt32(design.plan.decimation)
        report.extra_delay_frames = UInt32(design.plan.extraDelayFrames)
        report.full_tap_count = UInt32(design.plan.fullTapCount)
        report.low_tap_count = UInt32(design.plan.lowTapCount)
        report.group_delay_frames = UInt32(design.plan.groupDelayFrames)
        report.latency_frames = UInt32(design.plan.latencyFrames)
        var out = [Double](repeating: 0, count: frequencies.count)
        let low = design.lowTaps.isEmpty ? [0] : design.lowTaps
        let status = n60_xover_fir_magnitude_db(sampleRate, &report, design.fullTaps, low, frequencies,
                                                UInt32(frequencies.count), &out)
        guard status == N60_XOVER_OK else { throw CoreError.status(status) }
        return out
    }

    /// Largest difference (dB) between the realised FIR and the designed target (crossover magnitude, when linear phase,
    /// plus the correction) over the passband: the deploy gate, like the other prediction verifiers.
    static func verifyLinearisation(
        _ design: DriverLinearisation, fir: LinearPhaseDesign, highPass: FilterSpec?, lowPass: FilterSpec?, sampleRate: Double
    ) throws -> Double {
        let lo = highPass?.cornerHz ?? design.gridHz[0]
        // An open top edge is checked up to 0.7 x the capture's top (and 0.4 x the rate): the correction fades out at the
        // measurement's edge, which is not a realisation error.
        let hi = lowPass?.cornerHz ?? min(0.7 * design.gridHz[design.gridHz.count - 1], 0.4 * sampleRate)
        let points = design.gridHz.indices.filter { design.gridHz[$0] >= lo && design.gridHz[$0] <= hi }
        let frequencies = points.map { design.gridHz[$0] }
        let realised = try firMagnitudeDB(fir, sampleRate: sampleRate, atHz: frequencies)
        let hpCascade = try design.linearPhase ? highPass.map { try Self.design($0, highPass: true, sampleRate: sampleRate) } : nil
        let lpCascade = try design.linearPhase ? lowPass.map { try Self.design($0, highPass: false, sampleRate: sampleRate) } : nil
        var worst = 0.0
        for (offset, index) in points.enumerated() {
            var target = design.correctionDB[index]
            if let hpCascade { target += try hpCascade.magnitudeDB(atHz: frequencies[offset]) }
            if let lpCascade { target += try lpCascade.magnitudeDB(atHz: frequencies[offset]) }
            worst = max(worst, abs(realised[offset] - target))
        }
        return worst
    }

    private static func withLinParams<T>(
        highPass: FilterSpec?, lowPass: FilterSpec?, sampleRate: Double, linearPhase: Bool, mergeHz: Double,
        _ body: (inout n60_xover_lin_params) -> T
    ) -> T {
        var hp = highPass?.raw ?? n60_xover_spec()
        var lp = lowPass?.raw ?? n60_xover_spec()
        let hasHP = highPass != nil, hasLP = lowPass != nil
        return withUnsafePointer(to: &hp) { hpPointer in
            withUnsafePointer(to: &lp) { lpPointer in
                var params = n60_xover_lin_params()
                params.struct_size = UInt32(MemoryLayout<n60_xover_lin_params>.size)
                params.sample_rate = sampleRate
                params.highpass = hasHP ? hpPointer : nil
                params.lowpass = hasLP ? lpPointer : nil
                params.linear_phase = linearPhase ? 1 : 0
                params.merge_hz = mergeHz
                return body(&params)
            }
        }
    }
}
