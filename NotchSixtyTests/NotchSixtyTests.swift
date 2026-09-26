import CoreAudio
import Foundation
import XCTest
@testable import NotchSixty

final class NotchSixtyTests: XCTestCase {
    func testBootstrapTestBundleRuns() {
        XCTAssertTrue(true)
    }

    func testSampleRateRangeNormalizesBoundsAndMatchesRates() {
        let range = AudioSampleRateRange(minimum: 192_000, maximum: 44_100)
        XCTAssertEqual(range.minimum, 44_100)
        XCTAssertEqual(range.maximum, 192_000)
        XCTAssertTrue(range.contains(96_000))
        XCTAssertFalse(range.contains(384_000))
    }

    func testLifecycleAcceptsProductionStartupPath() throws {
        var machine = AudioLifecycleStateMachine()
        for state in [
            AudioLifecycleState.requestingPermission,
            .creatingTap,
            .creatingAggregate,
            .openingOutput,
            .starting,
            .running,
        ] {
            try machine.transition(to: state)
        }
        XCTAssertEqual(machine.state, .running)
    }

    func testLifecycleAcceptsReconfigurationAndRecoveryPaths() throws {
        var machine = AudioLifecycleStateMachine(initialState: .running)
        try machine.transition(to: .reconfiguring)
        try machine.transition(to: .running)
        try machine.transition(to: .recoveringOutput)
        try machine.transition(to: .running)
        XCTAssertEqual(machine.state, .running)
    }

    func testLifecycleCanRemainRecoveringUntilSelectedOutputReturns() {
        var machine = AudioLifecycleStateMachine(initialState: .running)
        XCTAssertNoThrow(try machine.transition(to: .recoveringOutput))
        XCTAssertEqual(machine.state, .recoveringOutput)
    }

    func testLifecycleRejectsInvalidJumpWithoutMutatingState() {
        var machine = AudioLifecycleStateMachine()
        XCTAssertThrowsError(try machine.transition(to: .running))
        XCTAssertEqual(machine.state, .idle)
    }

