import Foundation
import XCTest
@testable import NotchSixty

final class AmbientCompensationTests: XCTestCase {
    func testDisabledConfigurationAlwaysReturnsUnity() throws {
        var configuration = configured()
        configuration.enabled = false
        let target = try AmbientCompensationPlanner().plan(
            snapshot: snapshot(ambientDBFS: -35),
            configuration: configuration,
            availableHeadroomDB: 6
        )

        XCTAssertEqual(target.levelDB, 0, accuracy: 0.000_001)
        XCTAssertEqual(target.lowSupportDB, 0, accuracy: 0.000_001)
        XCTAssertEqual(target.presenceSupportDB, 0, accuracy: 0.000_001)
        XCTAssertEqual(target.detailSupportDB, 0, accuracy: 0.000_001)
        XCTAssertEqual(target.holdReason, .disabled)
    }

    func testAudiblePlaybackWithoutAcousticModelFailsClosed() throws {
        let target = try AmbientCompensationPlanner().plan(
            snapshot: snapshot(
                ambientDBFS: -32,
                mode: .playbackModelUnavailable,
                confidence: 0.15
            ),
            configuration: configured(),
            availableHeadroomDB: 6
        )

        XCTAssertEqual(target.holdReason, .playbackModelRequired)
        XCTAssertFalse(target.active)
    }

    func testLowPlaybackSeparationConfidenceFailsClosed() throws {
        let target = try AmbientCompensationPlanner().plan(
            snapshot: snapshot(
                ambientDBFS: -32,
                mode: .modeledPlaybackSubtraction,
                confidence: 0.60
            ),
            configuration: configured(),
            availableHeadroomDB: 6
        )

        XCTAssertEqual(target.holdReason, .lowSeparationConfidence)
        XCTAssertFalse(target.active)
    }

    func testPartyLevelCompensationCannotExceedAvailableHeadroom() throws {
        var configuration = configured()
        configuration.maximumLevelCompensationDB = 5
        let target = try AmbientCompensationPlanner().plan(
            snapshot: snapshot(
                ambientDBFS: -20,
                confidence: 0.95,
                stationarity: 0.95
            ),
            configuration: configuration,
            availableHeadroomDB: 1.75
        )

        XCTAssertEqual(target.activity, .party)
        XCTAssertLessThanOrEqual(target.levelDB, 1.750_001)
        XCTAssertGreaterThan(target.levelDB, 0)
        XCTAssertLessThanOrEqual(
            target.levelDB,
            configuration.maximumLevelCompensationDB
        )
    }

    func testNoDigitalHeadroomStillAllowsSmallTonalCompensation() throws {
        let target = try AmbientCompensationPlanner().plan(
            snapshot: snapshot(
                ambientDBFS: -26,
                confidence: 0.95,
                stationarity: 0.95
            ),
            configuration: configured(),
            availableHeadroomDB: 0
        )

        XCTAssertEqual(target.levelDB, 0, accuracy: 0.000_001)
        XCTAssertNil(target.holdReason)
        XCTAssertGreaterThan(
            target.lowSupportDB
                + target.presenceSupportDB
                + target.detailSupportDB,
            0
        )
    }

    func testPresenceHeavyAmbientNoiseBiasesPresenceSupport() throws {
        let spectrum = [
            band(80, -58),
            band(150, -57),
            band(1_000, -35),
            band(2_000, -33),
            band(3_500, -36),
            band(6_000, -51),
            band(10_000, -53),
        ]
        let target = try AmbientCompensationPlanner().plan(
            snapshot: snapshot(
                ambientDBFS: -28,
                confidence: 0.95,
                stationarity: 0.95,
                spectrum: spectrum
            ),
            configuration: configured(),
            availableHeadroomDB: 3
        )

        XCTAssertGreaterThan(
            target.presenceSupportDB,
            target.detailSupportDB
        )
        XCTAssertGreaterThan(
            target.presenceSupportDB,
            target.lowSupportDB
        )
        XCTAssertLessThanOrEqual(
            target.presenceSupportDB,
            AmbientCompensationPlanner.maximumPresenceSupportDB
        )
    }

    func testNonstationaryEventIsRejected() throws {
        let target = try AmbientCompensationPlanner().plan(
            snapshot: snapshot(
                ambientDBFS: -25,
                confidence: 0.95,
                stationarity: 0.20,
                character: .nonstationary
            ),
            configuration: configured(),
            availableHeadroomDB: 3
        )

        XCTAssertEqual(target.holdReason, .nonstationaryTransient)
        XCTAssertFalse(target.active)
    }

    func testActivityClassificationUsesHysteresis() throws {
        let planner = AmbientCompensationPlanner()
        let configuration = configured()
        let fromQuiet = try planner.plan(
            snapshot: snapshot(ambientDBFS: -46),
            configuration: configuration,
            availableHeadroomDB: 3,
            previousActivity: .quiet
        )
        let fromNormal = try planner.plan(
            snapshot: snapshot(ambientDBFS: -46),
            configuration: configuration,
            availableHeadroomDB: 3,
            previousActivity: .normal
        )

        XCTAssertEqual(fromQuiet.activity, .quiet)
        XCTAssertEqual(fromNormal.activity, .normal)
    }

