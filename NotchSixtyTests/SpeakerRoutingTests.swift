import XCTest
@testable import NotchSixty

/// E8 S3: routing model, validation, persistence and the pure compiler onto the unified graph.
@MainActor
final class SpeakerRoutingTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func ep(_ index: UInt32, device: String = "dev") -> PhysicalOutputEndpoint {
        PhysicalOutputEndpoint(deviceUID: device, channelIndex: index)
    }

    private func base(rate: Double = 48_000, lanes: Int, subs: Int = 0, lfe: Int? = nil) -> UnifiedGraphConfiguration {
        var c = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane](repeating: UnifiedGraphLane(), count: lanes))
        if subs > 0 {
            c.bassManagement = UnifiedGraphBassManagement(
                lfeLane: lfe, subwoofers: [UnifiedGraphSubwoofer](repeating: UnifiedGraphSubwoofer(), count: subs))
        }
        return c
    }

    private func stages(_ spec: UnifiedGraphSpec, _ kind: n60_stage_kind) -> [UnifiedGraphStageSpec] {
        spec.stages.filter { $0.kind == kind.rawValue }
    }

    private func context(lanes: Int, subs: Int = 0, rate: Double = 48_000) -> SpeakerRoutingContext {
        SpeakerRoutingContext(programLanes: lanes, subwoofers: subs, sampleRate: rate)
    }

    // MARK: Compiler

    func testStereoTwoWayCompiles() throws {
        let routing = SpeakerRoutingTemplate.twoWay.build(
            mains: [.init(lane: 0, name: "Left", endpoints: [ep(0), ep(1)]),
                    .init(lane: 1, name: "Right", endpoints: [ep(2), ep(3)])],
            crossoverHz: [2_000])!
        let config = try SpeakerRoutingCompiler.compile(routing, onto: base(lanes: 2))
        let spec = try config.makeSpec()
        XCTAssertEqual(spec.outputChannels, 6)
        let route = try XCTUnwrap(stages(spec, N60_STAGE_ROUTE).first)
        XCTAssertEqual(route.laneMask, 0b111100)
        XCTAssertEqual(route.params.count, 16 * 4)
        // Destinations ascend: lanes 2, 3 from source 0; lanes 4, 5 from source 1; unused entries are -1 / 0.
        XCTAssertEqual(Array(route.params[0..<4]), [0, 1, -1, 0])
        XCTAssertEqual(route.params[16], 0)
        XCTAssertEqual(route.params[32], 1)
        XCTAssertEqual(route.params[48], 1)
        let xovers = stages(spec, N60_STAGE_XOVER)
        XCTAssertEqual(xovers.map(\.laneA), [2, 3, 4, 5])
        let low = xovers[0].params, high = xovers[1].params
        XCTAssertEqual(low.count, 14)
        XCTAssertEqual(low[0], Float(N60_GRAPH_FILTER_OFF))
        XCTAssertEqual(Array(low[3...5]), [Float(N60_GRAPH_FILTER_LINKWITZ_RILEY), 4, 2_000])
        XCTAssertEqual(Array(high[0...2]), [Float(N60_GRAPH_FILTER_LINKWITZ_RILEY), 4, 2_000])
        XCTAssertEqual(high[3], Float(N60_GRAPH_FILTER_OFF))
        XCTAssertTrue(stages(spec, N60_STAGE_DELAY).isEmpty)
    }

    func testFiveOneThreeWayWithSubCompilesAndAligns() throws {
        // 5.1: lanes 0 L, 1 R, 2 C, 3 LFE, 4 Ls, 5 Rs; one sub lane. Left has a limited tweeter.
        let mains: [SpeakerRoutingTemplate.Main] = [0, 1, 2, 4, 5].enumerated().map { n, lane in
            .init(lane: lane, name: "M\(lane)", endpoints: [ep(UInt32(n * 3)), ep(UInt32(n * 3 + 1)), ep(UInt32(n * 3 + 2))])
        }
        var routing = SpeakerRoutingTemplate.threeWay.build(mains: mains, subs: [ep(15)], crossoverHz: [300, 3_000])!
        routing.speakers[0].ways[2].limiter = RoutingLimiter(ceilingDB: -3, lookAheadMilliseconds: 1)
        routing.speakers[0].ways[0].delayMilliseconds = 1
        let config = try SpeakerRoutingCompiler.compile(routing, onto: base(lanes: 6, subs: 1, lfe: 3))
        XCTAssertEqual(config.channelCount, 6 + 1 + 16)
        let spec = try config.makeSpec()
        XCTAssertEqual(stages(spec, N60_STAGE_XOVER).count, 16)
        XCTAssertEqual(stages(spec, N60_STAGE_PROTECTION).count, 1)
        let protectionLane = 7 + 2
        let latency = try XCTUnwrap(config.routing?.outputs[2].protection?.latencyFrames(sampleRate: 48_000))
        XCTAssertGreaterThan(latency, 0)
        // Every other output lane waits for the limited tweeter; the limited lane waits only for its own delay.
        let delays = stages(spec, N60_STAGE_DELAY)
        XCTAssertNil(delays.first { $0.laneA == UInt32(protectionLane) })
        let lane7 = try XCTUnwrap(delays.first { $0.laneA == 8 })
        XCTAssertEqual(lane7.params[0], Float(latency))
        let delayedWoofer = try XCTUnwrap(delays.first { $0.laneA == 7 })
        XCTAssertEqual(delayedWoofer.params[0], Float(latency) + 48)
        // The sub speaker reads sub lane 6.
        let route = try XCTUnwrap(stages(spec, N60_STAGE_ROUTE).first)
        XCTAssertEqual(route.params[16 * 15], 6)
    }

    func testMainsPlusEightSubsCompiles() throws {
        let routing = SpeakerRoutingTemplate.mainsPlusSub.build(
            mains: [.init(lane: 0, name: "L", endpoints: [ep(0)]), .init(lane: 1, name: "R", endpoints: [ep(1)])],
            subs: (0..<8).map { ep(UInt32(2 + $0)) })!
        let config = try SpeakerRoutingCompiler.compile(routing, onto: base(lanes: 2, subs: 8))
        let spec = try config.makeSpec()
        XCTAssertEqual(spec.outputChannels, 2 + 8 + 10)
        let route = try XCTUnwrap(stages(spec, N60_STAGE_ROUTE).first)
        XCTAssertEqual(route.laneMask.nonzeroBitCount, 10)
        XCTAssertEqual((0..<8).map { route.params[16 * (2 + $0)] }, (0..<8).map { Float(2 + $0) })
    }

    func testMatrixEntriesSumAndSplit() throws {
        var routing = SpeakerRoutingConfiguration(speakers: [
            RoutedSpeaker(source: .program(0), ways: [RoutedWay(endpoint: ep(0))])])
        routing.matrix = [RoutingMatrixEntry(source: .program(1), output: ep(0), gain: 0.5),
                          RoutingMatrixEntry(source: .program(1), output: ep(5), gain: -1)]
        let config = try SpeakerRoutingCompiler.compile(routing, onto: base(lanes: 2))
        let outputs = try XCTUnwrap(config.routing?.outputs)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs[0].entries, [.init(source: 0, gain: 1), .init(source: 1, gain: 0.5)])
        XCTAssertEqual(outputs[1].entries, [.init(source: 1, gain: -1)])
        XCTAssertNil(outputs[1].crossover)
    }

    func testCompileIsDeterministicAndRoutedGraphRendersAtEveryRate() throws {
        for rate in Self.rates {
            let routing = SpeakerRoutingTemplate.twoWay.build(
                mains: [.init(lane: 0, name: "L", endpoints: [ep(0), ep(1)])], crossoverHz: [2_000])!
            let config = try SpeakerRoutingCompiler.compile(routing, onto: base(rate: rate, lanes: 1))
            XCTAssertEqual(config, try SpeakerRoutingCompiler.compile(routing, onto: base(rate: rate, lanes: 1)))
            let host = try UnifiedGraphHost(spec: try config.makeSpec())
            defer { host.release() }
            let block = 512
            let total = Int(rate * 0.3) / block * block
            let tone = (0..<total).map { Float(0.2 * sin(2.0 * .pi * 300.0 * Double($0) / rate)) }
            var out = [[Float]](repeating: [], count: Int(host.outputChannels))
            var position = 0
            while position < total {
                let chunk = [[Float]](repeating: Array(tone[position..<position + block]), count: Int(host.inputChannels))
                let rendered = try host.processOffline(input: chunk, frames: block)
                for lane in 0..<rendered.count { out[lane] += rendered[lane] }
                position += block
            }
            func rms(_ x: [Float]) -> Double {
                let tail = x[(x.count * 3 / 4)...]
                return sqrt(tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count))
            }
            XCTAssertEqual(rms(out[0]), 0, accuracy: 1e-6, "program lane is cleared at \(rate)")
            XCTAssertGreaterThan(rms(out[1]), 0.12, "low way carries 300 Hz at \(rate)")
            XCTAssertLessThan(rms(out[2]), 0.01, "high way rejects 300 Hz at \(rate)")
        }
    }

    // MARK: Validation

    private func validRouting() -> SpeakerRoutingConfiguration {
        SpeakerRoutingTemplate.twoWay.build(
            mains: [.init(lane: 0, name: "L", endpoints: [ep(0), ep(1)])], crossoverHz: [2_000])!
    }

    func testValidationNamesEachError() {
        let ctx = context(lanes: 2)
        XCTAssertTrue(validRouting().validate(in: ctx).isValid)

        XCTAssertEqual(SpeakerRoutingConfiguration().validate(in: ctx).errors, [.noSpeakers])

        var r = validRouting()
        r.speakers[0].ways[1].endpoint = ep(0)
        XCTAssertEqual(r.validate(in: ctx).errors, [.endpointReused(ep(0))])

        r = validRouting()
        r.speakers[0].source = .program(5)
        XCTAssertEqual(r.validate(in: ctx).errors, [.sourceOutOfRange(.program(5))])
        r.speakers[0].source = .sub(0)
        XCTAssertEqual(r.validate(in: ctx).errors, [.sourceOutOfRange(.sub(0))])

        r = validRouting()
        r.speakers[0].ways = []
        XCTAssertEqual(r.validate(in: ctx).errors, [.speakerWayCount(speaker: "L", count: 0)])
        r.speakers[0].ways = (0..<9).map { RoutedWay(name: "w", endpoint: ep(UInt32($0))) }
        XCTAssertEqual(r.validate(in: ctx).errors, [.speakerWayCount(speaker: "L", count: 9)])

        r = validRouting()
        r.speakers[0].ways[0].lowPass?.order = 3        // LR needs an even order
        XCTAssertEqual(r.validate(in: ctx).errors, [.invalidFilter(way: "L Low", reason: "order")])
        r = validRouting()
        r.speakers[0].ways[0].lowPass?.cornerHz = 30_000
        XCTAssertEqual(r.validate(in: ctx).errors, [.invalidFilter(way: "L Low", reason: "corner")])

        r = validRouting()
        r.speakers[0].ways[0].trimDB = 40
        XCTAssertEqual(r.validate(in: ctx).errors, [.invalidTrim(way: "L Low")])
        r = validRouting()
        r.speakers[0].ways[0].delayMilliseconds = -1
        XCTAssertEqual(r.validate(in: ctx).errors, [.invalidDelay(way: "L Low")])
        r = validRouting()
        r.speakers[0].ways[0].eq = [RoutingEQSection](repeating: .init(type: 0, frequencyHz: 100, gainDB: 1, q: 1), count: 17)
        XCTAssertEqual(r.validate(in: ctx).errors, [.invalidEQ(way: "L Low")])
        r = validRouting()
        r.speakers[0].ways[0].limiter = RoutingLimiter(ceilingDB: 3)
        XCTAssertEqual(r.validate(in: ctx).errors, [.invalidLimiter(way: "L Low")])

        r = validRouting()
        r.matrix = [RoutingMatrixEntry(source: .program(0), output: ep(9), gain: 500)]
        XCTAssertEqual(r.validate(in: ctx).errors, [.matrixGainOutOfRange])
        r.matrix = (0..<8).map { _ in RoutingMatrixEntry(source: .program(1), output: ep(0)) }
        XCTAssertEqual(r.validate(in: ctx).errors, [.tooManyEntries(ep(0))])

        let big = SpeakerRoutingConfiguration(speakers: (0..<9).map { s in
            RoutedSpeaker(source: .program(0), ways: (0..<8).map { RoutedWay(endpoint: ep(UInt32(s * 8 + $0))) })
        })
        XCTAssertEqual(big.validate(in: context(lanes: 2)).errors, [.channelCap(lanes: 74)])

        XCTAssertEqual(validRouting().validate(in: context(lanes: 2, rate: 0)).errors, [.invalidSampleRate])
        XCTAssertThrowsError(try SpeakerRoutingCompiler.compile(SpeakerRoutingConfiguration(), onto: base(lanes: 2)))
    }

    func testValidationWarnings() {
        let ctx = context(lanes: 2, subs: 1)
        var r = validRouting()
        r.speakers[0].ways[1].highPass?.cornerHz = 3_000
        XCTAssertTrue(r.validate(in: ctx).warnings.contains(.bandGap(speaker: "L", lowerHz: 2_000, upperHz: 3_000)))
        r.speakers[0].ways[1].highPass?.cornerHz = 1_000
        XCTAssertTrue(r.validate(in: ctx).warnings.contains(.bandOverlap(speaker: "L", lowerHz: 2_000, upperHz: 1_000)))
        r = validRouting()
        r.speakers[0].ways[0].realisation = .fir
        XCTAssertTrue(r.validate(in: ctx).warnings.contains(.firRealisedAsIIR(way: "L Low")))
        XCTAssertTrue(r.validate(in: ctx).warnings.contains(.unroutedSource(.sub(0))))
        XCTAssertTrue(r.validate(in: ctx).isValid)
    }

    // MARK: Persistence

    func testCodableRoundTripAndVersionRejection() throws {
        var routing = validRouting()
        routing.speakers[0].ways[0].eq = [.init(type: 1, frequencyHz: 120, gainDB: -2, q: 0.7)]
        routing.speakers[0].ways[1].limiter = RoutingLimiter()
        routing.matrix = [RoutingMatrixEntry(source: .sub(0), output: ep(7), gain: 0.25)]
        let data = try JSONEncoder().encode(routing)
        XCTAssertEqual(try JSONDecoder().decode(SpeakerRoutingConfiguration.self, from: data), routing)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = SpeakerRoutingConfiguration.currentSchemaVersion + 1
        let future = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(SpeakerRoutingConfiguration.self, from: future))
        object["schemaVersion"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(SpeakerRoutingConfiguration.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testFlagOffSnapshotsAreUnchanged() throws {
        let state = PlaybackSystemState()
        XCTAssertNil(state.speakerRouting)
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertFalse(json.contains("speakerRouting"))
        // A stored profile without the key still decodes, and a graph without routing keeps its spec.
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSystemState.self, from: Data(json.utf8)), state)
        var withRouting = state
        withRouting.speakerRouting = validRouting()
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSystemState.self, from: JSONEncoder().encode(withRouting)), withRouting)
        let plain = base(lanes: 2, subs: 2)
        XCTAssertNil(plain.routing)
        let spec = try plain.makeSpec()
        XCTAssertTrue(stages(spec, N60_STAGE_ROUTE).isEmpty && stages(spec, N60_STAGE_XOVER).isEmpty)
        XCTAssertEqual(spec.outputChannels, 4)
    }
}
