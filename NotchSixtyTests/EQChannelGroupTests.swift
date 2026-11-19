import XCTest
@testable import NotchSixty

/// E33 S20 (G39): per-speaker-group EQ lists on wide sessions. Group membership, the profile schema (old profiles load
/// unchanged, a stereo session ignores the lists) and the stages the translator publishes at the eight rates.
final class EQChannelGroupTests: XCTestCase {
    private func shape(_ layout: OutputProgramLayout) throws -> UnifiedGraphLayoutShape {
        try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
    }

    private func makeSpec(
        rate: Double, shape: UnifiedGraphLayoutShape, mode: UnifiedGraphProgramDSP.EQMode, groups: [UnifiedGraphGroupEQ]
    ) throws -> UnifiedGraphSpec {
        var stereo = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        stereo.lanes[0].eq = [UnifiedGraphPEQSection(type: 0, frequencyHz: 1_000, gainDB: 2, q: 1)]
        stereo.lanes[1].eq = stereo.lanes[0].eq
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(
            sampleRate: rate, programChannels: shape.laneCount, subwoofers: [])
        configuration.orderPolicy = .canonical
        configuration.programDSP = UnifiedGraphProgramDSP(
            stereo: stereo, shape: shape, eqMode: mode, groupEQ: groups)
        return try configuration.makeSpec()
    }

    func testGroupsOfEachLayout() throws {
        let five = try shape(.fiveOne)
        XCTAssertEqual(EQChannelGroup.available(roleCodes: five.roleCodes), [.fronts, .centre, .surrounds, .lfe])
        XCTAssertEqual(EQChannelGroup.centre.lanes(roleCodes: five.roleCodes), [five.centerLane!])
        XCTAssertEqual(EQChannelGroup.lfe.lanes(roleCodes: five.roleCodes), [five.lfeLane!])
        let atmos = try shape(.sevenOneFour)
        XCTAssertEqual(EQChannelGroup.available(roleCodes: atmos.roleCodes), EQChannelGroup.allCases)
        XCTAssertEqual(EQChannelGroup.heights.lanes(roleCodes: atmos.roleCodes).count, 4)
        XCTAssertEqual(EQChannelGroup.available(roleCodes: try shape(.stereo).roleCodes), [])
    }

