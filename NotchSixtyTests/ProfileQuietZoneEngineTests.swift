import CoreAudio
import XCTest
@testable import NotchSixty

/// Shared hardware-free class A rig: a real bridge and graph host with the Quiet Zone feed behind the engine's seam.
@MainActor
enum ProfileQuietZoneFixture {
    static var bass: BassManagementConfiguration {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.physicalOutputMode = .mainsSub
        return bass
    }

    static func device(rate: Double) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: 77, uid: "fixture", name: "Fixture", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)])
    }

    private struct Catalog: OutputDeviceCataloging {
        let devices: [AudioOutputDevice]
        func outputDevices() throws -> [AudioOutputDevice] { devices }
    }

    /// `ceiling` lowers the graph guards' output ceiling so a test can trip them with a small tone.
    /// `lowLatency` pre-applies the Quiet Zone output profile, so the controller's Turn On does not schedule the planned
    /// reconfiguration that would rebuild (and, without hardware, drop) the seam session.
    static func make(rate: Double, hosted: Bool, ceiling: Float? = nil, lowLatency: Bool = false) throws -> (AudioIOEngine, CoreAudioNChannelTransportSession) {
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
        var configuration = try UnifiedGraphTranslator.nChannelEligibility(
            routePlan: plan, sampleRate: rate, gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: bass, ancHostFeed: hosted).get()
        if let ceiling { configuration.ancActuators?.outputCeiling = ceiling }
        let splitter = hosted ? try bass.makeSpeakerBusSplitterSnapshot(sampleRate: rate) : nil
        let output = device(rate: rate)
        let session = try CoreAudioNChannelTransportSession(
            testingSelectedOutput: output, routePlan: plan, renderGraph: render, inputMap: inputMap, sampleRate: rate,
            unifiedGraphConfiguration: configuration, ancFeedSplitter: splitter)
        let engine = AudioIOEngine(deviceCatalog: Catalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: output.uid)
        engine.unifiedGraphEnabled = true
        try engine.replaceBassManagementConfiguration(bass)
        var gain = DSPGainConfiguration()
        gain.headroomAttenuationDB = -12  // the planner reserves anti-noise headroom from this
        try engine.replaceGainConfiguration(gain)
        if lowLatency { engine.setLowLatencyOutputProfile(true) }
        try engine.installTestingNChannelSession(session)
        return (engine, session)
    }
}

/// E26 S7b2b: the engine's profile-session branch of `replaceActiveQuietZoneRuntimeTarget` (class A: two mains plus one
/// sub output). Hardware-free: a real bridge and graph host with the Quiet Zone feed behind the engine's test seam.
@MainActor
final class ProfileQuietZoneEngineTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func makeEngine(rate: Double, hosted: Bool, ceiling: Float? = nil) throws -> (AudioIOEngine, CoreAudioNChannelTransportSession) {
        try ProfileQuietZoneFixture.make(rate: rate, hosted: hosted, ceiling: ceiling)
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

    /// G26: the engine's reference passthroughs and the tonal controller's gate follow the profile session when it
    /// hosts the feed, and stay unavailable when it does not.
    func testReferencePassthroughsAndGateFollowTheProfileSession() throws {
        for rate in [48_000.0, 384_000.0] {
            let (engine, session) = try makeEngine(rate: rate, hosted: true)
            defer { engine.removeTestingNChannelSession() }
            XCTAssertTrue(engine.activeQuietZoneRuntimeAvailable)
            XCTAssertTrue(engine.ambientPlaybackReferenceAvailable)
            XCTAssertTrue(engine.activeQuietZoneReferenceAvailable)
            XCTAssertEqual(engine.ambientPlaybackReferenceSampleRate, rate)
            XCTAssertEqual(engine.activeQuietZoneReferenceSampleRate, rate)

            engine.setAmbientPlaybackReferenceDemand(true)
            engine.setActiveQuietZoneReferenceDemand(true)
            XCTAssertEqual(session.ambientReferenceSnapshot()?.enabled, true)
            XCTAssertEqual(engine.activeQuietZoneReferenceSnapshot()?.enabled, true)
            XCTAssertTrue(engine.readAmbientPlaybackReferenceFrames(maximumFrames: 64).isEmpty)
            engine.setAmbientPlaybackReferenceDemand(false)
            engine.setActiveQuietZoneReferenceDemand(false)
            XCTAssertEqual(session.ambientReferenceSnapshot()?.enabled, false)
        }
        let (plain, _) = try makeEngine(rate: 48_000, hosted: false)
        defer { plain.removeTestingNChannelSession() }
        XCTAssertFalse(plain.activeQuietZoneRuntimeAvailable)
        XCTAssertFalse(plain.ambientPlaybackReferenceAvailable)
        XCTAssertNil(plain.ambientPlaybackReferenceSampleRate)
        XCTAssertNil(plain.activeQuietZoneReferenceSnapshot())
    }

