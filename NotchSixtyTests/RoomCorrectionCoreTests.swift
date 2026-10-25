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
}
