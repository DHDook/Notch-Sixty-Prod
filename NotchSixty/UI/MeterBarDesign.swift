import Foundation
import SwiftUI

// E33 S6 (design 16, behind `e33.page-enhancements`): the decisions behind the level bars, in plain Swift so the
// tests can check them. Zones, colours, the numeric readout, the scale and hold choices, the named resets, the
// stopped state and the spoken-value rate limit. Nothing here is realtime code.

/// The four zones of a level bar. Each has a tint and a texture, so no zone depends on colour alone.
enum MeterZone: Int, CaseIterable, Comparable, Sendable {
    /// Below -18 dBFS: plain.
    case quiet
    /// -18 up to -6 dBFS: blue.
    case signal
    /// -6 up to -3 dBFS: amber, hatched.
    case hot
    /// -3 dBFS and above: red, cross-hatched.
    case over

    static let boundariesDB: [Double] = [-18, -6, -3]

    static func < (lhs: MeterZone, rhs: MeterZone) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The zone of a level. A boundary belongs to the zone above it.
    static func zone(forDB db: Double) -> MeterZone {
        if db >= boundariesDB[2] { return .over }
        if db >= boundariesDB[1] { return .hot }
        if db >= boundariesDB[0] { return .signal }
        return .quiet
    }

    var lowerBoundDB: Double? {
        switch self {
        case .quiet: return nil
        case .signal: return Self.boundariesDB[0]
        case .hot: return Self.boundariesDB[1]
        case .over: return Self.boundariesDB[2]
        }
    }

    var spokenName: String {
        switch self {
        case .quiet: return "low"
        case .signal: return "normal"
        case .hot: return "hot"
        case .over: return "over"
        }
    }

    /// Hatch lines per zone: none, none, one direction, both directions.
    var hatchDirections: Int {
        switch self {
        case .quiet, .signal: return 0
        case .hot: return 1
        case .over: return 2
        }
    }
}

/// The zone colours (sRGB, 0...1) and the luminance rule they are checked against.
enum MeterPalette {
    typealias RGB = (r: Double, g: Double, b: Double)

    static func color(_ zone: MeterZone) -> RGB {
        switch zone {
        case .quiet: return (0.30, 0.30, 0.30)
        case .signal: return (0.25, 0.55, 0.95)
        case .hot: return (1.00, 0.80, 0.20)
        case .over: return (0.80, 0.10, 0.10)
        }
    }

    static func swiftUIColor(_ zone: MeterZone) -> Color {
        let c = color(zone)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    enum Deficiency: CaseIterable, Sendable { case none, protanopia, deuteranopia }

    private static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func encoded(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    /// The colour as a person with full red or green blindness sees it (Machado, Oliveira and Fernandes 2009,
    /// severity 1.0, applied in linear RGB).
    static func simulated(_ rgb: RGB, _ deficiency: Deficiency) -> RGB {
        let m: [[Double]]
        switch deficiency {
        case .none: return rgb
        case .protanopia:
            m = [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]]
        case .deuteranopia:
            m = [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]]
        }
        let l = [linear(rgb.r), linear(rgb.g), linear(rgb.b)]
        func channel(_ row: [Double]) -> Double {
            encoded(min(max(row[0] * l[0] + row[1] * l[1] + row[2] * l[2], 0), 1))
        }
        return (channel(m[0]), channel(m[1]), channel(m[2]))
    }

    /// WCAG relative luminance.
    static func luminance(_ rgb: RGB) -> Double {
        0.2126 * linear(rgb.r) + 0.7152 * linear(rgb.g) + 0.0722 * linear(rgb.b)
    }

    /// WCAG contrast ratio, 1 to 21.
    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Adjacent zones must differ by at least this ratio in luminance, with or without a colour deficiency.
    static let minimumAdjacentContrast = 1.5
}

/// The numeric peak beside each bar.
enum MeterReadout {
    /// One decimal place; an em dash while the level is at the floor.
    static func peakText(_ db: Double, floorDB: Double) -> String {
        guard db.isFinite, db > floorDB + 0.05 else { return "\u{2014}" }
        return String(format: "%.1f", db)
    }
}

/// The scale of the level bars: the lowest level drawn.
enum MeterScaleChoice: Int, CaseIterable, Identifiable, Sendable {
    case minus60 = -60
    case minus96 = -96
    case minus120 = -120

    var id: Int { rawValue }
    var floorDB: Double { Double(rawValue) }
    var title: String { "\(rawValue) dB" }

    static let `default` = MeterScaleChoice.minus60

    static func stored(_ defaults: UserDefaults = .standard) -> MeterScaleChoice {
        MeterScaleChoice(rawValue: defaults.integer(forKey: PreferenceKeys.Meters.scaleFloorDB)) ?? .default
    }

