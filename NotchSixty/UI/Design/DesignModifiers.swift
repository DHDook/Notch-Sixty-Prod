import SwiftUI

/// E34 S2: the shared modifiers pages use instead of card helpers and hand-set values.

extension DesignSpacing {
    /// The step's value for the active style, for `spacing:` and `.padding` arguments.
    var pt: CGFloat { value(DesignStyle.active) }

    /// The nearest step for a point value a page used to write by hand (0 stays 0).
    static func nearest(_ points: CGFloat) -> DesignSpacing? {
        switch points {
        case ..<0.5: return nil
        case ..<5.5: return .xs
        case ..<9.5: return .s
        case ..<13.5: return .m
        case ..<19: return .l
        default: return .xl
        }
    }
}

extension DesignRadius {
    var pt: CGFloat { value(DesignStyle.active) }

    /// The nearest shared radius for a radius a page used to write by hand.
    static func nearest(_ points: CGFloat) -> DesignRadius {
        switch points {
        case ..<11: return .small
        case ..<17: return .medium
        default: return .large
        }
    }
}

enum DesignSurface {
    /// Fill opacity of a content card: today's common 0.22, the new look 0.4 (matches `DesignCard`).
    static func opacity(_ style: DesignStyle) -> Double { style == .redesigned ? 0.4 : 0.22 }
}

extension View {
    /// A content card background: plain fill, no glass (`docs/DESIGN_LANGUAGE.md` rule 1), shared radius. Honours
    /// Reduce Transparency and Increase Contrast (E34 S6).
    func designSurface(_ radius: DesignRadius = .medium) -> some View {
        modifier(DesignSurfaceModifier(radius: radius, style: DesignStyle.active))
    }

    /// A tinted status chip or note background, with the shared small radius.
    func designTint(_ color: Color, opacity: Double = 0.14, radius: DesignRadius = .small) -> some View {
        modifier(DesignTintModifier(color: color, opacity: opacity, radius: radius, style: DesignStyle.active))
    }

    /// A panel (large card with a hairline border), for the module and headphone panels.
    func designPanel() -> some View {
        modifier(DesignSurfaceModifier(radius: .large, style: DesignStyle.active, bordered: true))
    }

    /// Floating-control glass in a shared radius (navigation lists and controls only, never content). Solid under
    /// Reduce Transparency.
    func designGlass(_ radius: DesignRadius = .medium) -> some View {
        modifier(DesignGlassModifier(radius: radius, style: DesignStyle.active))
    }
}
