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
        let observer = samples[1]
        let captures = observer.seatCaptures.map { previous in
            QuietZoneSeatAcceptanceCapture(
                sessionID: previous.sessionID,
                rig: previous.rig, phase: previous.phase,
                launchID: previous.launchID,
                independentSourceID: previous.independentSourceID,
                instrumentCalibrationID: previous.instrumentCalibrationID,
                listenerPositionID: previous.listenerPositionID,
                measuredAt: previous.measuredAt,
                measuredCoherence: previous.measuredCoherence,
                bands: previous.phase == .experimentalTreatment
                    ? previous.bands.map {
                        QuietZoneSeatPowerBand(
                            frequencyHz: $0.frequencyHz, levelDBSPL: 70
                        )
                    } : previous.bands,
                maximumSeatLevelDBSPL: previous.maximumSeatLevelDBSPL,
                speakerOutputClipped: previous.speakerOutputClipped,
                maximumLeftSamplePeak: previous.maximumLeftSamplePeak,
                maximumRightSamplePeak: previous.maximumRightSamplePeak
            )
        }
        samples[1] = .init(
            position: observer.position, sessionID: observer.sessionID,
            rig: observer.rig, sessionStartedAt: observer.sessionStartedAt,
            seatCaptures: captures, faultProbes: observer.faultProbes
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

    private func spectralPackage(
        _ rig: QuietZoneHardwareCalibrationRig,
        _ visits: [QuietZonePhysicalVerificationVisit]
    ) throws -> QuietZonePhysicalEvidencePackage {
        try QuietZonePhysicalSpectralEvidenceAnalyzer().compile(
            rig: rig, visits: visits, now: now
        )
    }

    private func replacingTreatment(
        visit: QuietZonePhysicalVerificationVisit,
        levels: [Double]
    ) -> QuietZonePhysicalVerificationVisit {
        let old = visit.seatCaptures[1]
        let revised = QuietZoneSeatAcceptanceCapture(
            sessionID: old.sessionID, rig: old.rig,
            phase: old.phase, launchID: old.launchID,
            independentSourceID: old.independentSourceID,
            instrumentCalibrationID: old.instrumentCalibrationID,
            listenerPositionID: old.listenerPositionID,
            measuredAt: old.measuredAt,
            measuredCoherence: old.measuredCoherence,
            bands: zip(old.bands, levels).map {
                QuietZoneSeatPowerBand(
                    frequencyHz: $0.0.frequencyHz,
                    levelDBSPL: $0.1
                )
            },
            maximumSeatLevelDBSPL: old.maximumSeatLevelDBSPL,
            speakerOutputClipped: old.speakerOutputClipped,
            maximumLeftSamplePeak: old.maximumLeftSamplePeak,
            maximumRightSamplePeak: old.maximumRightSamplePeak
        )
        return .init(
            position: visit.position, sessionID: visit.sessionID,
            rig: visit.rig, sessionStartedAt: visit.sessionStartedAt,
            seatCaptures: [visit.seatCaptures[0], revised, visit.seatCaptures[2]],
            faultProbes: visit.faultProbes
        )
    }

    func testFrequencyResolvedBandsRetainWeakObserverAndWorstBand() throws {
        let r = rig()
        let package = try spectralPackage(r, campaign(r))
        XCTAssertEqual(package.frequencyResults.count, 3)
        XCTAssertEqual(package.frequencyResults.map(\.frequencyHz),
                       [40, 80, 120])
        XCTAssertEqual(package.frequencyResults[0].primaryFirstReductionDB,
                       5, accuracy: 0.00001)
        XCTAssertEqual(package.frequencyResults[1].neighboringSeatReductionDB,
                       1, accuracy: 0.00001)
        XCTAssertEqual(package.frequencyResults[1].primaryReturnReductionDB,
                       3.7, accuracy: 0.00001)
        XCTAssertEqual(package.worstFrequencyReductionDB,
                       1, accuracy: 0.00001)
        XCTAssertEqual(package.maximumPrimaryBandRepeatDifferenceDB,
                       0.3, accuracy: 0.00001)
        XCTAssertEqual(package.rawSourceLaunchCount, 9)
        XCTAssertEqual(package.rawFaultWitnessCount, 15)
        XCTAssertFalse(package.liveANCQualified)
        XCTAssertFalse(package.outputConnected)
        XCTAssertFalse(package.instrumentEvidenceIndependentlyAuthenticated)
        XCTAssertFalse(package.physicalAcousticReductionVerified)
        XCTAssertFalse(package.emergencyAnalogMuteVerified)
    }

    func testEvidenceCanonicalJSONAndDigestAreDeterministic() throws {
        let r = rig()
        let v = campaign(r)
        let first = try spectralPackage(r, v)
        let second = try spectralPackage(r, v)
        XCTAssertEqual(first.schemaVersion, 1)
        XCTAssertEqual(first.canonicalJSON, second.canonicalJSON)
        XCTAssertEqual(first.sha256Hex, second.sha256Hex)
        XCTAssertEqual(first.sha256Hex.count, 64)
        XCTAssertTrue(try QuietZonePhysicalSpectralEvidenceAnalyzer()
            .verifyDigest(
                canonicalJSON: first.canonicalJSON,
                expectedSHA256Hex: first.sha256Hex
            ))
        XCTAssertTrue(first.reviewText.contains("PROVISIONAL"))
    }

    func testEvidenceDigestChangesIfAcousticMeasurementChanges() throws {
        let r = rig()
        let original = campaign(r)
        let a = try spectralPackage(r, original)
        var modified = original
        modified[1] = replacingTreatment(
            visit: original[1], levels: [67.5, 69, 68])
        let b = try spectralPackage(r, modified)
        XCTAssertNotEqual(a.sha256Hex, b.sha256Hex)
        XCTAssertNotEqual(a.canonicalJSON, b.canonicalJSON)
        XCTAssertEqual(b.frequencyResults[0].neighboringSeatReductionDB,
                       2.5, accuracy: 0.00001)
    }

    func testSpectralRepeatGateDetectsHiddenBandVariationInStableAggregate() throws {
        let r = rig()
        var visits = campaign(r)
        visits[2] = replacingTreatment(
            visit: visits[2], levels: [67, 64, 65])
        // The original campaign gate checks aggregate improvement; here
        // opposite single-band excursions largely cancel when summed.
        let aggregate = try analyze(r, visits: visits)
        XCTAssertLessThan(
            aggregate.primaryReductionRepeatDifferenceDB, 1.5)
        XCTAssertThrowsError(try spectralPackage(r, visits)) {
            XCTAssertEqual(
                $0 as? QuietZonePhysicalSpectralFault,
                .inconsistentFrequencyReduction
            )
        }
    }

    func testTamperedManifestIsRejectedButCannotAuthenticateRealInstrument() throws {
        let r = rig()
        let p = try spectralPackage(r, campaign(r))
        XCTAssertThrowsError(try QuietZonePhysicalSpectralEvidenceAnalyzer()
            .verifyDigest(
                canonicalJSON: p.canonicalJSON
                    .replacingOccurrences(
                        of: "controlled-repeatable-source",
                        with: "different-source"
                    ),
                expectedSHA256Hex: p.sha256Hex
            )) {
            XCTAssertEqual(
                $0 as? QuietZonePhysicalSpectralFault,
                .corruptedEvidencePackage
            )
        }
        XCTAssertThrowsError(try QuietZonePhysicalSpectralEvidenceAnalyzer()
            .verifyDigest(canonicalJSON: "{\"schemaVersion\":1}",
                          expectedSHA256Hex: p.sha256Hex))
        XCTAssertThrowsError(try QuietZonePhysicalSpectralEvidenceAnalyzer()
            .verifyDigest(canonicalJSON: p.canonicalJSON,
                          expectedSHA256Hex: String(repeating: "0", count: 64)))
        XCTAssertFalse(p.instrumentEvidenceIndependentlyAuthenticated)
    }

    func testEvidenceManifestEscapesInstrumentNamesWithoutFieldCollisions() throws {
        let r = rig()
        let visits = (0..<3).map {
            makeVisit(rig: r, index: $0, meter: "meter \"A\"\nline two")
        }
        let p = try spectralPackage(r, visits)
        XCTAssertTrue(p.canonicalJSON.contains("meter"))
        XCTAssertTrue(try QuietZonePhysicalSpectralEvidenceAnalyzer()
            .verifyDigest(canonicalJSON: p.canonicalJSON,
                          expectedSHA256Hex: p.sha256Hex))
        XCTAssertFalse(p.liveANCQualified)
    }

    func testSpectralCompilerRefusesEvenOneFailedRawCampaign() throws {
        let r = rig()
        var visits = campaign(r)
        visits[1] = replacingTreatment(
            visit: visits[1], levels: [70, 70, 70])
        XCTAssertThrowsError(try spectralPackage(r, visits)) {
            XCTAssertEqual($0 as? QuietZonePhysicalSpectralFault,
                           .failedCampaign)
        }
    }


    func testSameRawRecordsHaveSameManifestAcrossLaterReviewTimes() throws {
        let r = rig()
        let visits = campaign(r)
        let a = try QuietZonePhysicalSpectralEvidenceAnalyzer().compile(
            rig: r, visits: visits, now: now
        )
        let later = try QuietZonePhysicalSpectralEvidenceAnalyzer().compile(
            rig: r, visits: visits, now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(a.sha256Hex, later.sha256Hex)
        XCTAssertEqual(a.canonicalJSON, later.canonicalJSON)
        XCTAssertFalse(later.instrumentEvidenceIndependentlyAuthenticated)
    }


    private func reviews(
        for package: QuietZonePhysicalEvidencePackage
    ) -> [QuietZoneExternalReviewAcknowledgment] {
        [
            .init(role: .acoustics, reviewerID: "acoustic-reviewer-1",
                  evidenceSHA256Hex: package.sha256Hex,
                  reviewedAt: now.addingTimeInterval(-60),
                  decision: .recommendFurtherHardwareReview,
                  notes: "Numerical spectral evidence examined."),
            .init(role: .electricalSafety, reviewerID: "safety-reviewer-2",
                  evidenceSHA256Hex: package.sha256Hex,
                  reviewedAt: now,
                  decision: .recommendFurtherHardwareReview,
                  notes: "Fault witness metadata reviewed; hardware unverified.")
        ]
    }

    func testTwoDistinctReviewerRolesRemainUnverifiedAndDisconnected() throws {
        let r = rig()
        let p = try spectralPackage(r, campaign(r))
        let packet = try QuietZoneIndependentReviewPacketAnalyzer().assess(
            package: p, reviews: reviews(for: p), now: now
        )
        XCTAssertTrue(packet.numericalAcceptance)
        XCTAssertTrue(packet.independentRolesAcknowledged)
        XCTAssertFalse(packet.reviewerIdentityCryptographicallyVerified)
        XCTAssertFalse(packet.instrumentEvidenceIndependentlyAuthenticated)
        XCTAssertFalse(packet.physicalAttenuationVerified)
        XCTAssertFalse(packet.emergencyMuteHardwareVerified)
        XCTAssertFalse(packet.liveANCQualified)
        XCTAssertFalse(packet.outputConnected)
    }

    func testReviewRejectsSamePersonAndSameRoleRepeated() throws {
        let r = rig()
        let p = try spectralPackage(r, campaign(r))
        let original = reviews(for: p)
        let samePerson = QuietZoneExternalReviewAcknowledgment(
            role: .electricalSafety,
            reviewerID: "ACOUSTIC-REVIEWER-1",
            evidenceSHA256Hex: p.sha256Hex, reviewedAt: now,
            decision: .recommendFurtherHardwareReview,
            notes: "Second claimed review."
        )
        XCTAssertThrowsError(try QuietZoneIndependentReviewPacketAnalyzer()
            .assess(package: p, reviews: [original[0], samePerson], now: now)) {
            XCTAssertEqual($0 as? QuietZoneExternalReviewFault, .duplicateReviewer)
        }
        XCTAssertThrowsError(try QuietZoneIndependentReviewPacketAnalyzer()
            .assess(package: p, reviews: [original[0], original[0]], now: now)) {
            XCTAssertEqual($0 as? QuietZoneExternalReviewFault, .incompleteReview)
        }
    }

    func testReviewerDigestMismatchAndRejectionBlockReview() throws {
        let r = rig()
        let p = try spectralPackage(r, campaign(r))
        let old = reviews(for: p)
        let altered = QuietZoneExternalReviewAcknowledgment(
            role: .electricalSafety, reviewerID: "safety-reviewer-2",
            evidenceSHA256Hex: String(repeating: "0", count: 64),
            reviewedAt: now,
            decision: .recommendFurtherHardwareReview,
            notes: "Different evidence packet."
        )
        XCTAssertThrowsError(try QuietZoneIndependentReviewPacketAnalyzer()
            .assess(package: p, reviews: [old[0], altered], now: now)) {
            XCTAssertEqual($0 as? QuietZoneExternalReviewFault, .mismatchedEvidence)
        }
        let rejection = QuietZoneExternalReviewAcknowledgment(
            role: .electricalSafety, reviewerID: "safety-reviewer-2",
            evidenceSHA256Hex: p.sha256Hex, reviewedAt: now,
            decision: .rejectEvidence, notes: "Insufficient physical evidence."
        )
        XCTAssertThrowsError(try QuietZoneIndependentReviewPacketAnalyzer()
            .assess(package: p, reviews: [old[0], rejection], now: now)) {
            XCTAssertEqual($0 as? QuietZoneExternalReviewFault, .rejectedEvidence)
        }
    }

    func testReviewerTimeWindowAndEmptyNotesAreRejected() throws {
        let r = rig()
        let p = try spectralPackage(r, campaign(r))
        let old = reviews(for: p)
        let late = QuietZoneExternalReviewAcknowledgment(
            role: .electricalSafety, reviewerID: "safety-reviewer-2",
            evidenceSHA256Hex: p.sha256Hex,
            reviewedAt: now.addingTimeInterval(-100_000),
            decision: .recommendFurtherHardwareReview,
            notes: "This review happened too far from the first."
        )
        XCTAssertThrowsError(try QuietZoneIndependentReviewPacketAnalyzer()
            .assess(package: p, reviews: [old[0], late], now: now)) {
            XCTAssertEqual($0 as? QuietZoneExternalReviewFault, .expiredReview)
        }
        let blank = QuietZoneExternalReviewAcknowledgment(
            role: .electricalSafety, reviewerID: "safety-reviewer-2",
            evidenceSHA256Hex: p.sha256Hex, reviewedAt: now,
            decision: .recommendFurtherHardwareReview,
            notes: "   "
        )
        XCTAssertThrowsError(try QuietZoneIndependentReviewPacketAnalyzer()
            .assess(package: p, reviews: [old[0], blank], now: now)) {
            XCTAssertEqual($0 as? QuietZoneExternalReviewFault, .invalidReviewer)
        }
    }

}
