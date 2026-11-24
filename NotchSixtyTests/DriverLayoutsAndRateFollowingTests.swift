import CoreAudio
import XCTest
@testable import NotchSixty

/// E36 S6b: surround programmes folded for a stereo DAC from the driver's ring, active stereo on a multichannel DAC, and
/// automatic rate following. The session constructors need a real output device (bench B3/B8, G19), so these tests run what
/// they call: the shape decision, the channel order the fold reads, the compiled gains and the follower.
@MainActor
final class DriverLayoutsAndRateFollowingTests: XCTestCase {
    nonisolated static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Session shape

    func testPlainStereoAndMultichannelDACKeepTheStereoRing() throws {
        // A same-device plan on a multichannel DAC is not a reason to refuse: the ring is stereo whatever the DAC has.
        let layout = try DriverStereoSessionShape.resolve(programSourceUID: nil, foldLayout: nil, hasAggregatePlan: false)
        XCTAssertEqual(layout, .stereo)
        XCTAssertEqual(layout.channelCount, 2)
    }

    func testFoldFromTheDriverReadsTheWiderRing() throws {
        let cases: [(OutputProgramLayout, Int)] = [(.fiveOne, 6), (.sevenOne, 8), (.fiveOneFour, 10), (.sevenOneFour, 12)]
        for (programme, channels) in cases {
            let layout = try DriverStereoSessionShape.resolve(
                programSourceUID: ProgramFoldDown.driverSourceUID, foldLayout: programme, hasAggregatePlan: false)
            XCTAssertEqual(layout.channelCount, channels)
            XCTAssertEqual(layout, programme.driverLayout)
        }
    }

    func testRefusalsNameTheCause() {
        XCTAssertThrowsError(try DriverStereoSessionShape.resolve(programSourceUID: nil, foldLayout: nil, hasAggregatePlan: true)) {
            XCTAssertEqual($0 as? DriverCaptureError, .unsupportedSession("a multi-device output"))
        }
        XCTAssertThrowsError(try DriverStereoSessionShape.resolve(programSourceUID: "other", foldLayout: .fiveOne, hasAggregatePlan: false)) {
            XCTAssertEqual($0 as? DriverCaptureError, .unsupportedSession("a programme taken from another device"))
        }
        for programme in [OutputProgramLayout.threeOne, .fiveOneTwo, .nineOneSix] {
            XCTAssertNil(programme.driverLayout)
            XCTAssertThrowsError(try DriverStereoSessionShape.resolve(
                programSourceUID: ProgramFoldDown.driverSourceUID, foldLayout: programme, hasAggregatePlan: false)) {
                XCTAssertEqual($0 as? DriverCaptureError, .unsupportedChannelCount(programme.roles.count))
            }
        }
    }

    // MARK: Fold through the ring's channel order

    /// A unit sample on each ring channel must come out of the compiled fold with that role's gain on each feed: the ring
    /// order, the labels the session resolves and the matrix agree for every layout the driver carries.
    func testFoldGainsFollowTheRingChannelOrder() throws {
        for programme in [OutputProgramLayout.fiveOne, .sevenOne, .fiveOneFour, .sevenOneFour] {
            let ring = try XCTUnwrap(programme.driverLayout)
            var fold = ProgramFoldDown()
            fold.programSourceDeviceUID = ProgramFoldDown.driverSourceUID
            fold.lfe = .foldPlus10dBWithLimiter
            let plan = try XCTUnwrap(ProgramFoldDownPlan(layout: programme, foldDown: fold))
            let roles = ring.channelDescriptions.compactMap {
                OutputProgramRole(realtime: N60ProgramChannelRoleFromAudioChannelLabel($0.mChannelLabel))
            }
            XCTAssertEqual(roles.count, ring.channelCount, "\(programme) labels resolve")
            let gains = try XCTUnwrap(plan.matrix.deviceOrderGains(streamRoles: roles), "\(programme)")
            for (index, role) in roles.enumerated() {
                var frame = [Float](repeating: 0, count: ring.channelCount)
                frame[index] = 1
                let left = zip(frame, gains.left).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                let right = zip(frame, gains.right).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                XCTAssertEqual(Double(left), plan.matrix.gain(feed: 0, role: role), accuracy: 1e-6, "\(programme) \(role) left")
                XCTAssertEqual(Double(right), plan.matrix.gain(feed: 1, role: role), accuracy: 1e-6, "\(programme) \(role) right")
            }
        }
    }

