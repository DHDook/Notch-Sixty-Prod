import CoreAudio
import XCTest
@testable import NotchSixty

/// E6 S9c2 (folds S9b2): the live setters run against a hardware-free running session (a real bridge and graph
/// host behind the engine's test seam). A rejected live edit leaves every piece of state unchanged, a refused graph
/// keeps the old graph rendering, and with the flag off nothing is live.
@MainActor
final class LiveSessionFixtureTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private static let labels: [AudioChannelLabel] = [
        kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
        kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
    ]

    private var bassOn: BassManagementConfiguration {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        return bass
    }

    private func device(_ rate: Double) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: 77, uid: "fixture", name: "Fixture", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)])
    }

    private func routePlan(bass: Bool) -> LiveNChannelOutputRoutePlan {
        LiveNChannelOutputRoutePlan(
            programLayout: .fiveOne, orderedDeviceUIDs: ["fixture"], referenceDeviceUID: "fixture",
            physicalChannelCount: 7,
            programPhysicalChannels: [5, 4, 3, bass ? N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED : 2, 1, 0],
            subwooferPhysicalChannels: [6], subwooferCount: 1, bassManagementEnabled: bass,
            speakerCalibrations: [:], subwooferCalibrations: [nil])
    }

    /// An engine in `.running` with a graph-rendered 5.1 session, or one rendered by the legacy core.
    private func makeEngine(rate: Double, bass: Bool, graph: Bool = true, flag: Bool = true) throws
        -> (AudioIOEngine, CoreAudioNChannelTransportSession) {
        let plan = routePlan(bass: bass)
        let bassConfiguration = bass ? bassOn : BassManagementConfiguration()
        let renderGraph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: plan, sampleRate: rate, gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: bassConfiguration)
        let descriptions = Self.labels.map {
            AudioChannelDescription(mChannelLabel: $0, mChannelFlags: [], mCoordinates: (0, 0, 0))
        }
        var inputMap = N60ProgramInputMap()
        XCTAssertTrue(descriptions.withUnsafeBufferPointer {
            N60ProgramInputMapCompile($0.baseAddress!, UInt32($0.count), renderGraph.programLayout, &inputMap)
        })
        let configuration = graph ? UnifiedGraphTranslator.nChannelConfiguration(
            routePlan: plan, sampleRate: rate, gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: bassConfiguration) : nil
        let session = try CoreAudioNChannelTransportSession(
            testingSelectedOutput: device(rate), routePlan: plan, renderGraph: renderGraph, inputMap: inputMap,
            sampleRate: rate, unifiedGraphConfiguration: configuration)
        let engine = AudioIOEngine()
        engine.unifiedGraphEnabled = flag
        if bass { try engine.replaceBassManagementConfiguration(bassOn) }
        try engine.installTestingNChannelSession(session)
        return (engine, session)
    }

    func testRejectedLiveEditLeavesStateAndGraphUnchangedAtEveryRate() throws {
        for rate in Self.rates {
            let (engine, session) = try makeEngine(rate: rate, bass: true)
            XCTAssertTrue(session.unifiedGraphActive, "rate \(rate)")
            XCTAssertTrue(engine.liveGraphEditsAvailable, "rate \(rate)")
            let host = try XCTUnwrap(session.unifiedGraphReadback)
            let specBefore = host.spec
            let bassBefore = engine.bassManagementConfiguration

            // A 48 dB/oct crossover is something the graph cannot reproduce: the edit is refused by name.
            var refused = bassBefore
            refused.topology = .linkwitzRiley48
            XCTAssertThrowsError(try engine.replaceBassManagementConfiguration(refused), "rate \(rate)") {
                guard case LiveNChannelTransportError.unifiedGraphRejected(let reason) = $0 else {
                    return XCTFail("wrong error \($0)")
                }
                XCTAssertEqual(reason, .nonLR4Crossover, "rate \(rate)")
            }
            XCTAssertEqual(engine.bassManagementConfiguration, bassBefore, "rate \(rate)")
            XCTAssertEqual(host.spec, specBefore, "rate \(rate)")

            // A value outside the crossover range is refused before anything runs.
            var outOfRange = bassBefore
            outOfRange.frequencyHz = 5
            XCTAssertThrowsError(try engine.replaceBassManagementConfiguration(outOfRange), "rate \(rate)")
            XCTAssertEqual(engine.bassManagementConfiguration, bassBefore, "rate \(rate)")
            XCTAssertEqual(host.spec, specBefore, "rate \(rate)")

            // A valid retune is live: the state commits and the graph moves.
            var retuned = bassBefore
            retuned.frequencyHz = bassBefore.frequencyHz + 20
            XCTAssertNoThrow(try engine.replaceBassManagementConfiguration(retuned), "rate \(rate)")
            XCTAssertEqual(engine.bassManagementConfiguration, retuned, "rate \(rate)")
            engine.removeTestingNChannelSession()
        }
    }

    func testStageBudgetRefusalKeepsTheOldGraphRendering() throws {
        let rate = 96_000.0
        let (engine, session) = try makeEngine(rate: rate, bass: true)
        let host = try XCTUnwrap(session.unifiedGraphReadback)
        let before = host.spec
        var over = before
        for extra in 0..<(UnifiedGraphProgramDSP.maxStages - before.stages.count + 1) {
            over.stages.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_GAIN.rawValue, stageId: 6_000 + UInt32(extra), laneA: N60_LANE_ALL,
                laneB: 0, laneMask: 0, capacityFrames: 0, params: [1]))
        }
        XCTAssertThrowsError(try host.apply(over))
        XCTAssertEqual(host.spec, before)
        let silence = [[Float]](repeating: [Float](repeating: 0.1, count: 256), count: Int(host.inputChannels))
        XCTAssertNoThrow(try host.processOffline(input: silence, frames: 256))
        engine.removeTestingNChannelSession()
    }

    func testFlagOffAndLegacySessionsStayRestartOnly() throws {
        let rate = 48_000.0
        var changed = bassOn
        changed.frequencyHz += 20

        let (flagOff, offSession) = try makeEngine(rate: rate, bass: true, flag: false)
        XCTAssertFalse(flagOff.liveGraphEditsAvailable)
        XCTAssertThrowsError(try flagOff.replaceBassManagementConfiguration(changed)) {
            guard case LiveNChannelTransportError.configurationChangeRequiresRestart = $0 else {
                return XCTFail("wrong error \($0)")
            }
        }
        XCTAssertEqual(flagOff.bassManagementConfiguration, bassOn)
        flagOff.removeTestingNChannelSession()
        _ = offSession

        let (legacy, legacySession) = try makeEngine(rate: rate, bass: true, graph: false)
        XCTAssertFalse(legacySession.unifiedGraphActive)
        XCTAssertFalse(legacy.liveGraphEditsAvailable)
        XCTAssertThrowsError(try legacy.replaceBassManagementConfiguration(changed))
        XCTAssertEqual(legacy.bassManagementConfiguration, bassOn)
        legacy.removeTestingNChannelSession()
    }

    func testBassEnabledToggleStillRestartsEvenWhenGraphIsLive() throws {
        let (engine, _) = try makeEngine(rate: 48_000, bass: true)
        var off = bassOn
        off.enabled = false
        XCTAssertThrowsError(try engine.replaceBassManagementConfiguration(off)) {
            guard case LiveNChannelTransportError.configurationChangeRequiresRestart = $0 else {
                return XCTFail("wrong error \($0)")
            }
        }
        XCTAssertEqual(engine.bassManagementConfiguration, bassOn)
        engine.removeTestingNChannelSession()
    }
}
