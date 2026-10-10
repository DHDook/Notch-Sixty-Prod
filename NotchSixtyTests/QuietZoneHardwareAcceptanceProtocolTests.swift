import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneHardwareAcceptanceProtocolTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var start: Date { now.addingTimeInterval(-100) }

    private func rig() -> QuietZoneHardwareCalibrationRig {
        .init(projectID: UUID(), microphoneID: "moveable-mic",
              microphoneChannel: 0, outputDeviceID: "selected-dac",
              routeID: "current-lease", sampleRate: 48_000,
              clockID: "separately-calibrated-clock",
              triggerID: "source-launch-fixture")
    }

    private func bands(_ levels: [Double], frequencies: [Double] = [40, 80, 120])
        -> [QuietZoneSeatPowerBand] {
        zip(frequencies, levels).map {
            .init(frequencyHz: $0.0, levelDBSPL: $0.1)
        }
    }

    private func capture(
        _ r: QuietZoneHardwareCalibrationRig, session: UUID,
        phase: QuietZoneSeatAcceptancePhase, index: Int,
        levels: [Double]? = nil, frequencies: [Double] = [40, 80, 120],
        coherence: Double = 0.97, clipped: Bool = false,
        peakL: Double? = nil, peakR: Double? = nil,
        position: String = "seat-1",
        instrument: String = "independently-calibrated-meter",
        launch: String? = nil
    ) -> QuietZoneSeatAcceptanceCapture {
        let values = levels ?? (index == 1 ? [65, 66, 65] : [70, 70, 70])
        return .init(
            sessionID: session, rig: r, phase: phase,
            launchID: launch ?? "source-launch-\(index)",
            independentSourceID: "repeatable-low-frequency-test",
            instrumentCalibrationID: instrument,
            listenerPositionID: position,
            measuredAt: start.addingTimeInterval(Double(10 + index * 10)),
            measuredCoherence: coherence,
            bands: bands(values, frequencies: frequencies),
            maximumSeatLevelDBSPL: 78,
            speakerOutputClipped: clipped,
            maximumLeftSamplePeak: peakL ?? (index == 1 ? 0.03 : 0),
            maximumRightSamplePeak: peakR ?? (index == 1 ? 0.03 : 0)
        )
    }

    private func captures(
        _ r: QuietZoneHardwareCalibrationRig, session: UUID
    ) -> [QuietZoneSeatAcceptanceCapture] {
        [
            capture(r, session: session, phase: .baselineBefore, index: 0),
            capture(r, session: session, phase: .experimentalTreatment, index: 1),
            capture(r, session: session, phase: .baselineAfter, index: 2)
        ]
    }

    private func fault(
        _ r: QuietZoneHardwareCalibrationRig,
        session: UUID,
        type: QuietZoneHardwareFaultProbeType,
        index: Int,
        muteSeconds: Double = 0.020,
        residual: Double = -80,
        autoRearm: Bool = false,
        launch: String? = nil
    ) -> QuietZoneHardwareFaultShutdownWitness {
        .init(
            sessionID: session, rig: r, fault: type,
            launchID: launch ?? "fault-probe-\(index)",
            instrumentCalibrationID: "independently-calibrated-meter",
            measuredAt: start.addingTimeInterval(Double(40 + index * 5)),
            detectedAtHostSeconds: 110 + Double(index),
            physicalMuteReachedAtHostSeconds:
                110 + Double(index) + muteSeconds,
            outputResidualDBFS: residual,
            noAutomaticRearmObserved: !autoRearm
        )
    }

    private func probes(
        _ r: QuietZoneHardwareCalibrationRig, session: UUID
    ) -> [QuietZoneHardwareFaultShutdownWitness] {
        QuietZoneHardwareFaultProbeType.allCases.enumerated().map { i, type in
            fault(r, session: session, type: type, index: i)
        }
    }

    private func analyze(
        _ r: QuietZoneHardwareCalibrationRig, session: UUID,
        measurements: [QuietZoneSeatAcceptanceCapture],
        faults: [QuietZoneHardwareFaultShutdownWitness],
        evaluatedAt: Date? = nil
    ) throws -> QuietZoneHardwareAcceptanceReview {
        try QuietZoneHardwareAcceptanceAnalyzer().analyze(
            rig: r, sessionID: session, sessionStartedAt: start,
            captures: measurements, faultProbes: faults,
            now: evaluatedAt ?? now
        )
    }

    func testNumericalBenchPassNeverClaimsRealAttenuationOrLiveOutput() throws {
        let r = rig(), session = UUID()
        let report = try analyze(
            r, session: session,
            measurements: captures(r, session: session),
            faults: probes(r, session: session)
        )
        XCTAssertTrue(report.provisionalBenchCriteriaMet)
        XCTAssertEqual(report.acceptedProbeCount, 5)
        XCTAssertGreaterThan(report.integratedReductionDB, 3)
        XCTAssertEqual(report.worstFrequencyReductionDB, 4, accuracy: 0.00001)
        XCTAssertEqual(report.worstPhysicalMuteSeconds, 0.020,
                       accuracy: 0.000001)
        XCTAssertTrue(report.reviewText.contains("UNVERIFIED"))
        XCTAssertFalse(report.physicalAcousticEvidenceIndependentlyVerified)
        XCTAssertFalse(report.emergencyMuteHardwareVerified)
        XCTAssertFalse(report.liveSpeakerConnectionAuthorized)
        XCTAssertFalse(report.liveANCQualified)
    }

    func testOffOffPowerBaselineDoesNotAverageDbValues() throws {
        let r = rig(), session = UUID()
        var m = captures(r, session: session)
        m[0] = capture(r, session: session, phase: .baselineBefore,
                       index: 0, levels: [70, 70, 70])
        m[2] = capture(r, session: session, phase: .baselineAfter,
                       index: 2, levels: [71, 71, 71])
        let result = try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session))
        let avgPower = (pow(10.0, 7.0) + pow(10.0, 7.1)) / 2.0
        let onPower = (pow(10.0, 6.5) * 2 + pow(10.0, 6.6)) / 3.0
        XCTAssertEqual(result.integratedReductionDB,
                       10 * log10(avgPower / onPower),
                       accuracy: 0.000001)
        XCTAssertEqual(result.maxBaselineDriftDB, 1)
    }

    func testMissingOrDuplicatePhysicalLaunchCannotPass() {
        let r = rig(), session = UUID()
        let m = captures(r, session: session)
        let f = probes(r, session: session)
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: Array(m.dropLast()), faults: f
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .missingMeasurement)
        }
        let duplicate = [
            m[0],
            capture(r, session: session, phase: .experimentalTreatment,
                    index: 1, launch: m[0].launchID),
            m[2]
        ]
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: duplicate, faults: f
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .replayedSource)
        }
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: Array(f.dropLast())
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .missingMeasurement)
        }
    }

    func testWrongTreatmentOrderOrSeatOrInstrumentFails() {
        let r = rig(), session = UUID()
        var m = captures(r, session: session)
        m[1] = capture(r, session: session, phase: .baselineAfter, index: 1)
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .invalidSequence)
        }
        m = captures(r, session: session)
        m[1] = capture(r, session: session, phase: .experimentalTreatment,
                       index: 1, position: "moved-seat")
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        ))
        m[1] = capture(r, session: session, phase: .experimentalTreatment,
                       index: 1, instrument: "unverified-other-meter")
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        ))
    }

    func testUnstableNoiseCoherenceOrChronologyFails() {
        let r = rig(), session = UUID()
        var m = captures(r, session: session)
        m[2] = capture(r, session: session, phase: .baselineAfter,
                       index: 2, levels: [74, 70, 70])
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .unrepeatableNoise)
        }
        m[2] = capture(r, session: session, phase: .baselineAfter,
                       index: 2, coherence: 0.40)
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .poorCoherence)
        }
        XCTAssertThrowsError(try analyze(
            r, session: session,
            measurements: captures(r, session: session),
            faults: probes(r, session: session),
            evaluatedAt: now.addingTimeInterval(400)
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .expiredEvidence)
        }
    }

    func testUnsafeSeatSignalOrJointStereoOutputIsRejected() {
        let r = rig(), session = UUID()
        var m = captures(r, session: session)
        m[1] = capture(r, session: session, phase: .experimentalTreatment,
                       index: 1, clipped: true)
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .unsafeSignal)
        }
        m[1] = capture(r, session: session, phase: .experimentalTreatment,
                       index: 1, peakL: 0.06, peakR: 0.06)
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .unsafeSignal)
        }
    }

    func testSpectralGridMustMatchAndMissingBinsMustNotCrash() {
        let r = rig(), session = UUID()
        var m = captures(r, session: session)
        m[1] = capture(r, session: session, phase: .experimentalTreatment,
                       index: 1, levels: [65, 65, 65, 65],
                       frequencies: [30, 40, 80, 120])
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .invalidSpectrum)
        }
        m[1] = capture(r, session: session, phase: .experimentalTreatment,
                       index: 1, frequencies: [40, 85, 120])
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        ))
    }

    func testNoRealImprovementAndFrequencyRegressionFail() {
        let r = rig(), session = UUID()
        var m = captures(r, session: session)
        m[1] = capture(r, session: session, phase: .experimentalTreatment,
                       index: 1, levels: [70, 70, 70])
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .insufficientAttenuation)
        }
        m[1] = capture(r, session: session, phase: .experimentalTreatment,
                       index: 1, levels: [60, 60, 75])
        XCTAssertThrowsError(try analyze(
            r, session: session, measurements: m,
            faults: probes(r, session: session)
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .acousticRegression)
        }
    }

    func testSlowMuteLoudResidualAndAutoRearmAllFail() {
        let r = rig(), session = UUID()
        let types = QuietZoneHardwareFaultProbeType.allCases
        var f = probes(r, session: session)
        f[0] = fault(r, session: session, type: types[0],
                     index: 0, muteSeconds: 0.20)
        XCTAssertThrowsError(try analyze(
            r, session: session,
            measurements: captures(r, session: session), faults: f
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .unverifiedFaultShutdown)
        }
        f[0] = fault(r, session: session, type: types[0],
                     index: 0, residual: -30)
        XCTAssertThrowsError(try analyze(
            r, session: session,
            measurements: captures(r, session: session), faults: f
        ))
        f[0] = fault(r, session: session, type: types[0],
                     index: 0, autoRearm: true)
        XCTAssertThrowsError(try analyze(
            r, session: session,
            measurements: captures(r, session: session), faults: f
        ))
    }

    func testReplayedFaultAndChangedHardwareSessionFail() {
        let r = rig(), session = UUID()
        var f = probes(r, session: session)
        f[1] = fault(r, session: session,
                     type: .inputMicrophoneLost,
                     index: 1, launch: f[0].launchID)
        XCTAssertThrowsError(try analyze(
            r, session: session,
            measurements: captures(r, session: session), faults: f
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .replayedSource)
        }
        XCTAssertThrowsError(try analyze(
            rig(), session: session,
            measurements: captures(r, session: session),
            faults: probes(r, session: session)
        )) {
            XCTAssertEqual($0 as? QuietZoneHardwareAcceptanceFault,
                           .wrongCalibrationRig)
        }
    }

    func testRunbookIsOrderedReadOnlyAndExplicitlyHardwareBlocked() {
        let p = QuietZonePhysicalCommissioningRunbook.make()
        XCTAssertEqual(p.steps.count, 9)
        XCTAssertEqual(p.steps.map(\.number), Array(1...9))
        XCTAssertTrue(p.steps[2].instruction.contains("listener"))
        XCTAssertTrue(p.steps.last!.instruction.contains("Numeric pass"))
        XCTAssertFalse(p.outputConnected)
        XCTAssertFalse(p.liveANCQualified)
    }
}
