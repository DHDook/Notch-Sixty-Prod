import XCTest
@testable import NotchSixty

/// E6 S12h part 2b (G46): the stereo Quiet Zone feed hosted on the unified graph. Eight rates.
/// Bench (E22): a live stereo Quiet Zone session on hardware through the graph.
final class StereoHostedQuietZoneTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func config(rate: Double, rackLatency: UInt32 = 0) -> UnifiedGraphConfiguration {
        var c = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        c.ancActuators = UnifiedGraphAncActuators(
            actuators: [.init(targetLane: 0), .init(targetLane: 1)], captureFrames: 4096,
            hostFed: true, stereoDirect: true, externalLatencyFrames: rackLatency)
        c.ancActuators?.authorised = true
        return c
    }

    private func install(_ feed: ProfileAncFeed, on host: UnifiedGraphHost) throws {
        let raw = try XCTUnwrap(host.rawGraph)
        let process = unsafeBitCast(
            N60AncLaneFeedProcess as @convention(c) (
                UnsafeMutableRawPointer?, UnsafePointer<UnsafePointer<Float>>, UnsafePointer<UnsafeMutablePointer<Float>>,
                UInt32, UInt32
            ) -> Int32,
            to: n60_external_process_fn.self)
        XCTAssertEqual(n60_graph_set_external_processor(
            OpaquePointer(raw), process, UnsafeMutableRawPointer(feed.pointer), feed.channels), N60_STATUS_OK)
        host.retainedResource = feed
    }

    private func tonal(rate: Double) -> N60ActiveQuietZoneSnapshot {
        var snapshot = N60ActiveQuietZoneSnapshotMakeBypassed()
        var tone = N60ActiveQuietZoneToneSnapshot()
        tone.frequencyHz = 60; tone.leftReal = 0.05; tone.rightReal = 0.05
        XCTAssertTrue(N60ActiveQuietZoneSnapshotSet(&snapshot, &tone, 1, 64, rate, true))
        snapshot.armGeneration = 1
        return snapshot
    }

    func testSpecHasOneExternalStageOverTheProgrammeAndSourceLanesAtEveryRate() throws {
        for rate in rates {
            let cfg = config(rate: rate, rackLatency: 128)
            let spec = try cfg.makeSpec()
            XCTAssertEqual(cfg.channelCount, 5, "base 2, sources 2 and 3, error lane 4 (\(rate))")
            let externals = spec.stages.filter { $0.kind == N60_STAGE_EXTERNAL.rawValue }
            XCTAssertEqual(externals.count, 1, "rate \(rate)")
            XCTAssertEqual(externals[0].laneMask, 0b01111)
            XCTAssertEqual(externals[0].capacityFrames, 128, "the rack latency is declared on the feed's stage")
        }
    }

    func testStereoDirectRejectsWrongActuatorCountAndUnhostedLatency() {
        var wrong = config(rate: 48_000)
        wrong.ancActuators?.actuators.append(.init(targetLane: 2))
        XCTAssertThrowsError(try wrong.makeSpec())
        var latency = config(rate: 48_000)
        latency.ancActuators?.hostFed = false
        latency.ancActuators?.externalLatencyFrames = 64
        XCTAssertThrowsError(try latency.makeSpec())
    }

    /// The graph has five lanes (programme pair, two sources, error); the host feeds zeros on the ANC lanes.
    private func lanes(_ tone: [Float]) -> [[Float]] {
        [tone, tone] + [[Float]](repeating: [Float](repeating: 0, count: tone.count), count: 3)
    }

    private func run(_ host: UnifiedGraphHost, blocks: Int, block: Int, level: Float) throws -> (left: [Float], right: [Float]) {
        var l = [Float](), r = [Float]()
        let tone = (0..<block).map { Float(level) * sin(Float($0) * 0.05) }
        for _ in 0..<blocks {
            let out = try host.processOffline(input: lanes(tone), frames: block)
            l += out[0]; r += out[1]
        }
        return (l, r)
    }

    /// Unauthorised or disarmed: the feed is transparent. Authorised, armed and leased: it adds anti-noise. Disarmed
    /// again: exactly the dry signal.
    func testGraphIsTransparentUntilArmedLeasedAndZeroAfterDisarmAtEveryRate() throws {
        for rate in rates {
            let host = try UnifiedGraphHost(spec: try config(rate: rate).makeSpec())
            let feed = try XCTUnwrap(ProfileAncFeed(stereoSampleRate: rate, peakLimit: 1, fadeInSeconds: 0.02))
            try install(feed, on: host)
            let block = 480
            let tone = (0..<block).map { 0.1 * sin(Float($0) * 0.05) }

            let idle = try host.processOffline(input: lanes(tone), frames: block)
            XCTAssertEqual(idle[0], tone, "no anti-noise before Arm (\(rate))")

            var snapshot = tonal(rate: rate)
            XCTAssertTrue(N60AncLaneFeedSetTonalSnapshot(feed.pointer, &snapshot))
            let unleased = try host.processOffline(input: lanes(tone), frames: block)
            XCTAssertEqual(unleased[0], tone, "no anti-noise without Arm (\(rate))")

            N60AncLaneFeedArm(feed.pointer)
            var armedUnleased = try host.processOffline(input: lanes(tone), frames: block)
            XCTAssertEqual(armedUnleased[0], tone, "armed without a lease still adds nothing (\(rate))")
            armedUnleased = []

            N60AncLaneFeedRenewLease(feed.pointer, UInt64(rate * 600))
            var differs = false
            for _ in 0..<max(4, Int(rate * 0.1) / block) {
                let out = try host.processOffline(input: lanes(tone), frames: block)
                if out[0] != tone { differs = true }
            }
            XCTAssertTrue(differs, "armed and leased adds the anti-noise pair (\(rate))")

            N60AncLaneFeedDisarm(feed.pointer)
            N60AncLaneFeedReleaseLease(feed.pointer)
            for _ in 0..<max(4, Int(rate * 0.1) / block) { _ = try host.processOffline(input: lanes(tone), frames: block) }
            let after = try host.processOffline(input: lanes(tone), frames: block)
            XCTAssertEqual(after[0], tone, "exactly dry after Disarm and the 20 ms fade (\(rate))")
            XCTAssertEqual(after[1], tone)
        }
    }

    /// An inner processor (the AU rack) runs in place on the programme pair before the feed.
    func testInnerProcessorRunsOnTheProgrammeLanesAtEveryRate() throws {
        for rate in rates {
            let host = try UnifiedGraphHost(spec: try config(rate: rate).makeSpec())
            let feed = try XCTUnwrap(ProfileAncFeed(stereoSampleRate: rate))
            try install(feed, on: host)
            let inner: N60AncLaneFeedInnerFn = { _, input, output, count, frames in
                for c in 0..<min(2, Int(count)) {
                    for n in 0..<Int(frames) { output[c][n] = input[c][n] * 0.5 }
                }
                return 1
            }
            XCTAssertTrue(N60AncLaneFeedSetInnerProcessor(feed.pointer, inner, nil))
            let block = 256
            let tone = (0..<block).map { 0.2 * sin(Float($0) * 0.05) }
            let out = try host.processOffline(input: lanes(tone), frames: block)
            for n in 0..<block { XCTAssertEqual(out[0][n], tone[n] * 0.5, accuracy: 1e-6, "rate \(rate) frame \(n)") }
        }
    }
}
