import XCTest
@testable import NotchSixty

/// E9 S8: the graduation test. The two E9 flags are graduated (on unless a release user switches them off with
/// `-NotchSixtyFeatures -<id>`); this runs the production path from the flag store through the published policy and the
/// translator's FIR cap to the built graph and the headroom assistant, with the flags on and off, at the eight standard rates.
final class E9ShipTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    @MainActor private func store(_ arguments: [String]) throws -> FeatureFlags {
        let suite = "E9Ship-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return FeatureFlags(known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly, arguments: arguments)
    }

    private func configuration(rate: Double, policy: UnifiedGraphOutputProtection?) -> UnifiedGraphConfiguration {
        var lane = UnifiedGraphLane()
        lane.outputGain = 2
        var c = UnifiedGraphConfiguration(sampleRate: rate, lanes: [lane, lane])
        c.bassManagement = UnifiedGraphBassManagement(
            crossoverHz: 80, redirectDB: UnifiedGraphBassManagement.twoMainMeanRedirectDB, subwoofers: [UnifiedGraphSubwoofer()])
        c.protection = UnifiedGraphProtection(
            limiterEnabled: true, ceilingDB: -12, attackMilliseconds: 1, releaseMilliseconds: 50,
            lookAheadMilliseconds: 2, truePeakGuard: true, oversampling: 2)
        c.outputProtection = policy
        return c
    }

    @MainActor func testBothFlagsAreGraduatedAndStayRegistered() throws {
        for flag in [FeatureFlag.longFIR, .outputProtection] {
            XCTAssertTrue(FeatureFlag.all.contains(flag))
            XCTAssertTrue(flag.graduated)
            XCTAssertTrue(try store([]).isEnabled(flag), "\(flag.id) defaults on")
            XCTAssertFalse(try store(["-NotchSixtyFeatures", "-\(flag.id)"]).isEnabled(flag), "\(flag.id) off switch")
        }
    }

    @MainActor func testOutputProtectionAndHeadroomAssistantReachThePublishedStagesWithFlagsOnAndOff() throws {
        let previous = UnifiedGraphOutputProtection.apply(settings: OutputProtectionSettings())
        defer {
            UnifiedGraphOutputProtection.apply(settings: previous)
            UnifiedGraphOutputProtection.refresh(try? store(["-NotchSixtyFeatures", "-e9.output-protection"]))
        }
        let hardLimits = UnifiedGraphOutputProtection.hardLimitStageBase..<UnifiedGraphOutputProtection.userLaneStageBase

        UnifiedGraphOutputProtection.refresh(try store(["-NotchSixtyFeatures", "-e9.output-protection"]))
        XCTAssertNil(UnifiedGraphOutputProtection.current())
        for rate in Self.rates {
            let off = try configuration(rate: rate, policy: UnifiedGraphOutputProtection.current()).makeSpec()
            XCTAssertFalse(off.stages.contains { hardLimits.contains($0.stageId) }, "flag off: no hard limits at \(rate)")
        }

        UnifiedGraphOutputProtection.refresh(try store([]))
        let policy = try XCTUnwrap(UnifiedGraphOutputProtection.current(), "graduated: on by default")
        for rate in Self.rates {
            let spec = try configuration(rate: rate, policy: policy).makeSpec()
            XCTAssertEqual(spec.stages.filter { hardLimits.contains($0.stageId) }.count, 3, "two mains and the sub at \(rate)")
            let before = HeadroomModel(spec: spec, laneCount: 2, strict: false, trimsDB: [:]).analyse()
            XCTAssertFalse(before.isEmpty)
            XCTAssertTrue(before.contains { $0.neededDB > 0 }, "+6 dB of gain under a -12 dB ceiling needs headroom at \(rate)")
            let applied = HeadroomAssistant.applying(before, to: OutputProtectionSettings())
            var trims: [Int: Double] = [:]
            for result in before { trims[result.lane] = result.appliedTrimDB }
            let trimmed = try configuration(rate: rate, policy: UnifiedGraphOutputProtection(applied)).makeSpec()
            let after = HeadroomModel(spec: trimmed, laneCount: 2, strict: false, trimsDB: trims).analyse()
            XCTAssertTrue(after.allSatisfy(\.isSatisfied), "assistant trims satisfy the model at \(rate)")
            XCTAssertNotEqual(applied, OutputProtectionSettings(), "assistant wrote the trims into the settings at \(rate)")
        }
    }

    @MainActor func testProgramFIR262144TapsBuildsWithTheGraduatedSchemeAndIsRefusedWithTheFlagOff() throws {
        let taps = 262_144
        for (arguments, accepted) in [([String](), true), (["-NotchSixtyFeatures", "-e9.long-fir"], false)] {
            let scheme = UnifiedGraphFIRScheme.scheme(for: try store(arguments))
            XCTAssertEqual(scheme, accepted ? UnifiedGraphFIRScheme.nonUniform : UnifiedGraphFIRScheme.uniform)
            for rate in Self.rates {
                var stages = UnifiedGraphStereoStages()
                stages.programFIR = UnifiedGraphFIRProgram(
                    generation: 1, left: [Float](repeating: 0, count: taps - 1) + [1], right: nil, declaredLatencyFrames: 0)
                var c = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
                c.stereoStages = stages
                c.firScheme = scheme
                if accepted {
                    let host = try UnifiedGraphHost(spec: c.makeSpec())
                    let out = try host.processOffline(input: [[Float](repeating: 0.25, count: 512), [Float](repeating: 0, count: 512)], frames: 512)
                    XCTAssertEqual(out.count, Int(host.outputChannels), "renders at \(rate)")
                } else {
                    XCTAssertThrowsError(try c.makeSpec(), "flag off keeps the 32,768-tap cap at \(rate)")
                }
            }
        }
    }
}
