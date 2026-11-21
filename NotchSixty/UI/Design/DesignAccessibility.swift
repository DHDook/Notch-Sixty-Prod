import SwiftUI

/// E34 S6: the accessibility settings the shared design parts honour (Reduce Motion, Increase Contrast, Reduce
/// Transparency, Differentiate Without Color), as plain values so each resolution can be tested without a view.
/// Swift UI only: the realtime engine never reads any of this.
struct DesignAccessibilitySettings: Equatable, Sendable {
    var reduceMotion = false
    var increaseContrast = false
    var reduceTransparency = false
    var differentiateWithoutColor = false

    static let standard = DesignAccessibilitySettings()

    /// Content card fill. Reduce Transparency or Increase Contrast makes it close to opaque.
    func surfaceOpacity(_ style: DesignStyle) -> Double {
        if reduceTransparency { return 0.9 }
        if increaseContrast { return max(DesignSurface.opacity(style), 0.6) }
        return DesignSurface.opacity(style)
    }

    /// Tinted chip or note fill (status badges). Stronger under Increase Contrast and Differentiate Without Color.
    func tintOpacity(_ base: Double) -> Double {
        if increaseContrast || differentiateWithoutColor { return max(base, 0.28) }
        return base
    }

    /// Hairline border width: heavier under Increase Contrast.
    var borderWidth: CGFloat { increaseContrast ? 1.5 : 0.5 }

    /// Cards and chips carry a visible outline under Increase Contrast or Differentiate Without Color.
    var drawsOutline: Bool { increaseContrast || differentiateWithoutColor }

    /// Floating-control glass is replaced by a solid surface under Reduce Transparency.
    var usesGlass: Bool { !reduceTransparency }

    /// An animation, or none under Reduce Motion.
    func animation(_ animation: Animation?) -> Animation? { reduceMotion ? nil : animation }
}

extension EnvironmentValues {
    /// The accessibility settings as the shared design parts see them.
    var designAccessibility: DesignAccessibilitySettings {
        DesignAccessibilitySettings(
            reduceMotion: accessibilityReduceMotion,
            increaseContrast: colorSchemeContrast == .increased,
            reduceTransparency: accessibilityReduceTransparency,
            differentiateWithoutColor: accessibilityDifferentiateWithoutColor)
    }
}

/// Content card background through the accessibility settings.
struct DesignSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: DesignRadius
    var style: DesignStyle
    var bordered = false

    private var settings: DesignAccessibilitySettings {
        DesignAccessibilitySettings(
            reduceMotion: reduceMotion, increaseContrast: contrast == .increased,
            reduceTransparency: reduceTransparency, differentiateWithoutColor: differentiate)
    }

    func body(content: Content) -> some View {
        let s = settings
        let shape = RoundedRectangle(cornerRadius: radius.value(style), style: .continuous)
        content
            .background(.quaternary.opacity(s.surfaceOpacity(style)), in: shape)
            .overlay {
                if bordered || s.drawsOutline {
                    shape.stroke(s.drawsOutline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary),
                                 lineWidth: s.borderWidth)
                }
            }
    }
}

/// Tinted chip or note background through the accessibility settings.
struct DesignTintModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.colorSchemeContrast) private var contrast
    var color: Color
    var opacity: Double
    var radius: DesignRadius
    var style: DesignStyle

    func body(content: Content) -> some View {
        let s = DesignAccessibilitySettings(
            reduceMotion: reduceMotion, increaseContrast: contrast == .increased,
            reduceTransparency: reduceTransparency, differentiateWithoutColor: differentiate)
        let shape = RoundedRectangle(cornerRadius: radius.value(style), style: .continuous)
        content
            .background(color.opacity(s.tintOpacity(opacity)), in: shape)
            .overlay {
                if s.drawsOutline { shape.stroke(color, lineWidth: s.borderWidth) }
            }
    }
}

/// Floating-control glass, or a solid surface under Reduce Transparency.
struct DesignGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: DesignRadius
    var style: DesignStyle

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: radius.value(style), style: .continuous))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius.value(style)))
        }
    }
}

// MARK: - Sliders

/// How a slider's value is spoken: the same units and formats the pages show (`DesignFormat`).
enum DesignSliderUnit: Equatable, Sendable {
    case db, dbfs, dbtp, hz, ms, degrees
    /// A plain number with two decimals (Q, ratios).
    case number
    /// A fraction 0...1 spoken as a whole percent.
    case percent
    /// A plain number with a spoken unit word ("seconds"), one decimal.
    case plain(String)

    func spoken(_ value: Double) -> String {
        switch self {
        case .db: return DesignFormat.db(value, signed: true)
        case .dbfs: return DesignFormat.level(value, unit: "dBFS")
        case .dbtp: return DesignFormat.level(value, unit: "dBTP")
        case .hz: return DesignFormat.hz(value)
        case .ms: return DesignFormat.ms(value)
        case .degrees: return DesignFormat.level(value, unit: "degrees")
        case .number: return String(format: "%.2f", value)
        case .percent: return DesignFormat.percent(value)
        case .plain(let word): return word.isEmpty ? String(format: "%.2f", value) : DesignFormat.level(value, unit: word)
        }
    }
}

extension View {
    /// A slider's VoiceOver label and value, in the unit the page shows. Use on every slider.
    func designSlider(_ label: String, value: Double, unit: DesignSliderUnit) -> some View {
        accessibilityLabel(label).accessibilityValue(unit.spoken(value))
    }

    /// Animation that is dropped under Reduce Motion.
    func designAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(DesignMotionModifier(animation: animation, value: value))
    }
}

struct DesignMotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animation: Animation?
    var value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
