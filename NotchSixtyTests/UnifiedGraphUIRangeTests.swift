import XCTest
@testable import NotchSixty

/// E6 S12f2 (G34): every soft clipper, gain rider, limiter ceiling and oversampling setting the UI can produce
/// (the validated ranges of `DynamicsConfiguration`) attaches the unified graph, or is refused with a named reason.
/// A seeded sweep of the corners plus random interior points, at all eight standard rates; a sample of the accepted
/// configurations is built into a host and rendered to prove the core takes them.
@MainActor
final class UnifiedGraphUIRangeTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private struct Generator {
        var state: UInt64
        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func pick(_ range: ClosedRange<Double>) -> Double {
            // Corners are over-represented: one draw in four lands exactly on an end.
            let u = unit()
            if u < 0.125 { return range.lowerBound }
            if u > 0.875 { return range.upperBound }
            return range.lowerBound + unit() * (range.upperBound - range.lowerBound)
        }
        mutating func flag() -> Bool { unit() < 0.5 }
    }

    private func configuration(_ g: inout Generator) -> DynamicsConfiguration {
        var d = DynamicsConfiguration()
        d.softClipper.enabled = g.flag()
        d.softClipper.driveDB = g.pick(SoftClipperConfiguration.driveRange)
        d.softClipper.thresholdDB = g.pick(SoftClipperConfiguration.thresholdRange)
        d.softClipper.kneeSmooth = g.pick(SoftClipperConfiguration.kneeRange)
        d.softClipper.curve = SoftClipperCurve.allCases[Int(g.unit() * 4) % 4]
        d.softClipper.autoCompensateGain = g.flag()
        d.softClipper.asymmetryTrimDB = g.pick(SoftClipperConfiguration.asymmetryTrimRange)
        d.limiter.enabled = g.flag()
        d.limiter.ceilingDB = g.pick(LimiterConfiguration.ceilingRange)
        d.limiter.attackMs = g.pick(LimiterConfiguration.attackRange)
        d.limiter.releaseMs = g.pick(LimiterConfiguration.releaseRange)
        d.limiter.lookAheadMs = g.pick(LimiterConfiguration.lookAheadRange)
        d.limiter.truePeakGuardEnabled = g.flag()
        d.gainRider.enabled = g.flag()
        d.gainRider.targetGainReductionDB = g.pick(GainRiderConfiguration.targetRange)
        d.gainRider.maxReductionDB = g.pick(GainRiderConfiguration.maxReductionRange)
        d.gainRider.speed = GainRiderSpeed.allCases[Int(g.unit() * 3) % 3]
        d.oversampling = OversamplingFactor.allCases[Int(g.unit() * 3) % 3]
        return d
    }

    func testEveryClipperRiderCeilingAndOversamplingSettingAttachesOrNamesItsRefusal() throws {
        var attached = 0
        var generator = Generator(state: 0x5EED_12F2)
        for rate in Self.rates {
            for index in 0..<250 {
                let dynamics = configuration(&generator)
                try dynamics.softClipper.validate()
                try dynamics.limiter.validate()
                try dynamics.gainRider.validate()
                var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
                snapshot.protection = try dynamics.makeProtectionSnapshot(sampleRate: rate)
                let label = "rate \(rate) #\(index) \(dynamics.softClipper) \(dynamics.limiter) \(dynamics.gainRider) \(dynamics.oversampling)"
                switch UnifiedGraphTranslator.stereoEligibility(snapshot: &snapshot, sampleRate: rate) {
                case .failure(let reason):
                    XCTFail("the graph refuses a setting the UI can produce (\(reason)): \(label)")
                case .success(let configuration):
                    attached += 1
                    if index % 25 == 0 {
                        do {
                            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
                            let block = (0..<512).map { Float(0.8 * sin(2 * .pi * 997 * Double($0) / rate)) }
                            let out = try host.processOffline(input: [block, block], frames: 512)
                            XCTAssertTrue(out.allSatisfy { $0.allSatisfy(\.isFinite) }, label)
                        } catch {
                            XCTFail("the core rejects an eligible setting (\(error)): \(label)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(attached, Self.rates.count * 250)
    }
}
