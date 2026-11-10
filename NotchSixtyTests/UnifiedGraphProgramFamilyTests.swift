import XCTest
@testable import NotchSixty

/// E6 S12g4 (G8, G12, G17): the clean-up, stereo image, loudness, de-esser and multiband stages follow the stereo
/// settings onto N-channel and Virtual Speakers sessions instead of being dropped. Real graphs, real blocks, eight rates.
@MainActor
final class UnifiedGraphProgramFamilyTests: XCTestCase {
    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_414, uid: "family-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "family-out")
        return engine
    }

    private func stereoStages(_ engine: AudioIOEngine, rate: Double) throws -> UnifiedGraphConfiguration {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        return try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
    }

    private func render(
        _ stereo: UnifiedGraphConfiguration, layout: OutputProgramLayout, rate: Double, input: [[Float]]
    ) throws -> (UnifiedGraphSpec, [[Float]]) {
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
        let dsp = UnifiedGraphProgramDSP(stereo: stereo, shape: shape, eqMode: .linked)
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(
            sampleRate: rate, programChannels: layout.roles.count, subwoofers: [])
        configuration.orderPolicy = .canonical
        configuration.programDSP = dsp
        let spec = try configuration.makeSpec()
        let host = try UnifiedGraphHost(spec: spec)
        var out = [[Float]](repeating: [], count: input.count)
        var position = 0
        while position < input[0].count {
            let count = min(512, input[0].count - position)
            let chunk = input.map { Array($0[position..<position + count]) }
            let result = try host.processOffline(input: chunk, frames: count)
            for lane in 0..<input.count { out[lane] += result[lane] }
            position += count
        }
        return (spec, out)
    }

    func testCleanupRunsOnEveryPairAndTrueMonoOnTheFrontPairAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            var dynamics = DynamicsConfiguration()
            dynamics.dcOffsetFilter.enabled = true
            dynamics.stereoMode = .trueMono
            let engine = try engine(rate: rate)
            try engine.replaceDynamicsConfiguration(dynamics)
            let stereo = try stereoStages(engine, rate: rate)
            XCTAssertNotNil(stereo.stereoStages.cleanup)
            XCTAssertNotNil(stereo.stereoStages.image)
            let layout = OutputProgramLayout.fiveOne
            let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
            let frames = Int(rate * 1.2)
            // DC plus a tone on every lane; the front left lane alone carries the tone for the true-mono check.
            var input = [[Float]](repeating: [Float](repeating: 0.2, count: frames), count: layout.roles.count)
            let fl = try XCTUnwrap(shape.frontLeft), fr = try XCTUnwrap(shape.frontRight)
            input[fl] = (0..<frames).map { 0.2 + 0.4 * Float(sin(2 * Double.pi * 1_000 * Double($0) / rate)) }
            input[fr] = [Float](repeating: 0.2, count: frames)
            let (spec, out) = try render(stereo, layout: layout, rate: rate, input: input)
            XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_CLEANUP.rawValue }.count,
                           shape.pairs.count + (layout.roles.count - 2 * shape.pairs.count),
                           "one per pair plus one single-lane instance for each unpaired lane (centre, LFE) at \(rate)")
            XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_IMAGE.rawValue }.count, 1)
            let tailStart = frames * 3 / 4
            for pair in shape.pairs {
                for lane in [pair.a, pair.b] where lane != fl && lane != fr {
                    let mean = out[lane][tailStart...].reduce(0.0) { $0 + Double($1) } / Double(frames - tailStart)
                    XCTAssertEqual(mean, 0, accuracy: 0.01, "DC removed on lane \(lane) at \(rate)")
                }
            }
            for index in tailStart..<frames {
                XCTAssertEqual(out[fl][index], out[fr][index], accuracy: 1e-3, "true mono: front L equals R at \(rate)")
            }
        }
    }

    func testImageStagesNeedAFrontPairAndNameTheReason() throws {
        let engine = try engine(rate: 48_000)
        var dynamics = DynamicsConfiguration()
        dynamics.stereoMode = .trueMono
        try engine.replaceDynamicsConfiguration(dynamics)
        let stereo = try stereoStages(engine, rate: 48_000)
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontCenter]))
        let dsp = UnifiedGraphProgramDSP(stereo: stereo, shape: shape, eqMode: .linked)
        var spec = try UnifiedGraphConfiguration(
            sampleRate: 48_000, lanes: [UnifiedGraphLane()]).makeSpec()
        XCTAssertThrowsError(try dsp.apply(to: &spec)) {
            XCTAssertEqual($0 as? UnifiedGraphFallbackReason, .noFrontPair)
        }
    }
    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    private func tone(_ rate: Double, _ hz: Double, _ frames: Int) -> [Float] {
        (0..<frames).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    /// G44: loudness and multiband reach the front pair of a 5.1 session and leave the rear pair alone, at every rate.
    func testLoudnessAndMultibandActOnTheFrontPairOnlyAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let layout = OutputProgramLayout.fiveOne
            let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
            let fl = try XCTUnwrap(shape.frontLeft), fr = try XCTUnwrap(shape.frontRight)
            let frames = Int(rate * 0.6)
            let input = (0..<layout.roles.count).map { _ in tone(rate, 1_000, frames) }
            let tail = frames / 2

            let plain = try engine(rate: rate)
            let (_, base) = try render(try stereoStages(plain, rate: rate), layout: layout, rate: rate, input: input)

            var dynamics = DynamicsConfiguration()
            dynamics.multibandCompressor.enabled = true
            dynamics.multibandCompressor.midThresholdDB = -40
            dynamics.multibandCompressor.midRatio = 10
            dynamics.multibandCompressor.lowThresholdDB = -40
            dynamics.multibandCompressor.lowRatio = 10
            dynamics.multibandCompressor.highThresholdDB = -40
            dynamics.multibandCompressor.highRatio = 10
            dynamics.loudnessMatch.enabled = true
            let loud = try engine(rate: rate)
            try loud.replaceDynamicsConfiguration(dynamics)
            let stereo = try stereoStages(loud, rate: rate)
            XCTAssertNotNil(stereo.stereoStages.multiband)
            XCTAssertNotNil(stereo.stereoStages.loudness)
            let (spec, out) = try render(stereo, layout: layout, rate: rate, input: input)
            XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_MULTIBAND.rawValue }.count, 1)
            XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_LOUDNESS.rawValue }.count, 1)
            XCTAssertTrue(out.allSatisfy { $0.allSatisfy(\.isFinite) }, "finite at \(rate)")
            let frontBase = rms(base[fl][tail...]), frontNow = rms(out[fl][tail...])
            XCTAssertLessThan(frontNow, frontBase * 0.9, "multiband compresses the front pair at \(rate)")
            XCTAssertEqual(rms(out[fl][tail...]), rms(out[fr][tail...]), accuracy: frontNow * 0.02, "front pair stays matched at \(rate)")
            for lane in 0..<layout.roles.count where lane != fl && lane != fr {
                XCTAssertEqual(rms(out[lane][tail...]), rms(base[lane][tail...]), accuracy: rms(base[lane][tail...]) * 0.01,
                               "lane \(lane) is not touched at \(rate)")
            }
        }
    }

    /// G42: every program layout, with every stage family on, builds into a real graph at every rate (no legacy fallback).
    func testEveryLayoutWithEveryStageFamilyAttachesTheGraphAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            var dynamics = DynamicsConfiguration()
            dynamics.dcOffsetFilter.enabled = true
            dynamics.stereoMode = .trueMono
            dynamics.multibandCompressor.enabled = true
            dynamics.loudnessMatch.enabled = true
            let engine = try engine(rate: rate)
            try engine.replaceDynamicsConfiguration(dynamics)
            let stereo = try stereoStages(engine, rate: rate)
            for layout in OutputProgramLayout.allCases where layout.roles.count > 2 {
                let frames = 2_048
                let input = (0..<layout.roles.count).map { _ in tone(rate, 997, frames) }
                let (spec, out) = try render(stereo, layout: layout, rate: rate, input: input)
                XCTAssertGreaterThan(spec.stages.filter { $0.kind == N60_STAGE_CLEANUP.rawValue }.count, 0, "\(layout) at \(rate)")
                XCTAssertTrue(out.allSatisfy { $0.allSatisfy(\.isFinite) }, "\(layout) finite at \(rate)")
            }
        }
    }

    /// G41: an optimizer FIR composes with a program FIR; every lane lands on the summed latency.
    func testOptimizerFIRComposesWithProgramFIRAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let layout = OutputProgramLayout.fiveOne
            let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
            var stereo = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            stereo.stereoStages.programFIR = UnifiedGraphFIRProgram(
                generation: 1, left: [0, 0, 1, 0, 0], right: nil, declaredLatencyFrames: 2)
            let dsp = UnifiedGraphProgramDSP(stereo: stereo, shape: shape, eqMode: .linked)
            XCTAssertTrue(dsp.hasProgramLatency)
            var configuration = UnifiedGraphTranslator.multichannelConfiguration(
                sampleRate: rate, programChannels: layout.roles.count, subwoofers: [])
            configuration.orderPolicy = .canonical
            configuration.programDSP = dsp
            configuration.optimizerFIR = UnifiedGraphOptimizerFIR(
                declaredLatencyFrames: 2, taps: [0: [0, 0, 1, 0, 0], 1: [0, 0, 1, 0, 0]])
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            var input = [[Float]](repeating: [Float](repeating: 0, count: 2_048), count: layout.roles.count)
            for lane in 0..<layout.roles.count { input[lane][0] = 0.5 }
            let out = try host.processOffline(input: input, frames: 2_048)
            let peaks = out.map { lane in lane.indices.max { abs(lane[$0]) < abs(lane[$1]) } ?? -1 }
            XCTAssertEqual(Set(peaks).count, 1, "every lane lands on the same sample at \(rate): \(peaks)")
            XCTAssertEqual(peaks[0], 2 * (256 + 2), "program plus optimizer latency at \(rate)")
        }
    }

    // MARK: E6 S12h part 3 (G50, G51): the delta audition on N-channel sessions

    private func fiveOnePlan(subs: Int) -> LiveNChannelOutputRoutePlan {
        LiveNChannelOutputRoutePlan(
            programLayout: .fiveOne,
            orderedDeviceUIDs: ["interface"],
            referenceDeviceUID: "interface",
            physicalChannelCount: UInt32(6 + subs),
            programPhysicalChannels: [5, 4, 3, N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED, 1, 0],
            subwooferPhysicalChannels: (0..<subs).map { UInt32(6 + $0) },
            subwooferCount: UInt32(subs),
            bassManagementEnabled: subs > 0,
            speakerCalibrations: [:],
            subwooferCalibrations: [PhysicalSubwooferCalibration?](repeating: nil, count: subs)
        )
    }

    private func block(_ lanes: Int, _ frames: Int, offset: Int) -> [[Float]] {
        (0..<lanes).map { lane in
            (0..<frames).map { i in
                let n = Double(offset + i)
                return Float(0.1 * sin(0.05 * n * Double(lane + 1)) + 0.03 * sin(0.9 * n + Double(lane)))
            }
        }
    }

    private func renderAll(_ host: UnifiedGraphHost, input: [[Float]]) throws -> [[Float]] {
        var out = [[Float]](repeating: [], count: input.count)
        var position = 0
        while position < input[0].count {
            let count = min(512, input[0].count - position)
            let chunk = input.map { Array($0[position..<position + count]) }
            let result = try host.processOffline(input: chunk, frames: count)
            for lane in 0..<input.count { out[lane] += result[lane] }
            position += count
        }
        return out
    }

    /// Program EQ plus a lane delay on a 5.1 session with bass management and two subs. The delta is processed minus the
    /// lane-aligned input on the six program lanes; the sub lanes are outside the delta and render as without it.
    func testFiveOneDeltaAuditionWithSubwoofersIsProcessedMinusAlignedInputAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            try engine.addEQBand(EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1))
            let stereo = try stereoStages(engine, rate: rate)
            let plan = fiveOnePlan(subs: 2)
            let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: plan.programLayout.roles))
            var bass = BassManagementConfiguration(enabled: true)
            bass.frequencyHz = 80
            func host(delta: Bool) throws -> UnifiedGraphHost {
                var dsp = UnifiedGraphProgramDSP(stereo: stereo, shape: shape, eqMode: .linked)
                dsp.laneDelayFrames = [2: 37]
                dsp.subLaneCount = 2
                dsp.deltaAudition = delta
                XCTAssertFalse(dsp.isNeutral)
                var configuration = try UnifiedGraphTranslator.nChannelEligibility(
                    routePlan: plan, sampleRate: rate, gainConfiguration: DSPGainConfiguration(),
                    bassManagementConfiguration: bass, programDSP: dsp).get()
                XCTAssertEqual(configuration.deltaAudition, delta)
                return try UnifiedGraphHost(spec: try configuration.makeSpec())
            }
            let plain = try host(delta: false)
            let audition = try host(delta: true)
            XCTAssertEqual(audition.latencyFrames, plain.latencyFrames, "the pair adds no latency at \(rate)")
            let lanes = Int(plain.spec.inputChannels)
            var input = block(6, 6_144, offset: 0)
            input += [[Float]](repeating: [Float](repeating: 0, count: 6_144), count: lanes - 6)
            let expected = try renderAll(plain, input: input)
            let actual = try renderAll(audition, input: input)
            let delays = [0, 0, 37, 0, 0, 0]
            var worst: Float = 0
            for lane in 0..<6 {
                for n in 0..<input[lane].count {
                    let aligned: Float = n >= delays[lane] ? input[lane][n - delays[lane]] : 0
                    worst = max(worst, abs(actual[lane][n] - (expected[lane][n] - aligned)))
                }
            }
            XCTAssertLessThan(worst, 1e-5, "program lane delta at \(rate)")
            for lane in 6..<lanes {
                let same = zip(actual[lane], expected[lane]).map { abs($0 - $1) }.max() ?? 1
                XCTAssertEqual(same, 0, accuracy: 1e-6, "sub lane \(lane) is outside the delta at \(rate)")
                XCTAssertGreaterThan(expected[lane].map { abs($0) }.max() ?? 0, 1e-4, "sub lane \(lane) carries bass at \(rate)")
            }
        }
    }

    /// The engine builds the mask delta for a speaker session and refuses it for Virtual Speakers, by name.
    func testEngineBuildsTheDeltaForSpeakersAndRefusesItForVirtualSpeakers() throws {
        let rate = 48_000.0
        let engine = try engine(rate: rate)
        engine.unifiedGraphEnabled = true
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: OutputProgramLayout.fiveOne.roles))
        var inputs = engine.currentLiveGraphInputs
        inputs.playback.auditionMode = .delta
        let dsp = try XCTUnwrap(engine.makeUnifiedProgramDSP(
            sampleRate: rate, shape: shape, virtualSpeakers: false, inputs: inputs))
        XCTAssertTrue(dsp.deltaAudition)
        XCTAssertFalse(dsp.isNeutral, "a delta alone is program DSP")
        XCTAssertThrowsError(try engine.makeUnifiedProgramDSP(
            sampleRate: rate, shape: shape, virtualSpeakers: true, inputs: inputs)) { error in
            guard case LiveNChannelTransportError.unsupportedActiveDSP(let what) = error else {
                return XCTFail("expected a named refusal, got \(error)")
            }
            XCTAssertTrue(what.contains("Virtual Speakers"))
        }
        inputs.playback.auditionMode = .processed
        XCTAssertEqual(try engine.makeUnifiedProgramDSP(sampleRate: rate, shape: shape, virtualSpeakers: false, inputs: inputs)?.deltaAudition, false)
    }

    // MARK: E8 S11b: the N-channel stereo-plus-sub session honours the stereo crossover

    private func stereoSubPlan(
        subs: Int = 1, calibrations: [PhysicalSubwooferCalibration?]? = nil
    ) -> LiveNChannelOutputRoutePlan {
        LiveNChannelOutputRoutePlan(
            programLayout: .stereo,
            orderedDeviceUIDs: ["interface"],
            referenceDeviceUID: "interface",
            physicalChannelCount: UInt32(2 + subs),
            programPhysicalChannels: [0, 1],
            subwooferPhysicalChannels: (0..<subs).map { UInt32(2 + $0) },
            subwooferCount: UInt32(subs),
            bassManagementEnabled: true,
            speakerCalibrations: [:],
            subwooferCalibrations: calibrations ?? [PhysicalSubwooferCalibration?](repeating: nil, count: subs)
        )
    }

    private func crossoverBass(
        hz: Double = 90, steep: Bool = false, mode: CrossoverMonitorMode = .recombined, gainDB: Double = 0,
        invert: Bool = false, align: Bool = false
    ) -> BassManagementConfiguration {
        var bass = BassManagementConfiguration(enabled: true)
        bass.frequencyHz = hz
        bass.topology = steep ? .linkwitzRiley48 : .linkwitzRiley24
        bass.monitorMode = mode
        bass.subGainDB = gainDB
        bass.subPolarityInverted = invert
        bass.subPhaseAlignmentEnabled = align
        bass.subPhaseAlignmentFrequencyHz = 70
        bass.subPhaseAlignmentQ = 0.9
        return bass
    }

    /// The session's graph the way the engine builds it: program DSP with the fold, then `nChannelEligibility`.
    private func foldedSession(
        _ engine: AudioIOEngine, rate: Double, bass: BassManagementConfiguration, subs: Int = 1,
        audition: AuditionMode = .processed
    ) throws -> UnifiedGraphConfiguration {
        engine.unifiedGraphEnabled = true
        var inputs = engine.currentLiveGraphInputs
        inputs.bass = bass
        inputs.playback.auditionMode = audition
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: OutputProgramLayout.stereo.roles))
        let program = try engine.makeUnifiedProgramDSP(
            sampleRate: rate, shape: shape, virtualSpeakers: false, subwooferCount: subs, foldStereoCrossover: true,
            inputs: inputs)
        return try UnifiedGraphTranslator.nChannelEligibility(
            routePlan: stereoSubPlan(subs: subs), sampleRate: rate, gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: bass, programDSP: program).get()
    }

    /// The stand-alone stereo crossover (no sub lanes) for the same settings, the reference the fold must match.
    private func standaloneCrossover(_ bass: BassManagementConfiguration, rate: Double) throws -> UnifiedGraphConfiguration {
        var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
        XCTAssertTrue(N60DSPGraphSnapshotSetCrossover(
            &snapshot, bass.frequencyHz, bass.topology.cType, bass.monitorMode.cType,
            Float(DSPGainConfiguration.linearGain(forDB: bass.subGainDB)), bass.subPolarityInverted, true))
        if bass.subPhaseAlignmentEnabled {
            XCTAssertTrue(N60DSPGraphSnapshotSetSubPhaseAlignment(
                &snapshot, bass.subPhaseAlignmentFrequencyHz, bass.subPhaseAlignmentQ, true))
        }
        return try UnifiedGraphTranslator.stereoEligibility(snapshot: &snapshot, sampleRate: rate).get()
    }

    private func crossoverTone(_ rate: Double, frames: Int? = nil) -> [Float] {
        (0..<(frames ?? Int(rate * 0.5))).map { i in
            let t = Double(i) / rate
            return Float(0.1 * sin(2 * .pi * 35 * t) + 0.1 * sin(2 * .pi * 80 * t) + 0.1 * sin(2 * .pi * 180 * t)
                         + 0.1 * sin(2 * .pi * 1_300 * t))
        }
    }

    private func renderMono(_ configuration: UnifiedGraphConfiguration, tone: [Float], subs: Int) throws -> [[Float]] {
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        let silence = [Float](repeating: 0, count: tone.count)
        return try renderAll(host, input: [tone, tone] + [[Float]](repeating: silence, count: subs))
    }

    private func settledDifference(_ a: [Float], _ b: [Float]) -> Float {
        var worst: Float = 0
        for i in a.count / 2..<a.count { worst = max(worst, abs(a[i] - b[i])) }
        return worst
    }

    /// Fold parity per filter family and the three settings the session used to ignore: phase alignment, sub gain and
    /// polarity, and the monitor modes. One split, front plus sub equal to the stand-alone stereo crossover.
    func testFoldedCrossoverMatchesTheStandaloneCrossoverForEachFamilyAndMode() throws {
        let cases: [(String, BassManagementConfiguration)] = [
            ("LR24", crossoverBass()),
            ("LR48", crossoverBass(steep: true)),
            ("LR24 aligned, trimmed, inverted", crossoverBass(hz: 110, gainDB: -6, invert: true, align: true)),
            ("LR48 aligned", crossoverBass(hz: 60, steep: true, align: true)),
            ("mains only", crossoverBass(mode: .mainsOnly)),
            ("sub only", crossoverBass(steep: true, mode: .subOnly)),
        ]
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            let tone = crossoverTone(rate)
            let half = tone.count / 2
            for (name, bass) in cases {
                let configuration = try foldedSession(engine, rate: rate, bass: bass)
                let spec = try configuration.makeSpec()
                XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_BASS_MGMT.rawValue }.count, 1, "\(name) one split")
                XCTAssertFalse(spec.stages.contains { $0.kind == N60_STAGE_STEREO_CROSSOVER.rawValue }, "\(name) at \(rate)")
                let folded = try renderMono(configuration, tone: tone, subs: 1)
                let reference = try renderMono(try standaloneCrossover(bass, rate: rate), tone: tone, subs: 0)
                switch bass.monitorMode {
                case .recombined:
                    let sum = zip(folded[0], folded[2]).map { $0 + $1 }
                    XCTAssertLessThan(settledDifference(sum, reference[0]), 3e-4, "\(name) front + sub at \(rate)")
                    let right = zip(folded[1], folded[2]).map { $0 + $1 }
                    XCTAssertLessThan(settledDifference(right, reference[1]), 3e-4, "\(name) right + sub at \(rate)")
                case .mainsOnly:
                    XCTAssertLessThan(folded[2][half...].map { abs($0) }.max() ?? 1, 1e-6, "\(name) sub muted at \(rate)")
                    XCTAssertLessThan(settledDifference(folded[0], reference[0]), 3e-4, "\(name) mains at \(rate)")
                case .subOnly:
                    XCTAssertLessThan(folded[0][half...].map { abs($0) }.max() ?? 1, 1e-6, "\(name) mains muted at \(rate)")
                    XCTAssertLessThan(settledDifference(folded[2], reference[0]), 3e-4, "\(name) sub at \(rate)")
                }
            }
        }
    }

    /// The route plan's per-sub calibration still adds to the crossover's sub gain and polarity.
    func testFoldedCrossoverKeepsTheRoutePlanSubCalibration() throws {
        let rate = 48_000.0
        let engine = try engine(rate: rate)
        let plan = stereoSubPlan(subs: 2, calibrations: [
            PhysicalSubwooferCalibration(gainDB: -3, delayMilliseconds: 2, polarityInverted: true, eqBands: []),
            nil,
        ])
        engine.unifiedGraphEnabled = true
        var inputs = engine.currentLiveGraphInputs
        inputs.bass = crossoverBass(gainDB: -6, invert: true, align: true)
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: OutputProgramLayout.stereo.roles))
        let program = try engine.makeUnifiedProgramDSP(
            sampleRate: rate, shape: shape, virtualSpeakers: false, subwooferCount: 2, foldStereoCrossover: true,
            inputs: inputs)
        let configuration = try UnifiedGraphTranslator.nChannelEligibility(
            routePlan: plan, sampleRate: rate, gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: inputs.bass, programDSP: program).get()
        let subs = try XCTUnwrap(configuration.bassManagement?.subwoofers)
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs[0].gainDB, -9, accuracy: 0.01)
        XCTAssertFalse(subs[0].polarityInverted, "crossover inversion and calibration inversion cancel")
        XCTAssertEqual(subs[0].delayMilliseconds, 2)
        XCTAssertEqual(subs[1].gainDB, -6, accuracy: 0.01)
        XCTAssertTrue(subs[1].polarityInverted)
        XCTAssertEqual(subs[0].eq.count, 1, "the phase-alignment all-pass heads each sub's EQ")
    }

    /// Anything but stereo plus subs does not fold: the program DSP carries no bass and the route plan's own split stands.
    func testOtherLayoutsAndRoutesDoNotFold() throws {
        let rate = 48_000.0
        let engine = try engine(rate: rate)
        engine.unifiedGraphEnabled = true
        var inputs = engine.currentLiveGraphInputs
        inputs.bass = crossoverBass(mode: .mainsOnly)
        let fiveOne = try XCTUnwrap(UnifiedGraphLayoutShape(roles: OutputProgramLayout.fiveOne.roles))
        let program = try engine.makeUnifiedProgramDSP(
            sampleRate: rate, shape: fiveOne, virtualSpeakers: false, subwooferCount: 1, foldStereoCrossover: true,
            inputs: inputs)
        XCTAssertNil(program?.foldedBass)
        let stereo = try XCTUnwrap(UnifiedGraphLayoutShape(roles: OutputProgramLayout.stereo.roles))
        XCTAssertNil(try engine.makeUnifiedProgramDSP(
            sampleRate: rate, shape: stereo, virtualSpeakers: false, subwooferCount: 1, foldStereoCrossover: false,
            inputs: inputs)?.foldedBass, "a routed session passes false")
        XCTAssertNil(try engine.makeUnifiedProgramDSP(
            sampleRate: rate, shape: stereo, virtualSpeakers: false, subwooferCount: 0, foldStereoCrossover: true,
            inputs: inputs)?.foldedBass, "no subs, no fold")
    }

    /// Delta audition with the mains-only mute: the delta is processed minus input on the program lanes, the mute still
    /// silences the sub lane, and the two stages coexist in one spec.
    func testDeltaAuditionCombinesWithTheMonitorMute() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            try engine.addEQBand(EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1))
            let bass = crossoverBass(mode: .mainsOnly)
            let plain = try foldedSession(engine, rate: rate, bass: bass)
            let delta = try foldedSession(engine, rate: rate, bass: bass, audition: .delta)
            XCTAssertTrue(delta.deltaAudition)
            XCTAssertNotEqual(delta.mutedLanes, 0)
            let tone = crossoverTone(rate)
            let expected = try renderMono(plain, tone: tone, subs: 1)
            let actual = try renderMono(delta, tone: tone, subs: 1)
            XCTAssertLessThan(actual[2][(tone.count / 2)...].map { abs($0) }.max() ?? 1, 1e-6, "sub muted at \(rate)")
            var worst: Float = 0
            for n in tone.count / 2..<tone.count { worst = max(worst, abs(actual[0][n] - (expected[0][n] - tone[n]))) }
            XCTAssertLessThan(worst, 1e-4, "delta = processed - input on the mains at \(rate)")
        }
    }

    /// A live crossover edit (frequency, gain, family) crosses the host's fade: no click on either lane.
    func testFoldedCrossoverLiveEditIsClickFree() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            let block = 512
            let first = try foldedSession(engine, rate: rate, bass: crossoverBass(hz: 80)).makeSpec()
            let edited = try foldedSession(engine, rate: rate, bass: crossoverBass(hz: 110, steep: true, gainDB: -3)).makeSpec()
            let host = try UnifiedGraphHost(spec: first)
            let steadyBlocks = Int(rate * 0.4) / block
            var lanes = [[Float]](repeating: [], count: 3)
            var position = 0
            for step in 0..<(steadyBlocks * 3) {
                if step == steadyBlocks { _ = try host.apply(edited) }
                let chunk = (0..<block).map { Float(0.4 * sin(2 * .pi * 60 * Double(position + $0) / rate)) }
                let out = try host.processOffline(
                    input: [chunk, chunk, [Float](repeating: 0, count: block)], frames: block)
                for lane in 0..<3 { lanes[lane] += out[lane] }
                position += block
            }
            for lane in [0, 2] {
                let x = lanes[lane]
                func worstStep(_ range: Range<Int>) -> Float {
                    var worst: Float = 0
                    for i in range.lowerBound + 1..<range.upperBound { worst = max(worst, abs(x[i] - x[i - 1])) }
                    return worst
                }
                let steady = max(worstStep(block * (steadyBlocks / 2)..<block * steadyBlocks),
                                 worstStep(block * steadyBlocks * 2..<x.count))
                let edit = worstStep(block * steadyBlocks..<block * steadyBlocks * 2)
                XCTAssertLessThan(edit, steady * 1.6 + 1e-4, "lane \(lane) click at \(rate)")
            }
        }
    }
}
