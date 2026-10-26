import Foundation

// E12 S4: pure logic behind the Measure and Alignment steps of the guided setup. No SwiftUI, no
// engine, nothing here runs on an audio thread. The measurement itself stays in the existing
// campaign transport (`MultichannelCalibrationController`); this file only reads its seat records.
// Gated by `e12.guided-setup` at the call sites.

// MARK: - Measure step (design note 3)

/// Progress of the one measurement pass: every source at every included seat.
struct SystemSetupMeasureProgress: Equatable, Sendable {
    var seats: [MultichannelCalibrationSeat]
    var sources: [MultichannelCalibrationSource]
    var measurements: [MultichannelCalibrationMeasurement]

    var includedSeats: [MultichannelCalibrationSeat] { seats.filter { $0.included && $0.weight > 0 } }

    func measurement(seat: MultichannelCalibrationSeat, source: MultichannelCalibrationSource)
        -> MultichannelCalibrationMeasurement? {
        measurements.last { $0.seatID == seat.id && $0.source == source }
    }

    func isComplete(_ seat: MultichannelCalibrationSeat) -> Bool {
        !sources.isEmpty && sources.allSatisfy { measurement(seat: seat, source: $0) != nil }
    }

    var completedSeats: [MultichannelCalibrationSeat] { includedSeats.filter(isComplete) }

    var totalCount: Int { includedSeats.count * sources.count }

    var completedCount: Int {
        includedSeats.reduce(0) { total, seat in
            total + sources.filter { measurement(seat: seat, source: $0) != nil }.count
        }
    }

    var fraction: Double { totalCount == 0 ? 0 : Double(completedCount) / Double(totalCount) }

    var isComplete: Bool { totalCount > 0 && completedCount == totalCount }

    /// The next seat and source the campaign would measure (seat by seat, sources in order).
    var next: (seat: MultichannelCalibrationSeat, source: MultichannelCalibrationSource)? {
        for seat in includedSeats {
            for source in sources where measurement(seat: seat, source: source) == nil {
                return (seat, source)
            }
        }
        return nil
    }

    /// Writes the campaign into the flow's choices: one name and one measurement ID per complete
    /// included seat (the ID of its first source), so the reducer's "Measure every seat" holds only
    /// when every seat is fully measured.
    func apply(to choices: inout SystemSetupChoices) {
        choices.seatNames = includedSeats.map(\.name)
        choices.measurementIDs = includedSeats.compactMap { seat in
            guard isComplete(seat), let first = sources.first else { return nil }
            return measurement(seat: seat, source: first)?.id
        }
    }
}

// MARK: - Seat records to a Room Correction project (design note 3)

/// One adapter from campaign seat records to a `RoomCorrectionProject`, so bass and correction use
/// the same measurements and the user never measures twice. The result matches what Room
/// Correction's own path (`RoomCorrectionProjectController.retainMeasurement`) builds from the same
/// left and right records: a position per included seat, aggregated in the log-magnitude domain.
enum SystemSetupRoomProjectAdapter {
    enum AdapterError: Error, Equatable {
        case noSeatHasBothFrontSpeakers
        case sampleRateMismatch(seat: String)
    }

    static func project(
        playbackSystemID: UUID,
        name: String,
        seats: [MultichannelCalibrationSeat],
        measurements: [MultichannelCalibrationMeasurement],
        sampleRate: Double,
        sweep: RoomCorrectionSweepSettings?,
        microphone: RoomCorrectionMicrophone?,
        now: Date = Date()
    ) throws -> RoomCorrectionProject {
        var project = RoomCorrectionProject(
            playbackSystemID: playbackSystemID, name: name, createdAt: now, modifiedAt: now)
        project.sweep = sweep
        project.microphone = microphone
        for seat in seats where seat.included {
            func record(_ role: OutputProgramRole) -> MultichannelCalibrationMeasurement? {
                measurements.last { $0.seatID == seat.id && $0.source == .speaker(role) }
            }
            guard let left = record(.frontLeft), let right = record(.frontRight) else { continue }
            guard abs(left.sampleRate - sampleRate) < 0.5, abs(right.sampleRate - sampleRate) < 0.5 else {
                throw AdapterError.sampleRateMismatch(seat: seat.name)
            }
            project.measurements.append(RoomCorrectionMeasurementPosition(
                id: seat.id, name: seat.name, included: true, weight: seat.weight,
                sampleRate: sampleRate, left: left.channel, right: right.channel))
        }
        guard !project.measurements.isEmpty else { throw AdapterError.noSeatHasBothFrontSpeakers }
        do {
            project.aggregate = try RoomCorrectionSpatialAggregator()
                .aggregate(positions: project.measurements, generatedAt: now)
        } catch RoomCorrectionSpatialAggregationError.noIncludedPositions {
            project.aggregate = nil
        } catch RoomCorrectionSpatialAggregationError.zeroTotalWeight {
            project.aggregate = nil
        }
        return project
    }
}

