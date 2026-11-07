import XCTest
@testable import NotchSixty

/// E26 S6a: multi-bus plan from the splitter render, per-output leakage passes, band delay and level re-verified on
/// the render, and the ANC stages with the sub lane as an actuator in the unified graph configuration. Eight rates.
/// Bench (E22): a 2.1 interface with the sub on output 3.
final class SubActuatorMultibusTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func bass(_ hz: Double = 80) -> BassManagementConfiguration {
        var c = BassManagementConfiguration()
        c.enabled = true
        c.frequencyHz = hz
        c.physicalOutputMode = .mainsSub
        return c
    }

    /// A 20-500 Hz log sweep followed by silence for the splitter's tail.
    private func sweep(rate: Double, seconds: Double = 0.5, tail: Double = 0.3) -> [Float] {
        // Wider than the analysed 20-500 Hz so the edge bands are fully excited.
        let n = Int(seconds * rate), total = n + Int(tail * rate)
        let f0 = 16.0, f1 = 640.0, k = log(f1 / f0)
        var x = [Float](repeating: 0, count: total)
        for i in 0..<n {
            let t = Double(i) / rate
            let phase = 2 * Double.pi * f0 * seconds / k * (exp(t / seconds * k) - 1)
            let fade = min(1, Double(i) / (0.01 * rate), Double(n - i) / (0.01 * rate))
            x[i] = Float(0.5 * fade * sin(phase))
        }
        return x
    }

    func testOutputMapRules() throws {
        let map = SubActuatorOutputMap(leftOutput: 0, rightOutput: 1, subOutput: 2)
        XCTAssertNoThrow(try map.validate(outputChannelCount: 3))
        XCTAssertThrowsError(try map.validate(outputChannelCount: 2)) {
            XCTAssertEqual($0 as? SubActuatorOutputMap.MapError, .outputUnavailable(2, available: 2))
        }
        XCTAssertThrowsError(try SubActuatorOutputMap(leftOutput: 0, rightOutput: 1, subOutput: 1)
            .validate(outputChannelCount: 8)) {
            XCTAssertEqual($0 as? SubActuatorOutputMap.MapError, .outputsClash)
        }
    }

    func testPlanPlacesMainsAndSubOnTheirOutputsAtEveryRate() throws {
        let map = SubActuatorOutputMap(leftOutput: 0, rightOutput: 1, subOutput: 2)
        for rate in rates {
            let dry = sweep(rate: rate)
            let rendered = try ThroughFeedSplitterRenderer.render(dry, feed: .left, bass: bass(), sampleRate: rate)
            let plan = try SubActuatorMultibusSweepPlan.make(rendered: rendered, map: map, outputChannelCount: 3)
            XCTAssertEqual(plan.primary.role, .leftMain, "rate \(rate)")
            XCTAssertEqual(plan.primary.outputChannel, 0)
            XCTAssertEqual(plan.lanes.map(\.role), [.sub], "the right main is silent for a left feed (\(rate))")
            XCTAssertEqual(plan.lanes.first?.outputChannel, 2)
            XCTAssertEqual(plan.primary.samples.count, dry.count)
            let programs = plan.laneProgramsForTransport(leadInFrames: 4_800)
            XCTAssertEqual(programs.map(\.outputChannelIndex), [2])
            XCTAssertEqual(programs.map(\.startFrame), [4_800], "lanes start with the primary sweep, after the lead-in")
            XCTAssertEqual(plan.leakagePasses.map(\.outputChannel), [0, 2], "one leakage sweep per live output")
            // The sub carries the bass the mains no longer do: its energy sits below the crossover.
            let subPeak = plan.lanes[0].samples.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(subPeak, 0.05, "rate \(rate)")
            // Mains plus sub sum to the combined render the secondary-path model uses.
            let sum = zip(plan.primary.samples, plan.lanes[0].samples).map { $0 + $1 }
            for n in stride(from: 0, to: sum.count, by: max(1, sum.count / 97)) {
                XCTAssertEqual(sum[n], rendered.combined[n], accuracy: 1e-5, "rate \(rate) frame \(n)")
            }
        }
    }

    func testRightFeedUsesTheRightMain() throws {
        let map = SubActuatorOutputMap(leftOutput: 0, rightOutput: 1, subOutput: 2)
        let rendered = try ThroughFeedSplitterRenderer.render(sweep(rate: 48_000), feed: .right, bass: bass(), sampleRate: 48_000)
        let plan = try SubActuatorMultibusSweepPlan.make(rendered: rendered, map: map, outputChannelCount: 3)
        XCTAssertEqual(plan.primary.role, .rightMain)
        XCTAssertEqual(plan.primary.outputChannel, 1)
    }

    func testBandDelayAndLevelHoldOnTheSplitterRenderAtEveryRate() throws {
        for rate in rates {
            let dry = SplitterVerificationSweep.samples(sampleRate: rate)
            let rendered = try ThroughFeedSplitterRenderer.render(dry, feed: .left, bass: bass(), sampleRate: rate)
            let impulse = try ThroughFeedSplitterRenderer.combinedImpulseResponse(
                feed: .left, bass: bass(), sampleRate: rate, seconds: 1.0)
            let bands = CombinedPathBandAnalyzer.analyze(impulseResponse: impulse, sampleRate: rate)
            let result = SplitterRenderVerifier.verify(
                dry: dry, rendered: rendered.combined, impulseBands: bands, sampleRate: rate)
            XCTAssertGreaterThan(result.bandsCompared, 6, "rate \(rate)")
            XCTAssertTrue(result.passes, "rate \(rate): gain error \(result.worstGainErrorDB) dB, delay error \(result.worstDelayErrorSeconds) s")
        }
    }

    func testVerifierRefusesAnAlteredRender() throws {
        let rate = 48_000.0
        let dry = SplitterVerificationSweep.samples(sampleRate: rate)
        let rendered = try ThroughFeedSplitterRenderer.render(dry, feed: .left, bass: bass(), sampleRate: rate)
        let impulse = try ThroughFeedSplitterRenderer.combinedImpulseResponse(feed: .left, bass: bass(), sampleRate: rate, seconds: 1.0)
        let bands = CombinedPathBandAnalyzer.analyze(impulseResponse: impulse, sampleRate: rate)
        let late = [Float](repeating: 0, count: 96) + rendered.combined.dropLast(96)  // 2 ms later
        XCTAssertFalse(SplitterRenderVerifier.verify(dry: dry, rendered: late, impulseBands: bands, sampleRate: rate).passes)
        let quiet = rendered.combined.map { $0 * 0.5 }  // 6 dB down
        XCTAssertFalse(SplitterRenderVerifier.verify(dry: dry, rendered: quiet, impulseBands: bands, sampleRate: rate).passes)
    }

    func testAncStagesPlaceAndAppendLanesAtEveryRate() throws {
        for rate in rates {
            var config = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            config.bassManagement = UnifiedGraphBassManagement(subwoofers: [UnifiedGraphSubwoofer()])
            let before = try config.makeSpec()
            XCTAssertFalse(before.stages.contains { $0.kind == N60_STAGE_ANC_INJECT.rawValue }, "off by default")
            config.ancActuators = UnifiedGraphAncActuators(
                actuators: [.init(targetLane: 0), .init(targetLane: 1), .init(targetLane: 2)], captureFrames: 4096)
            XCTAssertEqual(config.channelCount, 3 + 4, "3 speaker lanes + 3 sources + 1 error lane")
            let spec = try config.makeSpec()
            XCTAssertEqual(spec.inputChannels, 7)
            XCTAssertEqual(spec.outputChannels, 7)
            let injects = spec.stages.filter { $0.kind == N60_STAGE_ANC_INJECT.rawValue }
            XCTAssertEqual(injects.map(\.laneA), [0, 1, 2], "one inject per actuator lane, sub last")
            XCTAssertEqual(injects.map { $0.params[0] }, [3, 4, 5], "sources are the appended lanes")
            XCTAssertTrue(injects.allSatisfy { $0.params[1] == 0 }, "never authorised by default (\(rate))")
            // Rank order: guards, then injects, then capture, then the final stages.
            let kinds = spec.stages.map(\.kind)
            let lastGuard = try XCTUnwrap(kinds.lastIndex(of: N60_STAGE_ANC_GUARD.rawValue))
            let firstInject = try XCTUnwrap(kinds.firstIndex(of: N60_STAGE_ANC_INJECT.rawValue))
            let capture = try XCTUnwrap(kinds.firstIndex(of: N60_STAGE_ANC_CAPTURE.rawValue))
            let sanitise = try XCTUnwrap(kinds.firstIndex(of: N60_STAGE_FINAL_SANITISE.rawValue))
            XCTAssertLessThan(lastGuard, firstInject == lastGuard ? 0 : max(firstInject, lastGuard + 1))
            XCTAssertLessThan(firstInject, capture)
            XCTAssertLessThan(capture, sanitise)
            if let delay = kinds.lastIndex(of: N60_STAGE_DELAY.rawValue) { XCTAssertLessThan(delay, firstInject) }
            let mask = spec.stages[capture].laneMask
            XCTAssertEqual(mask, 0b1000111, "capture takes the three actuators and the error lane")
            config.ancActuators?.authorised = true
            let on = try config.makeSpec().stages.filter { $0.kind == N60_STAGE_ANC_INJECT.rawValue }
            XCTAssertTrue(on.allSatisfy { $0.params[1] == 1 })
        }
    }

    func testAncActuatorLaneRules() {
        var config = UnifiedGraphConfiguration(sampleRate: 48_000, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        config.bassManagement = UnifiedGraphBassManagement(subwoofers: [UnifiedGraphSubwoofer()])
        func rejects(_ a: UnifiedGraphAncActuators, _ note: String) {
            config.ancActuators = a
            XCTAssertThrowsError(try config.makeSpec(), note)
        }
        rejects(.init(actuators: [], captureFrames: 100), "no actuators")
        rejects(.init(actuators: [.init(targetLane: 1), .init(targetLane: 1)], captureFrames: 100), "duplicate target")
        rejects(.init(actuators: [.init(targetLane: 3)], captureFrames: 100), "target beyond the speaker lanes")
        rejects(.init(actuators: [.init(targetLane: -1)], captureFrames: 100), "negative lane")
        rejects(.init(actuators: [.init(targetLane: 0, gainDB: 3)], captureFrames: 100), "gain above 0 dB")
        rejects(.init(actuators: [.init(targetLane: 0)], captureFrames: 0), "no capture ring")
    }

    // MARK: E26 S7b2

    private func hostedConfig(rate: Double, userGain: Float = 1) -> UnifiedGraphConfiguration {
        var config = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        config.bassManagement = UnifiedGraphBassManagement(subwoofers: [UnifiedGraphSubwoofer()])
        config.ancActuators = UnifiedGraphAncActuators(
            actuators: [.init(targetLane: 0), .init(targetLane: 1), .init(targetLane: 2)], captureFrames: 4096,
            hostFed: true, userOutputGain: userGain)
        return config
    }

    func testHostFedClassAPlacesFeedAndMovesVolumeAheadOfInjectAtEveryRate() throws {
        for rate in rates {
            let spec = try hostedConfig(rate: rate, userGain: 0.25).makeSpec()
            let externals = spec.stages.filter { $0.kind == N60_STAGE_EXTERNAL.rawValue }
            XCTAssertEqual(externals.count, 1, "rate \(rate)")
            XCTAssertEqual(externals[0].laneMask, 0b111011, "programme lanes 0,1 and sources 3,4,5 (\(rate))")
            let kinds = spec.stages.map(\.kind)
            let external = try XCTUnwrap(kinds.firstIndex(of: N60_STAGE_EXTERNAL.rawValue))
            let bass = try XCTUnwrap(kinds.firstIndex(of: N60_STAGE_BASS_MGMT.rawValue))
            let inject = try XCTUnwrap(kinds.firstIndex(of: N60_STAGE_ANC_INJECT.rawValue))
            XCTAssertLessThan(external, bass, "the feed runs before bass management")
            let gains = spec.stages.enumerated().filter { $0.element.kind == N60_STAGE_OUTPUT_GAIN.rawValue }
            XCTAssertEqual(gains.map { $0.element.laneA }.sorted(), [0, 1, 2], "mains and the sub lane carry the volume")
            XCTAssertTrue(gains.allSatisfy { $0.element.params[0] == 0.25 })
            XCTAssertTrue(gains.allSatisfy { $0.offset < inject }, "volume sits ahead of ANC_INJECT")
            let guards = spec.stages.filter { $0.kind == N60_STAGE_ANC_GUARD.rawValue }
            XCTAssertTrue(guards.allSatisfy { $0.params[0] == -1 }, "no error input on the guards")
        }
    }

    func testHostFedOffLeavesSpecUnchangedAndRefusesASecondExternalStage() throws {
        var plain = UnifiedGraphConfiguration(sampleRate: 48_000, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        plain.bassManagement = UnifiedGraphBassManagement(subwoofers: [UnifiedGraphSubwoofer()])
        var withoutFeed = plain
        withoutFeed.ancActuators = UnifiedGraphAncActuators(
            actuators: [.init(targetLane: 0), .init(targetLane: 1), .init(targetLane: 2)], captureFrames: 4096)
        let spec = try withoutFeed.makeSpec()
        XCTAssertFalse(spec.stages.contains { $0.kind == N60_STAGE_EXTERNAL.rawValue })
        XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_OUTPUT_GAIN.rawValue }.count, 2, "no sub-lane gain")
        var wrong = hostedConfig(rate: 48_000)
        wrong.ancActuators?.actuators.removeLast()
        XCTAssertThrowsError(try wrong.makeSpec(), "host feed needs exactly three actuators")
        var bad = hostedConfig(rate: 48_000)
        bad.ancActuators?.userOutputGain = -1
        XCTAssertThrowsError(try bad.makeSpec())
    }

    /// G14: the feed's anti-noise lanes equal the tonal runtime rendered through `N60SpeakerBusRenderFeed`.
    func testFeedLanesMatchTheSpeakerBusRenderFeedAtEveryRate() throws {
        for rate in rates {
            let splitter = try bass().makeSpeakerBusSplitterSnapshot(sampleRate: rate)
            let fade = 0.05
            let feed = try XCTUnwrap(ProfileAncFeed(sampleRate: rate, splitter: splitter, peakLimit: 1, fadeInSeconds: fade))
            var tonal = N60ActiveQuietZoneSnapshotMakeBypassed()
            var tone = N60ActiveQuietZoneToneSnapshot()
            tone.frequencyHz = 60; tone.leftReal = 0.05; tone.rightReal = 0.05
            XCTAssertTrue(N60ActiveQuietZoneSnapshotSet(&tonal, &tone, 1, 64, rate, true))
            tonal.armGeneration = 1
            XCTAssertTrue(N60AncLaneFeedSetTonalSnapshot(feed.pointer, &tonal))
            N60AncLaneFeedArm(feed.pointer)
            N60AncLaneFeedRenewLease(feed.pointer, UInt64(rate * 600))

            let block = 480, blocks = max(2, Int(rate * 0.25) / block)
            let frames = block * blocks
            var lanes = [[Float]](repeating: [], count: 5)
            let inBufs = (0..<5).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
            let outBufs = (0..<5).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
            defer { inBufs.forEach { $0.deallocate() }; outBufs.forEach { $0.deallocate() } }
            var inPtrs: [UnsafePointer<Float>] = inBufs.map { UnsafePointer($0) }
            var outPtrs: [UnsafeMutablePointer<Float>] = outBufs
            for _ in 0..<blocks {
                for c in 0..<5 { inBufs[c].update(repeating: 0, count: block); outBufs[c].update(repeating: 0, count: block) }
                _ = N60AncLaneFeedProcess(UnsafeMutableRawPointer(feed.pointer), &inPtrs, &outPtrs, 5, UInt32(block))
                for c in 0..<5 { lanes[c] += UnsafeBufferPointer(start: outBufs[c], count: block) }
            }

            var runtime = N60ActiveQuietZoneRuntime()
            N60ActiveQuietZoneRuntimeReset(&runtime, rate)
            XCTAssertTrue(N60ActiveQuietZoneRuntimeSchedule(&runtime, &tonal, rate))
            var l = [Float](repeating: 0, count: frames), r = l
            let step = 1.0 / (fade * rate)
            var gain = 0.0
            for n in 0..<frames {
                N60ActiveQuietZoneRuntimeAccumulateProgramme(&runtime, 0, 0)
                var tl: Float = 0, tr: Float = 0
                N60ActiveQuietZoneRuntimeProcessFrame(&runtime, &tl, &tr)
                gain = min(1, gain + step)
                l[n] = max(-1, min(1, tl * Float(gain)))
                r[n] = max(-1, min(1, tr * Float(gain)))
            }
            func render(_ x: [Float], left: Bool) -> [Float] {
                var out = [Float](repeating: 0, count: frames * ThroughFeedSplitterRenderer.busCount)
                x.withUnsafeBufferPointer { i in
                    out.withUnsafeMutableBufferPointer { o in
                        XCTAssertTrue(N60SpeakerBusRenderFeed(
                            i.baseAddress!, UInt32(frames), left, splitter, N60SpeakerDriverProcessingSnapshot(), o.baseAddress!))
                    }
                }
                return out
            }
            let a = render(l, left: true), b = render(r, left: false)
            let bc = ThroughFeedSplitterRenderer.busCount
            func sum(_ n: Int, _ buses: [N60SpeakerOutputBus]) -> Float {
                buses.reduce(0) { $0 + a[n * bc + Int($1.rawValue)] + b[n * bc + Int($1.rawValue)] }
            }
            var maxErr: Float = 0, peak: Float = 0
            for n in 0..<frames {
                let left = a[n * bc + Int(N60SpeakerOutputBusLeftLow.rawValue)] + a[n * bc + Int(N60SpeakerOutputBusLeftMid.rawValue)]
                    + a[n * bc + Int(N60SpeakerOutputBusLeftHigh.rawValue)]
                    + b[n * bc + Int(N60SpeakerOutputBusLeftLow.rawValue)] + b[n * bc + Int(N60SpeakerOutputBusLeftMid.rawValue)]
                    + b[n * bc + Int(N60SpeakerOutputBusLeftHigh.rawValue)]
                maxErr = max(maxErr, abs(left - lanes[2][n]))
                maxErr = max(maxErr, abs(sum(n, [N60SpeakerOutputBusRightLow, N60SpeakerOutputBusRightMid, N60SpeakerOutputBusRightHigh]) - lanes[3][n]))
                maxErr = max(maxErr, abs(sum(n, [N60SpeakerOutputBusSubMono]) - lanes[4][n]))
                peak = max(peak, abs(lanes[2][n]), abs(lanes[4][n]))
            }
            XCTAssertGreaterThan(peak, 0.001, "anti-noise present (\(rate))")
            XCTAssertLessThan(maxErr, 1e-6, "feed vs N60SpeakerBusRenderFeed at \(rate)")
        }
    }
}