    func testStereoFloat32FormatIsAccepted() {
        let format = AudioStreamBasicDescription(
            mSampleRate: 96_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let description = AudioStreamFormatDescription(format)
        XCTAssertTrue(description.isSupportedStereoTransportFormat)
        XCTAssertEqual(description.sampleRate, 96_000)
        XCTAssertEqual(description.channelCount, 2)
    }

    func testNonStereoFormatIsRejected() {
        let format = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        XCTAssertFalse(AudioStreamFormatDescription(format).isSupportedStereoTransportFormat)
    }

    func testTransportCountersAccumulateAndUseLatestBufferedDepth() {
        let first = AudioTransportCounters(
            captureCallbacks: 10,
            outputCallbacks: 9,
            capturedFrames: 5_120,
            deliveredFrames: 4_608,
            gatedOutputCallbacks: 2,
            gatedOutputFrames: 1_024,
            bufferedFrames: 512
        )
        let second = AudioTransportCounters(
            captureCallbacks: 5,
            outputCallbacks: 5,
            capturedFrames: 2_560,
            deliveredFrames: 2_560,
            underrunFrames: 32,
            overrunFrames: 16,
            unsupportedBufferLayouts: 1,
            gatedOutputCallbacks: 3,
            gatedOutputFrames: 1_536,
            bufferedFrames: 0
        )
        let total = first + second
        XCTAssertEqual(total.captureCallbacks, 15)
        XCTAssertEqual(total.outputCallbacks, 14)
        XCTAssertEqual(total.capturedFrames, 7_680)
        XCTAssertEqual(total.deliveredFrames, 7_168)
        XCTAssertEqual(total.underrunFrames, 32)
        XCTAssertEqual(total.overrunFrames, 16)
        XCTAssertEqual(total.unsupportedBufferLayouts, 1)
        XCTAssertEqual(total.gatedOutputCallbacks, 5)
        XCTAssertEqual(total.gatedOutputFrames, 2_560)
        XCTAssertEqual(total.bufferedFrames, 0)
    }

    func testStartupGatePolicyKeepsOneHardwareBufferQueuedAfterOpening() {
        let policy = AudioStartupGatePolicy(outputBufferFrames: 512, sampleRate: 384_000)
        XCTAssertEqual(policy.steadyStateTargetFrames, 512)
        XCTAssertEqual(policy.activationBufferedFrames, 1_024)
        XCTAssertEqual(policy.fadeInFrames, 4_608)
    }

    func testStartupGatePolicyNeverUsesZeroBufferOrFadeFrames() {
        let policy = AudioStartupGatePolicy(outputBufferFrames: 0, sampleRate: 0, fadeInMilliseconds: 0)
        XCTAssertEqual(policy.steadyStateTargetFrames, 1)
        XCTAssertEqual(policy.activationBufferedFrames, 2)
        XCTAssertEqual(policy.fadeInFrames, 1)
    }

    func testStartupGatePolicyAvoidsUInt32Overflow() {
        let policy = AudioStartupGatePolicy(outputBufferFrames: UInt32.max, sampleRate: 384_000)
        XCTAssertEqual(policy.steadyStateTargetFrames, UInt32.max)
        XCTAssertEqual(policy.activationBufferedFrames, UInt32.max)
    }

    func testRenderKernelUnityIsTransparentAcrossSupportedRates() throws {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            let graph = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, 0.25, -0.5, &left, &right)

            XCTAssertEqual(left, 0.25, accuracy: 0.000_001)
            XCTAssertEqual(right, -0.5, accuracy: 0.000_001)

            let diagnostics = N60RenderKernelGetDiagnostics(kernel)
            XCTAssertEqual(diagnostics.sampleRate, rate, accuracy: 0.001)
            XCTAssertEqual(diagnostics.channelCount, 2)
            XCTAssertEqual(diagnostics.latencyFrames, 0)
            XCTAssertFalse(diagnostics.bypassed)
            XCTAssertFalse(diagnostics.crossoverEnabled)
        }
    }

    func testRenderKernelAppliesGainSnapshotAndBypass() throws {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        graph.inputGainLinear = 0.5
        graph.outputGainLinear = 0.25
        graph.latencyFrames = 64
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var left: Float = 0
        var right: Float = 0
        N60RenderKernelProcessStereoFrame(kernel, 0.8, -0.4, &left, &right)
        XCTAssertEqual(left, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(right, -0.05, accuracy: 0.000_001)
        XCTAssertEqual(N60RenderKernelGetDiagnostics(kernel).latencyFrames, 64)

        graph.bypassed = true
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        N60RenderKernelProcessStereoFrame(kernel, 0.8, -0.4, &left, &right)
        XCTAssertEqual(left, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(right, -0.4, accuracy: 0.000_001)
    }

    func testRenderKernelSanitizesNonFiniteSamplesAndRejectsInvalidGraphs() throws {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        var invalid = N60DSPGraphSnapshotMakeUnity(96_000)
        invalid.channelCount = 1
        XCTAssertFalse(N60RenderKernelPublishSnapshot(kernel, invalid))

        var left: Float = 1
        var right: Float = 1
        N60RenderKernelProcessStereoFrame(kernel, Float.nan, Float.infinity, &left, &right)
        XCTAssertEqual(left, 0)
        XCTAssertEqual(right, 0)
        XCTAssertEqual(N60RenderKernelGetDiagnostics(kernel).sanitizedNonFiniteSamples, 2)
    }

    func testParametricEQPeakingCenterGainAcrossSupportedRates() {
        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            let gain = measuredEQGainDB(
                sampleRate: rate,
                toneFrequency: 1_000,
                filterType: N60BiquadFilterTypePeaking,
                filterFrequency: 1_000,
                gainDB: 6,
                q: 0.707
            )
            XCTAssertEqual(gain, 6.0, accuracy: 0.15, "Unexpected 1 kHz peaking gain at \(rate) Hz")
        }
    }

    func testParametricEQLowPassAndHighPassHaveExpectedDirection() {
        let lowPassLowTone = measuredEQGainDB(sampleRate: 48_000, toneFrequency: 200, filterType: N60BiquadFilterTypeLowPass, filterFrequency: 2_000, gainDB: 0, q: 0.707)
        let lowPassHighTone = measuredEQGainDB(sampleRate: 48_000, toneFrequency: 10_000, filterType: N60BiquadFilterTypeLowPass, filterFrequency: 2_000, gainDB: 0, q: 0.707)
        XCTAssertGreaterThan(lowPassLowTone, -0.5)
        XCTAssertLessThan(lowPassHighTone, -20)

        let highPassLowTone = measuredEQGainDB(sampleRate: 48_000, toneFrequency: 200, filterType: N60BiquadFilterTypeHighPass, filterFrequency: 2_000, gainDB: 0, q: 0.707)
        let highPassHighTone = measuredEQGainDB(sampleRate: 48_000, toneFrequency: 10_000, filterType: N60BiquadFilterTypeHighPass, filterFrequency: 2_000, gainDB: 0, q: 0.707)
        XCTAssertLessThan(highPassLowTone, -20)
        XCTAssertGreaterThan(highPassHighTone, -0.5)
    }

    func testParametricEQShelvesAndNotchHaveExpectedResponse() {
        let lowShelfBass = measuredEQGainDB(sampleRate: 48_000, toneFrequency: 100, filterType: N60BiquadFilterTypeLowShelf, filterFrequency: 1_000, gainDB: 6, q: 0.707)
        let lowShelfTreble = measuredEQGainDB(sampleRate: 48_000, toneFrequency: 10_000, filterType: N60BiquadFilterTypeLowShelf, filterFrequency: 1_000, gainDB: 6, q: 0.707)
        XCTAssertGreaterThan(lowShelfBass, 5.0)
        XCTAssertLessThan(abs(lowShelfTreble), 0.5)

        let highShelfBass = measuredEQGainDB(sampleRate: 48_000, toneFrequency: 100, filterType: N60BiquadFilterTypeHighShelf, filterFrequency: 1_000, gainDB: 6, q: 0.707)
        let highShelfTreble = measuredEQGainDB(sampleRate: 48_000, toneFrequency: 10_000, filterType: N60BiquadFilterTypeHighShelf, filterFrequency: 1_000, gainDB: 6, q: 0.707)
        XCTAssertLessThan(abs(highShelfBass), 0.5)
        XCTAssertGreaterThan(highShelfTreble, 5.0)

        let notchCenter = measuredEQGainDB(sampleRate: 48_000, toneFrequency: 1_000, filterType: N60BiquadFilterTypeNotch, filterFrequency: 1_000, gainDB: 0, q: 2.0)
        XCTAssertLessThan(notchCenter, -30)
    }

    func testAllPassMaintainsUnityMagnitudeAcrossSupportedRates() {
        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            for tone in [100.0, 1_000.0, min(10_000.0, rate * 0.20)] {
                let gain = measuredEQGainDB(
                    sampleRate: rate,
                    toneFrequency: tone,
                    filterType: N60BiquadFilterTypeAllPass,
                    filterFrequency: min(2_000.0, rate * 0.10),
                    gainDB: 0,
                    q: 0.707
                )
                XCTAssertEqual(gain, 0.0, accuracy: 0.08, "All-pass magnitude drift at \(rate) Hz / \(tone) Hz")
            }
        }
    }

    func testAllPassIsRejectedByLinearPhaseProjection() {
        let configuration = EQConfiguration(
            phaseMode: .linearPhase,
            bands: [EQBand(type: .allPass, frequencyHz: 1_000, gainDB: 0, q: 0.707)]
        )
        XCTAssertThrowsError(try configuration.linearPhaseBands(sampleRate: 48_000)) { error in
            XCTAssertEqual(error as? EQConfigurationError, .allPassRequiresMinimumPhase)
        }
    }

    func testParametricEQRejectsInvalidBandDesigns() {
        var graph = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertFalse(N60DSPGraphSnapshotSetEQBand(&graph, 0, N60BiquadFilterTypePeaking, 24_000, 6, 0.707, true))
        XCTAssertFalse(N60DSPGraphSnapshotSetEQBand(&graph, 0, N60BiquadFilterTypePeaking, 1_000, 6, 0, true))
    }

    func testParametricEQPerBandAndStageBypassAreDry() {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetEQBand(&graph, 0, N60BiquadFilterTypePeaking, 1_000, 12, 0.707, false))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var left: Float = 0
        var right: Float = 0
        N60RenderKernelProcessStereoFrame(kernel, 0.2, -0.3, &left, &right)
        XCTAssertEqual(left, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(right, -0.3, accuracy: 0.000_001)

        XCTAssertTrue(N60DSPGraphSnapshotSetEQBand(&graph, 0, N60BiquadFilterTypePeaking, 1_000, 12, 0.707, true))
        graph.eqBypassed = true
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        N60RenderKernelProcessStereoFrame(kernel, 0.2, -0.3, &left, &right)
        XCTAssertEqual(left, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(right, -0.3, accuracy: 0.000_001)
    }

    func testLinkwitzRiley24And48AreMinus6DBAtCrossover() {
        for topology in [N60CrossoverTopologyLinkwitzRiley24, N60CrossoverTopologyLinkwitzRiley48] {
            let mainsGain = measuredCrossoverGainDB(
                sampleRate: 48_000,
                toneFrequency: 80,
                crossoverFrequency: 80,
                topology: topology,
                monitorMode: N60CrossoverMonitorModeMainsOnly
            )
            let subGain = measuredCrossoverGainDB(
                sampleRate: 48_000,
                toneFrequency: 80,
                crossoverFrequency: 80,
                topology: topology,
                monitorMode: N60CrossoverMonitorModeSubOnly
            )
            XCTAssertEqual(mainsGain, -6.02, accuracy: 0.25)
            XCTAssertEqual(subGain, -6.02, accuracy: 0.25)
        }
    }

    func testLinkwitzRileyRecombinedPreviewIsFlatForCorrelatedStereo() {
        for topology in [N60CrossoverTopologyLinkwitzRiley24, N60CrossoverTopologyLinkwitzRiley48] {
            for tone in [25.0, 80.0, 500.0, 5_000.0] {
                let gain = measuredCrossoverGainDB(
                    sampleRate: 48_000,
                    toneFrequency: tone,
                    crossoverFrequency: 80,
                    topology: topology,
                    monitorMode: N60CrossoverMonitorModeRecombined
                )
                XCTAssertEqual(gain, 0.0, accuracy: 0.2, "Unexpected recombined gain for \(topology) at \(tone) Hz")
            }
        }
    }

    func testCrossoverRejectsInvalidDesignsAndBypassStaysDry() {
        var graph = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertFalse(
            N60DSPGraphSnapshotSetCrossover(
                &graph,
                24_000,
                N60CrossoverTopologyLinkwitzRiley24,
                N60CrossoverMonitorModeRecombined,
                1,
                false,
                true
            )
        )
        XCTAssertFalse(
            N60DSPGraphSnapshotSetCrossover(
                &graph,
                80,
                N60CrossoverTopologyLinkwitzRiley24,
                N60CrossoverMonitorModeRecombined,
                -1,
                false,
                true
            )
        )

        XCTAssertTrue(
            N60DSPGraphSnapshotSetCrossover(
                &graph,
                80,
                N60CrossoverTopologyLinkwitzRiley24,
                N60CrossoverMonitorModeRecombined,
                1,
                false,
                false
            )
        )
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        var left: Float = 0
        var right: Float = 0
        N60RenderKernelProcessStereoFrame(kernel, 0.25, -0.4, &left, &right)
        XCTAssertEqual(left, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(right, -0.4, accuracy: 0.000_001)
    }

    func testSubPolarityInversionFlipsSubOnlyOutput() {
        let normal = measuredCrossoverSample(inverted: false)
        let inverted = measuredCrossoverSample(inverted: true)
        XCTAssertEqual(inverted, -normal, accuracy: 0.000_1)
    }

    func test384KHz64BandEQPlusLR48StressRemainsFinite() {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(384_000)
        for index in 0..<Int(N60_MAX_EQ_BANDS) {
            let position = Double(index) / Double(Int(N60_MAX_EQ_BANDS) - 1)
            let frequency = 30.0 * pow(18_000.0 / 30.0, position)
            XCTAssertTrue(
                N60DSPGraphSnapshotSetEQBand(
                    &graph,
                    UInt32(index),
                    N60BiquadFilterTypePeaking,
                    frequency,
                    index.isMultiple(of: 2) ? 0.25 : -0.25,
                    1.0,
                    true
                )
            )
        }
        XCTAssertTrue(
            N60DSPGraphSnapshotSetCrossover(
                &graph,
                80,
                N60CrossoverTopologyLinkwitzRiley48,
                N60CrossoverMonitorModeRecombined,
                1,
                false,
                true
            )
        )
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var left: Float = 0
        var right: Float = 0
        for frame in 0..<32_768 {
            let input = Float(sin(2.0 * Double.pi * 1_000.0 * Double(frame) / 384_000.0) * 0.1)
            N60RenderKernelProcessStereoFrame(kernel, input, input, &left, &right)
            XCTAssertTrue(left.isFinite)
            XCTAssertTrue(right.isFinite)
        }

        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertEqual(diagnostics.sanitizedNonFiniteSamples, 0)
        XCTAssertEqual(diagnostics.snapshotReadMisses, 0)
        XCTAssertTrue(diagnostics.crossoverEnabled)
        XCTAssertEqual(diagnostics.crossoverSectionCount, 4)
        XCTAssertEqual(diagnostics.eqBandCount, UInt32(N60_MAX_EQ_BANDS))
    }

    @MainActor
    func testSelectionFollowsStableUIDAcrossTransientDeviceIDChange() throws {
        let catalog = StubOutputDeviceCatalog(devices: [
            makeDevice(deviceID: 10, uid: "device-a", name: "Output A"),
            makeDevice(deviceID: 20, uid: "device-b", name: "Output B"),
        ])
        let engine = AudioIOEngine(deviceCatalog: catalog)
        try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "device-b")
        XCTAssertEqual(engine.selectedOutputDevice?.deviceID, 20)

        catalog.devices = [makeDevice(deviceID: 99, uid: "device-b", name: "Output B")]
        try engine.refreshOutputDevices()
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "device-b")
        XCTAssertEqual(engine.selectedOutputDevice?.deviceID, 99)
    }

    @MainActor
    func testRefreshPreservesSelectedUIDWhenHardwareDisappears() throws {
        let catalog = StubOutputDeviceCatalog(devices: [makeDevice(deviceID: 20, uid: "device-b", name: "Output B")])
        let engine = AudioIOEngine(deviceCatalog: catalog)
        try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "device-b")
        catalog.devices = []
        try engine.refreshOutputDevices()

        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "device-b")
        XCTAssertNil(engine.selectedOutputDevice)
        XCTAssertFalse(engine.diagnosticsSnapshot().selectedOutputPresent)
    }

    @MainActor
    func testSelectingUnavailableOutputFailsWithoutChangingRoute() throws {
        let catalog = StubOutputDeviceCatalog(devices: [makeDevice(deviceID: 10, uid: "device-a", name: "Output A")])
        let engine = AudioIOEngine(
            deviceCatalog: catalog,
            initialRouteConfiguration: AudioRouteConfiguration(selectedOutputUID: "persisted-device")
        )
        try engine.refreshOutputDevices()
        XCTAssertThrowsError(try engine.selectOutput(uid: "missing-device"))
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "persisted-device")
    }

    private func measuredEQGainDB(
        sampleRate: Double,
        toneFrequency: Double,
        filterType: N60BiquadFilterType,
        filterFrequency: Double,
        gainDB: Double,
        q: Double
    ) -> Double {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return .nan
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        guard N60DSPGraphSnapshotSetEQBand(&graph, 0, filterType, filterFrequency, gainDB, q, true) else {
            XCTFail("Unable to configure EQ band")
            return .nan
        }
        guard N60RenderKernelPublishSnapshot(kernel, graph) else {
            XCTFail("Unable to publish EQ graph")
            return .nan
        }

        let warmupFrames = 8_192
        let measurementFrames = 16_384
        var inputPower = 0.0
        var outputPower = 0.0
        var left: Float = 0
        var right: Float = 0

        for frame in 0..<(warmupFrames + measurementFrames) {
            let phase = 2.0 * Double.pi * toneFrequency * Double(frame) / sampleRate
            let input = Float(sin(phase) * 0.1)
            N60RenderKernelProcessStereoFrame(kernel, input, input, &left, &right)
            if frame >= warmupFrames {
                inputPower += Double(input * input)
                outputPower += Double(left * left)
            }
        }

        guard inputPower > 0, outputPower > 0 else { return -.infinity }
        return 10.0 * log10(outputPower / inputPower)
    }

    private func measuredCrossoverGainDB(
        sampleRate: Double,
        toneFrequency: Double,
        crossoverFrequency: Double,
        topology: N60CrossoverTopology,
        monitorMode: N60CrossoverMonitorMode
    ) -> Double {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return .nan
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        guard N60DSPGraphSnapshotSetCrossover(
            &graph,
            crossoverFrequency,
            topology,
            monitorMode,
            1,
            false,
            true
        ), N60RenderKernelPublishSnapshot(kernel, graph) else {
            XCTFail("Unable to configure crossover")
            return .nan
        }

        let warmupFrames = max(Int(sampleRate / max(toneFrequency, 1) * 16), 8_192)
        let measurementFrames = 32_768
        var inputPower = 0.0
        var outputPower = 0.0
        var left: Float = 0
        var right: Float = 0
        for frame in 0..<(warmupFrames + measurementFrames) {
            let input = Float(sin(2.0 * Double.pi * toneFrequency * Double(frame) / sampleRate) * 0.1)
            N60RenderKernelProcessStereoFrame(kernel, input, input, &left, &right)
            if frame >= warmupFrames {
                inputPower += Double(input * input)
                outputPower += Double(left * left)
            }
        }
        guard inputPower > 0, outputPower > 0 else { return -.infinity }
        return 10.0 * log10(outputPower / inputPower)
    }

    private func measuredCrossoverSample(inverted: Bool) -> Float {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return .nan
        }
        defer { N60RenderKernelDestroy(kernel) }
        var graph = N60DSPGraphSnapshotMakeUnity(48_000)
        guard N60DSPGraphSnapshotSetCrossover(
            &graph,
            80,
            N60CrossoverTopologyLinkwitzRiley24,
            N60CrossoverMonitorModeSubOnly,
            1,
            inverted,
            true
        ), N60RenderKernelPublishSnapshot(kernel, graph) else {
            XCTFail("Unable to configure crossover")
            return .nan
        }
        var left: Float = 0
        var right: Float = 0
        for frame in 0..<16_001 {
            let input = Float(sin(2.0 * Double.pi * 40.0 * Double(frame) / 48_000.0) * 0.1)
            N60RenderKernelProcessStereoFrame(kernel, input, input, &left, &right)
        }
        return left
    }

    private func makeDevice(deviceID: AudioDeviceID, uid: String, name: String) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: deviceID,
            uid: uid,
            name: name,
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)]
        )
    }
}

