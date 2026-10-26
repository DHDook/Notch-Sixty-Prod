import Foundation

// E12 S5: pure logic behind the Bass and Correction steps of the guided setup. No SwiftUI, no
// engine, nothing here runs on an audio thread. It uses only existing E10 APIs: the joint bass
// optimiser (`RoomCorrectionCore.optimiseBass`) and the Room Correction project controller's own
// design path. Gated by `e12.guided-setup` at the call sites.

// MARK: - Bass step

enum SystemSetupBassError: Error, Equatable, LocalizedError {
    case noMainSpeakers
    case missingMeasurement(seat: String, source: String)
    case missingArrival(source: String)

    var errorDescription: String? {
        switch self {
        case .noMainSpeakers: return "Measure the left and right speakers before designing the bass."
        case .missingMeasurement(let seat, let source): return "\(seat) has no measurement of \(source)."
        case .missingArrival(let source): return "The measurement of \(source) has no direct-arrival time."
        }
    }
}

struct SystemSetupBassRow: Equatable, Sendable, Identifiable {
    var source: MultichannelCalibrationSource
    var gainDB: Double
    var delayMilliseconds: Double
    var polarityInverted: Bool
    var id: MultichannelCalibrationSource { source }
    var title: String { source.displayName }
}

/// The result of the Bass step: either E10's joint optimisation or, when it is not allowed, today's
/// sub alignment (already applied by the Alignment step), so the step then changes nothing.
struct SystemSetupBassDesign: Sendable {
    enum Mode: Equatable, Sendable { case jointOptimised, subAlignmentOnly }

    static let fitLowHz = 20.0
    static let fitHighHz = 120.0

    var mode: Mode
    var sampleRate: Double
    var seatNames: [String]
    var rows: [SystemSetupBassRow]
    var report: BassReport?
    /// Mean predicted level per seat over the fit grid, before and after (dB).
    var seatMeanBeforeDB: [Double]
    var seatMeanAfterDB: [Double]
    var optimisation: BassOptimisation?

    /// Seat-to-seat standard deviation of the level, 20 to 120 Hz, without and with the design.
    var seatSpreadBeforeDB: Double? { report?.seatStdBeforeDB }
    var seatSpreadAfterDB: Double? { report?.seatStdAfterDB }

    /// The joint optimiser is used only when it is allowed (the caller resolves E10's switch) and
    /// the topology has a subwoofer to optimise.
    static func make(
        sources: [MultichannelCalibrationSource],
        seats: [MultichannelCalibrationSeat],
        measurements: [MultichannelCalibrationMeasurement],
        sampleRate: Double,
        crossoverHz: Double,
        timingTier: BassTimingTier = .acoustic,
        jointBassAllowed: Bool
    ) throws -> SystemSetupBassDesign {
        let included = seats.filter { $0.included && $0.weight > 0 }
        let mains: [MultichannelCalibrationSource] = [.speaker(.frontLeft), .speaker(.frontRight)]
            .filter { sources.contains($0) }
        let subs = sources.filter { if case .subwoofer = $0 { return true } else { return false } }
        guard !mains.isEmpty else { throw SystemSetupBassError.noMainSpeakers }
        guard jointBassAllowed, !subs.isEmpty, !included.isEmpty else {
            return SystemSetupBassDesign(
                mode: .subAlignmentOnly, sampleRate: sampleRate, seatNames: included.map(\.name), rows: [],
                report: nil, seatMeanBeforeDB: [], seatMeanAfterDB: [], optimisation: nil)
        }
        let ordered = mains + subs
        let irs = try ordered.map { source in
            try included.map { seat -> RoomCorrectionCore.SeatImpulseResponse in
                guard let measurement = measurements.last(where: { $0.seatID == seat.id && $0.source == source }) else {
                    throw SystemSetupBassError.missingMeasurement(seat: seat.name, source: source.displayName)
                }
                guard let arrival = measurement.channel.quality.directArrivalSeconds, arrival.isFinite, arrival >= 0 else {
                    throw SystemSetupBassError.missingArrival(source: source.displayName)
                }
                return .init(
                    samples: measurement.channel.impulseResponse, arrivalFrames: arrival * sampleRate,
                    weight: seat.weight)
            }
        }
        let specs = mains.map { _ in BassChannelSpec.defaults(.main) } + subs.map { _ in BassChannelSpec.defaults(.sub) }
        var settings = BassOptimiserSettings(timingTier: timingTier)
        settings.crossoverHz = crossoverHz
        settings.fitLowHz = fitLowHz
        settings.fitHighHz = fitHighHz
        let result = try RoomCorrectionCore.optimiseBass(
            irs: irs, channels: specs, sampleRate: sampleRate, settings: settings)
        let rows = zip(ordered, result.report.channels).map {
            SystemSetupBassRow(
                source: $0, gainDB: $1.gainDB, delayMilliseconds: $1.delaySeconds * 1_000,
                polarityInverted: $1.polarityInverted)
        }
        return SystemSetupBassDesign(
            mode: .jointOptimised, sampleRate: sampleRate, seatNames: included.map(\.name), rows: rows,
            report: result.report,
            seatMeanBeforeDB: Self.seatMeans(result.beforeDB, seatCount: included.count),
            seatMeanAfterDB: Self.seatMeans(result.afterDB, seatCount: included.count),
            optimisation: result)
    }

