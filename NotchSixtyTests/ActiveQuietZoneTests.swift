import Foundation
import XCTest
@testable import NotchSixty

final class ActiveQuietZoneTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testConfigurationRejectsBroadbandOrUnsafeLimits() {
        var configuration = ActiveQuietZoneConfiguration()
        configuration.maximumFrequencyHz = 500
        XCTAssertThrowsError(try configuration.validated())

        configuration = ActiveQuietZoneConfiguration()
        configuration.maximumToneCount = 5
        XCTAssertThrowsError(try configuration.validated())

        configuration = ActiveQuietZoneConfiguration()
        configuration.maximumPerSourceTonePeakDBFS = -6
        XCTAssertThrowsError(try configuration.validated())
    }

    func testEligibilityRequiresTrustedStationaryProminentLowFrequencyTone() throws {
        let planner = ActiveQuietZonePlanner()
        let configuration = ActiveQuietZoneConfiguration()

        let accepted = try planner.eligibleTones(
            snapshot: snapshot(
                mode: .modeledPlaybackSubtraction,
                confidence: 0.94,
                stationarity: 0.95,
                character: .tonalPeriodic,
                tones: [
                    tone(60, level: -34, prominence: 24),
                    tone(500, level: -28, prominence: 30),
                ]
            ),
            allowMicrophoneOnly: false,
            configuration: configuration
        )
        XCTAssertEqual(accepted.map(\.frequencyHz), [60])

        let unmodeled = try planner.eligibleTones(
            snapshot: snapshot(
                mode: .playbackModelUnavailable,
                confidence: 0.15,
                stationarity: 0.95,
                character: .tonal,
                tones: [tone(60, level: -30, prominence: 30)]
            ),
            allowMicrophoneOnly: false,
            configuration: configuration
        )
        XCTAssertTrue(unmodeled.isEmpty)

        let transient = try planner.eligibleTones(
            snapshot: snapshot(
                mode: .modeledPlaybackSubtraction,
                confidence: 0.95,
                stationarity: 0.25,
                character: .nonstationary,
                tones: [tone(60, level: -30, prominence: 30)]
            ),
            allowMicrophoneOnly: false,
            configuration: configuration
        )
        XCTAssertTrue(transient.isEmpty)
    }

    func testMicrophoneOnlyEligibilityRequiresExplicitSafeAllowance() throws {
        let planner = ActiveQuietZonePlanner()
        let snapshot = snapshot(
            mode: .microphoneOnly,
            confidence: 1,
            stationarity: 0.95,
            character: .tonalPeriodic,
            tones: [tone(50, level: -35, prominence: 20)]
        )

        XCTAssertTrue(
            try planner.eligibleTones(
                snapshot: snapshot,
                allowMicrophoneOnly: false,
                configuration: ActiveQuietZoneConfiguration()
            ).isEmpty
        )
        XCTAssertEqual(
            try planner.eligibleTones(
                snapshot: snapshot,
                allowMicrophoneOnly: true,
                configuration: ActiveQuietZoneConfiguration()
            ).map(\.frequencyHz),
            [50]
        )
    }

    func testTonePersistenceRequiresFourStableWindowsAndResetsOnDrift() throws {
        var tracker = ActiveQuietZoneTonePersistenceTracker()
        let configuration = ActiveQuietZoneConfiguration()

        XCTAssertFalse(
            try tracker.observe(
                frequencyHz: 60.0,
                configuration: configuration
            )
        )
        XCTAssertFalse(
            try tracker.observe(
                frequencyHz: 60.2,
                configuration: configuration
            )
        )
        XCTAssertFalse(
            try tracker.observe(
                frequencyHz: 59.9,
                configuration: configuration
            )
        )
        XCTAssertTrue(
            try tracker.observe(
                frequencyHz: 60.1,
                configuration: configuration
            )
        )
        XCTAssertEqual(tracker.stableWindowCount, 4)
        XCTAssertEqual(tracker.frequencyHz ?? 0, 60.05, accuracy: 0.15)

        XCTAssertFalse(
            try tracker.observe(
                frequencyHz: 64,
                configuration: configuration
            )
        )
        XCTAssertEqual(tracker.stableWindowCount, 1)
    }

    func testSecondaryPathRecoversDelayMagnitudeAndPhase() throws {
        let planner = ActiveQuietZonePlanner()
        let frequency = 100.0
        let delay = 120
        var impulse = [Float](repeating: 0, count: delay + 1)
        impulse[delay] = 0.5

        let path = try planner.secondaryPath(
            impulseResponse: impulse,
            frequencyHz: frequency,
            sampleRate: sampleRate
        )
        XCTAssertEqual(path.magnitude, 0.5, accuracy: 0.000_001)

        let expectedPhase =
            -2 * Double.pi * frequency
                * Double(delay) / sampleRate
        XCTAssertEqual(
            wrappedPhase(path.phaseRadians - expectedPhase),
            0,
            accuracy: 0.000_001
        )
    }

    func testTonePhasorRecoversSineAmplitudeAndPhase() throws {
        let planner = ActiveQuietZonePlanner()
        let frequency = 73.0
        let amplitude = 0.08
        let phase = 0.61
        let count = 16_384
        let samples = (0..<count).map { frame -> Float in
            Float(
                amplitude * cos(
                    2 * Double.pi * frequency
                        * Double(frame) / sampleRate
                        + phase
                )
            )
        }

        let phasor = try planner.tonePhasor(
            samples: samples,
            frequencyHz: frequency,
            sampleRate: sampleRate
        )
        XCTAssertEqual(phasor.magnitude, amplitude, accuracy: 0.001)
        XCTAssertEqual(
            wrappedPhase(phasor.phaseRadians - phase),
            0,
            accuracy: 0.02
        )
    }

    func testRegularizedStereoSolutionCancelsModeledDisturbance() throws {
        var configuration = ActiveQuietZoneConfiguration()
        configuration.maximumPerSourceTonePeakDBFS = -18
        configuration.maximumAggregateSourcePeakDBFS = -12

        let solution = try ActiveQuietZonePlanner().solveStereo(
            frequencyHz: 60,
            disturbance: ActiveQuietZoneComplex(
                real: 0.08,
                imaginary: 0.03
            ),
            leftSecondaryPath: ActiveQuietZoneComplex(
                real: 0.8,
                imaginary: 0.1
            ),
            rightSecondaryPath: ActiveQuietZoneComplex(
                real: 0.45,
                imaginary: -0.2
            ),
            availableInjectionPeak: 0.25,
            configuration: configuration
        )

        XCTAssertGreaterThan(solution.predictedReductionDB, 15)
        XCTAssertLessThan(
            solution.predictedResidual.magnitude,
            solution.disturbance.magnitude * 0.20
        )
        XCTAssertLessThanOrEqual(
            solution.leftOutput.magnitude,
            pow(10, -18.0 / 20) + 0.000_001
        )
        XCTAssertLessThanOrEqual(
            solution.rightOutput.magnitude,
            pow(10, -18.0 / 20) + 0.000_001
        )
    }

    func testSolverScalesCandidateToAvailableInjectionHeadroom() throws {
        var configuration = ActiveQuietZoneConfiguration()
        configuration.maximumPerSourceTonePeakDBFS = -12
        configuration.maximumAggregateSourcePeakDBFS = -9
        let available = 0.025

        let solution = try ActiveQuietZonePlanner().solveStereo(
            frequencyHz: 55,
            disturbance: ActiveQuietZoneComplex(
                real: 0.3,
                imaginary: 0.15
            ),
            leftSecondaryPath: ActiveQuietZoneComplex(
                real: 0.25,
                imaginary: 0
            ),
            rightSecondaryPath: ActiveQuietZoneComplex(
                real: 0.15,
                imaginary: 0
            ),
            availableInjectionPeak: available,
            configuration: configuration
        )

        XCTAssertLessThan(solution.safetyScale, 1)
        XCTAssertLessThanOrEqual(
            solution.leftOutput.magnitude,
            available + 0.000_001
        )
        XCTAssertLessThanOrEqual(
            solution.rightOutput.magnitude,
            available + 0.000_001
        )
    }

    func testAvailableInjectionHeadroomAccountsForPR89LevelRecovery() throws {
        let planner = ActiveQuietZonePlanner()
        let configuration = ActiveQuietZoneConfiguration()

        let withoutAmbient = try planner.availableInjectionPeak(
            headroomAttenuationDB: -3,
            ambientLevelRecoveryDB: 0,
            configuration: configuration
        )
        let withAmbient = try planner.availableInjectionPeak(
            headroomAttenuationDB: -3,
            ambientLevelRecoveryDB: 2.5,
            configuration: configuration
        )

        XCTAssertGreaterThan(withoutAmbient, withAmbient)
        XCTAssertGreaterThan(withAmbient, 0)
        XCTAssertLessThanOrEqual(
            withoutAmbient,
            pow(
                10,
                configuration.maximumAggregateSourcePeakDBFS / 20
            ) + 0.000_001
        )

        let none = try planner.availableInjectionPeak(
            headroomAttenuationDB: -3,
            ambientLevelRecoveryDB: 3,
            configuration: configuration
        )
        XCTAssertEqual(none, 0, accuracy: 0.000_001)
    }

    func testVerificationAcceptsImprovementAndFaultsRegression() throws {
        let planner = ActiveQuietZonePlanner()
        let configuration = ActiveQuietZoneConfiguration()

        let accepted = try planner.verify(
            beforeLevelDBFS: -35,
            afterLevelDBFS: -39,
            configuration: configuration
        )
        XCTAssertEqual(accepted.decision, .accept)
        XCTAssertEqual(
            accepted.measuredReductionDB,
            4,
            accuracy: 0.000_001
        )

        let probe = try planner.verify(
            beforeLevelDBFS: -35,
            afterLevelDBFS: -35.4,
            configuration: configuration
        )
        XCTAssertEqual(probe.decision, .continueProbe)

        let fault = try planner.verify(
            beforeLevelDBFS: -35,
            afterLevelDBFS: -33.5,
            configuration: configuration
        )
        XCTAssertEqual(fault.decision, .faultRegression)
    }

    private func snapshot(
        mode: AmbientSeparationMode,
        confidence: Double,
        stationarity: Double,
        character: AmbientNoiseCharacter,
        tones: [AmbientTonalComponent]
    ) -> AmbientAnalysisSnapshot {
        AmbientAnalysisSnapshot(
            sampleRate: sampleRate,
            analyzedFrames: 16_384,
            separationMode: mode,
            separationConfidence: confidence,
            predictionGain: mode == .modeledPlaybackSubtraction ? 1 : nil,
            microphoneLevelDBFS: -24,
            predictedPlaybackLevelDBFS:
                mode == .modeledPlaybackSubtraction ? -28 : nil,
            ambientLevelDBFS: -34,
            ambientLevelDBSPL: nil,
            stationarityScore: stationarity,
            periodicityScore: 0.92,
            periodicFrequencyHz: tones.first?.frequencyHz,
            lowFrequencyEnergyFraction: 0.92,
            cancellationCandidateScore: 0.9,
            character: character,
            spectrum: [],
            tonalComponents: tones
        )
    }

    private func tone(
        _ frequency: Double,
        level: Double,
        prominence: Double
    ) -> AmbientTonalComponent {
        AmbientTonalComponent(
            frequencyHz: frequency,
            levelDBFS: level,
            prominenceDB: prominence
        )
    }

    private func wrappedPhase(_ phase: Double) -> Double {
        atan2(sin(phase), cos(phase))
    }
}
