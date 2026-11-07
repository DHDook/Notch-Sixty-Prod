import Foundation

// E26 S7c (`e26.sub-aware-anc`, on by default): the direct multi-output (class A) sub-path measurement. Two mains and
// one sub output, each on its own hardware output. Two seat passes (one per feed) play the splitter's output buses on
// the real outputs together and the seat microphone records the combined path; nine leakage passes (three outputs,
// three repeats each) play one output alone at the reference microphone. The nine are combined offline into the
// per-feed leakage the echo model needs, and kept per output so the stability bound sees each output separately.
//
// Realtime contract (AGENTS.md section 4): control plane only. Nothing here runs in or is called from an audio
// callback; the transport's bridge is the only realtime consumer and it is unchanged. Allocates. Sample rate: any,
// every quantity is in frames of the passed impulse responses. Channels: mono impulse responses. Reset: stateless.

enum SubPathMeasurement {
    /// One seat pass per feed.
    static let seatPassCount = 2
    /// Three outputs, `FeedForwardEchoModel.minimumRepeats` repeats each.
    static let leakageRepeats = FeedForwardEchoModel.minimumRepeats
    static let leakagePassCount = 3 * leakageRepeats

    static let timeNote = "2 seat passes and 9 leakage passes, about 3 minutes."
    static let shapeRefusal = TwoChannelAncArming.classAShapeRefusal
    static let asymmetricSubText =
        "Your sub plays different bass for the left and right feeds, so the leakage cannot be combined. Check the bass settings."

    enum PlanError: Error, Equatable, LocalizedError {
        case unsupportedShape
        var errorDescription: String? { SubPathMeasurement.shapeRefusal }
    }

    /// Which hardware output channel is the left main, right main and the sub, from the live route plan. Refuses
    /// anything but the v1 shape (two mains plus one sub output).
    static func outputMap(routePlan: LiveNChannelOutputRoutePlan) throws -> SubActuatorOutputMap {
        let roles = routePlan.programLayout.roles
        // A live plan pads its arrays (program to the maximum channels, subs to at least four entries), so the sub count,
        // not the array length, says how many subs are routed.
        guard routePlan.subwooferCount == 1, routePlan.subwooferPhysicalChannels.count >= 1,
              let left = roles.firstIndex(of: .frontLeft), let right = roles.firstIndex(of: .frontRight),
              left < routePlan.programPhysicalChannels.count, right < routePlan.programPhysicalChannels.count
        else { throw PlanError.unsupportedShape }
        let map = SubActuatorOutputMap(
            leftOutput: routePlan.programPhysicalChannels[left],
            rightOutput: routePlan.programPhysicalChannels[right],
            subOutput: routePlan.subwooferPhysicalChannels[0])
        try map.validate(outputChannelCount: Int(routePlan.physicalChannelCount))
        return map
    }

    /// One seat pass: the transport plays `plan.primary` as the sweep and `lanes` beside it, the analysis divides the
    /// capture by the dry sweep, so the result is the combined seat path of `feed`.
    struct SeatPass: Equatable, Sendable {
        var feed: ThroughFeedSplitterRenderer.Feed
        var plan: SubActuatorMultibusSweepPlan
    }

    static func seatPasses(
        program: RoomCorrectionSweepProgram, bass: BassManagementConfiguration, map: SubActuatorOutputMap,
        outputChannelCount: Int
    ) throws -> [SeatPass] {
        try [ThroughFeedSplitterRenderer.Feed.left, .right].map { feed in
            let rendered = try ThroughFeedSplitterRenderer.render(
                program.sweepSamples, feed: feed, bass: bass, sampleRate: program.sampleRate)
            return SeatPass(
                feed: feed,
                plan: try SubActuatorMultibusSweepPlan.make(
                    rendered: rendered, map: map, outputChannelCount: outputChannelCount))
        }
    }

    /// One single-output leakage pass signal per output. The left main plays the left feed's left bus content, the
    /// right main the right feed's, and the sub the left feed's sub bus (the two sub buses are confirmed equal by the
    /// asymmetric-feeds check). Order: left main, right main, sub.
    static func leakageSignals(passes: [SeatPass]) throws -> [SubActuatorOutputSignal] {
        let left = passes.first { $0.feed == .left }, right = passes.first { $0.feed == .right }
        func signal(_ pass: SeatPass?, _ role: SubActuatorOutputSignal.Role) -> SubActuatorOutputSignal? {
            pass?.plan.leakagePasses.first { $0.role == role }
        }
        guard let l = signal(left, .leftMain), let r = signal(right, .rightMain), let s = signal(left, .sub)
        else { throw PlanError.unsupportedShape }
        return [l, r, s]
    }

