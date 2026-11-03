import XCTest
@testable import NotchSixty

/// E25 S3: the Outputs and Speakers steps, the arrangement planner, session schema 2 and the measurement feeds.
@MainActor
final class SystemSetupArrangementStepsTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Planner

    func testPlannerBuildsEveryClassAndItCompiles() {
        let uid = "dev"
        let cases: [(SystemSetupSpeakerChoices, Int, SystemArrangement.Class)] = [
            (.init(layout: .stereo, bass: .fullRange, subwooferCount: 0), 2, .b),
            (.init(layout: .stereo, bass: .dspMonoToMains, subwooferCount: 0), 2, .c),
            (.init(layout: .stereo, bass: .downstreamSubCrossover, subwooferCount: 1), 2, .d),
            (.init(layout: .fiveOne, bass: .downstreamReceiver, subwooferCount: 1), 2, .e),
            (.init(layout: .fiveOne, bass: .dspToSubOutputs, subwooferCount: 2), 8, .a),
            (.init(layout: .stereo, bass: .dspToSubOutputs, subwooferCount: 1), 3, .a),
        ]
        for (choices, channels, expected) in cases {
            let a = SystemSetupArrangementPlanner.arrangement(
                deviceUID: uid, detectedChannelCount: 8, channelsInUse: channels, choices: choices)
            XCTAssertEqual(a.arrangementClass, expected, "\(choices)")
            XCTAssertNil(SystemSetupArrangementPlanner.refusal(a, preserving: nil), "\(choices)")
        }
    }

    func testTwoChannelsNeverKeepADspSubOutputOrADirectWideLayout() {
        let a = SystemSetupArrangementPlanner.arrangement(
            deviceUID: "d", detectedChannelCount: 2, channelsInUse: 6,
            choices: .init(layout: .fiveOne, bass: .dspToSubOutputs, subwooferCount: 2))
        XCTAssertEqual(a.outputs.channelsInUse, 2)
        XCTAssertEqual(a.bass, .fullRange)
        XCTAssertEqual(a.layout, .stereo)
        XCTAssertNil(SystemSetupArrangementPlanner.refusal(a, preserving: nil))
    }

    func testEveryUnavailableCapabilityRowCarriesItsReason() {
        for bass in BassHandling.allCases {
            for channels in [2, 6] {
                let a = SystemSetupArrangementPlanner.arrangement(
                    deviceUID: "d", detectedChannelCount: 6, channelsInUse: channels,
                    choices: .init(layout: .stereo, bass: bass, subwooferCount: 1))
                for row in SystemSetupArrangementPlanner.capabilityRows(a, deviceChannelCount: 6) {
                    XCTAssertFalse(row.availability.text.isEmpty, "\(bass) \(channels) \(row.feature)")
                }
            }
        }
    }

    func testSchemaOneMigrationTable() {
        let stereo = SystemSetupArrangementPlanner.migrate(topology: .stereo, deviceUID: "d", detectedChannelCount: 2)
        XCTAssertEqual(stereo.arrangement.bass, .fullRange)
        XCTAssertFalse(stereo.resumeAtSpeakers)
        let roomy = SystemSetupArrangementPlanner.migrate(topology: .twoPointOne, deviceUID: "d", detectedChannelCount: 6)
        XCTAssertEqual(roomy.arrangement.bass, .dspToSubOutputs)
        XCTAssertEqual(roomy.arrangement.subwooferCount, 1)
        XCTAssertFalse(roomy.resumeAtSpeakers)
        let two = SystemSetupArrangementPlanner.migrate(topology: .twoPointTwo, deviceUID: "d", detectedChannelCount: 4)
        XCTAssertEqual(two.arrangement.subwooferCount, 2)
        let narrow = SystemSetupArrangementPlanner.migrate(topology: .twoPointOne, deviceUID: "d", detectedChannelCount: 2)
        XCTAssertEqual(narrow.arrangement.bass, .dspMonoToMains)
        XCTAssertTrue(narrow.resumeAtSpeakers)
        XCTAssertNotNil(narrow.note)
    }

    func testSchemaOneSessionStillLoadsAndWritesSchemaTwo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("S3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SystemSetupSessionStore(directory: dir)
        var flow = SystemSetupFlow()
        try flow.start(snapshot: PlaybackSystemState())
        var session = SystemSetupSession(playbackSystemKey: "k", updatedAt: Date(), flow: flow)
        session.schemaVersion = 1
        try store.save(session)
        let loaded = try XCTUnwrap(store.load(key: "k"))
        XCTAssertNil(loaded.flow.choices.arrangement)
        XCTAssertEqual(SystemSetupSession.currentSchemaVersion, 2)
    }

    func testFlowPreconditionsFollowTheArrangement() throws {
        var c = SystemSetupChoices()
        c.topology = .twoPointOne
        XCTAssertTrue(c.hasDspSubwoofer)
        c.arrangement = SystemSetupArrangementPlanner.arrangement(
            deviceUID: "d", detectedChannelCount: 2, channelsInUse: 2, choices: .init(bass: .dspMonoToMains))
        XCTAssertFalse(c.hasDspSubwoofer)
        var flow = SystemSetupFlow()
        try flow.start(snapshot: PlaybackSystemState(), choices: c)
        XCTAssertTrue(flow.canSkip(.bass))
    }

    // MARK: Wizard steps through production wiring

    func testSpeakersStepWritesTheProfileAndMeasureSourcesAreTheFeeds() throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate, arrangementEnabled: true)
            defer { rig.tearDown() }
            let model = rig.model
            let label = "\(rate) Hz"
            model.begin()
            model.chooseOutput(uid: OfflineSetupRig.outputUID)
            XCTAssertEqual(model.arrangement?.outputs.detectedChannelCount, 6, label)
            model.chooseChannelCount(3)
            model.next()
            XCTAssertEqual(model.step, .topology, label)
            model.chooseBass(.dspToSubOutputs)
            model.next()
            XCTAssertEqual(model.step, .microphone, "\(label): \(model.message ?? "")")
            let profile = try XCTUnwrap(rig.profiles.selectedSystemOutputDeviceProfile, label)
            XCTAssertEqual(profile.subwooferAssignments.count, 1, label)
            XCTAssertTrue(rig.profiles.selectedSystemProfile?.state.bassManagement.enabled == true, label)
            XCTAssertNotNil(rig.profiles.selectedSystemProfile?.state.systemArrangement, label)
            XCTAssertEqual(rig.calibration.sources.count, 3, label)
        }
    }

    func testTwoChannelMonoBassReachesMeasureWithoutAProfile() throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate, arrangementEnabled: true, outputChannels: 2)
            defer { rig.tearDown() }
            let model = rig.model
            let label = "\(rate) Hz"
            model.begin()
            model.chooseOutput(uid: OfflineSetupRig.outputUID)
            model.next()
            model.chooseBass(.dspMonoToMains)
            model.next()
            XCTAssertEqual(model.step, .microphone, "\(label): \(model.message ?? "")")
            XCTAssertNil(rig.profiles.selectedSystemOutputDeviceProfile, label)
            XCTAssertTrue(rig.profiles.selectedSystemProfile?.state.bassManagement.enabled == true, label)
            XCTAssertEqual(rig.calibration.sources, [.speaker(.frontLeft), .speaker(.frontRight)], label)
            XCTAssertNotNil(rig.calibration.profile, label)
            XCTAssertNil(rig.calibration.storedProfile, label)
        }
    }

    func testFlagOffKeepsTheTopologyStepAndIgnoresTheArrangement() throws {
        let rig = try OfflineSetupRig(rate: 48_000, arrangementEnabled: false, outputChannels: 2)
        defer { rig.tearDown() }
        rig.model.begin()
        XCTAssertNil(rig.model.arrangement)
        XCTAssertTrue(rig.calibration.sources.isEmpty)
    }

    func testCancelRestoresTheStoredArrangement() throws {
        let rig = try OfflineSetupRig(rate: 48_000, arrangementEnabled: true, outputChannels: 2)
        defer { rig.tearDown() }
        let model = rig.model
        model.begin()
        model.next()
        model.chooseBass(.dspMonoToMains)
        model.next()
        XCTAssertEqual(rig.profiles.selectedSystemProfile?.state.systemArrangement?.bass, .dspMonoToMains)
        model.cancel()
        XCTAssertTrue(rig.profiles.selectedSystemProfile?.state.bassManagement.enabled != true)
    }
}
