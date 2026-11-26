import XCTest
@testable import NotchSixty

/// E12 S28b1: the single audition override slot (engine half of the Blind Listening system sides).
@MainActor
final class AuditionOverrideTests: XCTestCase {
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func grid(_ db: Double) throws -> RoomCorrectionGridDesign {
        let frequencies = try RoomCorrectionCore.gridFrequencies()
        return RoomCorrectionGridDesign(
            correctionDB: frequencies.map { $0 < 1_000 ? db : 0 },
            correctionPhaseRadians: [Double](repeating: 0, count: frequencies.count),
            coherence: [Double](repeating: 0, count: frequencies.count), seatContribution: [])
    }

    private func install(db: Double, mode: RoomCorrectionLatencyMode = .video) throws -> RoomCorrectionLaneInstall {
        let design = RoomCorrectionMultiLaneDesign(
            latencyMode: mode, laneCount: 2,
            lanes: [RoomCorrectionLaneDesign(lane: 0, grid: try grid(db)), RoomCorrectionLaneDesign(lane: 1, grid: try grid(db))])
        return RoomCorrectionLaneInstall(name: "P", design: design, programLaneCount: 2, subwooferCount: 0)
    }

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_301, uid: "audition-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 6)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "audition-out")
        return engine
    }

    private func program(_ engine: AudioIOEngine, rate: Double, inputs: AudioIOEngine.LiveGraphInputs) throws -> UnifiedGraphProgramDSP? {
        try engine.makeUnifiedProgramDSP(
            sampleRate: rate, shape: try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontLeft, .frontRight])),
            virtualSpeakers: false, subwooferCount: 0, inputs: inputs)
    }

    private func storedInputs(_ engine: AudioIOEngine, lanes: RoomCorrectionLaneInstall) -> AudioIOEngine.LiveGraphInputs {
        var inputs = engine.currentLiveGraphInputs
        inputs.room = RoomCorrectionConfiguration(enabled: true, lanes: lanes)
        return inputs
    }

    func testOverrideThenClearBuildsTheStoredGraphAndLeavesConfigurationUntouched() throws {
        let profile = try install(db: -2)
        for rate in Self.rates {
            let engine = try engine(rate: rate)
            let inputs = storedInputs(engine, lanes: profile)
            let base = try program(engine, rate: rate, inputs: inputs)
            let bassBefore = engine.bassManagementConfiguration
            var bass = BassManagementConfiguration()
            bass.enabled = true
            engine.auditionOverride = AuditionOverride(
                roomCorrection: .off, bassManagement: bass, outputGainDB: -3, gain: 0.5, latencyPadFrames: 12)
            let during = try program(engine, rate: rate, inputs: inputs)
            XCTAssertNotEqual(during, base, "\(rate)")
            engine.auditionOverride = nil
            XCTAssertEqual(try program(engine, rate: rate, inputs: inputs), base, "\(rate)")
            XCTAssertEqual(engine.bassManagementConfiguration, bassBefore, "\(rate)")
            XCTAssertEqual(engine.renderBassManagementConfiguration(), bassBefore, "\(rate)")
        }
    }

    func testRoomCorrectionOffDropsLanesAndPadsTheMainsAndTheGainsCompose() throws {
        let profile = try install(db: -2)
        for rate in Self.rates {
            let engine = try engine(rate: rate)
            let inputs = storedInputs(engine, lanes: profile)
            let baseGain = try XCTUnwrap(try program(engine, rate: rate, inputs: inputs)).inputGain
            engine.auditionOverride = AuditionOverride(roomCorrection: .off, outputGainDB: -6, gain: 0.5, latencyPadFrames: 33)
            let off = try XCTUnwrap(try program(engine, rate: rate, inputs: inputs), "\(rate)")
            XCTAssertNil(off.roomLanes, "\(rate)")
            XCTAssertEqual(off.laneDelayFrames, [0: 33, 1: 33], "\(rate)")
            XCTAssertEqual(off.inputGain, baseGain * 0.5 * Float(pow(10.0, -6.0 / 20.0)), accuracy: 1e-6, "\(rate)")
        }
    }

    func testRoomCorrectionOnAndOffArriveTogetherOnAnImpulse() throws {
        let profile = try install(db: 0)
        for rate in Self.rates {
            let engine = try engine(rate: rate)
            let inputs = storedInputs(engine, lanes: profile)
            let plan = try engine.roomCorrectionRateCache.plan(for: profile.design, sampleRate: rate)
            func peak(_ override: AuditionOverride?) throws -> (index: Int, latency: Int) {
                engine.auditionOverride = override
                var configuration = UnifiedGraphTranslator.multichannelConfiguration(sampleRate: rate, programChannels: 2, subwoofers: [])
                configuration.orderPolicy = .canonical
                configuration.programDSP = try program(engine, rate: rate, inputs: inputs)
                let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
                defer { host.release() }
                let frames = 4_096 + Int(plan.declaredLatencyFrames)
                var impulse = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
                impulse[0][0] = 1
                var out = try host.processOffline(input: impulse, frames: frames)[0]
                // Skip the warm-up tail of the first block by reading the whole response.
                let index = out.indices.max { abs(out[$0]) < abs(out[$1]) } ?? 0
                out.removeAll()
                return (index, Int(host.latencyFrames))
            }
            // The pad is the built graph's latency difference (convolver engine latency plus declared), not the declared alone.
            let on = try peak(nil)
            XCTAssertGreaterThanOrEqual(on.latency, Int(plan.declaredLatencyFrames), "\(rate)")
            let off = try peak(AuditionOverride(roomCorrection: .off, latencyPadFrames: UInt32(on.latency)))
            XCTAssertEqual(on.index, off.index, "\(rate)")
        }
    }

    func testBassManagementOverrideReachesTheGraphBuildAndClears() throws {
        for rate in Self.rates {
            let engine = try engine(rate: rate)
            var stored = BassManagementConfiguration()
            stored.enabled = true
            stored.frequencyHz = 80
            engine.commitBassManagementConfiguration(stored)
            var other = stored
            other.frequencyHz = 120
            engine.auditionOverride = AuditionOverride(bassManagement: other)
            XCTAssertEqual(engine.renderBassManagementConfiguration().frequencyHz, 120, "\(rate)")
            XCTAssertEqual(engine.renderBassManagementConfiguration(stored).frequencyHz, 120, "\(rate)")
            var off = stored
            off.enabled = false
            engine.auditionOverride = AuditionOverride(bassManagement: off)
            XCTAssertFalse(engine.renderBassManagementConfiguration().enabled, "\(rate)")
            engine.auditionOverride = nil
            XCTAssertEqual(engine.renderBassManagementConfiguration(), stored, "\(rate)")
            XCTAssertEqual(engine.bassManagementConfiguration, stored, "\(rate)")
        }
    }

    func testRefusalsLeaveTheSlotEmpty() throws {
        let engine = try engine(rate: 48_000)
        for bad in [AuditionOverride(gain: 1.5), AuditionOverride(gain: 0), AuditionOverride(outputGainDB: .nan)] {
            XCTAssertThrowsError(try engine.setAuditionOverride(bad)) { XCTAssertEqual($0 as? AuditionOverrideError, .malformed) }
        }
        XCTAssertThrowsError(try engine.setAuditionOverride(
            AuditionOverride(roomCorrection: .off, latencyPadFrames: N60_GRAPH_MAX_DELAY_FRAMES + 1))) {
            XCTAssertEqual($0 as? AuditionOverrideError, .padTooLong)
        }
        // No running session: refused with the plain reason, never half applied.
        XCTAssertThrowsError(try engine.setAuditionOverride(AuditionOverride(roomCorrection: .off)))
        XCTAssertNil(engine.auditionOverride)
        XCTAssertNoThrow(try engine.setAuditionOverride(nil))
    }

    func testSystemDomainsAreRefusedWhileTreatmentRunsOrASplitterIsActive() throws {
        let engine = try engine(rate: 48_000)
        XCTAssertNil(engine.auditionSystemDomainsRefusal)
        engine.commitActiveQuietZoneRuntimeTarget(ActiveQuietZoneRuntimeTarget(
            tones: [ActiveQuietZoneRuntimeTone(
                frequencyHz: 60, leftOutput: ActiveQuietZoneComplex(real: 0.001, imaginary: 0), rightOutput: .zero)],
            transitionMilliseconds: 3_000, armGeneration: engine.liveTreatmentGeneration))
        XCTAssertNotNil(engine.auditionSystemDomainsRefusal)
        for system in [AuditionOverride(roomCorrection: .off), AuditionOverride(bassManagement: BassManagementConfiguration()),
                       AuditionOverride(outputGainDB: -1)] {
            XCTAssertThrowsError(try engine.setAuditionOverride(system)) {
                XCTAssertEqual($0 as? AuditionOverrideError, .unavailable(engine.auditionSystemDomainsRefusal ?? ""))
            }
        }
        engine.commitActiveQuietZoneRuntimeTarget(ActiveQuietZoneRuntimeTarget(tones: [], transitionMilliseconds: 100))
        XCTAssertNil(engine.auditionSystemDomainsRefusal)
        engine.commitMultiOutputRoutingConfiguration(MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [.leftLow, .rightLow, .leftHigh, .rightHigh].enumerated().map { index, bus in
                SpeakerOutputRoute(name: bus.displayName, bus: bus,
                                   destination: PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: UInt32(index)))
            }))
        XCTAssertNotNil(engine.auditionSystemDomainsRefusal)
    }

    func testStopClearsTheSlot() throws {
        let engine = try engine(rate: 48_000)
        engine.auditionOverride = AuditionOverride(roomCorrection: .off)
        engine.tearDownTransport(fadeOut: false)
        XCTAssertNil(engine.auditionOverride)
    }
}
