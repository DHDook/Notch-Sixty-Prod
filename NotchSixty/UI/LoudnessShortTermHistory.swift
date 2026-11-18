import SwiftUI

/// E33 S7 (design 17, C5, C6): the short-term loudness of the last 10 minutes at one point per second, and the
/// target the card draws a line at. Pure State, no clock of its own: the Meters page feeds it.
struct LoudnessShortTermHistory: Equatable, Sendable {
    static let windowSeconds = 600.0
    static let pointIntervalSeconds = 1.0
    static var capacity: Int { Int(windowSeconds / pointIntervalSeconds) }

    struct Point: Equatable, Sendable {
        var time: Double
        /// LUFS; nil while the 3 s window had not filled (a gap in the line).
        var lufs: Double?
    }

    private(set) var points: [Point] = []

    /// Adds one point when at least a second has passed since the last; drops points older than 10 minutes.
    mutating func ingest(_ shortTerm: Double?, at now: Double) {
        if let last = points.last, now - last.time < Self.pointIntervalSeconds { return }
        points.append(Point(time: now, lufs: shortTerm.flatMap { $0.isFinite ? $0 : nil }))
        let oldest = now - Self.windowSeconds
        if let first = points.firstIndex(where: { $0.time > oldest }), first > 0 {
            points.removeFirst(first)
        }
        if points.count > Self.capacity { points.removeFirst(points.count - Self.capacity) }
    }

    mutating func reset() { points.removeAll(keepingCapacity: true) }
}

/// The target line on the loudness history: the Loudness Match target when that stage is on, else a chosen
/// streaming or broadcast value.
enum LoudnessHistoryTarget: Int, CaseIterable, Identifiable, Sendable {
    case minus14 = -14, minus16 = -16, minus23 = -23

    var id: Int { rawValue }
    var lufs: Double { Double(rawValue) }
    var title: String { "\(rawValue) LUFS" }
    static let `default` = LoudnessHistoryTarget.minus16

    static func stored() -> LoudnessHistoryTarget {
        LoudnessHistoryTarget(rawValue: UserDefaults.standard.integer(forKey: PreferenceKeys.Meters.loudnessTarget)) ?? .default
    }

    /// The Loudness Match target if that stage is on, else the chosen value.
    static func lufs(matchEnabled: Bool, matchTarget: Double, chosen: LoudnessHistoryTarget) -> (lufs: Double, fromMatch: Bool) {
        matchEnabled ? (matchTarget, true) : (chosen.lufs, false)
    }
}

enum LoudnessHistoryText {
    static let integratedNote = "Integrated: last 24 h"
    static let matchDetectorLabel = "Match detector (3 s smoothed)"
    static let shortTermLabel = "Short-term (3 s window)"
    static func target(_ t: (lufs: Double, fromMatch: Bool)) -> String {
        String(format: "Target %.1f LUFS%@", t.lufs, t.fromMatch ? " (Loudness Match)" : "")
    }
}

/// The 10-minute short-term line with the target.
struct LoudnessHistoryView: View {
    let history: LoudnessShortTermHistory
    let targetLUFS: Double
    var range: ClosedRange<Double> = -50 ... 0

    var body: some View {
        Canvas { gc, size in
            gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.08)))
            func y(_ v: Double) -> CGFloat {
                size.height * CGFloat(1 - (min(max(v, range.lowerBound), range.upperBound) - range.lowerBound)
                    / (range.upperBound - range.lowerBound))
            }
            var target = Path()
            target.move(to: CGPoint(x: 0, y: y(targetLUFS)))
            target.addLine(to: CGPoint(x: size.width, y: y(targetLUFS)))
            gc.stroke(target, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            guard let last = history.points.last else { return }
            var path = Path()
            var open = false
            for p in history.points {
                let x = size.width - CGFloat((last.time - p.time) / LoudnessShortTermHistory.windowSeconds) * size.width
                guard let v = p.lufs else { open = false; continue }
                if open { path.addLine(to: CGPoint(x: x, y: y(v))) } else { path.move(to: CGPoint(x: x, y: y(v))); open = true }
            }
            gc.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
        }
        .frame(height: 70)
        .accessibilityElement()
        .accessibilityLabel("Short-term loudness, last 10 minutes")
        .accessibilityValue(LoudnessCardText.lufs(history.points.last?.lufs))
        .accessibilityIdentifier("meters.loudness.history")
    }
}
