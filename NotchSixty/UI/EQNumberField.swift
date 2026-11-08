import SwiftUI

/// E27 S1: a number field for the Equalizer band editor that accepts units ("2k", "-3 dB",
/// "1 oct"), clamps to the band type's range, rejects nonsense by restoring the old value, and
/// steps with the Up and Down arrows (Shift coarse, Option fine). All parsing and stepping
/// rules live in `EQValueParser` and `EQNudge`; this view only binds them.
struct EQNumberField: View {
    let title: String
    let field: EQValueParser.Field
    let value: Double
    let band: EQBand
    let maximumFrequency: Double
    var width: CGFloat = 90
    var identifier: String
    /// Called with the new, already clamped value. `isStep` is true for arrow-key steps so the
    /// caller can join held-key repeats into one undo step.
    let onCommit: (Double, _ isStep: Bool) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($focused)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
            .onAppear { text = display(value) }
            .onChange(of: value) { _, newValue in
                if !focused { text = display(newValue) }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commitText() }
            }
            .onSubmit { commitText() }
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                step(direction: press.key == .upArrow ? .up : .down, modifiers: press.modifiers)
                return .handled
            }
    }

    private func display(_ number: Double) -> String {
        EQValueParser.displayText(number, field: field)
    }

    private func commitText() {
        // Untouched text (it still shows the stored value) is not an edit.
        if text == display(value) { return }
        guard let parsed = EQValueParser.value(
            from: text, field: field, band: band, maximumFrequency: maximumFrequency
        ) else {
            text = display(value)
            return
        }
        text = display(parsed)
        if parsed != value { onCommit(parsed, false) }
    }

    private func step(direction: EQNudge.Direction, modifiers: EventModifiers) {
        // Step from what is typed if it parses, otherwise from the stored value.
        let current = EQValueParser.value(
            from: text, field: field, band: band, maximumFrequency: maximumFrequency
        ) ?? value
        let next = EQNudge.nudged(
            current,
            field: field,
            direction: direction,
            step: EQNudge.Step(shift: modifiers.contains(.shift), option: modifiers.contains(.option)),
            band: band,
            maximumFrequency: maximumFrequency
        )
        text = display(next)
        if next != value { onCommit(next, true) }
    }
}

/// E27 S4 (G4): the dynamic-EQ metric field, same behaviour as `EQNumberField`: units, clamping,
/// rejection restores the old value, Up/Down step (Shift coarse, Option fine). Rules in `EQDynamicMetric`.
struct EQDynamicMetricField: View {
    let title: String
    let metric: EQDynamicMetric
    @Binding var value: Double

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 92)
            .focused($focused)
            .accessibilityLabel(title)
            .accessibilityIdentifier("eq.dynamic.\(title)")
            .onAppear { text = EQDynamicMetric.displayText(value, metric: metric) }
            .onChange(of: value) { _, newValue in
                if !focused { text = EQDynamicMetric.displayText(newValue, metric: metric) }
            }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .onSubmit { commit() }
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let current = EQDynamicMetric.value(from: text, metric: metric) ?? value
                let next = EQDynamicMetric.nudged(
                    current, metric: metric, direction: press.key == .upArrow ? .up : .down,
                    step: EQNudge.Step(shift: press.modifiers.contains(.shift), option: press.modifiers.contains(.option)))
                text = EQDynamicMetric.displayText(next, metric: metric)
                if next != value { value = next }
                return .handled
            }
    }

    private func commit() {
        if text == EQDynamicMetric.displayText(value, metric: metric) { return }
        guard let parsed = EQDynamicMetric.value(from: text, metric: metric) else {
            text = EQDynamicMetric.displayText(value, metric: metric)
            return
        }
        text = EQDynamicMetric.displayText(parsed, metric: metric)
        if parsed != value { value = parsed }
    }
}
