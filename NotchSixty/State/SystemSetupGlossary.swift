import Foundation

// E12 S30 (G66): every technical term the guided setup shows has a plain label and a one-line explanation. A step lists
// the terms it uses in `terms(on:)`, and the step shows their explanations under its text, so a term cannot be
// added to a step without its explanation.

enum SystemSetupTerm: String, CaseIterable, Identifiable, Sendable {
    case dBFS, dBC, lfe, openSubPreout, calibratedLFEOut, polarity, errorNow, crossover

    var id: String { rawValue }

    /// The term as it appears on screen (the technical name stays visible so manuals and meters still match).
    var technicalName: String {
        switch self {
        case .dBFS: return "dBFS"
        case .dBC: return "dB(C)"
        case .lfe: return "LFE"
        case .openSubPreout: return "Open sub pre-out"
        case .calibratedLFEOut: return "Calibrated LFE out"
        case .polarity: return "Polarity"
        case .errorNow: return "Error now"
        case .crossover: return "Crossover"
        }
    }

    /// The plain label shown first.
    var plainLabel: String {
        switch self {
        case .dBFS: return "Playback level"
        case .dBC: return "Room loudness"
        case .lfe: return "Bass-only channel"
        case .openSubPreout: return "Subwoofer output with no filtering"
        case .calibratedLFEOut: return "Subwoofer output set up by the receiver"
        case .polarity: return "Push or pull"
        case .errorNow: return "Difference from target today"
        case .crossover: return "Where the bass hands over"
        }
    }

    var explanation: String {
        switch self {
        case .dBFS: return "How loud the test sound is sent, counted down from the loudest your output can carry. -40 is much quieter than -10; 0 is the limit."
        case .dBC: return "Room loudness as your microphone hears it, weighted to follow bass. About 75 is a normal, comfortable test level."
        case .lfe: return "The separate low-frequency effects channel of film soundtracks. It goes to the subwoofer only."
        case .openSubPreout: return "Your receiver sends the subwoofer everything, with no bass filter of its own, so Notch Sixty can do the filtering."
        case .calibratedLFEOut: return "Your receiver already filters the bass for the subwoofer, at the crossover you enter, and Notch Sixty works with that."
        case .polarity: return "Whether a speaker pushes air out or pulls it in when it should push. Opposite polarity makes bass cancel."
        case .errorNow: return "The average gap, in decibels, between what you hear now and the sound you chose. Smaller is better."
        case .crossover: return "The pitch below which bass moves from the main speakers to the subwoofer."
        }
    }

    /// The label with its technical name, for buttons and rows: "Playback level (dBFS)".
    var labelWithName: String { "\(plainLabel) (\(technicalName))" }

    /// The terms each step shows; the step lists their explanations.
    static func terms(on step: SystemSetupStep) -> [SystemSetupTerm] {
        switch step {
        case .topology: return [.openSubPreout, .calibratedLFEOut, .crossover]
        case .microphone: return [.dBFS, .dBC, .lfe]
        case .alignment, .bass: return [.polarity]
        case .correction: return [.errorNow]
        default: return []
        }
    }
}

/// E12 S30 (G61): what to tell the user about where the microphone and the seats go, and the marks the diagrams draw.
enum SystemSetupPlacementGuidance {
    static let microphoneLines = [
        "Put the microphone where your head will be: ear height when you sit, usually about 1 metre.",
        "Use a stand, not your hand, and keep it still while a sweep plays.",
        "Point it the way its instructions say. Most measurement microphones point straight up at the ceiling.",
        "Keep it away from walls, tables and screens, at least half a metre."
    ]
    static let seatLines = [
        "Measure the main seat first: the one where you listen most.",
        "Add the other seats where people really sit, about a head apart (30 to 50 cm) from the main seat or each other.",
        "More seats give a wider sweet spot but a little less polish at the main seat."
    ]

    /// Seat marks for the top-view diagram in a unit square (0 to 1 both ways, y down). The main seat is first and in
    /// the middle; the others sit on a ring around it.
    static func seatMarks(count: Int) -> [CGPoint] {
        let seats = max(1, min(count, 9))
        var marks = [CGPoint(x: 0.5, y: 0.62)]
        let others = seats - 1
        for index in 0..<others {
            let angle = (Double(index) + 0.5) / Double(max(others, 1)) * 2 * .pi
            marks.append(CGPoint(x: 0.5 + 0.28 * cos(angle), y: 0.62 + 0.22 * sin(angle)))
        }
        return marks
    }
}
