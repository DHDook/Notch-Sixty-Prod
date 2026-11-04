import XCTest
@testable import NotchSixty

/// E25 S7: ITU-R BS.775 fold-down matrix, LFE handling, headroom and the program-source policy.
final class ProgramFoldDownTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private func db(_ x: Double) -> Double { 20 * log10(x) }

    private func device(_ uid: String, channels: UInt32, max: Double = 384_000) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: 1, uid: uid, name: uid, nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: max)],
            outputChannelCount: channels)
    }

    func testFiveOneCoefficientsMatchBS775Within001dB() throws {
        let m = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: .fiveOne, foldDown: ProgramFoldDown()))
        XCTAssertEqual(m.gain(feed: 0, role: .frontLeft), 1)
        XCTAssertEqual(m.gain(feed: 0, role: .frontRight), 0)
        XCTAssertEqual(db(m.gain(feed: 0, role: .frontCenter)), -3.0103, accuracy: 0.01)
        XCTAssertEqual(db(m.gain(feed: 1, role: .frontCenter)), -3.0103, accuracy: 0.01)
        XCTAssertEqual(db(m.gain(feed: 0, role: .sideLeft)), -3.0103, accuracy: 0.01)
        XCTAssertEqual(m.gain(feed: 1, role: .sideLeft), 0)
        XCTAssertEqual(db(m.gain(feed: 1, role: .sideRight)), -3.0103, accuracy: 0.01)
        XCTAssertEqual(m.gain(feed: 0, role: .lowFrequencyEffects), 0, "LFE dropped by default")
        XCTAssertFalse(m.needsLimiter == false && m.left.absoluteSum > 1, "ITU sum exceeds 1, so it is flagged")
        XCTAssertTrue(m.needsLimiter)
    }

    func testSevenOneAndHeightsFoldToSameSide() throws {
        let m = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: .sevenOneFour, foldDown: ProgramFoldDown()))
        for role in [OutputProgramRole.rearLeft, .sideLeft, .topFrontLeft] {
            XCTAssertEqual(db(m.gain(feed: 0, role: role)), -3.0103, accuracy: 0.01)
            XCTAssertEqual(m.gain(feed: 1, role: role), 0)
        }
        XCTAssertEqual(db(m.gain(feed: 1, role: .topRearRight)), -6.0206, accuracy: 0.01)
        XCTAssertNil(ProgramFoldDownCompiler.compile(layout: .stereo, foldDown: ProgramFoldDown()))
    }

    func testLFEFoldIsPlus10dBAndFullScaleDoesNotClipWithPeakSafeHeadroom() throws {
        var f = ProgramFoldDown(programSourceDeviceUID: "x", lfe: .foldPlus10dBWithLimiter, headroom: .none)
        let raw = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: .fiveOne, foldDown: f))
        XCTAssertEqual(db(raw.gain(feed: 0, role: .lowFrequencyEffects)), 10, accuracy: 0.01)
        XCTAssertTrue(raw.needsLimiter)
        XCTAssertEqual(raw.protection?.ceilingDB, ProgramFoldDown.limiterCeilingDB)
        f.headroom = .peakSafe
        let safe = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: .fiveOne, foldDown: f))
        XCTAssertFalse(safe.needsLimiter)
        XCTAssertNil(safe.protection)
        // Worst case: every channel at +1 (matching sign). Applied matrix stays within full scale.
        for row in [safe.left, safe.right] {
            let out = row.gains.reduce(0, +)
            XCTAssertLessThanOrEqual(abs(out), 1 + 1e-12)
        }
        // LFE-to-other ratio is unchanged by the normalisation.
        XCTAssertEqual(safe.gain(feed: 0, role: .lowFrequencyEffects) / safe.gain(feed: 0, role: .frontLeft),
                       raw.gain(feed: 0, role: .lowFrequencyEffects) / raw.gain(feed: 0, role: .frontLeft), accuracy: 1e-12)
    }

    func testPeakSafeLeavesAlreadySafeMatrixAlone() throws {
        let m = try XCTUnwrap(ProgramFoldDownCompiler.compile(
            layout: .threeOne, foldDown: ProgramFoldDown(programSourceDeviceUID: "x", headroom: .none)))
        XCTAssertEqual(m.left.absoluteSum, 1 + ProgramFoldDown.surroundGain, accuracy: 1e-12)
    }

    func testRouteLanesAndLimiterLookAheadAtEightRates() throws {
        let f = ProgramFoldDown(programSourceDeviceUID: "x", lfe: .foldPlus10dBWithLimiter)
        let m = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: .fiveOne, foldDown: f))
        let lanes = try XCTUnwrap(m.outputLanes(firstLane: 6))
        XCTAssertEqual(lanes.map(\.lane), [6, 7])
        XCTAssertLessThanOrEqual(lanes[0].entries.count, Int(N60_ROUTE_MAX_ENTRIES))
        XCTAssertEqual(lanes[0].entries.map(\.source), [0, 2, 3, 4], "L, C, LFE, Ls feed the left lane")
        XCTAssertEqual(lanes[1].entries.map(\.source), [1, 2, 3, 5])
        let p = try XCTUnwrap(m.protection)
        for rate in rates {
            // Same matrix at every rate; the frame count scales with the rate from milliseconds.
            XCTAssertEqual(ProgramFoldDownCompiler.compile(layout: .fiveOne, foldDown: f), m)
            XCTAssertEqual(p.lookAheadMilliseconds * rate / 1000, rate / 1000, accuracy: 1e-9)
        }
    }

    func testRouteEntryLimit() throws {
        let drop = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: .nineOneSix, foldDown: ProgramFoldDown(programSourceDeviceUID: "x")))
        for lane in try XCTUnwrap(drop.outputLanes(firstLane: 0)) {
            XCTAssertLessThanOrEqual(lane.entries.count, Int(N60_ROUTE_MAX_ENTRIES))
        }
        let lfe = try XCTUnwrap(ProgramFoldDownCompiler.compile(
            layout: .nineOneSix, foldDown: ProgramFoldDown(programSourceDeviceUID: "x", lfe: .foldPlus10dBWithLimiter)))
        XCTAssertNil(lfe.outputLanes(firstLane: 0), "nine entries exceed the ROUTE limit")
    }

    func testSourcePolicy() {
        let f = ProgramFoldDown(programSourceDeviceUID: "wide")
        let wide = device("wide", channels: 6)
        XCTAssertEqual(f.resolveSource(layout: .fiveOne, availableDevices: [wide], sampleRate: 384_000), .source(uid: "wide"))
        // Disappearing source: wait for the same UID, never fall back to another device.
        XCTAssertEqual(f.resolveSource(layout: .fiveOne, availableDevices: [device("other", channels: 6)], sampleRate: 48_000),
                       .waitForDevice(uid: "wide"))
        XCTAssertEqual(f.resolveSource(layout: .sevenOne, availableDevices: [wide], sampleRate: 48_000),
                       .channelCountMismatch(expected: 8, actual: 6))
        XCTAssertEqual(f.resolveSource(layout: .fiveOne, availableDevices: [device("wide", channels: 6, max: 96_000)], sampleRate: 192_000),
                       .sampleRateUnsupported(192_000))
        XCTAssertEqual(ProgramFoldDown().resolveSource(layout: .fiveOne, availableDevices: [wide], sampleRate: 48_000), .upstreamFold)
        XCTAssertEqual(f.resolveSource(layout: .stereo, availableDevices: [wide], sampleRate: 48_000), .upstreamFold)
    }

    func testArrangementRoundTripAndCapabilityText() throws {
        var a = SystemSetupArrangementPlanner.arrangement(
            deviceUID: "d", detectedChannelCount: 2, channelsInUse: 2,
            choices: .init(layout: .fiveOne, bass: .downstreamReceiver, subwooferCount: 1))
        let before = SystemCapabilityMatrix.evaluate(.widerProgram, arrangement: a)
        XCTAssertTrue(before.text.contains("player or macOS"))
        a.foldDown = ProgramFoldDown(programSourceDeviceUID: "wide", lfe: .foldPlus10dBWithLimiter, headroom: .peakSafe)
        let back = try JSONDecoder().decode(SystemArrangement.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
        XCTAssertTrue(SystemCapabilityMatrix.evaluate(.widerProgram, arrangement: a).text.contains("BS.775"))
        // Older stored arrangements decode without the field.
        a.foldDown = nil
        let old = try JSONDecoder().decode(SystemArrangement.self, from: JSONEncoder().encode(a))
        XCTAssertNil(old.foldDown)
    }

    // MARK: E25 S8a

    private let foldLayouts: [OutputProgramLayout] = [.threeOne, .fiveOne, .sevenOne, .sevenOneFour]

    /// The independent oracle is the ROUTE formula: a sum of gain * input over the lane's entries, in float.
    private func routeSum(_ lane: UnifiedGraphOutputLane, input: [Float]) -> Float {
        lane.entries.reduce(Float(0)) { $0 + $1.gain * input[$1.source] }
    }

    private func tone(channel: Int, frame: Int, rate: Double) -> Float {
        Float(0.5 * sin(2 * Double.pi * (200 + 137 * Double(channel)) * Double(frame) / rate))
    }

    func testDeviceOrderGainsEqualRouteLanesAtEightRates() throws {
        for layout in foldLayouts {
            let f = ProgramFoldDown(programSourceDeviceUID: "wide", lfe: .foldPlus10dBWithLimiter, headroom: .none)
            let m = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: layout, foldDown: f))
            let lanes = try XCTUnwrap(m.outputLanes(firstLane: 0))
            let gains = try XCTUnwrap(m.deviceOrderGains(streamRoles: layout.roles))
            for rate in rates {
                for frame in stride(from: 0, to: 4096, by: 61) {
                    let input = (0..<layout.roles.count).map { tone(channel: $0, frame: frame, rate: rate) }
                    let l = zip(gains.left, input).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    let r = zip(gains.right, input).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    XCTAssertEqual(l, routeSum(lanes[0], input: input), accuracy: 1e-6, "\(layout) \(rate)")
                    XCTAssertEqual(r, routeSum(lanes[1], input: input), accuracy: 1e-6, "\(layout) \(rate)")
                }
            }
        }
    }

    func testDeviceOrderGainsFollowAReorderedStreamAndRefuseMismatches() throws {
        let m = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: .fiveOne, foldDown: ProgramFoldDown(programSourceDeviceUID: "w")))
        let reordered = Array(OutputProgramLayout.fiveOne.roles.reversed())
        let gains = try XCTUnwrap(m.deviceOrderGains(streamRoles: reordered))
        for (i, role) in reordered.enumerated() {
            XCTAssertEqual(gains.left[i], Float(m.gain(feed: 0, role: role)))
            XCTAssertEqual(gains.right[i], Float(m.gain(feed: 1, role: role)))
        }
        XCTAssertNil(m.deviceOrderGains(streamRoles: Array(reordered.dropLast())))
        XCTAssertNil(m.deviceOrderGains(streamRoles: Array(reordered.dropLast()) + [reordered[0]]), "duplicate role")
        XCTAssertNil(m.deviceOrderGains(streamRoles: Array(reordered.dropLast()) + [.topRearLeft]), "foreign role")
        for role in OutputProgramRole.allCases {
            XCTAssertEqual(OutputProgramRole(realtime: role.realtimeCType), role)
        }
    }

    func testProtectionMergeTakesTheStricterOfEachSetting() throws {
        let f = ProgramFoldDown(programSourceDeviceUID: "w", lfe: .foldPlus10dBWithLimiter, headroom: .none)
        let m = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: .fiveOne, foldDown: f))
        // User limiter off: the fold supplies its own settings.
        let off = DynamicsConfiguration().mergingFoldProtection(m)
        XCTAssertTrue(off.limiter.enabled)
        XCTAssertEqual(off.limiter.ceilingDB, -1)
        XCTAssertTrue(off.limiter.truePeakGuardEnabled)
        XCTAssertEqual(off.oversampling, .four)
        XCTAssertEqual(off.limiter.attackMs, 1)
        XCTAssertEqual(off.limiter.releaseMs, 100)
        XCTAssertEqual(off.limiter.lookAheadMs, 1)
        XCTAssertNoThrow(try off.limiter.validate())
        // User limiter on with a lower ceiling and their own times: theirs are kept.
        var user = DynamicsConfiguration()
        user.limiter.enabled = true
        user.limiter.ceilingDB = -3
        user.limiter.attackMs = 5
        user.limiter.releaseMs = 200
        user.limiter.lookAheadMs = 4
        user.limiter.truePeakGuardEnabled = false
        let merged = user.mergingFoldProtection(m)
        XCTAssertEqual(merged.limiter.ceilingDB, -3)
        XCTAssertEqual(merged.limiter.attackMs, 5)
        XCTAssertEqual(merged.limiter.releaseMs, 200)
        XCTAssertEqual(merged.limiter.lookAheadMs, 4)
        XCTAssertTrue(merged.limiter.truePeakGuardEnabled)
        // A looser user ceiling is tightened to -1.
        user.limiter.ceilingDB = -0.2
        XCTAssertEqual(user.mergingFoldProtection(m).limiter.ceilingDB, -1)
        // No fold, or a matrix that needs no limiter, changes nothing.
        XCTAssertEqual(user.mergingFoldProtection(nil), user)
        var safe = f
        safe.headroom = .peakSafe
        let safeMatrix = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: .fiveOne, foldDown: safe))
        XCTAssertEqual(user.mergingFoldProtection(safeMatrix), user)
        // Both protection snapshots build at every rate.
        for rate in rates { XCTAssertNoThrow(try off.makeProtectionSnapshot(sampleRate: rate)) }
    }

    func testBuildDecisionWaitsRefusesAndNeverUsesAnotherDevice() throws {
        let plan = try XCTUnwrap(ProgramFoldDownPlan(layout: .fiveOne, foldDown: ProgramFoldDown(programSourceDeviceUID: "wide")))
        let wide = device("wide", channels: 6)
        XCTAssertEqual(ProgramFoldDownPlan.buildDecision(plan: plan, availableDevices: [wide], sampleRate: 96_000), .tapSource(wide))
        XCTAssertEqual(ProgramFoldDownPlan.buildDecision(plan: nil, availableDevices: [wide], sampleRate: 96_000), .standard)
        // Missing source: wait for the same UID, even with another six-channel device present.
        XCTAssertEqual(
            ProgramFoldDownPlan.buildDecision(plan: plan, availableDevices: [device("other", channels: 6)], sampleRate: 48_000),
            .waitForSource(uid: "wide"))
        // The same UID returning resolves to the tap again.
        XCTAssertEqual(
            ProgramFoldDownPlan.buildDecision(plan: plan, availableDevices: [device("other", channels: 6), wide], sampleRate: 48_000),
            .tapSource(wide))
        XCTAssertEqual(
            ProgramFoldDownPlan.buildDecision(plan: plan, availableDevices: [device("wide", channels: 8)], sampleRate: 48_000),
            .refuse(.channelCountMismatch(expected: 6, actual: 8)))
        let slow = device("wide", channels: 6, max: 96_000)
        XCTAssertEqual(
            ProgramFoldDownPlan.buildDecision(plan: plan, availableDevices: [slow], sampleRate: 192_000),
            .refuse(.sampleRateUnsupported(192_000)))
        for e in [ProgramFoldDownError.sourceUnavailable(uid: "x"), .channelCountMismatch(expected: 6, actual: 8),
                  .sampleRateUnsupported(192_000), .sourceChannelLayoutUnresolved, .incompatibleOutput("y")] {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
        XCTAssertNil(ProgramFoldDownPlan(layout: .stereo, foldDown: ProgramFoldDown(programSourceDeviceUID: "wide")))
        XCTAssertNil(ProgramFoldDownPlan(layout: .fiveOne, foldDown: ProgramFoldDown()))
        XCTAssertNotNil(ProgramFoldDownPlan.incompatibility(sameDeviceOrAggregateOutput: true, headphoneProfileEnabled: false))
        XCTAssertNotNil(ProgramFoldDownPlan.incompatibility(sameDeviceOrAggregateOutput: false, headphoneProfileEnabled: true))
        XCTAssertNil(ProgramFoldDownPlan.incompatibility(sameDeviceOrAggregateOutput: false, headphoneProfileEnabled: false))
    }

    /// Full-scale correlated 5.1 with the LFE at +10 dB and headroom `.none`: the merged limiter (ceiling -1 dB with
    /// the true-peak guard) is configured, so the snapshot the graph runs bounds the output to -1 dBFS.
    func testFullScaleCorrelatedFiveOneWithLFEBoostGetsAMinus1dBTruePeakLimiter() throws {
        let f = ProgramFoldDown(programSourceDeviceUID: "w", lfe: .foldPlus10dBWithLimiter, headroom: .none)
        let m = try XCTUnwrap(ProgramFoldDownCompiler.compile(layout: .fiveOne, foldDown: f))
        XCTAssertGreaterThan(m.left.absoluteSum, 1, "the unlimited fold exceeds full scale")
        let merged = DynamicsConfiguration().mergingFoldProtection(m)
        for rate in rates {
            let snapshot = try merged.makeProtectionSnapshot(sampleRate: rate)
            XCTAssertTrue(snapshot.limiterEnabled)
            XCTAssertEqual(snapshot.effectiveFactor, N60OversamplingFactor4x)
        }
    }
}
