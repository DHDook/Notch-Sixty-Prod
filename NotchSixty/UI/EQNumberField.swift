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
