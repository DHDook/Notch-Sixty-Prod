import XCTest
@testable import NotchSixty

/// E25 S1: arrangement compiler table, migration, capability matrix and profile decoding.
final class SystemArrangementTests: XCTestCase {
    private let uid = "dac-1"

    private func ep(_ i: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: uid, channelIndex: i) }

    private func direct(_ roles: [OutputProgramRole]) -> [ArrangedSpeaker] {
        roles.enumerated().map { ArrangedSpeaker(role: $0.element, feed: .direct(ep(UInt32($0.offset)))) }
    }

    private func twoChannel(
        _ bass: BassHandling, layout: OutputProgramLayout = .stereo, subs: Int = 0
    ) -> SystemArrangement {
        SystemArrangement(
            outputs: SystemOutputs(deviceUID: uid, detectedChannelCount: 2, channelsInUse: 2),
            layout: layout, bass: bass, subwooferCount: subs,
            speakers: direct([.frontLeft, .frontRight]))
    }

    /// 5.1 direct: L R C SL SR on 0...4, subs on 5...
    private func fiveOneDirect(subs: Int) -> SystemArrangement {
        let roles: [OutputProgramRole] = [.frontLeft, .frontRight, .frontCenter, .sideLeft, .sideRight]
        return SystemArrangement(
            outputs: SystemOutputs(deviceUID: uid, detectedChannelCount: 8, channelsInUse: 6 + max(subs - 1, 0)),
            layout: .fiveOne, bass: subs > 0 ? .dspToSubOutputs : .fullRange, subwooferCount: subs,
            subOutputs: (0..<subs).map { ep(UInt32(5 + $0)) },
            speakers: direct(roles)
                + (subs > 0 ? [] : [ArrangedSpeaker(role: .lowFrequencyEffects, feed: .direct(ep(5)))]))
    }

    // MARK: Compiler table

    func testTwoChannelsAlwaysCompileToStereoSession() {
        let cases: [(SystemArrangement, Bool)] = [
            (twoChannel(.fullRange), false),
            (twoChannel(.dspMonoToMains), true),
            (twoChannel(.downstreamSubCrossover, subs: 1), false),
            (twoChannel(.downstreamReceiver, layout: .fiveOne, subs: 1), false),
        ]
        for (arrangement, mono) in cases {
            let compiled = try! SystemArrangementCompiler.compile(arrangement).get()
            XCTAssertEqual(compiled.session, .stereo, "\(arrangement.bass)")
            XCTAssertNil(compiled.outputDeviceProfile)
            XCTAssertNil(compiled.speakerRouting)
            XCTAssertEqual(compiled.monoBassOnPair, mono)
            XCTAssertEqual(compiled.bassManagementEnabled, mono, "downstream bass compiles to bass management off")
        }
    }

    func testClassesFollowTheArrangement() {
        XCTAssertEqual(twoChannel(.fullRange).arrangementClass, .b)
        XCTAssertEqual(twoChannel(.dspMonoToMains).arrangementClass, .c)
        XCTAssertEqual(twoChannel(.downstreamSubCrossover, subs: 1).arrangementClass, .d)
        XCTAssertEqual(twoChannel(.downstreamReceiver, layout: .fiveOne, subs: 1).arrangementClass, .e)
        XCTAssertEqual(fiveOneDirect(subs: 2).arrangementClass, .a)
    }

    func testDirectArrangementCompilesToProfile() throws {
        let compiled = try SystemArrangementCompiler.compile(fiveOneDirect(subs: 2)).get()
        XCTAssertEqual(compiled.session, .profile)
        XCTAssertTrue(compiled.bassManagementEnabled)
        let profile = try XCTUnwrap(compiled.outputDeviceProfile)
        XCTAssertTrue(profile.enabled)
        XCTAssertEqual(profile.programLayout, .fiveOne)
        XCTAssertEqual(profile.speakerAssignments.count, 5)
        XCTAssertEqual(profile.subwooferAssignments.map(\.destination.channelIndex), [5, 6])
        XCTAssertNil(compiled.speakerRouting)
    }

    func testDirectFullRangeMapsLFE() throws {
        let compiled = try SystemArrangementCompiler.compile(fiveOneDirect(subs: 0)).get()
        XCTAssertFalse(compiled.bassManagementEnabled)
        XCTAssertEqual(compiled.outputDeviceProfile?.speakerAssignments.count, 6)
    }

    func testRoutingRealisationCompilesToRouting() throws {
        var a = fiveOneDirect(subs: 1)
        a.realisation = .routing
        let compiled = try SystemArrangementCompiler.compile(a).get()
        XCTAssertEqual(compiled.session, .routed)
        XCTAssertNil(compiled.outputDeviceProfile)
        XCTAssertEqual(compiled.speakerRouting?.speakers.count, 6)
        XCTAssertTrue(compiled.bassManagementEnabled)
    }

    func testRefusalsCarryReasons() {
        func issue(_ a: SystemArrangement) -> ArrangementIssue? {
            if case .failure(let i) = SystemArrangementCompiler.compile(a) { return i }
            return nil
        }
        var a = twoChannel(.dspToSubOutputs, subs: 1)
        XCTAssertEqual(issue(a), .subFeedNeedsThirdOutput)
        XCTAssertEqual(ArrangementIssue.subFeedNeedsThirdOutput.errorDescription,
                       "A subwoofer feed needs a third output. With two outputs, use mono bass or a downstream sub.")
        a = fiveOneDirect(subs: 1); a.bass = .dspMonoToMains
        XCTAssertEqual(issue(a), .monoBassNeedsTwoChannels)
        a = fiveOneDirect(subs: 2); a.subwooferCount = 1
        XCTAssertEqual(issue(a), .subCountMismatch(count: 1, outputs: 2))
        a = fiveOneDirect(subs: 1); a.outputs.detectedChannelCount = 4
        XCTAssertEqual(issue(a), .channelsExceedDevice(inUse: 6, detected: 4))
        a = fiveOneDirect(subs: 1); a.speakers.removeLast()
        XCTAssertEqual(issue(a), .missingSpeaker(.sideRight))
        a = fiveOneDirect(subs: 1); a.subOutputs = [ep(0)]
        XCTAssertEqual(issue(a), .duplicateEndpoint(ep(0)))
        var one = twoChannel(.fullRange); one.outputs.channelsInUse = 1
        XCTAssertEqual(issue(one), .tooFewChannels(1))
        for i in [ArrangementIssue.tooManySubwoofers(9), .monoBassNeedsTwoChannels, .subOutputsNotAllowed] {
            XCTAssertFalse((i.errorDescription ?? "").isEmpty)
        }
    }

    func testRecompilePreservesCalibration() throws {
        var existing = try XCTUnwrap(SystemArrangementCompiler.compile(fiveOneDirect(subs: 1)).get().outputDeviceProfile)
        existing.speakerAssignments[0].calibration = SemanticSpeakerCalibration(trimDB: -3)
        let again = try SystemArrangementCompiler.compile(fiveOneDirect(subs: 1), preserving: existing).get()
        XCTAssertEqual(again.outputDeviceProfile, existing)
    }

    func testApplyKeepsBassSettingsAndTouchesOnlyOwnedFields() throws {
        var state = PlaybackSystemState()
        state.bassManagement.frequencyHz = 95
        state.bassManagement.topology = .linkwitzRiley48
        let compiled = try SystemArrangementCompiler.compile(twoChannel(.dspMonoToMains)).get()
        let applied = compiled.apply(to: state)
        XCTAssertTrue(applied.bassManagement.enabled)
        XCTAssertEqual(applied.bassManagement.frequencyHz, 95)
        XCTAssertEqual(applied.bassManagement.topology, .linkwitzRiley48)
        XCTAssertEqual(applied.bassManagement.monitorMode, .recombined)
        XCTAssertNil(applied.outputDeviceProfile)
    }

    // MARK: Migration

    func testNoProfileBassOffIsStereoFullRange() throws {
        var state = PlaybackSystemState(associatedOutputUID: uid)
        let a = try XCTUnwrap(SystemArrangementMigration.derive(from: state, detectedChannelCount: 2))
        XCTAssertEqual(a.bass, .fullRange)
        XCTAssertEqual(a.layout, .stereo)
        XCTAssertEqual(a.outputs.channelsInUse, 2)
        state.bassManagement.enabled = true
        XCTAssertEqual(SystemArrangementMigration.derive(from: state)?.bass, .dspMonoToMains)
    }

    func testNoProfileTwoPointOneRoundTripsToTodaysRecombinedConfiguration() throws {
        var state = PlaybackSystemState(associatedOutputUID: uid)
        state.bassManagement.enabled = true
        state.bassManagement.frequencyHz = 70
        let migrated = SystemArrangementMigration.migrated(state, detectedChannelCount: 2)
        let compiled = try SystemArrangementCompiler.compile(try XCTUnwrap(migrated.systemArrangement)).get()
        var expected = compiled.apply(to: state)
        expected.systemArrangement = nil
        XCTAssertEqual(expected, state, "compiling the migrated arrangement reproduces the stored configuration")
        XCTAssertEqual(compiled.session, .stereo)
    }

    func testProfileMigratesToDirectWithSubsAndRecompilesIdentically() throws {
        let compiled = try SystemArrangementCompiler.compile(fiveOneDirect(subs: 2)).get()
        var state = compiled.apply(to: PlaybackSystemState(associatedOutputUID: uid))
        state.outputDeviceProfile?.speakerAssignments[1].calibration = SemanticSpeakerCalibration(trimDB: -2)
        let a = try XCTUnwrap(SystemArrangementMigration.derive(from: state, detectedChannelCount: 8))
        XCTAssertEqual(a.arrangementClass, .a)
        XCTAssertEqual(a.bass, .dspToSubOutputs)
        XCTAssertEqual(a.subOutputs.map(\.channelIndex), [5, 6])
        let again = try SystemArrangementCompiler.compile(a, preserving: state.outputDeviceProfile).get()
        XCTAssertEqual(again.apply(to: state), state)
    }

    func testRoutingMigratesToDirect() throws {
        let routing = try XCTUnwrap(SpeakerRoutingTemplate.mainsPlusSub.build(
            mains: [.init(lane: 0, name: "L", endpoints: [ep(0)]), .init(lane: 1, name: "R", endpoints: [ep(1)])],
            subs: [ep(2)]))
        var state = PlaybackSystemState(associatedOutputUID: uid, speakerRouting: routing)
        state.bassManagement.enabled = true
        let a = try XCTUnwrap(SystemArrangementMigration.derive(from: state))
        XCTAssertEqual(a.realisation, .routing)
        XCTAssertEqual(a.subOutputs, [ep(2)])
        XCTAssertEqual(a.outputs.channelsInUse, 3)
        let again = try SystemArrangementCompiler.compile(a).get()
        let shape: (SpeakerRoutingConfiguration?) -> [String] = {
            ($0?.speakers ?? []).map { "\($0.source.kind.rawValue)\($0.source.index)@\($0.ways.map(\.endpoint.channelIndex))" }
        }
        XCTAssertEqual(shape(again.speakerRouting), shape(routing))
    }

    func testMigrationIsIdempotent() {
        var state = PlaybackSystemState(associatedOutputUID: uid)
        state.bassManagement.enabled = true
        let once = SystemArrangementMigration.migrated(state, detectedChannelCount: 2)
        let twice = SystemArrangementMigration.migrated(once, detectedChannelCount: 6)
        XCTAssertEqual(once, twice)
        XCTAssertNotNil(once.systemArrangement)
    }

    func testLegacyPhysicalCrossoverHasNoArrangement() {
        var state = PlaybackSystemState(associatedOutputUID: uid)
        state.bassManagement.enabled = true
        state.bassManagement.physicalOutputMode = .biAmp
        XCTAssertNil(SystemArrangementMigration.derive(from: state))
        XCTAssertNil(SystemArrangementMigration.migrated(state).systemArrangement)
    }

    // MARK: Storage

    func testOldStateDecodesWithoutArrangementAndEncodesNothingNew() throws {
        let data = try JSONEncoder().encode(PlaybackSystemState())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("systemArrangement"))
        XCTAssertNil(try JSONDecoder().decode(PlaybackSystemState.self, from: data).systemArrangement)
    }

    func testArrangementRoundTripsThroughState() throws {
        let a = fiveOneDirect(subs: 1)
        let state = PlaybackSystemState(systemArrangement: a)
        let back = try JSONDecoder().decode(PlaybackSystemState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.systemArrangement, a)
        var downstream = twoChannel(.downstreamReceiver, layout: .fiveOne, subs: 1)
        downstream.speakers.append(ArrangedSpeaker(role: .frontCenter, feed: .viaDownstream([0, 1])))
        let d = try JSONDecoder().decode(SystemArrangement.self, from: JSONEncoder().encode(downstream))
        XCTAssertEqual(d, downstream)
    }

    func testFutureArrangementSchemaIsRejected() throws {
        var data = try JSONEncoder().encode(twoChannel(.fullRange))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(SystemArrangement.self, from: data))
    }

    func testFlagIsRegisteredAndOffByDefault() {
        XCTAssertTrue(FeatureFlag.all.contains(.outputsAndSpeakers))
        XCTAssertFalse(FeatureFlag.outputsAndSpeakers.defaultEnabled)
        XCTAssertEqual(FeatureFlag.outputsAndSpeakers.id, "e25.outputs-and-speakers")
    }

    // MARK: Capability matrix

    private func oneOfEachClass() -> [SystemArrangement.Class: SystemArrangement] {
        [.a: fiveOneDirect(subs: 2), .b: twoChannel(.fullRange), .c: twoChannel(.dspMonoToMains),
         .d: twoChannel(.downstreamSubCrossover, subs: 1),
         .e: twoChannel(.downstreamReceiver, layout: .fiveOne, subs: 1)]
    }

    func testEveryFeatureHasTextForEveryClass() {
        for (cls, arrangement) in oneOfEachClass() {
            XCTAssertEqual(arrangement.arrangementClass, cls)
            for feature in SystemFeature.allCases {
                let answer = SystemCapabilityMatrix.evaluate(feature, arrangement: arrangement)
                XCTAssertFalse(answer.text.trimmingCharacters(in: .whitespaces).isEmpty, "\(feature) \(cls)")
                if case .unavailable(_, let fix) = answer, let fix { XCTAssertFalse(fix.isEmpty) }
            }
        }
        XCTAssertFalse(SystemFeature.allCases.map(\.displayName).contains(""))
    }

    func testAuditRowsMatchThePlan() {
        let all = oneOfEachClass()
        func eval(_ f: SystemFeature, _ c: SystemArrangement.Class) -> CapabilityAvailability {
            SystemCapabilityMatrix.evaluate(f, arrangement: all[c]!)
        }
        XCTAssertEqual(eval(.dspSubFeed, .b).text, "A subwoofer feed needs a third output.")
        XCTAssertTrue(eval(.dspSubFeed, .a).isUsable)
        XCTAssertTrue(eval(.monoBassOnPair, .c).isUsable)
        XCTAssertFalse(eval(.monoBassOnPair, .d).isUsable)
        XCTAssertEqual(eval(.subAlignment, .d).text, SystemCapabilityMatrix.receiverSetsBass)
        XCTAssertEqual(eval(.subAlignment, .e).text, SystemCapabilityMatrix.receiverSetsBass)
        XCTAssertFalse(eval(.multiSubOptimiser, .b).isUsable)
        XCTAssertFalse(eval(.multiSubOptimiser, .e).isUsable)
        XCTAssertTrue(eval(.multiSubOptimiser, .a).isUsable)
        XCTAssertFalse(eval(.speakerRoutingEditor, .c).isUsable)
        XCTAssertFalse(eval(.upmixer, .e).isUsable)
        XCTAssertFalse(eval(.activeCrossovers, .b).isUsable)
        XCTAssertFalse(eval(.perSpeakerTrim, .e).isUsable)
        for cls in [SystemArrangement.Class.b, .c] { XCTAssertTrue(eval(.quietZone, cls).isUsable) }
        for cls in [SystemArrangement.Class.d, .e] {
            if case .limited = eval(.quietZone, cls) {} else { XCTFail("Quiet Zone through a receiver is limited") }
        }
        XCTAssertFalse(eval(.quietZone, .a).isUsable)
        for f in [SystemFeature.stereoPlayback, .programFIR, .headphoneCorrection, .ambientCompensation] {
            for cls in SystemArrangement.Class.allCases { XCTAssertTrue(eval(f, cls).isUsable, "\(f) \(cls)") }
        }
        XCTAssertEqual(SystemCapabilityMatrix.rows(for: all[.b]!).count, SystemFeature.allCases.count)
    }
}
