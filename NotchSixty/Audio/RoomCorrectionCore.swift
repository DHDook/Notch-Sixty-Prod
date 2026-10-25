import Foundation

/// Swift face of the portable room-correction design core (`n60/correct.h`, E10 S1).
///
/// Offline only: every call allocates and runs on a design task, never from an audio callback.
/// S1 exposes the minimum-phase designer and the correction grid; later slices add the
/// multi-seat design and synthesis calls behind the `e10.mixed-phase-correction` flag.
enum RoomCorrectionCore {
    enum CoreError: Error, Equatable {
        case status(Int32)
    }

    static var abiVersion: UInt32 { n60_correct_abi_version() }

    /// The fixed 1/48-octave correction grid, independent of sample rate.
    static func gridFrequencies() throws -> [Double] {
        var frequencies = [Double](repeating: 0, count: Int(n60_correct_grid_size()))
        let status = frequencies.withUnsafeMutableBufferPointer {
            n60_correct_grid_frequencies($0.baseAddress, UInt32($0.count))
        }
        guard status == 0 else { throw CoreError.status(status) }
        return frequencies
    }

    /// Real-cepstrum minimum-phase FIR for a correction curve, evaluated in double precision.
    /// The curve applies strictly between `lowHz` and `highHz` and is 0 dB outside.
    static func minimumPhaseTaps(
        sampleRate: Double,
        tapCount: Int,
        frequenciesHz: [Double],
        gainDB: [Double],
        lowHz: Double,
        highHz: Double
    ) throws -> [Float] {
        precondition(frequenciesHz.count == gainDB.count)
        var params = n60_correct_minphase_params()
        n60_correct_minphase_defaults(sampleRate, UInt32(tapCount), &params)
        params.low_hz = lowHz
        params.high_hz = highHz
        var taps = [Float](repeating: 0, count: tapCount)
        let status = taps.withUnsafeMutableBufferPointer { out in
            frequenciesHz.withUnsafeBufferPointer { f in
                gainDB.withUnsafeBufferPointer { g in
                    n60_correct_minphase_synthesize(
                        &params, f.baseAddress, g.baseAddress, UInt32(f.count), out.baseAddress, UInt64(out.count))
                }
            }
        }
        guard status == 0 else { throw CoreError.status(status) }
        return taps
    }

    // MARK: - Multi-seat design and latency modes (E10 S2)

    /// One channel at one seat: an E11 impulse response and its direct arrival.
    struct SeatImpulseResponse: Equatable, Sendable {
        var samples: [Float]
        var arrivalFrames: Double
        var weight: Double
    }

    /// Default weights (design note 3): 1 for every seat, 2 for the main seat.
    static func defaultSeatWeights(seatCount: Int, mainSeat: Int) throws -> [Double] {
        var weights = [Double](repeating: 0, count: max(seatCount, 0))
        let status = weights.withUnsafeMutableBufferPointer {
            n60_correct_default_seat_weights(UInt32(seatCount), UInt32(max(mainSeat, 0)), $0.baseAddress, UInt32($0.count))
        }
        guard status == 0 else { throw CoreError.status(status) }
        return weights
    }

