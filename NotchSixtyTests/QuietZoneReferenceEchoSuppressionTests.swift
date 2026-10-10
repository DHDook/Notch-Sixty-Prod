import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneReferenceEchoSuppressionTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_800_000_000)
    private let rate = 48_000.0

    private func rig() -> QuietZoneHardwareCalibrationRig {
        .init(
            projectID: UUID(), microphoneID: "upstream-mic",
            microphoneChannel: 0, outputDeviceID: "speaker-dac",
            routeID: "leased-stereo-output", sampleRate: rate,
            clockID: "matched-host-seconds", triggerID: "source-probe"
        )
    }

    private func candidate() -> QuietZoneCausalFIRCandidate {
        .init(
            sampleRate: rate, leftTaps: [0.01, 0.01],
            rightTaps: [0.01, -0.01],
            worstPredictedReductionDB: 1.5,
            maximumRelativeFitError: 0.05,
            maximumReferenceEchoFraction: 0.01
        )
    }

    private func captures(
        _ r: QuietZoneHardwareCalibrationRig,
        sigma: Double = 0.001,
        measured: [Double] = [0.04, -0.01]
    ) -> [QuietZoneReferenceLeakageCapture] {
        [QuietZoneLeakageSpeaker.left, .right].flatMap { channel in
            (0..<3).map { n in
                .init(
                    rig: r, speaker: channel,
                    sourceFixtureID: r.triggerID,
                    launchID: "\(channel.rawValue)-rig-\(n)",
                    capturedAt: today.addingTimeInterval(-10 - Double(n * 2)),
                    measuredCoherence: 0.98,
                    impulseResponse: measured.map {
                        $0 * (1 + Double(n - 1) * 0.005)
                    },
                    oneSigmaError: .init(repeating: sigma, count: measured.count)
                )
            }
        }
    }

    private func model(
        _ r: QuietZoneHardwareCalibrationRig,
        sigma: Double = 0.001
    ) throws -> QuietZoneReferenceEchoModel {
        try QuietZoneReferenceEchoModelBuilder().build(
            candidate: candidate(), rig: r,
            captures: captures(r, sigma: sigma), now: today
        )
    }

    private func speakers(_ count: Int = 256) -> ([Float], [Float]) {
        var l = [Float](repeating: 0, count: count)
        var r = [Float](repeating: 0, count: count)
        for i in 16..<count where i % 48 == 16 { l[i] = 0.8 }
        for i in 24..<count where i % 48 == 24 { r[i] = -0.7 }
        return (l, r)
    }

    private func microphone(
        _ left: [Float], _ right: [Float],
        lResponse: [Double] = [0.04, -0.01],
        rResponse: [Double] = [0.04, -0.01],
        ambient: Double = 0
    ) -> [Float] {
        (0..<left.count).map { index in
            var echo = ambient
            for tap in lResponse.indices where tap <= index {
                echo += Double(left[index - tap]) * lResponse[tap]
            }
            for tap in rResponse.indices where tap <= index {
                echo += Double(right[index - tap]) * rResponse[tap]
            }
            return Float(echo)
        }
    }

    private func block(
        _ r: QuietZoneHardwareCalibrationRig,
        start: Int64, left: [Float], right: [Float],
        mic: [Float], time: Date? = nil
    ) -> QuietZoneReferenceEchoOfflineBlock {
        .init(
            rig: r, capturedAt: time ?? today,
            microphoneStartFrame: start, speakerStartFrame: start,
            microphone: mic, leftSpeaker: left, rightSpeaker: right
        )
    }

    func testStereoEchoPredictionPreservesIndependentAmbientReference() throws {
        let r = rig()
        let model = try model(r)
        let offline = QuietZoneReferenceEchoOfflineSimulator(model: model)
        let (l, rr) = speakers()
        let mic = microphone(l, rr, ambient: 0.1)
        let out = try offline.process(
            block(r, start: 0, left: l, right: rr, mic: mic)
        )
        XCTAssertEqual(out.predictedSpeakerEcho.count, 256)
        XCTAssertEqual(out.previewDecontaminatedReference.count, 256)
        for s in out.previewDecontaminatedReference {
            XCTAssertEqual(s, 0.1, accuracy: 0.00001)
        }
        XCTAssertLessThan(out.residualMeanSquare, out.rawReferenceMeanSquare)
        XCTAssertFalse(out.liveANCQualified)
        XCTAssertFalse(out.outputConnected)
        XCTAssertFalse(model.outputConnected)
        XCTAssertFalse(offline.outputConnected)
    }

    func testBlockBoundariesPreserveImpulseHistoryAndRejectMissingFrames() throws {
        let r = rig()
        let model = try model(r)
        let one = QuietZoneReferenceEchoOfflineSimulator(model: model)
        let two = QuietZoneReferenceEchoOfflineSimulator(model: model)
        let (l, rr) = speakers()
        let mic = microphone(l, rr, ambient: 0.05)
        let entire = try one.process(
            block(r, start: 0, left: l, right: rr, mic: mic)
        )
        let a = try two.process(
            block(r, start: 0, left: Array(l[..<128]),
                  right: Array(rr[..<128]), mic: Array(mic[..<128]))
        )
        let b = try two.process(
            block(r, start: 128, left: Array(l[128...]),
                  right: Array(rr[128...]), mic: Array(mic[128...]))
        )
        let joined = a.previewDecontaminatedReference
            + b.previewDecontaminatedReference
        XCTAssertEqual(joined.count, entire.previewDecontaminatedReference.count)
        for i in joined.indices {
            XCTAssertEqual(
                joined[i], entire.previewDecontaminatedReference[i],
                accuracy: 0.000001
            )
        }
        XCTAssertThrowsError(try two.process(
            block(r, start: 260, left: l, right: rr, mic: mic)
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceEchoError,
                           .frameDiscontinuity)
        }
        XCTAssertTrue(two.stopped)
        XCTAssertThrowsError(try two.process(
            block(r, start: 256, left: l, right: rr, mic: mic)
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceEchoError, .stopped)
        }
    }

    func testWrongRouteExpiredModelAndUnalignedSpeakerFramesStop() throws {
        let r = rig()
        let other = rig()
        let m = try model(r)
        let (l, rr) = speakers()
        let mic = microphone(l, rr)
        let wrong = QuietZoneReferenceEchoOfflineSimulator(model: m)
        XCTAssertThrowsError(try wrong.process(
            block(other, start: 0, left: l, right: rr, mic: mic)
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceEchoError, .incompatibleRig)
        }
        let expired = QuietZoneReferenceEchoOfflineSimulator(model: m)
        XCTAssertThrowsError(try expired.process(
            block(r, start: 0, left: l, right: rr, mic: mic,
                  time: today.addingTimeInterval(320))
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceEchoError, .expiredModel)
        }
        let mismatch = QuietZoneReferenceEchoOfflineSimulator(model: m)
        var shifted = block(r, start: 0, left: l, right: rr, mic: mic)
        shifted = .init(
            rig: shifted.rig, capturedAt: shifted.capturedAt,
            microphoneStartFrame: 100, speakerStartFrame: 99,
            microphone: shifted.microphone,
            leftSpeaker: shifted.leftSpeaker, rightSpeaker: shifted.rightSpeaker
        )
        XCTAssertThrowsError(try mismatch.process(shifted)) {
            XCTAssertEqual($0 as? QuietZoneReferenceEchoError,
                           .frameDiscontinuity)
        }
    }

    func testInvalidMeasurementsAndImplausibleSubtractionFailClosed() throws {
        let r = rig()
        let m = try model(r)
        let (l, rr) = speakers()
        let mic = microphone(l, rr)
        var invalid = mic
        invalid[5] = .nan
        let recorder = QuietZoneReferenceEchoOfflineSimulator(model: m)
        XCTAssertThrowsError(try recorder.process(
            block(r, start: 0, left: l, right: rr, mic: invalid)
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceEchoError, .invalidCapture)
        }
        let overflow = QuietZoneReferenceEchoOfflineSimulator(model: m)
        XCTAssertThrowsError(try overflow.process(
            block(r, start: 0, left: [Float](repeating: 1, count: 5_000),
                  right: [Float](repeating: 0, count: 5_000),
                  mic: [Float](repeating: 0, count: 5_000))
        ))
        let large = QuietZoneReferenceEchoOfflineSimulator(model: m)
        XCTAssertThrowsError(try large.process(
            block(r, start: 0, left: [1], right: [1], mic: [-1])
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceEchoError,
                           .implausibleEcho)
        }
    }

    func testRepeatRigAndInsufficientEchoConfidenceCannotCreateModel() {
        let r = rig()
        XCTAssertThrowsError(try QuietZoneReferenceEchoModelBuilder().build(
            candidate: candidate(), rig: r,
            captures: Array(captures(r).dropLast()), now: today
        ))
        XCTAssertThrowsError(try QuietZoneReferenceEchoModelBuilder().build(
            candidate: candidate(), rig: r,
            captures: captures(r, sigma: 1), now: today
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceLeakageError,
                           .excessiveFeedbackBound)
        }
    }

    private func probe(
        _ r: QuietZoneHardwareCalibrationRig, id: String,
        delay: TimeInterval, trueL: [Double] = [0.0405, -0.0099],
        trueR: [Double] = [0.0405, -0.0099],
        sourceSilent: Bool = true
    ) -> QuietZoneReferenceEchoAdaptationProbe {
        let (l, rr) = speakers()
        return .init(
            rig: r, eventID: id,
            capturedAt: today.addingTimeInterval(delay),
            sourceIsSilent: sourceSilent,
            microphone: microphone(l, rr, lResponse: trueL, rResponse: trueR),
            leftSpeaker: l, rightSpeaker: rr
        )
    }

    func testHeldOutSpeakerOnlyProbeCanProposeButCannotApplyAdaptation() throws {
        let r = rig()
        let m = try model(r)
        let p = try QuietZoneReferenceEchoAdaptationGuard().propose(
            model: m,
            training: probe(r, id: "train-only", delay: -2),
            validation: probe(r, id: "holdout-independent", delay: -1),
            now: today
        )
        XCTAssertGreaterThan(p.validationImprovementFraction, 0.01)
        XCTAssertLessThan(p.proposedValidationMSE, p.baselineValidationMSE)
        XCTAssertNotEqual(p.leftTaps, m.leftSpeakerToReference)
        XCTAssertEqual(m.leftSpeakerToReference[0], 0.04, accuracy: 0.000001)
        XCTAssertTrue(p.previewOnly)
        XCTAssertFalse(p.automaticallyApplied)
        XCTAssertFalse(p.liveANCQualified)
    }

    func testAdaptiveProposalRejectsDoubleTalkAndSameProbe() throws {
        let r = rig()
        let m = try model(r)
        let a = probe(r, id: "first", delay: -2)
        let b = probe(r, id: "second", delay: -1, sourceSilent: false)
        XCTAssertThrowsError(try QuietZoneReferenceEchoAdaptationGuard().propose(
            model: m, training: a, validation: b, now: today
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceEchoError, .invalidProbe)
        }
        XCTAssertThrowsError(try QuietZoneReferenceEchoAdaptationGuard().propose(
            model: m, training: a, validation: a, now: today
        ))
        XCTAssertThrowsError(try QuietZoneReferenceEchoAdaptationGuard().propose(
            model: m, training: a,
            validation: probe(r, id: "heldout", delay: -1),
            stepSize: 1, now: today
        ))
    }

    func testAdaptiveProposalMustImproveIndependentValidation() throws {
        let r = rig()
        let m = try model(r)
        let train = probe(r, id: "train", delay: -2)
        let validation = probe(
            r, id: "holdout", delay: -1,
            trueL: [0.0395, -0.0101], trueR: [0.0395, -0.0101]
        )
        XCTAssertThrowsError(try QuietZoneReferenceEchoAdaptationGuard().propose(
            model: m, training: train, validation: validation, now: today
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceEchoError,
                           .noValidationImprovement)
        }
    }

    func testAdaptiveUpdateExceedingMeasuredUncertaintyIsRejected() throws {
        let r = rig()
        let m = try model(r, sigma: 0.00001)
        XCTAssertThrowsError(try QuietZoneReferenceEchoAdaptationGuard().propose(
            model: m,
            training: probe(r, id: "train", delay: -2,
                            trueL: [0.05, -0.01], trueR: [0.05, -0.01]),
            validation: probe(r, id: "validate", delay: -1,
                              trueL: [0.05, -0.01], trueR: [0.05, -0.01]),
            now: today
        )) {
            XCTAssertEqual($0 as? QuietZoneReferenceEchoError,
                           .updateExceedsEnvelope)
        }
    }
}
