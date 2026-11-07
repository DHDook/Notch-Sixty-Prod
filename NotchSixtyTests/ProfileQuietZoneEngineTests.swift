import CoreAudio
import XCTest
@testable import NotchSixty

/// E26 S7b2b: the engine's profile-session branch of `replaceActiveQuietZoneRuntimeTarget` (class A: two mains plus one
/// sub output). Hardware-free: a real bridge and graph host with the Quiet Zone feed behind the engine's test seam.
@MainActor
final class ProfileQuietZoneEngineTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private var bass: BassManagementConfiguration {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.physicalOutputMode = .mainsSub
        return bass
    }

    private func makeEngine(rate: Double, hosted: Bool) throws -> (AudioIOEngine, CoreAudioNChannelTransportSession) {
        let plan = LiveNChannelOutputRoutePlan(
            programLayout: .stereo, orderedDeviceUIDs: ["fixture"], referenceDeviceUID: "fixture",
            physicalChannelCount: 3, programPhysicalChannels: [0, 1], subwooferPhysicalChannels: [2],
            subwooferCount: 1, bassManagementEnabled: true, speakerCalibrations: [:], subwooferCalibrations: [nil])
        let render = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: plan, sampleRate: rate, gainConfiguration: DSPGainConfiguration(), bassManagementConfiguration: bass)
        let labels: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
        let descriptions = labels.map { AudioChannelDescription(mChannelLabel: $0, mChannelFlags: [], mCoordinates: (0, 0, 0)) }
        var inputMap = N60ProgramInputMap()
        XCTAssertTrue(descriptions.withUnsafeBufferPointer {
            N60ProgramInputMapCompile($0.baseAddress!, UInt32($0.count), render.programLayout, &inputMap)
        })
        let configuration = try UnifiedGraphTranslator.nChannelEligibility(
            routePlan: plan, sampleRate: rate, gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: bass, ancHostFeed: hosted).get()
        let splitter = hosted ? try bass.makeSpeakerBusSplitterSnapshot(sampleRate: rate) : nil
        let device = AudioOutputDevice(
            deviceID: 77, uid: "fixture", name: "Fixture", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)])
        let session = try CoreAudioNChannelTransportSession(
            testingSelectedOutput: device, routePlan: plan, renderGraph: render, inputMap: inputMap, sampleRate: rate,
            unifiedGraphConfiguration: configuration, ancFeedSplitter: splitter)
        let engine = AudioIOEngine()
        engine.unifiedGraphEnabled = true
        try engine.replaceBassManagementConfiguration(bass)
        var gain = DSPGainConfiguration()
        gain.headroomAttenuationDB = -12  // the planner reserves anti-noise headroom from this
        try engine.replaceGainConfiguration(gain)
        try engine.installTestingNChannelSession(session)
        return (engine, session)
    }

    private func target(_ generation: UInt64?) -> ActiveQuietZoneRuntimeTarget {
        ActiveQuietZoneRuntimeTarget(
            tones: [ActiveQuietZoneRuntimeTone(
                frequencyHz: 60, leftOutput: ActiveQuietZoneComplex(real: 0.001, imaginary: 0), rightOutput: .zero)],
            transitionMilliseconds: 3_000, armGeneration: generation)
    }

    func testAuthorisationFollowsTheArmTokenAtEveryRate() throws {
        for rate in Self.rates {
            let (engine, session) = try makeEngine(rate: rate, hosted: true)
            defer { engine.removeTestingNChannelSession() }
            XCTAssertTrue(session.hostsQuietZone, "rate \(rate)")
            XCTAssertTrue(engine.activeQuietZoneProfileRuntimeAvailable)
            XCTAssertFalse(session.quietZoneInjectAuthorised, "nothing authorises on session start (\(rate))")

            XCTAssertThrowsError(try engine.replaceActiveQuietZoneRuntimeTarget(target(nil))) {
                XCTAssertEqual($0 as? ActiveQuietZoneError, .armRevoked)
            }
            XCTAssertFalse(session.quietZoneInjectAuthorised, "a target without a token never authorises")

            try engine.replaceActiveQuietZoneRuntimeTarget(target(engine.liveTreatmentGeneration))
            XCTAssertTrue(session.quietZoneInjectAuthorised, "an armed target authorises (\(rate))")
            XCTAssertTrue(engine.activeQuietZoneRuntimeTarget.active)

            engine.revokeLiveTreatmentArm()
            XCTAssertFalse(session.quietZoneInjectAuthorised, "revoking the arm revokes ANC_INJECT (\(rate))")
            XCTAssertFalse(engine.activeQuietZoneRuntimeTarget.active, "revoking clears the engine target (\(rate))")

            XCTAssertThrowsError(try engine.replaceActiveQuietZoneRuntimeTarget(target(engine.liveTreatmentGeneration &- 1))) {
                XCTAssertEqual($0 as? ActiveQuietZoneError, .armRevoked)
            }
            try engine.replaceActiveQuietZoneRuntimeTarget(target(engine.liveTreatmentGeneration))
            XCTAssertTrue(session.quietZoneInjectAuthorised)
            try engine.clearActiveQuietZoneRuntimeTarget()
            XCTAssertFalse(session.quietZoneInjectAuthorised, "a fade-out target ends the authorisation (\(rate))")
        }
    }

    func testASessionWithoutTheFeedRefusesAnActiveTarget() throws {
        let (engine, session) = try makeEngine(rate: 48_000, hosted: false)
        defer { engine.removeTestingNChannelSession() }
        XCTAssertFalse(session.hostsQuietZone)
        XCTAssertFalse(engine.activeQuietZoneProfileRuntimeAvailable)
        XCTAssertThrowsError(try engine.replaceActiveQuietZoneRuntimeTarget(target(engine.liveTreatmentGeneration))) {
            XCTAssertEqual($0 as? ActiveQuietZoneError, .runtimeUnsupported)
        }
        XCTAssertFalse(session.quietZoneInjectAuthorised)
    }

    /// G20: the keeper polls at its own, faster rate, so a guard trip reaches the feed within a poll.
    func testLeaseKeeperPollsFasterThanItRenews() async throws {
        var polls = 0, renewals = 0
        let keeper = ActiveQuietZoneLeaseKeeper(
            renewIntervalSeconds: 0.2, leaseSeconds: 3, pollIntervalSeconds: 0.01,
            poll: { polls += 1 }, renew: { _ in renewals += 1 }, release: {})
        keeper.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        keeper.stop()
        XCTAssertGreaterThan(polls, 5, "polled well inside one renewal interval")
        XCTAssertLessThanOrEqual(renewals, 3)
        XCTAssertEqual(ActiveQuietZoneLeaseKeeper.renewIntervalSeconds, 1)
    }
}