    /// Designs one channel on the correction grid from its impulse responses at every seat.
    static func designGrid(
        seats: [SeatImpulseResponse],
        sampleRate: Double,
        mainSeat: Int,
        mode: RoomCorrectionLatencyMode,
        phaseLimitHz: Double = 500,
        maximumBoostDB: Double = 6
    ) throws -> RoomCorrectionGridDesign {
        let buffers = seats.map { seat -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(seat.samples.count, 1))
            pointer.initialize(from: seat.samples, count: seat.samples.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        var irs = zip(seats, buffers).map { seat, buffer in
            n60_correct_seat_ir(
                ir: UnsafePointer(buffer), frames: UInt64(seat.samples.count),
                arrival_frames: seat.arrivalFrames, weight: seat.weight)
        }
        var params = n60_correct_design_params()
        n60_correct_design_defaults(mode.designMode, &params)
        params.phase_limit_hz = phaseLimitHz
        params.max_boost_db = maximumBoostDB
        let count = Int(n60_correct_grid_size())
        var design = RoomCorrectionGridDesign(
            correctionDB: [Double](repeating: 0, count: count), correctionPhaseRadians: [Double](repeating: 0, count: count),
            coherence: [Double](repeating: 0, count: count), seatContribution: [])
        var contribution = [Double](repeating: 0, count: seats.count)
        let status: Int32 = irs.withUnsafeMutableBufferPointer { irPointer in
            var problem = n60_correct_problem(
                struct_size: UInt32(MemoryLayout<n60_correct_problem>.size), sample_rate: sampleRate,
                channel_count: 1, seat_count: UInt32(seats.count), main_seat: UInt32(max(mainSeat, 0)),
                irs: UnsafePointer(irPointer.baseAddress))
            let designStatus: Int32 = design.correctionDB.withUnsafeMutableBufferPointer { db in
                design.correctionPhaseRadians.withUnsafeMutableBufferPointer { phase in
                    design.coherence.withUnsafeMutableBufferPointer { coherence in
                        var grid = n60_correct_design_grid(
                            correction_db: db.baseAddress, correction_phase_rad: phase.baseAddress,
                            coherence: coherence.baseAddress, measured_db: nil, seat_spread_db: nil, boost_limit_db: nil)
                        return n60_correct_design_channel(&problem, 0, &params, &grid)
                    }
                }
            }
            guard designStatus == 0 else { return designStatus }
            return contribution.withUnsafeMutableBufferPointer {
                n60_correct_seat_coherence_contribution(&problem, 0, &params, $0.baseAddress, UInt32($0.count))
            }
        }
        guard status == 0 else { throw CoreError.status(status) }
        design.seatContribution = contribution
        return design
    }

    /// Synthesises a grid design into taps at the device rate. Returns the taps and the declared latency.
    static func synthesize(
        _ design: RoomCorrectionGridDesign,
        sampleRate: Double,
        mode: RoomCorrectionLatencyMode
    ) throws -> (taps: [Float], declaredLatencyFrames: UInt32) {
        let tapCount = Int(n60_correct_latency_mode_tap_count(mode.rawValue, sampleRate))
        guard tapCount > 0, design.correctionDB.count == Int(n60_correct_grid_size()),
              design.correctionPhaseRadians.count == design.correctionDB.count else {
            throw CoreError.status(-1)
        }
        var params = n60_correct_synth_params()
        n60_correct_synth_defaults(mode.designMode, sampleRate, UInt32(tapCount), mode.budgetSeconds, &params)
        var taps = [Float](repeating: 0, count: tapCount)
        var report = n60_correct_synth_report()
        var db = design.correctionDB
        var phase = design.correctionPhaseRadians
        let status: Int32 = db.withUnsafeMutableBufferPointer { dbPointer in
            phase.withUnsafeMutableBufferPointer { phasePointer in
                taps.withUnsafeMutableBufferPointer { out in
                    var grid = n60_correct_design_grid(
                        correction_db: dbPointer.baseAddress, correction_phase_rad: phasePointer.baseAddress,
                        coherence: nil, measured_db: nil, seat_spread_db: nil, boost_limit_db: nil)
                    return n60_correct_synthesize(&params, &grid, out.baseAddress, UInt64(out.count), &report)
                }
            }
        }
        guard status == 0 else { throw CoreError.status(status) }
        return (taps, report.declared_latency_frames)
    }
}

extension RoomCorrectionCore {
    /// A two-band realisation of a design (E10 S8) for `N60_STAGE_ROOM_FIR_TWO_BAND`: the full-rate taps and the low band.
    struct TwoBandSynthesis: Equatable, Sendable {
        var fullTaps: [Float]
        var lowTaps: [Float]
        var decimation: UInt32
        var extraDelayFrames: UInt32
        var declaredLatencyFrames: UInt32
        var peakGainDB: Double
    }

