import XCTest
@testable import NotchSixty

/// E26 S2: per-band delay, per-band eligibility and the open-preout check on the acoustic twin's combined path, at the
/// eight standard rates. Bench (E22): sweeps through the owner's receiver.
final class CombinedPathBandTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    /// Swift twin of `twin::BassSplit` (ci/e4_twin_bass_path.hpp): feed L -> mains + sub, summed to the listener.
    private func combinedPath(
        rate fs: Double, crossoverHz: Double = 80, subDelay: Double, mainsHighPass: Bool = true, seconds: Double = 0.4
    ) -> [Float] {
        struct Bq {
            var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
            init(low: Bool, hz: Double, fs: Double) {
                let w = 2 * Double.pi * hz / fs, cs = cos(w), al = sin(w) / (2 * 0.7071067811865476), a0 = 1 + al
                a1 = -2 * cs / a0; a2 = (1 - al) / a0
                b0 = (low ? 1 - cs : 1 + cs) / (2 * a0); b1 = (low ? 1 - cs : -(1 + cs)) / a0; b2 = b0
            }
            mutating func run(_ x: Double) -> Double {
                let y = b0 * x + z1
                z1 = b1 * x - a1 * y + z2
                z2 = b2 * x - a2 * y
                return y
            }
        }
        var lp = [Bq(low: true, hz: crossoverHz, fs: fs), Bq(low: true, hz: crossoverHz, fs: fs)]
        var hp = [Bq(low: false, hz: crossoverHz, fs: fs), Bq(low: false, hz: crossoverHz, fs: fs)]
        let n = Int(seconds * fs)
        var sub = [Double](repeating: 0, count: n)
        var out = [Float](repeating: 0, count: n)
        let d = subDelay * fs
        for i in 0..<n {
            let l = i == 0 ? 1.0 : 0.0
            sub[i] = lp[1].run(lp[0].run(0.5 * l))
            let whole = Int(d), frac = d - Double(whole)
            let a = i - whole >= 0 ? sub[i - whole] : 0, b = i - whole - 1 >= 0 ? sub[i - whole - 1] : 0
            let delayed = a + (b - a) * frac
            let mains = mainsHighPass ? hp[1].run(hp[0].run(l)) : l
            out[i] = Float(mains + delayed)
        }
        return out
    }

    /// Independent truth: the twin's analytic response H(f) = mains + 0.5 * LP4 * e^{-jw*delay}, group delay by finite
    /// difference of its phase, power-weighted over the band's nine frequencies exactly as the analyzer weights them.
    private func truthDelay(band: CombinedPathBand, rate fs: Double, subDelay: Double, crossoverHz: Double = 80) -> Double {
        func biquad(_ low: Bool, _ f: Double) -> (re: Double, im: Double) {
            let w0 = 2 * Double.pi * crossoverHz / fs, cs = cos(w0), al = sin(w0) / (2 * 0.7071067811865476), a0 = 1 + al
            let a1 = -2 * cs / a0, a2 = (1 - al) / a0
            let b0 = (low ? 1 - cs : 1 + cs) / (2 * a0), b1 = (low ? 1 - cs : -(1 + cs)) / a0
            let w = 2 * Double.pi * f / fs
            let z1 = (cos(-w), sin(-w)), z2 = (cos(-2 * w), sin(-2 * w))
            let nr = b0 + b1 * z1.0 + b0 * z2.0, ni = b1 * z1.1 + b0 * z2.1
            let dr = 1 + a1 * z1.0 + a2 * z2.0, di = a1 * z1.1 + a2 * z2.1
            let m = dr * dr + di * di
            return ((nr * dr + ni * di) / m, (ni * dr - nr * di) / m)
        }
        func mul(_ x: (re: Double, im: Double), _ y: (re: Double, im: Double)) -> (re: Double, im: Double) {
            (x.re * y.re - x.im * y.im, x.re * y.im + x.im * y.re)
        }
        func response(_ f: Double) -> (re: Double, im: Double) {
            let hp = mul(biquad(false, f), biquad(false, f))
            var lp = mul(biquad(true, f), biquad(true, f))
            lp = mul(lp, (0.5, 0))
            let w = 2 * Double.pi * f * subDelay
            lp = mul(lp, (cos(w), -sin(w)))
            return (hp.re + lp.re, hp.im + lp.im)
        }
        var wsum = 0.0, dsum = 0.0
        for k in 0..<CombinedPathBandAnalyzer.frequenciesPerBand {
            let f = band.lowHz + (band.highHz - band.lowHz) * Double(k) / Double(CombinedPathBandAnalyzer.frequenciesPerBand - 1)
            let h = response(f), h2 = response(f * 1.0001)
            let rel = mul(h2, (h.re, -h.im))
            let tau = -atan2(rel.im, rel.re) / (2 * Double.pi * f * 0.0001)
            let p = h.re * h.re + h.im * h.im
            wsum += p; dsum += p * tau
        }
        return dsum / wsum
    }

    func testBandDelayMatchesTwinTruthAtEightRates() {
        for rate in rates {
            for subDelay in [0.0, 0.005, 0.020] {
                let bands = CombinedPathBandAnalyzer.analyze(
                    impulseResponse: combinedPath(rate: rate, subDelay: subDelay), sampleRate: rate)
                XCTAssertEqual(bands.count, CombinedPathBandAnalyzer.centersHz.count)
                var checked = 0
                for band in bands where band.centerHz <= 125 {
                    guard let d = band.delaySeconds else { XCTFail("band \(band.centerHz) unmeasured"); continue }
                    let truth = truthDelay(band: band, rate: rate, subDelay: subDelay)
                    XCTAssertEqual(d, truth, accuracy: 1.0 / min(rate, 48_000) + 1e-9, "\(rate) Hz, sub \(subDelay), band \(band.centerHz)")
                    checked += 1
                }
                XCTAssertGreaterThanOrEqual(checked, 8)
            }
        }
    }

    func testSubDelayRaisesLowBandDelayByThatDelay() {
        let rate = 48_000.0
        let base = CombinedPathBandAnalyzer.analyze(impulseResponse: combinedPath(rate: rate, subDelay: 0), sampleRate: rate)
        let late = CombinedPathBandAnalyzer.analyze(impulseResponse: combinedPath(rate: rate, subDelay: 0.020), sampleRate: rate)
        let b = base[0].delaySeconds ?? 0, l = late[0].delaySeconds ?? 0
        XCTAssertEqual(l - b, 0.020, accuracy: 0.002, "the sub carries the lowest band")
    }

    func testFullRangeFeedHasZeroDelayInEveryBand() {
        for rate in rates {
            var h = [Float](repeating: 0, count: Int(0.3 * rate)); h[0] = 1
            for band in CombinedPathBandAnalyzer.analyze(impulseResponse: h, sampleRate: rate) {
                XCTAssertEqual(band.delaySeconds ?? 1, 0, accuracy: 1.0 / rate)
            }
        }
    }

    func testShortLeadBandsAreExcludedWithReason() throws {
        let rate = 48_000.0
        let a = SystemSetupArrangementPlanner.arrangement(
            deviceUID: "d", detectedChannelCount: 2, channelsInUse: 2,
            choices: .init(layout: .stereo, bass: .downstreamSubCrossover, subwooferCount: 1))
        let bands = CombinedPathBandAnalyzer.analyze(impulseResponse: combinedPath(rate: rate, subDelay: 0.020), sampleRate: rate)
        let required = QuietZoneFeedForwardBudgetAnalyzer.requiredReserveSeconds
        // Lead covers a 5 ms delay but not the 20 ms sub path.
        let result = PerBandAncEligibility.evaluate(
            arrangement: a, bands: bands, conservativePreviewSeconds: 0.005 + required + 0.005)
        let low = try XCTUnwrap(result.bands.first { $0.centerHz < 30 })
        XCTAssertFalse(low.isEligible)
        XCTAssertTrue(result.tonalOnly.contains { $0.reason.contains("short by") })
        XCTAssertTrue(result.bands.contains { $0.isEligible }, "bands above the crossover keep feed-forward")
        // A generous lead makes every measured band eligible.
        let all = PerBandAncEligibility.evaluate(arrangement: a, bands: bands, conservativePreviewSeconds: 0.2)
        XCTAssertEqual(all.feedForwardBandsHz.count, bands.filter { $0.delaySeconds != nil }.count)
    }

    func testUnexcitedBandsAreUnmeasured() {
        let rate = 48_000.0
        var h = [Float](repeating: 0, count: Int(0.3 * rate))
        for i in 0..<h.count { h[i] = Float(sin(2 * Double.pi * 200 * Double(i) / rate) * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(h.count)))) }
        let bands = CombinedPathBandAnalyzer.analyze(impulseResponse: h, sampleRate: rate)
        XCTAssertNil(bands.first { $0.centerHz < 22 }?.delaySeconds)
        XCTAssertNotNil(bands.first { abs($0.centerHz - 200) < 25 }?.delaySeconds)
    }

    func testOpenPreoutCheck() {
        for rate in rates {
            let expected = CombinedPathBandAnalyzer.analyze(
                impulseResponse: combinedPath(rate: rate, subDelay: 0, mainsHighPass: false), sampleRate: rate)
            XCTAssertNil(OpenPreoutCheck.refusal(measured: expected, expected: expected, sampleRate: rate))
            // The receiver adds its own 20 ms of timing.
            let delayed = CombinedPathBandAnalyzer.analyze(
                impulseResponse: combinedPath(rate: rate, subDelay: 0.020, mainsHighPass: false), sampleRate: rate)
            XCTAssertEqual(OpenPreoutCheck.refusal(measured: delayed, expected: expected, sampleRate: rate), OpenPreoutCheck.refusal)
            // The receiver adds its own 120 Hz crossover on top of the app's 80 Hz.
            let extra = CombinedPathBandAnalyzer.analyze(
                impulseResponse: combinedPath(rate: rate, crossoverHz: 40, subDelay: 0, mainsHighPass: false), sampleRate: rate)
            XCTAssertNotNil(OpenPreoutCheck.refusal(measured: extra, expected: expected, sampleRate: rate))
        }
        XCTAssertNotNil(OpenPreoutCheck.refusal(measured: [], expected: [], sampleRate: 48_000), "nothing measured confirms nothing")
    }
}