// MARK: - Alignment step

struct SystemSetupAlignmentRow: Equatable, Sendable, Identifiable {
    var source: MultichannelCalibrationSource
    /// Speaker trim or subwoofer gain, dB (attenuation only, so 0 or negative).
    var levelDB: Double
    var delayMilliseconds: Double
    var polarityInverted: Bool
    /// Straight-line distance to the reference seat from the direct-arrival time.
    var distanceMetres: Double?

    var id: MultichannelCalibrationSource { source }
    var title: String { source.displayName }
    var distanceFeet: Double? { distanceMetres.map { $0 / SystemSetupAlignment.metresPerFoot } }

    var distanceText: String {
        guard let metres = distanceMetres, let feet = distanceFeet else { return "unknown" }
        return String(format: "%.2f m (%.1f ft)", metres, feet)
    }
}

/// Levels, polarity and distances the designer found, as the Alignment step shows them. Only these
/// three values are applied as the trial; EQ bands stay for the Correction step.
struct SystemSetupAlignment: Equatable, Sendable {
    static let speedOfSoundMetresPerSecond = 343.0
    static let metresPerFoot = 0.3048

    var sampleRate: Double
    var rows: [SystemSetupAlignmentRow]

    var invertedSources: [MultichannelCalibrationSource] { rows.filter(\.polarityInverted).map(\.source) }

    static func make(
        design: MultichannelCalibrationDesign,
        seats: [MultichannelCalibrationSeat],
        measurements: [MultichannelCalibrationMeasurement]
    ) -> SystemSetupAlignment {
        let reference = seats.first { $0.included && $0.weight > 0 }
        func distance(_ source: MultichannelCalibrationSource) -> Double? {
            guard let reference,
                  let seconds = measurements.last(where: { $0.seatID == reference.id && $0.source == source })?
                    .channel.quality.directArrivalSeconds,
                  seconds.isFinite, seconds >= 0 else { return nil }
            return seconds * speedOfSoundMetresPerSecond
        }
        var rows = design.speakers.map {
            SystemSetupAlignmentRow(
                source: .speaker($0.role), levelDB: $0.calibration.trimDB,
                delayMilliseconds: $0.calibration.delayMilliseconds,
                polarityInverted: $0.calibration.polarityInverted,
                distanceMetres: distance(.speaker($0.role)))
        }
        rows += design.subwoofers.map {
            SystemSetupAlignmentRow(
                source: .subwoofer($0.index), levelDB: $0.calibration.gainDB,
                delayMilliseconds: $0.calibration.delayMilliseconds,
                polarityInverted: $0.calibration.polarityInverted,
                distanceMetres: distance(.subwoofer($0.index)))
        }
        return SystemSetupAlignment(sampleRate: design.sampleRate, rows: rows)
    }

    /// The profile with only trim or gain, delay and polarity replaced; EQ bands and the
    /// deployment summary are untouched, so reverting to the snapshot restores it exactly.
    func applying(to profile: OutputDeviceProfileConfiguration) throws -> OutputDeviceProfileConfiguration {
        var updated = profile
        for row in rows {
            switch row.source {
            case .speaker(let role):
                guard let index = updated.speakerAssignments.firstIndex(where: { $0.role == role }) else {
                    throw OutputDeviceCalibrationError.speakerAssignmentUnavailable(role)
                }
                var calibration = updated.speakerAssignments[index].calibration ?? SemanticSpeakerCalibration()
                calibration.trimDB = row.levelDB
                calibration.delayMilliseconds = row.delayMilliseconds
                calibration.polarityInverted = row.polarityInverted
                try calibration.validate(sampleRate: sampleRate)
                updated.speakerAssignments[index].calibration = calibration
            case .subwoofer(let subIndex):
                guard let index = updated.subwooferAssignments.firstIndex(where: { $0.index == subIndex }) else {
                    throw OutputDeviceCalibrationError.subwooferAssignmentUnavailable(subIndex)
                }
                var calibration = updated.subwooferAssignments[index].calibration ?? PhysicalSubwooferCalibration()
                calibration.gainDB = row.levelDB
                calibration.delayMilliseconds = row.delayMilliseconds
                calibration.polarityInverted = row.polarityInverted
                try calibration.validate(sampleRate: sampleRate)
                updated.subwooferAssignments[index].calibration = calibration
            }
        }
        return updated
    }
}

