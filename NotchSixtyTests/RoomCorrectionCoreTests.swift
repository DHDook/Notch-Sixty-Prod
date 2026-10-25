import XCTest
@testable import NotchSixty

/// E10 S1: the core minimum-phase designer matches the Swift designer (0.01 dB, 0.5 degrees), and
/// the grid and ABI are what the design note fixes.
final class RoomCorrectionCoreTests: XCTestCase {
    func testAbiAndGrid() throws {
        XCTAssertEqual(RoomCorrectionCore.abiVersion, 1)
        let grid = try RoomCorrectionCore.gridFrequencies()
        XCTAssertEqual(grid.count, 479)
        XCTAssertEqual(grid[0], 20, accuracy: 1e-9)
        XCTAssertEqual(grid[48], 40, accuracy: 1e-9)
        XCTAssertLessThan(grid.last ?? 0, 20_000)
    }

    func testMinimumPhaseParityWithSwiftDesigner() throws {
        let curveFrequencies: [Double] = [20, 50, 100, 200, 400, 1000, 2500, 6000, 12000, 20000]
        let curveGain: [Double] = [0, -4, 3, -6, 2, 0, -3, 2, -1, 0]
        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: curveFrequencies, magnitudeDB: curveGain, phaseRadians: nil)
        for sampleRate in [44_100.0, 48_000, 96_000, 192_000] {
            let taps = Int(8192 * sampleRate / 48_000)
            let swiftTaps = try RoomCorrectionFIRDesigner().minimumPhaseTaps(
                desiredCorrection: response, effectiveLowHz: 20, effectiveHighHz: 20_000,
                sampleRate: sampleRate, tapCount: taps)
            let coreTaps = try RoomCorrectionCore.minimumPhaseTaps(
                sampleRate: sampleRate, tapCount: taps, frequenciesHz: curveFrequencies, gainDB: curveGain,
                lowHz: 20, highHz: 20_000)
            for frequency in [30.0, 60, 100, 150, 250, 500, 1000, 2000, 4000, 8000] {
                let s = Self.response(swiftTaps, frequency, sampleRate)
                let c = Self.response(coreTaps, frequency, sampleRate)
                let dB = 20 * log10(hypot(c.0, c.1) / hypot(s.0, s.1))
                var dPhase = atan2(c.1, c.0) - atan2(s.1, s.0)
                while dPhase > .pi { dPhase -= 2 * .pi }
                while dPhase < -.pi { dPhase += 2 * .pi }
                XCTAssertEqual(dB, 0, accuracy: 0.01, "magnitude at \(frequency) Hz, \(sampleRate)")
                XCTAssertEqual(dPhase * 180 / .pi, 0, accuracy: 0.5, "phase at \(frequency) Hz, \(sampleRate)")
            }
        }
    }

    // MARK: E10 S2

    func testLatencyModesResolveToBudgets() {
        XCTAssertEqual(RoomCorrectionLatencyMode.video.budgetSeconds, 0)
        XCTAssertFalse(RoomCorrectionLatencyMode.video.isMixedPhase)
        XCTAssertEqual(RoomCorrectionLatencyMode.music20ms.budgetSeconds, 0.020, accuracy: 1e-12)
        XCTAssertEqual(RoomCorrectionLatencyMode.defaultMusic.budgetSeconds, 0.050, accuracy: 1e-12)
        XCTAssertEqual(RoomCorrectionLatencyMode.music100ms.budgetSeconds, 0.100, accuracy: 1e-12)
        XCTAssertTrue(RoomCorrectionLatencyMode.music100ms.isMixedPhase)
    }

    func testDefaultSeatWeightsFavourMainSeat() throws {
        XCTAssertEqual(try RoomCorrectionCore.defaultSeatWeights(seatCount: 4, mainSeat: 1), [1, 2, 1, 1])
    }

    func testDesignAndSynthesisThroughTheWrapper() throws {
        // Two seats, each a delayed impulse with a small echo: coherent, so music mode delays by the budget.
        let rate = 48_000.0
        let seats = (0..<2).map { seat -> RoomCorrectionCore.SeatImpulseResponse in
            var ir = [Float](repeating: 0, count: 24_000)
            let arrival = 120 + seat * 12
            ir[arrival] = 1
            ir[arrival + 240] = 0.3
            return .init(samples: ir, arrivalFrames: Double(arrival), weight: seat == 0 ? 2 : 1)
        }
        for mode in [RoomCorrectionLatencyMode.video, .music50ms] {
            let design = try RoomCorrectionCore.designGrid(seats: seats, sampleRate: rate, mainSeat: 0, mode: mode)
            XCTAssertEqual(design.seatContribution.count, 2)
            if mode == .video { XCTAssertTrue(design.correctionPhaseRadians.allSatisfy { $0 == 0 }) }
            let result = try RoomCorrectionCore.synthesize(design, sampleRate: rate, mode: mode)
            XCTAssertEqual(result.declaredLatencyFrames, UInt32((mode.budgetSeconds * rate).rounded()))
            XCTAssertTrue(result.taps.allSatisfy { $0.isFinite })
        }
    }

    func testSchema1DesignMigratesToMinimumPhaseUnchanged() throws {
        let filter = RoomCorrectionFilter(
            name: "legacy", sampleRate: 48_000, leftTaps: [1, 0.5, 0.25], rightTaps: [1, 0.25], declaredLatencyFrames: 0)
        let legacy = RoomCorrectionDesign(
            name: "Old design", createdAt: Date(timeIntervalSince1970: 1_700_000_000), sampleRate: 48_000,
            parameters: RoomCorrectionDesignParameters(
                correctionLowHz: 20, correctionHighHz: 20_000, smoothingOctaves: 1.0 / 6, maximumBoostDB: 6,
                maximumCutDB: 12, requestedTapCount: 3),
            filter: filter, predictedLeftResponse: nil, predictedRightResponse: nil, recommendedHeadroomDB: 0,
            algorithmVersion: "1")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let migrated = try RoomCorrectionDesignRecord.decode(from: try encoder.encode(legacy), using: decoder)
        XCTAssertEqual(migrated.schemaVersion, 2)
        XCTAssertEqual(migrated.latencyMode, .video)
        XCTAssertEqual(migrated.filter, filter)
        XCTAssertEqual(migrated.id, legacy.id)
        XCTAssertNil(migrated.grid)

        // Schema 2 round-trips, and an unknown schema is refused.
        let round = try RoomCorrectionDesignRecord.decode(from: try encoder.encode(migrated), using: decoder)
        XCTAssertEqual(round, migrated)
        var future = migrated
        future.schemaVersion = 3
        XCTAssertThrowsError(try RoomCorrectionDesignRecord.decode(from: try encoder.encode(future), using: decoder)) {
            XCTAssertEqual($0 as? RoomCorrectionDesignRecord.DecodeError, .unsupportedSchema(3))
        }
    }

    private static func response(_ taps: [Float], _ frequency: Double, _ sampleRate: Double) -> (Double, Double) {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * frequency / sampleRate
        for (n, tap) in taps.enumerated() {
            re += Double(tap) * cos(w * Double(n))
            im -= Double(tap) * sin(w * Double(n))
        }
        return (re, im)
    }

    // MARK: - Joint bass optimiser (E10 S6)

    /// 2 mains and 2 subs at 4 seats: delayed direct sounds plus separable modal rings.
    private func bassRoom(rate: Double) -> [[RoomCorrectionCore.SeatImpulseResponse]] {
        let frames = Int(rate * 0.5)
        let modes: [Double] = [31, 44, 58, 73, 96, 112]
        let sourceDelay: [Double] = [0, 0.0004, 0.0031, 0.0046]
        let tau = 0.12 / log(1000.0)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / 4_503_599_627_370_496.0 - 1.0
        }
        let seatGain = (0..<4).map { _ in modes.map { _ in next() } }
        let sourceGain = (0..<4).map { _ in modes.map { _ in 0.35 + 0.65 * next() } }
        return (0..<4).map { source in
            (0..<4).map { seat in
                var ir = [Float](repeating: 0, count: frames)
                let arrival = (sourceDelay[source] + 0.0035 * Double(seat) / 10 + 0.004) * rate
                ir[Int(arrival.rounded())] = 0.1
                for (index, mode) in modes.enumerated() {
                    let amplitude = 0.012 * (48_000 / rate) * seatGain[seat][index] * sourceGain[source][index]
                    var i = Int(arrival) + 1
                    while i < frames {
                        let t = (Double(i) - arrival) / rate
                        if t > 6 * tau { break }
                        ir[i] += Float(amplitude * exp(-t / tau) * sin(2 * .pi * mode * t))
                        i += 1
                    }
                }
                return .init(samples: ir, arrivalFrames: arrival, weight: 1)
            }
        }
    }

    func testBassOptimiserThroughTheWrapper() throws {
        let rate = 48_000.0
        let irs = bassRoom(rate: rate)
        let channels: [BassChannelSpec] = [.defaults(.main), .defaults(.main), .defaults(.sub), .defaults(.sub)]

        var blocked = BassOptimiserSettings(timingTier: .none)
        XCTAssertThrowsError(try RoomCorrectionCore.optimiseBass(irs: irs, channels: channels, sampleRate: rate, settings: blocked)) {
            XCTAssertEqual($0 as? RoomCorrectionCore.CoreError, .status(N60_CORRECT_ERR_TIMING))
        }
        blocked.timingTier = .acoustic
        let result = try RoomCorrectionCore.optimiseBass(irs: irs, channels: channels, sampleRate: rate, settings: blocked)
        XCTAssertEqual(result.designs.count, 4)
        XCTAssertEqual(result.report.channels.count, 4)
        XCTAssertEqual(result.report.channels.map(\.delayFrames).min(), 0)
        XCTAssertLessThan(result.report.seatStdAfterDB, result.report.seatStdBeforeDB)
        XCTAssertEqual(result.beforeDB.count, 4 * 479)
        for (index, design) in result.designs.enumerated() {
            XCTAssertLessThanOrEqual(design.correctionDB.max() ?? 0, 6 + 1e-9)
            XCTAssertLessThanOrEqual(result.report.channels[index].peakBoostDB, 6 + 1e-9)
            XCTAssertTrue(design.correctionPhaseRadians.allSatisfy { $0.isFinite })
            // The design synthesises at the device rate.
            let taps = try RoomCorrectionCore.synthesize(design, sampleRate: rate, mode: .music100ms).taps
            XCTAssertTrue(taps.allSatisfy { $0.isFinite })
        }
        // Mains keep gain and polarity.
        XCTAssertEqual(result.report.channels[0].gainDB, 0)
        XCTAssertFalse(result.report.channels[0].polarityInverted)
        // Repeat runs are identical.
        let again = try RoomCorrectionCore.optimiseBass(irs: irs, channels: channels, sampleRate: rate, settings: blocked)
        XCTAssertEqual(again.report, result.report)
        XCTAssertEqual(again.designs, result.designs)
    }
}
