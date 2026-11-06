import Foundation

// E25 S6: Quiet Zone eligibility and the MIMO source set on a two-channel arrangement. Pure and control-plane only:
// it answers "could Quiet Zone be considered" and never arms, enables or schedules anything. Live ANC stays behind its
// own written authorisation path (E4 S25 arming); an `.eligible` result grants nothing.
enum TwoChannelAncEligibility: Equatable, Sendable {
    /// The measured end-to-end feed fits the budget. `reserveSeconds` is what remains after the required reserve.
    case eligible(reserveSeconds: Double)
    case refused(reason: String)

    /// `feedLatencyUpperBoundSeconds` is the measured upper bound of the whole feed (reference capture, processing, DAC
    /// and any receiver); `conservativePreviewSeconds` is the survey's conservative acoustic head start. Specified in
    /// seconds, so the answer is the same at every device rate; use `seconds(frames:sampleRate:)` for frame counts.
    static func evaluate(
        arrangement: SystemArrangement,
        feedLatencyUpperBoundSeconds: Double?,
        conservativePreviewSeconds: Double?,
        requiredReserveSeconds: Double = QuietZoneFeedForwardBudgetAnalyzer.requiredReserveSeconds,
        allowClassA: Bool = false
    ) -> TwoChannelAncEligibility {
        switch arrangement.arrangementClass {
        case .a:
            // E26 S7c: with sub-aware ANC on, the v1 shape (two mains and one sub output) is let through.
            if allowClassA {
                if !arrangement.isTwoMainsOneSub { return .refused(reason: TwoChannelAncArming.classAShapeRefusal) }
            } else {
                return .refused(reason: "Quiet Zone runs on the two-channel session; a separate output per speaker ends it.")
            }
        case .b, .c, .d, .e:
            break
        }
        let viaReceiver = arrangement.arrangementClass == .d || arrangement.arrangementClass == .e
        guard let latency = feedLatencyUpperBoundSeconds, latency.isFinite, latency >= 0 else {
            return .refused(reason: viaReceiver
                ? "Measure the whole feed through your receiver first: its latency counts against the Quiet Zone budget."
                : "Measure the feed latency first.")
        }
        guard let preview = conservativePreviewSeconds, preview.isFinite, preview > 0 else {
            return .refused(reason: "Complete the Quiet Zone timing survey first.")
        }
        let reserve = preview - latency - requiredReserveSeconds
        guard reserve >= 0 else {
            let over = String(format: "%.1f", -reserve * 1000)
            return .refused(reason: (viaReceiver ? "The receiver's latency leaves " : "The feed latency leaves ")
                + "too little time before the noise arrives (short by \(over) ms). "
                + (viaReceiver ? "Switch off the receiver's processing or its delay features, then measure again."
                               : "Shorten the processing path, then measure again."))
        }
        return .eligible(reserveSeconds: reserve)
    }

    static func seconds(frames: Int, sampleRate: Double) -> Double {
        sampleRate > 0 ? Double(frames) / sampleRate : .infinity
    }
}

enum TwoChannelMimoSources {
    /// Two-channel arrangements (classes B to E) offer only the left and right feeds; a downstream subwoofer is not
    /// independent, so it is never a source. Direct multi-output (class A) keeps the full set.
    static func restrict(
        _ sources: [MultichannelCalibrationSource], arrangement: SystemArrangement?
    ) -> [MultichannelCalibrationSource] {
        guard let arrangement, arrangement.arrangementClass != .a else { return sources }
        let feeds: [MultichannelCalibrationSource] = [.speaker(.frontLeft), .speaker(.frontRight)]
        return feeds.filter { sources.contains($0) }
    }
}

extension SystemArrangement {
    /// E25 S8b: a subwoofer the DSP does not drive (a powered sub's crossover, or a receiver's subs) still carries the
    /// bass the anti-noise would have to cancel. Class D always; class E when it has subs. Live Quiet Zone refuses it
    /// until sub-aware ANC exists (owner decision of 3 Nov 2026, question 18; E26).
    var hasDownstreamSubwoofer: Bool {
        switch arrangementClass {
        case .d: return true
        case .e: return subwooferCount > 0
        case .a, .b, .c: return false
        }
    }
}

extension SystemArrangement {
    /// E26 S7c: the one direct multi-output shape Quiet Zone supports in v1: a stereo pair of mains plus exactly one sub
    /// output that the DSP drives through bass management.
    var isTwoMainsOneSub: Bool {
        arrangementClass == .a && layout == .stereo && bass == .dspToSubOutputs && outputs.channelsInUse >= 3
            && subOutputs.count == 1
    }
}

enum TwoChannelAncArming {
    static let classAShapeRefusal = "Quiet Zone supports two speakers and one subwoofer output."
    static let subwooferRefusal = "not available with a subwoofer yet"
    /// E26 S1: always on, not flag-gated. The caps cannot be trusted without knowing how the receiver handles bass.
    static let undeclaredReceiverRefusal = "Tell Notch Sixty how your receiver handles bass."

    /// What the Quiet Zone readiness card and the arming policy show for the stored arrangement. nil: nothing to add
    /// (no arrangement). A downstream sub refuses first (asking for the receiver declaration while it is missing);
    /// otherwise an eligibility refusal.
    static func refusal(
        arrangement: SystemArrangement?, budget: QuietZoneFeedForwardBudget, subAware: Bool = false
    ) -> String? {
        guard let arrangement else { return nil }
        if arrangement.hasDownstreamSubwoofer, !(subAware && arrangement.receiverBass.isDeclared) {
            return arrangement.receiverBass.isDeclared
                ? "Quiet Zone is \(subwooferRefusal)." : undeclaredReceiverRefusal
        }
        if case .refused(let reason) = TwoChannelAncEligibility.evaluate(
            arrangement: arrangement, feedLatencyUpperBoundSeconds: budget.antiNoisePathSeconds,
            conservativePreviewSeconds: budget.conservativePreviewSeconds, allowClassA: subAware) {
            return reason
        }
        return nil
    }
}
