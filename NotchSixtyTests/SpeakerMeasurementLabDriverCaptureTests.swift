import XCTest
@testable import NotchSixty

/// E8 B2: the full-band per-driver near-field protocol and its adapter into `RoutedWayLinearisation`.
final class SpeakerMeasurementLabDriverCaptureTests: XCTestCase {
    private let playbackSystemID = UUID(uuidString: "E8B20000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let wayID = UUID(uuidString: "E8B20001-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    private let microphone = SpeakerOptimizerMicrophoneIdentity(
        deviceUID: "e8b2-mic", inputChannelIndex: 0, calibrationFingerprint: "e8b2-cal")
    private let source: MultichannelCalibrationSource = .speaker(.frontLeft)

    func testQualifiedCapturesYieldAFullBandNearFieldBeyondTheLowFrequencyLimit() throws {
        let labProtocol = makeProtocol()
        var session = makeSession([labProtocol])
        session.captures = captures(for: labProtocol, snrDB: 55)

        let result = try SpeakerMeasurementLabDriverCaptureAdapter().analyze(session: session, wayID: wayID)

        XCTAssertEqual(result.wayID, wayID)
        XCTAssertEqual(result.protocolID, labProtocol.id)
        XCTAssertTrue(result.measurementOnly)
        let near = result.linearisation.nearField
        XCTAssertEqual(near.frequenciesHz.count, near.levelsDB.count)
        XCTAssertGreaterThanOrEqual(near.frequenciesHz.first ?? 0, 40)
        XCTAssertLessThanOrEqual(near.frequenciesHz.last ?? 0, 18_000)
        XCTAssertGreaterThan(near.frequenciesHz.last ?? 0, 5_000, "the LF protocol stops at 500 Hz; this one must not")
        XCTAssertNil(result.linearisation.farField)
        let peak = try XCTUnwrap(near.levelsDB.max())
        XCTAssertEqual(peak, 6, accuracy: 0.2)
    }

    func testAdapterOutputFeedsTheCoreLinearisationAtEveryStandardRate() throws {
        let labProtocol = makeProtocol()
        var session = makeSession([labProtocol])
        session.captures = captures(for: labProtocol, snrDB: 55)
        let lin = try SpeakerMeasurementLabDriverCaptureAdapter().analyze(session: session, wayID: wayID).linearisation

        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let design = try CrossoverCore.linearise(
                nearField: lin.nearField, farField: lin.farField, mergeHz: lin.mergeHz,
                highPass: CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 1_500),
                lowPass: CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 12_000), sampleRate: rate, linearPhase: false)
            XCTAssertLessThan(design.rippleAfterDB, design.rippleBeforeDB, "rate \(rate)")
            XCTAssertLessThanOrEqual(design.maxBoostDB, CrossoverCore.DriverLinearisation.maximumBoostDB + 1e-9)
        }
    }

    func testUnqualifiedCapturesAreRefused() {
        let labProtocol = makeProtocol()
        var session = makeSession([labProtocol])
        session.captures = captures(for: labProtocol, snrDB: 3)
        XCTAssertThrowsError(try SpeakerMeasurementLabDriverCaptureAdapter().analyze(session: session, wayID: wayID)) {
            XCTAssertEqual(
                $0 as? SpeakerMeasurementLabDriverCaptureError, .unqualifiedProtocol(labProtocol.id))
        }
    }

    func testAnotherWayHasNoProtocol() {
        let labProtocol = makeProtocol()
        var session = makeSession([labProtocol])
        session.captures = captures(for: labProtocol, snrDB: 55)
        XCTAssertThrowsError(try SpeakerMeasurementLabDriverCaptureAdapter().analyze(session: session, wayID: UUID())) {
            XCTAssertEqual($0 as? SpeakerMeasurementLabDriverCaptureError, .protocolRequired)
        }
    }

    func testProtocolNeedsALowExplicitLevelAndAParentSource() throws {
        var loud = makeProtocol()
        loud.excitationLevelDBFS = -12
        XCTAssertThrowsError(try loud.validateForAcquisition())
        var noLevel = makeProtocol()
        noLevel.excitationLevelDBFS = nil
        XCTAssertThrowsError(try noLevel.validateForAcquisition())
        var noSource = makeProtocol()
        noSource.driverCaptureSource = nil
        XCTAssertThrowsError(try noSource.validateForAcquisition())
        XCTAssertNoThrow(try makeProtocol().validateForAcquisition())
    }

    func testPlanNeverStartsLiveAcquisition() throws {
        let plan = try SpeakerMeasurementLabCapabilityPlanner().plan(
            makeProtocol().request,
            routePlan: makeRoutePlan(),
            multiOutputRouting: nil,
            speakerDriverProcessing: nil)
        XCTAssertEqual(plan.blockReasons, [.routedWayAcquisitionUnavailable(wayID)])
        XCTAssertTrue(plan.analysisProducts.contains(.fullBandNearFieldMagnitude))
        XCTAssertFalse(plan.blockReasons[0].message.isEmpty)
    }

    func testGeometryIsNearField() {
        let far = SpeakerMeasurementLabGeometry(distanceMeters: 1.0)
        XCTAssertFalse(far.isValid(for: .driverNearField))
        XCTAssertTrue(SpeakerMeasurementLabGeometry(distanceMeters: 0.03).isValid(for: .driverNearField))
    }

    // MARK: - Fixtures

    private func makeRoutePlan() -> LiveNChannelOutputRoutePlan {
        var program = Array(repeating: UInt32.max, count: Int(N60_MAX_PROGRAM_CHANNELS))
        program[0] = 0
        program[1] = 1
        var subs = Array(repeating: UInt32.max, count: Int(N60_MAX_SUBWOOFER_OUTPUTS))
        subs[0] = 2
        return LiveNChannelOutputRoutePlan(
            programLayout: .stereo, orderedDeviceUIDs: ["e8b2-output"], referenceDeviceUID: "e8b2-output",
            physicalChannelCount: 3, programPhysicalChannels: program, subwooferPhysicalChannels: subs,
            subwooferCount: 1, bassManagementEnabled: true, speakerCalibrations: [:],
            subwooferCalibrations: Array(repeating: nil, count: Int(N60_MAX_SUBWOOFER_OUTPUTS)))
    }

    private func makeProtocol() -> SpeakerMeasurementLabProtocol {
        SpeakerMeasurementLabProtocol(
            name: "Left tweeter",
            request: SpeakerMeasurementLabRequest(
                mode: .driverNearField,
                target: .routedWay(wayID),
                geometry: SpeakerMeasurementLabGeometry(distanceMeters: 0.03)),
            excitationLevelDBFS: -30,
            driverCaptureSource: source)
    }

    private func makeSession(_ protocols: [SpeakerMeasurementLabProtocol]) -> SpeakerMeasurementLabSession {
        SpeakerMeasurementLabSession(
            playbackSystemID: playbackSystemID, routingSignature: "e8b2-route", microphone: microphone,
            sampleRate: 48_000, protocols: protocols, captures: [],
            createdAt: Date(timeIntervalSince1970: 1_704_200_000),
            modifiedAt: Date(timeIntervalSince1970: 1_704_200_000))
    }

    private func captures(for labProtocol: SpeakerMeasurementLabProtocol, snrDB: Double)
        -> [SpeakerMeasurementLabCapture] {
        let grid = (0..<128).map { 20 * pow(1000.0, Double($0) / 127.0) }
        return (0..<3).map { repeatIndex in
            SpeakerMeasurementLabCapture(
                protocolID: labProtocol.id, repeatIndex: repeatIndex,
                capturedAt: Date(timeIntervalSince1970: 1_704_200_100 + Double(repeatIndex)),
                playbackSystemID: playbackSystemID, routingSignature: "e8b2-route", microphone: microphone,
                excitationLevelDBFS: -30, sampleRate: 48_000, source: source,
                impulseResponse: [0, 0.2, 1, 0.2, 0],
                transferFunction: RoomCorrectionFrequencyResponse(
                    frequenciesHz: grid,
                    // A resonant peak at 3 kHz over a flat passband.
                    magnitudeDB: grid.map { 6 * exp(-0.5 * pow(log2($0 / 3_000) / 0.3, 2)) + Double(repeatIndex - 1) * 0.02 },
                    phaseRadians: grid.map { 0.3 * log2($0 / 60) }),
                quality: RoomCorrectionMeasurementQuality(
                    clipped: false, playbackPeakDBFS: -30, capturePeakDBFS: -20,
                    estimatedNoiseFloorDBFS: -80, estimatedSNRDB: snrDB, sweepComplete: true,
                    directArrivalSeconds: 0.0008 + Double(repeatIndex) * 0.00001,
                    usableLowHz: 40, usableHighHz: 18_000, warnings: []))
        }
    }
}
