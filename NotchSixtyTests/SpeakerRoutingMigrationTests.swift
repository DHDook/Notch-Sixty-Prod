import XCTest
@testable import NotchSixty

/// E8 S5: the legacy physical crossover migrates to a routing that renders the same audio, the protected-excitation guard
/// band holds, and the migration is pure, deterministic and idempotent.
@MainActor
final class SpeakerRoutingMigrationTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private static let frames = 6_144   // 12 blocks of 512
    private static let delayFrames = 24

    // MARK: Fixtures

    private func routes(_ buses: [SpeakerOutputBus]) -> MultiOutputRoutingConfiguration {
        MultiOutputRoutingConfiguration(
            enabled: true,
            routes: buses.enumerated().map { index, bus in
                SpeakerOutputRoute(
                    name: bus.displayName, bus: bus,
                    destination: PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: UInt32(index)))
            })
    }

    private func buses(for mode: SpeakerCrossoverMode) -> [SpeakerOutputBus] {
        switch mode {
        case .mainsSub: return [.leftHigh, .rightHigh, .subMono]
        case .biAmp: return [.leftLow, .rightLow, .leftHigh, .rightHigh]
        case .triAmp: return [.leftLow, .rightLow, .leftMid, .rightMid, .leftHigh, .rightHigh]
        }
    }

    private func bass(_ mode: SpeakerCrossoverMode, _ topology: CrossoverTopology) -> BassManagementConfiguration {
        var b = BassManagementConfiguration()
        b.enabled = true
        b.physicalOutputMode = mode
        b.topology = topology
        b.upperTopology = topology
        b.frequencyHz = mode == .mainsSub ? 80 : 400
        b.upperFrequencyHz = mode == .triAmp ? 3_000 : nil
        return b
    }

    private func driver(
        _ bus: SpeakerOutputBus, index: Int, rate: Double, limiter: Double? = nil
    ) -> SpeakerDriverBusProcessingConfiguration {
        SpeakerDriverBusProcessingConfiguration(
            bus: bus, enabled: true,
            eqBands: [
                EQBand(type: .peaking, frequencyHz: 2_000, gainDB: 3, q: 1.0),
                EQBand(type: .highShelf, frequencyHz: 8_000, gainDB: -2, q: 0.707),
            ],
            trimDB: index % 2 == 0 ? -3 : 1.5,
            polarityInverted: index % 3 == 0,
            // Whole frames, nudged off the float rounding edge (23.999999 would split as 23 + 1.0).
            delayMilliseconds: (Double(Self.delayFrames) + 1.0e-9) / rate * 1_000,
            limiterEnabled: limiter != nil,
            limiterThresholdDBFS: limiter ?? -3)
    }

    private func drivers(
        for buses: [SpeakerOutputBus], rate: Double, limiter: Double?
    ) -> SpeakerDriverProcessingConfiguration {
        SpeakerDriverProcessingConfiguration(
            buses: buses.enumerated().filter { $0.element != .subMono }
                .map { driver($0.element, index: $0.offset, rate: rate, limiter: limiter) })
    }

    /// Deterministic stereo programme: a handful of tones per channel spanning every band.
    private func programme(scale: Float) -> (left: [Float], right: [Float]) {
        let toneHz: [Double] = [60, 300, 1_000, 5_000, 9_000]
        func tones(_ phase: Double, _ rate: Double) -> [Float] {
            (0..<Self.frames).map { n in
                var v = 0.0
                for (k, hz) in toneHz.enumerated() {
                    v += 0.08 * sin(2 * Double.pi * hz * Double(n) / rate + phase + Double(k))
                }
                return Float(v) * scale
            }
        }
        return (tones(0.3, 48_000), tones(1.1, 48_000))
    }

    private func render(
        _ routing: SpeakerRoutingConfiguration, rate: Double, left: [Float], right: [Float]
    ) throws -> [PhysicalOutputEndpoint: [Float]] {
        let base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        let config = try SpeakerRoutingCompiler.compile(routing, onto: base)
        let host = try UnifiedGraphHost(spec: try config.makeSpec())
        defer { host.release() }
        var outputs = [[Float]](repeating: [], count: Int(host.outputChannels))
        var position = 0
        while position < left.count {
            let end = min(position + 512, left.count)
            var planar = [Array(left[position..<end]), Array(right[position..<end])]
            while planar.count < Int(host.inputChannels) { planar.append([Float](repeating: 0, count: end - position)) }
            let result = try host.processOffline(input: planar, frames: end - position)
            for channel in outputs.indices { outputs[channel] += result[channel][0..<(end - position)] }
            position = end
        }
        var map: [PhysicalOutputEndpoint: [Float]] = [:]
        for (index, endpoint) in routing.outputEndpoints.enumerated() { map[endpoint] = outputs[2 + index] }
        return map
    }

    private func oracle(
        input: [Float], bus: SpeakerOutputBus, bass: BassManagementConfiguration,
        driver: SpeakerDriverProcessingConfiguration, rate: Double
    ) throws -> [Float] {
        let splitter = try bass.makeSpeakerBusSplitterSnapshot(sampleRate: rate)
        let snapshot = try driver.makeRealtimeSnapshot(sampleRate: rate)
        var out = [Float](repeating: 0, count: input.count)
        let ok = input.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in
                N60ProtectedSpeakerBusRenderProgram(
                    i.baseAddress!, UInt32(i.count), bus.realtimeCType, splitter, snapshot, o.baseAddress!)
            }
        }
        XCTAssertTrue(ok, "oracle render failed for \(bus)")
        return out
    }

    private func peak(_ a: [Float], _ b: [Float]) -> Double {
        zip(a, b).reduce(0.0) { max($0, Double(abs($1.0 - $1.1))) }
    }

    private func dbfs(_ x: Double) -> Double { 20 * log10(max(x, 1.0e-12)) }

    private func peakOf(_ a: [Float], from: Int = 0) -> Double {
        Double(a[from...].reduce(Float(0)) { max($0, abs($1)) })
    }

    // MARK: Legacy against migrated

    private func checkLegacyEquivalence(limiter: Double?, scale: Float, toleranceDBFS: Double, gainToleranceDB: Double) throws {
        for rate in Self.rates {
            for mode in SpeakerCrossoverMode.allCases {
                for topology in CrossoverTopology.allCases {
                    let busList = buses(for: mode)
                    let bassConfig = bass(mode, topology)
                    let driverConfig = drivers(for: busList, rate: rate, limiter: limiter)
                    let migrated = SpeakerRoutingMigration.migrate(
                        routing: routes(busList), bassManagement: bassConfig, driverProcessing: driverConfig)
                    XCTAssertNil(migrated.refusal, "\(mode) \(topology) \(rate)")
                    let routing = try XCTUnwrap(migrated.routing)
                    let (l, r) = programme(scale: scale)
                    let rendered = try render(routing, rate: rate, left: l, right: r)

                    // The oracle needs a limiter on the target; a 0 dBFS one is inert for these levels.
                    var oracleDrivers = driverConfig
                    for index in oracleDrivers.buses.indices where !oracleDrivers.buses[index].limiterEnabled {
                        oracleDrivers.buses[index].limiterEnabled = true
                        oracleDrivers.buses[index].limiterThresholdDBFS = 0
                    }
                    let route = routes(busList)
                    for (index, bus) in busList.enumerated() {
                        let endpoint = route.routes[index].destination
                        let got = try XCTUnwrap(rendered[endpoint], "\(bus)")
                        let label = "\(mode) \(topology) \(bus) @\(rate)"
                        switch (mode, bus) {
                        case (.mainsSub, .subMono):
                            // Sub = low-pass of (L + R) / 2, then the sub gain and polarity.
                            var biAmp = bassConfig
                            biAmp.physicalOutputMode = .biAmp
                            biAmp.subGainDB = 0
                            biAmp.subPolarityInverted = false
                            let mono = zip(l, r).map { 0.5 * ($0 + $1) }
                            var lowDriver = SpeakerDriverProcessingConfiguration(buses: [
                                SpeakerDriverBusProcessingConfiguration(
                                    bus: .leftLow, enabled: true, limiterEnabled: true, limiterThresholdDBFS: 0),
                            ])
                            _ = lowDriver.buses
                            lowDriver.buses[0].limiterThresholdDBFS = 0
                            let expected = try oracle(
                                input: mono, bus: .leftLow, bass: biAmp, driver: lowDriver, rate: rate)
                            let gain = Float(pow(10.0, (bassConfig.subGainDB) / 20.0))
                                * (bassConfig.subPolarityInverted ? -1 : 1)
                            XCTAssertLessThan(
                                dbfs(peak(got, expected.map { $0 * gain })), toleranceDBFS, label)
                        case (.mainsSub, _):
                            var biAmp = bassConfig
                            biAmp.physicalOutputMode = .biAmp
                            let isLeft = bus == .leftHigh
                            let expected = try oracle(
                                input: isLeft ? l : r, bus: isLeft ? .leftHigh : .rightHigh, bass: biAmp,
                                driver: oracleDrivers, rate: rate)
                            try compare(got, expected, label: label, limiter: limiter,
                                        toleranceDBFS: toleranceDBFS, gainToleranceDB: gainToleranceDB)
                        default:
                            let isLeft = [SpeakerOutputBus.leftLow, .leftMid, .leftHigh].contains(bus)
                            let expected = try oracle(
                                input: isLeft ? l : r, bus: bus, bass: bassConfig, driver: oracleDrivers, rate: rate)
                            try compare(got, expected, label: label, limiter: limiter,
                                        toleranceDBFS: toleranceDBFS, gainToleranceDB: gainToleranceDB)
                        }
                    }
                }
            }
        }
    }

    private func compare(
        _ got: [Float], _ expected: [Float], label: String, limiter: Double?,
        toleranceDBFS: Double, gainToleranceDB: Double
    ) throws {
        if limiter == nil {
            XCTAssertLessThan(dbfs(peak(got, expected)), toleranceDBFS, label)
        } else {
            // The limiter's gain reduction is judged on the settled second half.
            let half = got.count / 2
            let a = dbfs(peakOf(got, from: half)), b = dbfs(peakOf(expected, from: half))
            XCTAssertEqual(a, b, accuracy: gainToleranceDB, label)
        }
    }

    /// -90 dBFS: both paths are float32 biquad cascades in different arrangements; the residue peaks near -96 dBFS at 352.8 kHz.
    func testMigratedRenderMatchesLegacyWithoutLimiter() throws {
        try checkLegacyEquivalence(limiter: nil, scale: 1, toleranceDBFS: -90, gainToleranceDB: 0.5)
    }

    func testMigratedRenderMatchesLegacyLimiterGainReduction() throws {
        try checkLegacyEquivalence(limiter: -12, scale: 1.5, toleranceDBFS: -100, gainToleranceDB: 0.5)
    }

    // MARK: Guard band

    func testTriAmpWaysKeepTheProtectedGuardBand() throws {
        for rate in Self.rates {
            let busList = buses(for: .triAmp)
            let result = SpeakerRoutingMigration.migrate(
                routing: routes(busList), bassManagement: bass(.triAmp, .linkwitzRiley24),
                driverProcessing: drivers(for: busList, rate: rate, limiter: -6))
            let left = try XCTUnwrap(result.routing?.speakers.first)
            XCTAssertEqual(left.ways.count, 3)
            let low = left.ways[0], mid = left.ways[1], high = left.ways[2]
            let lowBand = try XCTUnwrap(low.protectedPassband(sampleRate: rate))
            XCTAssertLessThanOrEqual(lowBand.upperBound, 400 / 1.5 + 1.0e-9)
            let midBand = try XCTUnwrap(mid.protectedPassband(sampleRate: rate))
            XCTAssertGreaterThanOrEqual(midBand.lowerBound, 400 * 1.5 - 1.0e-9)
            XCTAssertLessThanOrEqual(midBand.upperBound, 3_000 / 1.5 + 1.0e-9)
            // The tweeter's upper high-pass lives in its EQ and still counts.
            XCTAssertEqual(try XCTUnwrap(high.effectiveHighPassHz), 3_000, accuracy: 1.0e-9)
            let highBand = try XCTUnwrap(high.protectedPassband(sampleRate: rate))
            XCTAssertGreaterThanOrEqual(highBand.lowerBound, 3_000 * 1.5 - 1.0e-9)
            XCTAssertEqual(left.adjacentWayPairs.count, 2)
        }
    }

    func testNarrowWayHasNoProtectedPassband() {
        var way = RoutedWay(endpoint: PhysicalOutputEndpoint(deviceUID: "d", channelIndex: 0))
        way.highPass = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 1_000)
        way.lowPass = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 2_000)
        XCTAssertNil(way.protectedPassband(sampleRate: 48_000))
    }

    // MARK: Protected excitation

    func testProtectedExcitationRendersOnlyTheWayAndRefusesUnsafeInput() throws {
        let rate = 48_000.0
        let busList = buses(for: .triAmp)
        let result = SpeakerRoutingMigration.migrate(
            routing: routes(busList), bassManagement: bass(.triAmp, .linkwitzRiley24),
            driverProcessing: drivers(for: busList, rate: rate, limiter: -6))
        let routing = try XCTUnwrap(result.routing)
        let mid = routing.speakers[0].ways[1]
        func tone(_ hz: Double, _ amplitude: Float) -> [Float] {
            (0..<24_000).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
        }
        let compiler = SpeakerRoutingProtectedExcitationCompiler()
        let inBand = try compiler.compile(
            monoSamples: tone(1_000, 0.03), sampleRate: rate, routing: routing, wayID: mid.id)
        let outBand = try compiler.compile(
            monoSamples: tone(100, 0.03), sampleRate: rate, routing: routing, wayID: mid.id)
        XCTAssertFalse(inBand.canDeploy)
        XCTAssertTrue(inBand.measurementOnly)
        XCTAssertEqual(inBand.way, mid.withEndpoint(inBand.way.endpoint))
        XCTAssertGreaterThan(inBand.renderedPeakDBFS - outBand.renderedPeakDBFS, 20)

        XCTAssertThrowsError(try compiler.compile(
            monoSamples: tone(1_000, 0.5), sampleRate: rate, routing: routing, wayID: mid.id)) {
            guard case SpeakerRoutingProtectedExcitationError.excitationTooHot = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try compiler.compile(
            monoSamples: tone(1_000, 0.03), sampleRate: rate, routing: routing, wayID: UUID())) {
            XCTAssertEqual($0 as? SpeakerRoutingProtectedExcitationError, .wayNotFound)
        }
        // A way without a limiter is never excited.
        var unprotected = routing
        unprotected.speakers[0].ways[1].limiter = nil
        XCTAssertThrowsError(try compiler.compile(
            monoSamples: tone(1_000, 0.03), sampleRate: rate, routing: unprotected, wayID: mid.id)) {
            XCTAssertEqual($0 as? SpeakerRoutingProtectedExcitationError, .wayNotProtected)
        }
        XCTAssertTrue(SpeakerMeasurementLabCapabilityPlanner.protectedWayReady(routing: routing, wayID: mid.id))
        XCTAssertFalse(SpeakerMeasurementLabCapabilityPlanner.protectedWayReady(routing: unprotected, wayID: mid.id))
        XCTAssertFalse(SpeakerMeasurementLabCapabilityPlanner.protectedWayReady(routing: nil, wayID: mid.id))
    }

    func testProtectedExcitationCompilesAtEveryRate() throws {
        for rate in Self.rates {
            let busList = buses(for: .biAmp)
            let result = SpeakerRoutingMigration.migrate(
                routing: routes(busList), bassManagement: bass(.biAmp, .linkwitzRiley48),
                driverProcessing: drivers(for: busList, rate: rate, limiter: -6))
            let routing = try XCTUnwrap(result.routing)
            let high = routing.speakers[0].ways[1]
            let samples = (0..<4_800).map { 0.03 * Float(sin(2 * Double.pi * 3_000 * Double($0) / rate)) }
            let excitation = try SpeakerRoutingProtectedExcitationCompiler().compile(
                monoSamples: samples, sampleRate: rate, routing: routing, wayID: high.id)
            XCTAssertGreaterThan(excitation.renderedSamples.count, samples.count)
        }
    }

    // MARK: Purity

    func testMigrationIsDeterministicAndIdempotent() throws {
        let busList = buses(for: .triAmp)
        var state = PlaybackSystemState()
        state.bassManagement = bass(.triAmp, .linkwitzRiley48)
        state.outputRouting = routes(busList)
        state.speakerDriverProcessing = drivers(for: busList, rate: 48_000, limiter: -6)
        let once = state.migratingSpeakerRouting(enabled: true)
        XCTAssertNotNil(once.speakerRouting)
        XCTAssertEqual(once, state.migratingSpeakerRouting(enabled: true))
        XCTAssertEqual(once, once.migratingSpeakerRouting(enabled: true))
        // Legacy fields stay as stored.
        var stripped = once
        stripped.speakerRouting = nil
        XCTAssertEqual(stripped, state)
        // The routing survives a round trip through its stored form.
        let data = try JSONEncoder().encode(once)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSystemState.self, from: data), once)
    }

    func testFlagOffOrStoredRoutingLeavesStateUnchanged() throws {
        let busList = buses(for: .biAmp)
        var state = PlaybackSystemState()
        state.bassManagement = bass(.biAmp, .linkwitzRiley24)
        state.outputRouting = routes(busList)
        XCTAssertEqual(state.migratingSpeakerRouting(enabled: false), state)

        var stored = state
        let custom = SpeakerRoutingConfiguration(enabled: true, speakers: [])
        stored.speakerRouting = custom
        XCTAssertEqual(stored.migratingSpeakerRouting(enabled: true).speakerRouting, custom)

        // No physical crossover, disabled routing or a disabled bass manager: nothing to migrate.
        var off = state
        off.bassManagement.enabled = false
        XCTAssertEqual(off.migratingSpeakerRouting(enabled: true), off)
        var noMode = state
        noMode.bassManagement.physicalOutputMode = nil
        XCTAssertEqual(noMode.migratingSpeakerRouting(enabled: true), noMode)
        var noRoutes = state
        noRoutes.outputRouting = nil
        XCTAssertEqual(noRoutes.migratingSpeakerRouting(enabled: true), noRoutes)
        XCTAssertEqual(
            SpeakerRoutingMigration.migrate(routing: nil, bassManagement: state.bassManagement, driverProcessing: nil),
            SpeakerRoutingMigration.Result(routing: nil, refusal: .notApplicable))
    }

    /// E8 A2a: stored tri-amp, bi-amp and mains + sub profiles load, migrate and save with the legacy fields untouched.
    func testStoredLegacyProfilesRoundTripByteIdentical() throws {
        for mode in SpeakerCrossoverMode.allCases {
            let busList = buses(for: mode)
            var state = PlaybackSystemState()
            state.bassManagement = bass(mode, .linkwitzRiley24)
            state.outputRouting = routes(busList)
            state.speakerDriverProcessing = drivers(for: busList, rate: 48_000, limiter: -6)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let stored = try encoder.encode(state)
            let loaded = try JSONDecoder().decode(PlaybackSystemState.self, from: stored)
            XCTAssertEqual(loaded, state)
            XCTAssertEqual(try encoder.encode(loaded), stored)
            let migrated = loaded.migratingSpeakerRouting(enabled: true)
            XCTAssertNotNil(migrated.speakerRouting, "\(mode)")
            XCTAssertEqual(migrated.bassManagement, state.bassManagement)
            XCTAssertEqual(migrated.outputRouting, state.outputRouting)
            XCTAssertEqual(migrated.speakerDriverProcessing, state.speakerDriverProcessing)
            XCTAssertNil(migrated.unmigratedLegacyRoutingReason)
        }
    }

    /// E8 A2a: "Turn off legacy routing" shows only for an unmigratable profile and writes only `outputRouting.enabled`.
    func testTurnOffLegacyRoutingWritesOnlyEnabled() throws {
        let busList = buses(for: .biAmp)
        var state = PlaybackSystemState()
        state.bassManagement = bass(.biAmp, .linkwitzRiley24)
        state.outputRouting = routes(busList)
        XCTAssertNil(state.unmigratedLegacyRoutingReason, "migratable profile has nothing blocked")
        XCTAssertEqual(state.turningOffLegacyRouting().outputRouting?.enabled, false)

        state.speakerDriverProcessing = drivers(for: busList, rate: 48_000, limiter: -25)
        XCTAssertNotNil(state.unmigratedLegacyRoutingReason)
        let off = state.turningOffLegacyRouting()
        XCTAssertEqual(off.outputRouting?.enabled, false)
        XCTAssertNil(off.unmigratedLegacyRoutingReason)
        var expected = state
        expected.outputRouting?.enabled = false
        XCTAssertEqual(off, expected)
        XCTAssertEqual(PlaybackSystemState().turningOffLegacyRouting(), PlaybackSystemState())
    }

    func testUnrepresentableLegacyConfigurationIsRefusedNotApproximated() throws {
        let busList = buses(for: .biAmp)
        var driverConfig = drivers(for: busList, rate: 48_000, limiter: -25)
        let loose = SpeakerRoutingMigration.migrate(
            routing: routes(busList), bassManagement: bass(.biAmp, .linkwitzRiley24), driverProcessing: driverConfig)
        guard case .unsupported = loose.refusal else { return XCTFail("limiter below the routing floor") }
        XCTAssertNil(loose.routing)

        driverConfig = drivers(for: busList, rate: 48_000, limiter: -6)
        driverConfig.buses[0].eqBands.append(EQBand(type: .bandPass, frequencyHz: 1_000, gainDB: 0, q: 1))
        let shape = SpeakerRoutingMigration.migrate(
            routing: routes(busList), bassManagement: bass(.biAmp, .linkwitzRiley24), driverProcessing: driverConfig)
        guard case .unsupported = shape.refusal else { return XCTFail("unsupported EQ shape") }

        var state = PlaybackSystemState()
        state.bassManagement = bass(.biAmp, .linkwitzRiley24)
        state.outputRouting = routes(busList)
        state.speakerDriverProcessing = driverConfig
        XCTAssertEqual(state.migratingSpeakerRouting(enabled: true), state)
    }
}

private extension RoutedWay {
    func withEndpoint(_ endpoint: PhysicalOutputEndpoint) -> RoutedWay {
        var copy = self
        copy.endpoint = endpoint
        return copy
    }
}
