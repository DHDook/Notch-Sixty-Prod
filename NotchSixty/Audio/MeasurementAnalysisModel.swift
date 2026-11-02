import Foundation

/// E24 S4b (design note 9): the Analysis tab's model. A source is one capture or library record
/// reduced to what the analyses need: the impulse response, the raw capture when it was kept, and
/// the sweep settings that played. Everything here is pure and runs off the main actor.

struct MeasurementAnalysisSource: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case speakerLab = "Speaker Lab"
        case roomCorrection = "Room Correction"
        case multichannel = "Multichannel"
        case library = "Library"
    }

    var id: String
    var kind: Kind
    var title: String
    var sampleRate: Double
    var impulseResponse: [Float]
    var arrivalSeconds: Double?
    /// Empty when the capture did not keep the raw recording.
    var rawCapture: [Float]
    var sweep: RoomCorrectionSweepSettings?

    var displayTitle: String { "\(kind.rawValue): \(title)" }

    /// Why distortion cannot be computed, or nil when it can.
    var distortionUnavailableReason: String? {
        if rawCapture.isEmpty { return "Distortion needs the raw capture, and this one did not keep it." }
        if sweep == nil { return "Distortion needs the sweep settings, and this one does not record them." }
        return nil
    }
}

extension MeasurementAnalysisSource {
    static func speakerLab(_ capture: SpeakerMeasurementLabCapture) -> MeasurementAnalysisSource {
        MeasurementAnalysisSource(
            id: "lab-\(capture.id.uuidString)", kind: .speakerLab, title: capture.source.displayName,
            sampleRate: capture.sampleRate, impulseResponse: capture.impulseResponse,
            arrivalSeconds: capture.quality.directArrivalSeconds, rawCapture: [], sweep: nil)
    }

    static func roomCorrection(
        position: RoomCorrectionMeasurementPosition, left: Bool, sweep: RoomCorrectionSweepSettings?
    ) -> MeasurementAnalysisSource {
        let channel = left ? position.left : position.right
        return MeasurementAnalysisSource(
            id: "room-\(position.id.uuidString)-\(left ? "L" : "R")", kind: .roomCorrection,
            title: "\(position.name), \(left ? "left" : "right")", sampleRate: position.sampleRate,
            impulseResponse: channel.impulseResponse, arrivalSeconds: channel.quality.directArrivalSeconds,
            rawCapture: channel.rawCapture, sweep: sweep)
    }

    static func multichannel(
        _ measurement: MultichannelCalibrationMeasurement, seatName: String?
    ) -> MeasurementAnalysisSource {
        MeasurementAnalysisSource(
            id: "multi-\(measurement.id.uuidString)", kind: .multichannel,
            title: [seatName, measurement.source.displayName].compactMap { $0 }.joined(separator: ", "),
            sampleRate: measurement.sampleRate, impulseResponse: measurement.channel.impulseResponse,
            arrivalSeconds: measurement.channel.quality.directArrivalSeconds,
            rawCapture: measurement.channel.rawCapture, sweep: nil)
    }

    /// A library record. Throws when it has no impulse response or a file is unreadable.
    static func library(_ record: MeasurementRecord, from library: MeasurementLibrary) throws -> MeasurementAnalysisSource {
        guard record.hasImpulseResponse else {
            throw MeasurementLibraryError.incompatible("\(record.name) is a curve only, with no impulse response to analyse.")
        }
        return MeasurementAnalysisSource(
            id: "library-\(record.id.uuidString)", kind: .library, title: record.name,
            sampleRate: record.sampleRate, impulseResponse: try library.loadImpulseResponse(id: record.id),
            arrivalSeconds: record.quality.directArrivalSeconds,
            rawCapture: record.hasRawCapture ? try library.loadRawCapture(id: record.id) : [],
            sweep: record.sweep)
    }
}

enum MeasurementAnalysisModel {
    enum DistortionOutcome: Equatable, Sendable {
        case result(MeasurementCore.DistortionResult)
        case unavailable(String)
    }

    enum DecayOutcome: Equatable, Sendable {
        case result(octave: [MeasurementCore.DecayBand], thirdOctave: [MeasurementCore.DecayBand])
        case unavailable(String)
    }

    struct Result: Equatable, Sendable {
        var distortion: DistortionOutcome
        var decay: DecayOutcome
    }

    static func analyze(_ source: MeasurementAnalysisSource) -> Result {
        Result(distortion: distortion(of: source), decay: decay(of: source))
    }

    static func decay(of source: MeasurementAnalysisSource) -> DecayOutcome {
        guard !source.impulseResponse.isEmpty else { return .unavailable("This source has no impulse response.") }
        do {
            return .result(
                octave: try MeasurementCore.analyzeDecay(
                    impulseResponse: source.impulseResponse, sampleRate: source.sampleRate, bandsPerOctave: 1),
                thirdOctave: try MeasurementCore.analyzeDecay(
                    impulseResponse: source.impulseResponse, sampleRate: source.sampleRate, bandsPerOctave: 3))
        } catch {
            return .unavailable("The decay could not be computed from this impulse response.")
        }
    }

    /// Rebuilds the excitation from the sweep settings and deconvolves the first sweep period of the
    /// raw capture over its whole circular length. The stored impulse response is truncated and loses
    /// the negative-time harmonic impulses, so it cannot be used here.
    static func distortion(of source: MeasurementAnalysisSource) -> DistortionOutcome {
        if let reason = source.distortionUnavailableReason { return .unavailable(reason) }
        guard let settings = source.sweep else { return .unavailable("Distortion needs the sweep settings.") }
        do {
            var single = settings
            single.repeatCount = 1
            let program = try RoomCorrectionSweepGenerator().makeProgram(settings: single)
            let start = program.leadInFrames
            let end = start + program.sweepSamples.count + program.tailFrames
            guard abs(settings.sampleRate - source.sampleRate) < 0.5, end <= source.rawCapture.count,
                  source.rawCapture.allSatisfy(\.isFinite) else {
                return .unavailable("The raw capture does not match the sweep settings, so distortion was not computed.")
            }
            let observed = Array(source.rawCapture[start..<end])
            var excitation = [Float](repeating: 0, count: observed.count)
            for (index, sample) in program.sweepSamples.enumerated() { excitation[index] = sample }
            let response = try MeasurementCore.deconvolve(
                excitation: excitation, observed: observed,
                regularizationRatio: Double(RoomCorrectionMeasurementAnalyzer.regularizationPowerRatio))
            let logRatio = log(settings.endFrequencyHz / settings.startFrequencyHz)
            let sweep = MeasurementCore.SweepInfo(
                frameCount: program.sweepSamples.count, sweepRateSeconds: settings.durationSeconds / logRatio,
                durationSeconds: settings.durationSeconds)
            return .result(try MeasurementCore.analyzeDistortion(
                response: response, sampleRate: source.sampleRate, sweep: sweep,
                startFrequencyHz: settings.startFrequencyHz, endFrequencyHz: settings.endFrequencyHz))
        } catch {
            return .unavailable("Distortion could not be computed from this capture.")
        }
    }
}
