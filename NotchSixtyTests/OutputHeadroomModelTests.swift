import XCTest
@testable import NotchSixty

/// E9 S7: the headroom assistant's model against real graphs. The model reads the published stage list; each case renders a
/// tone at the frequency the model names and checks the measured gain, at the eight standard rates.
final class OutputHeadroomModelTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func configuration(
        rate: Double, programLanes: Int = 2, gain: Float = 1, subs: Int = 0, ceilingDB: Double? = nil,
        policy: UnifiedGraphOutputProtection? = nil
    ) -> UnifiedGraphConfiguration {
        var lane = UnifiedGraphLane()
        lane.outputGain = gain
        var c = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane](repeating: lane, count: programLanes))
        if subs > 0 {
            c.bassManagement = UnifiedGraphBassManagement(
                crossoverHz: 80, redirectDB: UnifiedGraphBassManagement.twoMainMeanRedirectDB,
                subwoofers: [UnifiedGraphSubwoofer](repeating: UnifiedGraphSubwoofer(), count: subs))
        }
        if let ceilingDB {
            c.protection = UnifiedGraphProtection(
                limiterEnabled: true, ceilingDB: ceilingDB, attackMilliseconds: 1, releaseMilliseconds: 50,
                lookAheadMilliseconds: 2, truePeakGuard: true, oversampling: 2)
        }
        c.outputProtection = policy
        return c
    }

    private func analyse(_ spec: UnifiedGraphSpec, lanes: Int, strict: Bool = false, trims: [Int: Double] = [:]) -> [OutputHeadroom] {
        HeadroomModel(spec: spec, laneCount: lanes, strict: strict, trimsDB: trims).analyse()
    }

    /// Steady-state peak of every output for a tone of `amp` on all `inputs` lanes.
    private func render(_ host: UnifiedGraphHost, rate: Double, hz: Double, amp: Float, lanes: Int) throws -> [Float] {
        let total = Int(rate * 0.4) / block * block
        var peaks = [Float](repeating: 0, count: Int(host.outputChannels))
        var position = 0
        while position < total {
            let tone = (0..<block).map { amp * Float(sin(2.0 * .pi * hz * Double(position + $0) / rate)) }
            var input = [[Float]](repeating: tone, count: lanes)
            input += [[Float]](repeating: [Float](repeating: 0, count: block), count: max(0, Int(host.inputChannels) - lanes))
            let out = try host.processOffline(input: input, frames: block)
            if position >= total / 2 { for l in 0..<out.count { peaks[l] = max(peaks[l], out[l].map(abs).max() ?? 0) } }
            position += block
        }
        return peaks
    }

    private func db(_ linear: Float) -> Double { 20 * log10(Double(max(linear, 1e-9))) }

    func testGainStageIsReportedAndNeedFollowsTheLowestCeilingAtEveryRate() throws {
        for rate in Self.rates {
            let spec = try configuration(rate: rate, gain: 2, ceilingDB: -12, policy: UnifiedGraphOutputProtection()).makeSpec()
            for result in analyse(spec, lanes: 2) {
                XCTAssertTrue(result.isComplete, "rate \(rate)")
                XCTAssertEqual(result.peakGainDB, 6.02, accuracy: 0.1, "rate \(rate)")
                XCTAssertEqual(result.ceilingDB, -12, accuracy: 1e-6)
                XCTAssertEqual(result.neededDB, 6.02 + 0.5 + 12, accuracy: 0.15, "rate \(rate)")
            }
            let hard = try configuration(rate: rate, gain: 2, policy: UnifiedGraphOutputProtection()).makeSpec()
            XCTAssertEqual(analyse(hard, lanes: 2)[0].ceilingDB, -1, accuracy: 1e-6, "hard limit only at \(rate)")
        }
    }

    func testModelMatchesTheRenderedGainOfTheSubLaneAtItsPeakAtEveryRate() throws {
        for rate in Self.rates {
            let c = configuration(rate: rate, subs: 1)
            let spec = try c.makeSpec()
            let results = analyse(spec, lanes: 3)
            let sub = results[2]
            XCTAssertTrue(sub.isComplete, "rate \(rate)")
            let host = try UnifiedGraphHost(spec: spec)
            let amp: Float = 0.1
            let peaks = try render(host, rate: rate, hz: min(max(sub.peakHz, 20), 79), amp: amp, lanes: 2)
            let measured = db(peaks[2]) - db(amp)
            XCTAssertEqual(measured, sub.peakGainDB, accuracy: 1.0, "sub lane at \(rate)")
            XCTAssertLessThanOrEqual(measured, sub.peakGainDB + 0.5, "the estimate is not optimistic at \(rate)")
        }
    }

    func testTrimIsALiveParameterPostAndLowersTheOutputByThatMuchAtEveryRate() throws {
        for rate in Self.rates {
            func spec(_ trim: Double) throws -> UnifiedGraphSpec {
                var s = OutputProtectionSettings()
                s.set(.init(trimDB: trim), at: 0)
                s.set(.init(trimDB: trim), at: 2)
                return try configuration(rate: rate, subs: 1, policy: UnifiedGraphOutputProtection(s)).makeSpec()
            }
            let host = try UnifiedGraphHost(spec: spec(0))
            XCTAssertEqual(try host.apply(spec(-6)), .posted(count: 2), "program and sub trim are live posts at \(rate)")
            let peaks = try render(host, rate: rate, hz: 1000, amp: 0.5, lanes: 2)
            XCTAssertEqual(db(peaks[0]), db(0.5) - 6, accuracy: 0.1, "rate \(rate)")
            XCTAssertEqual(db(peaks[1]), db(0.5), accuracy: 0.1, "an untrimmed output is unchanged at \(rate)")
        }
    }

    func testCurrentTrimIsSubtractedSoTheNeedIsTheTotalAtEveryRate() throws {
        for rate in Self.rates {
            var s = OutputProtectionSettings()
            s.set(.init(trimDB: -4), at: 0)
            let trimmed = try configuration(rate: rate, gain: 2, ceilingDB: -6, policy: UnifiedGraphOutputProtection(s)).makeSpec()
            let plain = try configuration(rate: rate, gain: 2, ceilingDB: -6, policy: UnifiedGraphOutputProtection()).makeSpec()
            let a = analyse(trimmed, lanes: 2, trims: [0: -4])[0]
            let b = analyse(plain, lanes: 2)[0]
            XCTAssertEqual(a.peakGainDB, b.peakGainDB, accuracy: 0.05, "rate \(rate)")
            XCTAssertEqual(a.neededDB, b.neededDB, accuracy: 0.05)
            XCTAssertTrue(a.isSatisfied == (-4 <= -a.neededDB + 0.05))
            XCTAssertEqual(a.currentTrimDB, -4)
        }
    }

    func testStrictNeverNeedsLessThanTheDefaultAndRedirectedPowerLanesDifferFromCoherent() throws {
        let c = configuration(rate: 48_000, programLanes: 4, subs: 1)
        let spec = try c.makeSpec()
        let normal = analyse(spec, lanes: 5)[4]
        let strict = analyse(spec, lanes: 5, strict: true)[4]
        XCTAssertTrue(normal.isComplete && strict.isComplete)
        XCTAssertGreaterThanOrEqual(strict.peakGainDB, normal.peakGainDB)
        XCTAssertGreaterThan(strict.peakGainDB, normal.peakGainDB + 0.5, "two extra coherent lanes add about 3 dB or more")
    }

    func testUnmodelledStagesMakeTheAffectedOutputsIncompleteAndApplySkipsThem() throws {
        var spec = try configuration(rate: 48_000, gain: 2).makeSpec()
        spec.stages.append(UnifiedGraphStageSpec(kind: N60_STAGE_EXTERNAL.rawValue, stageId: 9_999, laneA: 0, laneMask: 1))
        let results = analyse(spec, lanes: 2)
        XCTAssertFalse(results[0].isComplete)
        XCTAssertTrue(results[1].isComplete)
        let next = HeadroomAssistant.applying(results, to: OutputProtectionSettings())
        XCTAssertEqual(next.lane(0).trimDB, 0, "an incomplete output keeps its trim")
        XCTAssertLessThan(next.lane(1).trimDB, 0)
    }

    func testEveryStageKindTheGraphEmitsIsClassified() {
        let known: [n60_stage_kind] = [N60_STAGE_GAIN, N60_STAGE_PEQ, N60_STAGE_BASS_MGMT, N60_STAGE_ROUTE, N60_STAGE_XOVER,
                                       N60_STAGE_PROTECTION, N60_STAGE_METER_IN, N60_STAGE_BINAURAL, N60_STAGE_EXTERNAL,
                                       N60_STAGE_LOUDNESS, N60_STAGE_MULTIBAND, N60_STAGE_FIR, N60_STAGE_ROOM_FIR]
        for kind in known { XCTAssertNotNil(HeadroomStageKind.classify(kind.rawValue), "kind \(kind.rawValue)") }
        XCTAssertNil(HeadroomStageKind.classify(9_999))
        XCTAssertEqual(HeadroomStageKind.classify(N60_STAGE_BINAURAL.rawValue), .modelled)
        XCTAssertEqual(HeadroomStageKind.classify(N60_STAGE_ROOM_FIR_TWO_BAND.rawValue), .modelled)
        XCTAssertEqual(HeadroomStageKind.classify(N60_STAGE_EXTERNAL.rawValue), .unmodelled)
        XCTAssertEqual(HeadroomStageKind.classify(N60_STAGE_PROTECTION.rawValue), .passive)
    }

    func testAppliedTrimRoundsUpToATenthNeverBoostsAndStaysInRange() {
        func result(_ needed: Double) -> OutputHeadroom {
            OutputHeadroom(lane: 0, peakGainDB: 0, peakHz: 0, ceilingDB: 0, neededDB: needed, currentTrimDB: 0, incomplete: [])
        }
        XCTAssertEqual(result(0).appliedTrimDB, 0)
        XCTAssertEqual(result(6.52).appliedTrimDB, -6.6, accuracy: 1e-9)
        XCTAssertEqual(result(500).appliedTrimDB, OutputProtectionSettings.trimRangeDB.lowerBound)
    }

    func testSettingsRoundTripKeepTrimAndDecodeOlderSettings() throws {
        var s = OutputProtectionSettings(independent: true, headroomStrict: true)
        s.set(.init(enabled: true, ceilingDB: -6, trimDB: -3.5), at: 1)
        s.set(.init(trimDB: -400), at: 2)
        XCTAssertEqual(s.lane(2).trimDB, OutputProtectionSettings.trimRangeDB.lowerBound)
        let back = try JSONDecoder().decode(OutputProtectionSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let old = Data(#"{"independent":true,"lanes":{"1":{"enabled":false}}}"#.utf8)
        let decoded = try JSONDecoder().decode(OutputProtectionSettings.self, from: old)
        XCTAssertTrue(decoded.independent)
        XCTAssertFalse(decoded.headroomStrict)
        XCTAssertEqual(decoded.lane(1).trimDB, 0)
    }

    // MARK: E9 S7b: coverage of routed, binaural, two-band FIR and Linkwitz-transform outputs

    /// Inserts a stage where the core's processing order wants it (the graph refuses stages out of position order).
    private func insert(_ stage: UnifiedGraphStageSpec, into spec: inout UnifiedGraphSpec) {
        let rank = UnifiedGraphProgramDSP.position(of: stage.kind)
        let index = spec.stages.firstIndex { UnifiedGraphProgramDSP.position(of: $0.kind) > rank } ?? spec.stages.count
        spec.stages.insert(stage, at: index)
    }

    private func magnitudeDB(_ taps: [Float], rate: Double, hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for (n, t) in taps.enumerated() {
            let w = 2.0 * .pi * hz / rate * Double(n)
            re += Double(t) * cos(w); im -= Double(t) * sin(w)
        }
        return 10 * log10(max(re * re + im * im, 1e-30))
    }

    private func twoBandParams(d: Int, e: Int) -> [Float] {
        let n = 16, m = 16
        var p: [Float] = [Float(d), Float(n), Float(m), Float(e)]
        for i in 0..<n { p.append(Float(0.9 * pow(0.6, Double(i)) * (i % 2 == 0 ? 1 : -0.5))) }
        for j in 0..<m { p.append(Float(0.5 * pow(0.7, Double(j)))) }
        return p
    }

    func testTwoBandEquivalentFilterMatchesTheCoreStageResponseInTheLowBandAtEveryRate() throws {
        for rate in Self.rates {
            for d in [1, 4] {
                let params = twoBandParams(d: d, e: 5)
                let equivalent = try XCTUnwrap(HeadroomModel.twoBandEquivalentTaps(params), "rate \(rate) D \(d)")
                var spec = try configuration(rate: rate).makeSpec()
                insert(UnifiedGraphStageSpec(
                    kind: N60_STAGE_ROOM_FIR_TWO_BAND.rawValue, stageId: 9_001, laneA: N60_LANE_ALL, params: params), into: &spec)
                let host = try UnifiedGraphHost(spec: spec)
                let frames = 4_096
                var impulse = [[Float]](repeating: [Float](repeating: 0, count: frames), count: Int(host.inputChannels))
                impulse[0][0] = 1
                var response: [Float] = []
                var position = 0
                while position < frames {
                    let slice = impulse.map { Array($0[position..<(position + block)]) }
                    response += try host.processOffline(input: slice, frames: block)[0]
                    position += block
                }
                let lowBandLimit = 0.3 * rate / Double(d) / 2
                for hz in [lowBandLimit / 12, lowBandLimit / 4, lowBandLimit / 1.5] {
                    XCTAssertEqual(magnitudeDB(equivalent, rate: rate, hz: hz), magnitudeDB(response, rate: rate, hz: hz),
                                   accuracy: 0.3, "rate \(rate) D \(d) at \(hz) Hz")
                }
                let results = analyse(spec, lanes: 2)
                XCTAssertTrue(results.allSatisfy(\.isComplete), "rate \(rate) D \(d)")
            }
        }
    }

    func testTwoBandStageTooLongForTheCoreIsReportedIncompleteAndApplySkipsIt() throws {
        var spec = try configuration(rate: 48_000, gain: 2).makeSpec()
        spec.stages.append(UnifiedGraphStageSpec(
            kind: N60_STAGE_ROOM_FIR_TWO_BAND.rawValue, stageId: 9_002, laneA: 0, params: twoBandParams(d: 4, e: 400_000)))
        spec.stages.append(UnifiedGraphStageSpec(kind: N60_STAGE_DRIVER_FIR_TWO_BAND.rawValue, stageId: 9_003, laneA: 1, params: [3, 1]))
        let results = analyse(spec, lanes: 2)
        XCTAssertEqual(results[0].incomplete, ["two-band FIR"])
        XCTAssertEqual(results[1].incomplete, ["two-band FIR"], "a malformed stage is incomplete, not unity")
        XCTAssertEqual(HeadroomAssistant.applying(results, to: OutputProtectionSettings()), OutputProtectionSettings())
    }

    func testLinkwitzTransformBoostIsModelledAndMatchesTheRenderedPeakAtEveryRate() throws {
        for rate in Self.rates {
            var spec = try configuration(rate: rate).makeSpec()
            // Pass-through filters, no trim, transform from f0 30 Hz Q 0.9 to fp 20 Hz Q 0.5: a low-frequency boost.
            let params: [Float] = [3, 0, 20, 3, 0, 20_000, 0, 0, 1, 30, 0.9, 20, 0.5, 0]
            insert(UnifiedGraphStageSpec(kind: N60_STAGE_XOVER.rawValue, stageId: 9_004, laneA: 0, params: params), into: &spec)
            let results = analyse(spec, lanes: 2)
            XCTAssertTrue(results[0].isComplete, "rate \(rate)")
            XCTAssertGreaterThan(results[0].peakGainDB, 4, "the transform boosts at low frequency, rate \(rate)")
            XCTAssertEqual(results[1].peakGainDB, 0, accuracy: 0.05, "the other lane is untouched at \(rate)")
            let host = try UnifiedGraphHost(spec: spec)
            let hz = max(results[0].peakHz, 10)
            let peaks = try render(host, rate: rate, hz: hz, amp: 0.1, lanes: 2)
            let measured = db(peaks[0]) - db(0.1)
            XCTAssertEqual(measured, results[0].peakGainDB, accuracy: 0.6, "rate \(rate) at \(hz) Hz")
        }
    }

    func testRoutedOutputDoesNotCountTheSourceLanesTrimAtEveryRate() throws {
        for rate in Self.rates {
            var s = OutputProtectionSettings()
            s.set(.init(trimDB: -6), at: 1)
            var spec = try configuration(rate: rate, gain: 2, policy: UnifiedGraphOutputProtection(s)).makeSpec()
            var route = [Float](repeating: 0, count: 16)
            for e in 0..<8 { route[2 * e] = -1 }
            route[0] = 1; route[1] = 1
            insert(UnifiedGraphStageSpec(kind: N60_STAGE_ROUTE.rawValue, stageId: 9_005, laneA: 0, laneMask: 1, params: route), into: &spec)
            let results = analyse(spec, lanes: 2, trims: [1: -6])
            XCTAssertTrue(results[0].isComplete, "rate \(rate)")
            XCTAssertEqual(results[0].peakGainDB, 6.02, accuracy: 0.1, "rate \(rate)")
            let host = try UnifiedGraphHost(spec: spec)
            let peaks = try render(host, rate: rate, hz: 1000, amp: 0.1, lanes: 2)
            // The source lane carries its -6 dB trim into the destination: the rendered gain is the model's plus the trim.
            XCTAssertEqual(db(peaks[0]) - db(0.1), results[0].peakGainDB - 6, accuracy: 0.2, "rate \(rate)")
        }
    }

    func testBinauralEarsAreModelledAndNotOptimisticAtEveryRate() throws {
        for headTracking in [false, true] {
            for rate in Self.rates {
                let spec = try UnifiedGraphTranslator.binauralSpec(
                    asset: BinauralProfileAsset.validationStereo(sampleRate: rate), layout: .fiveOne,
                    profile: HeadphoneDeviceProfileConfiguration(), outputChannels: 2, sampleRate: rate,
                    headTracking: headTracking, outputProtection: nil).get()
                let strict = analyse(spec, lanes: 2, strict: true)
                let normal = analyse(spec, lanes: 2)
                XCTAssertTrue(strict.allSatisfy(\.isComplete), "rate \(rate) tracking \(headTracking)")
                for ear in 0..<2 {
                    XCTAssertLessThanOrEqual(normal[ear].peakGainDB, strict[ear].peakGainDB + 1e-6)
                }
                let host = try UnifiedGraphHost(spec: spec)
                let hz = min(max(strict[0].peakHz, 50), 0.4 * rate)
                let peaks = try render(host, rate: rate, hz: hz, amp: 0.1, lanes: 6)
                for ear in 0..<2 {
                    XCTAssertLessThanOrEqual(db(peaks[ear]) - db(0.1), strict[ear].peakGainDB + 0.5,
                                             "the estimate is not optimistic, ear \(ear) rate \(rate) tracking \(headTracking)")
                }
            }
        }
    }

    /// Sweeps both program lanes at full scale from 20 Hz to 0.45 fs, as a worst-case programme through the whole graph.
    private func sweepPeaks(_ host: UnifiedGraphHost, rate: Double) throws -> [Float] {
        let seconds = 0.6, f0 = 20.0, f1 = 0.45 * rate
        let total = Int(rate * seconds) / block * block
        let k = log(f1 / f0)
        var peaks = [Float](repeating: 0, count: Int(host.outputChannels))
        var position = 0
        while position < total {
            let chunk = (0..<block).map { i -> Float in
                let t = Double(position + i) / rate
                return Float(sin(2.0 * .pi * f0 * seconds / k * (exp(k * t / seconds) - 1)))
            }
            var input = [[Float]](repeating: chunk, count: 2)
            input += [[Float]](repeating: [Float](repeating: 0, count: block), count: max(0, Int(host.inputChannels) - 2))
            let out = try host.processOffline(input: input, frames: block)
            for l in 0..<out.count { peaks[l] = max(peaks[l], out[l].map(abs).max() ?? 0) }
            position += block
        }
        return peaks
    }

    func testAfterApplyAFullScaleSweepStaysBelowTheCeilingMinusTheMarginAndNothingLimitsAtEveryRate() throws {
        for rate in Self.rates {
            let before = OutputProtectionSettings()
            let spec = try configuration(rate: rate, gain: 2, subs: 1, ceilingDB: -6, policy: UnifiedGraphOutputProtection(before)).makeSpec()
            let results = analyse(spec, lanes: 3)
            XCTAssertTrue(results.allSatisfy(\.isComplete), "rate \(rate)")
            XCTAssertTrue(results.contains { $0.neededDB > 1 }, "the case needs a trim at \(rate)")
            let after = HeadroomAssistant.applying(results, to: before)
            let host = try UnifiedGraphHost(spec: configuration(
                rate: rate, gain: 2, subs: 1, ceilingDB: -6, policy: UnifiedGraphOutputProtection(after)).makeSpec())
            let peaks = try sweepPeaks(host, rate: rate)
            for r in results {
                let bound = r.ceilingDB - N60_HEADROOM_TRUE_PEAK_MARGIN_DB
                XCTAssertLessThanOrEqual(db(peaks[r.lane]), bound + 0.05, "lane \(r.lane) at \(rate)")
            }
            if let program = host.dynamicsReadings() {
                XCTAssertLessThanOrEqual(program.limiterGainReductionDB, 0.05, "program limiter at \(rate)")
            }
            for reading in host.outputProtectionReadings(lanes: 3) {
                XCTAssertLessThanOrEqual(reading.hardLimitGainReductionDB, 0.05, "hard limit lane \(reading.lane) at \(rate)")
                XCTAssertLessThanOrEqual(reading.userGainReductionDB ?? 0, 0.05, "user limiter lane \(reading.lane) at \(rate)")
            }
        }
    }

    func testUndoRestoresThePreviousTrimsAndTheRenderedAudioBitExactlyAtEveryRate() throws {
        for rate in Self.rates {
            var before = OutputProtectionSettings()
            before.set(.init(trimDB: -2.5), at: 2)
            func spec(_ s: OutputProtectionSettings) throws -> UnifiedGraphSpec {
                try configuration(rate: rate, gain: 2, subs: 1, ceilingDB: -6, policy: UnifiedGraphOutputProtection(s)).makeSpec()
            }
            let original = try spec(before)
            let results = analyse(original, lanes: 3, trims: [2: -2.5])
            let applied = HeadroomAssistant.applying(results, to: before)
            XCTAssertNotEqual(applied, before, "Apply changes the trims at \(rate)")
            // The undo snapshot is the settings value taken before Apply; restoring it is exact.
            XCTAssertEqual(try spec(before), original)
            let reference = try UnifiedGraphHost(spec: original)
            let host = try UnifiedGraphHost(spec: original)
            _ = try host.apply(spec(applied))
            _ = try host.apply(spec(before))
            var a: [[Float]] = [], b: [[Float]] = []
            for pos in stride(from: 0, to: Int(rate * 0.3) / block * block, by: block) {
                let tone = (0..<block).map { Float(0.7 * sin(2.0 * .pi * 60.0 * Double(pos + $0) / rate)) }
                var input = [[Float]](repeating: tone, count: 2)
                input += [[Float]](repeating: [Float](repeating: 0, count: block), count: max(0, Int(host.inputChannels) - 2))
                a = try reference.processOffline(input: input, frames: block)
                b = try host.processOffline(input: input, frames: block)
            }
            XCTAssertEqual(a, b, "the last block is bit-identical after Apply then Undo at \(rate)")
        }
    }

    func testRecomputeRunsOffTheMainThread() async throws {
        let spec = try configuration(rate: 48_000, gain: 2).makeSpec()
        let onMain = LockedFlag()
        let results = await HeadroomRecompute.run(spec: spec, laneCount: 2, strict: false, trimsDB: [:]) {
            if Thread.isMainThread { onMain.set() }
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertFalse(onMain.value)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
