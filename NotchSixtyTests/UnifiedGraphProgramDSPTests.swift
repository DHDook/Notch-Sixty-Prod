import XCTest
@testable import NotchSixty

/// E6 S9a: stereo-class program DSP mapped onto the lane sets of an N-channel layout (decision D2).
/// Behavioural: real graphs, real blocks, every standard rate.
final class UnifiedGraphProgramDSPTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    private func shape(_ layout: OutputProgramLayout) throws -> UnifiedGraphLayoutShape {
        try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
    }

    private func peak(_ gainDB: Double) -> UnifiedGraphPEQSection {
        UnifiedGraphPEQSection(type: Int(N60BiquadFilterTypePeaking.rawValue), frequencyHz: 1_000, gainDB: gainDB, q: 1)
    }

    private func stereo(rate: Double, left: [UnifiedGraphPEQSection] = [], right: [UnifiedGraphPEQSection] = [],
                        stages: UnifiedGraphStereoStages = UnifiedGraphStereoStages()) -> UnifiedGraphConfiguration {
        var l = UnifiedGraphLane(); l.eq = left
        var r = UnifiedGraphLane(); r.eq = right
        var configuration = UnifiedGraphConfiguration(sampleRate: rate, lanes: [l, r])
        configuration.stereoStages = stages
        return configuration
    }

    private func config(
        rate: Double, layout: OutputProgramLayout, dsp: UnifiedGraphProgramDSP?
    ) throws -> UnifiedGraphConfiguration {
        let count = layout.roles.count
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(
            sampleRate: rate, programChannels: count, subwoofers: []
        )
        configuration.orderPolicy = .canonical
        configuration.programDSP = dsp
        return configuration
    }

    /// Renders a 1 kHz tone per lane (amplitude 0 = silent) and returns every output lane.
    private func render(_ configuration: UnifiedGraphConfiguration, amps: [Float], seconds: Double = 0.3) throws -> [[Float]] {
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        let rate = configuration.sampleRate
        let total = Int(rate * seconds) / block * block
        var out = [[Float]](repeating: [], count: amps.count)
        var position = 0
        while position < total {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: amps.count)
            for lane in 0..<amps.count where amps[lane] != 0 {
                input[lane] = (0..<block).map {
                    amps[lane] * Float(sin(2.0 * .pi * 1_000.0 * Double(position + $0) / rate))
                }
            }
            let result = try host.processOffline(input: input, frames: block)
            for lane in 0..<amps.count { out[lane] += result[lane] }
            position += block
        }
        return out
    }

    private func tail(_ x: [Float]) -> Double { rms(x[(x.count * 3 / 4)...]) }

    func testLinkedEQCoversEveryNonLFELaneAndLeavesLFEUntouched() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, left: [peak(6)], right: [peak(6)]),
                                             shape: s, eqMode: .linked)
            let amps = [Float](repeating: 0.1, count: 6)
            let base = try render(try config(rate: rate, layout: layout, dsp: nil), amps: amps)
            let eq = try render(try config(rate: rate, layout: layout, dsp: dsp), amps: amps)
            let lfe = try XCTUnwrap(s.lfeLane)
            for lane in 0..<6 {
                if lane == lfe {
                    XCTAssertEqual(eq[lane], base[lane], "LFE must be bit-identical at \(rate)")
                } else {
                    let ratio = tail(eq[lane]) / tail(base[lane])
                    XCTAssertEqual(20 * log10(ratio), 6, accuracy: 0.5, "lane \(lane) at \(rate)")
                }
            }
        }
    }

    func testIndependentEQTouchesOnlyPairMembers() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, left: [peak(6)]), shape: s, eqMode: .independent)
            let amps = [Float](repeating: 0.1, count: 6)
            let base = try render(try config(rate: rate, layout: layout, dsp: nil), amps: amps)
            let eq = try render(try config(rate: rate, layout: layout, dsp: dsp), amps: amps)
            let touched = Set(s.leftMembers)
            for lane in 0..<6 {
                if touched.contains(lane) {
                    XCTAssertNotEqual(eq[lane], base[lane], "lane \(lane) at \(rate)")
                } else {
                    XCTAssertEqual(eq[lane], base[lane], "lane \(lane) must be untouched at \(rate)")
                }
            }
        }
    }

    func testLinkedCompressorReducesQuietLaneFromLoudLane() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            var stages = UnifiedGraphStereoStages()
            stages.compressor = [-30, 4, 6, 5, 50, 0, 0, 0, 0, 1]
            let dsp = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, stages: stages), shape: s, eqMode: .linked)
            // Loud tone on lane 0, a quiet one (below threshold on its own) on the lane across the layout.
            var amps = [Float](repeating: 0, count: 6)
            amps[0] = 0.8
            amps[4] = 0.01
            let base = try render(try config(rate: rate, layout: layout, dsp: nil), amps: amps)
            let comp = try render(try config(rate: rate, layout: layout, dsp: dsp), amps: amps)
            XCTAssertLessThan(tail(comp[4]), tail(base[4]) * 0.9, "quiet lane follows the group at \(rate)")
            XCTAssertLessThan(tail(comp[0]), tail(base[0]) * 0.9, "loud lane reduced at \(rate)")
        }
    }

    func testFrontPairDelayLeavesOtherLanesInPlace() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            var l = UnifiedGraphLane(); l.delayFrames = 48
            var r = UnifiedGraphLane(); r.delayFrames = 48
            var st = UnifiedGraphConfiguration(sampleRate: rate, lanes: [l, r])
            st.stereoStages = UnifiedGraphStereoStages()
            let dsp = UnifiedGraphProgramDSP(stereo: st, shape: s, eqMode: .linked)
            let amps = [Float](repeating: 0.1, count: 6)
            let base = try render(try config(rate: rate, layout: layout, dsp: nil), amps: amps)
            let delayed = try render(try config(rate: rate, layout: layout, dsp: dsp), amps: amps)
            let front: Set<Int> = [try XCTUnwrap(s.frontLeft), try XCTUnwrap(s.frontRight)]
            for lane in 0..<6 {
                if front.contains(lane) {
                    XCTAssertNotEqual(delayed[lane], base[lane], "front lane \(lane) at \(rate)")
                } else {
                    XCTAssertEqual(delayed[lane], base[lane], "lane \(lane) must be untouched at \(rate)")
                }
            }
        }
    }

    func testRejectionsNameTheirReason() throws {
        let rate = 48_000.0
        let s = try shape(.fiveOne)
        var spec = try config(rate: rate, layout: .fiveOne, dsp: nil).makeSpec()

        var delayLane = UnifiedGraphLane(); delayLane.delayFrames = 16
        let delayed = UnifiedGraphConfiguration(sampleRate: rate, lanes: [delayLane, delayLane])
        var virtual = UnifiedGraphProgramDSP(stereo: delayed, shape: s, eqMode: .linked, virtualSpeakers: true)
        XCTAssertThrowsError(try virtual.apply(to: &spec)) {
            XCTAssertEqual($0 as? UnifiedGraphFallbackReason, .virtualSpeakersSpeakerStage)
        }

        var fir = UnifiedGraphStereoStages()
        fir.programFIR = UnifiedGraphFIRProgram(generation: 1, left: [1, 0, 0, 0], right: nil, declaredLatencyFrames: 0)
        let ms = UnifiedGraphProgramDSP(stereo: stereo(rate: rate, left: [peak(3)], stages: fir), shape: s, eqMode: .midSide)
        XCTAssertThrowsError(try ms.apply(to: &spec)) {
            XCTAssertEqual($0 as? UnifiedGraphFallbackReason, .midSideProgramFIR)
        }
    }

    func testNeutralProgramDSPChangesNothing() throws {
        let rate = 48_000.0
        let s = try shape(.fiveOne)
        let neutral = UnifiedGraphProgramDSP(stereo: stereo(rate: rate), shape: s, eqMode: .linked)
        XCTAssertTrue(neutral.isNeutral)
        let amps = [Float](repeating: 0.1, count: 6)
        let a = try render(try config(rate: rate, layout: .fiveOne, dsp: nil), amps: amps)
        let b = try render(try config(rate: rate, layout: .fiveOne, dsp: neutral), amps: amps)
        XCTAssertEqual(a, b)
    }

    func testSevenOneFourBuildsAndRendersWithHeavyProgramDSP() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.sevenOneFour
            let s = try shape(layout)
            var stages = UnifiedGraphStereoStages()
            stages.compressor = [-30, 4, 6, 5, 50, 0, 0, 0, 0, 1]
            let dsp = UnifiedGraphProgramDSP(
                stereo: stereo(rate: rate, left: [peak(3), peak(-2)], right: [peak(3), peak(-2)], stages: stages),
                shape: s, eqMode: .linked
            )
            let amps = [Float](repeating: 0.1, count: layout.roles.count)
            let out = try render(try config(rate: rate, layout: layout, dsp: dsp), amps: amps, seconds: 0.1)
            XCTAssertEqual(out.count, layout.roles.count)
            XCTAssertTrue(out.allSatisfy { $0.allSatisfy(\.isFinite) }, "finite at \(rate)")
        }
    }
}
