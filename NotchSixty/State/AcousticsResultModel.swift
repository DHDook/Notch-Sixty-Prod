import Foundation

// E12 S20 (flag `e12.active-acoustics-page`): the plain result line on each Active Acoustics tab, a short in-memory
// history of results, and the wiring that writes arm, disarm, guard trips and bypass to the session event history.
// Control plane only: nothing here reaches the engine or arms anything.

/// One plain result: a sentence and whether it is an estimate (an estimate says so in words).
struct AcousticsResultLine: Equatable, Identifiable, Sendable {
    var text: String
    var isEstimate: Bool
    var id: String { text }

    /// The sentence as shown: an estimate carries the word.
    var displayText: String { isEstimate ? "\(text) (estimate)" : text }
}

enum AcousticsResultModel {
    /// Quiet Zone: the strongest measured tone, from the error microphone. Nil when there is no measurement.
    static func quietZone(tones: [ActiveQuietZoneToneTelemetry]) -> AcousticsResultLine? {
        let measured = tones.filter { $0.measuredReductionDB.isFinite }
        guard let best = measured.max(by: { $0.measuredReductionDB < $1.measuredReductionDB }) else { return nil }
        guard best.measuredReductionDB >= 1 else {
            return AcousticsResultLine(text: "No measurable reduction at your seat yet", isEstimate: false)
        }
        let hz = Int(best.frequencyHz.rounded())
        let db = Int(best.measuredReductionDB.rounded())
        return AcousticsResultLine(text: "\(hz) Hz hum: \(db) dB quieter at your seat", isEstimate: false)
    }

    /// Playback Adaptation: what the applied target does to the music. Nil when off, held or not changing anything.
    static func playbackAdaptation(target: AmbientCompensationTarget, monitoring: Bool) -> AcousticsResultLine? {
        guard monitoring, target.holdReason == nil else { return nil }
        switch target.mode {
        case .conversationFocus:
            if target.levelDB <= -0.5 {
                return AcousticsResultLine(
                    text: "Music turned down \(Int((-target.levelDB).rounded())) dB for conversation", isEstimate: false)
            }
            if target.estimatedClearanceDB >= 0.5 {
                return AcousticsResultLine(
                    text: "Music reshaped for conversation: about \(Int(target.estimatedClearanceDB.rounded())) dB clearer speech",
                    isEstimate: true)
            }
            return nil
        case .musicFocus:
            guard target.levelDB >= 0.5 else { return nil }
            return AcousticsResultLine(
                text: "Music turned up \(Int(target.levelDB.rounded())) dB to stay clear of room noise", isEstimate: false)
        default:
            return nil
        }
    }

    /// Room Treatment: the predicted decay change and, after a repeat measurement, the measured one.
    static func roomTreatment(
        predicted: [MIMOTreatmentController.SeatDecay], measured: [MIMOTreatmentController.SeatDecay]
    ) -> [AcousticsResultLine] {
        var lines: [AcousticsResultLine] = []
        if let pair = medianPair(predicted) {
            lines.append(AcousticsResultLine(
                text: String(format: "Bass decay %.2f s to %.2f s at your seats", pair.before, pair.after), isEstimate: true))
        }
        if let pair = medianPair(measured) {
            lines.append(AcousticsResultLine(
                text: String(format: "Measured after repeat measurement: bass decay %.2f s to %.2f s", pair.before, pair.after),
                isEstimate: false))
        }
        return lines
    }

    private static func medianPair(_ decays: [MIMOTreatmentController.SeatDecay]) -> (before: Double, after: Double)? {
        func median(_ values: [Double]) -> Double? {
            let sorted = values.sorted()
            return sorted.isEmpty ? nil : sorted[sorted.count / 2]
        }
        guard let before = median(decays.compactMap(\.beforeSeconds)),
              let after = median(decays.compactMap(\.afterSeconds)) else { return nil }
        return (before, after)
    }
}

/// The last few results per tab, newest last. In memory; a result equal to the previous one is not repeated.
struct AcousticsResultHistory: Equatable, Sendable {
    struct Entry: Equatable, Identifiable, Sendable {
        let id = UUID()
        var tab: ActiveAcousticsTab
        var line: AcousticsResultLine
        var time: Date
    }

    static let capacityPerTab = 5
    private(set) var entries: [Entry] = []

    func entries(for tab: ActiveAcousticsTab) -> [Entry] { entries.filter { $0.tab == tab } }

    mutating func record(_ line: AcousticsResultLine, tab: ActiveAcousticsTab, at time: Date) {
        if entries(for: tab).last?.line == line { return }
        entries.append(Entry(tab: tab, line: line, time: time))
        let mine = entries(for: tab)
        if mine.count > Self.capacityPerTab, let oldest = mine.first {
            entries.removeAll { $0.id == oldest.id }
        }
    }
}

@MainActor
final class AcousticsResultsStore: ObservableObject {
    @Published private(set) var history = AcousticsResultHistory()

    func record(_ lines: [AcousticsResultLine], tab: ActiveAcousticsTab, now: Date = Date()) {
        var next = history
        for line in lines { next.record(line, tab: tab, at: now) }
        if next != history { history = next }
    }
}

/// Writes Active Acoustics arm, disarm, guard trips and bypass to the session event history (E33 S16) in plain words.
@MainActor
enum ActiveAcousticsEventWiring {
    static func attach(
        quietZone: ActiveQuietZoneController, treatment: MIMOTreatmentController, flags: FeatureFlags,
        history: SessionEventHistory? = nil
    ) {
        guard flags.isEnabled(.activeAcousticsPage) else { return }
        let sink: @MainActor (String) -> Void = { sentence in
            (history ?? ProductionMeterHub.eventHistory).noteTreatment(sentence)
        }
        quietZone.onSessionEvent = sink
        treatment.onSessionEvent = sink
    }
}
