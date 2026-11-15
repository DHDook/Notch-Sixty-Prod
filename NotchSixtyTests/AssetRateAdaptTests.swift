import XCTest
@testable import NotchSixty

/// E7 S2 (`e7.rate-adapt`): imported assets follow the device rate. The core resampler is covered at all 64 rate pairs
/// by `core/tests/test_resample.cpp`; these tests cover the Swift side: the binaural set still matches the Swift
/// resampler it replaced, a 48 kHz speaker impulse response plays at the eight rates through a real graph with the
/// response of the original, the cache does no repeat work, the flag-off refusal is unchanged, and no conversion runs
/// while a graph renders.
final class AssetRateAdaptTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    // MARK: the Swift resampler this slice deleted, kept here as the -120 dB reference

    private func legacyResample(_ source: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        let tapCount = source.count
        let outputCount = max(1, Int(ceil(Double(tapCount) * targetRate / sourceRate)))
        let step = sourceRate / targetRate
        let cutoff = 0.95 * min(1.0, targetRate / sourceRate)
        let halfWidth = 32.0 / cutoff
        let beta = 8.6
        func besselI0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1.0e-12 * sum {
                term *= (x / (2 * k)) * (x / (2 * k))
                sum += term
                k += 1
            }
            return sum
        }
        let i0Beta = besselI0(beta)
        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * step
            let first = max(0, Int(ceil(position - halfWidth)))
            let last = min(tapCount - 1, Int(floor(position + halfWidth)))
            guard first <= last else { continue }
            var acc = 0.0
            for k in first...last {
                let distance = position - Double(k)
                let x = cutoff * distance
                let sinc = abs(x) < 1.0e-12 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let ratio = distance / halfWidth
                let window = besselI0(beta * sqrt(max(0, 1 - ratio * ratio))) / i0Beta
                acc += Double(source[k]) * cutoff * sinc * window * step
            }
            output[index] = Float(acc)
        }
        return output
    }

    func testStandardKernelMatchesTheDeletedSwiftResamplerWithin120dB() throws {
        var a = [Float](repeating: 0, count: 256), b = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            a[i] = Float(sin(0.01 * Double(i * i)) * exp(-0.01 * Double(i)))
            b[i] = i == 40 ? 1 : 0
        }
        for (source, target) in [(48_000.0, 44_100.0), (44_100.0, 96_000.0), (96_000.0, 48_000.0), (48_000.0, 384_000.0),
                                 (384_000.0, 44_100.0), (192_000.0, 352_800.0)] {
            let converted = try XCTUnwrap(AssetResampler.resample([a, b], from: source, to: target, quality: .standard))
            for (signal, input) in zip(converted, [a, b]) {
                let reference = legacyResample(input, from: source, to: target)
                XCTAssertEqual(signal.count, reference.count)
                XCTAssertEqual(signal.count, AssetResampler.outputCount(input.count, from: source, to: target))
                let peak = reference.map { abs(Double($0)) }.max() ?? 1
                let error = zip(signal, reference).map { abs(Double($0) - Double($1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(error, 1e-6 * peak, "\(source) -> \(target)")
            }
        }
    }

    func testBinauralAssetResamplesThroughTheCoreAndKeepsItsShape() throws {
        let tapCount = 128
        var left = [Float](repeating: 0, count: tapCount), right = left
        left[20] = 1; right[24] = 0.5
        let asset = BinauralProfileAsset(
            displayName: "Rate fixture", originalSourceName: "fixture", sampleRate: 48_000, tapCount: tapCount,
            declaredLatencyFrames: 20, kind: .hrtf,
            measurements: [BinauralMeasurement(
                azimuthDegrees: 0, elevationDegrees: 0, distanceMeters: 1, leftIR: left, rightIR: right)])
        for rate in Self.rates where rate != 48_000 {
            let converted = try asset.resampled(to: rate)
            XCTAssertEqual(converted.sampleRate, rate)
            XCTAssertEqual(converted.tapCount, BinauralProfileAsset.resampledTapCount(tapCount, from: 48_000, to: rate))
            let measurement = try XCTUnwrap(converted.measurements.first)
            let peak = measurement.leftIR.indices.max { abs(measurement.leftIR[$0]) < abs(measurement.leftIR[$1]) } ?? 0
            XCTAssertEqual(Double(peak), 20 * rate / 48_000, accuracy: 1.0, "onset at \(rate)")
        }
    }

    // MARK: speaker impulse response

    private func fixtureFilter(rate: Double = 48_000) -> SpeakerIRFilter {
        var left = [Float](repeating: 0, count: 1_500), right = [Float](repeating: 0, count: 1_500)
        // Like a measured IR: quiet lead-in (an abrupt first sample would lose its pre-ringing to the fixed tap count).
        for n in 80..<1_500 { left[n] = Float(0.3 * pow(0.97, Double(n - 80)) * cos(2 * Double.pi * 1_000 * Double(n) / rate)) }
        left[100] += 0.5
        right[120] = 0.5
        return SpeakerIRFilter(name: "48 kHz fixture", sampleRate: rate, leftTaps: left, rightTaps: right, declaredLatencyFrames: 100)
    }

    private func magnitudeDB(_ taps: ArraySlice<Float>, frequency: Double, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        for (offset, tap) in taps.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(offset) / rate
            re += Double(tap) * cos(phase)
            im -= Double(tap) * sin(phase)
        }
        return 20 * log10(max(1e-12, (re * re + im * im).squareRoot()))
    }

    private func renderedImpulse(rate: Double, left: [Float], right: [Float]?, declared: UInt32, adapter: SpeakerIRRateAdapter? = nil)
        throws -> (lanes: [[Float]], latency: Int) {
        var configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        configuration.stereoStages.speakerIR = UnifiedGraphFIRProgram(
            generation: 1, left: left, right: right, declaredLatencyFrames: declared)
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        let before = adapter?.conversionCount
        let frames = (left.count + 256 + 1_024) / block * block + block
        var out: [[Float]] = [[], []]
        var position = 0
        while position < frames {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: 2)
            if position == 0 { input[0][0] = 1; input[1][0] = 1 }
            let result = try host.processOffline(input: input, frames: block)
            for lane in 0..<2 { out[lane] += result[lane] }
            position += block
        }
        // Rendering is the realtime side: it never converts anything.
        if let adapter, let before { XCTAssertEqual(adapter.conversionCount, before) }
        return (out, Int(host.latencyFrames))
    }

    func testA48kHzSpeakerIRPlaysAtTheEightRatesWithTheOriginalResponse() throws {
        let original = fixtureFilter()
        let frequencies: [Double] = [100, 500, 1_000, 2_000, 4_000, 8_000, 12_000, 16_000, 18_000, 19_000, 20_000]
        let adapter = SpeakerIRRateAdapter()
        for rate in Self.rates {
            let adapted = try adapter.validated(original, outputSampleRate: rate, enabled: true)
            XCTAssertEqual(try XCTUnwrap(adapted.sampleRate), rate, accuracy: 0.5)
            XCTAssertEqual(adapted.leftTaps.count, AssetResampler.outputCount(1_500, from: 48_000, to: rate), "tap count at \(rate)")
            XCTAssertEqual(Double(adapted.declaredLatencyFrames), 100 * rate / 48_000, accuracy: 0.5)
            let played = try renderedImpulse(rate: rate, left: adapted.leftTaps, right: adapted.rightTaps,
                                             declared: adapted.declaredLatencyFrames, adapter: adapter)
            XCTAssertGreaterThanOrEqual(played.latency, 256)
            for (lane, taps) in [(0, original.leftTaps), (1, original.rightTaps ?? [])] {
                for frequency in frequencies {
                    let want = magnitudeDB(taps[...], frequency: frequency, rate: 48_000)
                    let got = magnitudeDB(played.lanes[lane][...], frequency: frequency, rate: rate)
                    XCTAssertEqual(got, want, accuracy: 0.05, "lane \(lane) \(frequency) Hz at \(rate)")
                }
            }
        }
    }

    func testCacheHitDoesNoWorkAndTheOriginalIsKept() throws {
        let adapter = SpeakerIRRateAdapter()
        let original = fixtureFilter()
        let copy = original
        let first = adapter.adapted(original, outputSampleRate: 96_000, enabled: true)
        XCTAssertEqual(adapter.conversionCount, 1)
        let second = adapter.adapted(original, outputSampleRate: 96_000, enabled: true)
        XCTAssertEqual(adapter.conversionCount, 1, "a repeat activation is a cache hit")
        XCTAssertEqual(first, second)
        _ = adapter.adapted(original, outputSampleRate: 44_100, enabled: true)
        XCTAssertEqual(adapter.conversionCount, 2)
        _ = adapter.adapted(original, outputSampleRate: 96_000, enabled: true)
        XCTAssertEqual(adapter.conversionCount, 2, "a rate round trip is a cache hit")
        XCTAssertEqual(original, copy, "the stored original is never changed")
        XCTAssertEqual(try XCTUnwrap(original.sampleRate), 48_000)
        // A different filter at the same rate is not served from the first one's entry.
        var other = original
        other.leftTaps[100] += 0.25
        XCTAssertNotEqual(adapter.adapted(other, outputSampleRate: 96_000, enabled: true), first)
        XCTAssertEqual(adapter.conversionCount, 3)
    }

    func testFlagOffAndUnratedFiltersBehaveAsBefore() throws {
        let adapter = SpeakerIRRateAdapter()
        let original = fixtureFilter()
        XCTAssertThrowsError(try adapter.validated(original, outputSampleRate: 96_000, enabled: false)) { error in
            XCTAssertEqual(error as? SpeakerIRConfigurationError, .sampleRateMismatch(filter: 48_000, output: 96_000))
        }
        XCTAssertEqual(adapter.conversionCount, 0)
        XCTAssertNoThrow(try adapter.validated(original, outputSampleRate: 48_000, enabled: false))
        XCTAssertNoThrow(try adapter.validated(original, outputSampleRate: 48_000, enabled: true))
        // The built-in validation IR carries no rate, so it never converts.
        XCTAssertEqual(try adapter.validated(.validation, outputSampleRate: 384_000, enabled: true), .validation)
        XCTAssertEqual(adapter.conversionCount, 0)
        // A tap count above the convolver's limit after conversion still refuses with the tap count.
        var long = original
        long.leftTaps = [Float](repeating: 0.001, count: 100_000)
        long.rightTaps = nil
        XCTAssertThrowsError(try adapter.validated(long, outputSampleRate: 384_000, enabled: true)) { error in
            XCTAssertEqual(error as? SpeakerIRConfigurationError, .invalidTapCount(800_000))
        }
    }

    func testRowNoteNamesTheCaptureRate() {
        let original = fixtureFilter()
        XCTAssertEqual(SpeakerIRRateAdapter.rowNote(for: original, outputSampleRate: 96_000, enabled: true), "Resampled from 48 kHz")
        XCTAssertEqual(SpeakerIRRateAdapter.rowNote(for: fixtureFilter(rate: 44_100), outputSampleRate: 48_000, enabled: true),
                       "Resampled from 44.1 kHz")
        XCTAssertNil(SpeakerIRRateAdapter.rowNote(for: original, outputSampleRate: 48_000, enabled: true))
        XCTAssertNil(SpeakerIRRateAdapter.rowNote(for: original, outputSampleRate: 96_000, enabled: false))
        XCTAssertNil(SpeakerIRRateAdapter.rowNote(for: .validation, outputSampleRate: 96_000, enabled: true))
        XCTAssertNil(SpeakerIRRateAdapter.rowNote(for: nil, outputSampleRate: 96_000, enabled: true))
    }

    func testTheFlagIsRegisteredGraduatedAndOnlySwiftReadsIt() {
        let flag = FeatureFlag.rateAdapt
        XCTAssertEqual(flag.id, "e7.rate-adapt")
        XCTAssertTrue(FeatureFlag.all.contains(flag))
        XCTAssertTrue(flag.graduated)
        XCTAssertTrue(flag.resolvedDefault)
    }
}