    /// Per-feed leakage from the per-output leakage repeats: left = left main + sub, right = right main + sub. The
    /// passes played each output's bus content and were analysed against the dry sweep, so each impulse response
    /// already contains the feed-to-output bus; summing (zero-padded to the longest) is the combined feed leakage.
    static func composeFeeds(
        leftMain: [[Float]], rightMain: [[Float]], sub: [[Float]]
    ) -> (left: [[Float]], right: [[Float]]) {
        func add(_ a: [Float], _ b: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: max(a.count, b.count))
            for i in 0..<a.count { out[i] += a[i] }
            for i in 0..<b.count { out[i] += b[i] }
            return out
        }
        let n = min(leftMain.count, rightMain.count, sub.count)
        return ((0..<n).map { add(leftMain[$0], sub[$0]) }, (0..<n).map { add(rightMain[$0], sub[$0]) })
    }

    /// The echo model for a class A rig: composed per feed (so every existing consumer works unchanged) and the
    /// per-output paths kept for the stability bound.
    static func echoModel(
        leftMain: [[Float]], rightMain: [[Float]], sub: [[Float]], map: SubActuatorOutputMap,
        nativeSampleRate: Double, capturedAt: Date
    ) throws -> FeedForwardEchoModel {
        let composed = composeFeeds(leftMain: leftMain, rightMain: rightMain, sub: sub)
        var model = try FeedForwardEchoModelBuilder.build(
            left: composed.left, right: composed.right, nativeSampleRate: nativeSampleRate, capturedAt: capturedAt)
        let factor = Int(N60AncDecimationFactor(nativeSampleRate))
        let fd = nativeSampleRate / Double(max(factor, 1))
        func path(_ repeats: [[Float]]) throws -> FeedForwardEchoPath {
            try FeedForwardEchoModelBuilder.side(repeats, nativeSampleRate: nativeSampleRate, factor: factor, fd: fd).path
        }
        model.outputs = [
            FeedForwardOutputEcho(role: "leftMain", outputChannel: Int(map.leftOutput), feeds: [0], path: try path(leftMain)),
            FeedForwardOutputEcho(role: "rightMain", outputChannel: Int(map.rightOutput), feeds: [1], path: try path(rightMain)),
            FeedForwardOutputEcho(role: "sub", outputChannel: Int(map.subOutput), feeds: [0, 1], path: try path(sub)),
        ]
        return model
    }

    /// The stored records: the two seat paths and one leakage record per output (mean of its repeats).
    static func records(
        seatLeft: [Float], seatRight: [Float], leftMain: [[Float]], rightMain: [[Float]], sub: [[Float]],
        map: SubActuatorOutputMap, sampleRate: Double, fingerprint: AncBassPathFingerprint
    ) -> [CombinedAncPathRecord] {
        func record(
            _ source: CombinedAncPathRecord.Source, _ destination: CombinedAncPathRecord.Destination, _ ir: [Float],
            channel: Int? = nil, role: CombinedAncPathRecord.OutputRole? = nil
        ) -> CombinedAncPathRecord {
            CombinedAncPathRecord(
                source: source, destination: destination, windowSeconds: Double(ir.count) / sampleRate + 1.0 / sampleRate,
                sampleRate: sampleRate, fingerprint: fingerprint, impulseResponse: ir, outputChannel: channel,
                outputRole: role)
        }
        func mean(_ repeats: [[Float]]) -> [Float] {
            let length = repeats.map(\.count).max() ?? 0
            var out = [Float](repeating: 0, count: length)
            for r in repeats { for i in 0..<r.count { out[i] += r[i] } }
            return out.map { $0 / Float(max(repeats.count, 1)) }
        }
        let all: [CombinedAncPathRecord] = [
            record(.feedLeft, .seatMicrophone, seatLeft),
            record(.feedRight, .seatMicrophone, seatRight),
            record(.outputLeakage, .referenceMicrophone, mean(leftMain), channel: Int(map.leftOutput), role: .leftMain),
            record(.outputLeakage, .referenceMicrophone, mean(rightMain), channel: Int(map.rightOutput), role: .rightMain),
            record(.outputLeakage, .referenceMicrophone, mean(sub), channel: Int(map.subOutput), role: .sub),
        ]
        return all.filter(\.isValid)
    }
}