    func testProfileRoundTripAndOldProfileLoad() throws {
        let five = try shape(.fiveOne)
        var eq = StereoEQConfiguration(linkedBands: [EQBand(gainDB: 1)])
        let encodedOld = try JSONEncoder().encode(eq)
        XCTAssertFalse(String(decoding: encodedOld, as: UTF8.self).contains("groupBandLists"))
        // An old profile (no group key) loads with no group lists.
        let old = try JSONDecoder().decode(StereoEQConfiguration.self, from: encodedOld)
        XCTAssertEqual(old, eq)
        XCTAssertTrue(old.groupBandLists.isEmpty)
        let cut = EQBand(type: .peaking, frequencyHz: 200, gainDB: -4, q: 1)
        eq.setGroupBands([cut], for: .centre, roleCodes: five.roleCodes)
        let back = try JSONDecoder().decode(StereoEQConfiguration.self, from: JSONEncoder().encode(eq))
        XCTAssertEqual(back, eq)
        XCTAssertEqual(back.groupBands(.centre, roleCodes: five.roleCodes), [cut])
        // Lists are per layout: a 7.1 session does not read the 5.1 list.
        XCTAssertTrue(back.groupBands(.centre, roleCodes: try shape(.sevenOne).roleCodes).isEmpty)
        // A content preset carries it.
        let preset = ContentPresetState(stereoEQ: eq)
        let presetBack = try JSONDecoder().decode(ContentPresetState.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(presetBack.stereoEQ.groupBandLists, eq.groupBandLists)
    }

    func testStereoSessionIgnoresGroupListsAndBypassClearsThem() throws {
        let five = try shape(.fiveOne)
        var eq = StereoEQConfiguration()
        eq.setGroupBands([EQBand(gainDB: -3)], for: .centre, roleCodes: five.roleCodes)
        XCTAssertEqual(try eq.groupCurves(shape: five, sampleRate: 48_000).count, 1)
        XCTAssertTrue(try eq.groupCurves(shape: try shape(.stereo), sampleRate: 48_000).isEmpty)
        eq.bypassed = true
        XCTAssertTrue(try eq.groupCurves(shape: five, sampleRate: 48_000).isEmpty)
    }

    func testUnsupportedBandsAreRefusedByName() throws {
        let five = try shape(.fiveOne)
        var dynamic = EQBand(type: .peaking)
        dynamic.dynamic.enabled = true
        for band in [EQBand(type: .linkwitzTransform), dynamic] {
            var eq = StereoEQConfiguration()
            eq.setGroupBands([band], for: .fronts, roleCodes: five.roleCodes)
            XCTAssertThrowsError(try eq.groupCurves(shape: five, sampleRate: 48_000))
        }
    }

    func testGroupStagesReachOnlyTheirLanesAtEveryRate() throws {
        let five = try shape(.fiveOne)
        var eq = StereoEQConfiguration()
        eq.setGroupBands([EQBand(type: .peaking, frequencyHz: 120, gainDB: -5, q: 1.2)], for: .centre, roleCodes: five.roleCodes)
        eq.setGroupBands([EQBand(type: .highShelf, frequencyHz: 4_000, gainDB: 2)], for: .surrounds, roleCodes: five.roleCodes)
        for rate in EQRenderHarness.rates {
            let groups = try eq.groupCurves(shape: five, sampleRate: rate)
            let surroundLanes = EQChannelGroup.surrounds.lanes(roleCodes: five.roleCodes)
            XCTAssertEqual(groups.map(\.lane), ([five.centerLane!] + surroundLanes).sorted())
            let spec = try makeSpec(rate: rate, shape: five, mode: .linked, groups: groups)
            let groupStages = spec.stages.filter {
                $0.kind == N60_STAGE_PEQ.rawValue && $0.stageId >= UnifiedGraphProgramDSP.groupPEQBase
                    && $0.stageId < UnifiedGraphProgramDSP.groupPEQBase + 96
            }
            XCTAssertEqual(groupStages.map { Int($0.laneA) }.sorted(), groups.map(\.lane))
            // The session curve still covers every lane but the LFE.
            let sessionLanes = spec.stages.filter {
                $0.kind == N60_STAGE_PEQ.rawValue && $0.stageId >= UnifiedGraphProgramDSP.programPEQBase && $0.stageId < 832
            }.map { Int($0.laneA) }.sorted()
            XCTAssertEqual(sessionLanes, (0..<five.laneCount).filter { $0 != five.lfeLane })
        }
    }

    func testMidSideRefusesPairedGroupButTakesTheCentre() throws {
        let five = try shape(.fiveOne)
        var eq = StereoEQConfiguration()
        eq.setGroupBands([EQBand(gainDB: -2)], for: .centre, roleCodes: five.roleCodes)
        let centreOnly = try eq.groupCurves(shape: five, sampleRate: 48_000)
        XCTAssertNoThrow(try makeSpec(rate: 48_000, shape: five, mode: .midSide, groups: centreOnly))
        eq.setGroupBands([EQBand(gainDB: -2)], for: .fronts, roleCodes: five.roleCodes)
        let groups = try eq.groupCurves(shape: five, sampleRate: 48_000)
        XCTAssertThrowsError(try makeSpec(rate: 48_000, shape: five, mode: .midSide, groups: groups)) {
            XCTAssertEqual($0 as? UnifiedGraphFallbackReason, .midSideGroupEQ)
        }
    }

    func testLongListSplitsIntoStagesOfSixteenSections() throws {
        let five = try shape(.fiveOne)
        let sections = (0..<20).map { UnifiedGraphPEQSection(type: 0, frequencyHz: 100 + Double($0) * 50, gainDB: 1, q: 1) }
        let spec = try makeSpec(
            rate: 96_000, shape: five, mode: .linked,
            groups: [UnifiedGraphGroupEQ(group: .centre, lane: five.centerLane!, sections: sections)])
        let stages = spec.stages.filter {
            $0.kind == N60_STAGE_PEQ.rawValue && $0.stageId >= UnifiedGraphProgramDSP.groupPEQBase && $0.stageId < 1_400
        }
        XCTAssertEqual(stages.map { $0.params.count }, [64, 16])
    }
}
