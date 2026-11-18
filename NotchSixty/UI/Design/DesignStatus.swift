import SwiftUI

/// E34 S1: four status levels, each with a colour, an icon and a word, so colour is never the only signal.
enum StatusLevel: CaseIterable, Sendable {
    case good
    case attention
    case problem
    case off

    var label: String {
        switch self {
        case .good: return "Good"
        case .attention: return "Attention"
        case .problem: return "Problem"
        case .off: return "Off"
        }
    }

    var iconName: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        case .off: return "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .good: return .green
        case .attention: return .orange
        case .problem: return .red
        case .off: return .secondary
        }
    }
}