private final class StubOutputDeviceCatalog: OutputDeviceCataloging {
    var devices: [AudioOutputDevice]
    init(devices: [AudioOutputDevice]) { self.devices = devices }
    func outputDevices() throws -> [AudioOutputDevice] { devices }
}


extension NotchSixtyTests {
    func testMainsNotchSuppressesConfiguredFundamentalAcrossRates() throws {
        for rate in [48_000.0, 96_000.0, 384_000.0] {
            let gainDB = try measuredMainsNotchGainDB(
                sampleRate: rate,
                toneFrequency: 60,
                region: .hz60,
                harmonic: 1,
                depthDB: -24
            )
            XCTAssertLessThan(gainDB, -20.0, "Insufficient 60 Hz rejection at \(rate) Hz")
        }
    }

    func testMainsNotchTargetsSelectedHarmonicWithoutBroadLevelLoss() throws {
        let secondHarmonic = try measuredMainsNotchGainDB(
            sampleRate: 96_000,
            toneFrequency: 120,
            region: .hz60,
            harmonic: 2,
            depthDB: -18
        )
        let offBand = try measuredMainsNotchGainDB(
            sampleRate: 96_000,
            toneFrequency: 1_000,
            region: .hz60,
            harmonic: 2,
            depthDB: -18
        )
        XCTAssertLessThan(secondHarmonic, -14.0)
        XCTAssertGreaterThan(offBand, -0.15)
    }

