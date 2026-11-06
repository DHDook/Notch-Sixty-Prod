import Foundation

// E26 S6a: multi-bus transport planning for the sub-aware Quiet Zone. The splitter-rendered through-feed (S2c) is
// split into the signal each hardware output plays (left main, right main, sub), so a sweep can drive the mains and
// the sub together on their real outputs, and each output can be swept alone for the post-split leakage sweep. Also
// verifies the band delay and level of that render against the impulse-response render (design 5).
//
// Realtime contract (AGENTS.md section 4): control plane only, allocates. The bridge's IOProc is the only realtime
// consumer, and it reads the lane programs this plan hands the transport. Sample rate: any; every quantity is in
// frames at the device rate or in seconds and hertz. Channels: at most 1 primary plus 7 lane programs.

/// Which hardware output channel plays which part of the split feed (a 2.1 interface with the sub on output 3 is
/// left 0, right 1, sub 2).
struct SubActuatorOutputMap: Equatable, Sendable {
    var leftOutput: UInt32
    var rightOutput: UInt32
    var subOutput: UInt32

    enum MapError: Error, Equatable, LocalizedError {
        case outputsClash
        case outputUnavailable(UInt32, available: Int)

        var errorDescription: String? {
            switch self {
            case .outputsClash: return "The left, right and sub outputs must be three different outputs."
            case .outputUnavailable(let channel, let available):
                return "Output \(channel + 1) does not exist on this device (\(available) outputs)."
            }
        }
    }

    func validate(outputChannelCount: Int) throws {
        guard Set([leftOutput, rightOutput, subOutput]).count == 3 else { throw MapError.outputsClash }
        for channel in [leftOutput, rightOutput, subOutput] where Int(channel) >= outputChannelCount {
            throw MapError.outputUnavailable(channel, available: outputChannelCount)
        }
    }
}

/// One output's signal, at the device rate.
struct SubActuatorOutputSignal: Equatable, Sendable {
    enum Role: Equatable, Sendable { case leftMain, rightMain, sub }
    var role: Role
    var outputChannel: UInt32
    var samples: [Float]

    var isSilent: Bool { samples.allSatisfy { $0 == 0 } }
}

/// The transport plan for one feed: the primary output plus up to six more outputs played in the same pass.
struct SubActuatorMultibusSweepPlan: Equatable, Sendable {
    var primary: SubActuatorOutputSignal
    var lanes: [SubActuatorOutputSignal]
    var frameCount: Int

    /// Every non-silent output, primary first. The mains split into low, mid and high buses that sum to the main's
    /// own output; the sub plays `SubMono`.
    static func make(
        rendered: ThroughFeedSplitterRenderer.Rendered, map: SubActuatorOutputMap, outputChannelCount: Int
    ) throws -> SubActuatorMultibusSweepPlan {
        try map.validate(outputChannelCount: outputChannelCount)
        func sum(_ buses: [N60SpeakerOutputBus]) -> [Float] {
            var out = [Float](repeating: 0, count: rendered.frameCount)
            for bus in buses {
                let b = rendered.bus(bus)
                for n in 0..<out.count { out[n] += b[n] }
            }
            return out
        }
        let left = SubActuatorOutputSignal(
            role: .leftMain, outputChannel: map.leftOutput,
            samples: sum([N60SpeakerOutputBusLeftLow, N60SpeakerOutputBusLeftMid, N60SpeakerOutputBusLeftHigh]))
        let right = SubActuatorOutputSignal(
            role: .rightMain, outputChannel: map.rightOutput,
            samples: sum([N60SpeakerOutputBusRightLow, N60SpeakerOutputBusRightMid, N60SpeakerOutputBusRightHigh]))
        let sub = SubActuatorOutputSignal(
            role: .sub, outputChannel: map.subOutput, samples: sum([N60SpeakerOutputBusSubMono]))
        let live = [left, right, sub].filter { !$0.isSilent }
        guard let primary = live.first else { throw ThroughFeedSplitterRenderer.RenderError.renderFailed }
        return SubActuatorMultibusSweepPlan(primary: primary, lanes: Array(live.dropFirst()), frameCount: rendered.frameCount)
    }

    /// The post-split leakage sweep per output: one single-output pass each, with that output's bus content as the
    /// sweep. Reuses the single-output transport unchanged.
    var leakagePasses: [SubActuatorOutputSignal] { [primary] + lanes }

    /// The lane programs the multi-bus transport attaches beside the primary sweep. `startFrame` is an absolute
    /// capture-timeline frame, so every lane starts where the primary sweep starts: after the lead-in.
    func laneProgramsForTransport(leadInFrames: Int) -> [MultichannelLaneProgram] {
        lanes.map {
            MultichannelLaneProgram(samples: $0.samples, startFrame: leadInFrames, outputChannelIndex: $0.outputChannel)
        }
    }
}

