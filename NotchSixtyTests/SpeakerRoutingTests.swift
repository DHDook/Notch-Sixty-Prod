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

// MARK: - E8 S4: live wiring

extension SpeakerRoutingTests {
    private func fixtureDevice(_ uid: String, rate: Double, channels: UInt32) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: 77, uid: uid, name: uid, nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)],
            outputChannelCount: channels)
    }

    private var bassOn: BassManagementConfiguration {
        var bass = BassManagementConfiguration()
        bass.enabled = true
        return bass
    }

    private func engineReady(subs: Bool) throws -> AudioIOEngine {
        let engine = AudioIOEngine()
        engine.unifiedGraphEnabled = true
        engine.routingMatrixEnabled = true
        if subs { try engine.replaceBassManagementConfiguration(bassOn) }
        return engine
    }

    /// A running, hardware-free routed session behind the engine's test seam.
    private func routedSession(
        engine: AudioIOEngine, routing: SpeakerRoutingConfiguration, layout: OutputProgramLayout,
        labels: [AudioChannelLabel], rate: Double, channels: UInt32
    ) throws -> (CoreAudioNChannelTransportSession, LiveNChannelOutputRoutePlan, UnifiedGraphHost) {
        try engine.replaceSpeakerRoutingConfiguration(routing)
        let device = fixtureDevice("fixture", rate: rate, channels: channels)
        let plan = try routing.makeLivePlan(
            programLayout: layout, availableDevices: [device], sampleRate: rate,
            selectedOutputUID: "fixture", bassManagementEnabled: routing.subwooferSourceCount > 0)
        let renderGraph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: plan, sampleRate: rate, gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: engine.bassManagementConfiguration)
        let descriptions = labels.map {
            AudioChannelDescription(mChannelLabel: $0, mChannelFlags: [], mCoordinates: (0, 0, 0))
        }
        var inputMap = N60ProgramInputMap()
        XCTAssertTrue(descriptions.withUnsafeBufferPointer {
            N60ProgramInputMapCompile($0.baseAddress!, UInt32($0.count), renderGraph.programLayout, &inputMap)
        })
        let configuration = try engine.makeRoutedGraphConfiguration(
            routing: routing, routePlan: plan, sampleRate: rate, inputs: engine.currentLiveGraphInputs)
        let session = try CoreAudioNChannelTransportSession(
            testingSelectedOutput: device, routePlan: plan, renderGraph: renderGraph, inputMap: inputMap,
            sampleRate: rate, unifiedGraphConfiguration: configuration)
        XCTAssertNil(session.unifiedGraphFallbackReason, "graph fallback")
        try engine.installTestingNChannelSession(session)
        let host = try XCTUnwrap(session.unifiedGraphReadback)
        return (session, plan, host)
    }

    private func sine(_ hz: Double, rate: Double, frames: Int, amplitude: Double = 0.5) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    /// Renders in blocks so the host sees realistic callback sizes; state carries across blocks.
    private func render(_ host: UnifiedGraphHost, input: [[Float]], block: Int = 512) throws -> [[Float]] {
        let frames = input[0].count
        // The host takes every graph lane as input; sub and output lanes start silent.
        var input = input
        while input.count < Int(host.spec.inputChannels) { input.append([Float](repeating: 0, count: frames)) }
        var out = [[Float]](repeating: [], count: Int(host.spec.outputChannels))
        var start = 0
        while start < frames {
            let n = min(block, frames - start)
            let chunk = input.map { Array($0[start..<(start + n)]) }
            let result = try host.processOffline(input: chunk, frames: n)
            for lane in out.indices { out[lane] += result[lane][0..<n] }
            start += n
        }
        return out
    }

    /// Amplitude of a steady sine at `hz` by Hann-windowed single-bin correlation over the tail of `signal`.
    private func amplitude(_ signal: [Float], hz: Double, rate: Double, skip: Int) -> Double {
        let tail = Array(signal[skip...])
        let n = tail.count
        var re = 0.0, im = 0.0, wsum = 0.0
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            let phase = 2 * Double.pi * hz * Double(i + skip) / rate
            re += w * Double(tail[i]) * cos(phase)
            im -= w * Double(tail[i]) * sin(phase)
            wsum += w
        }
        return 2 * (re * re + im * im).squareRoot() / wsum
    }

    // MARK: Plan

    func testLivePlanFlattensDevicesWithSelectedOutputFirst() throws {
        let routing = SpeakerRoutingConfiguration(speakers: [
            RoutedSpeaker(name: "L", source: .program(0), ways: [
                RoutedWay(endpoint: ep(1, device: "dev")), RoutedWay(endpoint: ep(0, device: "other"))]),
            RoutedSpeaker(name: "R", source: .program(1), ways: [
                RoutedWay(endpoint: ep(3, device: "dev"))]),
        ])
        let devices = [fixtureDevice("dev", rate: 48_000, channels: 4), fixtureDevice("other", rate: 48_000, channels: 2)]
        let plan = try routing.makeLivePlan(
            programLayout: .stereo, availableDevices: devices, sampleRate: 48_000, selectedOutputUID: "other",
            bassManagementEnabled: false)
        XCTAssertTrue(plan.isRouted)
        XCTAssertEqual(plan.orderedDeviceUIDs, ["other", "dev"])
        XCTAssertEqual(plan.referenceDeviceUID, "other")
        XCTAssertEqual(plan.physicalChannelCount, 6)
        // "other" occupies physical 0-1, "dev" 2-5; endpoints in first-use order: dev 1, other 0, dev 3.
        XCTAssertEqual(plan.routedOutputPhysicalChannels, [3, 0, 5])

        XCTAssertThrowsError(try routing.makeLivePlan(
            programLayout: .stereo, availableDevices: devices, sampleRate: 48_000, selectedOutputUID: "missing",
            bassManagementEnabled: false))
        let small = [fixtureDevice("dev", rate: 48_000, channels: 3), fixtureDevice("other", rate: 48_000, channels: 2)]
        XCTAssertThrowsError(try routing.makeLivePlan(
            programLayout: .stereo, availableDevices: small, sampleRate: 48_000, selectedOutputUID: "other",
            bassManagementEnabled: false)) {
            XCTAssertEqual($0 as? OutputDeviceProfileError, .outputChannelUnavailable(deviceUID: "dev", channelIndex: 3, channelCount: 3))
        }
        let wide = [fixtureDevice("dev", rate: 48_000, channels: 40), fixtureDevice("other", rate: 48_000, channels: 40)]
        XCTAssertThrowsError(try routing.makeLivePlan(
            programLayout: .stereo, availableDevices: wide, sampleRate: 48_000, selectedOutputUID: "other",
            bassManagementEnabled: false)) {
            XCTAssertEqual($0 as? OutputDeviceProfileError, .physicalChannelCountOverflow)
        }
    }

    // MARK: Live render

    func testThreeWayStereoMatchesCrossoverPredictionAtEveryRate() throws {
        for rate in Self.rates {
            let engine = try engineReady(subs: false)
            let routing = SpeakerRoutingTemplate.threeWay.build(
                mains: [.init(lane: 0, name: "L", endpoints: [ep(0, device: "fixture"), ep(1, device: "fixture"), ep(2, device: "fixture")]),
                        .init(lane: 1, name: "R", endpoints: [ep(3, device: "fixture"), ep(4, device: "fixture"), ep(5, device: "fixture")])],
                crossoverHz: [300, 3_000])!
            let (_, plan, host) = try routedSession(
                engine: engine, routing: routing, layout: .stereo,
                labels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right], rate: rate, channels: 6)
            XCTAssertEqual(plan.routedOutputPhysicalChannels, [0, 1, 2, 3, 4, 5], "rate \(rate)")
            XCTAssertEqual(host.spec.outputChannels, 2 + 6, "rate \(rate)")
            let frames = Int(rate * 0.4)
            let skip = Int(rate * 0.15)
            let ways = routing.speakers[0].ways
            for hz in [150.0, 300, 1_000, 3_000, 6_000] {
                let silent = [Float](repeating: 0, count: frames)
                let out = try render(host, input: [sine(hz, rate: rate, frames: frames), silent])
                for (index, way) in ways.enumerated() {
                    var expected = 0.0
                    if let hp = way.highPass { expected += try CrossoverCore.design(hp, highPass: true, sampleRate: rate).magnitudeDB(atHz: hz) }
                    if let lp = way.lowPass { expected += try CrossoverCore.design(lp, highPass: false, sampleRate: rate).magnitudeDB(atHz: hz) }
                    guard expected > -50 else { continue }
                    let measured = 20 * log10(amplitude(out[2 + index], hz: hz, rate: rate, skip: skip) / 0.5)
                    XCTAssertEqual(measured, expected, accuracy: 0.05, "rate \(rate) hz \(hz) way \(index)")
                }
                // The right speaker has no input: its ways are silent.
                for index in 0..<3 {
                    XCTAssertLessThan(out[5 + index].map(abs).max() ?? 0, 1e-6, "rate \(rate) hz \(hz)")
                }
            }
            engine.removeTestingNChannelSession()
        }
    }

    func testFiveOnePlusEightSubsDrivesEveryPhysicalSub() throws {
        let rate = 48_000.0
        let engine = try engineReady(subs: true)
        let mains: [SpeakerRoutingTemplate.Main] = [0, 1, 2, 4, 5].enumerated().map { n, lane in
            .init(lane: lane, name: "M\(lane)", endpoints: [ep(UInt32(n), device: "fixture")])
        }
        let routing = SpeakerRoutingTemplate.mainsPlusSub.build(
            mains: mains, subs: (0..<8).map { ep(UInt32(5 + $0), device: "fixture") })!
        XCTAssertEqual(routing.subwooferSourceCount, 8)
        let labels: [AudioChannelLabel] = [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        let (_, plan, host) = try routedSession(
            engine: engine, routing: routing, layout: .fiveOne, labels: labels, rate: rate, channels: 13)
        XCTAssertEqual(plan.routedOutputPhysicalChannels, (0..<13).map { UInt32($0) })
        XCTAssertEqual(plan.subwooferCount, 8)
        let frames = 24_000
        var input = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 6)
        input[3] = sine(50, rate: rate, frames: frames)      // LFE
        let out = try render(host, input: input)
        let firstSub = 6 + 8                                  // program lanes, sub lanes, then the five mains
        let levels = (0..<8).map { amplitude(out[firstSub + 5 + $0], hz: 50, rate: rate, skip: 12_000) }
        XCTAssertGreaterThan(levels[0], 0.01)
        for level in levels { XCTAssertEqual(level, levels[0], accuracy: levels[0] * 1e-3) }
        engine.removeTestingNChannelSession()
    }

    func testLiveCrossoverEditIsClickFreeAtEveryRate() throws {
        for rate in Self.rates {
            let engine = try engineReady(subs: false)
            func routing(_ corner: Double) -> SpeakerRoutingConfiguration {
                SpeakerRoutingTemplate.twoWay.build(
                    mains: [.init(lane: 0, name: "L", endpoints: [ep(0, device: "fixture"), ep(1, device: "fixture")]),
                            .init(lane: 1, name: "R", endpoints: [ep(2, device: "fixture"), ep(3, device: "fixture")])],
                    crossoverHz: [corner])!
            }
            let before = routing(2_000), after = routing(2_600)
            let (_, _, host) = try routedSession(
                engine: engine, routing: before, layout: .stereo,
                labels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right], rate: rate, channels: 4)
            let hz = 1_000.0
            let total = Int(rate * 0.5)
            let tone = sine(hz, rate: rate, frames: total)
            let silent = [Float](repeating: 0, count: total)
            let half = total / 2
            let settle = Int(rate * 0.1)
            let first = try render(host, input: [Array(tone[0..<half]), Array(silent[0..<half])])
            try engine.replaceSpeakerRoutingConfiguration(after)
            XCTAssertEqual(engine.speakerRoutingConfiguration, after, "rate \(rate)")
            let second = try render(host, input: [Array(tone[half...]), Array(silent[half...])])
            func maxStep(_ s: ArraySlice<Float>) -> Float { zip(s, s.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }
            let lane = 2 + 0                                  // L low way
            let baseline = maxStep(first[lane][settle...])
            let across = maxStep(Array(first[lane].suffix(256)) + Array(second[lane].prefix(Int(rate * 0.1)))[...])
            XCTAssertGreaterThan(baseline, 0, "rate \(rate)")
            XCTAssertLessThanOrEqual(across, baseline * 2, "rate \(rate)")
            engine.removeTestingNChannelSession()
        }
    }

    // MARK: Refusals

    func testRoutingRefusalsNameTheReasonAndKeepState() throws {
        let routing = SpeakerRoutingTemplate.mainsPlusSub.build(
            mains: [.init(lane: 0, name: "L", endpoints: [ep(0)]), .init(lane: 1, name: "R", endpoints: [ep(1)])])!
        var disabled = routing
        disabled.enabled = false

        // Flag off: an active routing is refused; nil and a disabled routing are accepted and stereo is untouched.
        let off = AudioIOEngine()
        off.unifiedGraphEnabled = true
        XCTAssertFalse(off.routingMatrixEnabled)
        XCTAssertThrowsError(try off.replaceSpeakerRoutingConfiguration(routing)) {
            guard case LiveNChannelTransportError.routingRefused(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("switched off"))
        }
        XCTAssertNil(off.speakerRoutingConfiguration)
        XCTAssertNoThrow(try off.replaceSpeakerRoutingConfiguration(nil))
        XCTAssertNoThrow(try off.replaceSpeakerRoutingConfiguration(disabled))
        XCTAssertEqual(off.speakerRoutingConfiguration, disabled)

        // Legacy kernel selected.
        let legacy = AudioIOEngine()
        legacy.routingMatrixEnabled = true
        legacy.unifiedGraphEnabled = false
        XCTAssertThrowsError(try legacy.replaceSpeakerRoutingConfiguration(routing)) {
            guard case LiveNChannelTransportError.routingRefused(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("legacy render kernel"))
        }
        XCTAssertNil(legacy.speakerRoutingConfiguration)

        // Sub sources need bass management, and bass management needs sub sources.
        let engine = try engineReady(subs: false)
        let withSub = SpeakerRoutingTemplate.mainsPlusSub.build(
            mains: [.init(lane: 0, name: "L", endpoints: [ep(0)]), .init(lane: 1, name: "R", endpoints: [ep(1)])],
            subs: [ep(2)])!
        XCTAssertThrowsError(try engine.replaceSpeakerRoutingConfiguration(withSub)) {
            guard case LiveNChannelTransportError.routingRefused(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("bass management must be on"))
        }
        XCTAssertNil(engine.speakerRoutingConfiguration)
        try engine.replaceBassManagementConfiguration(bassOn)
        XCTAssertThrowsError(try engine.replaceSpeakerRoutingConfiguration(routing)) {
            guard case LiveNChannelTransportError.routingRefused(let reason) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("no speaker reads a subwoofer"))
        }
        XCTAssertNil(engine.speakerRoutingConfiguration)
        XCTAssertNoThrow(try engine.replaceSpeakerRoutingConfiguration(withSub))
        XCTAssertEqual(engine.speakerRoutingConfiguration, withSub)
    }
}