    /// G22: a rebuilt session carries a new feed that is disarmed and unauthorised; nothing re-arms it implicitly.
    func testARebuiltSessionStartsDisarmed() throws {
        let (engine, session) = try makeEngine(rate: 48_000, hosted: true)
        try engine.replaceActiveQuietZoneRuntimeTarget(target(engine.liveTreatmentGeneration))
        XCTAssertTrue(session.quietZoneInjectAuthorised)
        engine.removeTestingNChannelSession()
        let (rebuiltEngine, rebuilt) = try makeEngine(rate: 96_000, hosted: true)
        defer { rebuiltEngine.removeTestingNChannelSession() }
        XCTAssertFalse(rebuilt.quietZoneInjectAuthorised)
        XCTAssertFalse(rebuiltEngine.activeQuietZoneRuntimeTarget.active)
    }

    // MARK: S7b2c part 2: guard trips, revoke, latency, sink swap (G20, G21, G27, G29)

    private func peak(_ block: [Float]) -> Float { block.reduce(0) { max($0, abs($1)) } }

    /// Drives blocks (programme silent, so any output is anti-noise) until `condition` or `limit` blocks.
    @discardableResult
    private func drive(_ session: CoreAudioNChannelTransportSession, limit: Int, until condition: () -> Bool) -> Int {
        var blocks = 0
        while blocks < limit, !condition() {
            _ = session.testingRunBlock(frames: 512, programme: 0, outputChannels: 3)
            blocks += 1
        }
        return blocks
    }

    /// G20 and G27: a real graph guard trip is seen by the lease keeper's poll, which fades the feed within 20 ms of
    /// rendered frames; the arm owner then reads the trip count and the revoke ends the authorisation.
    func testGuardTripFadesTheFeedAndTheTripCountRevokesAtEveryRate() throws {
        for rate in Self.rates {
            let (engine, session) = try makeEngine(rate: rate, hosted: true, ceiling: 1.0e-5)
            defer { engine.removeTestingNChannelSession() }
            let baseline = engine.liveTreatmentHowlTripCount
            engine.rearmHowlGuard()
            try engine.replaceActiveQuietZoneRuntimeTarget(target(engine.liveTreatmentGeneration))
            session.renewActiveQuietZoneLease(seconds: 60)
            XCTAssertTrue(session.quietZoneInjectAuthorised)

            let blocks = drive(session, limit: Int(rate * 8 / 512)) { session.howlGuardTripCount > baseline }
            XCTAssertGreaterThan(session.howlGuardTripCount, baseline, "a tone above the ceiling trips the guard (\(rate), \(blocks) blocks)")
            XCTAssertGreaterThan(engine.liveTreatmentHowlTripCount, baseline, "the arm owner sees the trip count move (\(rate))")

            let before = try XCTUnwrap(session.quietZoneFeedStatus())
            session.pollQuietZoneGuards()   // what the lease keeper does every 50 ms
            let polled = try XCTUnwrap(session.quietZoneFeedStatus())
            XCTAssertFalse(polled.armed, "the poll disarms the feed at once (\(rate))")
            var fadeFrames: UInt64 = 0
            var last = polled.gain
            drive(session, limit: 64) {
                let status = session.quietZoneFeedStatus()!
                fadeFrames = status.renderedFrames - before.renderedFrames
                last = status.gain
                return status.gain == 0
            }
            XCTAssertEqual(last, 0, "the feed fades to zero (\(rate))")
            XCTAssertLessThanOrEqual(Double(fadeFrames), rate * 0.020 + 2 * 512, "fade within 20 ms plus a block (\(rate))")

            // G27: the arm owner reacts to the count by revoking; that ends the authorisation and clears the target.
            engine.revokeLiveTreatmentArm()
            XCTAssertFalse(session.quietZoneInjectAuthorised, "a trip leads to a revoke (\(rate))")
            XCTAssertFalse(engine.activeQuietZoneRuntimeTarget.active)
            let silent = session.testingRunBlock(frames: 512, programme: 0, outputChannels: 3)
            XCTAssertEqual(peak(silent), 0, "nothing plays after the revoke (\(rate))")
        }
    }