    func testMainsNotchDisabledIsTransparent() throws {
        guard let kernel = N60RenderKernelCreate() else { return XCTFail("Unable to create render kernel") }
        defer { N60RenderKernelDestroy(kernel) }
        var dynamics = DynamicsConfiguration()
        dynamics.mainsNotch.enabled = false
        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        graph.dynamics = try dynamics.makeSnapshot(sampleRate: 96_000)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        for frame in 0..<4_000 {
            let leftIn = Float(sin(Double(frame) * 0.071) * 0.35)
            let rightIn = Float(cos(Double(frame) * 0.053) * 0.27)
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, leftIn, rightIn, &left, &right)
            XCTAssertEqual(left, leftIn, accuracy: 0.000_001)
            XCTAssertEqual(right, rightIn, accuracy: 0.000_001)
        }
    }

    private func measuredMainsNotchGainDB(
        sampleRate: Double,
        toneFrequency: Double,
        region: MainsRegion,
        harmonic: Int,
        depthDB: Double
    ) throws -> Double {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to create render kernel")
            return 0
        }
        defer { N60RenderKernelDestroy(kernel) }

        var dynamics = DynamicsConfiguration()
        dynamics.mainsNotch.enabled = true
        dynamics.mainsNotch.region = region
        dynamics.mainsNotch.harmonicCount = max(1, harmonic)
        dynamics.mainsNotch.q = 30
        dynamics.mainsNotch.harmonicDepthsDB = Array(repeating: 0, count: MainsNotchConfiguration.maximumHarmonics)
        dynamics.mainsNotch.harmonicDepthsDB[harmonic - 1] = depthDB

        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.dynamics = try dynamics.makeSnapshot(sampleRate: sampleRate)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        // A 60 Hz, Q=30 cut has a long physical settling time. Give the
        // realtime IIR enough time to reach steady state before evaluating the
        // requested depth, especially at the 384 kHz validation rate.
        let frameCount = max(Int(sampleRate * 1.25), 60_000)
        let settleFrames = max(Int(sampleRate * 0.55), 24_000)
        var inputEnergy = 0.0
        var outputEnergy = 0.0
        var measuredFrames = 0
        for frame in 0..<frameCount {
            let sample = Float(0.1 * sin(2.0 * Double.pi * toneFrequency * Double(frame) / sampleRate))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
            if frame >= settleFrames {
                inputEnergy += Double(sample * sample)
                outputEnergy += Double(left * left)
                measuredFrames += 1
            }
        }
        let inputRMS = sqrt(inputEnergy / Double(measuredFrames))
        let outputRMS = sqrt(outputEnergy / Double(measuredFrames))
        return 20.0 * log10(max(outputRMS, 1.0e-12) / max(inputRMS, 1.0e-12))
    }
}


