import Foundation
import XCTest
@testable import NotchSixty

final class MIMORoomTreatmentActivationPermitTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let sources: [MultichannelCalibrationSource] = [
        .subwoofer(0),
        .subwoofer(1),
    ]

    func testPermitRequiresCompletePR75Evidence() {
        let program = safeProgram()
        let safety = sources.map(safetyDeclaration)

        XCTAssertNil(MIMORoomTreatmentActivationPermit.make(
            firProgram: program,
            sourceSafety: safety,
            verification: acceptedVerification(),
            hardwareAcceptance: nil
        ))

        let permit = MIMORoomTreatmentActivationPermit.make(
            firProgram: program,
            sourceSafety: safety,
            verification: acceptedVerification(),
            hardwareAcceptance: completeHardwareAcceptance(),
            issuedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertNotNil(permit)
        XCTAssertEqual(permit?.sources, sources)
        XCTAssertEqual(permit?.sampleRate, sampleRate)
        XCTAssertEqual(permit?.tapCount, 512)
        XCTAssertEqual(permit?.declaredLatencyFrames, 256)
        XCTAssertEqual(permit?.engineLatencyFrames, 256)
        XCTAssertEqual(permit?.totalLatencyFrames, 512)
        XCTAssertEqual(
            permit?.verifiedSpatialRMSErrorImprovementDB ?? 0,
            3.5,
            accuracy: 0.000_001
        )
    }

    func testPermitRejectsUnsafeOrForgedFIRProgram() {
        var diagnostics = safeProgram().diagnostics
        diagnostics = MIMORoomTreatmentFIRCompileDiagnostics(
            maximumEdgeEnergyFraction: diagnostics.maximumEdgeEnergyFraction,
            maximumCoefficientMagnitude: 1.2,
            maximumColumnPower: diagnostics.maximumColumnPower,
            maximumPerSourcePower: diagnostics.maximumPerSourcePower,
            maximumCoefficientOvershootDB: 1.58,
            maximumColumnPowerOvershootDB: 0,
            maximumPerSourcePowerOvershootDB: 0
        )
        let unsafe = MIMORoomTreatmentFIRProgram(
            sampleRate: sampleRate,
            sources: sources,
            tapCount: 512,
            declaredLatencyFrames: 256,
            engineLatencyFrames: 256,
            taps: safeTaps(diagonalGain: 0.5),
            diagnostics: diagnostics
        )
        XCTAssertNil(MIMORoomTreatmentActivationPermit.make(
            firProgram: unsafe,
            sourceSafety: sources.map(safetyDeclaration),
            verification: acceptedVerification(),
            hardwareAcceptance: completeHardwareAcceptance()
        ))

        let forgedLatency = MIMORoomTreatmentFIRProgram(
            sampleRate: sampleRate,
            sources: sources,
            tapCount: 512,
            declaredLatencyFrames: 128,
            engineLatencyFrames: 256,
            taps: safeTaps(diagonalGain: 0.5),
            diagnostics: safeDiagnostics()
        )
        XCTAssertNil(MIMORoomTreatmentActivationPermit.make(
            firProgram: forgedLatency,
            sourceSafety: sources.map(safetyDeclaration),
            verification: acceptedVerification(),
            hardwareAcceptance: completeHardwareAcceptance()
        ))
    }

    func testPreparedStandaloneTransitionArmsAndAuthorizationRevocationFaultsClosed() throws {
        let program = safeProgram()
        let permit = try XCTUnwrap(MIMORoomTreatmentActivationPermit.make(
            firProgram: program,
            sourceSafety: sources.map(safetyDeclaration),
            verification: acceptedVerification(),
            hardwareAcceptance: completeHardwareAcceptance()
        ))
        let fourFramesMs = 4.0 / sampleRate * 1_000.0
        let twoFramesMs = 2.0 / sampleRate * 1_000.0
        let transition = try MIMORoomTreatmentPreparedTransition(
            firProgram: program,
            permit: permit,
            configuration: MIMORoomTreatmentTransitionConfiguration(
                armFadeMilliseconds: fourFramesMs,
                faultFadeMilliseconds: twoFramesMs
            )
        )

        for _ in 0..<700 {
            let output = try XCTUnwrap(
                transition.processStandaloneFrame(input: [1, 1])
            )
            XCTAssertTrue(output.allSatisfy(\.isFinite))
        }
        XCTAssertEqual(
            transition.snapshot.state,
            N60MIMOTreatmentStateBypassed
        )
        XCTAssertTrue(transition.requestArm())

        for _ in 0..<4 {
            _ = try XCTUnwrap(
                transition.processStandaloneFrame(input: [1, 1])
            )
        }
        XCTAssertEqual(
            transition.snapshot.state,
            N60MIMOTreatmentStateActive
        )
        XCTAssertEqual(
            transition.snapshot.treatmentMix,
            1,
            accuracy: 0.000_01
        )

        let activeOutput = try XCTUnwrap(
            transition.processStandaloneFrame(input: [1, 1])
        )
        XCTAssertEqual(activeOutput[0], 0.5, accuracy: 0.000_2)
        XCTAssertEqual(activeOutput[1], 0.5, accuracy: 0.000_2)

        transition.revokeAuthorization()
        _ = try XCTUnwrap(
            transition.processStandaloneFrame(input: [1, 1])
        )
        _ = try XCTUnwrap(
            transition.processStandaloneFrame(input: [1, 1])
        )

        XCTAssertEqual(
            transition.snapshot.state,
            N60MIMOTreatmentStateFaulted
        )
        XCTAssertEqual(
            transition.snapshot.fault,
            N60MIMOTreatmentFaultAuthorizationRevoked
        )
        XCTAssertEqual(
            transition.snapshot.treatmentMix,
            0,
            accuracy: 0.000_01
        )
        let fallback = try XCTUnwrap(
            transition.processStandaloneFrame(input: [1, 1])
        )
        XCTAssertEqual(fallback[0], 1, accuracy: 0.000_2)
        XCTAssertEqual(fallback[1], 1, accuracy: 0.000_2)
    }

    func testPreparedTransitionRejectsPermitProgramMismatch() throws {
        let program = safeProgram()
        let permit = try XCTUnwrap(MIMORoomTreatmentActivationPermit.make(
            firProgram: program,
            sourceSafety: sources.map(safetyDeclaration),
            verification: acceptedVerification(),
            hardwareAcceptance: completeHardwareAcceptance()
        ))
        let different = MIMORoomTreatmentFIRProgram(
            sampleRate: sampleRate,
            sources: sources,
            tapCount: 1_024,
            declaredLatencyFrames: 512,
            engineLatencyFrames: 256,
            taps: safeTaps(
                tapCount: 1_024,
                delay: 512,
                diagonalGain: 0.5
            ),
            diagnostics: safeDiagnostics()
        )

        XCTAssertThrowsError(
            try MIMORoomTreatmentPreparedTransition(
                firProgram: different,
                permit: permit
            )
        ) { error in
            XCTAssertEqual(
                error as? MIMORoomTreatmentTransitionPreparationError,
                .permitMismatch
            )
        }
    }

    func testTransitionFadeConfigurationProducesBoundedFrameCounts() {
        let configuration = MIMORoomTreatmentTransitionConfiguration(
            armFadeMilliseconds: 40,
            faultFadeMilliseconds: 10
        )
        let frames = configuration.frameCounts(sampleRate: sampleRate)
        XCTAssertEqual(frames?.armFadeFrames, 1_920)
        XCTAssertEqual(frames?.faultFadeFrames, 480)

        let invalid = MIMORoomTreatmentTransitionConfiguration(
            armFadeMilliseconds: 0,
            faultFadeMilliseconds: 10
        )
        XCTAssertNil(invalid.frameCounts(sampleRate: sampleRate))
    }

    private func safeProgram() -> MIMORoomTreatmentFIRProgram {
        MIMORoomTreatmentFIRProgram(
            sampleRate: sampleRate,
            sources: sources,
            tapCount: 512,
            declaredLatencyFrames: 256,
            engineLatencyFrames: 256,
            taps: safeTaps(diagonalGain: 0.5),
            diagnostics: safeDiagnostics()
        )
    }

    private func safeTaps(
        tapCount: Int = 512,
        delay: Int = 256,
        diagonalGain: Float
    ) -> [Float] {
        var taps = [Float](
            repeating: 0,
            count: sources.count * sources.count * tapCount
        )
        for channel in sources.indices {
            let offset =
                ((channel * sources.count + channel) * tapCount)
                + delay
            taps[offset] = diagonalGain
        }
        return taps
    }

    private func safeDiagnostics()
        -> MIMORoomTreatmentFIRCompileDiagnostics
    {
        MIMORoomTreatmentFIRCompileDiagnostics(
            maximumEdgeEnergyFraction: 0,
            maximumCoefficientMagnitude: 0.5,
            maximumColumnPower: 0.25,
            maximumPerSourcePower: 0.25,
            maximumCoefficientOvershootDB: 0,
            maximumColumnPowerOvershootDB: 0,
            maximumPerSourcePowerOvershootDB: 0
        )
    }

    private func safetyDeclaration(
        _ source: MultichannelCalibrationSource
    ) -> MIMORoomTreatmentSourceSafetyDeclaration {
        MIMORoomTreatmentSourceSafetyDeclaration(
            source: source,
            safeMinimumFrequencyHz: 15,
            safeMaximumFrequencyHz: 180,
            reservedHeadroomDB: 6,
            excursionModelConfirmed: true,
            thermalModelConfirmed: true,
            finalProtectionChainConfirmed: true
        )
    }

    private func acceptedVerification()
        -> MIMORoomTreatmentVerificationReport
    {
        MIMORoomTreatmentVerificationReport(
            sampleRate: sampleRate,
            seatIDs: [],
            sources: sources,
            frequenciesHz: [20, 150],
            sourceReports: sources.map {
                MIMORoomTreatmentSourceVerification(
                    source: $0,
                    baselineSpatialRMSErrorDB: 5,
                    treatedSpatialRMSErrorDB: 1.5,
                    spatialRMSErrorImprovementDB: 3.5,
                    maximumAbsoluteMeanLevelShiftDB: 0.2,
                    worstSeatErrorIncreaseDB: 0.1
                )
            },
            baselineSpatialRMSErrorDB: 5,
            treatedSpatialRMSErrorDB: 1.5,
            spatialRMSErrorImprovementDB: 3.5,
            maximumAbsoluteMeanLevelShiftDB: 0.2,
            worstSeatErrorIncreaseDB: 0.1,
            accepted: true
        )
    }

    private func completeHardwareAcceptance()
        -> MIMORoomTreatmentHardwareAcceptance
    {
        MIMORoomTreatmentHardwareAcceptance(
            confirmedAt: Date(timeIntervalSince1970: 1_750_000_000),
            sourceCount: sources.count,
            sampleRate: sampleRate,
            longRunThermalPassed: true,
            protectionChainPassed: true,
            stopStartPassed: true,
            unplugReplugPassed: true,
            sleepWakePassed: true,
            audibleArtifactCheckPassed: true
        )
    }
}
