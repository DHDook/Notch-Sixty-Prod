import Foundation
import XCTest
@testable import NotchSixty

final class QuietZonePhysicalVerificationCampaignTests: XCTestCase {
    private let initial = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { initial.addingTimeInterval(750) }

    private func rig() -> QuietZoneHardwareCalibrationRig {
        .init(projectID: UUID(), microphoneID: "single-moved-mic",
              microphoneChannel: 0, outputDeviceID: "selected-dac",
              routeID: "same-physical-route-lease", sampleRate: 48_000,
              clockID: "calibrated-cross-device-clock", triggerID: "external-source")
    }

    private func makeVisit(
        rig: QuietZoneHardwareCalibrationRig,
        index: Int,
        seat: String? = nil,
        meter: String = "external-calibrated-meter",
        source: String = "controlled-repeatable-source",
        primaryReturnBaseline: Double = 70,
        primaryReturnOn: Double = 65.3,
        frequencies: [Double] = [40, 80, 120],
        faultMuteSeconds: Double = 0.020,
        replicateLaunchesFrom: Int? = nil
    ) -> QuietZonePhysicalVerificationVisit {
        let start = initial.addingTimeInterval(Double(index * 200))
        let id = UUID()
        let phase = QuietZoneSeatAcceptancePhase.allCases
        let position = QuietZonePhysicalVerificationPosition.allCases[index]
        let selectedSeat = seat ?? (index == 1 ? "neighbor" : "main")
        let captures = (0..<3).map { j in
            let on = index == 1 ? [68.0, 69.0, 68.0] :
                index == 2 ? [primaryReturnOn, primaryReturnOn + 1,
                              primaryReturnOn] : [65, 66, 65]
            let off = Array(repeating: index == 2
                            ? primaryReturnBaseline : 70.0, count: 3)
            return QuietZoneSeatAcceptanceCapture(
                sessionID: id, rig: rig, phase: phase[j],
                launchID: "visit-\(replicateLaunchesFrom ?? index)-source-\(j)",
                independentSourceID: source, instrumentCalibrationID: meter,
                listenerPositionID: selectedSeat,
                measuredAt: start.addingTimeInterval(Double(10 + j * 10)),
                measuredCoherence: 0.97,
                bands: zip(frequencies, j == 1 ? on : off).map { pair in
                    .init(frequencyHz: pair.0, levelDBSPL: pair.1)
                },
                maximumSeatLevelDBSPL: 79,
                speakerOutputClipped: false,
                maximumLeftSamplePeak: j == 1 ? 0.025 : 0,
                maximumRightSamplePeak: j == 1 ? 0.025 : 0
            )
        }
        let probes = QuietZoneHardwareFaultProbeType.allCases
            .enumerated().map { j, type in
                QuietZoneHardwareFaultShutdownWitness(
                    sessionID: id, rig: rig, fault: type,
                    launchID: "visit-\(replicateLaunchesFrom ?? index)-fault-\(j)",
                    instrumentCalibrationID: meter,
                    measuredAt: start.addingTimeInterval(Double(40 + j * 5)),
                    detectedAtHostSeconds: 300 + Double(index * 30 + j),
                    physicalMuteReachedAtHostSeconds:
                        300 + Double(index * 30 + j) + faultMuteSeconds,
                    outputResidualDBFS: -80,
                    noAutomaticRearmObserved: true
                )
            }
        return .init(
            position: position, sessionID: id, rig: rig,
            sessionStartedAt: start,
            seatCaptures: captures, faultProbes: probes
        )
    }

    private func campaign(_ r: QuietZoneHardwareCalibrationRig)
        -> [QuietZonePhysicalVerificationVisit] {
        (0..<3).map { makeVisit(rig: r, index: $0) }
    }

    private func analyze(
        _ rig: QuietZoneHardwareCalibrationRig,
        visits: [QuietZonePhysicalVerificationVisit],
        now: Date? = nil
    ) throws -> QuietZonePhysicalVerificationReview {
        try QuietZonePhysicalVerificationCampaignAnalyzer().analyze(
            rig: rig, visits: visits, now: now ?? self.now
        )
    }

    func testThreeIndependentVisitsProduceProvisionalRepeatabilityReview() throws {
        let r = rig()
        let review = try analyze(r, visits: campaign(r))
        XCTAssertEqual(review.sessionIDs.count, 3)
        XCTAssertEqual(review.uniqueExternalLaunchCount, 24)
        XCTAssertGreaterThan(review.firstPrimaryReductionDB, 3)
        XCTAssertGreaterThan(review.neighboringSeatReductionDB, 1)
        XCTAssertLessThan(review.primaryReductionRepeatDifferenceDB, 1)
        XCTAssertEqual(review.largestPrimaryBaselineDifferenceDB, 0)
        XCTAssertTrue(review.allThreeNumericalReviewsPassed)
        XCTAssertFalse(review.instrumentEvidenceIndependentlyAuthenticated)
        XCTAssertFalse(review.physicalAcousticReductionVerified)
        XCTAssertFalse(review.emergencyAnalogMuteVerified)
        XCTAssertFalse(review.liveANCQualified)
        XCTAssertFalse(review.outputConnected)
        XCTAssertTrue(review.reviewText.contains("PROVISIONAL"))
    }

