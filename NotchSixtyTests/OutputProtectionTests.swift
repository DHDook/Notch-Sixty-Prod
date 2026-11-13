import XCTest
@testable import NotchSixty

/// E9 S5b: output protection model, live ceiling edits, and the S5 tests still open (true-peak hold, gain linking, program
/// lanes unchanged below the sub ceiling, equal latency at 1/2/8 subs, click-free mode switch, flag-off output).
/// Behavioural: real graphs, real blocks, the eight standard rates.
final class OutputProtectionTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func user(ceilingDB: Double = -12) -> UnifiedGraphProtection {
        UnifiedGraphProtection(
            limiterEnabled: true, ceilingDB: ceilingDB, attackMilliseconds: 1, releaseMilliseconds: 50,
            lookAheadMilliseconds: 2, truePeakGuard: true, oversampling: 2)
    }

    private func make(
        rate: Double, subs: Int = 1, user: UnifiedGraphProtection?, policy: UnifiedGraphOutputProtection?
    ) -> UnifiedGraphConfiguration {
        var configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        if subs > 0 {
            configuration.bassManagement = UnifiedGraphBassManagement(
                crossoverHz: 80, redirectDB: UnifiedGraphBassManagement.twoMainMeanRedirectDB,
                subwoofers: [UnifiedGraphSubwoofer](repeating: UnifiedGraphSubwoofer(), count: subs))
        }
        configuration.protection = user
        configuration.outputProtection = policy
        return configuration
    }

    /// Runs `seconds` of per-lane tones (nil lane = silence) and returns the output of every lane, whole.
    private func render(
        _ host: UnifiedGraphHost, rate: Double, inputs: Int, seconds: Double,
        tone: (lane: Int, hz: Double, amp: Float)...
    ) throws -> [[Float]] {
        let total = Int(rate * seconds) / block * block
        var out: [[Float]] = []
        var position = 0
        while position < total {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: Int(host.inputChannels))
            for t in tone {
                input[t.lane] = (0..<block).map { t.amp * Float(sin(2.0 * .pi * t.hz * Double(position + $0) / rate)) }
            }
            let result = try host.processOffline(input: input, frames: block)
            if out.isEmpty { out = result.map { _ in [] } }
            for lane in 0..<result.count { out[lane] += result[lane] }
            position += block
        }
        return out
    }

    private func padded(_ lanes: [[Float]], _ host: UnifiedGraphHost) -> [[Float]] {
        lanes + [[Float]](repeating: [Float](repeating: 0, count: lanes[0].count), count: max(0, Int(host.inputChannels) - lanes.count))
    }

    private func settled(_ x: [Float]) -> ArraySlice<Float> { x[(x.count / 2)...] }
    private func peak(_ x: ArraySlice<Float>) -> Float { x.map(abs).max() ?? 0 }

    /// The 4x oversampled peak of `x` (windowed-sinc interpolation, 32 taps per phase), in dB.
    private func truePeakDB(_ x: ArraySlice<Float>) -> Double {
        let samples = Array(x)
        let half = 16
        var best: Double = 0
        for index in half..<(samples.count - half) where index % 3 == 0 {
            for phase in 0..<4 {
                let frac = Double(phase) / 4
                var sum = 0.0
                for k in -half + 1...half {
                    let t = Double(k) - frac
                    let sinc = t == 0 ? 1 : sin(.pi * t) / (.pi * t)
                    let window = 0.5 + 0.5 * cos(.pi * t / Double(half))
                    sum += Double(samples[index + k]) * sinc * window
                }
                best = max(best, abs(sum))
            }
        }
        return 20 * log10(max(best, 1e-12))
    }

    // MARK: Model

    func testSettingsRoundTripClampAndDropDefaults() throws {
        var settings = OutputProtectionSettings(independent: true)
        settings.set(.init(enabled: true, ceilingDB: -40), at: 2)
        XCTAssertEqual(settings.lane(2).ceilingDB, -20, "the ceiling is held to the range")
        settings.set(.init(enabled: true, ceilingDB: 3), at: 3)
        XCTAssertEqual(settings.lane(3).ceilingDB, -1, "never above the hard ceiling")
        settings.set(.init(enabled: false, ceilingDB: nil), at: 4)
        settings.set(.init(), at: 3)
        XCTAssertNil(settings.lanes[3], "a default lane is dropped")
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(OutputProtectionSettings.self, from: data), settings)

        var dynamics = DynamicsConfiguration()
        dynamics.outputProtection = settings
        let encoded = try JSONEncoder().encode(dynamics)
        XCTAssertEqual(try JSONDecoder().decode(DynamicsConfiguration.self, from: encoded).outputProtection, settings)
        // A configuration saved before this key existed still loads, with the defaults.
        let legacy = try JSONEncoder().encode(DynamicsConfiguration())
        XCTAssertNil(try JSONDecoder().decode(DynamicsConfiguration.self, from: legacy).outputProtection)
    }

    func testLaneParametersClampAndApplyOverrides() {
        let base: [Float] = [1, -0.5, 1, 50, 2, 1, 2]
        let policy = UnifiedGraphOutputProtection(independent: true, laneSettings: [
            1: .init(enabled: true, ceilingDB: -9), 2: .init(enabled: false, ceilingDB: -9), 3: .init(enabled: true, ceilingDB: nil)])
        XCTAssertEqual(policy.laneParameters(base, lane: 0)[1], -1, "no override: clamped to the hard ceiling")
        XCTAssertEqual(policy.laneParameters(base, lane: 1)[1], -9)
        XCTAssertEqual(policy.laneParameters(base, lane: 2)[1], -1, "off parks the ceiling at the hard ceiling")
        XCTAssertEqual(policy.laneParameters(base, lane: 3)[1], -1)
        for lane in 0..<4 {
            var a = policy.laneParameters(base, lane: lane), b = base
            a[1] = 0; b[1] = 0
            XCTAssertEqual(a, b, "only the ceiling moves, so look-ahead and oversampling (the latency) are shared")
        }
    }

    @MainActor func testPolicyFollowsSettingsOnlyWhileTheFlagIsOn() throws {
        let previous = UnifiedGraphOutputProtection.apply(settings: OutputProtectionSettings())
        defer {
            UnifiedGraphOutputProtection.apply(settings: previous)
            UnifiedGraphOutputProtection.refresh(try? flags(on: false))
        }
        let custom = OutputProtectionSettings(independent: true, lanes: [2: .init(enabled: true, ceilingDB: -8)])
        UnifiedGraphOutputProtection.refresh(try flags(on: false), settings: custom)
        XCTAssertNil(UnifiedGraphOutputProtection.current(), "flag off: no policy whatever the settings")
        UnifiedGraphOutputProtection.refresh(try flags(on: true))
        XCTAssertEqual(UnifiedGraphOutputProtection.current(), UnifiedGraphOutputProtection(custom))
        UnifiedGraphOutputProtection.apply(settings: OutputProtectionSettings())
        XCTAssertEqual(UnifiedGraphOutputProtection.current(), UnifiedGraphOutputProtection())
        // A new configuration picks the policy up with its sub-lane override.
        UnifiedGraphOutputProtection.apply(settings: custom)
        let spec = try make(rate: 48_000, user: user(), policy: UnifiedGraphOutputProtection.current()).makeSpec()
        let sub = try XCTUnwrap(spec.stages.first { $0.stageId == UnifiedGraphOutputProtection.userLaneStageBase + 2 })
        XCTAssertEqual(sub.params[1], -8)
    }

    @MainActor private func flags(on: Bool) throws -> FeatureFlags {
        let suite = "E9S5b-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return FeatureFlags(
            known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly,
            arguments: ["-NotchSixtyFeatures", on ? "e9.output-protection" : "-e9.output-protection"])
    }

    // MARK: Closing the S5 tests

    func testSubLaneAtPlusSixDBFSIsHeldAtTheCeilingWithinATenthOfADBTruePeakAtEveryRate() throws {
        let ceilingDB = -6.0
        for rate in Self.rates {
            let configuration = make(rate: rate, user: user(ceilingDB: ceilingDB), policy: UnifiedGraphOutputProtection())
            let spec = try configuration.makeSpec()
            let host = try UnifiedGraphHost(spec: spec)
            let out = try render(host, rate: rate, inputs: Int(spec.inputChannels), seconds: 0.6,
                                 tone: (0, 40, 2), (1, 40, 2))
            let sub = settled(out[2])
            let tp = truePeakDB(sub)
            XCTAssertEqual(tp, ceilingDB, accuracy: 0.1, "sub true peak at \(rate)")
            // The unprotected sub would have been well above the ceiling.
            let bare = try render(try UnifiedGraphHost(spec: make(rate: rate, user: nil, policy: nil).makeSpec()),
                                  rate: rate, inputs: 2, seconds: 0.6, tone: (0, 40, 2), (1, 40, 2))
            XCTAssertGreaterThan(truePeakDB(settled(bare[2])), ceilingDB + 1, "the test drives the sub into the limiter at \(rate)")
        }
    }

    func testLinkedModeReducesProgramLanesTogetherAndIndependentModeOnlyThePeakingLane() throws {
        for rate in Self.rates {
            func renderMode(_ policy: UnifiedGraphOutputProtection?, user u: UnifiedGraphProtection?) throws -> [[Float]] {
                let spec = try make(rate: rate, user: u, policy: policy).makeSpec()
                return try render(try UnifiedGraphHost(spec: spec), rate: rate, inputs: 2, seconds: 0.5,
                                  tone: (0, 1_000, 4), (1, 1_000, 0.1))
            }
            let reference = try renderMode(nil, user: nil)
            let linked = try renderMode(UnifiedGraphOutputProtection(independent: false), user: user())
            let independent = try renderMode(UnifiedGraphOutputProtection(independent: true), user: user())
            let refR = peak(settled(reference[1]))
            let linkedGainL = peak(settled(linked[0])) / peak(settled(reference[0]))
            let linkedGainR = peak(settled(linked[1])) / refR
            XCTAssertLessThan(linkedGainL, 0.1, "the loud lane is limited at \(rate)")
            XCTAssertEqual(linkedGainR, linkedGainL, accuracy: linkedGainL * 0.15, "linked: the quiet lane takes the same gain at \(rate)")
            let independentGainR = peak(settled(independent[1])) / refR
            XCTAssertEqual(independentGainR, 1, accuracy: 0.03, "independent: the quiet lane is untouched at \(rate)")
            XCTAssertLessThan(peak(settled(independent[0])) / peak(settled(reference[0])), 0.1, "independent: the loud lane is limited at \(rate)")
            // The sub (a 1 kHz tone is nearly all above its crossover) is the same in both modes.
            XCTAssertEqual(peak(settled(linked[2])), peak(settled(independent[2])), accuracy: 1e-4, "subs unaffected at \(rate)")
        }
    }

    func testProgramLanesAreBitIdenticalToBeforeWhenTheSubStaysBelowItsCeiling() throws {
        for rate in Self.rates {
            let play = { (policy: UnifiedGraphOutputProtection?) throws -> [[Float]] in
                let spec = try self.make(rate: rate, user: self.user(), policy: policy).makeSpec()
                return try self.render(try UnifiedGraphHost(spec: spec), rate: rate, inputs: 2, seconds: 0.3,
                                       tone: (0, 40, 0.05), (1, 300, 0.05))
            }
            let before = try play(nil)
            let after = try play(UnifiedGraphOutputProtection(independent: false))
            XCTAssertEqual(before[0], after[0], "left bit-identical at \(rate)")
            XCTAssertEqual(before[1], after[1], "right bit-identical at \(rate)")
        }
    }

    func testEveryOutputHasTheSameProtectionLatencyAtOneTwoAndEightSubsInBothModes() throws {
        for rate in Self.rates {
            for subs in [1, 2, 8] {
                let off = try UnifiedGraphHost(spec: make(rate: rate, subs: subs, user: user(), policy: nil).makeSpec())
                for independent in [false, true] {
                    let spec = try make(rate: rate, subs: subs, user: user(), policy: UnifiedGraphOutputProtection(independent: independent)).makeSpec()
                    let users = spec.stages.filter { $0.kind == N60_STAGE_PROTECTION.rawValue
                        && $0.stageId != N60_LSTAGE_PROTECTION || $0.stageId == N60_LSTAGE_PROTECTION }
                        .filter { $0.stageId < UnifiedGraphOutputProtection.hardLimitStageBase || $0.stageId >= UnifiedGraphOutputProtection.userLaneStageBase }
                    XCTAssertGreaterThanOrEqual(users.count, subs + 1)
                    let reference = users[0].params
                    for stage in users {
                        for index in [0, 2, 3, 4, 5, 6] {
                            XCTAssertEqual(stage.params[index], reference[index], "param \(index) shared, \(subs) subs at \(rate)")
                        }
                    }
                    let host = try UnifiedGraphHost(spec: spec)
                    XCTAssertEqual(host.latencyFrames, off.latencyFrames, "\(subs) subs, independent=\(independent) at \(rate): hard limits add none")
                    // An impulse reaches every output after the same number of frames.
                    var input = [[Float]](repeating: [Float](repeating: 0, count: 4_096), count: Int(host.inputChannels))
                    input[0][100] = 0.01; input[1][100] = 0.01
                    var arrival: [Int] = []
                    let out = try host.processOffline(input: input, frames: 4_096)
                    for lane in 0..<2 { arrival.append(out[lane].firstIndex { abs($0) > 1e-5 } ?? -1) }
                    XCTAssertEqual(arrival[0], arrival[1], "program lanes align at \(rate)")
                }
            }
        }
    }

    func testSwitchingTheIndependentModeIsClickFreeAtEveryRate() throws {
        for rate in Self.rates {
            let a = try make(rate: rate, user: user(), policy: UnifiedGraphOutputProtection(independent: false)).makeSpec()
            let b = try make(rate: rate, user: user(), policy: UnifiedGraphOutputProtection(independent: true)).makeSpec()
            XCTAssertFalse(a.hasSameTopology(as: b), "the switch is a topology rebuild")
            let host = try UnifiedGraphHost(spec: a)
            let total = Int(rate * 0.5) / block * block
            var left: [Float] = []
            var position = 0
            var switched = false
            while position < total {
                if position >= total / 2, !switched { XCTAssertEqual(try host.apply(b), .published); switched = true }
                let tone = (0..<block).map { 4 * Float(sin(2.0 * .pi * 200.0 * Double(position + $0) / rate)) }
                left += try host.processOffline(input: padded([tone, tone], host), frames: block)[0]
                position += block
            }
            let steps = zip(left.dropFirst(), left).map { abs($0 - $1) }
            let steady = steps[(steps.count / 4)..<(steps.count / 2 - 2_000)].max() ?? 0
            let overall = steps[(steps.count / 4)...].max() ?? 0
            XCTAssertLessThanOrEqual(overall, steady * 2 + 1e-3, "no click across the switch at \(rate)")
        }
    }

    @MainActor func testFlagOffOutputIsBitIdenticalWhateverTheSettings() throws {
        let previous = UnifiedGraphOutputProtection.apply(settings: OutputProtectionSettings(
            independent: true, lanes: [2: .init(enabled: false, ceilingDB: -9)]))
        defer {
            UnifiedGraphOutputProtection.apply(settings: previous)
            UnifiedGraphOutputProtection.refresh()
        }
        // The flag is graduated (default on), so force it off explicitly.
        UnifiedGraphOutputProtection.refresh(try flags(on: false))
        for rate in Self.rates {
            var plain = make(rate: rate, user: user(), policy: nil)
            var viaDefault = make(rate: rate, user: user(), policy: nil)
            viaDefault.outputProtection = UnifiedGraphOutputProtection.current()
            XCTAssertNil(viaDefault.outputProtection, "flag off: no policy")
            plain.outputProtection = nil
            XCTAssertEqual(try plain.makeSpec(), try viaDefault.makeSpec())
            let run = { (c: UnifiedGraphConfiguration) throws -> [[Float]] in
                try self.render(try UnifiedGraphHost(spec: c.makeSpec()), rate: rate, inputs: 2, seconds: 0.3, tone: (0, 40, 2), (1, 1_000, 2))
            }
            XCTAssertEqual(try run(plain), try run(viaDefault), "output at \(rate)")
        }
    }

    // MARK: Live edits and readings

    func testCeilingAndOnOffEditsArePostedLiveNotRebuiltAtEveryRate() throws {
        for rate in Self.rates {
            func spec(_ lane: OutputProtectionSettings.Lane) throws -> UnifiedGraphSpec {
                var settings = OutputProtectionSettings(independent: false)
                settings.set(lane, at: 2)
                return try make(rate: rate, user: user(ceilingDB: -3), policy: UnifiedGraphOutputProtection(settings)).makeSpec()
            }
            let host = try UnifiedGraphHost(spec: spec(.init(enabled: true, ceilingDB: -6)))
            let loud = (0..<block).map { 2 * Float(sin(2.0 * .pi * 40.0 * Double($0) / rate)) }
            _ = try host.processOffline(input: padded([loud, loud], host), frames: block)
            XCTAssertEqual(try host.apply(spec(.init(enabled: true, ceilingDB: -14))), .posted(count: 1), "ceiling edit at \(rate)")
            XCTAssertEqual(try host.apply(spec(.init(enabled: false, ceilingDB: -14))), .posted(count: 1), "off edit at \(rate)")
            XCTAssertEqual(try host.apply(spec(.init(enabled: true, ceilingDB: -6))), .posted(count: 1), "back on at \(rate)")
        }
    }

    func testLowerSubCeilingLowersTheSubOutputAndReportsGainReductionAtEveryRate() throws {
        for rate in Self.rates {
            func spec(_ ceiling: Double) throws -> UnifiedGraphSpec {
                var settings = OutputProtectionSettings()
                settings.set(.init(enabled: true, ceilingDB: ceiling), at: 2)
                return try make(rate: rate, user: user(ceilingDB: -3), policy: UnifiedGraphOutputProtection(settings)).makeSpec()
            }
            let host = try UnifiedGraphHost(spec: spec(-3))
            let before = try render(host, rate: rate, inputs: 2, seconds: 0.5, tone: (0, 40, 2), (1, 40, 2))
            _ = host.outputProtectionReadings(lanes: 3)
            XCTAssertEqual(try host.apply(spec(-15)), .posted(count: 1))
            let after = try render(host, rate: rate, inputs: 2, seconds: 0.5, tone: (0, 40, 2), (1, 40, 2))
            let readings = host.outputProtectionReadings(lanes: 3)
            XCTAssertEqual(readings.map(\.lane), [0, 1, 2], "one reading per output at \(rate)")
            XCTAssertEqual(truePeakDB(settled(before[2])), -3, accuracy: 0.15, "before at \(rate)")
            XCTAssertEqual(truePeakDB(settled(after[2])), -15, accuracy: 0.15, "after at \(rate)")
            let sub = try XCTUnwrap(readings.first { $0.lane == 2 })
            XCTAssertNotNil(sub.userGainReductionDB, "the sub lane has its own stage at \(rate)")
            XCTAssertNil(readings[0].userGainReductionDB, "linked program lanes have no stage of their own")
            XCTAssertGreaterThan(sub.outputTruePeakLinear, 0)
        }
    }

    // MARK: E9 S5c

    private func ep(_ index: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: index) }

    /// Stereo mains, a way on each with a limiter whose ceiling is `wayCeilingDB`, no crossover: two routed outputs.
    private func routed(rate: Double, wayCeilingDB: Double, policy: UnifiedGraphOutputProtection?) throws -> UnifiedGraphConfiguration {
        var routing = SpeakerRoutingTemplate.mainsPlusSub.build(
            mains: [.init(lane: 0, name: "L", endpoints: [ep(0)]), .init(lane: 1, name: "R", endpoints: [ep(1)])], subs: [])!
        for index in routing.speakers.indices {
            routing.speakers[index].ways[0].limiter = RoutingLimiter(ceilingDB: wayCeilingDB, lookAheadMilliseconds: 1)
        }
        var base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        base.outputProtection = policy
        return try SpeakerRoutingCompiler.compile(routing, onto: base)
    }

    func testRoutedOutputKeepsItsOwnLimiterButItsCeilingIsClampedWhileProtectionIsOn() throws {
        for rate in Self.rates {
            func wayCeilings(_ configuration: UnifiedGraphConfiguration) throws -> [Float] {
                try configuration.makeSpec().stages
                    .filter { $0.stageId >= UnifiedGraphConfiguration.outputProtectionStageBase && $0.stageId < UnifiedGraphConfiguration.driverFIRStageBase }
                    .map { $0.params[1] }
            }
            XCTAssertEqual(try wayCeilings(routed(rate: rate, wayCeilingDB: 0, policy: nil)), [0, 0], "flag off keeps the way ceiling at \(rate)")
            XCTAssertEqual(try wayCeilings(routed(rate: rate, wayCeilingDB: 0, policy: UnifiedGraphOutputProtection())), [-1, -1], "clamped at \(rate)")
            XCTAssertEqual(try wayCeilings(routed(rate: rate, wayCeilingDB: -6, policy: UnifiedGraphOutputProtection())), [-6, -6], "a lower ceiling is kept at \(rate)")
        }
    }

    func testRoutedOutputsGetTheHardLimitAndHoldMinusOneDBAtEveryRate() throws {
        let ceiling = Float(pow(10.0, -1.0 / 20.0)) * 1.02
        for rate in Self.rates {
            let configuration = try routed(rate: rate, wayCeilingDB: 0, policy: UnifiedGraphOutputProtection())
            let spec = try configuration.makeSpec()
            let hard = spec.stages.filter { $0.stageId >= UnifiedGraphOutputProtection.hardLimitStageBase && $0.stageId < UnifiedGraphOutputProtection.userLaneStageBase }
            XCTAssertEqual(hard.count, Int(spec.outputChannels), "one hard limit on every lane, routed included, at \(rate)")
            let host = try UnifiedGraphHost(spec: spec)
            let out = try render(host, rate: rate, inputs: 2, seconds: 0.5, tone: (0, 1_000, 4), (1, 1_000, 4))
            for lane in 2..<4 {
                XCTAssertLessThanOrEqual(peak(settled(out[lane])), ceiling, "routed lane \(lane) held at \(rate)")
                XCTAssertGreaterThan(peak(settled(out[lane])), 0.5, "routed lane \(lane) plays at \(rate)")
            }
        }
    }

    func testAnOutputCeilingAboveTheProgramCeilingIsHonouredAtEveryRate() throws {
        for rate in Self.rates {
            var settings = OutputProtectionSettings()
            settings.set(.init(enabled: true, ceilingDB: -3), at: 2)
            let spec = try make(rate: rate, user: user(ceilingDB: -12), policy: UnifiedGraphOutputProtection(settings)).makeSpec()
            let out = try render(try UnifiedGraphHost(spec: spec), rate: rate, inputs: 2, seconds: 0.6, tone: (0, 40, 2), (1, 40, 2))
            XCTAssertEqual(truePeakDB(settled(out[2])), -3, accuracy: 0.2, "the sub keeps its own, higher ceiling at \(rate)")
            XCTAssertLessThanOrEqual(truePeakDB(settled(out[0])), -12 + 0.2, "the mains keep the program ceiling at \(rate)")
        }
    }

    func testOutputCeilingsDoNothingWhileTheProgramLimiterIsOffButTheHardLimitHolds() throws {
        let ceiling = Float(pow(10.0, -1.0 / 20.0)) * 1.02
        var settings = OutputProtectionSettings()
        settings.set(.init(enabled: true, ceilingDB: -12), at: 2)
        for rate in Self.rates {
            var off = user(ceilingDB: -3)
            off.limiterEnabled = false
            off.truePeakGuard = false
            for protection in [Optional(off), nil] {
                let spec = try make(rate: rate, user: protection, policy: UnifiedGraphOutputProtection(settings)).makeSpec()
                let out = try render(try UnifiedGraphHost(spec: spec), rate: rate, inputs: 2, seconds: 0.6, tone: (0, 40, 2), (1, 40, 2))
                let sub = peak(settled(out[2]))
                XCTAssertGreaterThan(sub, Float(pow(10.0, -6.0 / 20.0)), "the -12 dB override is inert with the limiter off at \(rate)")
                XCTAssertLessThanOrEqual(sub, ceiling, "the hard limit still holds the sub at \(rate)")
            }
        }
    }

    private func binaural(rate: Double, policy: UnifiedGraphOutputProtection?) throws -> UnifiedGraphSpec {
        var profile = HeadphoneDeviceProfileConfiguration()
        profile.programLayout = .fiveOne
        return try UnifiedGraphTranslator.binauralSpec(
            asset: BinauralProfileAsset.validationStereo(sampleRate: rate), layout: .fiveOne, profile: profile,
            outputChannels: 2, sampleRate: rate, headTracking: false, outputProtection: policy).get()
    }

    func testBinauralEarsGetUnlinkedHardLimitsAndFlagOffIsUnchangedAtEveryRate() throws {
        let ceiling = Float(pow(10.0, -1.0 / 20.0)) * 1.02
        for rate in Self.rates {
            let off = try binaural(rate: rate, policy: nil)
            let on = try binaural(rate: rate, policy: UnifiedGraphOutputProtection())
            XCTAssertEqual(on.stages.count, off.stages.count + 2, "one hard limit per ear at \(rate)")
            let ears = on.stages.filter { $0.stageId >= UnifiedGraphOutputProtection.hardLimitStageBase && $0.stageId < UnifiedGraphOutputProtection.userLaneStageBase }
            XCTAssertEqual(ears.map(\.laneMask), [1, 2], "each ear alone at \(rate)")
            XCTAssertEqual(on.stages.filter { $0.stageId == N60_LSTAGE_PROTECTION }.count, 1, "the layout safety limiter stays at \(rate)")
            XCTAssertEqual(try UnifiedGraphHost(spec: on).latencyFrames, try UnifiedGraphHost(spec: off).latencyFrames, "no added latency at \(rate)")
            let host = try UnifiedGraphHost(spec: on)
            let out = try render(host, rate: rate, inputs: 6, seconds: 0.4, tone: (0, 1_000, 40))
            for ear in 0..<2 { XCTAssertLessThanOrEqual(peak(settled(out[ear])), ceiling, "ear \(ear) held at \(rate)") }
        }
    }

    func testBinauralHardLimitsAloneLimitEachEarIndependentlyAtEveryRate() throws {
        for rate in Self.rates {
            var bare = try binaural(rate: rate, policy: nil)
            bare.stages.removeAll { $0.stageId == N60_LSTAGE_PROTECTION }
            let reference = try render(try UnifiedGraphHost(spec: bare), rate: rate, inputs: 6, seconds: 0.4, tone: (0, 1_000, 1))
            let nearUnit = peak(settled(reference[0])), farUnit = peak(settled(reference[1]))
            // Drive the near ear to 2.0 (+6 dBFS); the far ear is then well under the hard ceiling.
            let amp = 2 / nearUnit
            XCTAssertLessThan(farUnit * amp, 0.6, "the test drives only one ear into its limit at \(rate)")
            var spec = try binaural(rate: rate, policy: UnifiedGraphOutputProtection())
            spec.stages.removeAll { $0.stageId == N60_LSTAGE_PROTECTION }
            let out = try render(try UnifiedGraphHost(spec: spec), rate: rate, inputs: 6, seconds: 0.4, tone: (0, 1_000, amp))
            XCTAssertLessThanOrEqual(peak(settled(out[0])), Float(pow(10.0, -1.0 / 20.0)) * 1.02, "the loud ear is limited at \(rate)")
            XCTAssertEqual(peak(settled(out[1])), farUnit * amp, accuracy: farUnit * amp * 0.02, "the far ear is not ducked at \(rate)")
        }
    }

    // MARK: Ceiling edit debounce (G20)

    @MainActor func testCeilingDragTicksAreCoalescedIntoOneEditAfterThePause() async throws {
        var delivered: [Double] = []
        let debouncer = OutputProtectionEditDebouncer<Double>(delay: .milliseconds(60)) { delivered.append($0) }
        for tick in stride(from: -3.0, through: -9.0, by: -0.5) { debouncer.submit(tick) }
        XCTAssertTrue(delivered.isEmpty, "nothing is published while the drag moves")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(delivered, [-9], "one edit with the last value")
    }

    @MainActor func testFlushDeliversTheLastTickAtOnceAndNothingIsDeliveredTwice() async throws {
        var delivered: [Double] = []
        let debouncer = OutputProtectionEditDebouncer<Double>(delay: .milliseconds(60)) { delivered.append($0) }
        debouncer.submit(-4)
        debouncer.submit(-5)
        debouncer.flush()
        XCTAssertEqual(delivered, [-5])
        debouncer.flush()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(delivered, [-5], "the pause timer was cancelled by the flush")
        debouncer.submit(-6)
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(delivered, [-5], "a cancelled edit is dropped")
    }
}
