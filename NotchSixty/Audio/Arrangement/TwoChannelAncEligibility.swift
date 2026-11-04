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
        requiredReserveSeconds: Double = QuietZoneFeedForwardBudgetAnalyzer.requiredReserveSeconds
    ) -> TwoChannelAncEligibility {
        switch arrangement.arrangementClass {
        case .a:
            return .refused(reason: "Quiet Zone runs on the two-channel session; a separate output per speaker ends it.")
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
