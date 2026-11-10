import XCTest
@testable import NotchSixty

/// E4 S30a: the AMBIENT stage's live section trailer (graph ABI v32) and its control-plane fit, at every standard rate.
final class AmbientUnmaskOverlayTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private var smoothPlan: [Double] {
        // Broad speech-band cut, 0 to 4.5 dB, no band-to-band step over 1.5 dB.
        [0, 0, 0.5, 1.5, 2.5, 3.5, 4.5, 4.5, 4, 3.5, 2.5, 1.5, 1, 0.5, 0, 0, 0]
    }

    private func centreError(_ plan: [Double], rate: Double) throws -> Double {
        let gains = try XCTUnwrap(AmbientUnmaskOverlay.sectionGains(plannedCutsDB: plan, sampleRate: rate))
        var worst = 0.0
        for (i, f) in AmbientUnmaskOverlay.centersHz.enumerated() where f <= rate * 0.45 {
            let got = AmbientUnmaskOverlay.response(gainsDB: gains, atHz: f, sampleRate: rate)
            worst = max(worst, abs(got - (-plan[i])))
        }
        return worst
    }

    func testRealisedResponseFollowsASmoothPlanAtTheCentresAtEveryRate() throws {
        for rate in Self.rates {
            XCTAssertLessThan(try centreError(smoothPlan, rate: rate), 0.5, "smooth plan at \(rate)")
            var single = [Double](repeating: 0, count: 17)
            single[7] = 4
            // Cuts only: an isolated band cannot be matched at its neighbours (they would need a boost), so the
            // fit compromises. The band itself still gets most of its cut and nothing is boosted.
            let gains = try XCTUnwrap(AmbientUnmaskOverlay.sectionGains(plannedCutsDB: single, sampleRate: rate))
            let atCentre = AmbientUnmaskOverlay.response(
                gainsDB: gains, atHz: AmbientUnmaskOverlay.centersHz[7], sampleRate: rate)
            XCTAssertLessThan(atCentre, -3.0, "single band cut at \(rate)")
            XCTAssertGreaterThan(atCentre, -5.0, "single band cut at \(rate)")
        }
    }

    func testRealisedResponseNeverBoostsAndNeverCutsPastTheLimitAtEveryRate() throws {
        let rough = [0, 6, 0, 6, 0, 6, 6, 0, 6, 6, 6, 0, 6, 0, 6, 0, 6].map(Double.init)
        let flat = [Double](repeating: 6, count: 17)
        for rate in Self.rates {
            for plan in [smoothPlan, rough, flat] {
                let gains = try XCTUnwrap(AmbientUnmaskOverlay.sectionGains(plannedCutsDB: plan, sampleRate: rate))
                XCTAssertTrue(gains.allSatisfy { $0 <= 0 && $0 >= -8 }, "section range at \(rate)")
                let high = rate * 0.45
                for k in 0..<512 {
                    let f = 20 * pow(high / 20, Double(k) / 511)
                    let r = AmbientUnmaskOverlay.response(gainsDB: gains, atHz: f, sampleRate: rate)
                    XCTAssertLessThanOrEqual(r, 1e-9, "never above 0 dB at \(f) Hz, \(rate)")
                    XCTAssertGreaterThanOrEqual(r, -7.0001, "no more than 7 dB of cut at \(f) Hz, \(rate)")
                }
            }
        }
    }

    func testTheLowSkirtLeavesTheBassAloneAtEveryRate() throws {
        // The lowest section is 200 Hz at one third octave: below 125 Hz the response stays under 0.3 dB.
        for rate in Self.rates {
            let gains = try XCTUnwrap(AmbientUnmaskOverlay.sectionGains(plannedCutsDB: smoothPlan, sampleRate: rate))
            for f in stride(from: 20.0, through: 125.0, by: 5.0) {
                let r = AmbientUnmaskOverlay.response(gainsDB: gains, atHz: f, sampleRate: rate)
                XCTAssertGreaterThan(r, -0.3, "bass at \(f) Hz, \(rate)")
            }
        }
    }

    func testInvalidPlansAreRefused() {
        let good = [Double](repeating: 1, count: 17)
        XCTAssertNil(AmbientUnmaskOverlay.sectionGains(plannedCutsDB: Array(good.dropLast()), sampleRate: 48_000))
        var boost = good; boost[3] = -1
        XCTAssertNil(AmbientUnmaskOverlay.sectionGains(plannedCutsDB: boost, sampleRate: 48_000))
        var deep = good; deep[3] = 6.5
        XCTAssertNil(AmbientUnmaskOverlay.sectionGains(plannedCutsDB: deep, sampleRate: 48_000))
        var nan = good; nan[0] = .nan
        XCTAssertNil(AmbientUnmaskOverlay.sectionGains(plannedCutsDB: nan, sampleRate: 48_000))
        XCTAssertNil(AmbientUnmaskOverlay.stageParameters(base: [0, 1], plannedCutsDB: good, sampleRate: 48_000))
    }

    func testStageParametersCarryTheTrailerInTheLegalRangeAtEveryRate() throws {
        for rate in Self.rates {
            let params = try XCTUnwrap(
                AmbientUnmaskOverlay.stageParameters(base: nil, plannedCutsDB: smoothPlan, sampleRate: rate))
            XCTAssertEqual(params.count, 11 + 3 * 17)
            XCTAssertEqual(params[10], 17)
            for i in 0..<17 {
                XCTAssertLessThanOrEqual(Double(params[11 + 3 * i]), rate * 0.45)
                XCTAssertLessThanOrEqual(params[12 + 3 * i], 0)
                XCTAssertGreaterThanOrEqual(params[12 + 3 * i], -8)
            }
        }
    }

    // MARK: Through the graph

    private func spec(_ params: [Float], rate: Double) throws -> UnifiedGraphSpec {
        var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
        var configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        configuration.stereoStages.ambient = params
        return try configuration.makeSpec()
    }

    private func noise(_ frames: Int, seed: UInt32) -> [Float] {
        var state = seed
        return (0..<frames).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.25
        }
    }

    private func render(_ host: UnifiedGraphHost, _ input: [[Float]]) throws -> [[Float]] {
        var out: [[Float]] = [[], []]
        var position = 0
        while position + block <= input[0].count {
            let chunk = input.map { Array($0[position..<position + block]) }
            let r = try host.processOffline(input: chunk, frames: block)
            out[0] += r[0]; out[1] += r[1]
            position += block
        }
        return out
    }

    func testNoTrailerAndAZeroTrailerRenderLikeThePlainStageAtEveryRate() throws {
        // G6: the unified graph with no cut is the kernel-equivalent stage, bit for bit.
        for rate in Self.rates {
            let base = AmbientUnmaskOverlay.neutralBase.enumerated().map { $0.offset == 2 ? Float(1.5) : $0.element }
            let zero = try XCTUnwrap(AmbientUnmaskOverlay.stageParameters(
                base: base, plannedCutsDB: [Double](repeating: 0, count: 17), sampleRate: rate))
            let frames = Int(rate * 0.2) / block * block
            let input = [noise(frames, seed: 1), noise(frames, seed: 2)]
            let plain = try UnifiedGraphHost(spec: spec(base, rate: rate))
            let trailer = try UnifiedGraphHost(spec: spec(zero, rate: rate))
            defer { plain.release(); trailer.release() }
            XCTAssertEqual(try render(plain, input), try render(trailer, input), "zero cuts at \(rate)")
        }
    }

    func testCutsMatchTheAnalyticResponseThroughTheGraphAtEveryRate() throws {
        // A tone at three band centres comes out with the modelled gain, so the kernel-side and control-side maths agree.
        for rate in Self.rates {
            let params = try XCTUnwrap(
                AmbientUnmaskOverlay.stageParameters(base: nil, plannedCutsDB: smoothPlan, sampleRate: rate))
            let gains = try XCTUnwrap(AmbientUnmaskOverlay.sectionGains(plannedCutsDB: smoothPlan, sampleRate: rate))
            for f in [630.0, 1_600.0, 3_150.0] {
                let host = try UnifiedGraphHost(spec: spec(params, rate: rate))
                defer { host.release() }
                let frames = Int(rate * 0.4) / block * block
                let tone = (0..<frames).map { Float(0.25 * sin(2 * .pi * f * Double($0) / rate)) }
                let out = try render(host, [tone, tone])
                let start = frames * 3 / 4
                func rms(_ x: ArraySlice<Float>) -> Double {
                    sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
                }
                let measured = 20 * log10(rms(out[0][start...]) / rms(tone[start...]))
                let expected = AmbientUnmaskOverlay.response(gainsDB: gains, atHz: f, sampleRate: rate)
                XCTAssertEqual(measured, expected, accuracy: 0.15, "\(f) Hz at \(rate)")
            }
        }
    }

    func testALiveCutEditIsPostedNotRebuiltAtEveryRate() throws {
        for rate in Self.rates {
            let a = try XCTUnwrap(AmbientUnmaskOverlay.stageParameters(base: nil, plannedCutsDB: smoothPlan, sampleRate: rate))
            let b = try XCTUnwrap(AmbientUnmaskOverlay.stageParameters(
                base: nil, plannedCutsDB: smoothPlan.map { $0 * 0.5 }, sampleRate: rate))
            let host = try UnifiedGraphHost(spec: spec(a, rate: rate))
            defer { host.release() }
            guard case .posted = try host.apply(spec(b, rate: rate)) else {
                return XCTFail("a section gain edit must post at \(rate)")
            }
            // An all-zero plan (speech stops) keeps n = 17, so it posts too.
            let zero = try XCTUnwrap(AmbientUnmaskOverlay.stageParameters(
                base: nil, plannedCutsDB: [Double](repeating: 0, count: 17), sampleRate: rate))
            guard case .posted = try host.apply(spec(zero, rate: rate)) else {
                return XCTFail("a return to zero must post at \(rate)")
            }
        }
    }

    func testALiveEditNeverStepsFasterThanTheRampAtEveryRate() throws {
        for rate in Self.rates {
            let loud = [Double](repeating: 6, count: 17)
            let a = try XCTUnwrap(AmbientUnmaskOverlay.stageParameters(
                base: nil, plannedCutsDB: [Double](repeating: 0, count: 17), sampleRate: rate))
            let b = try XCTUnwrap(AmbientUnmaskOverlay.stageParameters(base: nil, plannedCutsDB: loud, sampleRate: rate))
            let host = try UnifiedGraphHost(spec: spec(a, rate: rate))
            defer { host.release() }
            let frames = Int(rate * 0.3) / block * block
            // A 1 kHz sine: the cut moves the amplitude, never a jump larger than the whole-cut step per sample.
            let tone = (0..<frames).map { Float(0.25 * sin(2 * .pi * 1_000 * Double($0) / rate)) }
            var out: [[Float]] = [[], []]
            var position = 0
            while position + block <= frames {
                if position == block * 4 { _ = try host.apply(spec(b, rate: rate)) }
                let chunk = [Array(tone[position..<position + block]), Array(tone[position..<position + block])]
                let r = try host.processOffline(input: chunk, frames: block)
                out[0] += r[0]; out[1] += r[1]
                position += block
            }
            // A sample-to-sample jump beyond what the tone's own slope plus a 1 dB-per-ramp-quarter envelope allows
            // would be a step. 0.25 * 2 pi f / fs is the tone's own maximum slope.
            let slope = 0.25 * 2 * Double.pi * 1_000 / rate
            var worst = 0.0
            for i in 1..<out[0].count { worst = max(worst, abs(Double(out[0][i] - out[0][i - 1]))) }
            XCTAssertLessThan(worst, slope * 1.5 + 1e-4, "no step at \(rate)")
            XCTAssertTrue(out[0].allSatisfy { $0.isFinite })
        }
    }

    func testSeventeenCutSectionsStayFiniteOnFullScaleNoiseAtEveryRate() throws {
        for rate in Self.rates {
            let params = try XCTUnwrap(AmbientUnmaskOverlay.stageParameters(
                base: nil, plannedCutsDB: [Double](repeating: 6, count: 17), sampleRate: rate))
            let host = try UnifiedGraphHost(spec: spec(params, rate: rate))
            defer { host.release() }
            let frames = Int(rate * 0.2) / block * block
            let loud = noise(frames, seed: 9).map { max(-1, min(1, $0 * 4)) }
            let out = try render(host, [loud, loud])
            XCTAssertTrue(out[0].allSatisfy { $0.isFinite && abs($0) < 4 }, "finite at \(rate)")
        }
    }

    // MARK: Engine hook

    func testTheTargetCarriesNoCutsByDefault() {
        XCTAssertNil(AmbientCompensationTarget.unity.unmaskingCutsDB)
    }
}
