import XCTest
@testable import NotchSixty

/// E8 S9: the YAML-subset reader, CamillaDSP import and export for the routing model, and the pipeline view's model.
final class CamillaDSPRoutingTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let uid = "dev"

    private func ctx(programLanes: Int = 2, subs: Int = 0, rate: Double = 48_000) -> SpeakerRoutingContext {
        SpeakerRoutingContext(programLanes: programLanes, subwoofers: subs, sampleRate: rate)
    }

    private func ep(_ i: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: uid, channelIndex: i) }

    // MARK: YAML subset

    func testYAMLSubsetParsesBlocksFlowAndComments() throws {
        let node = try YAMLSubset.parse("""
        ---
        # comment
        a: 1   # trailing
        b:
          - x
          - key: v
            other: "q: r"
        c: [0, 1, 2]
        d: {}
        e:
        - 7
        """)
        XCTAssertEqual(node["a"]?.int, 1)
        XCTAssertEqual(node["b"]?.items?.count, 2)
        XCTAssertEqual(node["b"]?.items?[1]["key"]?.string, "v")
        XCTAssertEqual(node["b"]?.items?[1]["other"]?.string, "q: r")
        XCTAssertEqual(node["c"]?.items?.compactMap(\.int), [0, 1, 2])
        XCTAssertEqual(node["d"]?.entries?.count, 0)
        XCTAssertEqual(node["e"]?.items?.first?.int, 7)
    }

    func testMalformedYAMLReportsLineNumber() {
        func line(_ text: String) -> Int? {
            do { _ = try YAMLSubset.parse(text); return nil } catch let e as YAMLSubsetError { return e.line } catch { return nil }
        }
        XCTAssertEqual(line("a: 1\nb: [1, 2\n"), 2)
        XCTAssertEqual(line("a: 1\n\tb: 2\n"), 2)
        XCTAssertEqual(line("a: 1\na: 2\n"), 2)
        XCTAssertEqual(line("a:\n    b: 1\n  c: 2\n"), 3)
        XCTAssertEqual(line("a: |\n"), 1)
        XCTAssertEqual(line("a: \"open\n"), 1)
        XCTAssertThrowsError(try CamillaDSPRouting.importRouting("a: [1\n", context: ctx(), deviceUID: uid)) {
            XCTAssertEqual(($0 as? YAMLSubsetError)?.line, 1)
        }
    }

    // MARK: Reference files

    private let twoWayYAML = """
    ---
    devices:
      samplerate: 48000
      capture: {type: CoreAudio, channels: 2, device: "in"}
      playback: {type: CoreAudio, channels: 4, device: "out"}
    mixers:
      split:
        channels: {in: 2, out: 4}
        mapping:
          - dest: 0
            sources: [{channel: 0, gain: 0}]
          - dest: 1
            sources: [{channel: 0, gain: 0}]
          - dest: 2
            sources: [{channel: 1, gain: 0}]
          - dest: 3
            sources: [{channel: 1, gain: 0}]
    filters:
      lp:
        type: BiquadCombo
        parameters: {type: LinkwitzRileyLowpass, freq: 2000, order: 4}
      hp:
        type: BiquadCombo
        parameters: {type: LinkwitzRileyHighpass, freq: 2000, order: 4}
      tweeter_gain:
        type: Gain
        parameters: {gain: -3.5, inverted: true}
      tweeter_delay:
        type: Delay
        parameters: {delay: 0.25, unit: ms}
      bump:
        type: Biquad
        parameters: {type: Peaking, freq: 1000, gain: 2.5, q: 1.5}
      room:
        type: Biquad
        parameters: {type: Lowshelf, freq: 80, gain: -2, q: 0.7}
    pipeline:
      - type: Filter
        channels: [0, 1]
        names: [room]
      - type: Mixer
        name: split
      - type: Filter
        channels: [0, 2]
        names: [lp]
      - type: Filter
        channels: [1, 3]
        names: [hp, tweeter_gain, tweeter_delay, bump]
    """

    func testTwoWayImportBuildsExpectedModel() throws {
        let imported = try CamillaDSPRouting.importRouting(twoWayYAML, context: ctx(), deviceUID: uid)
        XCTAssertEqual(imported.warnings, [])
        let routing = try XCTUnwrap(imported.routing)
        XCTAssertEqual(routing.speakers.count, 2)
        XCTAssertEqual(routing.speakers[0].source, .program(0))
        XCTAssertEqual(routing.speakers[1].source, .program(1))
        let left = routing.speakers[0].ways
        XCTAssertEqual(left.map(\.endpoint), [ep(0), ep(1)])
        XCTAssertEqual(left[0].lowPass, CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 2000))
        XCTAssertNil(left[0].highPass)
        XCTAssertEqual(left[1].highPass, CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 2000))
        XCTAssertEqual(left[1].trimDB, -3.5)
        XCTAssertTrue(left[1].polarityInverted)
        XCTAssertEqual(left[1].delayMilliseconds, 0.25)
        XCTAssertEqual(left[1].eq, [RoutingEQSection(type: 0, frequencyHz: 1000, gainDB: 2.5, q: 1.5)])
        XCTAssertEqual(routing.speakers[1].ways.map(\.endpoint), [ep(2), ep(3)])
        XCTAssertEqual(imported.programEQ[0], [RoutingEQSection(type: 1, frequencyHz: 80, gainDB: -2, q: 0.7)])
        XCTAssertEqual(imported.programEQ[1], imported.programEQ[0])
        XCTAssertTrue(routing.validate(in: ctx()).isValid)
    }

    func testThreeWayImport() throws {
        let yaml = """
        devices: {samplerate: 96000}
        mixers:
          m:
            channels: {in: 2, out: 3}
            mapping:
              - {dest: 0, sources: [{channel: 0}]}
              - {dest: 1, sources: [{channel: 0}]}
              - {dest: 2, sources: [{channel: 0}]}
        filters:
          lo: {type: BiquadCombo, parameters: {type: ButterworthLowpass, freq: 300, order: 3}}
          mid_hp: {type: BiquadCombo, parameters: {type: ButterworthHighpass, freq: 300, order: 3}}
          mid_lp: {type: BiquadCombo, parameters: {type: ButterworthLowpass, freq: 3000, order: 3}}
          hi: {type: BiquadCombo, parameters: {type: ButterworthHighpass, freq: 3000, order: 3}}
        pipeline:
          - {type: Mixer, name: m}
          - {type: Filter, channel: 0, names: [lo]}
          - {type: Filter, channel: 1, names: [mid_hp, mid_lp]}
          - {type: Filter, channel: 2, names: [hi]}
        """
        let imported = try CamillaDSPRouting.importRouting(yaml, context: ctx(rate: 48_000), deviceUID: uid)
        // The only note is the sample-rate difference.
        XCTAssertEqual(imported.warnings.count, 1)
        XCTAssertTrue(imported.warnings[0].contains("96000"))
        let ways = try XCTUnwrap(imported.routing).speakers.flatMap(\.ways)
        XCTAssertEqual(ways.count, 3)
        XCTAssertEqual(ways[1].highPass?.cornerHz, 300)
        XCTAssertEqual(ways[1].lowPass?.cornerHz, 3000)
        XCTAssertEqual(ways[1].lowPass?.family, .butterworth)
    }

    func testFiveOneImportWithSubAndSummedLFE() throws {
        let yaml = """
        mixers:
          m:
            channels: {in: 6, out: 6}
            mapping:
              - {dest: 0, sources: [{channel: 0}]}
              - {dest: 1, sources: [{channel: 1}]}
              - {dest: 2, sources: [{channel: 2}]}
              - {dest: 3, sources: [{channel: 3, gain: -10, scale: dB}]}
              - {dest: 4, sources: [{channel: 4}]}
              - dest: 5
                sources:
                  - {channel: 0, gain: -6}
                  - {channel: 1, gain: -6, inverted: true}
        filters: {}
        pipeline:
          - {type: Mixer, name: m}
        """
        let imported = try CamillaDSPRouting.importRouting(yaml, context: ctx(programLanes: 6), deviceUID: uid)
        XCTAssertEqual(imported.warnings, [])
        let routing = try XCTUnwrap(imported.routing)
        // Unity single-source outputs are ways; the attenuated output and the two-source sum are matrix entries.
        XCTAssertEqual(routing.speakers.map(\.source), [.program(0), .program(1), .program(2), .program(4)])
        XCTAssertEqual(routing.matrix.count, 3)
        XCTAssertEqual(routing.matrix[0].output, ep(3))
        XCTAssertEqual(routing.matrix[0].gain, pow(10, -0.5), accuracy: 1e-12)
        XCTAssertEqual(routing.matrix[2].gain, -pow(10, -6.0 / 20), accuracy: 1e-12)
        XCTAssertTrue(routing.validate(in: ctx(programLanes: 6)).isValid)
    }

    // MARK: Unsupported items

    func testEachUnsupportedItemWarns() throws {
        let yaml = """
        title: t
        extra_key: 1
        processors:
          comp: {type: Compressor}
        mixers:
          m:
            channels: {in: 2, out: 2}
            mapping:
              - {dest: 0, sources: [{channel: 0}]}
              - {dest: 1, sources: [{channel: 1}]}
        filters:
          fir: {type: Conv, parameters: {type: Values, values: [1, 0]}}
          dith: {type: Dither, parameters: {type: Simple, bits: 16}}
          loud: {type: Loudness, parameters: {reference_level: -25}}
          vol: {type: Volume, parameters: {ramp_time: 200}}
          bw: {type: Biquad, parameters: {type: Peaking, freq: 1000, gain: 1, bandwidth: 1}}
          lt: {type: Biquad, parameters: {type: LinkwitzTransform, freq_act: 50}}
          combo: {type: BiquadCombo, parameters: {type: Tilt, gain: 3}}
          ok: {type: Gain, parameters: {gain: -1}}
        pipeline:
          - {type: Mixer, name: m}
          - {type: Filter, channel: 0, names: [fir, dith, loud, vol, bw, lt, combo, ok, missing]}
          - {type: Processor, name: comp}
        """
        let imported = try CamillaDSPRouting.importRouting(yaml, context: ctx(), deviceUID: uid)
        let all = imported.warnings.joined(separator: "\n")
        for needle in ["extra_key", "processors", "`fir`", "`dith`", "`loud`", "`vol`", "`bw`", "`lt`", "`combo`", "`missing`", "Processor"] {
            XCTAssertTrue(all.contains(needle), "no warning mentions \(needle): \(all)")
        }
        XCTAssertEqual(imported.warnings.count, 11)
        // The supported gain still applies.
        XCTAssertEqual(try XCTUnwrap(imported.routing).speakers[0].ways[0].trimDB, -1)
    }

    func testSampleRateMismatchWarnsOnce() throws {
        let yaml = "devices: {samplerate: 44100}\npipeline: []\nfilters: {}\nmixers: {}\n"
        let imported = try CamillaDSPRouting.importRouting(yaml, context: ctx(rate: 192_000), deviceUID: uid)
        XCTAssertEqual(imported.warnings.count, 1)
        XCTAssertNil(imported.routing)
    }

    // MARK: Round trip

    private func canonical() -> (SpeakerRoutingConfiguration, [Int: [RoutingEQSection]]) {
        func spec(_ f: CrossoverCore.Family, _ o: Int, _ hz: Double) -> CrossoverCore.FilterSpec {
            CrossoverCore.FilterSpec(family: f, order: o, cornerHz: hz)
        }
        var low = RoutedWay(name: "Output 1", endpoint: ep(0))
        low.lowPass = spec(.linkwitzRiley, 4, 300)
        low.eq = [RoutingEQSection(type: 1, frequencyHz: 60, gainDB: 3, q: 0.8)]
        var mid = RoutedWay(name: "Output 2", endpoint: ep(1))
        mid.highPass = spec(.linkwitzRiley, 4, 300)
        mid.lowPass = spec(.butterworth, 3, 3_000)
        mid.trimDB = -2.5
        mid.polarityInverted = true
        mid.delayMilliseconds = 0.4
        var high = RoutedWay(name: "Output 3", endpoint: ep(2))
        high.highPass = spec(.butterworth, 3, 3_000)
        high.eq = [RoutingEQSection(type: 0, frequencyHz: 8_000, gainDB: -3, q: 2),
                   RoutingEQSection(type: 4, frequencyHz: 25, gainDB: 0, q: 0.7071)]
        let right = RoutedWay(name: "Output 4", endpoint: ep(3))
        let routing = SpeakerRoutingConfiguration(
            speakers: [
                RoutedSpeaker(name: "Speaker 1", source: .program(0), ways: [low, mid, high]),
                RoutedSpeaker(name: "Speaker 2", source: .program(1), ways: [right]),
            ],
            matrix: [
                RoutingMatrixEntry(source: .program(0), output: ep(4), gain: 0.5),
                RoutingMatrixEntry(source: .program(1), output: ep(4), gain: -0.25),
                RoutingMatrixEntry(source: .sub(0), output: ep(2), gain: 1.5),
            ])
        return (routing, [0: [RoutingEQSection(type: 0, frequencyHz: 120, gainDB: -4, q: 3)],
                          1: [RoutingEQSection(type: 2, frequencyHz: 9_000, gainDB: 1, q: 0.7)]])
    }

    func testExportImportRoundTripIsExact() throws {
        let (routing, programEQ) = canonical()
        let context = ctx(programLanes: 2, subs: 1)
        let exported = CamillaDSPRouting.exportRouting(routing, programEQ: programEQ, context: context)
        XCTAssertFalse(exported.yaml.isEmpty)
        let imported = try CamillaDSPRouting.importRouting(exported.yaml, context: context, deviceUID: uid)
        XCTAssertEqual(imported.warnings, [])
        let back = try XCTUnwrap(imported.routing)
        XCTAssertEqual(back.speakers.count, routing.speakers.count)
        for (a, b) in zip(routing.speakers, back.speakers) {
            XCTAssertEqual(a.source, b.source)
            XCTAssertEqual(a.ways.count, b.ways.count)
            for (x, y) in zip(a.ways, b.ways) {
                XCTAssertEqual(x.name, y.name)
                XCTAssertEqual(x.endpoint, y.endpoint)
                XCTAssertEqual(x.highPass, y.highPass)
                XCTAssertEqual(x.lowPass, y.lowPass)
                XCTAssertEqual(x.eq, y.eq)
                XCTAssertEqual(x.trimDB, y.trimDB)
                XCTAssertEqual(x.polarityInverted, y.polarityInverted)
                XCTAssertEqual(x.delayMilliseconds, y.delayMilliseconds)
            }
        }
        XCTAssertEqual(back.matrix.count, routing.matrix.count)
        for entry in routing.matrix {
            let found = try XCTUnwrap(back.matrix.first { $0.source == entry.source && $0.output == entry.output })
            XCTAssertEqual(found.gain, entry.gain, accuracy: 1e-12)
        }
        XCTAssertEqual(imported.programEQ, programEQ)
        // Exporting what was imported gives the same file.
        XCTAssertEqual(CamillaDSPRouting.exportRouting(back, programEQ: imported.programEQ, context: context).yaml, exported.yaml)
    }

    func testExportWarnsForUnrepresentableItems() {
        var way = RoutedWay(name: "W", endpoint: ep(0))
        way.highPass = CrossoverCore.FilterSpec(family: .bessel, order: 4, cornerHz: 500)
        way.limiter = RoutingLimiter()
        way.realisation = .fir
        let other = RoutedWay(name: "O", endpoint: PhysicalOutputEndpoint(deviceUID: "other", channelIndex: 0))
        let routing = SpeakerRoutingConfiguration(speakers: [RoutedSpeaker(name: "S", source: .program(0), ways: [way, other])])
        let warnings = CamillaDSPRouting.exportRouting(routing, context: ctx()).warnings.joined(separator: "\n")
        for needle in ["Bessel", "limiter", "minimum-phase", "other devices"] {
            XCTAssertTrue(warnings.contains(needle), "no export warning mentions \(needle)")
        }
    }

    // MARK: Pipeline

    func testPipelineLatencyMatchesCompilerAlignment() {
        var a = RoutedWay(name: "Woofer", endpoint: ep(0))
        a.lowPass = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 2_000)
        a.delayMilliseconds = 1
        var b = RoutedWay(name: "Tweeter", endpoint: ep(1))
        b.highPass = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 2_000)
        b.limiter = RoutingLimiter(lookAheadMilliseconds: 2)
        let routing = SpeakerRoutingConfiguration(speakers: [RoutedSpeaker(name: "L", source: .program(0), ways: [a, b])])
        for rate in Self.rates {
            let rows = SpeakerRoutingPipeline.rows(
                routing, context: ctx(rate: rate), programStages: [.init(name: "Room correction", latencyFrames: 100)])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0].steps.map(\.title), ["Source", "Room correction", "Route", "Crossover", "Delay", "Output"])
            XCTAssertEqual(rows[1].steps.map(\.title), ["Source", "Room correction", "Route", "Crossover", "Protection", "Output"])
            let protection = RoutingLimiter(lookAheadMilliseconds: 2).graphProtection.latencyFrames(sampleRate: rate)
            // Every output reaches the same latency: program stages plus the limiter's, plus the user delay on the woofer.
            XCTAssertEqual(rows[1].totalLatencyFrames, 100 + Double(protection), accuracy: 1e-9)
            XCTAssertEqual(rows[0].totalLatencyFrames, 100 + Double(protection) + 0.001 * rate, accuracy: 1e-6)
            XCTAssertEqual(rows[0].steps[3].detail, "Linkwitz-Riley 24 dB/oct low-pass 2000 Hz")
        }
    }

    func testPipelineShowsSummedFeedsAndMatrixOnlyOutput() {
        let routing = SpeakerRoutingConfiguration(
            speakers: [RoutedSpeaker(name: "L", source: .program(0), ways: [RoutedWay(name: "Full", endpoint: ep(0))])],
            matrix: [RoutingMatrixEntry(source: .program(1), output: ep(0), gain: 0.5),
                     RoutingMatrixEntry(source: .program(0), output: ep(5), gain: 1)])
        let rows = SpeakerRoutingPipeline.rows(routing, context: ctx())
        XCTAssertEqual(rows[0].steps[0].detail, "Program lane 1 + Program lane 2")
        XCTAssertEqual(rows[0].steps[1].detail, "2 feeds summed")
        XCTAssertEqual(rows[1].title, "Output 6")
        XCTAssertFalse(rows[1].steps.contains { $0.title == "Crossover" })
    }
}
