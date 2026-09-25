import XCTest
@testable import NotchSixty

final class StereoPlaybackControlTests: XCTestCase {
    func testIndependentLeftEQDoesNotProcessRightChannel() throws {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(
            N60DSPGraphSnapshotSetEQBandForChannels(
                &graph,
                0,
                UInt8(N60_EQ_CHANNEL_LEFT),
                N60BiquadFilterTypePeaking,
                1_000,
                12,
                1.0,
                true
            )
        )
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var inputSquare = 0.0
        var leftSquare = 0.0
        var rightSquare = 0.0
        let frameCount = 24_000
        for frame in 0..<frameCount {
            let sample = Float(0.1 * sin(2.0 * Double.pi * 1_000.0 * Double(frame) / 96_000.0))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
            if frame > 4_000 {
                inputSquare += Double(sample * sample)
                leftSquare += Double(left * left)
                rightSquare += Double(right * right)
            }
        }

        let inputRMS = sqrt(inputSquare / Double(frameCount - 4_001))
        let leftRMS = sqrt(leftSquare / Double(frameCount - 4_001))
        let rightRMS = sqrt(rightSquare / Double(frameCount - 4_001))

        XCTAssertGreaterThan(leftRMS, inputRMS * 2.5)
        XCTAssertEqual(rightRMS, inputRMS, accuracy: 0.000_01)

        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertEqual(diagnostics.eqLeftBandCount, 1)
        XCTAssertEqual(diagnostics.eqRightBandCount, 0)
    }