    func testRingStreamFormatCarriesTheLayoutAtEveryRate() throws {
        for programme in [OutputProgramLayout.fiveOne, .sevenOne, .fiveOneFour, .sevenOneFour] {
            let ring = try XCTUnwrap(programme.driverLayout)
            for rate in Self.rates {
                let format = ring.streamFormat(sampleRate: rate)
                XCTAssertEqual(Int(format.channelCount), programme.roles.count)
                XCTAssertEqual(format.sampleRate, rate)
                XCTAssertTrue(format.isSupportedFloat32TransportFormat)
            }
        }
    }

    // MARK: Plan and build decision

    func testBuildDecisionUsesTheDriverOnlyWhileThePathIsOn() throws {
        var fold = ProgramFoldDown()
        fold.programSourceDeviceUID = ProgramFoldDown.driverSourceUID
        let plan = try XCTUnwrap(ProgramFoldDownPlan(layout: .sevenOne, foldDown: fold))
        XCTAssertEqual(ProgramFoldDownPlan.buildDecision(plan: plan, availableDevices: [], sampleRate: 96_000), .standard)
        let on = ProgramFoldDownPlan.buildDecision(plan: plan, availableDevices: [], sampleRate: 96_000, driverPathActive: true)
        guard case .tapSource(let device) = on else { return XCTFail("expected the driver source") }
        XCTAssertEqual(device.uid, ProgramFoldDown.driverSourceUID)
        XCTAssertEqual(device.outputChannelCount, 8)
        XCTAssertEqual(fold.resolveSource(layout: .sevenOne, availableDevices: [], sampleRate: 96_000),
                       .source(uid: ProgramFoldDown.driverSourceUID))
    }

    func testAnotherDeviceStillResolvesAsBefore() throws {
        var fold = ProgramFoldDown()
        fold.programSourceDeviceUID = "elsewhere"
        let plan = try XCTUnwrap(ProgramFoldDownPlan(layout: .fiveOne, foldDown: fold))
        XCTAssertEqual(ProgramFoldDownPlan.buildDecision(plan: plan, availableDevices: [], sampleRate: 48_000, driverPathActive: true),
                       .waitForSource(uid: "elsewhere"))
    }

    // MARK: Rate following

    func testPolicyPicksTheSameRateThenTheNearestSupportedMultiple() {
        let all = Self.rates
        for rate in all { XCTAssertEqual(DriverRateFollowPolicy.target(playerRate: rate, dacRates: all), rate) }
        // 44.1 kHz on a DAC that has only 88.2 and above: the nearest multiple, not 96 kHz.
        XCTAssertEqual(DriverRateFollowPolicy.target(playerRate: 44_100, dacRates: [48_000, 88_200, 96_000]), 88_200)
        XCTAssertEqual(DriverRateFollowPolicy.target(playerRate: 48_000, dacRates: [44_100, 96_000, 192_000]), 96_000)
        XCTAssertEqual(DriverRateFollowPolicy.target(playerRate: 44_100, dacRates: [352_800, 384_000]), 352_800)
        XCTAssertNil(DriverRateFollowPolicy.target(playerRate: 44_100, dacRates: [48_000, 96_000]), "no multiple: the DAC stays")
        XCTAssertNil(DriverRateFollowPolicy.target(playerRate: 384_000, dacRates: [44_100, 48_000]))
        XCTAssertNil(DriverRateFollowPolicy.target(playerRate: 0, dacRates: all))
    }

    final class MemoryStore: RateFollowingStore { var isEnabled = false }

    @MainActor
    final class World {
        var player: Double? = 48_000
        var dac: Double? = 48_000
        var dacRates = DriverLayoutsAndRateFollowingTests.rates
        var writes: [Double] = []
        var accept = true
        var ports: DriverRatePorts {
            DriverRatePorts(
                playerRate: { self.player }, dacRate: { self.dac }, dacRates: { self.dacRates },
                setDACRate: { rate in self.writes.append(rate); if self.accept { self.dac = rate }; return self.accept })
        }
    }

