import XCTest
@testable import NotchSixty

final class SpeakerMeasurementLabUIModelTests: XCTestCase {
    func testOnAxisDraftBuildsValidWholeSpeakerProtocol() throws {
        var draft = SpeakerMeasurementLabProtocolDraft()
        draft.speakerRole = .frontRight
        draft.name = "Right Reference"
        let protocols = try draft.makeProtocols()
        XCTAssertEqual(protocols.count, 1)
        XCTAssertEqual(protocols[0].request.mode, .wholeSpeakerOnAxis)
        XCTAssertEqual(
            protocols[0].request.target,
            .acousticSource(.speaker(.frontRight))
        )
        XCTAssertNil(protocols[0].excitationLevelDBFS)
    }

    func testOffAxisDefaultsProduceActualAngularOffset() throws {
        var draft = SpeakerMeasurementLabProtocolDraft()
        draft.applyModeDefaults(.wholeSpeakerOffAxis)
        let protocolItem = try XCTUnwrap(
            draft.makeProtocols().first
        )
        XCTAssertEqual(
            protocolItem.request.geometry.horizontalAngleDegrees,
            30
        )
        XCTAssertNoThrow(try protocolItem.validateForAcquisition())
    }

    func testSubNearFieldDraftCarriesComponentMetadata() throws {
        var draft = SpeakerMeasurementLabProtocolDraft()
        draft.applyModeDefaults(.subwooferNearField)
        draft.subwooferIndex = 1
        draft.nearFieldComponentKind = .port
        draft.nearFieldComponentLabel = "Rear Port"
        let protocolItem = try XCTUnwrap(
            draft.makeProtocols().first
        )
        XCTAssertEqual(
            protocolItem.request.target,
            .acousticSource(.subwoofer(1))
        )
        XCTAssertEqual(protocolItem.nearFieldComponent?.kind, .port)
        XCTAssertEqual(
            protocolItem.nearFieldComponent?.label,
            "Rear Port"
        )
    }

    func testProtectedDriverDraftAlwaysUsesBoundedExplicitLevel() throws {
        var draft = SpeakerMeasurementLabProtocolDraft()
        draft.applyModeDefaults(.protectedDriverNearField)
        let wayID = UUID()
        draft.routedWayID = wayID
        draft.excitationLevelDBFS = -30
        let protocolItem = try XCTUnwrap(
            draft.makeProtocols().first
        )
        XCTAssertEqual(
            protocolItem.request.target,
            .protectedRoutedWay(wayID)
        )
        XCTAssertEqual(protocolItem.excitationLevelDBFS, -30)
        XCTAssertNoThrow(try protocolItem.validateForAcquisition())

        draft.excitationLevelDBFS = -18
        XCTAssertThrowsError(try draft.makeProtocols())
    }

    func testCoherentDraftCreatesLinkedMainAndSubLegs() throws {
        var draft = SpeakerMeasurementLabProtocolDraft()
        draft.applyModeDefaults(.coherentMainsSubTiming)
        draft.speakerRole = .frontLeft
        draft.subwooferIndex = 0
        draft.excitationLevelDBFS = -30
        let protocols = try draft.makeProtocols()
        XCTAssertEqual(protocols.count, 2)
        XCTAssertEqual(
            Set(protocols.compactMap(\.coherentLeg)),
            Set(SpeakerMeasurementLabCoherentLeg.allCases)
        )
        XCTAssertEqual(
            Set(protocols.compactMap(\.coherentPairID)).count,
            1
        )
        XCTAssertTrue(
            protocols.allSatisfy {
                $0.excitationLevelDBFS == -30
            }
        )
    }

    func testInvalidGeometryAndRepeatCountFailBeforeSessionStart() {
        var draft = SpeakerMeasurementLabProtocolDraft()
        draft.distanceMeters = 0.1
        XCTAssertThrowsError(try draft.makeProtocols())

        draft = SpeakerMeasurementLabProtocolDraft()
        draft.repeatCount = 1
        XCTAssertThrowsError(try draft.makeProtocols())
    }
}
