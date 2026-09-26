import XCTest
@testable import NotchSixty

final class ProtectionTests: XCTestCase {
    func testTwoAndFourTimesOversamplingPreserveUnityAfterDeclaredDelay() {
        for (factor, expectedLatency) in [(N60OversamplingFactor2x, UInt32(32)), (N60OversamplingFactor4x, UInt32(48))] {
            var snapshot = N60ProtectionSnapshotMakeBypassed(96_000)
            XCTAssertTrue(N60ProtectionSnapshotSetOversamplingFactor(&snapshot, factor))
            XCTAssertEqual(snapshot.latencyFrames, expectedLatency)
            guard let runtime = N60ProtectionRuntimeCreate() else {
                return XCTFail("Unable to create protection runtime")
            }
            defer { N60ProtectionRuntimeDestroy(runtime) }

            var history = [Float](repeating: 0, count: 256)
            var inputEnergy = 0.0
            var outputEnergy = 0.0
            var errorEnergy = 0.0
            for frame in 0..<24_000 {
                let input = Float(0.45 * sin(2.0 * .pi * 1_000.0 * Double(frame) / 96_000.0))
                history[frame % history.count] = input
                var left = input
                var right = -input * 0.7
                N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
                if frame > Int(expectedLatency) + 400 {
                    let expected = history[(frame - Int(expectedLatency)) % history.count]
                    inputEnergy += Double(expected * expected)
                    outputEnergy += Double(left * left)
                    let error = left - expected
                    errorEnergy += Double(error * error)
                }
            }
            let gainDB = 10.0 * log10(outputEnergy / inputEnergy)
            let residualDB = 10.0 * log10(errorEnergy / inputEnergy)
            XCTAssertLessThan(abs(gainDB), 0.01, "\(factor)x gain changed by \(gainDB) dB")
            XCTAssertLessThan(residualDB, -45.0, "\(factor)x residual was \(residualDB) dB")
        }
    }

    func testFourTimesTruePeakDetectorFindsInterSamplePeak() {
        var snapshot = N60ProtectionSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60ProtectionSnapshotSetOversamplingFactor(&snapshot, N60OversamplingFactor4x))
        guard let runtime = N60ProtectionRuntimeCreate() else {
            return XCTFail("Unable to create protection runtime")
        }
        defer { N60ProtectionRuntimeDestroy(runtime) }
        N60ProtectionRuntimeBeginBuffer(runtime)

        for _ in 0..<100 {
            var left: Float = 0
            var right: Float = 0
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
        }
        for sample: Float in [1, -1, -1, 1] {
            var left = sample
            var right = sample
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
        }
        for _ in 0..<100 {
            var left: Float = 0
            var right: Float = 0
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
        }

