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
