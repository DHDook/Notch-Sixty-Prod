import Foundation
import XCTest
@testable import NotchSixty

final class LiveMIMORoomTreatmentIntegrationTests: XCTestCase {
    private let sampleRate = 48_000.0

    func testPreparationMapsAcceptedSubwooferSourcesToPhysicalChannels() throws {
        let sources: [MultichannelCalibrationSource] = [
            .subwoofer(0),
            .subwoofer(1),
        ]
        let profile = makeProfile()
        let fir = makeFIRProgram(sources: sources)
        let permit = try XCTUnwrap(makePermit(firProgram: fir))
        let preparation = LiveMIMORoomTreatmentPreparation(
            firProgram: fir,
            permit: permit,
            acceptedProfile: profile,
            acceptedSelectedOutputUID: "device-A"
        )
        try preparation.validate(sampleRate: sampleRate)

        let route = makeRoutePlan()
        XCTAssertEqual(
            try preparation.physicalChannels(routePlan: route),
            [2, 3]
        )
    }

    func testPreparationMapsMixedSpeakerAndSubwooferSourcesInPermitOrder() throws {
        let sources: [MultichannelCalibrationSource] = [
            .speaker(.frontRight),
            .subwoofer(0),
            .speaker(.frontLeft),
        ]
        let profile = makeProfile()
        let fir = makeFIRProgram(sources: sources)
        let permit = try XCTUnwrap(makePermit(firProgram: fir))
        let preparation = LiveMIMORoomTreatmentPreparation(
            firProgram: fir,
            permit: permit,
            acceptedProfile: profile,
            acceptedSelectedOutputUID: "device-A"
        )

        XCTAssertEqual(
            try preparation.physicalChannels(routePlan: makeRoutePlan()),
            [1, 2, 0]
        )
    }

    func testUnavailablePhysicalTreatmentSourceFailsClosed() throws {
        let sources: [MultichannelCalibrationSource] = [
            .speaker(.lowFrequencyEffects),
        ]
        let profile = makeProfile()
        let fir = makeFIRProgram(sources: sources)
        let permit = try XCTUnwrap(makePermit(firProgram: fir))
        let preparation = LiveMIMORoomTreatmentPreparation(
            firProgram: fir,
            permit: permit,
            acceptedProfile: profile,
            acceptedSelectedOutputUID: "device-A"
        )

        XCTAssertThrowsError(
            try preparation.physicalChannels(routePlan: makeRoutePlan())
        ) { error in
            XCTAssertEqual(
                error as? LiveNChannelTransportError,
                .roomTreatmentSourceUnavailable("LFE")
            )
        }
    }

    func testPermitSampleRateMismatchFailsBeforeLivePreparation() throws {
        let sources: [MultichannelCalibrationSource] = [.subwoofer(0)]
        let profile = makeProfile()
        let fir = makeFIRProgram(sources: sources)
        let permit = try XCTUnwrap(makePermit(firProgram: fir))
        let preparation = LiveMIMORoomTreatmentPreparation(
            firProgram: fir,
            permit: permit,
            acceptedProfile: profile,
            acceptedSelectedOutputUID: "device-A"
        )

        XCTAssertThrowsError(
            try preparation.validate(sampleRate: 44_100)
        ) { error in
            XCTAssertEqual(
                error as? LiveNChannelTransportError,
                .roomTreatmentPermitMismatch
            )
        }
    }

    func testProductionDiagnosticsDescribeConfiguredTreatmentWithoutEnableControl() {
        let diagnostics = ProductionRoomTreatmentDiagnostics(
            authorized: true,
            armRequested: false,
            active: false,
            transitioning: false,
            faulted: false,
            treatmentMix: 0,
            treatmentSourceCount: 2,
            latencyFrames: 2_304,
            processedFrames: 100,
            protectionClampSamples: 0,
            integrationFailures: 0
        )
        XCTAssertTrue(diagnostics.authorized)
        XCTAssertFalse(diagnostics.active)
        XCTAssertEqual(diagnostics.latencyFrames, 2_304)
        XCTAssertEqual(diagnostics.treatmentSourceCount, 2)
    }