    func testMissingReorderedOrRepeatedSessionRejected() {
        let r = rig()
        let valid = campaign(r)
        XCTAssertThrowsError(try analyze(r, visits: Array(valid.dropLast()))) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .incompleteSurvey)
        }
        XCTAssertThrowsError(try analyze(r, visits: [valid[1], valid[0], valid[2]])) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .wrongVisitOrder)
        }
        let repeatedSession = QuietZonePhysicalVerificationVisit(
            position: .listenerReturn, sessionID: valid[0].sessionID,
            rig: r, sessionStartedAt: valid[2].sessionStartedAt,
            seatCaptures: valid[2].seatCaptures,
            faultProbes: valid[2].faultProbes
        )
        XCTAssertThrowsError(try analyze(
            r, visits: [valid[0], valid[1], repeatedSession]
        )) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .duplicatedEvidence)
        }
    }

    func testDuplicateSourceLaunchAcrossIndependentVisitsIsNotPermitted() {
        let r = rig()
        let first = makeVisit(rig: r, index: 0)
        let observer = makeVisit(rig: r, index: 1, replicateLaunchesFrom: 0)
        let last = makeVisit(rig: r, index: 2)
        XCTAssertThrowsError(try analyze(r, visits: [first, observer, last])) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .duplicatedEvidence)
        }
    }

    func testMovedReturnSeatAndUnexpectedRigCannotBeCounted() {
        let r = rig()
        var samples = campaign(r)
        samples[2] = makeVisit(rig: r, index: 2, seat: "not-main")
        XCTAssertThrowsError(try analyze(r, visits: samples)) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .movedReturnMicrophone)
        }
        samples = campaign(r)
        samples[1] = makeVisit(rig: rig(), index: 1)
        XCTAssertThrowsError(try analyze(r, visits: samples)) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .changedHardwareRig)
        }
    }

    func testDifferentCalibrationMeterAndExternalSourceFailAcrossVisits() {
        let r = rig()
        var samples = campaign(r)
        samples[1] = makeVisit(rig: r, index: 1, meter: "other-meter")
        XCTAssertThrowsError(try analyze(r, visits: samples)) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .changedInstrumentOrSource)
        }
        samples[1] = makeVisit(rig: r, index: 1, source: "different-source")
        XCTAssertThrowsError(try analyze(r, visits: samples)) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .changedInstrumentOrSource)
        }
    }

    func testIndependentVisitFrequencyGridMustMatch() {
        let r = rig()
        var samples = campaign(r)
        samples[1] = makeVisit(
            rig: r, index: 1, frequencies: [45, 80, 120])
        XCTAssertThrowsError(try analyze(r, visits: samples)) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .mismatchedFrequencyBands)
        }
    }

    func testReturningToSeatRevealsDriftingNoiseBaseline() {
        let r = rig()
        var samples = campaign(r)
        samples[2] = makeVisit(
            rig: r, index: 2,
            primaryReturnBaseline: 73,
            primaryReturnOn: 68.3)
        XCTAssertThrowsError(try analyze(r, visits: samples)) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .changedNoiseBaseline)
        }
    }

    func testPrimaryAcousticGainMustRemainStableAfterMicMovedAwayAndBack() {
        let r = rig()
        var samples = campaign(r)
        samples[2] = makeVisit(
            rig: r, index: 2, primaryReturnOn: 68.5)
        XCTAssertThrowsError(try analyze(r, visits: samples)) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .unstableAttenuation)
        }
    }

    func testObserverPositionWithNoCancellationIsNotSilentlyIgnored() {
        let r = rig()
        var samples = campaign(r)
        samples[1] = makeVisit(
            rig: r, index: 1, primaryReturnBaseline: 70,
            primaryReturnOn: 70)
        // The observer fixture uses its own treatment values; force a true
        // failed raw PR98 visit by poisoning a mandatory external fault.
        let bad = samples[1]
        let corrupt = bad.faultProbes.enumerated().map { i, p in
            QuietZoneHardwareFaultShutdownWitness(
                sessionID: p.sessionID, rig: p.rig, fault: p.fault,
                launchID: p.launchID,
                instrumentCalibrationID: p.instrumentCalibrationID,
                measuredAt: p.measuredAt,
                detectedAtHostSeconds: p.detectedAtHostSeconds,
                physicalMuteReachedAtHostSeconds:
                    i == 0 ? p.detectedAtHostSeconds + 0.2
                           : p.physicalMuteReachedAtHostSeconds,
                outputResidualDBFS: p.outputResidualDBFS,
                noAutomaticRearmObserved: p.noAutomaticRearmObserved
            )
        }
        samples[1] = .init(
            position: bad.position, sessionID: bad.sessionID, rig: bad.rig,
            sessionStartedAt: bad.sessionStartedAt,
            seatCaptures: bad.seatCaptures, faultProbes: corrupt
        )
        XCTAssertThrowsError(try analyze(r, visits: samples)) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .failedNumericalPreflight)
        }
    }

    func testStaleOrOverlappingCampaignIsRejected() {
        let r = rig()
        let samples = campaign(r)
        XCTAssertThrowsError(try analyze(
            r, visits: samples, now: initial.addingTimeInterval(2_000)
        )) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .staleOrReorderedSessions)
        }
        let a = samples[0]
        let b = QuietZonePhysicalVerificationVisit(
            position: .neighboringSeat, sessionID: samples[1].sessionID,
            rig: r, sessionStartedAt: a.sessionStartedAt,
            seatCaptures: samples[1].seatCaptures,
            faultProbes: samples[1].faultProbes
        )
        XCTAssertThrowsError(try analyze(r, visits: [a,b,samples[2]])) {
            XCTAssertEqual($0 as? QuietZonePhysicalVerificationFault,
                           .staleOrReorderedSessions)
        }
    }
}
