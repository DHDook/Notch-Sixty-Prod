import Foundation
import Observation

/// E20 S9: replaces `objectWillChange.sink` for `@Observable` models. Runs `onChange` on the main
/// actor one hop after any property that `track` read has changed, then re-arms. `track` should read
/// only the properties the handler needs, so unrelated changes do not wake it. An optional `debounce`
/// waits that long after the first change and coalesces everything in between.
///
/// Main-actor only; never touched from an audio callback. Cancelled by `cancel()` or by release.
@MainActor
final class ObservationSubscription {
    private let track: @MainActor () -> Void
    private let onChange: @MainActor () -> Void
    private let debounce: Duration?
    private var cancelled = false

    init(
        debounce: Duration? = nil,
        track: @escaping @MainActor () -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.debounce = debounce
        self.track = track
        self.onChange = onChange
        arm()
    }

    /// Value form: runs `onChange` with the new value only when it differs from the last one seen
    /// (the starting value is not delivered), like `$property.dropFirst().removeDuplicates()`.
    convenience init<Value: Equatable>(
        value: @escaping @MainActor () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) {
        let last = LastValue<Value>(value())
        self.init(
            track: { _ = value() },
            onChange: {
                let now = value()
                guard now != last.value else { return }
                last.value = now
                onChange(now)
            }
        )
    }

    private final class LastValue<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    func cancel() { cancelled = true }

    private func arm() {
        guard !cancelled else { return }
        withObservationTracking {
            track()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in await self?.fired() }
        }
    }

    private func fired() async {
        guard !cancelled else { return }
        if let debounce {
            try? await Task.sleep(for: debounce)
            guard !cancelled else { return }
        }
        onChange()
        arm()
    }
}