    /// Synthesises a grid design as the two-band stage's taps. The span is the mode's full tap count, so a design
    /// that does not fit the 32768-tap single-band stage (music modes above about 192 kHz) is carried in full.
    static func synthesizeTwoBand(
        _ design: RoomCorrectionGridDesign,
        sampleRate: Double,
        mode: RoomCorrectionLatencyMode
    ) throws -> TwoBandSynthesis {
        let tapCount = Int(n60_correct_latency_mode_tap_count(mode.rawValue, sampleRate))
        guard tapCount > 0, design.correctionDB.count == Int(n60_correct_grid_size()),
              design.correctionPhaseRadians.count == design.correctionDB.count else {
            throw CoreError.status(-1)
        }
        var params = n60_correct_synth_params()
        n60_correct_synth_defaults(mode.designMode, sampleRate, UInt32(tapCount), mode.budgetSeconds, &params)
        var full = [Float](repeating: 0, count: 32_768)
        var low = [Float](repeating: 0, count: 32_768)
        var report = n60_correct_two_band_report()
        var db = design.correctionDB
        var phase = design.correctionPhaseRadians
        let status: Int32 = db.withUnsafeMutableBufferPointer { dbPointer in
            phase.withUnsafeMutableBufferPointer { phasePointer in
                full.withUnsafeMutableBufferPointer { fullOut in
                    low.withUnsafeMutableBufferPointer { lowOut in
                        var grid = n60_correct_design_grid(
                            correction_db: dbPointer.baseAddress, correction_phase_rad: phasePointer.baseAddress,
                            coherence: nil, measured_db: nil, seat_spread_db: nil, boost_limit_db: nil)
                        return n60_correct_synthesize_two_band(
                            &params, &grid, fullOut.baseAddress, UInt64(fullOut.count), lowOut.baseAddress,
                            UInt64(lowOut.count), &report)
                    }
                }
            }
        }
        guard status == 0 else { throw CoreError.status(status) }
        return TwoBandSynthesis(
            fullTaps: Array(full.prefix(Int(report.full_tap_count))), lowTaps: Array(low.prefix(Int(report.low_tap_count))),
            decimation: report.decimation, extraDelayFrames: report.extra_delay_frames,
            declaredLatencyFrames: report.declared_latency_frames, peakGainDB: report.peak_gain_db)
    }

    /// The magnitude (dB) and delay-removed phase (radians) of a published filter at `frequencies`: single-band taps
    /// (`low` nil) or a two-band stage. Analytic, so a verifier can compare it with a measurement.
    static func filterResponse(
        sampleRate: Double, taps: [Float], twoBand: RoomCorrectionTwoBandPart?, declaredLatencyFrames: UInt32,
        frequencies: [Double]
    ) throws -> (magnitudeDB: [Double], phaseRadians: [Double]) {
        var magnitude = [Double](repeating: 0, count: frequencies.count)
        var phase = [Double](repeating: 0, count: frequencies.count)
        let low = twoBand?.lowTaps ?? []
        let status: Int32 = taps.withUnsafeBufferPointer { fullPointer in
            low.withUnsafeBufferPointer { lowPointer in
                frequencies.withUnsafeBufferPointer { freq in
                    magnitude.withUnsafeMutableBufferPointer { mag in
                        phase.withUnsafeMutableBufferPointer { ph in
                            n60_correct_two_band_response(
                                sampleRate, twoBand?.decimation ?? 1, twoBand?.extraDelayFrames ?? 0, declaredLatencyFrames,
                                fullPointer.baseAddress, UInt32(taps.count), lowPointer.baseAddress, UInt32(low.count),
                                freq.baseAddress, UInt32(frequencies.count), mag.baseAddress, ph.baseAddress)
                        }
                    }
                }
            }
        }
        guard status == 0 else { throw CoreError.status(status) }
        return (magnitude, phase)
    }
}

// MARK: - Joint bass optimiser (E10 S6)

/// One channel of the joint bass optimiser: a main (delay free) or a subwoofer (delay, gain and polarity free).
struct BassChannelSpec: Equatable, Sendable {
    enum Role: UInt32, Sendable { case main = 0, sub = 1 }
    var role: Role
    var freeDelay: Bool
    var freeGain: Bool
    var freePolarity: Bool
    var minimumGainDB: Double
    var maximumGainDB: Double