// MARK: - Level step noise (design note 5)

enum SystemSetupNoiseError: Error, Equatable, LocalizedError {
    /// The engine does not yet publish the generator stage to the live graph (follow-up slice).
    case engineHookUnavailable
    case aboveCeiling

    var errorDescription: String? {
        switch self {
        case .engineHookUnavailable:
            return "This output cannot play the setup noise right now (it needs playback running on the graph renderer). Play steady pink noise from another app, or use the Generator tab in Measure."
        case .aboveCeiling:
            return "That level is above the generator ceiling."
        }
    }
}

/// What the Level step needs from the E11 generator. The real engine hook publishes
/// `SignalGeneratorSettings.stageParams` through `UnifiedGraphConfiguration.generatorParams`.
@MainActor
protocol SystemSetupNoisePlaying: AnyObject {
    var isPlaying: Bool { get }
    func start(_ settings: SignalGeneratorSettings, selection: SignalGeneratorLaneSelection) throws
    func stop()
}

extension SystemSetupLevelPlan {
    /// The settings the Level step may hand to a noise player: refuses anything above the ceiling
    /// and anything that is not band-limited pink noise at or below the plan's level.
    func validatedGeneratorSettings(sampleRate: Double = 48_000) throws -> SignalGeneratorSettings {
        let settings = generatorSettings(sampleRate: sampleRate)
        guard settings.levelDB <= Self.ceilingDB, settings.ceilingDB <= SignalGeneratorSettings.hardCeilingDB else {
            throw SystemSetupNoiseError.aboveCeiling
        }
        return settings
    }
}

/// What the engine-backed player needs from the engine: the same call `AudioIOEngine.setLiveGenerator` makes.
@MainActor
protocol SystemSetupGeneratorHost: AnyObject {
    func setLiveGenerator(_ settings: SignalGeneratorSettings?, selection: SignalGeneratorLaneSelection) throws
}

extension AudioIOEngine: SystemSetupGeneratorHost {}

/// E12 S4a: plays the Level step's noise through the engine's live graph. Re-checks the ceiling itself, so no
/// caller can hand the engine anything the plan would refuse; the engine reports sessions that cannot take it.
@MainActor
final class EngineSystemSetupNoisePlayer: SystemSetupNoisePlaying {
    private let host: SystemSetupGeneratorHost
    private(set) var isPlaying = false

    init(host: SystemSetupGeneratorHost) { self.host = host }

    func start(_ settings: SignalGeneratorSettings, selection: SignalGeneratorLaneSelection) throws {
        guard settings.kind == .bandLimitedPink || settings.kind == .pink,
              settings.levelDB <= SystemSetupLevelPlan.ceilingDB,
              settings.ceilingDB <= SignalGeneratorSettings.hardCeilingDB else {
            throw SystemSetupNoiseError.aboveCeiling
        }
        do {
            try host.setLiveGenerator(settings, selection: selection)
        } catch {
            isPlaying = false
            throw SystemSetupNoiseError.engineHookUnavailable
        }
        isPlaying = true
    }

    /// Retries once; if the engine still refuses, `isPlaying` stays true so the UI never claims silence while a
    /// generator stage may still be in the graph (the engine clears it on any session stop).
    func stop() {
        for _ in 0..<2 {
            do {
                try host.setLiveGenerator(nil, selection: .allProgram(includeLFE: false))
                isPlaying = false
                return
            } catch {}
        }
    }
}

/// Used until the engine publishes the generator stage: starting always reports why not.
@MainActor
final class UnconnectedSystemSetupNoisePlayer: SystemSetupNoisePlaying {
    var isPlaying: Bool { false }
    func start(_ settings: SignalGeneratorSettings, selection: SignalGeneratorLaneSelection) throws { throw SystemSetupNoiseError.engineHookUnavailable }
    func stop() {}
}
