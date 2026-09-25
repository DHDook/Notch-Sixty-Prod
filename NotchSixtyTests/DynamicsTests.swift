import XCTest
@testable import NotchSixty

final class DynamicsTests: XCTestCase {
    func testBypassedDynamicsIsExactUnity() {
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        let snapshot = N60DynamicsSnapshotMakeBypassed(96_000)

        for frame in 0..<20_000 {
            let leftIn = Float(sin(Double(frame) * 0.017) * 0.72)
            let rightIn = Float(cos(Double(frame) * 0.011) * 0.41)
            var left = leftIn
            var right = rightIn
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
            XCTAssertEqual(left, leftIn, accuracy: 0.000_001)
            XCTAssertEqual(right, rightIn, accuracy: 0.000_001)
        }
    }

    func testCompressorAppliesLinkedStereoGainAndExpectedSteadyStateRatio() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetCompressor(&snapshot, sampleRate, true, -20, 4, 0, 2, 50, 0))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)

        var left: Float = 0
        var right: Float = 0
        for _ in 0..<48_000 {
            left = 0.5
            right = 0.25
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
        }

        let inputDB = 20.0 * log10(0.5)
        let expectedOutputDB = -20.0 + (inputDB + 20.0) / 4.0
        let expectedGain = pow(10.0, (expectedOutputDB - inputDB) / 20.0)
        XCTAssertEqual(Double(left), 0.5 * expectedGain, accuracy: 0.002)
        XCTAssertEqual(Double(right), 0.25 * expectedGain, accuracy: 0.002)
        XCTAssertEqual(Double(left / right), 2.0, accuracy: 0.000_1)
        XCTAssertGreaterThan(N60DynamicsRuntimeTelemetry(&runtime).compressorGainReductionDB, 1)
    }

    func testExpanderIsUnityAboveThresholdAndBoundedBelowThreshold() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetExpander(&snapshot, sampleRate, true, -35, 2, -12, 1, 20))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)

        for _ in 0..<10_000 {
            var left: Float = 0.5
            var right: Float = -0.25
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
            XCTAssertEqual(left, 0.5, accuracy: 0.000_001)
            XCTAssertEqual(right, -0.25, accuracy: 0.000_001)
        }

        var lowLeft: Float = 0
        var lowRight: Float = 0
        for _ in 0..<48_000 {
            lowLeft = 0.001
            lowRight = -0.0005
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &lowLeft, &lowRight)
        }
        let minimumGain = pow(10.0, -12.0 / 20.0)
        XCTAssertEqual(Double(lowLeft), 0.001 * minimumGain, accuracy: 0.000_02)
        XCTAssertEqual(Double(lowLeft / lowRight), -2.0, accuracy: 0.000_1)
        XCTAssertLessThanOrEqual(N60DynamicsRuntimeTelemetry(&runtime).expanderAttenuationDB, 12.01)
    }

    func testPauseGateAttackFadesOutAndReleaseFadesIn() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetPauseGate(&snapshot, sampleRate, true, -60, 0, 5, 50, 3))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)

        // Start with signal safely above the reopen threshold.
        for _ in 0..<5_000 {
            var left: Float = 0.1
            var right: Float = 0.1
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
        }
        XCTAssertTrue(N60DynamicsRuntimeTelemetry(&runtime).pauseGateOpen)

        // Silence closes the gate and Attack controls the fade-out trajectory.
        for _ in 0..<8_000 {
            var left: Float = 0
            var right: Float = 0
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
        }
        let closed = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertFalse(closed.pauseGateOpen)
        XCTAssertLessThan(closed.pauseGateGain, 0.001)

        // Resume signal reopens immediately, but Release deliberately fades in more slowly.
        var firstResumeLeft: Float = 0.1
        var firstResumeRight: Float = 0.1
        N60DynamicsProcessStereoFrame(&runtime, snapshot, &firstResumeLeft, &firstResumeRight)
        XCTAssertTrue(N60DynamicsRuntimeTelemetry(&runtime).pauseGateOpen)
        XCTAssertLessThan(firstResumeLeft, 0.02)

        for _ in 0..<24_000 {
            var left: Float = 0.1
            var right: Float = 0.1
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
        }
        XCTAssertGreaterThan(N60DynamicsRuntimeTelemetry(&runtime).pauseGateGain, 0.98)
    }

    func testDynamicsConfigurationRejectsNonFiniteAndOutOfRangeParameters() {
        var config = DynamicsConfiguration()
        config.compressor.enabled = true
        config.compressor.ratio = .infinity
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))

        config = DynamicsConfiguration()
        config.expander.rangeDB = 1
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))

        config = DynamicsConfiguration()
        config.pauseGate.hysteresisDB = 7
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))
    }

    func testKernelGlobalBypassOverridesDynamics() throws {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        var dynamics = N60DynamicsSnapshotMakeBypassed(96_000)
        XCTAssertTrue(N60DynamicsSnapshotSetCompressor(&dynamics, 96_000, true, -40, 20, 0, 0.1, 20, 0))
        graph.dynamics = dynamics
        graph.bypassed = true
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        for _ in 0..<2_000 {
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, 0.5, -0.25, &left, &right)
            XCTAssertEqual(left, 0.5, accuracy: 0.000_001)
            XCTAssertEqual(right, -0.25, accuracy: 0.000_001)
        }
    }


    func testConfiguredDisabledMultibandIsUnityForLR4AndLR8() {
        for topology in [N60CrossoverTopologyLinkwitzRiley24, N60CrossoverTopologyLinkwitzRiley48] {
            var snapshot = N60DynamicsSnapshotMakeBypassed(96_000)
            XCTAssertTrue(N60DynamicsSnapshotSetMultibandCompressor(
                &snapshot, 96_000, false, 120, 3_500, topology, -18, -18, -18
            ))
            var runtime = N60DynamicsRuntime()
            N60DynamicsRuntimeReset(&runtime)

            for frame in 0..<40_000 {
                let leftIn = Float(0.57 * sin(Double(frame) * 0.071) + 0.11 * cos(Double(frame) * 0.017))
                let rightIn = Float(0.31 * cos(Double(frame) * 0.043) - 0.09 * sin(Double(frame) * 0.013))
                var left = leftIn
                var right = rightIn
                N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
                XCTAssertEqual(left, leftIn, accuracy: 0.000_002)
                XCTAssertEqual(right, rightIn, accuracy: 0.000_002)
            }
        }
    }

    func testDeEsserDynamicEQReducesSibilanceBand() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetDeEsser(&snapshot, sampleRate, true, 6_500, -36, true))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)

        var inputSquare = 0.0
        var outputSquare = 0.0
        let startMeasure = 24_000
        for frame in 0..<48_000 {
            let input = Float(0.5 * sin(2.0 * Double.pi * 6_500.0 * Double(frame) / sampleRate))
            var left = input
            var right = input * 0.5
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
            if frame >= startMeasure {
                inputSquare += Double(input * input)
                outputSquare += Double(left * left)
            }
        }

        let inputRMS = sqrt(inputSquare / 24_000.0)
        let outputRMS = sqrt(outputSquare / 24_000.0)
        XCTAssertLessThan(outputRMS, inputRMS * 0.9)
        XCTAssertGreaterThan(N60DynamicsRuntimeTelemetry(&runtime).deEsserGainReductionDB, 2.0)
    }

    func testMultibandHighBandCompressionTriggersIndependentlyAndStaysLinked() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetMultibandCompressor(
            &snapshot,
            sampleRate,
            true,
            120,
            3_500,
            N60CrossoverTopologyLinkwitzRiley24,
            0,
            0,
            -30
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)

        var left: Float = 0
        var right: Float = 0
        for frame in 0..<48_000 {
            let input = Float(0.5 * sin(2.0 * Double.pi * 6_000.0 * Double(frame) / sampleRate))
            left = input
            right = input * 0.5
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
        }

        let telemetry = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertGreaterThan(telemetry.multibandHighGainReductionDB, 2.0)
        XCTAssertLessThan(telemetry.multibandLowGainReductionDB, 0.05)
        XCTAssertLessThan(telemetry.multibandMidGainReductionDB, 0.05)
        if abs(right) > 0.000_01 {
            XCTAssertEqual(left / right, 2.0, accuracy: 0.001)
        }
    }

    func testPR28ConfigurationRejectsOutOfRangeControls() {
        var config = DynamicsConfiguration()
        config.deEsser.frequencyHz = 1_999
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))

        config = DynamicsConfiguration()
        config.multibandCompressor.lowMidFrequencyHz = 300
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))

        config = DynamicsConfiguration()
        config.multibandCompressor.highThresholdDB = 1
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))
    }

    func testKernelGlobalBypassOverridesPR28Dynamics() throws {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        var dynamics = N60DynamicsSnapshotMakeBypassed(96_000)
        XCTAssertTrue(N60DynamicsSnapshotSetDeEsser(&dynamics, 96_000, true, 6_500, -50, true))
        XCTAssertTrue(N60DynamicsSnapshotSetMultibandCompressor(
            &dynamics, 96_000, true, 120, 3_500,
            N60CrossoverTopologyLinkwitzRiley48, -40, -40, -40
        ))
        graph.dynamics = dynamics
        graph.bypassed = true
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        for _ in 0..<4_000 {
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, 0.5, -0.25, &left, &right)
            XCTAssertEqual(left, 0.5, accuracy: 0.000_001)
            XCTAssertEqual(right, -0.25, accuracy: 0.000_001)
        }
    }


    func testDCOffsetFilterRemovesConstantBias() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetDCOffsetFilter(&snapshot, sampleRate, true))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        var last: Float = 0
        for _ in 0..<240_000 {
            var left: Float = 0.25
            var right: Float = 0.25
            N60DynamicsProcessPreEQStereoFrame(&runtime, snapshot, &left, &right)
            last = left
        }
        XCTAssertLessThan(abs(last), 0.01)
    }

    func testInfrasonicFilterAttenuatesFiveHzAndPassesOneKHz() {
        let sampleRate = 48_000.0
        func rms(at frequency: Double) -> Double {
            var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
            XCTAssertTrue(N60DynamicsSnapshotSetInfrasonicFilter(&snapshot, sampleRate, true, 18, N60InfrasonicSlope48DBPerOctave))
            var runtime = N60DynamicsRuntime()
            N60DynamicsRuntimeReset(&runtime)
            var sum = 0.0
            let start = 96_000
            for frame in 0..<192_000 {
                var left = Float(0.5 * sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate))
                var right = left
                N60DynamicsProcessPreEQStereoFrame(&runtime, snapshot, &left, &right)
                if frame >= start { sum += Double(left * left) }
            }
            return sqrt(sum / Double(192_000 - start))
        }
        XCTAssertLessThan(rms(at: 5), 0.03)
        XCTAssertGreaterThan(rms(at: 1_000), 0.30)
    }

    func testLoudnessContourBoostsBassMoreThanMidbandAtLowListeningLevel() {
        let sampleRate = 48_000.0
        let lowMasterGain = Float(pow(10.0, -36.0 / 20.0))

        func rms(at frequency: Double) -> Double {
            var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
            XCTAssertTrue(N60DynamicsSnapshotSetLoudnessContour(&snapshot, sampleRate, true, 1.0))
            var runtime = N60DynamicsRuntime()
            N60DynamicsRuntimeReset(&runtime)
            var sum = 0.0
            let startMeasure = 48_000
            for frame in 0..<96_000 {
                var left = Float(0.2 * sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate))
                var right = left
                N60DynamicsProcessCoreStereoFrameWithMasterGain(
                    &runtime,
                    snapshot,
                    lowMasterGain,
                    &left,
                    &right
                )
                if frame >= startMeasure { sum += Double(left * left) }
            }
            return sqrt(sum / Double(96_000 - startMeasure))
        }

        let bass = rms(at: 60)
        let mid = rms(at: 1_000)
        XCTAssertGreaterThan(bass, mid * 1.25)
    }

    func testLoudnessContourBacksOffAtHighListeningLevel() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetLoudnessContour(&snapshot, sampleRate, true, 1.0))

        func settledScale(masterGain: Float) -> Float {
            var runtime = N60DynamicsRuntime()
            N60DynamicsRuntimeReset(&runtime)
            for frame in 0..<48_000 {
                var left = Float(0.2 * sin(2.0 * Double.pi * 60.0 * Double(frame) / sampleRate))
                var right = left
                N60DynamicsProcessCoreStereoFrameWithMasterGain(
                    &runtime,
                    snapshot,
                    masterGain,
                    &left,
                    &right
                )
            }
            return N60DynamicsRuntimeTelemetry(&runtime).loudnessContourScale
        }

        let lowMaster = Float(pow(10.0, -36.0 / 20.0))
        let mediumMaster = Float(pow(10.0, -18.0 / 20.0))
        let highMaster: Float = 1.0
        let lowScale = settledScale(masterGain: lowMaster)
        let mediumScale = settledScale(masterGain: mediumMaster)
        let highScale = settledScale(masterGain: highMaster)

        XCTAssertGreaterThan(lowScale, 0.95)
        XCTAssertGreaterThan(lowScale, mediumScale)
        XCTAssertGreaterThan(mediumScale, highScale)
        XCTAssertLessThan(highScale, 0.01)
    }

    func testLoudnessMatchAppliesBoundedLinkedStereoCorrection() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetLoudnessMatch(
            &snapshot,
            sampleRate,
            true,
            false,
            -16,
            6,
            0.3,
            1.0
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)

        var lastLeft: Float = 0
        var lastRight: Float = 0
        for frame in 0..<192_000 {
            let input = Float(0.03 * sin(2.0 * Double.pi * 1_000.0 * Double(frame) / sampleRate))
            lastLeft = input
            lastRight = input * 0.5
            N60DynamicsProcessCoreStereoFrameWithMasterGain(
                &runtime,
                snapshot,
                1.0,
                &lastLeft,
                &lastRight
            )
        }

        let telemetry = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertGreaterThan(telemetry.loudnessMatchGainDB, 1.0)
        XCTAssertLessThanOrEqual(telemetry.loudnessMatchGainDB, 6.01)
        if abs(lastRight) > 0.000_001 {
            XCTAssertEqual(lastLeft / lastRight, 2.0, accuracy: 0.001)
        }
    }

    func testLoudnessDialogueGateDoesNotRaiseSilence() {
        let sampleRate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate)
        XCTAssertTrue(N60DynamicsSnapshotSetLoudnessMatch(
            &snapshot,
            sampleRate,
            true,
            true,
            -16,
            12,
            0.3,
            1.0
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)

        for _ in 0..<192_000 {
            var left: Float = 0
            var right: Float = 0
            N60DynamicsProcessCoreStereoFrameWithMasterGain(
                &runtime,
                snapshot,
                1.0,
                &left,
                &right
            )
        }

        let telemetry = N60DynamicsRuntimeTelemetry(&runtime)
        XCTAssertLessThan(abs(telemetry.loudnessMatchGainDB), 0.01)
        XCTAssertLessThan(telemetry.loudnessShortTermLUFS, -60.0)
    }

}
