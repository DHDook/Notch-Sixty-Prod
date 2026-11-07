import XCTest
@testable import NotchSixty

/// E26 S7b2 / G37: the host-fed class A graph against the `.appSplitter` twin, `BASS_MGMT` against the bus splitter
/// per filter family, and the software-mode volume invariance. Deterministic, all eight rates. Nothing here arms a
/// real device: the feed is driven offline through `UnifiedGraphHost.processOffline`.
final class SubActuatorTwinTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 480
    // Long enough that the guard's growth detector (energy x6 for 3 blocks) sees a ramp, as with the 3 s production fade.
    private let fade = 0.5

    private func bass(_ topology: CrossoverTopology = .linkwitzRiley24, hz: Double = 80) -> BassManagementConfiguration {
        var c = BassManagementConfiguration()
        c.enabled = true
        c.frequencyHz = hz
        c.topology = topology
        c.physicalOutputMode = .mainsSub
        return c
    }

    /// Two programme lanes, one sub lane (3 audio lanes) plus three anti-noise source lanes.
    private func hostedConfig(rate: Double, userGain: Float, hostFed: Bool = true, laneGain: Float = 1) -> UnifiedGraphConfiguration {
        var lane = UnifiedGraphLane()
        lane.outputGain = laneGain
        var config = UnifiedGraphConfiguration(sampleRate: rate, lanes: [lane, lane])
        config.bassManagement = UnifiedGraphBassManagement(subwoofers: [UnifiedGraphSubwoofer()])
        if hostFed {
            config.ancActuators = UnifiedGraphAncActuators(
                actuators: [.init(targetLane: 0), .init(targetLane: 1), .init(targetLane: 2)], captureFrames: 4096,
                hostFed: true, userOutputGain: userGain)
            config.ancActuators?.authorised = true
        }
        return config
    }

    private func armTonal(_ feed: ProfileAncFeed, rate: Double, hz: Double) {
        var tonal = N60ActiveQuietZoneSnapshotMakeBypassed()
        var tone = N60ActiveQuietZoneToneSnapshot()
        tone.frequencyHz = hz; tone.leftReal = 0.05; tone.rightReal = 0.05
        XCTAssertTrue(N60ActiveQuietZoneSnapshotSet(&tonal, &tone, 1, 64, rate, true))
        tonal.armGeneration = 1
        XCTAssertTrue(N60AncLaneFeedSetTonalSnapshot(feed.pointer, &tonal))
        N60AncLaneFeedArm(feed.pointer)
        N60AncLaneFeedRenewLease(feed.pointer, UInt64(rate * 600))
    }

    /// Feed-forward: weights are a pure -0.5 gain on the reference; the reference pump is `ref`.
    private func armFeedForward(_ feed: ProfileAncFeed, rate: Double) {
        let w: [Float] = [-0.5, 0, 0, 0, 0, 0, 0, 0], z = w
        XCTAssertTrue(N60AncLaneFeedSetFeedForwardWeights(feed.pointer, w, z, 1))
        XCTAssertEqual(Int(N60AncLaneFeedFeedForwardArm(feed.pointer, 0.010, 0.005)), Int(N60FeedForwardLiveArmOK))
        N60AncLaneFeedArm(feed.pointer)
        N60AncLaneFeedRenewLease(feed.pointer, UInt64(rate * 600))
    }

    private func referenceTone(hz: Double, rate: Double, index: UInt64, count: Int) -> [Float] {
        (0..<count).map { Float(0.5 * sin(2 * Double.pi * hz * Double(index + UInt64($0)) / rate)) }
    }

    private func pumpReference(_ feed: ProfileAncFeed, hz: Double, rate: Double, pushed: inout UInt64, ahead: Int) {
        let want = N60AncLaneFeedReferenceOutputIndex(feed.pointer) + UInt64(ahead)
        while pushed < want {
            let chunk = referenceTone(hz: hz, rate: rate, index: pushed, count: block)
            pushed = N60AncLaneFeedPushReference(feed.pointer, pushed, chunk, UInt32(block))
        }
    }

    private enum Drive { case none, tonal(Double), feedForward(Double) }

    /// Renders `frames` through the host-fed graph. `programme` is planar (left, right); `midway` swaps the spec once.
    private func runGraph(
        rate: Double, config: UnifiedGraphConfiguration, drive: Drive, frames: Int,
        programme: [Float]? = nil, swapAt: Int? = nil, swapTo: UnifiedGraphConfiguration? = nil,
        splitter: N60SpeakerBusSplitterSnapshot? = nil, programmeLanes: [Int] = [0, 1]
    ) throws -> [[Float]] {
        let spec = try config.makeSpec()
        let host = try UnifiedGraphHost(spec: spec)
        defer { host.release() }
        let channels = Int(spec.inputChannels)
        if config.ancActuators?.hostFed == true {
            let snapshot = try splitter ?? bass().makeSpeakerBusSplitterSnapshot(sampleRate: rate)
            let feed = try XCTUnwrap(ProfileAncFeed(sampleRate: rate, splitter: snapshot, peakLimit: 1, fadeInSeconds: fade))
            let process = unsafeBitCast(
                N60AncLaneFeedProcess as @convention(c) (
                    UnsafeMutableRawPointer?, UnsafePointer<UnsafePointer<Float>>, UnsafePointer<UnsafeMutablePointer<Float>>,
                    UInt32, UInt32
                ) -> Int32,
                to: n60_external_process_fn.self)
            let raw = try XCTUnwrap(host.rawGraph)
            XCTAssertEqual(n60_graph_set_external_processor(
                OpaquePointer(raw), process, UnsafeMutableRawPointer(feed.pointer), ProfileAncFeed.channelCount), N60_STATUS_OK)
            host.retainedResource = feed
            switch drive {
            case .none: break
            case .tonal(let hz): armTonal(feed, rate: rate, hz: hz)
            case .feedForward: armFeedForward(feed, rate: rate)
            }
            // Production releases the rebuild hold with a re-arm revision change (updateHostedAnc).
            var rearmed = config
            rearmed.ancActuators?.rearmRevision = 1
            _ = try host.apply(try rearmed.makeSpec())
            var out = [[Float]](repeating: [], count: channels)
            var pushed: UInt64 = 0
            var done = 0
            while done < frames {
                if case .feedForward(let hz) = drive { pumpReference(feed, hz: hz, rate: rate, pushed: &pushed, ahead: 4 * block) }
                if let swapAt, let swapTo, done == swapAt { _ = try host.apply(try swapTo.makeSpec()) }
                let n = min(block, frames - done)
                var input = [[Float]](repeating: [Float](repeating: 0, count: n), count: channels)
                if let programme { for c in programmeLanes { input[c] = Array(programme[done..<(done + n)]) } }
                let result = try host.processOffline(input: input, frames: n)
                for c in 0..<channels { out[c] += result[c] }
                done += n
            }
            XCTAssertEqual(host.guardTripCount(stageIds: (0..<3).map { UnifiedGraphAncActuators.guardStageBase + $0 }), 0, "no guard trip (\(rate))")
            return out
        }
        var out = [[Float]](repeating: [], count: channels)
        var done = 0
        while done < frames {
            if let swapAt, let swapTo, done == swapAt { _ = try host.apply(try swapTo.makeSpec()) }
            let n = min(block, frames - done)
            var input = [[Float]](repeating: [Float](repeating: 0, count: n), count: channels)
            if let programme { for c in programmeLanes { input[c] = Array(programme[done..<(done + n)]) } }
            let result = try host.processOffline(input: input, frames: n)
            for c in 0..<channels { out[c] += result[c] }
            done += n
        }
        return out
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count)))
    }

    /// Reduction in dB of a primary `d` by the anti-noise `y` over the settled second half.
    private func reductionDB(primary d: [Float], antiNoise y: [Float]) -> Double {
        let h = d.count / 2
        let residual = zip(d, y).map { $0 + $1 }
        return 20 * log10(rms(d[h...]) / max(1e-12, rms(residual[h...])))
    }

    // MARK: 2.1 class A twin against the appSplitter twin

    /// The `.appSplitter` twin: the tonal runtime drive through `N60SpeakerBusRenderFeed`, summed over every bus (what
    /// one microphone hears from the mains plus the sub).
    private func appSplitterTwinSum(rate: Double, hz: Double, frames: Int, splitter: N60SpeakerBusSplitterSnapshot) -> [Float] {
        var tonal = N60ActiveQuietZoneSnapshotMakeBypassed()
        var tone = N60ActiveQuietZoneToneSnapshot()
        tone.frequencyHz = hz; tone.leftReal = 0.05; tone.rightReal = 0.05
        XCTAssertTrue(N60ActiveQuietZoneSnapshotSet(&tonal, &tone, 1, 64, rate, true))
        tonal.armGeneration = 1
        var runtime = N60ActiveQuietZoneRuntime()
        N60ActiveQuietZoneRuntimeReset(&runtime, rate)
        XCTAssertTrue(N60ActiveQuietZoneRuntimeSchedule(&runtime, &tonal, rate))
        var l = [Float](repeating: 0, count: frames), r = l
        let step = 1.0 / (fade * rate)
        var gain = 0.0
        for n in 0..<frames {
            N60ActiveQuietZoneRuntimeAccumulateProgramme(&runtime, 0, 0)
            var tl: Float = 0, tr: Float = 0
            N60ActiveQuietZoneRuntimeProcessFrame(&runtime, &tl, &tr)
            gain = min(1, gain + step)
            l[n] = max(-1, min(1, tl * Float(gain)))
            r[n] = max(-1, min(1, tr * Float(gain)))
        }
        func render(_ x: [Float], left: Bool) -> [Float] {
            var out = [Float](repeating: 0, count: frames * ThroughFeedSplitterRenderer.busCount)
            x.withUnsafeBufferPointer { i in
                out.withUnsafeMutableBufferPointer { o in
                    XCTAssertTrue(N60SpeakerBusRenderFeed(
                        i.baseAddress!, UInt32(frames), left, splitter, N60SpeakerDriverProcessingSnapshot(), o.baseAddress!))
                }
            }
            return out
        }
        let a = render(l, left: true), b = render(r, left: false)
        // Buses 0 and 1 are the unsplit full-range copies; the feed plays Low + Mid + High per side plus SubMono.
        let bc = ThroughFeedSplitterRenderer.busCount
        return (0..<frames).map { n in (2..<bc).reduce(Float(0)) { $0 + a[n * bc + $1] + b[n * bc + $1] } }
    }

    func testClassAFeedTwinMatchesTheAppSplitterTwinForTonalAtEveryRate() throws {
        for rate in rates {
            let splitter = try bass().makeSpeakerBusSplitterSnapshot(sampleRate: rate)
            let frames = max(2, Int(rate * 0.9) / block) * block
            for hz in [40.0, 120.0] {
                let twin = appSplitterTwinSum(rate: rate, hz: hz, frames: frames, splitter: splitter)
                let graph = try runGraph(rate: rate, config: hostedConfig(rate: rate, userGain: 1), drive: .tonal(hz), frames: frames)
                let classA = (0..<frames).map { graph[0][$0] + graph[1][$0] + graph[2][$0] }
                XCTAssertGreaterThan(rms(twin[(frames / 2)...]), 0.001, "twin plays \(hz) Hz at \(rate)")
                // A primary a quarter louder than the twin's anti-noise, so each twin leaves a 14 dB reduction.
                let primary = twin.map { -1.25 * $0 }
                let reductionTwin = reductionDB(primary: primary, antiNoise: twin)
                let reductionA = reductionDB(primary: primary, antiNoise: classA)
                XCTAssertEqual(reductionTwin, 14, accuracy: 0.5, "reference reduction at \(hz) Hz, \(rate)")
                XCTAssertEqual(reductionA, reductionTwin, accuracy: 1.0, "class A vs appSplitter, tonal \(hz) Hz at \(rate)")
                // The injected anti-noise leaves the graph untouched by the programme path.
                for source in 3...5 {
                    XCTAssertEqual(graph[source].map(abs).max() ?? 0, 0, accuracy: 0, "source lane \(source) is consumed (\(rate))")
                }
            }
        }
    }


    func testClassAFeedTwinMatchesTheAppSplitterTwinForFeedForwardBandsAtEveryRate() throws {
        for rate in rates {
            let splitter = try bass().makeSpeakerBusSplitterSnapshot(sampleRate: rate)
            let frames = Int(rate * 0.9) / block * block
            // 31.5 and 50 Hz trip the ANC_GUARD growth detector (gap G39), so they are not asserted here.
            for hz in [80.0, 125.0] {
                // The appSplitter twin of a feed-forward drive: the stand-alone feed-forward filter (same weights, same
                // reference, its own 10 ms ramp) through the feed's fade, then the shared bus splitter.
                let reference = referenceTone(hz: hz, rate: rate, index: 0, count: frames)
                var config = N60FeedForwardLiveConfig(
                    sampleRate: rate, maxBlockFrames: UInt32(block), kernelHalf: 0, swapFadeSeconds: 0, peakLimit: 1,
                    armRampSeconds: 0.01)
                let filter = try XCTUnwrap(N60FeedForwardLiveCreate(&config))
                defer { N60FeedForwardLiveDestroy(filter) }
                let w: [Float] = [-0.5, 0, 0, 0, 0, 0, 0, 0]
                XCTAssertTrue(N60FeedForwardLiveSetWeights(filter, w, w, 1))
                XCTAssertEqual(Int(N60FeedForwardLiveArm(filter, 0.010, 0.005)), Int(N60FeedForwardLiveArmOK))
                var driveL = [Float](repeating: 0, count: frames), driveR = driveL
                var pos = 0
                while pos < frames {
                    let n = min(block, frames - pos)
                    driveL.withUnsafeMutableBufferPointer { l in
                        driveR.withUnsafeMutableBufferPointer { r in
                            N60FeedForwardLiveProcess(filter, Array(reference[pos..<(pos + n)]), l.baseAddress! + pos, r.baseAddress! + pos, UInt32(n))
                        }
                    }
                    pos += n
                }
                let step = 1.0 / (fade * rate)
                var gain = 0.0
                for n in 0..<frames { gain = min(1, gain + step); driveL[n] *= Float(gain); driveR[n] *= Float(gain) }
                func busSum(_ x: [Float], left: Bool) -> [Float] {
                    var out = [Float](repeating: 0, count: frames * ThroughFeedSplitterRenderer.busCount)
                    x.withUnsafeBufferPointer { i in
                        out.withUnsafeMutableBufferPointer { o in
                            XCTAssertTrue(N60SpeakerBusRenderFeed(
                                i.baseAddress!, UInt32(frames), left, splitter, N60SpeakerDriverProcessingSnapshot(), o.baseAddress!))
                        }
                    }
                    let bc = ThroughFeedSplitterRenderer.busCount
                    return (0..<frames).map { n in (2..<bc).reduce(Float(0)) { $0 + out[n * bc + $1] } }
                }
                let twin = zip(busSum(driveL, left: true), busSum(driveR, left: false)).map { $0 + $1 }
                let graph = try runGraph(rate: rate, config: hostedConfig(rate: rate, userGain: 1), drive: .feedForward(hz), frames: frames)
                let classA = (0..<frames).map { graph[0][$0] + graph[1][$0] + graph[2][$0] }
                XCTAssertGreaterThan(rms(classA[(frames / 2)...]), 0.01, "feed-forward plays \(hz) Hz at \(rate)")
                let primary = twin.map { -1.25 * $0 }
                XCTAssertEqual(
                    reductionDB(primary: primary, antiNoise: classA), reductionDB(primary: primary, antiNoise: twin),
                    accuracy: 1.0, "class A vs appSplitter, feed-forward \(hz) Hz at \(rate)")
            }
        }
    }

    // MARK: Split agreement per filter family

    /// The impulse response of the graph's `BASS_MGMT` for a left impulse: left main plus the sub lane, summed.
    private func graphCombinedImpulse(rate: Double, hz: Double, seconds: Double) throws -> [Float] {
        var config = hostedConfig(rate: rate, userGain: 1, hostFed: false)
        config.bassManagement?.crossoverHz = hz
        // The graph's sub is the SUM of the main low-passes; the stereo bus splitter's is their MEAN (0.5 * (L + R)).
        // Level convention differs by 20 * log10(2) dB (G38); matching it here compares shape, gain slope and delay.
        config.bassManagement?.subwoofers[0].gainDB = -20 * log10(2.0)
        let frames = Int(seconds * rate) / block * block
        var impulse = [Float](repeating: 0, count: frames)
        impulse[0] = 1
        let out = try runGraph(rate: rate, config: config, drive: .none, frames: frames, programme: impulse, programmeLanes: [0])
        return (0..<frames).map { out[0][$0] + out[2][$0] }
    }

    func testBassMgmtAgreesWithTheBusSplitterForEveryFilterFamilyThatClassACanRun() throws {
        let seconds = SplitterVerificationSweep.tailSeconds
        for rate in rates {
            for hz in [60.0, 80.0, 120.0] {
                let graph = try graphCombinedImpulse(rate: rate, hz: hz, seconds: seconds)
                let bus = try ThroughFeedSplitterRenderer.combinedImpulseResponse(
                    feed: .left, bass: bass(.linkwitzRiley24, hz: hz), sampleRate: rate, seconds: seconds)
                let bandsGraph = CombinedPathBandAnalyzer.analyze(impulseResponse: graph, sampleRate: rate)
                let bandsBus = CombinedPathBandAnalyzer.analyze(impulseResponse: bus, sampleRate: rate)
                XCTAssertEqual(bandsGraph.count, bandsBus.count, "\(rate) \(hz)")
                var compared = 0
                for (g, b) in zip(bandsGraph, bandsBus)
                where g.lowHz >= SplitterRenderVerifier.defaultSweepRangeHz.lowerBound
                    && g.highHz <= SplitterRenderVerifier.defaultSweepRangeHz.upperBound {
                    XCTAssertEqual(g.gainDB, b.gainDB, accuracy: SplitterRenderVerifier.gainToleranceDB,
                                   "gain at \(g.centerHz) Hz, crossover \(hz), \(rate)")
                    if let dg = g.delaySeconds, let db = b.delaySeconds {
                        XCTAssertEqual(dg, db, accuracy: SplitterRenderVerifier.delayToleranceSeconds,
                                       "delay at \(g.centerHz) Hz, crossover \(hz), \(rate)")
                    }
                    compared += 1
                }
                XCTAssertGreaterThan(compared, 8, "bands compared (\(rate), \(hz))")
            }
        }
    }

    // MARK: Software-mode volume

    func testSoftwareVolumeLeavesTheAntiNoiseUnchangedFromMinus40ToZeroDB() throws {
        for rate in rates {
            let frames = Int(rate * 0.9) / block * block
            var reference: [[Float]]?
            for db in stride(from: -40.0, through: 0.0, by: 10.0) {
                let gain = Float(pow(10.0, db / 20.0))
                let out = try runGraph(rate: rate, config: hostedConfig(rate: rate, userGain: gain), drive: .tonal(60), frames: frames)
                if let reference {
                    for c in 0..<3 {
                        let worst = zip(out[c], reference[c]).map { abs($0 - $1) }.max() ?? 0
                        XCTAssertLessThan(worst, 1e-6, "anti-noise lane \(c) moved at \(db) dB, \(rate)")
                    }
                } else {
                    reference = out
                    XCTAssertGreaterThan(rms(out[2][(frames / 2)...]) + rms(out[0][(frames / 2)...]), 0.001, "anti-noise present")
                }
            }
        }
    }

    func testSoftwareVolumeProgrammeEqualsTodayWithRampsAtEveryRate() throws {
        for rate in rates {
            let frames = Int(rate * 0.9) / block * block
            let programme: [Float] = (0..<frames).map { Float(0.4 * sin(2 * Double.pi * 100 * Double($0) / rate)) }
            let swapAt = (frames / 2 / block) * block
            let gains: [(Float, Float)] = [(1, 0.01), (0.1, 0.5), (0.5, 1)]
            for (start, end) in gains {
                // Today: the volume is each programme lane's output gain, with no host feed.
                let today = try runGraph(
                    rate: rate, config: hostedConfig(rate: rate, userGain: 1, hostFed: false, laneGain: start), drive: .none,
                    frames: frames, programme: programme, swapAt: swapAt,
                    swapTo: hostedConfig(rate: rate, userGain: 1, hostFed: false, laneGain: end))
                // Host-fed, feed disarmed: the same volume sits in the OUTPUT_GAIN stages ahead of ANC_INJECT.
                let hosted = try runGraph(
                    rate: rate, config: hostedConfig(rate: rate, userGain: start), drive: .none, frames: frames,
                    programme: programme, swapAt: swapAt, swapTo: hostedConfig(rate: rate, userGain: end))
                for c in 0..<2 {
                    let worst = zip(today[c], hosted[c]).map { abs($0 - $1) }.max() ?? 0
                    XCTAssertLessThan(worst, 1e-6, "programme lane \(c) differs from today (\(start)->\(end)) at \(rate)")
                }
                XCTAssertGreaterThan(rms(hosted[0][(frames / 2)...]), 0.0001)
            }
        }
    }
}