/// Re-verifies, on the splitter render, the band delay and level the anti-noise will see (design 5). A sweep cannot
/// go through the sweep analyzer for this (it re-times and normalises), so the render is divided by the dry sweep
/// band by band in the frequency domain, and compared with the impulse render's bands.
enum SplitterRenderVerifier {
    struct Result: Equatable, Sendable {
        var worstGainErrorDB: Double
        var worstDelayErrorSeconds: Double
        var bandsCompared: Int
        var passes: Bool
    }

    static let gainToleranceDB = 1.0
    static let delayToleranceSeconds = 0.0005
    /// Bands that stick out of the sweep's own range, or where the dry sweep has less than this fraction of its peak band energy, are skipped (the sweep gives no estimate there).
    static let minimumDryEnergyFraction = 1.0e-4

    static func verify(
        dry: [Float], rendered: [Float], impulseBands: [CombinedPathBand], sampleRate: Double,
        sweepRangeHz: ClosedRange<Double> = 40...450
    ) -> Result {
        guard dry.count == rendered.count, !dry.isEmpty, sampleRate > 0 else {
            return Result(worstGainErrorDB: .infinity, worstDelayErrorSeconds: .infinity, bandsCompared: 0, passes: false)
        }
        var energies: [Double] = []
        for band in impulseBands { energies.append(dryEnergy(dry, band: band, sampleRate: sampleRate)) }
        let peak = energies.max() ?? 0
        var worstGain = 0.0, worstDelay = 0.0, compared = 0
        for (i, band) in impulseBands.enumerated() where peak > 0 && energies[i] >= peak * minimumDryEnergyFraction
            && band.lowHz >= sweepRangeHz.lowerBound && band.highHz <= sweepRangeHz.upperBound {
            guard let reference = band.delaySeconds else { continue }
            let measured = bandResponse(dry: dry, rendered: rendered, band: band, sampleRate: sampleRate)
            guard let delay = measured.delay else { continue }
            let gainError = abs(20 * log10(max(measured.gain, 1e-12)) - band.gainDB)
            worstGain = max(worstGain, gainError)
            worstDelay = max(worstDelay, abs(delay - reference))
            compared += 1
        }
        return Result(
            worstGainErrorDB: worstGain, worstDelayErrorSeconds: worstDelay, bandsCompared: compared,
            passes: compared > 0 && worstGain <= gainToleranceDB && worstDelay <= delayToleranceSeconds)
    }

    private static func frequencies(_ band: CombinedPathBand) -> [Double] {
        (0..<CombinedPathBandAnalyzer.frequenciesPerBand).map {
            band.lowHz + (band.highHz - band.lowHz) * Double($0) / Double(CombinedPathBandAnalyzer.frequenciesPerBand - 1)
        }
    }

    private static func dft(_ x: [Float], _ f: Double, _ fs: Double) -> (re: Double, im: Double) {
        // Hann-windowed so the finite sweep's edges do not leak into the band.
        var re = 0.0, im = 0.0
        let w0 = 2 * Double.pi * f / fs
        let n = Double(x.count)
        for (i, v) in x.enumerated() where v != 0 {
            let win = 0.5 - 0.5 * cos(2 * Double.pi * (Double(i) + 0.5) / n)
            let ph = w0 * Double(i)
            re += win * Double(v) * cos(ph)
            im -= win * Double(v) * sin(ph)
        }
        return (re, im)
    }

    private static func dryEnergy(_ dry: [Float], band: CombinedPathBand, sampleRate: Double) -> Double {
        let f = (band.lowHz + band.highHz) / 2
        let d = dft(dry, f, sampleRate)
        return d.re * d.re + d.im * d.im
    }

    /// H(f) = Y(f) / X(f) at the band's frequencies, with the same weighting as the impulse analysis.
    private static func bandResponse(
        dry: [Float], rendered: [Float], band: CombinedPathBand, sampleRate: Double
    ) -> (gain: Double, delay: Double?) {
        let fs = frequencies(band)
        var h: [(re: Double, im: Double)] = []
        for f in fs {
            let x = dft(dry, f, sampleRate), y = dft(rendered, f, sampleRate)
            let den = x.re * x.re + x.im * x.im
            guard den > 0 else { return (0, nil) }
            h.append(((y.re * x.re + y.im * x.im) / den, (y.im * x.re - y.re * x.im) / den))
        }
        let mean = h.map { ($0.re * $0.re + $0.im * $0.im).squareRoot() }.reduce(0, +) / Double(h.count)
        // Group delay from the phase slope between neighbouring frequencies, weighted by power.
        var weighted = 0.0, weights = 0.0
        for k in 1..<h.count {
            let a = h[k - 1], b = h[k]
            let rel = (re: b.re * a.re + b.im * a.im, im: b.im * a.re - b.re * a.im)
            let dphi = atan2(rel.im, rel.re)
            let power = (a.re * a.re + a.im * a.im) + (b.re * b.re + b.im * b.im)
            weighted += power * (-dphi / (2 * Double.pi * (fs[k] - fs[k - 1])))
            weights += power
        }
        return (mean, weights > 0 ? weighted / weights : nil)
    }
}
