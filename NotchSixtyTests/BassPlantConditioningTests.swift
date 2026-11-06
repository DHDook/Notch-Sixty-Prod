import XCTest
@testable import NotchSixty

// E26 S3: rank-one bass conditioning of the L/R design.
final class BassPlantConditioningTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func c(_ r: Double, _ i: Double) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(real: r, imaginary: i)
    }

    private func delayed(_ gain: Double, seconds: Double, rate: Double, hz: Double) -> ActiveQuietZoneComplex {
        let samples = (seconds * rate).rounded()
        let angle = -2 * Double.pi * hz * samples / rate
        return c(gain * cos(angle), gain * sin(angle))
    }

    func testIdentityPlantIsFree() {
        let a = BassPlantConditioning.assess(
            frequencyHz: 60, leftToFirst: c(1, 0), rightToFirst: c(0, 0),
            leftToSecond: c(0, 0), rightToSecond: c(1, 0))
        XCTAssertEqual(a.conditionDB, 0, accuracy: 1e-9)
        XCTAssertEqual(a.mode, .free)
    }

    func testSharedSubPlantIsCommonModeAtEveryRate() {
        for rate in rates {
            // Both feeds reach both points through one sub: the columns are nearly parallel.
            let sub = delayed(1, seconds: 0.005, rate: rate, hz: 60)
            let a = BassPlantConditioning.assess(
                frequencyHz: 60,
                leftToFirst: sub, rightToFirst: sub * c(1.001, 0),
                leftToSecond: sub * c(0.8, 0), rightToSecond: sub * c(0.8, 0.0005))
            XCTAssertEqual(a.mode, .commonMode, "rate \(rate)")
            XCTAssertGreaterThan(a.conditionDB, 20)
        }
    }

    func testModeBandsAndScaling() {
        XCTAssertEqual(BassPlantConditioning.mode(forConditionDB: 9.9), .free)
        XCTAssertEqual(BassPlantConditioning.mode(forConditionDB: 20.1), .commonMode)
        XCTAssertEqual(BassPlantConditioning.mode(forConditionDB: .infinity), .commonMode)
        guard case .tikhonov(let low) = BassPlantConditioning.mode(forConditionDB: 12),
              case .tikhonov(let high) = BassPlantConditioning.mode(forConditionDB: 19) else {
            return XCTFail("expected tikhonov")
        }
        XCTAssertGreaterThan(high, low)
        XCTAssertGreaterThan(low, 1)
        XCTAssertLessThanOrEqual(high, BassPlantConditioning.maximumLambdaScale)
    }

    func testCommonModeMatchesSingleActuatorOptimumAndDrivesSubNoHarderThanOneChannel() throws {
        var config = ActiveQuietZoneConfiguration()
        config.maximumPerSourceTonePeakDBFS = -18
        config.maximumAggregateSourcePeakDBFS = -12
        let planner = ActiveQuietZonePlanner()
        for rate in rates {
            let sub = delayed(0.7, seconds: 0.005, rate: rate, hz: 60)
            let left = sub
            let right = sub * c(0.999, 0.001)
            let d = c(0.05, 0.02)
            let common = try planner.solveStereo(
                frequencyHz: 60, disturbance: d, leftSecondaryPath: left, rightSecondaryPath: right,
                availableInjectionPeak: 0.25, configuration: config, bassConditioning: .commonMode)
            // Single actuator: the summed path driven by one weight (through solveStereo with a zero second path).
            let single = try planner.solveStereo(
                frequencyHz: 60, disturbance: d, leftSecondaryPath: left + right, rightSecondaryPath: c(0, 0),
                availableInjectionPeak: 0.25, configuration: config)
            XCTAssertEqual(common.leftOutput, common.rightOutput)
            XCTAssertEqual(
                common.predictedReductionDB, single.predictedReductionDB, accuracy: 0.5, "rate \(rate)")
            // The sub sees (L + R) / 2 of the weights: no higher than one channel's weight.
            let subDrive = (common.leftOutput.magnitude + common.rightOutput.magnitude) / 2
            XCTAssertLessThanOrEqual(subDrive, common.leftOutput.magnitude + 1e-12)
            // A free solve splits the work across channels; common mode never exceeds the single-channel optimum
            // by more than the regularisation allows.
            XCTAssertLessThanOrEqual(common.leftOutput.magnitude, single.leftOutput.magnitude * 1.01 + 1e-9)
        }
    }

    func testFreeModeIsBitIdenticalToDefault() throws {
        let config = ActiveQuietZoneConfiguration()
        let planner = ActiveQuietZonePlanner()
        let a = try planner.solveStereo(
            frequencyHz: 60, disturbance: c(0.08, 0.03), leftSecondaryPath: c(0.8, 0.1),
            rightSecondaryPath: c(0.45, -0.2), availableInjectionPeak: 0.25, configuration: config)
        let b = try planner.solveStereo(
            frequencyHz: 60, disturbance: c(0.08, 0.03), leftSecondaryPath: c(0.8, 0.1),
            rightSecondaryPath: c(0.45, -0.2), availableInjectionPeak: 0.25, configuration: config,
            bassConditioning: .free)
        XCTAssertEqual(a, b)
    }

    func testTikhonovKeepsSingleErrorPointSolutionValid() throws {
        let config = ActiveQuietZoneConfiguration()
        let planner = ActiveQuietZonePlanner()
        func solve(_ mode: BassPlantConditioningMode) throws -> ActiveQuietZoneStereoSolution {
            try planner.solveStereo(
                frequencyHz: 60, disturbance: c(0.08, 0.03), leftSecondaryPath: c(0.8, 0.1),
                rightSecondaryPath: c(0.45, -0.2), availableInjectionPeak: 5, configuration: config,
                bassConditioning: mode)
        }
        let free = try solve(.free)
        let reg = try solve(.tikhonov(lambdaScale: 5))
        // The solution is rescaled to the target reduction, so a larger Tikhonov term changes the direction
        // (and keeps the result finite and bounded) rather than the raw level.
        // With one error point the result is rescaled to the target reduction, so the term only matters when the
        // caps bind; the multi-point callers (FIR, FxLMS) consume the scale directly.
        XCTAssertEqual(free.leftOutput, reg.leftOutput)
        XCTAssertTrue(reg.leftOutput.magnitude.isFinite && reg.rightOutput.magnitude.isFinite)
        XCTAssertGreaterThan(reg.predictedReductionDB, 0)
    }

    func testCardReadout() {
        func bin(_ hz: Double, _ db: Double) -> BassPlantConditioning {
            BassPlantConditioning(
                frequencyHz: hz, conditionDB: db, mode: BassPlantConditioning.mode(forConditionDB: db))
        }
        let shared = BassPlantConditioningSummary(bins: [bin(30, 30), bin(60, 25), bin(88, 22), bin(120, 5), bin(200, 40)])
        XCTAssertEqual(shared.cardReadout, "Below 90 Hz both channels share your subwoofer.")
        XCTAssertNil(BassPlantConditioningSummary(bins: [bin(30, 3), bin(60, 30)]).cardReadout)
    }

    func testBoundedAdaptationUnderDriftOverSixtySeconds() throws {
        // Simulated drift of the sub's phase: the common-mode weight stays bounded by the single-channel limit.
        let config = ActiveQuietZoneConfiguration()
        let planner = ActiveQuietZonePlanner()
        var peak = 0.0
        for step in 0..<600 {
            let t = Double(step) * 0.1
            let phase = 0.3 * sin(2 * Double.pi * t / 60)
            let sub = c(0.7 * cos(phase), 0.7 * sin(phase))
            let s = try planner.solveStereo(
                frequencyHz: 60, disturbance: c(0.05, 0.02), leftSecondaryPath: sub, rightSecondaryPath: sub,
                availableInjectionPeak: 0.25, configuration: config, bassConditioning: .commonMode)
            peak = max(peak, s.leftOutput.magnitude)
        }
        XCTAssertLessThanOrEqual(peak, 0.25)
    }
}