    /// G21: revoking fades the feed over 20 ms before the graph latch lands; the output returns to the programme alone
    /// with no step larger than the anti-noise level it started from.
    func testRevokeFadesTheFeedWithoutAStep() throws {
        let rate = 48_000.0
        let (engine, session) = try makeEngine(rate: rate, hosted: true)
        defer { engine.removeTestingNChannelSession() }
        let programme: Float = 0.1
        func block() -> [Float] { session.testingRunBlock(frames: 512, programme: programme, outputChannels: 3) }
        func difference(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) } }
        for _ in 0..<40 { _ = block() }
        let baseline = block()

        engine.rearmHowlGuard()  // the controller does this before every arm; a rebuilt graph holds injection until then
        try engine.replaceActiveQuietZoneRuntimeTarget(target(engine.liveTreatmentGeneration))
        session.renewActiveQuietZoneLease(seconds: 60)
        var antiNoise: Float = 0
        for _ in 0..<400 { antiNoise = max(antiNoise, difference(block(), baseline)) }
        XCTAssertGreaterThan(antiNoise, 0, "the anti-noise plays while armed \(String(describing: session.quietZoneFeedStatus()))")

        engine.revokeLiveTreatmentArm()
        XCTAssertFalse(try XCTUnwrap(session.quietZoneFeedStatus()).armed)
        XCTAssertFalse(session.quietZoneInjectAuthorised)
        var previous = antiNoise
        var maxStep: Float = 0
        for _ in 0..<8 {
            let level = difference(block(), baseline)
            maxStep = max(maxStep, abs(level - previous))
            previous = level
        }
        XCTAssertEqual(previous, 0, accuracy: 1e-6, "back to the programme alone after the fade and the latch")
        XCTAssertLessThanOrEqual(maxStep, antiNoise * 1.01, "no step beyond the level the anti-noise started from")
    }

    /// G27: a revoke whose graph publish fails leaves the record consistent with the graph (still authorised, feed silent),
    /// and the next authorisation arms the feed again instead of returning early.
    func testFailedRevokePublishRollsBackAndTheNextArmRecovers() throws {
        let (engine, session) = try makeEngine(rate: 48_000, hosted: true)
        defer { engine.removeTestingNChannelSession() }
        try engine.replaceActiveQuietZoneRuntimeTarget(target(engine.liveTreatmentGeneration))
        session.renewActiveQuietZoneLease(seconds: 60)
        XCTAssertTrue(session.quietZoneInjectAuthorised)

        session.testingRepublishFailure = .configurationChangeRequiresRestart
        XCTAssertThrowsError(try session.setQuietZoneInjectAuthorised(false))
        XCTAssertTrue(session.quietZoneInjectAuthorised, "the record matches the graph, which still holds the old actuators")
        let silenced = try XCTUnwrap(session.quietZoneFeedStatus())
        XCTAssertFalse(silenced.armed, "the feed was disarmed first, so it is silent")
        XCTAssertFalse(silenced.leaseActive)

        // The engine path swallows the failure but still ends its own target.
        engine.revokeLiveTreatmentArm()
        XCTAssertFalse(engine.activeQuietZoneRuntimeTarget.active)
        XCTAssertFalse(session.quietZoneInjectAuthorised, "the retry inside the engine revoke lands")

        // A fresh arm after a failed revoke plays again.
        try engine.replaceActiveQuietZoneRuntimeTarget(target(engine.liveTreatmentGeneration))
        XCTAssertTrue(try XCTUnwrap(session.quietZoneFeedStatus()).armed)

        session.testingRepublishFailure = .configurationChangeRequiresRestart
        XCTAssertThrowsError(try session.setQuietZoneInjectAuthorised(false))
        XCTAssertTrue(session.quietZoneInjectAuthorised)
        try session.setQuietZoneInjectAuthorised(true)
        XCTAssertTrue(try XCTUnwrap(session.quietZoneFeedStatus()).armed, "authorising again arms the silent feed")
    }

    /// G27: the publish lock serialises authorise and revoke; the last call wins and the record never gets ahead of the graph.
    func testConcurrentAuthoriseAndRevokeNeverLeaveAnArmedFeedWithoutAuthorisation() throws {
        let (engine, session) = try makeEngine(rate: 48_000, hosted: true)
        defer { engine.removeTestingNChannelSession() }
        let group = DispatchGroup()
        for i in 0..<40 {
            group.enter()
            DispatchQueue.global().async {
                try? session.setQuietZoneInjectAuthorised(i % 2 == 0)
                group.leave()
            }
        }
        group.wait()
        try session.setQuietZoneInjectAuthorised(false)
        XCTAssertFalse(session.quietZoneInjectAuthorised)
        XCTAssertFalse(try XCTUnwrap(session.quietZoneFeedStatus()).armed)
        let block = session.testingRunBlock(frames: 512, programme: 0, outputChannels: 3)
        XCTAssertEqual(peak(block), 0)
    }

    private final class SinkCounter { var calls = 0; var last: UInt64 = 0 }

    /// G29: the bridge's host-time sink can be swapped while IO is stopped, the new sink runs before the graph, and the
    /// feed's own sink can be restored.
    func testHostTimeSinkSwapRunsBeforeTheGraphAndRestores() throws {
        let (engine, session) = try makeEngine(rate: 48_000, hosted: true)
        defer { engine.removeTestingNChannelSession() }
        let counter = SinkCounter()
        let context = Unmanaged.passUnretained(counter).toOpaque()
        session.testingSwapHostTimeSink({ context, hostTime in
            let counter = Unmanaged<SinkCounter>.fromOpaque(context!).takeUnretainedValue()
            counter.calls += 1
            counter.last = hostTime
        }, context: context)
        _ = session.testingRunBlock(frames: 512, programme: 0, outputChannels: 3, hostTime: 123_456)
        _ = session.testingRunBlock(frames: 512, programme: 0, outputChannels: 3, hostTime: 654_321)
        XCTAssertEqual(counter.calls, 2)
        XCTAssertEqual(counter.last, 654_321)

        session.testingSwapHostTimeSink(nil, context: nil)
        _ = session.testingRunBlock(frames: 512, programme: 0, outputChannels: 3, hostTime: 999)
        XCTAssertEqual(counter.calls, 2, "the swapped-out sink is no longer called")
        XCTAssertEqual(try XCTUnwrap(session.quietZoneFeedStatus()).renderedFrames, 3 * 512, "the graph still ran every block")
    }
}