    private static func seatMeans(_ values: [Double], seatCount: Int) -> [Double] {
        guard seatCount > 0, values.count >= seatCount else { return [] }
        let grid = values.count / seatCount
        return (0..<seatCount).map { seat in
            values[(seat * grid)..<((seat + 1) * grid)].reduce(0, +) / Double(grid)
        }
    }

    /// The profile with only the subwoofers' gain, delay and polarity replaced by the design's;
    /// speaker trims and delays from the Alignment step, and EQ bands, stay. Reverting to the
    /// snapshot restores everything. The subwoofer gain range is attenuation only, so a larger
    /// gain is limited to it.
    func applying(to profile: OutputDeviceProfileConfiguration) throws -> OutputDeviceProfileConfiguration {
        guard mode == .jointOptimised else { return profile }
        var updated = profile
        for row in rows {
            guard case .subwoofer(let subIndex) = row.source else { continue }
            guard let index = updated.subwooferAssignments.firstIndex(where: { $0.index == subIndex }) else {
                throw OutputDeviceCalibrationError.subwooferAssignmentUnavailable(subIndex)
            }
            var calibration = updated.subwooferAssignments[index].calibration ?? PhysicalSubwooferCalibration()
            let range = PhysicalSubwooferCalibration.gainRangeDB
            calibration.gainDB = min(range.upperBound, max(range.lowerBound, row.gainDB))
            calibration.delayMilliseconds = min(
                PhysicalSubwooferCalibration.delayRangeMilliseconds.upperBound, max(0, row.delayMilliseconds))
            calibration.polarityInverted = row.polarityInverted
            try calibration.validate(sampleRate: sampleRate)
            updated.subwooferAssignments[index].calibration = calibration
        }
        return updated
    }
}

// MARK: - Correction step

/// Music is the default: it can spend a latency budget on better pre-ringing behaviour. Video keeps
/// latency at zero (minimum phase).
enum SystemSetupCorrectionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case music, video

    var id: String { rawValue }
    static let `default`: SystemSetupCorrectionMode = .music

    var title: String { self == .music ? "Music" : "Video" }

    var detail: String {
        self == .music
            ? "Best sound for listening. May add a small delay (up to 50 ms)."
            : "No added delay, so picture and sound stay in step."
    }

    var latencyMode: RoomCorrectionLatencyMode { self == .music ? .defaultMusic : .video }

    /// The design family for this mode. Mixed phase only when the caller allows it (it then needs
    /// the verification that gates saving); otherwise minimum phase, whatever the mode.
    func designKind(mixedPhaseAllowed: Bool) -> SystemSetupDesignKind {
        mixedPhaseAllowed && self == .music ? .mixedPhase : .minimumPhase
    }
}

/// The E10 target library in plain language.
struct SystemSetupCorrectionTarget: Hashable, Sendable, Identifiable {
    var builtIn: RoomCorrectionBuiltInTarget
    var id: String { builtIn.rawValue }

    static let all = RoomCorrectionBuiltInTarget.allCases.map(SystemSetupCorrectionTarget.init)
    /// A gentle downward tilt is what most rooms and listeners prefer.
    static let `default` = SystemSetupCorrectionTarget(builtIn: .gentleDownwardTilt)

    var title: String {
        switch builtIn {
        case .gentleDownwardTilt: return "Natural"
        case .flat: return "Flat"
        case .bassShelfAndTilt: return "Warm"
        }
    }

    var detail: String {
        switch builtIn {
        case .gentleDownwardTilt: return "Slightly softer highs, like a well-treated room. Recommended."
        case .flat: return "Equal level at every frequency. Can sound bright."
        case .bassShelfAndTilt: return "Extra low-frequency weight with softer highs."
        }
    }

    var curve: RoomCorrectionTargetCurve { builtIn.curve }
}

enum SystemSetupCorrectionPlan {
    /// The Room Correction workspace's own defaults, so a design made here matches one made there.
    static let defaultParameters = RoomCorrectionDesignParameters(
        correctionLowHz: 30, correctionHighHz: 20_000, smoothingOctaves: 1.0 / 6.0,
        maximumBoostDB: 4, maximumCutDB: 8, requestedTapCount: 4_096)
}

/// What the Correction step shows for each seat: predicted error against the target before and after.
struct SystemSetupSeatPrediction: Equatable, Sendable, Identifiable {
    var name: String
    var rmsErrorBeforeDB: Double
    var rmsErrorAfterDB: Double
    var id: String { name }

    static func make(from report: RoomCorrectionDesignVerificationReport) -> [SystemSetupSeatPrediction] {
        report.positionReports.map {
            SystemSetupSeatPrediction(
                name: $0.positionName, rmsErrorBeforeDB: $0.rmsErrorBeforeDB, rmsErrorAfterDB: $0.rmsErrorAfterDB)
        }
    }
}
