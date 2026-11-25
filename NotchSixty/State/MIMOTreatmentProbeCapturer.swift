import Foundation

/// E19 S12c: one source of the staged design, and the program lane that can play it alone (nil when the generator cannot).
struct MIMOProbeSource: Equatable, Sendable {
    var source: MultichannelCalibrationSource?
    var programLane: Int?
}

/// The engine side of the probe stimulus (`AudioIOEngine+MIMOTreatmentProbeFeed.swift`); fakes stand in for tests.
@MainActor
protocol MIMOProbeStimulusFeeding: AnyObject {
    var probeOutputSampleRate: Double? { get }
    var probeStageArmed: Bool { get }
    func probeSources() -> [MIMOProbeSource]
    func installProbeStimulus(_ settings: SignalGeneratorSettings, programLanes lanes: [Int]) throws
    func cueProbeStimulus(solo: Int) throws
    func removeProbeStimulus() throws
}

/// The seat microphone, recorded on its own clock beside the running playback (the `MeasurementInputMonitor` pattern).
@MainActor
protocol ProbeMicrophoneRecording: AnyObject {
    var sampleRate: Double { get }
    func begin() throws
    /// Stops and returns every sample recorded since `begin`.
    func finish() -> [Float]
}

enum MIMOTreatmentProbeCapturerError: Error, Equatable, LocalizedError {
    case noSources
    case sourceNotAddressable(String)
    case budgetExceeded(seconds: Double)
    case notInstalled
    case stageArmedMismatch(treated: Bool)
    case microphoneRateMismatch(microphone: Double, output: Double)
    case noResponse(String)
    case invalidStimulus
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .noSources: return "The staged design has no sources to measure."
        case .sourceNotAddressable(let name):
            return "\(name) cannot be played alone through the running graph yet, so the treated measurement cannot cover it."
        case .budgetExceeded(let seconds):
            return "The treated measurement would take \(Int(seconds)) s per seat, over the limit."
        case .notInstalled: return "The measurement stimulus is not installed."
        case .stageArmedMismatch(let treated):
            return treated ? "The treated capture needs the stage armed for the probe." : "The untreated capture needs the stage off."
        case .microphoneRateMismatch(let mic, let out):
            return "The microphone runs at \(Int(mic)) Hz but the output at \(Int(out)) Hz; set both to the same rate."
        case .noResponse(let source): return "No response was heard from \(source); check the microphone and the level."
        case .invalidStimulus: return "The measurement sweep is not valid at this sample rate."
        case .noMicrophone: return "Choose the seat microphone first."
        }
    }
}

/// E19 S12c (D15, decisions 2 to 4): the production `TreatmentProbeCapturing`. It installs the cued sweep generator once, with
/// the stage unarmed, then per seat plays one solo sweep per source (a cue post, never a rebuild) while the seat microphone
/// records on its own clock; the impulse response comes from deconvolving with the known synchronised sweep and the arrival is
/// located in the result, so microphone and output clocks need not be shared. The generator is removed only after the probe has
/// disarmed. It owns `probeProgrammeMuted`: set after the install succeeded, cleared before the removal.
@MainActor
final class MIMOTreatmentProbeCapturer: TreatmentProbeCapturing {
    /// Per seat: sweeps plus tails must fit this (inside the 120 s per-seat limit, D13).
    nonisolated static let budgetSeconds = 100.0
    nonisolated static let tailSeconds = 1.0
    nonisolated static let preRollSeconds = 0.3
    nonisolated static let minSweepSeconds = 2.0
    nonisolated static let maxSweepSeconds = 5.0
    /// Kept before the direct arrival so the onset is whole, and after it for the room's decay.
    nonisolated static let irLeadSeconds = 0.005
    nonisolated static let irLengthSeconds = 0.5
    nonisolated static let regularisation = 1.0e-10

    private let treatment: MIMOGraphTreatment
    private let feed: MIMOProbeStimulusFeeding
    private let makeRecorder: () throws -> ProbeMicrophoneRecording
    /// The E24 seat sweep settings at a rate; its level is the ceiling of the probe's stimulus.
    private let seatSweep: (Double) -> RoomCorrectionSweepSettings
    private let sleep: (TimeInterval) async throws -> Void
    private let budget: Double
    private var installed = false
    private var sources: [MIMOProbeSource] = []
    private var excitation: [Float] = []
    private var sweepSeconds = 0.0
    private var gain: Float = 1
    private var rate = 0.0

