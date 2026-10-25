import XCTest
@testable import NotchSixty

/// E6 S9c: headphone profile edits while a binaural session runs on the graph. Behavioural: real graphs, real blocks,
/// every standard rate.
final class LiveHeadphoneProfileTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func profile(_ edit: (inout HeadphoneDeviceProfileConfiguration) -> Void = { _ in })
        -> HeadphoneDeviceProfileConfiguration {
        var profile = HeadphoneDeviceProfileConfiguration()
        profile.programLayout = .fiveOne
        profile.spatialMode = .virtualSpeakers
        edit(&profile)
        return profile
    }

    private func base(
        _ rate: Double, _ profile: HeadphoneDeviceProfileConfiguration, asset: BinauralProfileAsset? = nil
    ) throws -> UnifiedGraphSpec {
        try UnifiedGraphTranslator.binauralBaseSpec(
            asset: asset ?? BinauralProfileAsset.validationStereo(sampleRate: rate), layout: .fiveOne,
            profile: profile, outputChannels: 2, sampleRate: rate, headTracking: false).get()
    }

    private func tone(_ rate: Double, start: Int) -> [Float] {
        (0..<block).map { 0.2 * Float(sin(2.0 * .pi * 1_000.0 * Double(start + $0) / rate)) }
    }

    /// Both ear outputs for `seconds` of a 1 kHz tone on lane 0.
    @discardableResult
    private func run(_ host: UnifiedGraphHost, rate: Double, seconds: Double, from position: inout Int) throws -> [[Float]] {
        let total = Int(rate * seconds) / block * block
        var ears: [[Float]] = [[], []]
        var done = 0
        while done < total {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: 6)
            input[0] = tone(rate, start: position)
            let out = try host.processOffline(input: input, frames: block)
            ears[0] += out[0]; ears[1] += out[1]
            position += block; done += block
        }
        return ears
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    /// Frame index of the largest magnitude in `x`.
    private func peakIndex(_ x: [Float]) -> Int {
        x.indices.max { abs(x[$0]) < abs(x[$1]) } ?? 0
    }

    private func impulseResponse(_ host: UnifiedGraphHost, seconds: Double, rate: Double) throws -> [[Float]] {
        var ears: [[Float]] = [[], []]
        let total = Int(rate * seconds) / block * block
        var done = 0
        while done < total {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: 6)
            if done == 0 { input[0][0] = 0.5 }
            let out = try host.processOffline(input: input, frames: block)
            ears[0] += out[0]; ears[1] += out[1]
            done += block
        }
        return ears
    }

    // MARK: edits

    func testLiveEQAndGainEditMatchesAFreshBuildAfterTheFade() throws {
        for rate in Self.rates {
            let before = profile()
            let after = profile {
                $0.left.gainDB = -3
                $0.left.eqBands = [HeadphoneCorrectionEQBand(type: .peaking, frequencyHz: 1_000, gainDB: -4, q: 1)]
                $0.right.polarityInverted = true
            }
            let startSpec = try base(rate, before)
            let editedSpec = try UnifiedGraphTranslator.binauralApplyHeadphone(
                base: startSpec, profile: after).get()
            let live = try UnifiedGraphHost(spec: startSpec)
            var position = 0
            try run(live, rate: rate, seconds: 0.1, from: &position)
            _ = try live.apply(editedSpec)
            try run(live, rate: rate, seconds: 0.5, from: &position)
            let liveTail = try run(live, rate: rate, seconds: 0.3, from: &position)

            let fresh = try UnifiedGraphHost(spec: try base(rate, after))
            var freshPosition = 0
            try run(fresh, rate: rate, seconds: 0.6, from: &freshPosition)
            let freshTail = try run(fresh, rate: rate, seconds: 0.3, from: &freshPosition)
            for ear in 0..<2 {
                let a = rms(liveTail[ear][(liveTail[ear].count / 2)...])
                let b = rms(freshTail[ear][(freshTail[ear].count / 2)...])
                XCTAssertGreaterThan(b, 0, "rate \(rate)")
                XCTAssertEqual(a, b, accuracy: max(b * 0.03, 1e-6), "ear \(ear) at \(rate)")
            }
            live.release(); fresh.release()
        }
    }

    func testLiveEditNeverStepsAboveTheRampSlope() throws {
        for rate in Self.rates {
            let start = try base(rate, profile())
            let edits: [(String, HeadphoneDeviceProfileConfiguration)] = [
                ("gain", profile { $0.left.gainDB = -6 }),
                ("eq", profile { $0.left.eqBands = [HeadphoneCorrectionEQBand(type: .peaking, frequencyHz: 1_000, gainDB: 3, q: 1)]
                    $0.headroomAttenuationDB = 6 }),
                ("delay", profile { $0.left.delayMilliseconds = 2; $0.right.delayMilliseconds = 1 }),
            ]
            for (name, edited) in edits {
                let host = try UnifiedGraphHost(spec: start)
                var position = 0
                try run(host, rate: rate, seconds: 0.1, from: &position)
                _ = try host.apply(try UnifiedGraphTranslator.binauralApplyHeadphone(base: start, profile: edited).get())
                let out = try run(host, rate: rate, seconds: 0.5, from: &position)
                let slope = Float(0.45 * 2.0 * .pi * 1_000.0 / rate)
                var maxStep: Float = 0
                for ear in 0..<2 {
                    for index in 1..<out[ear].count { maxStep = max(maxStep, abs(out[ear][index] - out[ear][index - 1])) }
                }
                XCTAssertLessThan(maxStep, 4 * slope + 1e-3, "\(name) at \(rate)")
                host.release()
            }
        }
    }

    func testCrossfeedEditIsInertInVirtualSpeakersMode() throws {
        let rate = 48_000.0
        let start = try base(rate, profile())
        let edited = profile { $0.crossfeed.preset = .wide; $0.crossfeed.amount = 0.5 }
        let applied = try UnifiedGraphTranslator.binauralApplyHeadphone(base: start, profile: edited).get()
        XCTAssertEqual(applied, start)
        let host = try UnifiedGraphHost(spec: start)
        XCTAssertEqual(try host.apply(applied), .unchanged)
        host.release()
    }

    // MARK: channel delay

    func testChannelDelayMatchesTheLegacyDelayFramesAtEveryRate() throws {
        for rate in Self.rates {
            let delayed = profile { $0.left.delayMilliseconds = 2.5 }
            let expected = Int(llround(rate * 2.5 * 0.001))
            XCTAssertGreaterThan(expected, 0)

            let plain = try UnifiedGraphHost(spec: try base(rate, profile()))
            let late = try UnifiedGraphHost(spec: try base(rate, delayed))
            let a = try impulseResponse(plain, seconds: 0.1, rate: rate)
            let b = try impulseResponse(late, seconds: 0.1, rate: rate)
            XCTAssertEqual(peakIndex(b[0]) - peakIndex(a[0]), expected, "left ear at \(rate)")
            XCTAssertEqual(peakIndex(b[1]), peakIndex(a[1]), "right ear unchanged at \(rate)")
            plain.release(); late.release()
        }
    }

    func testDelayEditIsAPostedParameter() throws {
        let rate = 48_000.0
        let start = try base(rate, profile())
        let host = try UnifiedGraphHost(spec: start)
        let edited = try UnifiedGraphTranslator.binauralApplyHeadphone(
            base: start, profile: profile { $0.right.delayMilliseconds = 3 }).get()
        guard case .posted = try host.apply(edited) else { return XCTFail("a delay edit must not rebuild") }
        host.release()
    }

    // MARK: refusals

    func testHeadroomAboveThirtyAndHugeDelayAreRefusedAndTheRunningGraphKeepsRendering() throws {
        let rate = 48_000.0
        let start = try base(rate, profile())
        let host = try UnifiedGraphHost(spec: start)
        var position = 0
        try run(host, rate: rate, seconds: 0.1, from: &position)
        for bad in [profile { $0.headroomAttenuationDB = 31 }, profile { $0.left.delayMilliseconds = 100 }] {
            guard case .failure(let reason) = UnifiedGraphTranslator.binauralApplyHeadphone(base: start, profile: bad) else {
                return XCTFail("the stages cannot reproduce this profile")
            }
            XCTAssertEqual(reason, .headphoneDSP)
        }
        XCTAssertEqual(host.spec, start)
        let tail = try run(host, rate: rate, seconds: 0.2, from: &position)
        XCTAssertGreaterThan(rms(tail[0][(tail[0].count / 2)...]), 0.01)
        host.release()
    }

    // MARK: asset swap

    func testAssetSwapRendersLikeAFreshBuildAfterTheFade() throws {
        for rate in Self.rates {
            let first = BinauralProfileAsset.validationStereo(sampleRate: rate)
            var second = BinauralProfileAsset.validationStereo(sampleRate: rate)
            second.id = UUID()
            second.measurements = second.measurements.map {
                var m = $0
                m.leftIR = m.leftIR.map { $0 * 0.5 }
                m.rightIR = m.rightIR.map { $0 * 0.5 }
                return m
            }
            let p = profile()
            let live = try UnifiedGraphHost(spec: try base(rate, p, asset: first))
            var position = 0
            try run(live, rate: rate, seconds: 0.1, from: &position)
            _ = try live.apply(try base(rate, p, asset: second))
            try run(live, rate: rate, seconds: 0.5, from: &position)
            let liveTail = try run(live, rate: rate, seconds: 0.3, from: &position)

            let fresh = try UnifiedGraphHost(spec: try base(rate, p, asset: second))
            var freshPosition = 0
            try run(fresh, rate: rate, seconds: 0.6, from: &freshPosition)
            let freshTail = try run(fresh, rate: rate, seconds: 0.3, from: &freshPosition)
            for ear in 0..<2 {
                let a = rms(liveTail[ear][(liveTail[ear].count / 2)...])
                let b = rms(freshTail[ear][(freshTail[ear].count / 2)...])
                XCTAssertGreaterThan(b, 0, "rate \(rate)")
                XCTAssertEqual(a, b, accuracy: max(b * 0.03, 1e-6), "ear \(ear) at \(rate)")
            }
            live.release(); fresh.release()
        }
    }

    func testResampledAssetCacheConvertsEachAssetAndRateOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n60-hrtf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BinauralProfileAssetStore(rootURL: root)
        let reference = try store.save(BinauralProfileAsset.validationStereo(sampleRate: 44_100))
        let cache = BinauralResampledAssetCache(capacity: 2)
        for rate in [48_000.0, 96_000.0, 48_000.0, 96_000.0] {
            let asset = try cache.asset(for: reference, sampleRate: rate, store: store)
            XCTAssertEqual(asset.sampleRate, rate, accuracy: 0.5)
        }
        XCTAssertEqual(cache.conversionCount, 2)
        // A third rate evicts the least recently used pair (capacity 2): 48 kHz converts again.
        _ = try cache.asset(for: reference, sampleRate: 192_000, store: store)
        _ = try cache.asset(for: reference, sampleRate: 48_000, store: store)
        XCTAssertEqual(cache.conversionCount, 4)
        var wrong = reference
        wrong.tapCount += 1
        XCTAssertThrowsError(try cache.asset(for: wrong, sampleRate: 352_800, store: store))
    }

    // MARK: engine decision (what the running engine does with a change)

    private func context(
        flag: Bool = true, running: Bool = true, session: HeadphoneLiveEditPlanner.BinauralSession = .graph,
        nChannel: Bool = false
    ) -> HeadphoneLiveEditPlanner.Context {
        .init(unifiedGraphEnabled: flag, lifecycleRunning: running, binauralSession: session, nChannelSessionActive: nChannel)
    }

    func testPlannerDecisions() {
        var old = profile { $0.enabled = true; $0.outputDeviceUID = "out" }
        old.binauralProfile = BinauralProfileAsset.validationStereo().reference
        func plan(_ new: HeadphoneDeviceProfileConfiguration?, _ ctx: HeadphoneLiveEditPlanner.Context)
            -> HeadphoneLiveEditPlan { HeadphoneLiveEditPlanner.plan(from: old, to: new, context: ctx) }

        XCTAssertEqual(plan(old, context(flag: false)), .unchanged)
        var eq = old; eq.left.gainDB = -2; eq.name = "Renamed"; eq.crossfeed.amount = 0.4
        XCTAssertEqual(plan(eq, context()), .liveEdit(assetChanged: false))
        var asset = old; asset.binauralProfile = BinauralProfileAsset.validationStereo().reference
        XCTAssertEqual(plan(asset, context()), .liveEdit(assetChanged: true))

        // Session-kind changes reconfigure.
        XCTAssertEqual(plan(nil, context()), .reconfigure)
        var stereo = old; stereo.spatialMode = .stereo
        XCTAssertEqual(plan(stereo, context()), .reconfigure)
        var layout = old; layout.programLayout = .sevenOne
        XCTAssertEqual(plan(layout, context()), .reconfigure)
        var tracked = old; tracked.headTracking = HeadTrackingConfiguration()
        XCTAssertEqual(plan(tracked, context()), .reconfigure)

        // Nothing changes while the flag is off, the session is not running or it is not on the graph.
        XCTAssertEqual(plan(eq, context(flag: false)), .refuse)
        XCTAssertEqual(plan(eq, context(running: false)), .refuse)
        XCTAssertEqual(plan(eq, context(session: .legacy)), .refuse)
        XCTAssertEqual(plan(eq, context(nChannel: true)), .refuse)
        XCTAssertEqual(plan(nil, context(session: .legacy)), .refuse)

        // From no headphone session only Virtual Speakers on reconfigures.
        XCTAssertEqual(HeadphoneLiveEditPlanner.plan(from: nil, to: old, context: context(session: .none)), .reconfigure)
        XCTAssertEqual(HeadphoneLiveEditPlanner.plan(from: nil, to: stereo, context: context(session: .none)), .refuse)
        XCTAssertEqual(HeadphoneLiveEditPlanner.plan(from: nil, to: old, context: context(flag: false, session: .none)), .refuse)
    }
}