extension NotchSixtyTests {
    func testMainsHumDetectorFindsOffsetFundamental() throws {
        guard let kernel = N60RenderKernelCreate() else { return XCTFail("Unable to create render kernel") }
        defer { N60RenderKernelDestroy(kernel) }
        let sampleRate = 48_000.0
        var dynamics = DynamicsConfiguration()
        dynamics.mainsNotch.enabled = false
        dynamics.mainsNotch.region = .hz60
        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.dynamics = try dynamics.makeSnapshot(sampleRate: sampleRate)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        let frequency = 60.75
        for frame in 0..<Int(sampleRate * 2.2) {
            let sample = Float(0.08 * sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
        }
        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertEqual(Double(diagnostics.mainsDetectedFrequencyHz), frequency, accuracy: 0.35)
        XCTAssertGreaterThan(diagnostics.mainsDetectionConfidence, 0.70)
    }

    func testMainsHumDetectorRejectsOutOfBandTone() throws {
        guard let kernel = N60RenderKernelCreate() else { return XCTFail("Unable to create render kernel") }
        defer { N60RenderKernelDestroy(kernel) }
        let sampleRate = 48_000.0
        var dynamics = DynamicsConfiguration()
        dynamics.mainsNotch.region = .hz60
        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.dynamics = try dynamics.makeSnapshot(sampleRate: sampleRate)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        for frame in 0..<Int(sampleRate * 1.2) {
            let sample = Float(0.1 * sin(2.0 * Double.pi * 1_000.0 * Double(frame) / sampleRate))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
        }
        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertLessThan(diagnostics.mainsDetectionConfidence, 0.25)
    }

    func testMainsNotchRetuneTransitionRemainsFiniteAndBounded() throws {
        guard let kernel = N60RenderKernelCreate() else { return XCTFail("Unable to create render kernel") }
        defer { N60RenderKernelDestroy(kernel) }
        let sampleRate = 48_000.0
        var dynamics = DynamicsConfiguration()
        dynamics.mainsNotch.enabled = true
        dynamics.mainsNotch.harmonicCount = 1
        dynamics.mainsNotch.harmonicDepthsDB = Array(repeating: 0, count: MainsNotchConfiguration.maximumHarmonics)
        dynamics.mainsNotch.harmonicDepthsDB[0] = -24
        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.dynamics = try dynamics.makeSnapshot(sampleRate: sampleRate)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        var previous: Float = 0
        var maximumJump: Float = 0
        for frame in 0..<12_000 {
            if frame == 6_000 {
                dynamics.mainsNotch.detectedFundamentalHz = 60.8
                graph.dynamics = try dynamics.makeSnapshot(sampleRate: sampleRate)
                XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
            }
            let sample = Float(0.1 * sin(2.0 * Double.pi * 60.4 * Double(frame) / sampleRate))
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
            XCTAssertTrue(left.isFinite)
            maximumJump = max(maximumJump, abs(left - previous))
            previous = left
        }
        XCTAssertLessThan(maximumJump, 0.03)
    }
}


extension NotchSixtyTests {
    func testSpectralDenoiserQualityModesHaveExplicitPowerOfTwoContracts() throws {
        for (quality, expected) in [
            (N60DenoiserQualityQuality, UInt32(1024)),
            (N60DenoiserQualityHigh, UInt32(2048)),
            (N60DenoiserQualityUltra, UInt32(4096)),
        ] {
            var snapshot = N60SpectralDenoiserSnapshotMakeBypassed(96_000)
            XCTAssertTrue(N60SpectralDenoiserSnapshotConfigure(
                &snapshot, 96_000, true, N60DenoiserTuningStandard, quality,
                0.5, -60, false, 0, 150, 0, N60DenoiserProfileCommandNone
            ))
            XCTAssertEqual(snapshot.fftSize, expected)
            XCTAssertEqual(snapshot.hopSize, expected / 2)
            XCTAssertEqual(snapshot.latencyFrames, expected)
            XCTAssertTrue(N60SpectralDenoiserSnapshotIsValid(snapshot, 96_000))
        }
    }