    init(
        treatment: MIMOGraphTreatment, feed: MIMOProbeStimulusFeeding,
        makeRecorder: @escaping () throws -> ProbeMicrophoneRecording,
        seatSweep: @escaping (Double) -> RoomCorrectionSweepSettings,
        budget: Double = MIMOTreatmentProbeCapturer.budgetSeconds,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }
    ) {
        self.treatment = treatment
        self.feed = feed
        self.makeRecorder = makeRecorder
        self.seatSweep = seatSweep
        self.budget = budget
        self.sleep = sleep
    }

    /// Seconds of one sweep for `count` sources: as long as the budget allows, between 2 and 5 s; nil when none fits.
    nonisolated static func sweepSeconds(sourceCount count: Int, budget: Double = budgetSeconds) -> Double? {
        guard count > 0 else { return nil }
        let fit = budget / Double(count) - tailSeconds
        guard fit >= minSweepSeconds else { return nil }
        return min(maxSweepSeconds, fit)
    }

    // MARK: TreatmentProbeCapturing

    func setProgrammeStopped(_ stopped: Bool) throws {
        if stopped {
            guard !installed else { return }
            let list = feed.probeSources()
            guard !list.isEmpty, let outputRate = feed.probeOutputSampleRate else { throw MIMOTreatmentProbeCapturerError.noSources }
            if let bad = list.first(where: { $0.programLane == nil }) {
                throw MIMOTreatmentProbeCapturerError.sourceNotAddressable(bad.source?.displayName ?? "A routed output")
            }
            guard let seconds = Self.sweepSeconds(sourceCount: list.count, budget: budget) else {
                throw MIMOTreatmentProbeCapturerError.budgetExceeded(
                    seconds: Double(list.count) * (Self.minSweepSeconds + Self.tailSeconds))
            }
            let seat = seatSweep(outputRate)
            // Never above the E24 level: the generator's level is RMS, so the sweep peak is 3 dB above it.
            let level = min(seat.levelDBFS - 20 * log10(2.0.squareRoot()), SignalGeneratorSettings.hardCeilingDB)
            var settings = SignalGeneratorSettings()
            settings.kind = .sweep
            settings.levelDB = level
            settings.ceilingDB = SignalGeneratorSettings.hardCeilingDB
            settings.lowHz = seat.startFrequencyHz
            settings.highHz = min(seat.endFrequencyHz, 0.45 * outputRate)
            settings.periodFrames = Int((seconds * outputRate).rounded())
            settings.seed = 1
            settings.muteOtherAudio = true
            settings.autoStopSeconds = SignalGeneratorSettings.maxAutoStopSeconds
            let made: (samples: [Float], info: MeasurementCore.SweepInfo)
            do {
                made = try MeasurementCore.makeSweep(
                    sampleRate: outputRate, startFrequencyHz: settings.lowHz, endFrequencyHz: settings.highHz,
                    durationSeconds: Double(settings.periodFrames) / outputRate, levelDBFS: 0, fadeSeconds: 0.05, synchronised: true)
            } catch { throw MIMOTreatmentProbeCapturerError.invalidStimulus }
            try feed.installProbeStimulus(settings, programLanes: list.compactMap(\.programLane).sorted())
            // Only after the install succeeded: the generator now replaces programme on every source lane.
            treatment.probeProgrammeMuted = true
            installed = true
            sources = list
            excitation = made.samples
            sweepSeconds = Double(made.samples.count) / outputRate
            gain = Float(pow(10.0, settings.effectiveLevelDB / 20.0) * 2.0.squareRoot())
            rate = outputRate
        } else {
            // Cleared before the removal, so no arm can start on a stimulus that is going away.
            treatment.probeProgrammeMuted = false
            guard installed else { return }
            try feed.removeProbeStimulus()
            installed = false
        }
    }

    func capture(seatID: UUID, treated: Bool) async throws -> [MultichannelCalibrationMeasurement] {
        guard installed else { throw MIMOTreatmentProbeCapturerError.notInstalled }
        guard feed.probeStageArmed == treated else { throw MIMOTreatmentProbeCapturerError.stageArmedMismatch(treated: treated) }
        let recorder = try makeRecorder()
        guard abs(recorder.sampleRate - rate) < 0.5 else {
            throw MIMOTreatmentProbeCapturerError.microphoneRateMismatch(microphone: recorder.sampleRate, output: rate)
        }
        // Source order follows the stage; the solo word counts the installed lanes in ascending lane order.
        let ascending = sources.compactMap(\.programLane).sorted()
        var out: [MultichannelCalibrationMeasurement] = []
        for entry in sources {
            try Task.checkCancellation()
            guard feed.probeStageArmed == treated else { throw MIMOTreatmentProbeCapturerError.stageArmedMismatch(treated: treated) }
            guard let lane = entry.programLane, let solo = ascending.firstIndex(of: lane), let source = entry.source else {
                throw MIMOTreatmentProbeCapturerError.sourceNotAddressable(entry.source?.displayName ?? "A source")
            }
            try recorder.begin()
            let recorded: [Float]
            do {
                try await sleep(Self.preRollSeconds)
                try feed.cueProbeStimulus(solo: solo + 1)
                try await sleep(sweepSeconds + Self.tailSeconds)
                recorded = recorder.finish()
            } catch {
                _ = recorder.finish()
                throw error
            }
            let channel = try Self.measurement(
                recording: recorded, excitation: excitation, gain: gain, sampleRate: rate, sourceName: source.displayName)
            out.append(MultichannelCalibrationMeasurement(seatID: seatID, source: source, sampleRate: rate, channel: channel))
        }
        return out
    }

    // MARK: Analysis (pure)

    /// Deconvolves `recording` with the known `excitation` (the 0 dBFS peak synchronised sweep the generator plays) and keeps
    /// the impulse response from just before the direct arrival: the arrival is the largest response in the recording, so the
    /// recording's start offset and clock need not be known. The result is scaled to per unit of drive (divided by `gain`, the
    /// peak amplitude actually played). Harmonic impulses sit at negative time, the end of the circular result, and are left out.
    nonisolated static func measurement(
        recording: [Float], excitation: [Float], gain: Float, sampleRate: Double, sourceName: String
    ) throws -> RoomCorrectionChannelMeasurement {
        guard !recording.isEmpty, recording.allSatisfy(\.isFinite) else { throw MIMOTreatmentProbeCapturerError.noResponse(sourceName) }
        let circular: [Float]
        do {
            circular = try MeasurementCore.deconvolve(excitation: excitation, observed: recording, regularizationRatio: regularisation)
        } catch { throw MIMOTreatmentProbeCapturerError.noResponse(sourceName) }
        // The sweep starts somewhere in the first part of the recording, so the arrival is before the last sweep length.
        let searchEnd = min(circular.count, max(1, recording.count - excitation.count / 2))
        var peakIndex = 0
        var peak: Float = 0
        for index in 0..<searchEnd where abs(circular[index]) > peak {
            peak = abs(circular[index])
            peakIndex = index
        }
        var floorSum = 0.0
        let floorStart = min(circular.count, peakIndex + Int(sampleRate * 0.8))
        let floorEnd = min(searchEnd, floorStart + Int(sampleRate * 0.5))
        if floorEnd > floorStart { for index in floorStart..<floorEnd { floorSum += Double(circular[index]) * Double(circular[index]) } }
        let floorRMS = floorEnd > floorStart ? (floorSum / Double(floorEnd - floorStart)).squareRoot() : 0
        guard peak > 0, Double(peak) > 4 * floorRMS else { throw MIMOTreatmentProbeCapturerError.noResponse(sourceName) }
        let lead = Int((irLeadSeconds * sampleRate).rounded())
        let start = max(0, peakIndex - lead)
        let end = min(circular.count, peakIndex + Int((irLengthSeconds * sampleRate).rounded()))
        let scale = 1 / gain
        let response = circular[start..<end].map { $0 * scale }
        var quality = RoomCorrectionMeasurementQuality()
        let capturePeak = Double(recording.map { abs($0) }.max() ?? 0)
        quality.sweepComplete = true
        quality.capturePeakDBFS = capturePeak > 0 ? 20 * log10(capturePeak) : nil
        quality.clipped = capturePeak >= 0.99
        quality.directArrivalSeconds = Double(peakIndex - start) / sampleRate
        quality.estimatedSNRDB = floorRMS > 0 ? 20 * log10(Double(peak) / floorRMS) : nil
        return RoomCorrectionChannelMeasurement(
            capturedAt: Date(), rawCapture: [], impulseResponse: response, transferFunction: nil, quality: quality)
    }
}

extension MIMOTreatmentProbeCapturer {
    /// The production wiring: the engine's probe feed, the seat microphone the E24 calibration controls select, and the E24
    /// sweep level and range.
    static func production(engine: AudioIOEngine, calibration: RoomCorrectionCalibrationController) -> MIMOTreatmentProbeCapturer {
        MIMOTreatmentProbeCapturer(
            treatment: engine.treatment, feed: engine,
            makeRecorder: { [calibration] in
                guard let microphone = calibration.selectedInputDevice else { throw MIMOTreatmentProbeCapturerError.noMicrophone }
                return try ProbeMicrophoneRecorder(microphone: microphone, channel: calibration.selectedInputChannelIndex)
            },
            seatSweep: { [calibration] in calibration.sweepSettings(sampleRate: $0) })
    }
}
