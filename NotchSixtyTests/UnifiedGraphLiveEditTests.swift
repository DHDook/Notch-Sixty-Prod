import XCTest
@testable import NotchSixty

/// E6 S9b: live edits republish the graph; the ambient order decision of 24 Oct 2026 (ambient after the compressor
/// and expander, before protection). Behavioural: real graphs, real blocks, every standard rate.
final class UnifiedGraphLiveEditTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    private func tone(_ rate: Double, amp: Float, start: Int, count: Int) -> [Float] {
        (0..<count).map { amp * Float(sin(2.0 * .pi * 1_000.0 * Double(start + $0) / rate)) }
    }

    /// Runs `seconds` of a 1 kHz tone on every lane in `amps` and returns each lane's output.
    @discardableResult
    private func run(_ host: UnifiedGraphHost, rate: Double, amps: [Float], seconds: Double,
                     from position: inout Int) throws -> [[Float]] {
        let total = Int(rate * seconds) / block * block
        var out = [[Float]](repeating: [], count: amps.count)
        var done = 0
        while done < total {
            let input = amps.map { tone(rate, amp: $0, start: position, count: block) }
            let result = try host.processOffline(input: input, frames: block)
            for lane in 0..<amps.count { out[lane] += result[lane] }
            position += block
            done += block
        }
        return out
    }

    private func peak(_ gainDB: Double) -> UnifiedGraphPEQSection {
        UnifiedGraphPEQSection(type: Int(N60BiquadFilterTypePeaking.rawValue), frequencyHz: 1_000, gainDB: gainDB, q: 1)
    }

    private func program(
        rate: Double, layout: OutputProgramLayout, eq: Double? = nil, compressor: Bool = false, ambient: Bool = false
    ) throws -> UnifiedGraphProgramDSP {
        var lane = UnifiedGraphLane()
        if let eq { lane.eq = [peak(eq)] }
        var stereo = UnifiedGraphConfiguration(sampleRate: rate, lanes: [lane, lane])
        if compressor { stereo.stereoStages.compressor = [-30, 4, 6, 5, 50, 0, 0, 0, 0, 1] }
        if ambient { stereo.stereoStages.ambient = ambientParams(rate) }
        return UnifiedGraphProgramDSP(
            stereo: stereo, shape: try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles)), eqMode: .linked)
    }

    /// Ambient stage parameters as the snapshot translator produces them (a +4 dB level boost).
    private func ambientParams(_ rate: Double) -> [Float] {
        var s = N60DSPGraphSnapshotMakeUnity(rate)
        XCTAssertTrue(N60DSPGraphSnapshotSetAmbientCompensation(&s, 4, 0, 0, 0, true))
        let configuration = UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: rate)
        return configuration?.stereoStages.ambient ?? []
    }

    private func spec(_ rate: Double, _ layout: OutputProgramLayout, _ dsp: UnifiedGraphProgramDSP?) throws -> UnifiedGraphSpec {
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(
            sampleRate: rate, programChannels: layout.roles.count, subwoofers: [])
        configuration.orderPolicy = .canonical
        configuration.programDSP = dsp
        return try configuration.makeSpec()
    }

    // MARK: ambient order

    func testAmbientBoostDoesNotChangeCompressorGainReduction() throws {
        for rate in Self.rates {
            var reductions: [Float] = []
            for ambient in [false, true] {
                var s = N60DSPGraphSnapshotMakeUnity(rate)
                XCTAssertTrue(N60DynamicsSnapshotSetCompressor(&s.dynamics, rate, true, -20, 4, 0, 2, 50, 0))
                if ambient { XCTAssertTrue(N60DSPGraphSnapshotSetAmbientCompensation(&s, 4, 0, 0, 0, true)) }
                let configuration = try XCTUnwrap(
                    UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: rate),
                    "ambient with a compressor is eligible at \(rate)")
                let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
                var position = 0
                try run(host, rate: rate, amps: [0.5, 0.5], seconds: 0.4, from: &position)
                reductions.append(try XCTUnwrap(host.dynamicsReadings()).compressorGainReductionDB)
            }
            XCTAssertGreaterThan(reductions[0], 1, "the compressor works at \(rate)")
            XCTAssertEqual(reductions[0], reductions[1], accuracy: 0.05,
                           "the ambient boost sits after the compressor at \(rate)")
        }
    }

    func testAmbientBoostDoesNotChangeCompressorGainReductionOnFiveOne() throws {
        for rate in Self.rates {
            var reductions: [Float] = []
            for ambient in [false, true] {
                let layout = OutputProgramLayout.fiveOne
                let host = try UnifiedGraphHost(
                    spec: try spec(rate, layout, try program(rate: rate, layout: layout, compressor: true, ambient: ambient)))
                var position = 0
                try run(host, rate: rate, amps: [Float](repeating: 0.5, count: 6), seconds: 0.4, from: &position)
                reductions.append(try XCTUnwrap(host.dynamicsReadings()).compressorGainReductionDB)
            }
            XCTAssertGreaterThan(reductions[0], 1, "rate \(rate)")
            XCTAssertEqual(reductions[0], reductions[1], accuracy: 0.05, "rate \(rate)")
        }
    }

    func testAmbientBoostStillRaisesTheOutput() throws {
        for rate in Self.rates {
            let layout = OutputProgramLayout.fiveOne
            var levels: [Double] = []
            for ambient in [false, true] {
                let host = try UnifiedGraphHost(
                    spec: try spec(rate, layout, try program(rate: rate, layout: layout, compressor: true, ambient: ambient)))
                var position = 0
                let out = try run(host, rate: rate, amps: [0.5, 0, 0, 0, 0, 0], seconds: 0.4, from: &position)
                levels.append(rms(out[0][(out[0].count * 3 / 4)...]))
            }
            XCTAssertGreaterThan(levels[1], levels[0] * 1.3, "ambient boost reaches the output at \(rate)")
        }
    }

    // MARK: live edits

    func testLiveEditsMatchAFreshBuildAfterTheFadeOnFiveOne() throws {
        let layout = OutputProgramLayout.fiveOne
        for rate in Self.rates {
            let targets: [(String, UnifiedGraphProgramDSP)] = [
                ("eq", try program(rate: rate, layout: layout, eq: 6)),
                ("compressor", try program(rate: rate, layout: layout, compressor: true)),
                ("ambient", try program(rate: rate, layout: layout, compressor: true, ambient: true)),
            ]
            for (name, target) in targets {
                let amps: [Float] = [0.3, 0.2, 0.1, 0.05, 0.25, 0.15]
                let live = try UnifiedGraphHost(spec: try spec(rate, layout, nil))
                var position = 0
                try run(live, rate: rate, amps: amps, seconds: 0.1, from: &position)
                _ = try live.apply(try spec(rate, layout, target))
                try run(live, rate: rate, amps: amps, seconds: 0.5, from: &position)
                let after = try run(live, rate: rate, amps: amps, seconds: 0.3, from: &position)

                let fresh = try UnifiedGraphHost(spec: try spec(rate, layout, target))
                var freshPosition = 0
                try run(fresh, rate: rate, amps: amps, seconds: 0.6, from: &freshPosition)
                let expected = try run(fresh, rate: rate, amps: amps, seconds: 0.3, from: &freshPosition)
                for lane in 0..<amps.count {
                    let a = rms(after[lane][(after[lane].count / 2)...])
                    let b = rms(expected[lane][(expected[lane].count / 2)...])
                    XCTAssertEqual(a, b, accuracy: max(b * 0.03, 1e-5), "\(name) lane \(lane) at \(rate)")
                }
            }
        }
    }

    func testLiveEditNeverStepsAboveTheRampSlope() throws {
        let layout = OutputProgramLayout.fiveOne
        for rate in Self.rates {
            let targets: [(String, UnifiedGraphProgramDSP)] = [
                ("eq", try program(rate: rate, layout: layout, eq: 4)),
                ("compressor", try program(rate: rate, layout: layout, compressor: true)),
                ("ambient", try program(rate: rate, layout: layout, ambient: true)),
            ]
            for (name, target) in targets {
                let host = try UnifiedGraphHost(spec: try spec(rate, layout, nil))
                var position = 0
                let amps: [Float] = [0.2, 0, 0, 0, 0, 0]
                try run(host, rate: rate, amps: amps, seconds: 0.1, from: &position)
                _ = try host.apply(try spec(rate, layout, target))
                let out = try run(host, rate: rate, amps: amps, seconds: 0.5, from: &position)
                // The edit may raise the level (up to about 2x for the 4 dB boost); the slope bound allows for that.
                let slope = Float(0.45 * 2.0 * .pi * 1_000.0 / rate)
                var maxStep: Float = 0
                for index in 1..<out[0].count { maxStep = max(maxStep, abs(out[0][index] - out[0][index - 1])) }
                XCTAssertLessThan(maxStep, 4 * slope + 1e-3, "\(name) at \(rate)")
            }
        }
    }

    // MARK: binaural

    func testBinauralProgramGainIsLiveThroughTheInputGainStage() throws {
        for rate in Self.rates {
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.programLayout = .fiveOne
            let base = try XCTUnwrap(try? UnifiedGraphTranslator.binauralBaseSpec(
                asset: BinauralProfileAsset.validationStereo(sampleRate: rate), layout: .fiveOne, profile: profile,
                outputChannels: 2, sampleRate: rate, headTracking: false, programGain: 1).get(), "rate \(rate)")
            let quiet = try UnifiedGraphTranslator.binauralApplyProgram(base: base, programDSP: nil, programGain: 1).get()
            let loud = try UnifiedGraphTranslator.binauralApplyProgram(base: base, programDSP: nil, programGain: 2).get()
            let amps: [Float] = [0.1, 0, 0, 0, 0, 0]

            let live = try UnifiedGraphHost(spec: quiet)
            var position = 0
            try run(live, rate: rate, amps: amps, seconds: 0.1, from: &position)
            _ = try live.apply(loud)
            try run(live, rate: rate, amps: amps, seconds: 0.5, from: &position)
            let after = try run(live, rate: rate, amps: amps, seconds: 0.3, from: &position)

            let fresh = try UnifiedGraphHost(spec: loud)
            var freshPosition = 0
            try run(fresh, rate: rate, amps: amps, seconds: 0.6, from: &freshPosition)
            let expected = try run(fresh, rate: rate, amps: amps, seconds: 0.3, from: &freshPosition)
            for ear in 0..<2 {
                let a = rms(after[ear][(after[ear].count / 2)...])
                let b = rms(expected[ear][(expected[ear].count / 2)...])
                XCTAssertGreaterThan(b, 0, "rate \(rate)")
                XCTAssertEqual(a, b, accuracy: max(b * 0.03, 1e-6), "ear \(ear) at \(rate)")
            }
        }
    }

    func testBinauralGainOutOfRangeIsRefused() throws {
        let rate = 48_000.0
        var profile = HeadphoneDeviceProfileConfiguration()
        profile.programLayout = .fiveOne
        let base = try UnifiedGraphTranslator.binauralBaseSpec(
            asset: BinauralProfileAsset.validationStereo(sampleRate: rate), layout: .fiveOne, profile: profile,
            outputChannels: 2, sampleRate: rate, headTracking: false).get()
        guard case .failure(let reason) = UnifiedGraphTranslator.binauralApplyProgram(
            base: base, programDSP: nil, programGain: 40) else { return XCTFail("a gain above 16 must be refused") }
        XCTAssertEqual(reason, .gainOutOfRange)
    }
}