    func testSpectralDenoiserDisabledPathIsExactlyTransparent() throws {
        guard let runtime = N60SpectralDenoiserCreate() else {
            XCTFail("Unable to allocate spectral denoiser")
            return
        }
        defer { N60SpectralDenoiserDestroy(runtime) }
        var snapshot = N60SpectralDenoiserSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60SpectralDenoiserSnapshotConfigure(
            &snapshot, 48_000, false, N60DenoiserTuningNatural, N60DenoiserQualityHigh,
            0.5, -72, false, 0, 150, 0, N60DenoiserProfileCommandNone
        ))
        for frame in 0..<12_000 {
            let left = Float(sin(Double(frame) * 0.071)) * 0.37
            let right = Float(cos(Double(frame) * 0.043)) * 0.29
            var outputLeft: Float = 0
            var outputRight: Float = 0
            N60SpectralDenoiserProcessStereoFrame(runtime, snapshot, 48_000, left, right, &outputLeft, &outputRight)
            XCTAssertEqual(outputLeft, left, accuracy: 0)
            XCTAssertEqual(outputRight, right, accuracy: 0)
        }
    }

    func testSpectralDenoiserCapturedProfileReducesStationaryNoiseWithLinkedStereoGain() throws {
        guard let runtime = N60SpectralDenoiserCreate() else {
            XCTFail("Unable to allocate spectral denoiser")
            return
        }
        defer { N60SpectralDenoiserDestroy(runtime) }
        var snapshot = N60SpectralDenoiserSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60SpectralDenoiserSnapshotConfigure(
            &snapshot, 48_000, true, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
            0.8, -48, false, 0, 150, 1, N60DenoiserProfileCommandCapture
        ))

