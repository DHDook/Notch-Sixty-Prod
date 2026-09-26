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

    func testZeroInterChannelDelayIsTransparent() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }
        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&graph, 0))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        for frame in 0..<2_000 {
            let leftInput = Float(sin(Double(frame) * 0.031) * 0.6)
            let rightInput = Float(cos(Double(frame) * 0.027) * 0.4)
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, leftInput, rightInput, &left, &right)
            XCTAssertEqual(left, leftInput, accuracy: 0.000_001)
            XCTAssertEqual(right, rightInput, accuracy: 0.000_001)
        }
    }

    func testSignedInterChannelDelaySelectsCorrectChannelAndExactIntegerTiming() {
        for signedDelay in [5.0, -5.0] {
            guard let kernel = N60RenderKernelCreate() else {
                return XCTFail("Unable to create render kernel")
            }
            defer { N60RenderKernelDestroy(kernel) }
            var graph = N60DSPGraphSnapshotMakeUnity(48_000)
            XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&graph, signedDelay))
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

            var leftImpulseIndex: Int?
            var rightImpulseIndex: Int?
            for frame in 0..<300 {
                let input: Float = frame == 0 ? 1 : 0
                var left: Float = 0
                var right: Float = 0
                N60RenderKernelProcessStereoFrame(kernel, input, input, &left, &right)
                if leftImpulseIndex == nil && abs(left) > 0.99 { leftImpulseIndex = frame }
                if rightImpulseIndex == nil && abs(right) > 0.99 { rightImpulseIndex = frame }
            }

            if signedDelay > 0 {
                XCTAssertEqual(leftImpulseIndex, 2)
                XCTAssertEqual(rightImpulseIndex, 242)
            } else {
                XCTAssertEqual(leftImpulseIndex, 242)
                XCTAssertEqual(rightImpulseIndex, 2)
            }
            let diagnostics = N60RenderKernelGetDiagnostics(kernel)
            XCTAssertEqual(diagnostics.interChannelDelayMs, signedDelay, accuracy: 0.000_001)
            XCTAssertEqual(diagnostics.interChannelAlignmentLatencyFrames, 2)
        }
    }

    func testFractionalInterChannelDelayTracksHalfSampleTimingWithUnityMagnitude() {
        let sampleRate = 48_000.0
        let relativeDelayFrames = 240.5
        let signedDelayMs = relativeDelayFrames / sampleRate * 1_000.0
        let frequency = 10_000.0
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }
        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&graph, signedDelayMs))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var inputSquare = 0.0
        var rightSquare = 0.0
        var errorSquare = 0.0
        var measured = 0
        for frame in 0..<30_000 {
            let phase = 2.0 * Double.pi * frequency * Double(frame) / sampleRate
            let sample = Float(0.4 * sin(phase))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
            if frame > 5_000 {
                let expectedPhase = 2.0 * Double.pi * frequency
                    * (Double(frame) - relativeDelayFrames - 2.0) / sampleRate
                let expected = 0.4 * sin(expectedPhase)
                inputSquare += Double(sample * sample)
                rightSquare += Double(right * right)
                let error = Double(right) - expected
                errorSquare += error * error
                measured += 1
            }
        }
        let inputRMS = sqrt(inputSquare / Double(measured))
        let rightRMS = sqrt(rightSquare / Double(measured))
        let errorRMS = sqrt(errorSquare / Double(measured))
        XCTAssertEqual(rightRMS, inputRMS, accuracy: 0.000_2)
        XCTAssertLessThan(errorRMS, 0.002)
    }

    func testGlobalBypassRemainsRawWithInterChannelDelayConfigured() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }
        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&graph, 12.34))
        graph.bypassed = true
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        for frame in 0..<4_000 {
            let leftInput = Float(sin(Double(frame) * 0.019) * 0.55)
            let rightInput = Float(cos(Double(frame) * 0.023) * 0.45)
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, leftInput, rightInput, &left, &right)
            XCTAssertEqual(left, leftInput, accuracy: 0.000_001)
            XCTAssertEqual(right, rightInput, accuracy: 0.000_001)
        }
    }

    func testInterChannelDelayRangeIsPartOfPlaybackConfiguration() {
        XCTAssertEqual(PlaybackControlConfiguration.interChannelDelayRange, -20.0...20.0)
        XCTAssertEqual(PlaybackControlConfiguration(interChannelDelayMs: 3.25).interChannelDelayMs, 3.25)
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

    func testSystemDefinedVolumeKeyDecodingUsesKeyDownOnly() {
        let volumeUpDownEvent = (0 << 16) | (0xA << 8)
        let volumeDownDownEvent = (1 << 16) | (0xA << 8)
        let volumeUpReleaseEvent = (0 << 16) | (0xB << 8)
        let muteDownEvent = (7 << 16) | (0xA << 8)

        XCTAssertEqual(
            CoreGraphicsGlobalVolumeKeyMonitor.action(subtype: 8, data1: volumeUpDownEvent),
            .increment
        )
        XCTAssertEqual(
            CoreGraphicsGlobalVolumeKeyMonitor.action(subtype: 8, data1: volumeDownDownEvent),
            .decrement
        )
        XCTAssertNil(CoreGraphicsGlobalVolumeKeyMonitor.action(subtype: 8, data1: volumeUpReleaseEvent))
        XCTAssertNil(CoreGraphicsGlobalVolumeKeyMonitor.action(subtype: 8, data1: muteDownEvent))
        XCTAssertNil(CoreGraphicsGlobalVolumeKeyMonitor.action(subtype: 7, data1: volumeUpDownEvent))
    }

    func testFixedVolumeDeviceUsesSoftwareMasterGainForKeyboardFallback() {
        let fixedVolume = MasterVolumeDeviceCapabilities(
            volumeReadable: false,
            volumeWritable: false,
            muteReadable: true,
            muteWritable: true
        )
        XCTAssertEqual(fixedVolume.controlMode, .softwareDSP)
        XCTAssertEqual(
            MasterVolumeConfiguration(level: 0.375, muted: false).softwareGain(for: fixedVolume),
            0.375,
            accuracy: 0.000_001
        )
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

    func testReferenceAuditionDelaysRawInputByPublishedLatency() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        graph.auditionMode = N60AuditionModeReference
        graph.latencyFrames = 3
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        let inputs: [Float] = [1, 0.5, -0.25, 0, 0, 0]
        var outputs: [Float] = []
        for sample in inputs {
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
            outputs.append(left)
            XCTAssertEqual(left, right, accuracy: 0.000_001)
        }
        XCTAssertEqual(outputs[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(outputs[1], 0, accuracy: 0.000_001)
        XCTAssertEqual(outputs[2], 0, accuracy: 0.000_001)
        XCTAssertEqual(outputs[3], 1, accuracy: 0.000_001)
        XCTAssertEqual(outputs[4], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(outputs[5], -0.25, accuracy: 0.000_001)
    }

    func testDeltaAuditionNullsUnityConvolutionAgainstLatencyMatchedReference() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var program = N60ConvolutionProgramInfo()
        var taps: [Float] = [1]
        XCTAssertTrue(taps.withUnsafeBufferPointer { buffer in
            N60RenderKernelPrepareConvolutionProgram(
                kernel,
                0,
                buffer.baseAddress!,
                nil,
                UInt32(buffer.count),
                0,
                &program
            )
        })

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&graph, 0, program, true))
        graph.auditionMode = N60AuditionModeDelta
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var maxAbs: Float = 0
        for frame in 0..<2_000 {
            let sample = Float(sin(Double(frame) * 0.031) * 0.4)
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, -sample, &left, &right)
            if frame > Int(program.engineLatencyFrames) + 16 {
                maxAbs = max(maxAbs, abs(left), abs(right))
            }
        }
        XCTAssertLessThan(maxAbs, 0.000_01)
    }

    func testGlobalBypassOverridesAuditionModeAndStillAppliesMasterGain() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        graph.bypassed = true
        graph.auditionMode = N60AuditionModeDelta
        graph.latencyFrames = 128
        graph.masterGainLinear = 0.5
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var left: Float = 0
        var right: Float = 0
        N60RenderKernelProcessStereoFrame(kernel, 0.4, -0.2, &left, &right)
        XCTAssertEqual(left, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(right, -0.1, accuracy: 0.000_001)
    }

    func testFlatCompatibilityAliasMapsToReferenceAudition() {
        var playback = PlaybackControlConfiguration(flatAuditionEnabled: true)
        XCTAssertEqual(playback.auditionMode, .reference)
        XCTAssertTrue(playback.flatAuditionEnabled)
        playback.flatAuditionEnabled = false
        XCTAssertEqual(playback.auditionMode, .processed)
        XCTAssertFalse(FIRUpdatePolicy.isRawBypassed(PlaybackControlConfiguration(auditionMode: .reference)))
        XCTAssertTrue(FIRUpdatePolicy.isRawBypassed(PlaybackControlConfiguration(globalBypassed: true)))
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
        let globalBypassStates = [
            PlaybackControlConfiguration(balance: 0, globalBypassed: true, auditionMode: .processed),
            PlaybackControlConfiguration(balance: 0, globalBypassed: true, auditionMode: .reference),
            PlaybackControlConfiguration(balance: 0, globalBypassed: true, auditionMode: .delta),
        ]

        for playback in globalBypassStates {
            for _ in 0..<32 {
                XCTAssertTrue(FIRUpdatePolicy.isRawBypassed(playback))
                XCTAssertFalse(FIRUpdatePolicy.shouldPrepareLinearPhase(stereoEQ: linearEQ, playback: playback))
                XCTAssertFalse(FIRUpdatePolicy.shouldPrepareRoomCorrection(roomCorrection: room, playback: playback))
            }
        }
    }

    func testReferenceAndDeltaKeepFIRStagesPrepared() {
        let linearEQ = StereoEQConfiguration(phaseMode: .linearPhase)
        let room = RoomCorrectionConfiguration(enabled: true, filter: .validation)
        for mode in [AuditionMode.reference, .delta] {
            let playback = PlaybackControlConfiguration(auditionMode: mode)
            XCTAssertFalse(FIRUpdatePolicy.isRawBypassed(playback))
            XCTAssertTrue(FIRUpdatePolicy.shouldPrepareLinearPhase(stereoEQ: linearEQ, playback: playback))
            XCTAssertTrue(FIRUpdatePolicy.shouldPrepareRoomCorrection(roomCorrection: room, playback: playback))
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

    func testAutomaticHeadroomAddsPredictiveAttenuationAndRespectsCap() throws {
        var eq = StereoEQConfiguration()
        eq.linkedBands = [
            EQBand(enabled: true, type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1),
            EQBand(enabled: true, type: .peaking, frequencyHz: 3_000, gainDB: 6, q: 1),
        ]
        var dynamics = DynamicsConfiguration()
        dynamics.automaticHeadroom.enabled = true
        dynamics.automaticHeadroom.maxAttenuationDB = 8
        let graph = try eq.makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: dynamics,
            playbackConfiguration: PlaybackControlConfiguration())
        let expected = Float(pow(10.0, -8.0 / 20.0))
        XCTAssertEqual(graph.headroomGainLinear, expected, accuracy: 0.000_001)
    }


    func testUnifiedDynamicEQCompilesFromMainEQBandsAtFullCapacity() throws {
        let count = EQConfiguration.maximumBandCount
        XCTAssertEqual(count, 64)
        let minimumFrequency = 30.0
        let maximumFrequency = 18_000.0
        let ratio = maximumFrequency / minimumFrequency
        let bands = (0..<count).map { index -> EQBand in
            let position = count > 1 ? Double(index) / Double(count - 1) : 0
            var dynamic = EQBandDynamicConfiguration()
            dynamic.enabled = true
            dynamic.direction = index.isMultiple(of: 2) ? .cutOnly : .both
            dynamic.maxBoostDB = 3
            return EQBand(
                enabled: true,
                type: .peaking,
                frequencyHz: minimumFrequency * pow(ratio, position),
                gainDB: index.isMultiple(of: 2) ? 0.25 : -0.25,
                q: 1.0,
                dynamic: dynamic
            )
        }
        let config = StereoEQConfiguration(linkedBands: bands)
        let graph = try config.makeGraphSnapshot(
            sampleRate: 384_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: DynamicsConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertEqual(graph.eqBandCount, 64)
        XCTAssertEqual(graph.dynamics.dynamicEQ.bandCount, 64)
        XCTAssertTrue(graph.dynamics.dynamicEQ.enabled)
        XCTAssertTrue(N60DynamicEQSnapshotIsValid(graph.dynamics.dynamicEQ))
    }

    func testUnifiedDynamicEQIsAnEQStageCapabilityNotASeparateConfiguredBank() throws {
        var dynamic = EQBandDynamicConfiguration()
        dynamic.enabled = true
        dynamic.thresholdDB = -30
        dynamic.ratio = 4
        let band = EQBand(
            type: .peaking,
            frequencyHz: 1_000,
            gainDB: 3,
            q: 1.0,
            dynamic: dynamic
        )
        var staleDynamics = DynamicsConfiguration()
        staleDynamics.dynamicEQ.enabled = true
        var staleBand = DynamicEQBandConfiguration()
        staleBand.frequencyHz = 8_000
        staleDynamics.dynamicEQ.bands = [staleBand]
        let config = StereoEQConfiguration(linkedBands: [band])
        let graph = try config.makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: staleDynamics,
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertEqual(graph.eqBandCount, 1)
        XCTAssertEqual(graph.dynamics.dynamicEQ.bandCount, 1)
        XCTAssertTrue(graph.dynamics.dynamicEQ.enabled)
    }

}
