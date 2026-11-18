import XCTest
@testable import NotchSixty

/// E33 S14: limiter Auto Release from the profile field to the rendered graph. Behavioural: real graphs and blocks at the eight
/// standard rates; the core's own recovery-time and ceiling tests are in `core/tests/test_limiter_auto_release.cpp`.
final class LimiterAutoReleaseTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func protection(auto: Bool, releaseMs: Double = 5) -> UnifiedGraphProtection {
        var p = UnifiedGraphProtection(
            limiterEnabled: true, ceilingDB: -12, attackMilliseconds: 0.5, releaseMilliseconds: releaseMs,
            lookAheadMilliseconds: 2, truePeakGuard: false, oversampling: 1)
        p.autoRelease = auto
        return p
    }

    func testWordCarriesAutoReleaseWithOrWithoutSoundFixes() {
        let off = UnifiedGraphConfiguration.protectionParameters(protection(auto: false), soundFixes: false)
        XCTAssertEqual(off.count, 7, "off publishes today's 7-value block")
        let on = UnifiedGraphConfiguration.protectionParameters(protection(auto: true), soundFixes: false)
        XCTAssertEqual(on.count, 8)
        XCTAssertEqual(Array(on.dropLast()), off)
        XCTAssertEqual(on.last, LimiterAutoRelease.wordBit)
        let both = UnifiedGraphConfiguration.protectionParameters(protection(auto: true), soundFixes: true)
        XCTAssertEqual(both.last, DynamicsSoundFixes.protectionWord + LimiterAutoRelease.wordBit)
        let fixesOnly = UnifiedGraphConfiguration.protectionParameters(protection(auto: false), soundFixes: true)
        XCTAssertEqual(fixesOnly.last, DynamicsSoundFixes.protectionWord)
    }

    func testOldProfilesDecodeAsFixedRelease() throws {
        let old = try JSONEncoder().encode(LimiterConfiguration())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object.removeValue(forKey: "autoRelease")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(LimiterConfiguration.self, from: stripped)
        XCTAssertNil(decoded.autoRelease)
        XCTAssertFalse(decoded.isAutoRelease)
        var on = LimiterConfiguration()
        on.autoRelease = true
        let round = try JSONDecoder().decode(LimiterConfiguration.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(round.isAutoRelease)
        XCTAssertEqual(round.releaseMs, on.releaseMs, "the fixed value is kept")
    }

    func testStoredSwitchIsIgnoredWithoutThePageFlag() throws {
        var d = DynamicsConfiguration()
        d.limiter.enabled = true
        d.limiter.autoRelease = true
        let snapshot = try d.makeProtectionSnapshot(sampleRate: 48_000)
        XCTAssertEqual(snapshot.limiterAutoRelease, LimiterAutoRelease.isAvailable)
        d.limiter.autoRelease = nil
        XCTAssertFalse(try d.makeProtectionSnapshot(sampleRate: 48_000).limiterAutoRelease)
    }

    func testTranslatorCarriesTheSwitchToTheGraphProtection() throws {
        for rate in Self.rates {
            var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
            snapshot.protection = try limiterSnapshot(rate: rate, auto: true)
            var configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
            XCTAssertEqual(configuration.protection?.autoRelease, true, "rate \(rate)")
            snapshot.protection = try limiterSnapshot(rate: rate, auto: false)
            configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
            XCTAssertEqual(configuration.protection?.autoRelease, false, "rate \(rate)")
        }
    }

    private func limiterSnapshot(rate: Double, auto: Bool) throws -> N60ProtectionSnapshot {
        var d = DynamicsConfiguration()
        d.limiter.enabled = true
        d.limiter.ceilingDB = -12
        d.limiter.attackMs = 0.5
        d.limiter.releaseMs = 5
        d.limiter.lookAheadMs = 2
        d.limiter.truePeakGuardEnabled = false
        var snapshot = try d.makeProtectionSnapshot(sampleRate: rate)
        XCTAssertTrue(N60ProtectionSnapshotSetLimiterAutoRelease(&snapshot, auto))
        return snapshot
    }

    private func render(_ p: UnifiedGraphProtection, rate: Double, seconds: Double) throws -> [Float] {
        var configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        configuration.protection = p
        let host = try UnifiedGraphHost(spec: configuration.makeSpec())
        let total = Int(rate * seconds) / block * block
        var out: [Float] = []
        var position = 0
        while position < total {
            let tone = (0..<block).map { 0.7 * Float(sin(2.0 * .pi * 50.0 * Double(position + $0) / rate)) }
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: Int(host.inputChannels))
            input[0] = tone
            input[1] = tone
            out += try host.processOffline(input: input, frames: block)[0]
            position += block
        }
        return out
    }

    /// Energy outside the 50 Hz fundamental over the last 25 periods, relative to the fundamental.
    private func distortion(_ x: [Float], rate: Double) -> Double {
        let period = Int((rate / 50.0).rounded()), n = 25 * period, from = x.count - n
        var sc = 0.0, ss = 0.0, total = 0.0
        for i in 0..<n {
            let phase = 2.0 * Double.pi * 50.0 * Double(i) / rate
            let v = Double(x[from + i])
            sc += v * cos(phase); ss += v * sin(phase); total += v * v
        }
        let fundamental = 2.0 * (sc * sc + ss * ss) / Double(n)
        return (max(0, total - fundamental) / max(fundamental, 1e-30)).squareRoot()
    }

    func testAutoReleaseLowersLowFrequencyDistortionThroughTheGraphAtEveryRate() throws {
        for rate in Self.rates {
            let fixed = try render(protection(auto: false), rate: rate, seconds: 1.6)
            let auto = try render(protection(auto: true), rate: rate, seconds: 1.6)
            XCTAssertLessThan(distortion(auto, rate: rate), 0.8 * distortion(fixed, rate: rate), "rate \(rate)")
            let ceiling = Float(pow(10.0, -12.0 / 20.0))
            XCTAssertLessThanOrEqual(auto.dropFirst(Int(rate * 0.1)).map(abs).max() ?? 0, ceiling * 1.001, "ceiling holds at \(rate)")
        }
    }
}
