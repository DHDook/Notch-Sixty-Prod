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
        XCTAssertEqual(HeadroomStageKind.classify(N60_STAGE_BINAURAL.rawValue), .unmodelled)
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

    func testRecomputeRunsOffTheMainThread() async throws {
        let spec = try configuration(rate: 48_000, gain: 2).makeSpec()
        let onMain = LockedFlag()
        let results = await HeadroomRecompute.run(spec: spec, laneCount: 2, strict: false, trimsDB: [:]) {
            if Thread.isMainThread { onMain.set() }
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertFalse(onMain.value)
    }

    /// E19 S5: a MIMO stage is a bounded kind. Zero taps pass the program (0 dB); a unit in-band diagonal tap doubles it.
    func testMIMOStageIsBoundedByItsRealisedTaps() {
        for rate in Self.rates {
            func spec(diagonal: Float) -> UnifiedGraphSpec {
                var params = [Float](repeating: 0, count: 8 + 2 + 2 * 2 * 1)
                params[0] = rate <= 48_000 ? 16 : 32
                params[1] = 1; params[2] = 2; params[3] = 0
                params[8] = 12; params[9] = 12
                params[10] = diagonal // E(0,0), the first tap
                let stage = UnifiedGraphStageSpec(kind: N60_STAGE_MIMO.rawValue, stageId: 1, laneA: 0, laneMask: 0b11, params: params)
                return UnifiedGraphSpec(sampleRate: rate, maxBlockFrames: 512, inputChannels: 2, outputChannels: 2, stages: [stage], denoiserPark: nil)
            }
            let off = analyse(spec(diagonal: 0), lanes: 2)
            XCTAssertTrue(off[0].isComplete, "rate \(rate)")
            XCTAssertEqual(off[0].peakGainDB, 0, accuracy: 0.3, "rate \(rate)")
            let on = analyse(spec(diagonal: 1), lanes: 2)
            XCTAssertTrue(on[0].isComplete, "rate \(rate)")
            XCTAssertGreaterThan(on[0].peakGainDB, 5, "rate \(rate)")
            XCTAssertEqual(on[1].peakGainDB, off[1].peakGainDB, accuracy: 0.3, "the other source is untouched at rate \(rate)")
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