    func testLinkedEQProcessesBothChannelsEqually() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(
            N60DSPGraphSnapshotSetEQBand(
                &graph,
                0,
                N60BiquadFilterTypePeaking,
                1_000,
                6,
                1.0,
                true
            )
        )
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        for frame in 0..<8_000 {
            let sample = Float(0.1 * sin(2.0 * Double.pi * 1_000.0 * Double(frame) / 96_000.0))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
            if frame > 2_000 {
                XCTAssertEqual(left, right, accuracy: 0.000_001)
            }
        }

        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertEqual(diagnostics.eqLeftBandCount, 1)
        XCTAssertEqual(diagnostics.eqRightBandCount, 1)
    }

    func testBalanceIsAttenuationOnlyAndCenterIsUnity() {
        let centered = PlaybackControlConfiguration(balance: 0).balanceLinearGains
        XCTAssertEqual(centered.left, 1.0)
        XCTAssertEqual(centered.right, 1.0)

        let fullLeft = PlaybackControlConfiguration(balance: -1).balanceLinearGains
        XCTAssertEqual(fullLeft.left, 1.0)
        XCTAssertEqual(fullLeft.right, 0.0)

        let fullRight = PlaybackControlConfiguration(balance: 1).balanceLinearGains
        XCTAssertEqual(fullRight.left, 0.0)
        XCTAssertEqual(fullRight.right, 1.0)

        for balance in stride(from: -1.0, through: 1.0, by: 0.05) {
            let gains = PlaybackControlConfiguration(balance: balance).balanceLinearGains
            XCTAssertGreaterThanOrEqual(gains.left, 0)
            XCTAssertGreaterThanOrEqual(gains.right, 0)
            XCTAssertLessThanOrEqual(gains.left, 1)
            XCTAssertLessThanOrEqual(gains.right, 1)
        }
    }


    func testMasterVolumeCapabilityPolicyUsesHardwareVolumeWhenWritable() {
        let hardware = MasterVolumeDeviceCapabilities(
            volumeReadable: true,
            volumeWritable: true,
            muteReadable: true,
            muteWritable: true
        )
        let software = MasterVolumeDeviceCapabilities.softwareOnly
        let normal = MasterVolumeConfiguration(level: 0.25, muted: false)
        let muted = MasterVolumeConfiguration(level: 0.25, muted: true)

        XCTAssertEqual(hardware.controlMode, .device)
        XCTAssertEqual(normal.softwareGain(for: hardware), 1.0)
        XCTAssertEqual(muted.softwareGain(for: hardware), 1.0)
        XCTAssertEqual(software.controlMode, .softwareDSP)
        XCTAssertEqual(normal.softwareGain(for: software), 0.25, accuracy: 0.000_001)
        XCTAssertEqual(muted.softwareGain(for: software), 0.0)
    }

    func testMasterMuteFallsBackToSoftwareWhenDeviceHasNoWritableMute() {
        let capability = MasterVolumeDeviceCapabilities(
            volumeReadable: true,
            volumeWritable: true,
            muteReadable: false,
            muteWritable: false
        )
        XCTAssertEqual(
            MasterVolumeConfiguration(level: 0.7, muted: true).softwareGain(for: capability),
            0.0
        )
        XCTAssertEqual(
            MasterVolumeConfiguration(level: 0.7, muted: false).softwareGain(for: capability),
            1.0
        )
    }

    func testRealtimeMasterGainIsIndependentAndSmoothed() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        graph.masterGainLinear = 0.25
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        for _ in 0..<2_000 {
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, 0.8, -0.4, &left, &right)
            XCTAssertEqual(left, 0.2, accuracy: 0.000_01)
            XCTAssertEqual(right, -0.1, accuracy: 0.000_01)
        }
        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertEqual(diagnostics.masterGainLinear, 0.25, accuracy: 0.000_001)
    }


    func testMasterGainStillAppliesDuringGlobalGraphBypass() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }
        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        graph.bypassed = true
        graph.masterGainLinear = 0.25
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        var left: Float = 0
        var right: Float = 0
        for _ in 0..<2_000 {
            N60RenderKernelProcessStereoFrame(kernel, 0.8, -0.4, &left, &right)
        }
        XCTAssertEqual(left, 0.2, accuracy: 0.000_01)
        XCTAssertEqual(right, -0.1, accuracy: 0.000_01)
    }

    func testGraphBypassReturnsUntreatedStereoSamples() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(384_000)
        graph.inputGainLinear = 2.0
        graph.headroomGainLinear = 0.25
        graph.outputGainLinear = 0.5
        graph.balanceGainLeftLinear = 0
        graph.balanceGainRightLinear = 1
        graph.bypassed = true
        XCTAssertTrue(
            N60DSPGraphSnapshotSetEQBand(
                &graph,
                0,
                N60BiquadFilterTypePeaking,
                2_000,
                12,
                0.7,
                true
            )
        )
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        for frame in 0..<2_000 {
            let leftInput = Float(sin(Double(frame) * 0.017) * 0.6)
            let rightInput = Float(cos(Double(frame) * 0.013) * 0.4)
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, leftInput, rightInput, &left, &right)
            XCTAssertEqual(left, leftInput, accuracy: 0.000_001)
            XCTAssertEqual(right, rightInput, accuracy: 0.000_001)
        }
    }

    func testFirstSwitchToIndependentSeedsBothChannelsAndLaterRoundTripsPreserveEdits() {
        let linkedBand = EQBand(frequencyHz: 1_200, gainDB: 3, q: 1.1)
        var configuration = StereoEQConfiguration(linkedBands: [linkedBand])

        configuration.setChannelMode(.independent)
        XCTAssertEqual(configuration.leftBands, [linkedBand])
        XCTAssertEqual(configuration.rightBands, [linkedBand])

        configuration.setEditChannel(.left)
        var editedLeft = configuration.leftBands[0]
        editedLeft.gainDB = 7
        configuration.updateEditableBand(editedLeft)

        configuration.setChannelMode(.linked)
        configuration.setChannelMode(.independent)

        XCTAssertEqual(configuration.leftBands[0].gainDB, 7)
        XCTAssertEqual(configuration.rightBands[0].gainDB, 3)
    }

    func testUnsafeEQGainIsRejectedBeforeGraphPublication() {
        for gain in [300.0, -300.0, .infinity, -.infinity, .nan] {
            let configuration = StereoEQConfiguration(
                linkedBands: [EQBand(frequencyHz: 1_000, gainDB: gain, q: 1)]
            )
            XCTAssertThrowsError(
                try configuration.makeGraphSnapshot(
                    sampleRate: 96_000,
                    gainConfiguration: DSPGainConfiguration(),
                    bassManagementConfiguration: BassManagementConfiguration(),
                    playbackConfiguration: PlaybackControlConfiguration()
                ),
                "gain \(gain) must not reach the realtime graph"
            )
        }
    }

    func testTwentyFourDBBoundaryIsAcceptedAndBeyondBoundaryIsRejected() throws {
        for gain in [-24.0, 24.0] {
            let configuration = StereoEQConfiguration(
                linkedBands: [EQBand(frequencyHz: 1_000, gainDB: gain, q: 1)]
            )
            XCTAssertNoThrow(
                try configuration.makeGraphSnapshot(
                    sampleRate: 96_000,
                    gainConfiguration: DSPGainConfiguration(),
                    bassManagementConfiguration: BassManagementConfiguration(),
                    playbackConfiguration: PlaybackControlConfiguration()
                )
            )
        }

        for gain in [-24.001, 24.001] {
            let configuration = StereoEQConfiguration(
                linkedBands: [EQBand(frequencyHz: 1_000, gainDB: gain, q: 1)]
            )
            XCTAssertThrowsError(
                try configuration.makeGraphSnapshot(
                    sampleRate: 96_000,
                    gainConfiguration: DSPGainConfiguration(),
                    bassManagementConfiguration: BassManagementConfiguration(),
                    playbackConfiguration: PlaybackControlConfiguration()
                )
            )
        }

        var coefficients = N60BiquadCoefficients()
        XCTAssertTrue(N60BiquadDesign(N60BiquadFilterTypePeaking, 96_000, 1_000, 24, 1, &coefficients))
        XCTAssertTrue(N60BiquadDesign(N60BiquadFilterTypePeaking, 96_000, 1_000, -24, 1, &coefficients))
        XCTAssertFalse(N60BiquadDesign(N60BiquadFilterTypePeaking, 96_000, 1_000, 24.001, 1, &coefficients))
        XCTAssertFalse(N60BiquadDesign(N60BiquadFilterTypePeaking, 96_000, 1_000, -24.001, 1, &coefficients))
        XCTAssertFalse(N60BiquadDesign(N60BiquadFilterTypePeaking, 96_000, 1_000, 300, 1, &coefficients))
    }


    func testRawBypassDefersFIRPreparationPolicyAcrossRepeatedEdits() {
        let linearEQ = StereoEQConfiguration(phaseMode: .linearPhase)
        let room = RoomCorrectionConfiguration(enabled: true, filter: .validation)
        let bypassStates = [
            PlaybackControlConfiguration(balance: 0, globalBypassed: true, flatAuditionEnabled: false),
            PlaybackControlConfiguration(balance: 0, globalBypassed: false, flatAuditionEnabled: true),
            PlaybackControlConfiguration(balance: 0, globalBypassed: true, flatAuditionEnabled: true),
        ]

        for playback in bypassStates {
            for _ in 0..<32 {
                XCTAssertTrue(FIRUpdatePolicy.isRawBypassed(playback))
                XCTAssertFalse(FIRUpdatePolicy.shouldPrepareLinearPhase(stereoEQ: linearEQ, playback: playback))
                XCTAssertFalse(FIRUpdatePolicy.shouldPrepareRoomCorrection(roomCorrection: room, playback: playback))
            }
        }
    }

    func testProcessedModePreparesFIRStages() {
        let playback = PlaybackControlConfiguration()
        let linearEQ = StereoEQConfiguration(phaseMode: .linearPhase)
        let room = RoomCorrectionConfiguration(enabled: true, filter: .validation)
        XCTAssertFalse(FIRUpdatePolicy.isRawBypassed(playback))
        XCTAssertTrue(FIRUpdatePolicy.shouldPrepareLinearPhase(stereoEQ: linearEQ, playback: playback))
        XCTAssertTrue(FIRUpdatePolicy.shouldPrepareRoomCorrection(roomCorrection: room, playback: playback))
    }

    func testStereoGraphCompilesUpToSixtyFourBandsPerChannelAt384k() throws {
        let left = (0..<64).map { index in
            EQBand(
                frequencyHz: 40 * pow(1.07, Double(index)),
                gainDB: index.isMultiple(of: 2) ? 0.25 : -0.25,
                q: 1
            )
        }
        let right = (0..<64).map { index in
            EQBand(
                frequencyHz: 45 * pow(1.07, Double(index)),
                gainDB: index.isMultiple(of: 2) ? -0.25 : 0.25,
                q: 1
            )
        }
        let configuration = StereoEQConfiguration(
            channelMode: .independent,
            editChannel: .left,
            phaseMode: .minimumPhase,
            leftBands: left,
            rightBands: right,
            independentSeeded: true
        )

        let graph = try configuration.makeGraphSnapshot(
            sampleRate: 384_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )

        XCTAssertEqual(graph.eqBandCount, 128)
    }
}