    static func defaults(_ role: Role) -> BassChannelSpec {
        var channel = n60_correct_bass_channel()
        n60_correct_bass_channel_defaults(role.rawValue, &channel)
        return BassChannelSpec(
            role: role, freeDelay: channel.free_delay != 0, freeGain: channel.free_gain != 0,
            freePolarity: channel.free_polarity != 0, minimumGainDB: channel.min_gain_db, maximumGainDB: channel.max_gain_db)
    }
}

/// How the measurement was timed (E11); `.none` blocks the design.
enum BassTimingTier: UInt32, Sendable {
    case loopback = 1
    case acoustic = 2
    case none = 3
}

struct BassOptimiserSettings: Equatable, Sendable {
    var timingTier: BassTimingTier
    var crossoverHz: Double = 80
    var fitLowHz: Double = 20
    var fitHighHz: Double = 0
    var filterHighHz: Double = 0
    var maximumDelaySeconds: Double = 0.02
    var maximumBoostDB: Double = 6
    var regularisation: Double = 0.01
    /// Shared target as (frequency Hz, gain dB) points; empty is flat.
    var target: [(hz: Double, gainDB: Double)] = []

    static func == (lhs: BassOptimiserSettings, rhs: BassOptimiserSettings) -> Bool {
        lhs.timingTier == rhs.timingTier && lhs.crossoverHz == rhs.crossoverHz && lhs.fitLowHz == rhs.fitLowHz
            && lhs.fitHighHz == rhs.fitHighHz && lhs.filterHighHz == rhs.filterHighHz
            && lhs.maximumDelaySeconds == rhs.maximumDelaySeconds && lhs.maximumBoostDB == rhs.maximumBoostDB
            && lhs.regularisation == rhs.regularisation && lhs.target.count == rhs.target.count
            && zip(lhs.target, rhs.target).allSatisfy { $0.hz == $1.hz && $0.gainDB == $1.gainDB }
    }
}

/// What the optimiser decided for one channel, and its boost and headroom.
struct BassChannelResult: Equatable, Sendable {
    var delaySeconds: Double
    var delayFrames: Int
    var gainDB: Double
    var polarityInverted: Bool
    var peakBoostDB: Double
    var peakGainDB: Double
    var headroomDB: Double
}

/// The bass report: seat-to-seat standard deviation of the level (dB, averaged over the fit band) before
/// alignment, after delay/gain/polarity, and after the filters, plus boost and headroom per channel.
struct BassReport: Equatable, Sendable {
    var seatStdBeforeDB: Double
    var seatStdAlignedDB: Double
    var seatStdAfterDB: Double
    var targetRMSBeforeDB: Double
    var targetRMSAfterDB: Double
    var referenceLevelDB: Double
    var headroomDB: Double
    var boostLimitedBins: Int
    var channels: [BassChannelResult]
}

struct BassOptimisation: Sendable {
    /// One grid design per channel (correction magnitude and extra phase, synthesisable per rate).
    var designs: [RoomCorrectionGridDesign]
    var report: BassReport
    /// Predicted seat responses (seat-major, grid points) of the uncorrected and the optimised system.
    var beforeDB: [Double]
    var afterDB: [Double]
}

extension RoomCorrectionCore {
    /// Jointly optimises delay, gain, polarity and low-frequency filters of the mains and subwoofers.
    /// `irs` is channel-major: `irs[channel][seat]`, all in one time reference.
    static func optimiseBass(
        irs: [[SeatImpulseResponse]],
        channels: [BassChannelSpec],
        sampleRate: Double,
        settings: BassOptimiserSettings
    ) throws -> BassOptimisation {
        let channelCount = irs.count
        guard channelCount > 0, channels.count == channelCount, let seatCount = irs.first?.count, seatCount > 0,
              irs.allSatisfy({ $0.count == seatCount }) else { throw CoreError.status(N60_CORRECT_ERR_ARGUMENT) }
        let flat = irs.flatMap { $0 }
        let buffers = flat.map { seat -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(seat.samples.count, 1))
            pointer.initialize(from: seat.samples, count: seat.samples.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        var seatIRs = zip(flat, buffers).map { seat, buffer in
            n60_correct_seat_ir(
                ir: UnsafePointer(buffer), frames: UInt64(seat.samples.count),
                arrival_frames: seat.arrivalFrames, weight: seat.weight)
        }
        var channelParams = channels.map { spec -> n60_correct_bass_channel in
            n60_correct_bass_channel(
                role: spec.role.rawValue, free_delay: spec.freeDelay ? 1 : 0, free_gain: spec.freeGain ? 1 : 0,
                free_polarity: spec.freePolarity ? 1 : 0, min_gain_db: spec.minimumGainDB, max_gain_db: spec.maximumGainDB)
        }
        let targetHz = settings.target.map(\.hz)
        let targetDB = settings.target.map(\.gainDB)
        let gridCount = Int(n60_correct_grid_size())
        let dbBuffers = (0..<channelCount).map { _ -> UnsafeMutablePointer<Double> in
            let pointer = UnsafeMutablePointer<Double>.allocate(capacity: gridCount)
            pointer.initialize(repeating: 0, count: gridCount)
            return pointer
        }
        let phaseBuffers = (0..<channelCount).map { _ -> UnsafeMutablePointer<Double> in
            let pointer = UnsafeMutablePointer<Double>.allocate(capacity: gridCount)
            pointer.initialize(repeating: 0, count: gridCount)
            return pointer
        }
        defer {
            dbBuffers.forEach { $0.deallocate() }
            phaseBuffers.forEach { $0.deallocate() }
        }
        var grids = (0..<channelCount).map { index -> n60_correct_design_grid in
            var grid = n60_correct_design_grid()
            grid.correction_db = dbBuffers[index]
            grid.correction_phase_rad = phaseBuffers[index]
            return grid
        }
        var before = [Double](repeating: 0, count: seatCount * gridCount)
        var after = before
        var report = n60_correct_bass_report()

        let status: Int32 = seatIRs.withUnsafeMutableBufferPointer { irPointer in
            channelParams.withUnsafeMutableBufferPointer { channelPointer in
                targetHz.withUnsafeBufferPointer { hz in
                    targetDB.withUnsafeBufferPointer { gain in
                        grids.withUnsafeMutableBufferPointer { gridPointer in
                            before.withUnsafeMutableBufferPointer { beforePointer in
                                after.withUnsafeMutableBufferPointer { afterPointer in
                                    var params = n60_correct_bass_params()
                                    n60_correct_bass_defaults(channelPointer.baseAddress, &params)
                                    params.timing_tier = settings.timingTier.rawValue
                                    params.crossover_hz = settings.crossoverHz
                                    params.fit_low_hz = settings.fitLowHz
                                    params.fit_high_hz = settings.fitHighHz
                                    params.fir_high_hz = settings.filterHighHz
                                    params.max_delay_seconds = settings.maximumDelaySeconds
                                    params.max_boost_db = settings.maximumBoostDB
                                    params.regularisation = settings.regularisation
                                    params.target_frequencies_hz = hz.baseAddress
                                    params.target_gain_db = gain.baseAddress
                                    params.target_points = UInt32(hz.count)
                                    var problem = n60_correct_problem(
                                        struct_size: UInt32(MemoryLayout<n60_correct_problem>.size), sample_rate: sampleRate,
                                        channel_count: UInt32(channelCount), seat_count: UInt32(seatCount), main_seat: 0,
                                        irs: UnsafePointer(irPointer.baseAddress))
                                    return n60_correct_bass_optimise(
                                        &problem, &params, gridPointer.baseAddress, &report,
                                        beforePointer.baseAddress, afterPointer.baseAddress)
                                }
                            }
                        }
                    }
                }
            }
        }
        guard status == 0 else { throw CoreError.status(status) }

        let results: [BassChannelResult] = withUnsafeBytes(of: &report.channels) { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: n60_correct_bass_channel_result.self)
            return (0..<channelCount).map { index in
                let item = base[index]
                return BassChannelResult(
                    delaySeconds: item.delay_seconds, delayFrames: Int(item.delay_frames), gainDB: item.gain_db,
                    polarityInverted: item.polarity_invert != 0, peakBoostDB: item.peak_boost_db,
                    peakGainDB: item.peak_gain_db, headroomDB: item.headroom_db)
            }
        }
        let designs = (0..<channelCount).map { index in
            RoomCorrectionGridDesign(
                correctionDB: Array(UnsafeBufferPointer(start: dbBuffers[index], count: gridCount)),
                correctionPhaseRadians: Array(UnsafeBufferPointer(start: phaseBuffers[index], count: gridCount)),
                coherence: [Double](repeating: 0, count: gridCount), seatContribution: [])
        }
        return BassOptimisation(
            designs: designs,
            report: BassReport(
                seatStdBeforeDB: report.seat_std_before_db, seatStdAlignedDB: report.seat_std_aligned_db,
                seatStdAfterDB: report.seat_std_after_db, targetRMSBeforeDB: report.target_rms_before_db,
                targetRMSAfterDB: report.target_rms_after_db, referenceLevelDB: report.reference_level_db,
                headroomDB: report.headroom_db, boostLimitedBins: Int(report.boost_limited_bins), channels: results),
            beforeDB: before, afterDB: after)
    }
}

/// The two correction modes and the latency budgets of design note 4.
enum RoomCorrectionLatencyMode: UInt32, CaseIterable, Codable, Sendable {
    case video = 0
    case music20ms = 1
    case music50ms = 2
    case music100ms = 3

