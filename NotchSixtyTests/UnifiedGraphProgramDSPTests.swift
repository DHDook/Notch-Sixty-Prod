import XCTest
@testable import NotchSixty

/// E6 S9a: stereo-class program DSP mapped onto the lane sets of an N-channel layout (decision D2).
/// Behavioural: real graphs, real blocks, every standard rate.
final class UnifiedGraphProgramDSPTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    private func shape(_ layout: OutputProgramLayout) throws -> UnifiedGraphLayoutShape {
        try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
    }

    private func peak(_ gainDB: Double) -> UnifiedGraphPEQSection {
        UnifiedGraphPEQSection(type: Int(N60BiquadFilterTypePeaking.rawValue), frequencyHz: 1_000, gainDB: gainDB, q: 1)
    }

    private func stereo(rate: Double, left: [UnifiedGraphPEQSection] = [], right: [UnifiedGraphPEQSection] = [],
                        stages: UnifiedGraphStereoStages = UnifiedGraphStereoStages()) -> UnifiedGraphConfiguration {
        var l = UnifiedGraphLane(); l.eq = left
        var r = UnifiedGraphLane(); r.eq = right
        var configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [l, r])
        configuration.stereoStages = stages
        return configuration
    }

    private func config(
        rate: Double, layout: OutputProgramLayout, dsp: UnifiedGraphProgramDSP?
    ) throws -> UnifiedGraphConfiguration {
        let count = layout.roles.count
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(
            sampleRate: rate, programChannels: count, subwoofers: []
        )
        configuration.orderPolicy = .canonical
        configuration.programDSP = dsp
        return configuration
    }

    /// Renders a 1 kHz tone per lane (amplitude 0 = silent) and returns every output lane.
    private func render(_ configuration: UnifiedGraphConfiguration, amps: [Float], seconds: Double = 0.3) throws -> [[Float]] {
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        let rate = configuration.sampleRate
        let total = Int(rate * seconds) / block * block
        var out = [[Float]](repeating: [], count: amps.count)
        var position = 0
        while position < total {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: amps.count)
            for lane in 0..<amps.count where amps[lane] != 0 {
                input[lane] = (0..<block).map {
                    amps[lane] * Float(sin(2.0 * .pi * 1_000.0 * Double(position + $0) / rate))
                }
            }
            let result = try host.processOffline(input: input, frames: block)
            for lane in 0..<amps.count { out[lane] += result[lane] }
            position += block
        }
        return out
    }

    private func tail(_ x: [Float]) -> Double { rms(x[(x.count * 3 / 4)...]) }

    func testLinkedEQCoversEveryNonLFELaneAndLeavesLFEUntouched() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, left: [peak(6)], right: [peak(6)]),
                                             shape: s, eqMode: .linked)
            let amps = [Float](repeating: 0.1, count: 6)
            let base = try render(try config(rate: rate, layout: layout, dsp: nil), amps: amps)
            let eq = try render(try config(rate: rate, layout: layout, dsp: dsp), amps: amps)
            let lfe = try XCTUnwrap(s.lfeLane)
            for lane in 0..<6 {
                if lane == lfe {
                    XCTAssertEqual(eq[lane], base[lane], "LFE must be bit-identical at \(rate)")
                } else {
                    let ratio = tail(eq[lane]) / tail(base[lane])
                    XCTAssertEqual(20 * log10(ratio), 6, accuracy: 0.5, "lane \(lane) at \(rate)")
                }
            }
        }
    }

    func testIndependentEQTouchesOnlyPairMembers() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, left: [peak(6)]), shape: s, eqMode: .independent)
            let amps = [Float](repeating: 0.1, count: 6)
            let base = try render(try config(rate: rate, layout: layout, dsp: nil), amps: amps)
            let eq = try render(try config(rate: rate, layout: layout, dsp: dsp), amps: amps)
            let touched = Set(s.leftMembers)
            for lane in 0..<6 {
                if touched.contains(lane) {
                    XCTAssertNotEqual(eq[lane], base[lane], "lane \(lane) at \(rate)")
                } else {
                    XCTAssertEqual(eq[lane], base[lane], "lane \(lane) must be untouched at \(rate)")
                }
            }
        }
    }

    func testLinkedCompressorReducesQuietLaneFromLoudLane() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            var stages = UnifiedGraphStereoStages()
            stages.compressor = [-30, 4, 6, 5, 50, 0, 0, 0, 0, 1]
            let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, stages: stages), shape: s, eqMode: .linked)
            // Loud tone on lane 0, a quiet one (below threshold on its own) on the lane across the layout.
            var amps = [Float](repeating: 0, count: 6)
            amps[0] = 0.8
            amps[4] = 0.01
            let base = try render(try config(rate: rate, layout: layout, dsp: nil), amps: amps)
            let comp = try render(try config(rate: rate, layout: layout, dsp: dsp), amps: amps)
            XCTAssertLessThan(tail(comp[4]), tail(base[4]) * 0.9, "quiet lane follows the group at \(rate)")
            XCTAssertLessThan(tail(comp[0]), tail(base[0]) * 0.9, "loud lane reduced at \(rate)")
        }
    }

    func testFrontPairDelayLeavesOtherLanesInPlace() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            var l = UnifiedGraphLane(); l.delayFrames = 48
            var r = UnifiedGraphLane(); r.delayFrames = 48
            var st = UnifiedGraphConfiguration(sampleRate: rate, lanes: [l, r])
            st.stereoStages = UnifiedGraphStereoStages()
            let dsp = UnifiedGraphProgramDSP(stereo: st, shape: s, eqMode: .linked)
            let amps = [Float](repeating: 0.1, count: 6)
            let base = try render(try config(rate: rate, layout: layout, dsp: nil), amps: amps)
            let delayed = try render(try config(rate: rate, layout: layout, dsp: dsp), amps: amps)
            let front: Set<Int> = [try XCTUnwrap(s.frontLeft), try XCTUnwrap(s.frontRight)]
            for lane in 0..<6 {
                if front.contains(lane) {
                    XCTAssertNotEqual(delayed[lane], base[lane], "front lane \(lane) at \(rate)")
                } else {
                    XCTAssertEqual(delayed[lane], base[lane], "lane \(lane) must be untouched at \(rate)")
                }
            }
        }
    }

    func testRejectionsNameTheirReason() throws {
        let rate = 48_000.0
        let s = try shape(.fiveOne)
        var spec = try config(rate: rate, layout: .fiveOne, dsp: nil).makeSpec()

        var delayLane = UnifiedGraphLane(); delayLane.delayFrames = 16
        let delayed = UnifiedGraphConfiguration(sampleRate: rate, lanes: [delayLane, delayLane])
        var virtual = UnifiedGraphProgramDSP(stereo: delayed, shape: s, eqMode: .linked, virtualSpeakers: true)
        XCTAssertThrowsError(try virtual.apply(to: &spec)) {
            XCTAssertEqual($0 as? UnifiedGraphFallbackReason, .virtualSpeakersSpeakerStage)
        }

        var fir = UnifiedGraphStereoStages()
        fir.programFIR = UnifiedGraphFIRProgram(generation: 1, left: [1, 0, 0, 0], right: nil, declaredLatencyFrames: 0)
        let ms = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, left: [peak(3)], stages: fir), shape: s, eqMode: .midSide)
        XCTAssertThrowsError(try ms.apply(to: &spec)) {
            XCTAssertEqual($0 as? UnifiedGraphFallbackReason, .midSideProgramFIR)
        }
    }

    func testNeutralProgramDSPChangesNothing() throws {
        let rate = 48_000.0
        let s = try shape(.fiveOne)
        let neutral = UnifiedGraphProgramDSP(stereo: stereo(rate: rate), shape: s, eqMode: .linked)
        XCTAssertTrue(neutral.isNeutral)
        let amps = [Float](repeating: 0.1, count: 6)
        let a = try render(try config(rate: rate, layout: .fiveOne, dsp: nil), amps: amps)
        let b = try render(try config(rate: rate, layout: .fiveOne, dsp: neutral), amps: amps)
        XCTAssertEqual(a, b)
    }

    func testSevenOneFourBuildsAndRendersWithHeavyProgramDSP() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.sevenOneFour
            let s = try shape(layout)
            var stages = UnifiedGraphStereoStages()
            stages.compressor = [-30, 4, 6, 5, 50, 0, 0, 0, 0, 1]
            let dsp = UnifiedGraphProgramDSP(
                stereo: stereo(rate: rate, left: [peak(3), peak(-2)], right: [peak(3), peak(-2)], stages: stages),
                shape: s, eqMode: .linked
            )
            let amps = [Float](repeating: 0.1, count: layout.roles.count)
            let out = try render(try config(rate: rate, layout: layout, dsp: dsp), amps: amps, seconds: 0.1)
            XCTAssertEqual(out.count, layout.roles.count)
            XCTAssertTrue(out.allSatisfy { $0.allSatisfy(\.isFinite) }, "finite at \(rate)")
        }
    }

    // MARK: S9a2 hardening

    /// A unit impulse on every lane at frame 0, rendered for `frames` frames; returns every output lane.
    private func renderImpulse(_ spec: UnifiedGraphSpec, lanes: Int, only: Int? = nil, frames: Int) throws -> [[Float]] {
        let host = try UnifiedGraphHost(spec: spec)
        var out = [[Float]](repeating: [], count: Int(spec.outputChannels))
        var position = 0
        while position < frames {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: lanes)
            if position == 0 {
                for lane in 0..<lanes where only == nil || only == lane { input[lane][0] = 1 }
            }
            let result = try host.processOffline(input: input, frames: block)
            for lane in 0..<result.count { out[lane] += result[lane] }
            position += block
        }
        return out
    }

    private func peakIndex(_ x: [Float]) -> Int {
        var best = 0
        for index in x.indices where abs(x[index]) > abs(x[best]) { best = index }
        return best
    }

    private func delta(at index: Int, length: Int? = nil) -> [Float] {
        var taps = [Float](repeating: 0, count: max(index + 1, length ?? 0))
        taps[index] = 1
        return taps
    }

    /// A denoiser as the translator builds it from a real snapshot, with the latency the snapshot reports.
    private func denoiserStages(rate: Double, quality: N60DenoiserQuality) throws -> (UnifiedGraphStereoStages, UInt32) {
        var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
            &snapshot.dynamics, rate, true, N60DenoiserTuningStandard, quality,
            0.7, -50, false, 0, 150, 0, N60DenoiserProfileCommandNone))
        let reported = snapshot.dynamics.spectralDenoiser.latencyFrames
        let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        XCTAssertNotNil(configuration.stereoStages.denoiser)
        return (configuration.stereoStages, reported)
    }

    func testRoomAndSpeakerIRLatencyAlignsEveryLaneAtEveryRate() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            let roomDelay = 100, irDelay = 40
            var stages = UnifiedGraphStereoStages()
            stages.roomFIR = UnifiedGraphFIRProgram(generation: 1, left: delta(at: roomDelay), right: nil,
                                                    declaredLatencyFrames: UInt32(roomDelay))
            stages.speakerIR = UnifiedGraphFIRProgram(generation: 1, left: delta(at: irDelay), right: nil,
                                                      declaredLatencyFrames: UInt32(irDelay))
            let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, stages: stages), shape: s, eqMode: .linked)
            let spec = try config(rate: rate, layout: layout, dsp: dsp).makeSpec()
            let expected = 256 + roomDelay + 256 + irDelay
            let out = try renderImpulse(spec, lanes: 6, frames: 2_048)
            for lane in 0..<6 {
                XCTAssertEqual(peakIndex(out[lane]), expected, "lane \(lane) at \(rate)")
            }
            let host = try UnifiedGraphHost(spec: spec)
            XCTAssertEqual(Int(host.latencyFrames), expected, "reported latency at \(rate)")
        }
    }

    func testRoomOnlyAndSpeakerIROnlyAlignEveryLane() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.sevenOneFour
            let s = try shape(layout)
            for useRoom in [true, false] {
                var stages = UnifiedGraphStereoStages()
                let program = UnifiedGraphFIRProgram(generation: 1, left: delta(at: 64), right: nil, declaredLatencyFrames: 64)
                if useRoom { stages.roomFIR = program } else { stages.speakerIR = program }
                let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, stages: stages), shape: s, eqMode: .linked)
                let spec = try config(rate: rate, layout: layout, dsp: dsp).makeSpec()
                let out = try renderImpulse(spec, lanes: layout.roles.count, frames: 1_024)
                for lane in 0..<layout.roles.count {
                    XCTAssertEqual(peakIndex(out[lane]), 256 + 64, "lane \(lane) room \(useRoom) at \(rate)")
                }
            }
        }
    }

    func testDenoiserLatencyIsTheReportedLatencyAtEveryRate() throws {
        for rate in Self.rates {
            for quality in [N60DenoiserQualityQuality, N60DenoiserQualityHigh] {
                let layout = OutputProgramLayout.fiveOne
                let s = try shape(layout)
                let (stages, reported) = try denoiserStages(rate: rate, quality: quality)
                XCTAssertEqual(stages.denoiserLatencyFrames, reported)
                let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, stages: stages), shape: s, eqMode: .linked)
                let spec = try config(rate: rate, layout: layout, dsp: dsp).makeSpec()
                let host = try UnifiedGraphHost(spec: spec)
                XCTAssertEqual(host.latencyFrames, reported, "graph latency at \(rate)")
                // The LFE is not covered by the denoiser: its delta filter lands on the reported latency.
                let lfe = try XCTUnwrap(s.lfeLane)
                let out = try renderImpulse(spec, lanes: 6, only: lfe, frames: Int(reported) / block * block + 2 * block)
                XCTAssertEqual(peakIndex(out[lfe]), Int(reported), "LFE alignment at \(rate)")
            }
        }
    }

    func testAlignmentFollowsAReportedLatencyThatIsNotTheFFTSize() throws {
        let rate = 48_000.0
        let s = try shape(.fiveOne)
        var (stages, _) = try denoiserStages(rate: rate, quality: N60DenoiserQualityQuality)
        stages.denoiserLatencyFrames = 1_500
        let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, stages: stages), shape: s, eqMode: .linked)
        let spec = try config(rate: rate, layout: .fiveOne, dsp: dsp).makeSpec()
        let lfe = try XCTUnwrap(s.lfeLane)
        let out = try renderImpulse(spec, lanes: 6, only: lfe, frames: 2_048)
        XCTAssertEqual(peakIndex(out[lfe]), 1_500)
    }

    func testBinauralDenoiserLatencyShiftsUncoveredLanesByTheReportedLatency() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            let (stages, reported) = try denoiserStages(rate: rate, quality: N60DenoiserQualityQuality)
            let lfe = try XCTUnwrap(s.lfeLane)
            func binaural(_ dsp: UnifiedGraphProgramDSP?) throws -> UnifiedGraphSpec {
                var profile = HeadphoneDeviceProfileConfiguration()
                profile.programLayout = layout
                let result = UnifiedGraphTranslator.binauralSpec(
                    asset: BinauralProfileAsset.validationStereo(sampleRate: rate), layout: layout, profile: profile,
                    outputChannels: 2, sampleRate: rate, headTracking: false, programDSP: dsp)
                guard case .success(let spec) = result else { throw XCTSkip("binaural spec rejected at \(rate)") }
                return spec
            }
            let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, stages: stages), shape: s, eqMode: .linked,
                                             virtualSpeakers: true)
            let plainSpec = try binaural(nil)
            let dspSpec = try binaural(dsp)
            let frames = Int(reported) / block * block + 3 * block
            let plain = try renderImpulse(plainSpec, lanes: 6, only: lfe, frames: frames)
            let aligned = try renderImpulse(dspSpec, lanes: 6, only: lfe, frames: frames)
            XCTAssertEqual(peakIndex(aligned[0]) - peakIndex(plain[0]), Int(reported), "left ear at \(rate)")
            XCTAssertEqual(peakIndex(aligned[1]) - peakIndex(plain[1]), Int(reported), "right ear at \(rate)")
        }
    }

    func testBinauralUserProtectionNeverReplacesTheSafetyLimiter() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            let protection = UnifiedGraphProtection(
                limiterEnabled: true, ceilingDB: -12, attackMilliseconds: 1, releaseMilliseconds: 50,
                lookAheadMilliseconds: 2, truePeakGuard: true, oversampling: 2)
            var st = stereo(rate: rate)
            st.protection = protection
            let dsp = UnifiedGraphProgramDSP(stereo: st, shape: s, eqMode: .linked, virtualSpeakers: true)
            XCTAssertNotNil(dsp.protection)
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.programLayout = layout
            let build = { (dsp: UnifiedGraphProgramDSP?) -> UnifiedGraphSpec? in
                guard case .success(let spec) = UnifiedGraphTranslator.binauralSpec(
                    asset: BinauralProfileAsset.validationStereo(sampleRate: rate), layout: layout, profile: profile,
                    outputChannels: 2, sampleRate: rate, headTracking: false, programDSP: dsp) else { return nil }
                return spec
            }
            let plain = try XCTUnwrap(build(nil))
            let spec = try XCTUnwrap(build(dsp))
            let safetyBefore = try XCTUnwrap(plain.stages.first { $0.stageId == N60_LSTAGE_PROTECTION })
            let protections = spec.stages.filter { $0.kind == N60_STAGE_PROTECTION.rawValue }
            XCTAssertEqual(protections.count, 2, "user protection is an extra stage at \(rate)")
            XCTAssertEqual(protections.last?.stageId, N60_LSTAGE_PROTECTION, "the safety limiter runs last")
            XCTAssertEqual(protections.last?.params, safetyBefore.params, "safety parameters unchanged at \(rate)")
            XCTAssertEqual(protections.last?.laneMask, safetyBefore.laneMask)
            XCTAssertEqual(protections.first?.params, UnifiedGraphConfiguration.protectionParameters(protection))

            // A loud tone is held to the stricter user ceiling, and the safety ceiling (-1 dB) holds with the user's
            // protection off in the same graph shape.
            let host = try UnifiedGraphHost(spec: spec)
            var peak: Float = 0
            var position = 0
            let total = Int(rate * 0.4) / block * block
            while position < total {
                var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: 6)
                input[0] = (0..<block).map { 4 * Float(sin(2.0 * .pi * 1_000.0 * Double(position + $0) / rate)) }
                let out = try host.processOffline(input: input, frames: block)
                if position > total / 2 { peak = max(peak, out[0].map(abs).max() ?? 0, out[1].map(abs).max() ?? 0) }
                position += block
            }
            XCTAssertLessThanOrEqual(peak, Float(pow(10.0, -1.0 / 20.0)) * 1.02, "safety ceiling at \(rate)")
            XCTAssertGreaterThan(peak, 0.01)
        }
    }

    func testStageBudgetRejectionKeepsTheRunningGraph() throws {
        for rate in [44_100.0, 96_000.0, 384_000.0] {
            let layout = OutputProgramLayout.sevenOneFour
            let s = try shape(layout)
            let good = try config(rate: rate, layout: layout, dsp: nil).makeSpec()
            let reference = try UnifiedGraphHost(spec: good)
            let running = try UnifiedGraphHost(spec: good)
            let lanes = layout.roles.count

            func blockInput(_ index: Int) -> [[Float]] {
                (0..<lanes).map { lane in
                    (0..<block).map { 0.2 * Float(sin(2.0 * .pi * Double(220 + 40 * lane) * Double(index * block + $0) / rate)) }
                }
            }
            for index in 0..<4 {
                XCTAssertEqual(try running.processOffline(input: blockInput(index), frames: block),
                               try reference.processOffline(input: blockInput(index), frames: block))
            }

            // Program DSP that overflows the 256-stage budget is refused with the named reason.
            var padded = good
            for extra in 0..<(UnifiedGraphProgramDSP.maxStages - good.stages.count) {
                padded.stages.append(UnifiedGraphStageSpec(
                    kind: N60_STAGE_GAIN.rawValue, stageId: 4_000 + UInt32(extra), laneA: N60_LANE_ALL,
                    laneB: 0, laneMask: 0, capacityFrames: 0, params: [1]))
            }
            XCTAssertEqual(padded.stages.count, UnifiedGraphProgramDSP.maxStages)
            let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, left: [peak(3)], right: [peak(3)]),
                                             shape: s, eqMode: .linked)
            var candidate = padded
            XCTAssertThrowsError(try dsp.apply(to: &candidate)) {
                XCTAssertEqual($0 as? UnifiedGraphFallbackReason, .stageBudget, "rate \(rate)")
            }
            // A description over the core's budget that does reach the host is refused too, and nothing changes.
            var over = padded
            over.stages.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_GAIN.rawValue, stageId: 9_000, laneA: N60_LANE_ALL,
                laneB: 0, laneMask: 0, capacityFrames: 0, params: [1]))
            XCTAssertThrowsError(try running.apply(over), "rate \(rate)")
            for index in 4..<12 {
                XCTAssertEqual(try running.processOffline(input: blockInput(index), frames: block),
                               try reference.processOffline(input: blockInput(index), frames: block),
                               "the old graph keeps rendering bit-identically at \(rate), block \(index)")
            }
        }
    }
}