        var state: UInt32 = 0x1234ABCD
        var inputSquare = 0.0
        var outputSquare = 0.0
        var measured = 0
        let totalFrames = 48_000 * 4
        for frame in 0..<totalFrames {
            state = state &* 1_664_525 &+ 1_013_904_223
            let unit = Float(state & 0xFFFF) / 32_767.5 - 1.0
            let left = unit * 0.045
            let right = left * 0.5
            var outputLeft: Float = 0
            var outputRight: Float = 0
            N60SpectralDenoiserProcessStereoFrame(runtime, snapshot, 48_000, left, right, &outputLeft, &outputRight)
            if frame > 48_000 * 3 {
                inputSquare += Double(left * left)
                outputSquare += Double(outputLeft * outputLeft)
                measured += 1
                if abs(outputLeft) > 1.0e-5 {
                    XCTAssertEqual(outputRight / outputLeft, 0.5, accuracy: 0.015)
                }
            }
        }
        let inputRMS = sqrt(inputSquare / Double(measured))
        let outputRMS = sqrt(outputSquare / Double(measured))
        XCTAssertLessThan(outputRMS, inputRMS * 0.75)
        let telemetry = N60SpectralDenoiserRuntimeTelemetry(runtime)
        XCTAssertTrue(telemetry.profileReady)
        XCTAssertTrue(telemetry.capturedProfile)
        XCTAssertFalse(telemetry.captureActive)
        XCTAssertGreaterThan(telemetry.meanSuppressionDB, 1.0)
        XCTAssertGreaterThan(telemetry.maxSuppressionDB, telemetry.meanSuppressionDB)
    }

    func testSpectralDenoiserProfileResetReturnsToAdaptiveLearning() throws {
        guard let runtime = N60SpectralDenoiserCreate() else {
            XCTFail("Unable to allocate spectral denoiser")
            return
        }
        defer { N60SpectralDenoiserDestroy(runtime) }
        var snapshot = N60SpectralDenoiserSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60SpectralDenoiserSnapshotConfigure(
            &snapshot, 48_000, false, N60DenoiserTuningStandard, N60DenoiserQualityQuality,
            0.5, -60, false, 0, 150, 1, N60DenoiserProfileCommandCapture
        ))
        var left: Float = 0
        var right: Float = 0
        for frame in 0..<(48_000 + 2_048) {
            let noise = Float(sin(Double(frame) * 0.713)) * 0.02
            N60SpectralDenoiserProcessStereoFrame(runtime, snapshot, 48_000, noise, noise, &left, &right)
        }
        XCTAssertTrue(N60SpectralDenoiserRuntimeTelemetry(runtime).profileReady)

        snapshot.profileRevision = 2
        snapshot.profileCommand = N60DenoiserProfileCommandReset
        N60SpectralDenoiserProcessStereoFrame(runtime, snapshot, 48_000, 0, 0, &left, &right)
        let telemetry = N60SpectralDenoiserRuntimeTelemetry(runtime)
        XCTAssertFalse(telemetry.profileReady)
        XCTAssertFalse(telemetry.capturedProfile)
        XCTAssertFalse(telemetry.captureActive)
    }
}


extension NotchSixtyTests {
    func testSpectralDenoiserGraphLatencyTracksQualityOnlyWhenEnabled() throws {
        for (quality, expected) in [
            (SpectralDenoiserQuality.quality, UInt32(1024)),
            (.high, UInt32(2048)),
            (.ultra, UInt32(4096)),
        ] {
            var dynamics = DynamicsConfiguration()
            dynamics.spectralDenoiser.enabled = true
            dynamics.spectralDenoiser.quality = quality
            let graph = try StereoEQConfiguration().makeGraphSnapshot(
                sampleRate: 96_000,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: BassManagementConfiguration(),
                dynamicsConfiguration: dynamics,
                playbackConfiguration: PlaybackControlConfiguration()
            )
            XCTAssertEqual(graph.latencyFrames, expected)
            XCTAssertEqual(graph.dynamics.spectralDenoiser.latencyFrames, expected)

            dynamics.spectralDenoiser.enabled = false
            let bypassed = try StereoEQConfiguration().makeGraphSnapshot(
                sampleRate: 96_000,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: BassManagementConfiguration(),
                dynamicsConfiguration: dynamics,
                playbackConfiguration: PlaybackControlConfiguration()
            )
            XCTAssertEqual(bypassed.latencyFrames, 0)
        }
    }

    func testSpectralDenoiserGraphUnityBeforeProfileReadyMatchesLatencyReference() throws {
        guard let processedKernel = N60RenderKernelCreate(), let referenceKernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernels")
            return
        }
        defer {
            N60RenderKernelDestroy(processedKernel)
            N60RenderKernelDestroy(referenceKernel)
        }

