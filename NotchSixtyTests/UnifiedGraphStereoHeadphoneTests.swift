import XCTest
@testable import NotchSixty

/// E6 S9d: the stereo headphone profile on the graph. Behavioural: the graph's HEADPHONE and ear delay stages against
/// the legacy `N60HeadphoneDSP` the kernel runs, live edits, eligibility and the planner's stereo decisions.
final class UnifiedGraphStereoHeadphoneTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func profile(_ edit: (inout HeadphoneDeviceProfileConfiguration) -> Void = { _ in })
        -> HeadphoneDeviceProfileConfiguration {
        var profile = HeadphoneDeviceProfileConfiguration()
        profile.spatialMode = .stereo
        edit(&profile)
        return profile
    }

    private func stereoSpec(_ rate: Double, _ profile: HeadphoneDeviceProfileConfiguration) throws -> UnifiedGraphSpec {
        let configuration = UnifiedGraphConfiguration(
            sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        return try UnifiedGraphTranslator.stereoApplyHeadphone(spec: try configuration.makeSpec(), profile: profile)
            .get().spec
    }

    /// Deterministic, different signals on both channels with content from low to high frequency.
    private func signal(_ rate: Double, start: Int, count: Int) -> [[Float]] {
        var left = [Float](), right = [Float]()
        for i in start..<(start + count) {
            let t = Double(i) / rate
            let l = 0.12 * sin(2 * .pi * 120 * t) + 0.08 * sin(2 * .pi * 1_000 * t) + 0.05 * sin(2 * .pi * 5_000 * t)
            let r = 0.10 * sin(2 * .pi * 80 * t + 1) + 0.09 * sin(2 * .pi * 2_500 * t) + 0.04 * sin(2 * .pi * 9_000 * t)
            left.append(Float(l)); right.append(Float(r))
        }
        return [left, right]
    }

    private func renderGraph(_ spec: UnifiedGraphSpec, rate: Double, frames: Int) throws -> [[Float]] {
        let host = try UnifiedGraphHost(spec: spec)
        defer { host.release() }
        var out: [[Float]] = [[], []]
        var done = 0
        while done < frames {
            let input = signal(rate, start: done, count: block)
            let rendered = try host.processOffline(input: input, frames: block)
            out[0] += rendered[0]; out[1] += rendered[1]
            done += block
        }
        return out
    }

    private func renderLegacy(_ profile: HeadphoneDeviceProfileConfiguration, rate: Double, frames: Int) throws -> [[Float]] {
        var snapshot = try profile.makeRealtimeSnapshot(sampleRate: rate)
        let runtime = try XCTUnwrap(N60HeadphoneDSPRuntimeCreate())
        defer { N60HeadphoneDSPRuntimeDestroy(runtime) }
        XCTAssertTrue(N60HeadphoneDSPRuntimePrepare(runtime, &snapshot))
        let input = signal(rate, start: 0, count: frames)
        var out: [[Float]] = [[], []]
        for i in 0..<frames {
            var l: Float = 0, r: Float = 0
            XCTAssertTrue(N60HeadphoneDSPProcessStereoFrame(runtime, &snapshot, input[0][i], input[1][i], &l, &r))
            out[0].append(l); out[1].append(r)
        }
        return out
    }

    /// Largest difference over the settled part, relative to the legacy peak.
    private func relativeError(_ a: [[Float]], _ b: [[Float]], skip: Int) -> Double {
        var peak = 1e-9, worst = 0.0
        for ear in 0..<2 {
            for i in skip..<min(a[ear].count, b[ear].count) {
                peak = max(peak, Double(abs(b[ear][i])))
                worst = max(worst, Double(abs(a[ear][i] - b[ear][i])))
            }
        }
        return worst / peak
    }

    // MARK: parity with the legacy stage

    private func settings() -> [(String, HeadphoneDeviceProfileConfiguration)] {
        func bands(_ gain: Double) -> [HeadphoneCorrectionEQBand] {
            [HeadphoneCorrectionEQBand(type: .peaking, frequencyHz: 1_000, gainDB: gain, q: 1.2),
             HeadphoneCorrectionEQBand(type: .highShelf, frequencyHz: 6_000, gainDB: -3, q: 0.7)]
        }
        return [
            ("unity", profile()),
            ("gain", profile { $0.left.gainDB = -4; $0.right.gainDB = 2.5 }),
            ("polarity", profile { $0.right.polarityInverted = true }),
            ("headroom", profile { $0.headroomAttenuationDB = 12 }),
            ("eq", profile { $0.left.eqBands = bands(4); $0.right.eqBands = bands(-3) }),
            ("delay", profile { $0.left.delayMilliseconds = 0.8; $0.right.delayMilliseconds = 0.3 }),
            ("crossfeed", profile { $0.crossfeed.applyPreset(.standard) }),
            ("crossfeed wide", profile { $0.crossfeed.applyPreset(.wide); $0.left.gainDB = -1 }),
        ]
    }

    func testGraphMatchesTheLegacyHeadphoneStageForEverySettingAtEveryRate() throws {
        for rate in Self.rates {
            for (name, setting) in settings() {
                let frames = Int(rate * 0.4) / block * block
                let graph = try renderGraph(try stereoSpec(rate, setting), rate: rate, frames: frames)
                let legacy = try renderLegacy(setting, rate: rate, frames: frames)
                let error = relativeError(graph, legacy, skip: Int(rate * 0.1))
                XCTAssertLessThan(error, 0.02, "\(name) at \(rate): relative error \(error)")
            }
        }
    }

    // MARK: eligibility

    func testEligibilityFollowsTheStageRanges() throws {
        let rate = 48_000.0
        let spec = try stereoSpec(rate, profile())
        XCTAssertNoThrow(try UnifiedGraphTranslator.stereoApplyHeadphone(spec: spec, profile: profile()).get())
        // Virtual Speakers profiles belong to the binaural path.
        XCTAssertEqual(
            UnifiedGraphTranslator.stereoApplyHeadphone(spec: spec, profile: profile { $0.spatialMode = .virtualSpeakers })
                .failureReason, .headphoneDSP)
        // A crossfeed corner above the stage's range stays on the kernel; outside stereo mode it is inert.
        var wide = profile { $0.crossfeed.applyPreset(.custom); $0.crossfeed.amount = 0.4; $0.crossfeed.headShadowFrequencyHz = 5_000 }
        XCTAssertEqual(UnifiedGraphTranslator.stereoApplyHeadphone(spec: spec, profile: wide).failureReason, .headphoneDSP)
        wide.crossfeed.preset = .off
        XCTAssertNoThrow(try UnifiedGraphTranslator.stereoApplyHeadphone(spec: spec, profile: wide).get())
        let sixteen = (0..<16).map { HeadphoneCorrectionEQBand(type: .peaking, frequencyHz: 200 + Double($0) * 300, gainDB: 1, q: 1) }
        XCTAssertNoThrow(try UnifiedGraphTranslator.stereoApplyHeadphone(
            spec: spec, profile: profile { $0.left.eqBands = sixteen; $0.headroomAttenuationDB = 30 }).get())
    }

    func testCrossfeedIsPartOfTheStageForStereoAndInertForVirtualSpeakers() throws {
        let rate = 48_000.0
        var stereo = profile { $0.crossfeed.applyPreset(.standard) }
        let stage = UnifiedGraphTranslator.headphoneStage(profile: stereo)
        XCTAssertEqual(stage.params[1], Float(stereo.crossfeed.amount))
        stereo.spatialMode = .virtualSpeakers
        XCTAssertEqual(UnifiedGraphTranslator.headphoneStage(profile: stereo).params[1], 0)
        _ = rate
    }

    // MARK: live edits

    func testLiveEditNeverStepsAboveTheRampSlopeAndMatchesAFreshBuild() throws {
        for rate in Self.rates {
            let start = profile()
            let edits: [(String, HeadphoneDeviceProfileConfiguration)] = [
                ("gain", profile { $0.left.gainDB = -6 }),
                ("eq", profile { $0.left.eqBands = [HeadphoneCorrectionEQBand(type: .peaking, frequencyHz: 1_000, gainDB: 3, q: 1)]
                    $0.headroomAttenuationDB = 6 }),
                ("delay", profile { $0.left.delayMilliseconds = 2; $0.right.delayMilliseconds = 1 }),
                ("crossfeed", profile { $0.crossfeed.applyPreset(.gentle) }),
            ]
            for (name, edited) in edits {
                let host = try UnifiedGraphHost(spec: try stereoSpec(rate, start))
                var position = 0
                var all: [[Float]] = [[], []]
                func run(_ seconds: Double) throws {
                    let total = Int(rate * seconds) / block * block
                    var done = 0
                    while done < total {
                        let out = try host.processOffline(input: signal(rate, start: position, count: block), frames: block)
                        all[0] += out[0]; all[1] += out[1]
                        position += block; done += block
                    }
                }
                try run(0.1)
                let before = all[0].count
                _ = try host.apply(try stereoSpec(rate, edited))
                try run(0.6)
                // The signal is the same before and after; compare the edit against a fresh build of the new profile.
                let fresh = try renderGraph(try stereoSpec(rate, edited), rate: rate, frames: position)
                let tail = (position - Int(rate * 0.2))..<position
                var worst = 0.0, peak = 1e-9
                for ear in 0..<2 {
                    for i in tail {
                        peak = max(peak, Double(abs(fresh[ear][i])))
                        worst = max(worst, Double(abs(all[ear][i] - fresh[ear][i])))
                    }
                }
                XCTAssertLessThan(worst / peak, 0.02, "\(name) at \(rate) after the fade")
                // No sample-to-sample step far above what the signal itself produces (the ramps are click-free).
                var maxStep: Float = 0, maxFresh: Float = 0
                for ear in 0..<2 {
                    for i in max(before, 1)..<all[ear].count { maxStep = max(maxStep, abs(all[ear][i] - all[ear][i - 1])) }
                    for i in 1..<fresh[ear].count { maxFresh = max(maxFresh, abs(fresh[ear][i] - fresh[ear][i - 1])) }
                }
                XCTAssertLessThan(maxStep, 3 * maxFresh + 1e-3, "\(name) at \(rate)")
                host.release()
            }
        }
    }

    // MARK: engine decisions

    func testPlannerDecisionsForStereoSessions() {
        func context(graph: Bool) -> HeadphoneLiveEditPlanner.Context {
            .init(unifiedGraphEnabled: true, lifecycleRunning: true, binauralSession: .none,
                  nChannelSessionActive: false, stereoHeadphoneGraphActive: graph)
        }
        let old = profile { $0.enabled = true; $0.outputDeviceUID = "out" }
        var edited = old; edited.left.gainDB = -3; edited.crossfeed.applyPreset(.wide)
        func plan(_ from: HeadphoneDeviceProfileConfiguration?, _ to: HeadphoneDeviceProfileConfiguration?, graph: Bool)
            -> HeadphoneLiveEditPlan { HeadphoneLiveEditPlanner.plan(from: from, to: to, context: context(graph: graph)) }
        XCTAssertEqual(plan(old, edited, graph: true), .liveEdit(assetChanged: false))
        // Session-kind changes rebuild through the fade.
        XCTAssertEqual(plan(old, nil, graph: true), .reconfigure)
        XCTAssertEqual(plan(nil, old, graph: false), .reconfigure)
        var other = old; other.outputDeviceUID = "other"
        XCTAssertEqual(plan(old, other, graph: true), .reconfigure)
        var virtual = old; virtual.spatialMode = .virtualSpeakers
        XCTAssertEqual(plan(old, virtual, graph: true), .reconfigure)
        // A kernel-rendered headphone session does not edit live.
        XCTAssertEqual(plan(old, edited, graph: false), .reconfigure)
        // Two disabled profiles change nothing a session renders.
        var disabled = old; disabled.enabled = false
        var renamed = disabled; renamed.name = "x"
        XCTAssertEqual(plan(disabled, renamed, graph: false), .refuse)
    }
}

private extension Result {
    var failureReason: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}