    private func makeProfile() -> OutputDeviceProfileConfiguration {
        OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "device-A",
                        channelIndex: 0
                    )
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "device-A",
                        channelIndex: 1
                    )
                ),
            ],
            subwooferAssignments: [
                PhysicalSubwooferOutputAssignment(
                    index: 0,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "device-A",
                        channelIndex: 2
                    )
                ),
                PhysicalSubwooferOutputAssignment(
                    index: 1,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "device-A",
                        channelIndex: 3
                    )
                ),
            ],
            synchronizationMode: .automatic,
            referenceDeviceUID: "device-A"
        )
    }

    private func makeRoutePlan() -> LiveNChannelOutputRoutePlan {
        LiveNChannelOutputRoutePlan(
            programLayout: .stereo,
            orderedDeviceUIDs: ["device-A"],
            referenceDeviceUID: "device-A",
            physicalChannelCount: 4,
            programPhysicalChannels: [0, 1],
            subwooferPhysicalChannels: [2, 3],
            subwooferCount: 2,
            bassManagementEnabled: true,
            speakerCalibrations: [:],
            subwooferCalibrations: [nil, nil]
        )
    }

    private func makeFIRProgram(
        sources: [MultichannelCalibrationSource]
    ) -> MIMORoomTreatmentFIRProgram {
        let tapCount = 512
        var taps = [Float](
            repeating: 0,
            count: sources.count * sources.count * tapCount
        )
        for channel in sources.indices {
            let offset =
                ((channel * sources.count + channel) * tapCount)
                + tapCount / 2
            taps[offset] = 1
        }
        return MIMORoomTreatmentFIRProgram(
            sampleRate: sampleRate,
            sources: sources,
            tapCount: tapCount,
            declaredLatencyFrames: tapCount / 2,
            engineLatencyFrames: Int(N60_MIMO_FIR_PARTITION_FRAMES),
            taps: taps,
            diagnostics: MIMORoomTreatmentFIRCompileDiagnostics(
                maximumEdgeEnergyFraction: 0,
                maximumCoefficientMagnitude: 1,
                maximumColumnPower: 1,
                maximumPerSourcePower: 1,
                maximumCoefficientOvershootDB: 0,
                maximumColumnPowerOvershootDB: 0,
                maximumPerSourcePowerOvershootDB: 0
            )
        )
    }

    private func makePermit(
        firProgram: MIMORoomTreatmentFIRProgram
    ) -> MIMORoomTreatmentActivationPermit? {
        let safety = firProgram.sources.map { source in
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
        let verification = MIMORoomTreatmentVerificationReport(
            sampleRate: sampleRate,
            seatIDs: [],
            sources: firProgram.sources,
            frequenciesHz: [20, 150],
            sourceReports: [],
            baselineSpatialRMSErrorDB: 5,
            treatedSpatialRMSErrorDB: 1,
            spatialRMSErrorImprovementDB: 4,
            maximumAbsoluteMeanLevelShiftDB: 0.2,
            worstSeatErrorIncreaseDB: 0.2,
            accepted: true
        )
        let hardware = MIMORoomTreatmentHardwareAcceptance(
            confirmedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceCount: firProgram.sources.count,
            sampleRate: sampleRate,
            longRunThermalPassed: true,
            protectionChainPassed: true,
            stopStartPassed: true,
            unplugReplugPassed: true,
            sleepWakePassed: true,
            audibleArtifactCheckPassed: true
        )
        return MIMORoomTreatmentActivationPermit.make(
            firProgram: firProgram,
            sourceSafety: safety,
            verification: verification,
            hardwareAcceptance: hardware,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }
}
