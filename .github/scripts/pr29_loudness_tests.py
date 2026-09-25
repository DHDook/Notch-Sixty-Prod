from pathlib import Path

path = Path('NotchSixtyTests/DynamicsTests.swift')
text = path.read_text()
start_marker = '    func testLoudnessContourBoostsBassMoreThanMidband() {'
start = text.find(start_marker)
if start < 0:
    raise SystemExit('missing stale PR28 loudness contour test')
end = text.find('\n    func ', start + len(start_marker))
if end < 0:
    end = text.rfind('\n}')
if end < 0:
    raise SystemExit('unable to locate end of stale contour test')

replacement = r'''    func testLoudnessContourBoostsBassMoreThanMidbandAtLowListeningLevel() {
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
'''

text = text[:start] + replacement + text[end:]
path.write_text(text)
print('PR29 loudness regression tests updated')
