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
}
