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
        XCTAssertEqual(diagnostics.eqBandCount, N60_MAX_EQ_BANDS)
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