    func store(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: PreferenceKeys.Meters.scaleFloorDB) }
}

/// The one peak-hold time for the level bars and the gain-reduction bars.
enum MeterHoldChoice: String, CaseIterable, Identifiable, Sendable {
    case oneSecond, twoSeconds, fiveSeconds, untilReset

    var id: String { rawValue }

    /// `.infinity` holds until the Reset menu clears it.
    var seconds: Double {
        switch self {
        case .oneSecond: return 1
        case .twoSeconds: return 2
        case .fiveSeconds: return 5
        case .untilReset: return .infinity
        }
    }

    var title: String {
        switch self {
        case .oneSecond: return "1 s"
        case .twoSeconds: return "2 s"
        case .fiveSeconds: return "5 s"
        case .untilReset: return "Until reset"
        }
    }

    static let `default` = MeterHoldChoice.twoSeconds

    static func stored(_ defaults: UserDefaults = .standard) -> MeterHoldChoice {
        defaults.string(forKey: PreferenceKeys.Meters.peakHold).flatMap(MeterHoldChoice.init(rawValue:)) ?? .default
    }

    func store(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: PreferenceKeys.Meters.peakHold) }
}

/// The names in the one Reset menu. Each clears its own target and nothing else.
enum MeterResetTarget: String, CaseIterable, Identifiable, Sendable {
    case clipLatches, peakHold, loudness, truePeakMax

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipLatches: return "Clip latches"
        case .peakHold: return "Peak hold"
        case .loudness: return "Loudness"
        case .truePeakMax: return "True-peak max"
        }
    }
}

/// Spoken (VoiceOver) values change at most every 2 s, or at once when the value moved by a whole unit (1 LU).
struct SpokenValueThrottle: Sendable {
    static let minimumIntervalSeconds = 2.0
    static let changeThreshold = 1.0

    private var lastTime: Double?
    private var lastNumber: Double?
    private(set) var text = ""

    mutating func offer(_ newText: String, number: Double?, now: Double) -> String {
        guard let lastTime else {
            publish(newText, number, now)
            return text
        }
        let moved: Bool = {
            guard let number, let lastNumber else { return false }
            return abs(number - lastNumber) >= Self.changeThreshold
        }()
        if newText != text, moved || now - lastTime >= Self.minimumIntervalSeconds { publish(newText, number, now) }
        return text
    }

    private mutating func publish(_ newText: String, _ number: Double?, _ now: Double) {
        text = newText
        lastNumber = number
        lastTime = now
    }
}

/// Holds one throttle per value id for a card that cannot keep mutable state of its own.
@MainActor
final class SpokenValueBook {
    private var throttles: [String: SpokenValueThrottle] = [:]

    func value(id: String, text: String, number: Double?, now: Double) -> String {
        var throttle = throttles[id] ?? SpokenValueThrottle()
        let out = throttle.offer(text, number: number, now: now)
        throttles[id] = throttle
        return out
    }
}

/// The stopped state, one for every meter page.
enum MeterStoppedPolicy {
    static func showsStoppedState(isRunning: Bool, page: ProductionMetersPage) -> Bool { !isRunning }
}

/// Shown at the top of every Meters page while processing is stopped. One wording, one Start button.
struct MeterStoppedState: View {
    let onStart: () -> Void

    static let message = "Audio is stopped. Start processing to see live meters."

    var body: some View {
        DesignStoppedBanner(message: Self.message, onStart: onStart, identifier: "meters.stopped")
    }
}

/// The hold time and Reset menu, on Levels and on Meters > Dynamics.
struct MeterDisplayControls: View {
    @Binding var hold: MeterHoldChoice
    @Binding var scale: MeterScaleChoice
    let showsScale: Bool
    let onReset: (MeterResetTarget) -> Void

    var body: some View {
        HStack(spacing: DesignSpacing.m.pt) {
            Picker("Peak hold", selection: $hold) {
                ForEach(MeterHoldChoice.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 190)
            .accessibilityIdentifier("meters.peakHold")
            if showsScale {
                Picker("Scale", selection: $scale) {
                    ForEach(MeterScaleChoice.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 160)
                .accessibilityIdentifier("meters.scale")
            }
            Menu("Reset") {
                ForEach(MeterResetTarget.allCases) { target in
                    Button(target.title) { onReset(target) }
                        .accessibilityIdentifier("meters.reset.\(target.rawValue)")
                }
            }
            .menuIndicator(.visible)
            .fixedSize()
            .accessibilityIdentifier("meters.reset")
            Spacer()
        }
    }
}