    /// The default music budget is 50 ms.
    static let defaultMusic: RoomCorrectionLatencyMode = .music50ms

    var designMode: UInt32 { self == .video ? UInt32(N60_CORRECT_MODE_MIN_PHASE) : UInt32(N60_CORRECT_MODE_MIXED_PHASE) }

    var isMixedPhase: Bool { self != .video }

    /// The declared latency budget in seconds; 0 for video mode (minimum phase).
    var budgetSeconds: Double {
        var budget = 0.0
        _ = n60_correct_latency_mode(rawValue, nil, &budget)
        return budget
    }
}

/// A multi-seat design on the correction grid: independent of sample rate.
struct RoomCorrectionGridDesign: Codable, Equatable, Sendable {
    var correctionDB: [Double]
    var correctionPhaseRadians: [Double]
    var coherence: [Double]
    /// Each seat's agreement with the applied phase correction, for the UI (1 agrees, 0 or less disagrees).
    var seatContribution: [Double]
}

/// Design schema 2 (E10 design note 6): a rate-independent record that also holds the previous
/// schema's filter. Schema 1 (`RoomCorrectionDesign`, no schemaVersion) migrates as minimum phase
/// with its filter unchanged.
struct RoomCorrectionDesignRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID
    var name: String
    var createdAt: Date
    var latencyMode: RoomCorrectionLatencyMode
    var phaseLimitHz: Double
    var seatWeights: [Double]
    var grid: RoomCorrectionGridDesign?
    /// The filter deployed for the rate the design was made at.
    var filter: RoomCorrectionFilter

