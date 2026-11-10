import SwiftUI

/// E28 S4: a Dynamics parameter row built from a `DynamicsParameterSpec`: log or linear slider (Option drags
/// fine, double-click resets), a typed field with units and arrow-key stepping, and VoiceOver adjustment.
/// `commit` returns false when the engine refused the value; the row then shows the live value again.
struct DynamicsParameterRow: View {
    let spec: DynamicsParameterSpec
    let title: String
    let value: Double
    let isEnabled: Bool
    let reference: ProductionReferenceNavigator?
    /// (value, isStep). `isStep` marks arrow and VoiceOver steps so the history can coalesce them.
    let commit: (Double, Bool) -> Bool
    let beginGesture: () -> Void
    let endGesture: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                ParameterSlider(
                    spec: spec,
                    title: title,
                    value: value,
                    commit: commit,
                    beginGesture: beginGesture,
                    endGesture: endGesture
                )
                .frame(minWidth: 220)
                .accessibilityIdentifier("dynamics.\(spec.id).slider")

                ParameterNumberField(spec: spec, title: title, value: value, commit: commit)
                    .accessibilityIdentifier("dynamics.\(spec.id)")

                if !spec.unit.suffix.isEmpty {
                    Text(spec.unit.suffix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 38, alignment: .leading)
                }
            }
            .disabled(!isEnabled)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if let reference, let formula = spec.formula {
                    ProductionReferenceHelpButton(
                        navigator: reference,
                        articleID: "dynamics",
                        formulaID: formula,
                        destination: .dspReference,
                        label: "Open \(title) math in DSP Reference"
                    )
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

/// Typed field: Return commits, a refused or unreadable entry restores the live value, Up and Down step
/// (Shift coarse, Option fine).
private struct ParameterNumberField: View {
    let spec: DynamicsParameterSpec
    let title: String
    let value: Double
    let commit: (Double, Bool) -> Bool

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 76)
            .focused($focused)
            .onAppear { text = spec.displayText(value) }
            .onChange(of: value) { _, new in if !focused { text = spec.displayText(new) } }
            .onChange(of: focused) { _, isFocused in if !isFocused { submit() } }
            .onSubmit { submit() }
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let step = EQNudge.Step(shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option))
                let next = spec.nudged(value, direction: press.key == .upArrow ? .up : .down, step: step)
                _ = commit(next, true)
                text = spec.displayText(next)
                return .handled
            }
            .accessibilityValue(ValueParser.spokenText(value, unit: spec.unit, digits: spec.digits))
    }

    private func submit() {
        defer { text = spec.displayText(value) }
        guard text != spec.displayText(value), let parsed = spec.parse(text) else { return }
        if commit(parsed, false) { text = spec.displayText(parsed) }
    }
}

/// Custom slider so log scales, Option-fine drags, double-click reset and keyboard steps behave alike.
private struct ParameterSlider: View {
    let spec: DynamicsParameterSpec
    let title: String
    let value: Double
    let commit: (Double, Bool) -> Bool
    let beginGesture: () -> Void
    let endGesture: () -> Void

    @State private var dragStartPosition: Double?
    @State private var lastX: CGFloat?
    @State private var position = 0.0

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: width * displayPosition, height: 4)
                Circle()
                    .fill(Color.white)
                    .shadow(radius: 1)
                    .frame(width: 16, height: 16)
                    .offset(x: (width - 16) * displayPosition)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if dragStartPosition == nil {
                            dragStartPosition = spec.position(of: value)
                            position = dragStartPosition ?? 0
                            lastX = drag.startLocation.x
                            beginGesture()
                            if !NSEvent.modifierFlags.contains(.option) {
                                position = Double(min(max(drag.startLocation.x / width, 0), 1))
                            }
                        }
                        let fine = NSEvent.modifierFlags.contains(.option)
                        let previous = lastX ?? drag.location.x
                        if fine {
                            position += Double((drag.location.x - previous) / width) * 0.1
                        } else {
                            position = Double(drag.location.x / width)
                        }
                        position = min(max(position, 0), 1)
                        lastX = drag.location.x
                        _ = commit(spec.value(atPosition: position), false)
                    }
                    .onEnded { _ in
                        dragStartPosition = nil
                        lastX = nil
                        endGesture()
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { _ = commit(spec.defaultValue, false) }
            )
        }
        .frame(height: 20)
        .focusable()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            let up = press.key == .upArrow || press.key == .rightArrow
            let step = EQNudge.Step(shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option))
            _ = commit(spec.nudged(value, direction: up ? .up : .down, step: step), true)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(ValueParser.spokenText(value, unit: spec.unit, digits: spec.digits))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = commit(spec.nudged(value, direction: .up, step: .normal), true)
            case .decrement: _ = commit(spec.nudged(value, direction: .down, step: .normal), true)
            @unknown default: break
            }
        }
    }

    private var displayPosition: Double {
        dragStartPosition == nil ? spec.position(of: value) : position
    }
}