/// E26 S7b2c part 2 (G16): class A (two mains plus one sub output) from the Quiet Zone Turn On to the engine and the
/// feed, through the real `ActiveQuietZoneController`, `LiveTreatmentArm`, `AudioIOEngine` and the profile session.
/// The hardware edge is the only fake: a hardware-free session behind the engine's test seam.
@MainActor
final class ClassAEndToEndTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private struct InputCatalog: InputDeviceCataloging {
        let devices: [AudioInputDevice]
        func inputDevices() throws -> [AudioInputDevice] { devices }
    }

    private struct Permission: MicrophonePermissionRequesting, Sendable {
        func currentStatus() -> MicrophonePermissionStatus { .authorized }
        func requestAccess() async -> MicrophonePermissionStatus { .authorized }
    }

    /// A silent microphone monitor: the controller's observation demand starts it, nothing reads real hardware.
    private final class SilentMonitor: AmbientMonitorTransporting {
        let sampleRate: Double
        init(rate: Double) { sampleRate = rate }
        func start() throws {}
        func stop() {}
        func readAvailableFrames(maximumFrames: Int) throws -> [Float] { [] }
        func discardBufferedFrames() {}
    }

    private func z(_ r: Double, _ i: Double = 0) -> ActiveQuietZoneComplex { ActiveQuietZoneComplex(real: r, imaginary: i) }

    private func plant(rate: Double) -> BassPlantMap {
        BassPlantMap(bands: [40.0, 50, 63].map { hz in
            let angle = -2 * Double.pi * hz * (0.004 * rate).rounded() / rate
            let sub = z(cos(angle), sin(angle))
            return QuietZoneVirtualSeatBand(
                frequencyHz: hz, sourceToReference: z(1), sourceToListener: z(0.02),
                leftSecondaryAtListener: sub, rightSecondaryAtListener: sub,
                leftLeakageAtReference: sub * z(0.2), rightLeakageAtReference: sub * z(0.2), measuredCoherence: 0.98)
        })
    }

    /// A class A controller on an engine that runs the hosted profile session, measured and ready.
    private func makeRig(rate: Double) throws -> (ActiveQuietZoneController, AudioIOEngine, CoreAudioNChannelTransportSession) {
        let (engine, session) = try ProfileQuietZoneFixture.make(rate: rate, hosted: true, lowLatency: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            engine.removeTestingNChannelSession()
            try? FileManager.default.removeItem(at: root)
        }
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        let arrangement = SystemSetupArrangementPlanner.arrangement(
            deviceUID: "fixture", detectedChannelCount: 3, channelsInUse: 3,
            choices: .init(layout: .stereo, bass: .dspToSubOutputs, subwooferCount: 1, receiverBass: .undeclared))
        XCTAssertTrue(arrangement.isTwoMainsOneSub)
        try profiles.replaceSelectedSystemArrangement(arrangement)
        let input = AudioInputDevice(
            deviceID: 22, uid: "mic", name: "Mic", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: rate, maximum: rate)])
        let calibration = RoomCorrectionCalibrationController(
            engine: engine, inputCatalog: InputCatalog(devices: [input]), permissionClient: Permission())
        calibration.prepareForUse()
        calibration.selectInput(uid: "mic")
        let projects = RoomCorrectionProjectController(
            profiles: profiles,
            store: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("rc", isDirectory: true)))
        try projects.startNewProject()
        let ambient = AmbientCompensationController(
            engine: engine, profiles: profiles, microphone: calibration, projects: projects,
            transportFactory: { _, _ in SilentMonitor(rate: rate) })
        let quietZone = ActiveQuietZoneController(engine: engine, profiles: profiles, ambient: ambient)
        quietZone.subAwareAncEnabled = true
        quietZone.attachExcursionCap { ExcursionLimits(mainLowerLimitHz: 45, subCrossoverHz: 80) }
        quietZone.setBassPlant(plant(rate: rate), fingerprint: quietZone.ancBassPathState.fingerprint)
        quietZone.setSubSweepReport(SubAwareArmingTests.report(fingerprint: quietZone.ancBassPathState.fingerprint))
        return (quietZone, engine, session)
    }

    func testTurnOnReachesTheEngineAndTurnOffRevokesItAtEveryRate() async throws {
        for rate in rates {
            let (quietZone, engine, session) = try makeRig(rate: rate)
            XCTAssertTrue(quietZone.subAwareReadiness(mode: .tonal).isReady, "\(rate): \(String(describing: quietZone.subAwareReadiness(mode: .tonal).message))")
            // G16 regression: the arm switch needs the profile session's rate, not only the stereo transport's.
            XCTAssertEqual(engine.liveTreatmentSampleRate, rate)
            XCTAssertFalse(session.quietZoneInjectAuthorised)

            func publish() throws {
                try engine.replaceActiveQuietZoneRuntimeTarget(ActiveQuietZoneRuntimeTarget(
                    tones: [ActiveQuietZoneRuntimeTone(frequencyHz: 60, leftOutput: z(0.001), rightOutput: .zero)],
                    transitionMilliseconds: 3_000, armGeneration: engine.liveTreatmentGeneration))
            }

            try quietZone.setEnabled(true)
            XCTAssertTrue(quietZone.arm.isArmed, "\(rate)")
            XCTAssertFalse(session.quietZoneInjectAuthorised, "\(rate): arming alone injects nothing")
            try publish()
            XCTAssertTrue(session.quietZoneInjectAuthorised, "\(rate): the armed target authorises the graph")

            // A howl-guard trip disarms the controller and revokes through the production poll.
            engine.requestHowlTrip()
            await quietZone.pollNowForTesting()
            XCTAssertFalse(quietZone.arm.isArmed, "\(rate): a guard trip disarms")
            XCTAssertFalse(session.quietZoneInjectAuthorised, "\(rate): a guard trip revokes")
            quietZone.stop()

            // Turn Off on a second armed run revokes too (it also drops the low-latency profile, which on hardware
            // reconfigures the transport).
            let (second, secondEngine, secondSession) = try makeRig(rate: rate)
            try second.setEnabled(true)
            try secondEngine.replaceActiveQuietZoneRuntimeTarget(ActiveQuietZoneRuntimeTarget(
                tones: [ActiveQuietZoneRuntimeTone(frequencyHz: 60, leftOutput: z(0.001), rightOutput: .zero)],
                transitionMilliseconds: 3_000, armGeneration: secondEngine.liveTreatmentGeneration))
            XCTAssertTrue(secondSession.quietZoneInjectAuthorised, "\(rate)")
            try second.setEnabled(false)
            XCTAssertFalse(second.arm.isArmed, "\(rate)")
            XCTAssertFalse(secondSession.quietZoneInjectAuthorised, "\(rate): Turn Off revokes the graph")
        }
    }
}