    enum DecodeError: Error, Equatable {
        case unsupportedSchema(Int)
    }

    init(
        id: UUID = UUID(), name: String, createdAt: Date = Date(), latencyMode: RoomCorrectionLatencyMode,
        phaseLimitHz: Double = 500, seatWeights: [Double] = [], grid: RoomCorrectionGridDesign? = nil,
        filter: RoomCorrectionFilter
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.latencyMode = latencyMode
        self.phaseLimitHz = phaseLimitHz
        self.seatWeights = seatWeights
        self.grid = grid
        self.filter = filter
    }

    /// Schema 1 to schema 2: minimum phase, no grid, the filter untouched.
    init(migrating legacy: RoomCorrectionDesign) {
        self.init(
            id: legacy.id, name: legacy.name, createdAt: legacy.createdAt, latencyMode: .video,
            seatWeights: legacy.sourcePositions?.map(\.weight) ?? [], grid: nil, filter: legacy.filter)
    }

    /// Decodes either schema. Data without a schemaVersion is a schema 1 `RoomCorrectionDesign`.
    static func decode(from data: Data, using decoder: JSONDecoder = JSONDecoder()) throws -> RoomCorrectionDesignRecord {
        struct Probe: Decodable { var schemaVersion: Int? }
        let version = try decoder.decode(Probe.self, from: data).schemaVersion
        switch version {
        case nil:
            return RoomCorrectionDesignRecord(migrating: try decoder.decode(RoomCorrectionDesign.self, from: data))
        case Self.currentSchemaVersion?:
            return try decoder.decode(RoomCorrectionDesignRecord.self, from: data)
        case let other?:
            throw DecodeError.unsupportedSchema(other)
        }
    }
}
