import XCTest
@testable import NotchSixty

/// E19 S9: routed MIMO design maths (design note 10, design side). Speakers are the sources, in-band ways take the treatment
/// delta, plants come from raw way captures through the way chain rendered from the compiled routed graph, and the routed
/// fields of the permit fingerprint change with every audible edit.
@MainActor
final class MIMORoutedTreatmentPlannerTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Fixtures

    private func ep(_ channel: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: "DEV", channelIndex: channel) }
    private func lr(_ order: Int, _ hz: Double) -> CrossoverCore.FilterSpec { .init(family: .linkwitzRiley, order: order, cornerHz: hz) }
    private func way(_ name: String, _ channel: UInt32, high: CrossoverCore.FilterSpec? = nil, low: CrossoverCore.FilterSpec? = nil) -> RoutedWay {
        var w = RoutedWay(endpoint: ep(channel))
        w.name = name
        w.highPass = high
        w.lowPass = low
        return w
    }
    private func speaker(_ name: String, _ source: RoutingSource, _ ways: [RoutedWay]) -> RoutedSpeaker {
        var s = RoutedSpeaker(source: source, ways: ways)
        s.name = name
        return s
    }

    /// Two 2-way mains (LR24 at 2 kHz) and two subs.
    private func twoWayMainsAndSubs() -> SpeakerRoutingConfiguration {
        SpeakerRoutingConfiguration(speakers: [
            speaker("Left", .program(0), [way("L woofer", 0, low: lr(4, 2_000)), way("L tweeter", 1, high: lr(4, 2_000))]),
            speaker("Right", .program(1), [way("R woofer", 2, low: lr(4, 2_000)), way("R tweeter", 3, high: lr(4, 2_000))]),
            speaker("Sub 1", .sub(0), [way("Sub 1", 4)]),
            speaker("Sub 2", .sub(1), [way("Sub 2", 5)]),
        ])
    }

    private let seats = [MultichannelCalibrationSeat(name: "Seat 1"), MultichannelCalibrationSeat(name: "Seat 2")]

    /// A raw capture: direct arrival plus two decaying modes when `modes`, or the arrival alone.
    private func rawIR(rate: Double, seed: Int, modes: Bool, seconds: Double = 1.2) -> [Float] {
        let length = Int(rate * seconds)
        var ir = [Float](repeating: 0, count: length)
        ir[Int(rate * (0.002 + 0.0003 * Double(seed % 5)))] = 1
        guard modes else { return ir }
        let alpha = 6.907755 / (0.8 * rate)
        for (index, hz) in [40.0, 70.0].enumerated() {
            let gain = 0.02 * (1 + 0.3 * Double((seed + index) % 3))
            let phase = 0.7 * Double(seed + index)
            for n in 0..<length {
                ir[n] += Float(gain * exp(-alpha * Double(n)) * sin(2 * Double.pi * hz * Double(n) / rate + phase))
            }
        }
        return ir
    }

    private func captures(
        _ routing: SpeakerRoutingConfiguration, rate: Double, skip: (RoutedSpeaker, RoutedWay, Int) -> Bool = { _, _, _ in false }
    ) -> [MIMORoutedWayCapture] {
        var out: [MIMORoutedWayCapture] = []
        for (si, speaker) in routing.speakers.enumerated() {
            for (wi, way) in speaker.ways.enumerated() {
                let bass = (way.highPass?.cornerHz ?? 0) < 400
                for (ki, seat) in seats.enumerated() where !skip(speaker, way, ki) {
                    out.append(MIMORoutedWayCapture(
                        speakerID: speaker.id, wayID: way.id, seatID: seat.id, sampleRate: rate,
                        impulseResponse: rawIR(rate: rate, seed: si * 3 + wi + ki, modes: bass)))
                }
            }
        }
        return out
    }

    private func plan(
        _ routing: SpeakerRoutingConfiguration, rate: Double, captures: [MIMORoutedWayCapture]? = nil,
        settings: MIMORoutedTreatmentSettings = .init()
    ) async throws -> MIMORoutedTreatmentPlan {
        var settings = settings
        settings.tauSeconds = 0.02
        settings.taps = Int(try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: rate).lowRateHz)
        let subs = routing.speakers.filter { $0.source.kind == .sub }.count
        return try await MIMORoutedTreatmentPlanner.plan(
            routing: routing, sampleRate: rate, programLanes: 2, subwoofers: subs, seats: seats,
            captures: captures ?? self.captures(routing, rate: rate), settings: settings)
    }

    private var loose: MIMOTreatmentRealisationLimits {
        var limits = MIMOTreatmentRealisationLimits.standard
        limits.maximumDeviationDB = 6
        return limits
    }

    private func naiveConvolve(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = [Double](repeating: 0, count: a.count + b.count - 1)
        for (i, x) in a.enumerated() where x != 0 { for (j, y) in b.enumerated() { out[i + j] += Double(x) * Double(y) } }
        return out.map(Float.init)
    }

    private func errorDB(_ a: [Float], _ reference: [Float]) -> Double {
        let n = max(a.count, reference.count)
        var err = 0.0, peak = 0.0
        for i in 0..<n {
            let x = i < a.count ? Double(a[i]) : 0, r = i < reference.count ? Double(reference[i]) : 0
            err = max(err, abs(x - r))
            peak = max(peak, abs(r))
        }
        return 20 * log10(max(err, 1e-30) / max(peak, 1e-30))
    }

    // MARK: Equivalence with the unrouted design

    func testOneUnfilteredWayPerSpeakerGivesTheUnroutedDesignAtEveryRate() async throws {
        let routing = SpeakerRoutingConfiguration(speakers: [
            speaker("Left", .program(0), [way("Left", 0)]), speaker("Right", .program(1), [way("Right", 1)]),
        ])
        for rate in rates {
            let planned = try await plan(routing, rate: rate)
            XCTAssertEqual(planned.sourceLanes, [0, 1])
            XCTAssertEqual(planned.inBandWaysPerSpeaker, 1)
            // The same request built the unrouted way, from the raw captures.
            let raw = captures(routing, rate: rate)
            var unrouted = planned.request
            unrouted.plants = routing.speakers.map { speaker in
                seats.map { seat in
                    MIMOTreatmentPlant(
                        program: raw.first { $0.speakerID == speaker.id && $0.seatID == seat.id }!.impulseResponse,
                        injection: nil, arrivalSeconds: nil)
                }
            }
            for (s, row) in planned.request.plants.enumerated() {
                for (m, plant) in row.enumerated() {
                    XCTAssertEqual(plant?.program, unrouted.plants[s][m]?.program, "rate \(rate): plant is the raw capture")
                    XCTAssertNil(plant?.injection)
                }
            }
            // The equivalence is about plants, not budgets: lift the default 2.5 dB headroom cap on both designs.
            var routedRequest = planned.request
            for index in routedRequest.sources.indices { routedRequest.sources[index].gainLimitDB = 9 }
            unrouted.sources = routedRequest.sources
            let routed = try MIMORoomTreatmentCoreDesigner.designUnchecked(routedRequest, limits: loose)
            let direct = try MIMORoomTreatmentCoreDesigner.designUnchecked(unrouted, limits: loose)
            XCTAssertEqual(routed.filters.taps, direct.filters.taps, "rate \(rate)")
            XCTAssertEqual(routed.summary.peakGainDB, direct.summary.peakGainDB, "rate \(rate)")
        }
    }

    // MARK: Which ways take the delta

    func testOnlyWooferWaysAreInBandForTwoWayMainsAndSubs() async throws {
        let routing = twoWayMainsAndSubs()
        for rate in rates {
            let planned = try await plan(routing, rate: rate)
            XCTAssertEqual(planned.sourceLanes, [0, 1, 2, 3], "rate \(rate): program lanes then sub lanes")
            XCTAssertEqual(planned.speakers.map(\.inBandWayNames), [["L woofer"], ["R woofer"], ["Sub 1"], ["Sub 2"]], "rate \(rate)")
            XCTAssertEqual(planned.inBandWaysPerSpeaker, 1)
            // The tweeter is in the program plant and not in the injection plant.
            let left = try XCTUnwrap(planned.request.plants[0][0])
            let injection = try XCTUnwrap(left.injection)
            XCTAssertNotEqual(left.program, injection, "rate \(rate)")
            XCTAssertNil(planned.request.plants[2][0]?.injection, "a sub has no out-of-band way")
            XCTAssertEqual(planned.request.sources.map(\.excluded), [false, false, false, false])
        }
    }

    func testTriAmpMainsOnlyWoofersTakeTheDeltaAndPredictedWaysNeedNoCapture() async throws {
        let rate = 48_000.0
        let mains = speaker("Tri", .program(0), [
            way("woofer", 0, low: lr(8, 500)), way("mid", 1, high: lr(8, 500), low: lr(4, 3_000)), way("tweeter", 2, high: lr(4, 3_000)),
        ])
        let routing = SpeakerRoutingConfiguration(speakers: [
            mains, speaker("Sub", .sub(0), [way("Sub", 3)]),
        ])
        let all = captures(routing, rate: rate)
        // Only the woofer and the sub are captured: the mid (500 Hz LR8) and tweeter are predicted from their chains.
        let wanted = all.filter { $0.wayID == mains.ways[0].id || $0.speakerID == routing.speakers[1].id }
        let planned = try await MIMORoutedTreatmentPlanner.plan(
            routing: routing, sampleRate: rate, programLanes: 1, subwoofers: 1, seats: seats, captures: wanted,
            settings: { var s = MIMORoutedTreatmentSettings(); s.taps = 2_000; return s }())
        XCTAssertEqual(planned.speakers[0].inBandWayNames, ["woofer"])
        let injection = try XCTUnwrap(planned.request.plants[0][0]).injection ?? []
        XCTAssertNil(planned.request.plants[0][0]?.injection, "predicted ways add nothing to the program plant, so both plants agree")
        XCTAssertTrue(injection.isEmpty)
    }

    func testTwoAndAHalfWayDeltaGoesToBothWoofersAndPlantIsTheSum() async throws {
        let rate = 48_000.0
        let routing = SpeakerRoutingConfiguration(speakers: [
            speaker("Left", .program(0), [
                way("woofer A", 0, low: lr(4, 1_500)), way("woofer B", 1, low: lr(4, 300)), way("tweeter", 2, high: lr(4, 1_500)),
            ]),
        ])
        var short = [MIMORoutedWayCapture]()
        for way in routing.speakers[0].ways {
            for (ki, seat) in seats.enumerated() {
                short.append(MIMORoutedWayCapture(
                    speakerID: routing.speakers[0].id, wayID: way.id, seatID: seat.id, sampleRate: rate,
                    impulseResponse: rawIR(rate: rate, seed: ki + way.endpoint.channelIndex.hashValue % 3, modes: way.highPass == nil, seconds: 0.05)))
            }
        }
        let planned = try await MIMORoutedTreatmentPlanner.plan(
            routing: routing, sampleRate: rate, programLanes: 1, subwoofers: 0, seats: seats, captures: short,
            settings: { var s = MIMORoutedTreatmentSettings(); s.taps = 2_000; return s }())
        XCTAssertEqual(planned.speakers[0].inBandWayNames, ["woofer A", "woofer B"])
        XCTAssertEqual(planned.inBandWaysPerSpeaker, 2)
        let chains = try MIMORoutedTreatmentPlanner.renderChains(of: routing.speakers[0], name: "Left", sampleRate: rate, offsetFrames: 0)
        for (ki, seat) in seats.enumerated() {
            func raw(_ index: Int) -> [Float] { short.first { $0.wayID == routing.speakers[0].ways[index].id && $0.seatID == seat.id }!.impulseResponse }
            func product(_ index: Int) -> [Float] { naiveConvolve(raw(index), chains[routing.speakers[0].ways[index].id]!) }
            let a = product(0), b = product(1), t = product(2)
            func add(_ x: [Float], _ y: [Float]) -> [Float] {
                (0..<max(x.count, y.count)).map { ($0 < x.count ? x[$0] : 0) + ($0 < y.count ? y[$0] : 0) }
            }
            let plant = try XCTUnwrap(planned.request.plants[0][ki])
            XCTAssertLessThan(errorDB(try XCTUnwrap(plant.injection), add(a, b)), -100, "injection plant is the sum over both woofers (seat \(ki))")
            XCTAssertLessThan(errorDB(plant.program, add(add(a, b), t)), -100, "program plant adds the tweeter (seat \(ki))")
        }
    }

    // MARK: Plants match a rendered routed graph

    func testProgramPlantMatchesARenderedRoutedGraphAtEveryRate() async throws {
        for rate in rates {
            var woofer = way("woofer", 0, low: lr(4, 2_000))
            woofer.trimDB = -2
            woofer.polarityInverted = true
            woofer.delayMilliseconds = 0.25
            let tweeter = way("tweeter", 1, high: lr(4, 2_000))
            let routing = SpeakerRoutingConfiguration(speakers: [
                speaker("Left", .program(0), [woofer, tweeter]),
                speaker("Right", .program(1), [way("Right", 2)]),
            ])
            let short = captures(routing, rate: rate).map { c -> MIMORoutedWayCapture in
                var c = c
                c.impulseResponse = Array(c.impulseResponse.prefix(Int(rate * 0.06)))
                return c
            }
            let planned = try await MIMORoutedTreatmentPlanner.plan(
                routing: routing, sampleRate: rate, programLanes: 2, subwoofers: 0, seats: seats, captures: short,
                settings: { var s = MIMORoutedTreatmentSettings(); s.taps = 2_000; return s }())
            // Render each way's raw capture through the real compiled routed graph and sum the way outputs.
            let config = try SpeakerRoutingCompiler.compile(
                routing, onto: UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()]))
            let endpoints = routing.outputEndpoints
            let plant = try XCTUnwrap(planned.request.plants[0][0])
            let block = 512
            var rendered = [Float](repeating: 0, count: plant.program.count)
            for way in routing.speakers[0].ways {
                let raw = short.first { $0.wayID == way.id && $0.seatID == seats[0].id }!.impulseResponse.map { $0 * 0.1 }
                let host = try UnifiedGraphHost(spec: try config.makeSpec())
                defer { host.release() }
                let lane = 2 + (endpoints.firstIndex(of: way.endpoint) ?? 0)
                var position = 0
                while position < rendered.count {
                    var chunk = [Float](repeating: 0, count: block)
                    for n in 0..<block where position + n < raw.count { chunk[n] = raw[position + n] }
                    var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: Int(host.inputChannels))
                    input[0] = chunk
                    let out = try host.processOffline(input: input, frames: block)
                    for n in 0..<block where position + n < rendered.count { rendered[position + n] += out[lane][n] * 10 }
                    position += block
                }
            }
            XCTAssertLessThan(errorDB(plant.program, rendered), -100, "rate \(rate)")
        }
    }

    // MARK: Refusals by name

    func testMissingInBandCaptureIsRefusedByNameAndQuietWaysNeedNone() async throws {
        let rate = 48_000.0
        let routing = twoWayMainsAndSubs()
        // The left woofer is missing at seat 2.
        let gap = captures(routing, rate: rate) { speaker, way, seat in way.name == "L woofer" && seat == 1 }
        do {
            _ = try await plan(routing, rate: rate, captures: gap)
            XCTFail("expected a refusal")
        } catch let error as MIMORoutedTreatmentRefusal {
            XCTAssertEqual(error, .missingWayCapture(speaker: "Left", way: "L woofer", seat: "Seat 2"))
            XCTAssertTrue((error.errorDescription ?? "").contains("L woofer"))
        }
        // A tweeter with a 2 kHz high-pass is out of band and 40 dB down below 200 Hz only when it is steep: LR4 at 2 kHz is
        // 24 dB/octave, 3.3 octaves down at 200 Hz is far below -40 dB, but the rule needs a high-pass of at least 400 Hz.
        let noTweeter = captures(routing, rate: rate) { speaker, way, _ in way.name.hasSuffix("tweeter") }
        let planned = try await plan(routing, rate: rate, captures: noTweeter)
        XCTAssertEqual(planned.speakers[0].inBandWayNames, ["L woofer"])
        // A way with only a 160 Hz high-pass is out of band yet not 40 dB down: its capture is required.
        let mid = speaker("Left", .program(0), [way("woofer", 0, low: lr(4, 160)), way("mid", 1, high: lr(4, 160))])
        let midRouting = SpeakerRoutingConfiguration(speakers: [mid])
        let missing = captures(midRouting, rate: rate) { _, way, _ in way.name == "mid" }
        do {
            _ = try await MIMORoutedTreatmentPlanner.plan(
                routing: midRouting, sampleRate: rate, programLanes: 1, subwoofers: 0, seats: seats, captures: missing)
            XCTFail("expected a refusal")
        } catch let error as MIMORoutedTreatmentRefusal {
            XCTAssertEqual(error, .missingWayCapture(speaker: "Left", way: "mid", seat: "Seat 1"))
        }
    }

    func testSharedSourceAndNoInBandWayAreRefusedByName() async throws {
        let rate = 48_000.0
        let shared = SpeakerRoutingConfiguration(speakers: [
            speaker("A", .program(0), [way("a", 0)]), speaker("B", .program(0), [way("b", 1)]),
        ])
        do {
            _ = try await plan(shared, rate: rate)
            XCTFail("expected a refusal")
        } catch let error as MIMORoutedTreatmentRefusal {
            XCTAssertEqual(error, .sourceShared(first: "A", second: "B"))
        }
        let highOnly = SpeakerRoutingConfiguration(speakers: [speaker("Horn", .program(0), [way("horn", 0, high: lr(4, 1_000))])])
        do {
            _ = try await plan(highOnly, rate: rate)
            XCTFail("expected a refusal")
        } catch let error as MIMORoutedTreatmentRefusal {
            XCTAssertEqual(error, .noInBandWay(speaker: "Horn"))
        }
        var excludedSettings = MIMORoutedTreatmentSettings()
        excludedSettings.excluded = [highOnly.speakers[0].id]
        let planned = try await plan(highOnly, rate: rate, settings: excludedSettings)
        XCTAssertEqual(planned.request.sources.map(\.excluded), [true], "an excluded speaker plays its own program only")
    }

    // MARK: Headroom and excursion

    func testWayHeadroomBudgetAndExcursionCorner() async throws {
        let rate = 48_000.0
        var woofer = way("woofer", 0, low: lr(4, 2_000))
        woofer.limiter = RoutingLimiter(ceilingDB: -1)
        let routing = SpeakerRoutingConfiguration(speakers: [
            speaker("Left", .program(0), [woofer, way("tweeter", 1, high: lr(4, 2_000))]),
        ])
        // A woofer that rolls off below 60 Hz (second order): -10 dB at about 35 Hz.
        let shaped = captures(routing, rate: rate).map { c -> MIMORoutedWayCapture in
            var c = c
            if c.wayID == woofer.id { c.impulseResponse = highPass(rawIR(rate: rate, seed: 0, modes: false), hz: 60, rate: rate) }
            return c
        }
        let planned = try await MIMORoutedTreatmentPlanner.plan(
            routing: routing, sampleRate: rate, programLanes: 1, subwoofers: 0, seats: seats, captures: shaped,
            settings: { var s = MIMORoutedTreatmentSettings(); s.taps = 2_000; return s }())
        let info = planned.speakers[0]
        // Ceiling -1 dBFS plus the 3 dB trim allowance, chain gain about 0 dB in band: about 1.5 dB (via n60_headroom_mimo_budget_db).
        XCTAssertEqual(info.gainLimitDB, n60_headroom_mimo_budget_db(-1, N60_HEADROOM_MIMO_TRIM_ALLOWANCE_DB, 0), accuracy: 0.3)
        XCTAssertEqual(planned.request.sources[0].gainLimitDB, info.gainLimitDB)
        XCTAssertEqual(info.excursionCornerHz, 35, accuracy: 4, "the measured -10 dB point sets the excursion corner")
        XCTAssertGreaterThanOrEqual(info.supportLowHz, 31, "support starts at the -10 dB point")
        XCTAssertEqual(planned.request.sources[0].excursionCornerHz, info.excursionCornerHz)
        // A woofer trimmed up 8 dB under a -1 dBFS limiter has no room: refused by name.
        var hot = woofer
        hot.trimDB = 8
        let hotRouting = SpeakerRoutingConfiguration(speakers: [speaker("Left", .program(0), [hot])])
        do {
            _ = try await MIMORoutedTreatmentPlanner.plan(
                routing: hotRouting, sampleRate: rate, programLanes: 1, subwoofers: 0, seats: seats,
                captures: captures(hotRouting, rate: rate), settings: { var s = MIMORoutedTreatmentSettings(); s.taps = 2_000; return s }())
            XCTFail("expected a headroom refusal")
        } catch let error as MIMORoutedTreatmentRefusal {
            guard case .headroom(let name, let wayName, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "Left")
            XCTAssertEqual(wayName, "woofer")
        }
    }

    private func highPass(_ x: [Float], hz: Double, rate: Double) -> [Float] {
        let w = 2 * Double.pi * hz / rate, q = 0.70710678
        let alpha = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + alpha
        let b0 = (1 + c) / 2 / a0, b1 = -(1 + c) / a0, b2 = (1 + c) / 2 / a0, a1 = -2 * c / a0, a2 = (1 - alpha) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        return x.map { sample in
            let v = Double(sample)
            let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = y
            return Float(y)
        }
    }

    // MARK: Decay

    /// The synthetic room reaches 5 to 29 percent at 40 Hz (design is regularised and budgeted); the test checks the routed
    /// plants drive a design that shortens the decay at every seat and rate, not a target figure (real-room target: E22).
    func testT30AtFortyHertzFallsAtEveryIncludedSeat() async throws {
        let routing = twoWayMainsAndSubs()
        for rate in rates {
            var settings = MIMORoutedTreatmentSettings()
            settings.decaySeconds = 0.3
            let planned = try await plan(routing, rate: rate, settings: settings)
            var request = planned.request
            for index in request.sources.indices { request.sources[index].gainLimitDB = 9 }
            let result = try MIMORoomTreatmentCoreDesigner.designUnchecked(request, limits: loose)
            let filters = result.filters
            let factor = MIMOTreatmentController.analysisFactor(lowRateHz: filters.lowRateHz)
            let tauIndex = Int((filters.tauSeconds * filters.lowRateHz).rounded())
            let sources = filters.sourceCount
            var rowSums: [[Float]] = []
            for s in 0..<sources {
                var f = [Float](repeating: 0, count: filters.tapCount)
                for r in 0..<sources { for t in 0..<filters.tapCount { f[t] += filters.taps[(s * sources + r) * filters.tapCount + t] } }
                rowSums.append(f)
            }
            for seat in 0..<seats.count {
                var plants: [[Float]] = [], taps: [[Float]] = []
                var baseline: [[Float]] = []
                for s in 0..<sources {
                    let plant = try XCTUnwrap(planned.request.plants[s][seat])
                    let program = try MIMOTreatmentController.decimate(plant.program, rate: rate)
                    let injection = try MIMOTreatmentController.decimate(plant.injection ?? plant.program, rate: rate)
                    var delay = [Float](repeating: 0, count: tauIndex + 1)
                    delay[tauIndex] = 1
                    plants += [program, injection]
                    taps += [delay, rowSums[s]]
                    baseline.append(program)
                }
                let after = MIMOTreatmentController.upsample(try MeasurementCore.predictTreatedIR(plants: plants, filters: taps), by: factor)
                let before = MIMOTreatmentController.upsample(MIMOTreatmentController.sum(baseline), by: factor)
                func t30(_ ir: [Float]) throws -> Double {
                    let bands = try MeasurementCore.analyzeDecay(
                        impulseResponse: ir, sampleRate: filters.lowRateHz * Double(factor), bandsPerOctave: 3, minCentreHz: 40, maxCentreHz: 40)
                    return bands.first { $0.t30Seconds > 0 }?.t30Seconds ?? 0
                }
                let reduction = 1 - (try t30(after)) / max(try t30(before), 1e-9)
                XCTAssertGreaterThanOrEqual(reduction, 0.03, "rate \(rate) seat \(seat): 40 Hz T30 falls by \(Int(reduction * 100)) percent")
            }
        }
    }

    // MARK: Fingerprint

    func testEachRoutedFieldChangesTheDigestAndTheFingerprintGate() throws {
        var base = twoWayMainsAndSubs()
        base.matrix = [RoutingMatrixEntry(source: .program(0), output: ep(9), gain: 0.5)]
        base.speakers[0].ways[0].linearisation = RoutedWayLinearisation(
            nearField: CrossoverCore.ResponseCapture(frequenciesHz: [20, 100, 1_000], levelsDB: [-3, 0, 0]))
        let digest = MIMORoutedTreatmentPlanner.digest(of: base)
        var renamed = base
        renamed.speakers[0].name = "Other"
        renamed.speakers[0].ways[0].name = "Other"
        XCTAssertEqual(MIMORoutedTreatmentPlanner.digest(of: renamed), digest, "names are not audible")

        let edits: [(String, (inout SpeakerRoutingConfiguration) -> Void)] = [
            ("ROUTE gain", { $0.matrix[0].gain = 0.6 }),
            ("ROUTE entry", { $0.matrix.append(RoutingMatrixEntry(source: .program(1), output: self.ep(9))) }),
            ("XOVER corner", { $0.speakers[0].ways[0].lowPass = self.lr(4, 2_100) }),
            ("XOVER order", { $0.speakers[0].ways[0].lowPass = self.lr(6, 2_000) }),
            ("DRIVER_FIR source", { $0.speakers[0].ways[0].linearisation?.nearField.levelsDB[0] = -4 }),
            ("realisation", { $0.speakers[0].ways[0].realisation = .fir }),
            ("delay", { $0.speakers[1].ways[0].delayMilliseconds = 0.1 }),
            ("trim", { $0.speakers[1].ways[0].trimDB = -1 }),
            ("polarity", { $0.speakers[1].ways[0].polarityInverted = true }),
            ("limiter", { $0.speakers[1].ways[0].limiter = RoutingLimiter(ceilingDB: -6) }),
            ("endpoint", { $0.speakers[1].ways[0].endpoint = PhysicalOutputEndpoint(deviceUID: "DEV", channelIndex: 7) }),
            ("speaker-to-way map", { $0.speakers[0].ways.swapAt(0, 1) }),
            ("eq", { $0.speakers[1].ways[0].eq = [RoutingEQSection(type: 0, frequencyHz: 50, gainDB: 3, q: 1)] }),
        ]
        var digests: Set<String> = [digest]
        for (name, edit) in edits {
            var changed = base
            edit(&changed)
            let next = MIMORoutedTreatmentPlanner.digest(of: changed)
            XCTAssertNotEqual(next, digest, name)
            digests.insert(next)
        }
        XCTAssertEqual(digests.count, edits.count + 1, "every edit gives its own digest")

        // The permit binds the digest: a permit issued for `digest` fails the gate for any other.
        let flags = FeatureFlags(
            defaults: UserDefaults(suiteName: "MIMORoutedTests.\(UUID().uuidString)") ?? .standard, policy: .launchArgumentOnly,
            arguments: [FeatureFlags.launchArgument, FeatureFlag.mimoTreatment.id])
        let treatment = MIMOGraphTreatment(flags: flags)
        let low = try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: 48_000)
        let stage = try UnifiedGraphMIMOStage(
            filters: MIMOTreatmentFilterSet(
                sampleRate: 48_000, lowRateHz: low.lowRateHz, decimation: low.decimation, sourceCount: 2, tapCount: 16, tauSeconds: 0.015,
                taps: [Float](repeating: 0, count: 64), solved: [], gridLowHz: 0, gridBins: 0), sourceLanes: [0, 1])
        treatment.stage(stage)
        func context(_ routed: String) -> MIMOGraphTreatment.Context {
            MIMOGraphTreatment.Context(
                engineRunning: true, outputDeviceUID: "OUT", sampleRate: 48_000, stageAttached: true, hardLimitPresent: true,
                engineLeaseHeld: true, videoLatencyMode: false, outputTrimsDB: [0, 0], laneCount: 2, routedDigest: routed)
        }
        treatment.setPermit(.init(fingerprint: treatment.currentFingerprint(stage, context(digest))))
        XCTAssertNil(treatment.gateFailure(context(digest)))
        for other in digests where other != digest {
            XCTAssertEqual(treatment.gateFailure(context(other)), .fingerprintMismatch)
        }
        XCTAssertEqual(treatment.gateFailure(context("")), .fingerprintMismatch, "an unrouted context does not match a routed permit")
    }

    func testMatrixOnlyOutputsAreListedNotTreated() async throws {
        var routing = SpeakerRoutingConfiguration(speakers: [speaker("Left", .program(0), [way("Left", 0)])])
        routing.matrix = [RoutingMatrixEntry(source: .program(0), output: ep(5), gain: 1)]
        let planned = try await MIMORoutedTreatmentPlanner.plan(
            routing: routing, sampleRate: 48_000, programLanes: 1, subwoofers: 0, seats: seats,
            captures: captures(routing, rate: 48_000), settings: { var s = MIMORoutedTreatmentSettings(); s.taps = 2_000; return s }())
        XCTAssertEqual(planned.matrixOnlyOutputs, [ep(5)])
        XCTAssertEqual(planned.sourceLanes, [0])
    }

    func testSourceRowShowsInBandWays() throws {
        let routing = twoWayMainsAndSubs()
        let window = MIMORoutedTreatmentPlanner.defaultSupportHz
        let names = MIMORoutedTreatmentPlanner.inBandWays(of: routing.speakers[0], lowHz: window.lowerBound, highHz: window.upperBound).map(\.name)
        XCTAssertEqual(names, ["L woofer"])
        XCTAssertEqual(MIMORoutedTreatmentPlanner.inBandWayCount(of: routing), 1)
        XCTAssertEqual(MIMOTreatmentSourceInfo(source: .speaker(.frontLeft), lane: 0, name: "L", inBandWays: names).inBandWays, names)
    }
}
