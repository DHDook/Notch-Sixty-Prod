import XCTest
@testable import NotchSixty

/// E33 S20 part 2 (G39, G76): editing one speaker group's list from the Equalizer page.
final class EQGroupEditingTests: XCTestCase {
    private func shape(_ layout: OutputProgramLayout) throws -> UnifiedGraphLayoutShape {
        try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
    }

    private let boost = EQBand(type: .peaking, frequencyHz: 100, gainDB: 6, q: 1)

    func testEditsRouteToTheChosenGroupAndEqualityIgnoresTheChoice() throws {
        let codes = try shape(.fiveOne).roleCodes
        var eq = StereoEQConfiguration(linkedBands: [EQBand(gainDB: 1)])
        let plain = eq
        eq.setEditGroup(.centre, roleCodes: codes)
        XCTAssertEqual(eq, plain, "choosing a group republishes nothing")
        XCTAssertEqual(eq.editGroup(roleCodes: codes), .centre)
        XCTAssertTrue(eq.editableBands.isEmpty)
        eq.replaceEditableBands([boost])
        XCTAssertEqual(eq.groupBands(.centre, roleCodes: codes), [boost])
        XCTAssertEqual(eq.linkedBands, plain.linkedBands)
        XCTAssertNotEqual(eq, plain, "the list itself still counts")
        // A key from another layout means All.
        XCTAssertNil(eq.editGroup(roleCodes: try shape(.sevenOne).roleCodes))
        eq.replaceEditableBands([])
        XCTAssertTrue(eq.groupBandLists.isEmpty)
        eq.setEditGroup(nil, roleCodes: codes)
        eq.replaceEditableBands([boost])
        XCTAssertEqual(eq.linkedBands, [boost])
    }

    func testStorageRefusals() throws {
        let codes = try shape(.fiveOne).roleCodes
        var eq = StereoEQConfiguration()
        eq.setGroupBands([EQBand(type: .linkwitzTransform, frequencyHz: 50, gainDB: 0, q: 0.7)], for: .lfe, roleCodes: codes)
        XCTAssertThrowsError(try eq.validateStorage(sampleRate: 48_000)) {
            XCTAssertEqual(($0 as? EQGroupBandError), .unsupportedType(group: "LFE", type: EQFilterType.linkwitzTransform.displayName))
        }
        var dynamic = boost
        dynamic.dynamic.enabled = true
        eq.setGroupBands([dynamic], for: .centre, roleCodes: codes)
        eq.setGroupBands([], for: .lfe, roleCodes: codes)
        XCTAssertThrowsError(try eq.validateStorage(sampleRate: 48_000))
        eq.setGroupBands([boost], for: .centre, roleCodes: codes)
        XCTAssertNoThrow(try eq.validateStorage(sampleRate: 48_000))
    }

    func testListenOnAGroupPlaysThatGroupOnly() throws {
        let codes = try shape(.fiveOne).roleCodes
        var eq = StereoEQConfiguration(linkedBands: [EQBand(gainDB: 3)])
        eq.setGroupBands([boost], for: .surrounds, roleCodes: [UInt32](codes))
        eq.setEditGroup(.surrounds, roleCodes: codes)
        let heard = eq.auditioned(EQAuditionOverride(band: boost))
        let key = EQChannelGroup.editKey(.surrounds, roleCodes: codes)
        XCTAssertEqual(heard.groupBandLists.keys.sorted(), [key])
        XCTAssertEqual(heard.groupBandLists[key]?.first?.type, .bandPass)
        XCTAssertTrue(heard.linkedBands.isEmpty)
        eq.setEditGroup(nil, roleCodes: codes)
        XCTAssertTrue(eq.auditioned(EQAuditionOverride(band: boost)).groupBandLists.isEmpty)
    }

    func testHeadroomIncludesGroupBoost() throws {
        let codes = try shape(.fiveOne).roleCodes
        var eq = StereoEQConfiguration(linkedBands: [EQBand(type: .peaking, frequencyHz: 100, gainDB: 3, q: 1)])
        let before = EQHeadroomPredictor.predict(configuration: eq, sampleRate: 48_000, roleCodes: codes)
        eq.setGroupBands([boost], for: .fronts, roleCodes: codes)
        let after = EQHeadroomPredictor.predict(configuration: eq, sampleRate: 48_000, roleCodes: codes)
        XCTAssertGreaterThan(after.boostDB, before.boostDB + 4)
        let stereo = EQHeadroomPredictor.predict(configuration: eq, sampleRate: 48_000)
        XCTAssertEqual(stereo.boostDB, before.boostDB, accuracy: 0.01, "a stereo session ignores group lists")
    }

    func testSelectorModel() throws {
        let five = try shape(.fiveOne)
        var eq = StereoEQConfiguration()
        eq.setGroupBands([boost], for: .centre, roleCodes: five.roleCodes)
        eq.setEditGroup(.centre, roleCodes: five.roleCodes)
        let model = EQGroupSelectorModel.make(configuration: eq, shape: five, sampleRate: 48_000)
        XCTAssertEqual(model.items.map(\.id), ["all", "fronts", "centre", "surrounds", "lfe"])
        XCTAssertEqual(model.items.first { $0.selected }?.id, "centre")
        XCTAssertEqual(model.items.first { $0.id == "centre" }?.title, "Centre (1)")
        XCTAssertNotNil(model.note)
        XCTAssertTrue(EQGroupSelectorModel.make(configuration: eq, shape: try shape(.stereo), sampleRate: 48_000).items.isEmpty)
        XCTAssertTrue(EQGroupSelectorModel.make(configuration: eq, shape: nil, sampleRate: 48_000).items.isEmpty)
        var ms = StereoEQConfiguration()
        ms.channelMode = .midSide
        let msModel = EQGroupSelectorModel.make(configuration: ms, shape: five, sampleRate: 48_000)
        XCTAssertFalse(msModel.items.first { $0.id == "fronts" }!.enabled)
        XCTAssertTrue(msModel.items.first { $0.id == "centre" }!.enabled)
    }

    func testTransferFollowsTheGroup() throws {
        let codes = try shape(.fiveOne).roleCodes
        var eq = StereoEQConfiguration()
        eq.setEditGroup(.lfe, roleCodes: codes)
        XCTAssertTrue(EQBandTransfer.copyTargets(for: eq).isEmpty)
        let outcome = try EQBandTransfer.pasting([boost], into: eq)
        XCTAssertEqual(outcome.configuration.groupBands(.lfe, roleCodes: codes).count, 1)
        XCTAssertTrue(outcome.configuration.linkedBands.isEmpty)
    }
}