    func testEnvelopeRisesFasterThanItReleases() throws {
        var envelope = AmbientCompensationEnvelope()
        let configuration = configured()
        let active = AmbientCompensationTarget(
            activity: .party,
            levelDB: 3,
            lowSupportDB: 2,
            presenceSupportDB: 2,
            detailSupportDB: 1.5,
            confidence: 1,
            ambientDeltaDB: 20,
            holdReason: nil
        )
        let afterRise = try envelope.update(
            toward: active,
            configuration: configuration,
            elapsedSeconds: 6
        )
        let risingLevel = afterRise.levelDB
        XCTAssertGreaterThan(risingLevel, 1.5)

        let afterOneSecondRelease = try envelope.update(
            toward: .unity,
            configuration: configuration,
            elapsedSeconds: 1
        )
        XCTAssertGreaterThan(
            afterOneSecondRelease.levelDB,
            risingLevel * 0.90
        )
    }

    func testTransientHoldKeepsCompensationAtUnityUntilHoldExpires() throws {
        var configuration = configured()
        configuration.transientHoldSeconds = 3
        var envelope = AmbientCompensationEnvelope()

        let transient = AmbientCompensationTarget(
            activity: .party,
            levelDB: 0,
            lowSupportDB: 0,
            presenceSupportDB: 0,
            detailSupportDB: 0,
            confidence: 0.9,
            ambientDeltaDB: 20,
            holdReason: .nonstationaryTransient
        )
        let held = try envelope.update(
            toward: transient,
            configuration: configuration,
            elapsedSeconds: 0.5
        )
        XCTAssertEqual(held.holdReason, .nonstationaryTransient)

        let desired = AmbientCompensationTarget(
            activity: .busy,
            levelDB: 2,
            lowSupportDB: 1,
            presenceSupportDB: 1,
            detailSupportDB: 0.5,
            confidence: 0.9,
            ambientDeltaDB: 12,
            holdReason: nil
        )
        _ = try envelope.update(
            toward: desired,
            configuration: configuration,
            elapsedSeconds: 2
        )
        let afterExpiry = try envelope.update(
            toward: desired,
            configuration: configuration,
            elapsedSeconds: 1.5
        )

        XCTAssertNil(afterExpiry.holdReason)
        XCTAssertGreaterThan(afterExpiry.levelDB, 0)
    }

    func testInvalidConfigurationFailsBeforePlanning() {
        var configuration = configured()
        configuration.maximumLevelCompensationDB = 20

        XCTAssertThrowsError(
            try AmbientCompensationPlanner().plan(
                snapshot: snapshot(ambientDBFS: -30),
                configuration: configuration,
                availableHeadroomDB: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? AmbientCompensationError,
                .invalidConfiguration
            )
        }
    }

    private func configured() -> AmbientCompensationConfiguration {
        var configuration = AmbientCompensationConfiguration()
        configuration.enabled = true
        configuration.strength = 1
        configuration.baselineAmbientLevelDBFS = -50
        configuration.minimumSeparationConfidence = 0.75
        configuration.attackSeconds = 6
        configuration.releaseSeconds = 20
        return configuration
    }

    private func snapshot(
        ambientDBFS: Double,
        mode: AmbientSeparationMode = .modeledPlaybackSubtraction,
        confidence: Double = 0.9,
        stationarity: Double = 0.9,
        character: AmbientNoiseCharacter = .broadband,
        spectrum: [AmbientSpectrumBand]? = nil
    ) -> AmbientAnalysisSnapshot {
        AmbientAnalysisSnapshot(
            sampleRate: 48_000,
            analyzedFrames: 16_384,
            separationMode: mode,
            separationConfidence: confidence,
            predictionGain: mode == .modeledPlaybackSubtraction ? 1 : nil,
            microphoneLevelDBFS: ambientDBFS + 8,
            predictedPlaybackLevelDBFS:
                mode == .modeledPlaybackSubtraction ? ambientDBFS + 6 : nil,
            ambientLevelDBFS: ambientDBFS,
            ambientLevelDBSPL: nil,
            stationarityScore: stationarity,
            periodicityScore: 0.2,
            periodicFrequencyHz: nil,
            lowFrequencyEnergyFraction: 0.3,
            cancellationCandidateScore: 0.2,
            character: character,
            spectrum: spectrum ?? [
                band(80, ambientDBFS - 3),
                band(160, ambientDBFS - 2),
                band(1_000, ambientDBFS),
                band(2_500, ambientDBFS - 1),
                band(6_000, ambientDBFS - 2),
                band(12_000, ambientDBFS - 4),
            ],
            tonalComponents: []
        )
    }

    private func band(
        _ frequency: Double,
        _ level: Double
    ) -> AmbientSpectrumBand {
        AmbientSpectrumBand(
            lowerFrequencyHz: frequency / 1.1,
            centerFrequencyHz: frequency,
            upperFrequencyHz: frequency * 1.1,
            levelDBFS: level
        )
    }
}