    func testFollowingIsOffByDefaultAndStoreDefaultsOff() {
        let suite = UserDefaults(suiteName: "n60.e36.rate.\(UUID().uuidString)")!
        XCTAssertFalse(UserDefaultsRateFollowingStore(defaults: suite).isEnabled)
        let world = World()
        let follower = DriverRateFollower(store: MemoryStore(), ports: world.ports)
        world.player = 96_000
        XCTAssertEqual(follower.tick(driverInUse: true), .disabled)
        XCTAssertEqual(follower.tick(driverInUse: true), .disabled)
        XCTAssertTrue(world.writes.isEmpty)
    }

    func testFollowerSettlesThenChangesTheDACAtEveryRate() {
        for rate in Self.rates {
            let world = World()
            world.dac = rate == 48_000 ? 44_100 : 48_000
            world.player = rate
            let follower = DriverRateFollower(store: MemoryStore(), ports: world.ports)
            follower.isEnabled = true
            XCTAssertEqual(follower.tick(driverInUse: true), .settling(rate), "\(rate) first sight")
            XCTAssertTrue(world.writes.isEmpty)
            XCTAssertEqual(follower.tick(driverInUse: true), .changed(rate))
            XCTAssertEqual(world.writes, [rate])
            // Not retried while the player stays on that rate.
            follower.tick(driverInUse: true)
            XCTAssertEqual(world.writes, [rate])
        }
    }

    func testChangingRateDuringTheSettleWindowRestartsIt() {
        let world = World()
        let follower = DriverRateFollower(store: MemoryStore(), ports: world.ports)
        follower.isEnabled = true
        world.player = 96_000
        XCTAssertEqual(follower.tick(driverInUse: true), .settling(96_000))
        world.player = 192_000
        XCTAssertEqual(follower.tick(driverInUse: true), .settling(192_000))
        XCTAssertTrue(world.writes.isEmpty)
        XCTAssertEqual(follower.tick(driverInUse: true), .changed(192_000))
    }

    func testFollowerUsesTheNearestMultipleAndLeavesUnsupportedRatesAlone() {
        let world = World()
        world.dacRates = [48_000, 96_000]
        world.player = 44_100
        let follower = DriverRateFollower(store: MemoryStore(), ports: world.ports)
        follower.isEnabled = true
        XCTAssertEqual(follower.tick(driverInUse: true), .unsupported(playerRate: 44_100))
        world.player = 48_000
        XCTAssertEqual(follower.tick(driverInUse: true), .alreadyAtTarget)
        XCTAssertTrue(world.writes.isEmpty)
        world.dacRates = [44_100, 88_200]
        world.dac = 44_100
        world.player = 44_100
        XCTAssertEqual(follower.tick(driverInUse: true), .alreadyAtTarget)
    }

    func testNothingFollowsWithoutTheDriverPathOrWhenAWriteFails() {
        let world = World()
        world.player = 96_000
        let follower = DriverRateFollower(store: MemoryStore(), ports: world.ports)
        follower.isEnabled = true
        XCTAssertEqual(follower.tick(driverInUse: false), .inactive)
        XCTAssertEqual(follower.tick(driverInUse: false), .inactive)
        XCTAssertTrue(world.writes.isEmpty)
        world.accept = false
        follower.tick(driverInUse: true)
        XCTAssertEqual(follower.tick(driverInUse: true), .failed(96_000))
        world.player = nil
        XCTAssertEqual(follower.tick(driverInUse: true), .noPlayerRate)
    }

    func testModelFollowsOnlyWhileTheDriverIsInUse() {
        let world = World()
        world.player = 96_000
        let model = AudioInputPathModel(probe: { .inUse(version: 1) }, downloadURL: nil, openURL: { _ in })
        model.rateFollower = DriverRateFollower(store: MemoryStore(), ports: world.ports)
        model.setRateFollowing(true)
        XCTAssertTrue(model.rateFollowingEnabled)
        // Tap path chosen: unavailable, so nothing is written however often the poll runs.
        XCTAssertFalse(model.rateFollowingAvailable)
        model.refresh(); model.refresh(); model.refresh()
        XCTAssertTrue(world.writes.isEmpty)
        model.select(.virtualDriver)
        XCTAssertTrue(model.rateFollowingAvailable)
        model.refresh(); model.refresh()
        XCTAssertEqual(world.writes, [96_000])
        model.setRateFollowing(false)
        XCTAssertFalse(model.rateFollowingEnabled)
    }
}
