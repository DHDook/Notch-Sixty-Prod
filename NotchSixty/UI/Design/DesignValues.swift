import SwiftUI

/// E34 S1: the shared design values (see `docs/DESIGN_LANGUAGE.md`).
///
/// Every value exists twice: `.current` is today's most common value, `.redesigned` is the new one. Pages move onto
/// these values first with almost no visible change; the `e34.design-language` flag switches the whole app to the new
/// set at once. Swift UI only: the realtime engine never reads any of this.
enum DesignStyle: Equatable, Sendable {
    case current
    case redesigned

    /// The style the app uses now. Reads the flag process-wide (any thread, no MainActor).
    static var active: DesignStyle {
        FeatureFlags.isEnabledProcessWide(.designLanguage) ? .redesigned : .current
    }
}

/// The three corner radii. Nothing else sets a radius by hand.
enum DesignRadius: CaseIterable, Sendable {
    case small  // chips, fields, small controls
    case medium  // cards
    case large  // panels and sheets

    func value(_ style: DesignStyle) -> CGFloat {
        switch (self, style) {
        case (.small, .current): return 8
        case (.medium, .current): return 12
        case (.large, .current): return 18
        case (.small, .redesigned): return 8
        case (.medium, .redesigned): return 14
        case (.large, .redesigned): return 22
        }
    }
}

/// One spacing scale (points). Pages pick a step; no other padding or spacing value is written by hand.
enum DesignSpacing: CaseIterable, Sendable {
    case xs, s, m, l, xl

    func value(_ style: DesignStyle) -> CGFloat {
        switch (self, style) {
        case (.xs, _): return 4
        case (.s, _): return 8
        case (.m, _): return 12
        case (.l, .current): return 16
        case (.l, .redesigned): return 16
        case (.xl, .current): return 20
        case (.xl, .redesigned): return 24
        }
    }
}

/// The type scale. The smallest size is 11 points (owner decision 3); `body` is for text meant to be read and
/// `caption` is for secondary notes only.
enum DesignType: CaseIterable, Sendable {
    case pageTitle, sectionTitle, body, label, caption

    /// Point size at the default Dynamic Type setting.
    func size(_ style: DesignStyle) -> CGFloat {
        switch (self, style) {
        case (.pageTitle, _): return 22
        case (.sectionTitle, _): return 15
        case (.body, .current): return 12
        case (.body, .redesigned): return 13
        case (.label, .current): return 11
        case (.label, .redesigned): return 12
        case (.caption, _): return 11
        }
    }

    var weight: Font.Weight {
        switch self {
        case .pageTitle: return .semibold
        case .sectionTitle: return .semibold
        case .body, .label, .caption: return .regular
        }
    }

    var font: Font { font(DesignStyle.active) }

    func font(_ style: DesignStyle) -> Font {
        .system(size: size(style), weight: weight)
    }

    /// The smallest size any text may use.
    static let minimumSize: CGFloat = 11
}