        XCTAssertGreaterThan(N60ProtectionRuntimeTelemetry(runtime).inputTruePeakLinear, 1.2)
    }

    func testLimiterForcesFourTimesTruePeakPathAndRespectsCeiling() {
        var snapshot = N60ProtectionSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60ProtectionSnapshotSetLimiter(&snapshot, true, -1, 0.1, 50, 2))
        XCTAssertEqual(snapshot.effectiveFactor, N60OversamplingFactor4x)
        XCTAssertEqual(snapshot.latencyFrames, 144)
        guard let runtime = N60ProtectionRuntimeCreate() else {
            return XCTFail("Unable to create protection runtime")
        }
        defer { N60ProtectionRuntimeDestroy(runtime) }
        N60ProtectionRuntimeBeginBuffer(runtime)

        let ceiling = Float(pow(10.0, -1.0 / 20.0))
        var basePeak: Float = 0
        for frame in 0..<12_000 {
            let input = Float(1.35 * sin(2.0 * .pi * 997.0 * Double(frame) / 48_000.0))
            var left = input
            var right = -input
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
            basePeak = max(basePeak, abs(left), abs(right))
        }
        let telemetry = N60ProtectionRuntimeTelemetry(runtime)
        XCTAssertLessThanOrEqual(telemetry.outputTruePeakLinear, ceiling + 0.000_01)
        XCTAssertLessThanOrEqual(basePeak, ceiling + 0.000_5)
        XCTAssertGreaterThan(telemetry.limiterGainReductionDB, 0.1)
        XCTAssertEqual(telemetry.limiterSafetyClampSamples, 0)
    }

    func testClipperCurvesRemainFiniteAndBounded() {
        for curve in [N60ClipperCurveQuadratic, N60ClipperCurveCubic, N60ClipperCurveSine, N60ClipperCurveAsymmetricTube] {
            var snapshot = N60ProtectionSnapshotMakeBypassed(96_000)
            XCTAssertTrue(N60ProtectionSnapshotSetSoftClipper(&snapshot, true, 6, -1.5, 0.7, curve, false))
            guard let runtime = N60ProtectionRuntimeCreate() else {
                return XCTFail("Unable to create protection runtime")
            }
            for frame in 0..<1_000 {
                var left: Float = frame.isMultiple(of: 2) ? 2 : -2
                var right = -left
                N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
                XCTAssertTrue(left.isFinite && right.isFinite)
                XCTAssertLessThanOrEqual(abs(left), 1.000_001)
                XCTAssertLessThanOrEqual(abs(right), 1.000_001)
            }
            N60ProtectionRuntimeDestroy(runtime)
        }
    }

    func testProtectionConfigurationRejectsInvalidRanges() {
        var config = DynamicsConfiguration()
        config.softClipper.driveDB = 13
        XCTAssertThrowsError(try config.makeProtectionSnapshot(sampleRate: 96_000))

        config = DynamicsConfiguration()
        config.limiter.lookAheadMs = 21
        XCTAssertThrowsError(try config.makeProtectionSnapshot(sampleRate: 96_000))
    }

    func testTruePeakGuardControlsForcedFourTimesPath() {
        var guarded = N60ProtectionSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60ProtectionSnapshotSetOversamplingFactor(&guarded, N60OversamplingFactor1x))
        XCTAssertTrue(N60ProtectionSnapshotSetLimiterAdvanced(&guarded, true, -1, 0.1, 50, 2, true))
        XCTAssertEqual(guarded.effectiveFactor, N60OversamplingFactor4x)

        var unguarded = N60ProtectionSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60ProtectionSnapshotSetOversamplingFactor(&unguarded, N60OversamplingFactor2x))
        XCTAssertTrue(N60ProtectionSnapshotSetLimiterAdvanced(&unguarded, true, -1, 0.1, 50, 2, false))
        XCTAssertEqual(unguarded.effectiveFactor, N60OversamplingFactor2x)
    }

    func testClipperAsymmetryTrimIsBoundedAndZeroTrimPreservesSymmetry() {
        for trim: Float in [0, 3, -3] {
            var snapshot = N60ProtectionSnapshotMakeBypassed(96_000)
            XCTAssertTrue(N60ProtectionSnapshotSetSoftClipperAdvanced(
                &snapshot, true, 6, -2, 1, N60ClipperCurveQuadratic, false, trim))
            guard let runtime = N60ProtectionRuntimeCreate() else { return XCTFail("runtime") }
            defer { N60ProtectionRuntimeDestroy(runtime) }
            var positive: Float = 0.3
            var positiveRight = positive
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &positive, &positiveRight)
            N60ProtectionRuntimeReset(runtime)
            var negative: Float = -0.3
            var negativeRight = negative
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &negative, &negativeRight)
            XCTAssertTrue(positive.isFinite && negative.isFinite)
            XCTAssertLessThanOrEqual(abs(positive), 1.000_001)
            XCTAssertLessThanOrEqual(abs(negative), 1.000_001)
            if trim == 0 {
                XCTAssertEqual(abs(positive), abs(negative), accuracy: 0.000_001)
            } else {
                XCTAssertGreaterThan(abs(abs(positive) - abs(negative)), 0.005)
            }
        }
    }

    func testGainRiderIgnoresTransientButRespondsToSustainedLimiting() {
        var snapshot = N60ProtectionSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60ProtectionSnapshotSetLimiterAdvanced(&snapshot, true, -1, 0.1, 20, 1, true))
        XCTAssertTrue(N60ProtectionSnapshotSetGainRider(&snapshot, true, 1.0, 6.0, N60GainRiderSpeedFast))
        guard let runtime = N60ProtectionRuntimeCreate() else { return XCTFail("runtime") }
        defer { N60ProtectionRuntimeDestroy(runtime) }

        for frame in 0..<48_000 {
            let amp: Float = frame < 240 ? 1.4 : 0.2
            var left = amp * Float(sin(2 * Double.pi * 997 * Double(frame) / 48_000))
            var right = -left
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
        }
        let afterTransient = N60ProtectionRuntimeTelemetry(runtime).gainRiderAttenuationDB
        XCTAssertLessThan(afterTransient, 0.15)

        for frame in 0..<(48_000 * 5) {
            var left = Float(1.5 * sin(2 * Double.pi * 997 * Double(frame) / 48_000))
            var right = -left
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
        }
        let telemetry = N60ProtectionRuntimeTelemetry(runtime)
        XCTAssertGreaterThan(telemetry.gainRiderAttenuationDB, 0.25)
        XCTAssertLessThanOrEqual(telemetry.gainRiderAttenuationDB, 6.001)
        XCTAssertGreaterThan(telemetry.sustainedLimiterGainReductionDB, 0)
    }

    func testGainRiderSpeedOrdering() {
        func attenuation(_ speed: N60GainRiderSpeed) -> Float {
            var snapshot = N60ProtectionSnapshotMakeBypassed(48_000)
            XCTAssertTrue(N60ProtectionSnapshotSetLimiterAdvanced(&snapshot, true, -1, 0.1, 20, 0.5, false))
            XCTAssertTrue(N60ProtectionSnapshotSetGainRider(&snapshot, true, 0.5, 6.0, speed))
            guard let runtime = N60ProtectionRuntimeCreate() else { return -1 }
            defer { N60ProtectionRuntimeDestroy(runtime) }
            for frame in 0..<(48_000 * 3) {
                var left = Float(1.5 * sin(2 * Double.pi * 997 * Double(frame) / 48_000))
                var right = -left
                N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
            }
            return N60ProtectionRuntimeTelemetry(runtime).gainRiderAttenuationDB
        }
        let fast = attenuation(N60GainRiderSpeedFast)
        let medium = attenuation(N60GainRiderSpeedMedium)
        let slow = attenuation(N60GainRiderSpeedSlow)
        XCTAssertGreaterThan(fast, medium)
        XCTAssertGreaterThan(medium, slow)
    }

    func testGainProtectionConfigurationValidAt384k() throws {
        var config = DynamicsConfiguration()
        config.softClipper.asymmetryTrimDB = 3
        config.limiter.enabled = true
        config.limiter.truePeakGuardEnabled = true
        config.gainRider.enabled = true
        config.gainRider.targetGainReductionDB = 3
        config.gainRider.maxReductionDB = 6
        config.gainRider.speed = .slow
        config.automaticHeadroom.enabled = true
        config.automaticHeadroom.maxAttenuationDB = 24
        var snapshot = try config.makeProtectionSnapshot(sampleRate: 384_000)
        XCTAssertTrue(N60ProtectionSnapshotIsValid(&snapshot))
        XCTAssertEqual(snapshot.effectiveFactor, N60OversamplingFactor4x)
    }

}
