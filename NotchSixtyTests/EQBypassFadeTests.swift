import XCTest
@testable import NotchSixty

/// E27 S3b design 13 (closes G2): the default unified graph meets the click-free bypass
/// criterion on its own, so no engine change is made. A -6 dBFS 1 kHz sine through +12 dB of EQ,
/// bypass toggled while the stream runs: no sample step above the largest steady step plus 1e-4,
/// settled within 25 ms, and the 1 ms level never above max(before, after) + 0.5 dB.
final class EQBypassFadeTests: XCTestCase {
    private func check(_ result: EQRenderHarness.Result, label: String) {
        let rate = result.rate
        let out = result.output
        let s = result.switchIndex
        let settled = Int(rate * 0.1)
        let before = out[(s - settled)..<s]
        let after = out[(out.count - settled)...]
        let beforeStep = EQRenderHarness.maxStep(before)
        let afterStep = EQRenderHarness.maxStep(after)
        let allowed = max(beforeStep, afterStep) + 1e-4
        let window = out[(s - 1)..<min(out.count, s + Int(rate * 0.04))]
        XCTAssertLessThanOrEqual(EQRenderHarness.maxStep(window), allowed, "\(label) step at \(rate)")

        let beforeRMS = EQRenderHarness.rms(before)
        let afterRMS = EQRenderHarness.rms(after)
        let ceiling = max(beforeRMS, afterRMS) * pow(10, 0.5 / 20)
        let oneMs = max(8, Int(rate * 0.001))
        var index = s
        while index + oneMs < out.count {
            // One whole 1 kHz period is the shortest window whose RMS is level-true.
            let period = Int((rate / 1_000).rounded())
            if index + period < out.count {
                XCTAssertLessThanOrEqual(
                    EQRenderHarness.rms(out[index..<index + period]), ceiling, "\(label) swell at \(rate)")
            }
            index += oneMs
        }

        let doneAt = s + Int(rate * 0.025)
        let target = afterRMS
        let tail = EQRenderHarness.rms(out[doneAt..<doneAt + Int(rate / 1_000) * 5])
        XCTAssertEqual(20 * log10(tail / target), 0, accuracy: 0.1, "\(label) settled by 25 ms at \(rate)")
    }

    func testBypassOnAndOffAreClickFreeAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            var eq = EQRenderHarness.peakConfiguration(gainDB: 12)
            let active = try EQRenderHarness.spec(eq, rate: rate)
            eq.bypassed = true
            let bypassed = try EQRenderHarness.spec(eq, rate: rate)
            check(try EQRenderHarness.render(rate: rate, specs: [active, bypassed]), label: "bypass on")
            check(try EQRenderHarness.render(rate: rate, specs: [bypassed, active]), label: "bypass off")
        }
    }
}
