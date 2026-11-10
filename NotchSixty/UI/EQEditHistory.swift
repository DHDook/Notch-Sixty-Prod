import Foundation

/// E27 S1: undo and redo for edits made on the Equalizer page. G17 (E28 S5): a thin wrapper over the generic
/// `EditHistory<StereoEQConfiguration>`, which holds the one implementation of the stack, coalescing,
/// staleness and `UndoManager` plumbing. This type adds only what is specific to the EQ:
///
/// - Bypass and the edit-lane picker are not covered: `normalized` ignores `bypassed` and `editChannel`, a
///   change to them neither makes the history stale nor is undone, and an undo keeps the live bypass state.
/// - The Edit menu wording ("Undo Add EQ Band") from `actionName`.
/// - A/B slots keep their own undo steps (`detachSteps` / `attachSteps`).
///
/// Rules (owner decisions of 7 Nov 2026): undo applies `before` only while the live EQ still equals `after`;
/// a drag is one step; repeated steps on one field within `coalescingWindow` join; depth is 100.
/// Main-thread only; it never touches the audio engine's realtime side.
@MainActor
final class EQEditHistory {
    static let depth = EditHistory<StereoEQConfiguration>.depth
    static let coalescingWindow: TimeInterval = EditHistory<StereoEQConfiguration>.coalescingWindow

    /// E27 S3b: the undo steps of one A/B slot, set aside while the other slot is active.
    typealias SlotSteps = EditHistory<StereoEQConfiguration>.SlotSteps

    private let base = EditHistory<StereoEQConfiguration>(
        normalize: EQEditHistory.normalized,
        nameFor: EQEditHistory.actionName,
        adjustRestored: { target, current in
            var adjusted = target
            adjusted.bypassed = current.bypassed
            return adjusted
        }
    )

    var now: () -> Date {
        get { base.now }
        set { base.now = newValue }
    }

    init() {}

    init(
        undoManager: UndoManager?,
        live: @escaping () -> StereoEQConfiguration,
        apply: @escaping (StereoEQConfiguration) throws -> Void
    ) {
        configure(undoManager: undoManager, live: live, apply: apply)
    }

    /// Attaches the window's undo manager and the live-state accessors. Safe to call again.
    func configure(
        undoManager: UndoManager?,
        live: @escaping () -> StereoEQConfiguration,
        apply: @escaping (StereoEQConfiguration) throws -> Void
    ) {
        base.configure(undoManager: undoManager, live: live, apply: apply)
    }

    /// Normalised comparison: ignores the parts of the configuration the history does not cover.
    static func normalized(_ configuration: StereoEQConfiguration) -> StereoEQConfiguration {
        var copy = configuration
        copy.bypassed = false
        copy.editChannel = .linked
        return copy
    }

    var isGestureOpen: Bool { base.isGestureOpen }
    var undoStepCount: Int { base.undoCount }

    func record(before: StereoEQConfiguration, after: StereoEQConfiguration, coalesceKey: String? = nil) {
        base.record(before: before, after: after, coalesceKey: coalesceKey)
    }

    func beginGesture(before: StereoEQConfiguration) { base.beginGesture(before: before) }
    func endGesture(after: StereoEQConfiguration) { base.endGesture(after: after) }
    func observeLiveChange() { base.observeLiveChange() }
    func clear() { base.clear() }
    func detachSteps() -> SlotSteps { base.detachSteps() }
    func attachSteps(_ steps: SlotSteps) { base.attachSteps(steps) }

    /// The Edit menu wording: "Undo Add EQ Band" and so on.
    static func actionName(before: StereoEQConfiguration, after: StereoEQConfiguration) -> String {
        if before.channelMode != after.channelMode { return "Change EQ Channels" }
        if before.phaseMode != after.phaseMode { return "Change EQ Phase" }
        let beforeCount = before.editableBands.count
        let afterCount = after.editableBands.count
        if afterCount > beforeCount { return "Add EQ Band" }
        if afterCount < beforeCount { return "Remove EQ Band" }
        return "Edit EQ Band"
    }
}