        var dynamics = DynamicsConfiguration()
        dynamics.spectralDenoiser.enabled = true
        dynamics.spectralDenoiser.quality = .quality
        dynamics.spectralDenoiser.thresholdDBFS = -72
        let processedGraph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: dynamics,
            playbackConfiguration: PlaybackControlConfiguration(auditionMode: .processed)
        )
        let referenceGraph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: dynamics,
            playbackConfiguration: PlaybackControlConfiguration(auditionMode: .reference)
        )
        XCTAssertTrue(N60RenderKernelPublishSnapshot(processedKernel, processedGraph))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(referenceKernel, referenceGraph))

        let totalFrames = 22_000
        var squaredError = 0.0
        var squaredReference = 0.0
        var measured = 0
        for frame in 0..<totalFrames {
            let source = Float(0.25 * sin(2.0 * Double.pi * 997.0 * Double(frame) / 48_000.0))
            var processedLeft: Float = 0
            var processedRight: Float = 0
            var referenceLeft: Float = 0
            var referenceRight: Float = 0
            N60RenderKernelProcessStereoFrame(processedKernel, source, source * 0.7, &processedLeft, &processedRight)
            N60RenderKernelProcessStereoFrame(referenceKernel, source, source * 0.7, &referenceLeft, &referenceRight)
            if frame > Int(processedGraph.latencyFrames + processedGraph.dynamics.spectralDenoiser.hopSize + 256) {
                let error = Double(processedLeft - referenceLeft)
                squaredError += error * error
                squaredReference += Double(referenceLeft * referenceLeft)
                measured += 1
            }
        }
        XCTAssertGreaterThan(measured, 1000)
        let normalizedError = sqrt(squaredError / max(squaredReference, 1.0e-20))
        XCTAssertLessThan(normalizedError, 0.0025, "WOLA unity path should track latency-matched Reference before adaptive profile becomes active")
    }

    func testSpectralDenoiserGraphStaysFiniteAt384k() throws {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }
        var dynamics = DynamicsConfiguration()
        dynamics.spectralDenoiser.enabled = true
        dynamics.spectralDenoiser.applyPreset(.natural)
        dynamics.spectralDenoiser.quality = .ultra
        let graph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 384_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: dynamics,
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        var state: UInt32 = 0xCAFEBABE
        var maxMagnitude: Float = 0
        for _ in 0..<30_000 {
            state = state &* 1_664_525 &+ 1_013_904_223
            let sample = (Float(state & 0xFFFF) / 32_767.5 - 1) * 0.1
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, -sample * 0.8, &left, &right)
            XCTAssertTrue(left.isFinite)
            XCTAssertTrue(right.isFinite)
            maxMagnitude = max(maxMagnitude, max(abs(left), abs(right)))
        }
        XCTAssertLessThan(maxMagnitude, 1.0)
        XCTAssertEqual(N60RenderKernelGetDiagnostics(kernel).denoiserLatencyFrames, 4096)
    }
}


extension NotchSixtyTests {
    func testSpectralDenoiserAdaptiveLearningDoesNotTreatLoudToneAsNoise() throws {
        guard let runtime = N60SpectralDenoiserCreate() else {
            XCTFail("Unable to allocate spectral denoiser")
            return
        }
        defer { N60SpectralDenoiserDestroy(runtime) }
        var snapshot = N60SpectralDenoiserSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60SpectralDenoiserSnapshotConfigure(
            &snapshot, 48_000, true, N60DenoiserTuningAggressive, N60DenoiserQualityQuality,
            1.0, -72, false, 0, 150, 0, N60DenoiserProfileCommandNone
        ))

        let frequency = 3_000.0
        var inputDot = 0.0
        var outputDot = 0.0
        var referencePower = 0.0
        let totalFrames = 48_000 * 4
        for frame in 0..<totalFrames {
            let phase = 2.0 * Double.pi * frequency * Double(frame) / 48_000.0
            let source = Float(0.20 * sin(phase))
            var left: Float = 0
            var right: Float = 0
            N60SpectralDenoiserProcessStereoFrame(runtime, snapshot, 48_000, source, source, &left, &right)
            if frame > 48_000 * 3 {
                let delayedPhase = 2.0 * Double.pi * frequency * Double(frame - Int(snapshot.latencyFrames)) / 48_000.0
                let reference = sin(delayedPhase)
                inputDot += 0.20 * reference * reference
                outputDot += Double(left) * reference
                referencePower += reference * reference
            }
        }
        let inputAmplitude = inputDot / max(referencePower, 1.0e-20)
        let outputAmplitude = outputDot / max(referencePower, 1.0e-20)
        XCTAssertGreaterThan(outputAmplitude, inputAmplitude * 0.96,
                             "Adaptive learning must not classify a clearly above-threshold program tone as stationary noise")
    }

    func testSpectralDenoiserProtectedRangeRemainsNearUnityWhileHighNoiseIsReduced() throws {
        guard let runtime = N60SpectralDenoiserCreate() else {
            XCTFail("Unable to allocate spectral denoiser")
            return
        }
        defer { N60SpectralDenoiserDestroy(runtime) }
        var snapshot = N60SpectralDenoiserSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60SpectralDenoiserSnapshotConfigure(
            &snapshot, 48_000, true, N60DenoiserTuningAggressive, N60DenoiserQualityQuality,
            1.0, -42, true, 0, 200, 1, N60DenoiserProfileCommandCapture
        ))

        let lowHz = 93.75   // exact FFT bin for N=1024 at 48 kHz
        let highHz = 6_000.0
        let totalFrames = 48_000 * 4
        var lowDot = 0.0
        var highDot = 0.0
        var basisPower = 0.0
        for frame in 0..<totalFrames {
            let low = 0.025 * sin(2.0 * Double.pi * lowHz * Double(frame) / 48_000.0)
            let high = 0.025 * sin(2.0 * Double.pi * highHz * Double(frame) / 48_000.0)
            let source = Float(low + high)
            var left: Float = 0
            var right: Float = 0
            N60SpectralDenoiserProcessStereoFrame(runtime, snapshot, 48_000, source, source, &left, &right)
            if frame > 48_000 * 3 {
                let delayedFrame = Double(frame - Int(snapshot.latencyFrames))
                let lowBasis = sin(2.0 * Double.pi * lowHz * delayedFrame / 48_000.0)
                let highBasis = sin(2.0 * Double.pi * highHz * delayedFrame / 48_000.0)
                lowDot += Double(left) * lowBasis
                highDot += Double(left) * highBasis
                basisPower += lowBasis * lowBasis
            }
        }
        let lowAmplitude = lowDot / max(basisPower, 1.0e-20)
        let highAmplitude = highDot / max(basisPower, 1.0e-20)
        XCTAssertGreaterThan(lowAmplitude, 0.022,
                             "The protected low-frequency band should remain close to unity")
        XCTAssertLessThan(highAmplitude, lowAmplitude * 0.75,
                          "An unprotected captured stationary component should be reduced relative to the protected band")
    }
}
