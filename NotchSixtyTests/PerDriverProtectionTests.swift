import XCTest
@testable import NotchSixty

/// E8 S13 (`e8.active-commissioning`): per-way limiter by default, the cumulative boost guard and the long-term power
/// limit, from the editor model to rendered audio, at the eight standard rates.
@MainActor
final class PerDriverProtectionTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func ep(_ i: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: i) }
    private func spec(_ hz: Double) -> CrossoverCore.FilterSpec { CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: hz) }

    private func context(rate: Double = 48_000, enforce: Bool = true) -> SpeakerRoutingContext {
        SpeakerRoutingContext(programLanes: 2, subwoofers: 0, sampleRate: rate, enforceDriverRoles: enforce)
    }

    private func config(_ way: RoutedWay) -> SpeakerRoutingConfiguration {
        SpeakerRoutingConfiguration(speakers: [RoutedSpeaker(name: "L", source: .program(0), ways: [way])])
    }

    private func threeWayModel(enforce: Bool = true) -> SpeakerRoutingEditorModel {
        let m = SpeakerRoutingEditorModel(context: context(enforce: enforce))
        XCTAssertTrue(m.applyTemplate(
            .threeWay,
            mains: [.init(lane: 0, name: "Left", endpoints: [ep(0), ep(1), ep(2)]),
                    .init(lane: 1, name: "Right", endpoints: [ep(3), ep(4), ep(5)])],
            crossoverHz: [400, 3_000]))
        return m
    }

    // MARK: Defaults

    func testEveryWayGetsItsRolesLimiterAndAnOffChoiceSticks() throws {
        let m = threeWayModel()
        m.inferMissingRoles()
        m.applyProtectionDefaults()
        let left = try XCTUnwrap(m.configuration.speakers.first)
        XCTAssertEqual(left.ways.compactMap { $0.limiter?.ceilingDB }.count, 3, "every way has a limiter")
        let byRole = Dictionary(uniqueKeysWithValues: left.ways.map { ($0.role!, $0.limiter!.ceilingDB) })
        XCTAssertEqual(byRole[.tweeter], DriverRole.tweeter.defaultLimiterCeilingDB)
        XCTAssertEqual(byRole[.midrange], DriverRole.midrange.defaultLimiterCeilingDB)
        XCTAssertEqual(byRole[.woofer], DriverRole.woofer.defaultLimiterCeilingDB)
        XCTAssertLessThan(byRole[.tweeter]!, byRole[.woofer]!, "the tweeter has the lowest ceiling")

        let way = left.ways[0]
        m.setLimiterEnabled(false, way: way.id, speaker: left.id)
        m.editWay(way.id, speaker: left.id) { $0.trimDB = -1 }   // any later edit must not put the default back
        XCTAssertNil(m.configuration.speakers[0].ways[0].limiter)
        m.setLimiterEnabled(true, way: way.id, speaker: left.id)
        XCTAssertEqual(m.configuration.speakers[0].ways[0].limiter?.ceilingDB, DriverRole.woofer.defaultLimiterCeilingDB)
    }

    func testFlagOffAddsNoLimiters() {
        let m = threeWayModel(enforce: false)
        m.applyProtectionDefaults()
        XCTAssertTrue(m.configuration.speakers.flatMap(\.ways).allSatisfy { $0.limiter == nil })
    }

    func testNewWaysFromAnEditGetTheDefaultToo() {
        let m = threeWayModel()
        XCTAssertTrue(m.configuration.speakers.flatMap(\.ways).allSatisfy { $0.limiter != nil }, "template ways are protected on creation")
    }

    func testOldStoredWayDecodesWithoutProtectionFields() throws {
        let data = try JSONEncoder().encode(RoutedWay(name: "W", endpoint: ep(0)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "limiterDeclined")
        object.removeValue(forKey: "powerLimit")
        let back = try JSONDecoder().decode(RoutedWay.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(back.powerLimit)
        XCTAssertNil(back.limiterDeclined)
        var limited = RoutedWay(name: "W", endpoint: ep(0))
        limited.powerLimit = RoutingPowerLimit(levelDB: -15, timeConstantMilliseconds: 3_000)
        XCTAssertEqual(try JSONDecoder().decode(RoutedWay.self, from: JSONEncoder().encode(limited)).powerLimit, limited.powerLimit)
    }

    // MARK: Boost guard

    private func way(trim: Double = 0, eq: [RoutingEQSection] = [], hp: Double? = 100, role: DriverRole? = nil) -> RoutedWay {
        RoutedWay(name: "W", endpoint: ep(0), highPass: hp.map(spec), eq: eq, trimDB: trim, role: role)
    }

    func testBoostGuardTableAtEveryRate() {
        let peak: (Double) -> RoutingEQSection = { RoutingEQSection(type: 0, frequencyHz: 1_000, gainDB: $0, q: 1) }
        for rate in Self.rates {
            let ctx = context(rate: rate)
            let quiet = config(way(eq: [peak(6)])).validate(in: ctx)
            XCTAssertTrue(quiet.isValid && quiet.warnings.isEmpty, "+6 dB passes at \(rate)")
            let warned = config(way(eq: [peak(14)])).validate(in: ctx)
            XCTAssertTrue(warned.isValid, "+14 dB is a warning, not an error, at \(rate)")
            XCTAssertTrue(warned.warnings.contains { if case .boostHigh = $0 { return true } else { return false } }, "warns at \(rate)")
            let named = warned.warnings.compactMap { w -> Double? in if case .boostHigh(_, _, let hz) = w { return hz }; return nil }
            XCTAssertEqual(named.first ?? 0, 1_000, accuracy: 60, "the warning names the frequency at \(rate)")
            let refused = config(way(eq: [peak(20)])).validate(in: ctx)
            XCTAssertTrue(refused.errors.contains { if case .boostTooHigh = $0 { return true } else { return false } }, "+20 dB refused at \(rate)")
            // Trim counts: +10 trim and +10 EQ is +20 in the passband.
            let summed = config(way(trim: 10, eq: [peak(10)])).validate(in: ctx)
            XCTAssertTrue(summed.errors.contains { if case .boostTooHigh = $0 { return true } else { return false } }, "trim adds at \(rate)")
            // A boost outside the passband (above the low-pass) does not count.
            var banded = way(eq: [RoutingEQSection(type: 0, frequencyHz: 12_000, gainDB: 20, q: 2)])
            banded.lowPass = spec(2_000)
            XCTAssertTrue(config(banded).validate(in: ctx).isValid, "out-of-band boost ignored at \(rate)")
            // Flag off: no boost rule.
            XCTAssertTrue(config(way(eq: [peak(20)])).validate(in: context(rate: rate, enforce: false)).isValid, "flag off at \(rate)")
        }
    }

    func testNoBoostBelowTheLowestSafeFrequency() {
        for rate in Self.rates {
            let ctx = context(rate: rate)
            var tweeter = way(eq: [RoutingEQSection(type: 0, frequencyHz: 800, gainDB: 6, q: 1)], hp: 3_000, role: .tweeter)
            XCTAssertTrue(config(tweeter).validate(in: ctx).errors.contains {
                if case .boostBelowSafe = $0 { return true } else { return false } }, "boost under 1.5 kHz refused at \(rate)")
            tweeter.eq = [RoutingEQSection(type: 0, frequencyHz: 8_000, gainDB: 6, q: 4)]
            XCTAssertFalse(config(tweeter).validate(in: ctx).errors.contains {
                if case .boostBelowSafe = $0 { return true } else { return false } }, "boost in the passband passes at \(rate)")
            // A cut below the safe frequency is fine.
            tweeter.eq = [RoutingEQSection(type: 0, frequencyHz: 800, gainDB: -6, q: 1)]
            XCTAssertTrue(config(tweeter).validate(in: ctx).isValid, "a cut passes at \(rate)")
        }
    }

    func testAnEditThatBreaksTheBoostLimitIsRefusedAndPublishesNothing() throws {
        let m = threeWayModel()
        var commits = 0
        m.onCommit = { _ in commits += 1 }
        let speaker = try XCTUnwrap(m.configuration.speakers.first)
        let target = try XCTUnwrap(speaker.ways.last)   // the tweeter: its passband holds 4 kHz
        let before = m.configuration
        m.addEQ(RoutingEQSection(type: 0, frequencyHz: 4_000, gainDB: 24, q: 1), way: target.id, speaker: speaker.id)
        XCTAssertEqual(m.configuration, before)
        XCTAssertEqual(commits, 0)
        XCTAssertNotNil(m.roleRefusal)
    }

    // MARK: Engine

    private func render(_ host: UnifiedGraphHost, rate: Double, seconds: Double, amp: Float, hz: Double = 1_000) throws -> [[Float]] {
        let total = Int(rate * seconds) / block * block
        var out: [[Float]] = []
        var position = 0
        while position < total {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: Int(host.inputChannels))
            input[0] = (0..<block).map { amp * Float(sin(2.0 * .pi * hz * Double(position + $0) / rate)) }
            let result = try host.processOffline(input: input, frames: block)
            if out.isEmpty { out = result.map { _ in [] } }
            for lane in 0..<result.count { out[lane] += result[lane] }
            position += block
        }
        return out
    }

    private func routed(rate: Double, limiter: RoutingLimiter?, power: RoutingPowerLimit?) throws -> UnifiedGraphConfiguration {
        var routing = SpeakerRoutingTemplate.mainsPlusSub.build(
            mains: [.init(lane: 0, name: "L", endpoints: [ep(0)]), .init(lane: 1, name: "R", endpoints: [ep(1)])], subs: [])!
        for index in routing.speakers.indices {
            routing.speakers[index].ways[0].limiter = limiter
            routing.speakers[index].ways[0].powerLimit = power
        }
        // The program Limiter stays off (base.protection nil): the way limiter works on its own.
        let base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        return try SpeakerRoutingCompiler.compile(routing, onto: base)
    }

    private func settledPeak(_ x: [Float]) -> Float { x[(x.count / 2)...].map(abs).max() ?? 0 }
    private func settledRMSDB(_ x: [Float]) -> Double {
        let tail = x[(x.count * 3 / 4)...]
        return 10 * log10(tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count) + 1e-30)
    }

    func testWayLimiterHoldsItsCeilingWithTheProgramLimiterOffAtEveryRate() throws {
        let ceilingDB = DriverRole.tweeter.defaultLimiterCeilingDB
        let limit = Float(pow(10.0, ceilingDB / 20.0)) * 1.02
        for rate in Self.rates {
            let spec = try routed(rate: rate, limiter: RoutedWay.defaultLimiter(role: .tweeter), power: nil).makeSpec()
            let out = try render(try UnifiedGraphHost(spec: spec), rate: rate, seconds: 0.4, amp: 0.9)
            XCTAssertLessThanOrEqual(settledPeak(out[2]), limit, "limited at \(rate)")
            XCTAssertGreaterThan(settledPeak(out[2]), limit * 0.5, "still plays at \(rate)")
            let bare = try routed(rate: rate, limiter: nil, power: nil).makeSpec()
            let free = try render(try UnifiedGraphHost(spec: bare), rate: rate, seconds: 0.4, amp: 0.9)
            XCTAssertGreaterThan(settledPeak(free[2]), 0.8, "no limiter, no limit at \(rate)")
        }
    }

    func testPowerLimitHoldsItsLevelAndIsAbsentWhenOff() throws {
        let power = RoutingPowerLimit(levelDB: -20, timeConstantMilliseconds: 100)
        for rate in Self.rates {
            let spec = try routed(rate: rate, limiter: nil, power: power).makeSpec()
            let stages = spec.stages.filter { $0.kind == N60_STAGE_THERMAL_LIMIT.rawValue }
            XCTAssertEqual(stages.count, 2, "each driven way has one power limit at \(rate)")
            XCTAssertEqual(stages.map(\.params), [[-20, 100], [-20, 100]])
            let out = try render(try UnifiedGraphHost(spec: spec), rate: rate, seconds: 1.6, amp: 0.5)
            XCTAssertEqual(settledRMSDB(out[2]), -20, accuracy: 0.6, "settles at the level at \(rate)")
            let off = try routed(rate: rate, limiter: nil, power: nil).makeSpec()
            XCTAssertFalse(off.stages.contains { $0.kind == N60_STAGE_THERMAL_LIMIT.rawValue }, "off: no stage at \(rate)")
            let quiet = try render(try UnifiedGraphHost(spec: spec), rate: rate, seconds: 0.4, amp: 0.05)
            XCTAssertEqual(settledPeak(quiet[2]), 0.05, accuracy: 0.0005, "transparent below the level at \(rate)")
        }
    }

    func testAnInvalidPowerLimitIsRefusedAndHeadroomTreatsTheStageAsPassive() {
        var w = way()
        w.powerLimit = RoutingPowerLimit(levelDB: 3, timeConstantMilliseconds: 10)
        XCTAssertTrue(config(w).validate(in: context()).errors.contains(.invalidPowerLimit(way: "W")))
        XCTAssertEqual(HeadroomStageKind.classify(N60_STAGE_THERMAL_LIMIT.rawValue), .passive)
    }

    func testEditorSetsAndClearsThePowerLimitWithTweeterDefault() throws {
        let m = threeWayModel()
        m.inferMissingRoles()
        let speaker = try XCTUnwrap(m.configuration.speakers.first)
        let tweeter = try XCTUnwrap(speaker.ways.first { $0.role == .tweeter })
        m.setPowerLimitEnabled(true, way: tweeter.id, speaker: speaker.id)
        var current = try XCTUnwrap(m.configuration.speakers[0].ways.first { $0.id == tweeter.id })
        XCTAssertEqual(current.powerLimit?.levelDB, -18)
        m.setPowerLimit(levelDB: -500, timeConstantMilliseconds: 1, way: tweeter.id, speaker: speaker.id)
        current = try XCTUnwrap(m.configuration.speakers[0].ways.first { $0.id == tweeter.id })
        XCTAssertEqual(current.powerLimit?.levelDB, RoutingPowerLimit.levelRangeDB.lowerBound)
        XCTAssertEqual(current.powerLimit?.timeConstantMilliseconds, RoutingPowerLimit.timeConstantRangeMilliseconds.lowerBound)
        XCTAssertTrue(m.validation.isValid)
        m.setPowerLimitEnabled(false, way: tweeter.id, speaker: speaker.id)
        XCTAssertNil(m.configuration.speakers[0].ways.first { $0.id == tweeter.id }?.powerLimit)
    }
}
