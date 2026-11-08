import Foundation

/// E27 S1: undo and redo for edits made on the Equalizer page, registered with the window's
/// `UndoManager` (tests inject their own). Each step is a (before, after) pair of whole
/// `StereoEQConfiguration` values, so every covered edit - band move, add, remove, enable,
/// type, frequency, gain, Q, slope, constant-Q, Linkwitz target, dynamic settings, channel
/// mode, phase mode - round-trips exactly.
///
/// Rules (owner decisions of 7 Nov 2026):
/// - Undo applies `before` only while the live EQ still equals `after`. If anything else has
///   changed it (profile switch, import, Room Correction apply), the history is cleared
///   rather than undoing that change.
/// - Bypass, the edit-lane picker, A/B and audition are not covered, and a change to them
///   neither makes the history stale nor is undone: `normalized` ignores `bypassed` and
///   `editChannel`, and an undo keeps the live bypass state.
/// - A drag is one step (`beginGesture` ... `endGesture`); repeated scroll or arrow steps on
///   the same field within `coalescingWindow` join the previous step.
/// - Depth is 100 steps. A new edit discards the redo steps (the `UndoManager` does this).
///
/// Main-thread only; it never touches the audio engine's realtime side.
@MainActor
final class EQEditHistory {
    static let depth = 100
    static let coalescingWindow: TimeInterval = 0.75

    fileprivate final class Entry {
        let before: StereoEQConfiguration
        var after: StereoEQConfiguration
        let name: String

        init(before: StereoEQConfiguration, after: StereoEQConfiguration, name: String) {
            self.before = before
            self.after = after
            self.name = name
        }
    }

    /// E27 S3b: the undo steps of one A/B slot, set aside while the other slot is active.
    /// Redo steps are not kept across a slot switch (an `UndoManager` cannot register a redo
    /// outside an undo), so a switch ends redo for the slot it leaves.
    struct SlotSteps {
        fileprivate var undo: [Entry] = []
        var count: Int { undo.count }
    }

    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []

    private weak var undoManager: UndoManager?
    private var live: (() -> StereoEQConfiguration)?
    private var apply: ((StereoEQConfiguration) throws -> Void)?
    var now: () -> Date = Date.init

    private var expected: StereoEQConfiguration?
    private var gestureBefore: StereoEQConfiguration?
    private var lastEntry: Entry?
    private var lastKey: String?
    private var lastTime = Date.distantPast

    init() {}

    init(
        undoManager: UndoManager?,
        live: @escaping () -> StereoEQConfiguration,
        apply: @escaping (StereoEQConfiguration) throws -> Void
    ) {
        configure(undoManager: undoManager, live: live, apply: apply)
    }

    /// Attaches the window's undo manager and the live-state accessors. Safe to call again
    /// (for example when the window changes); it keeps nothing from a previous manager.
    func configure(
        undoManager: UndoManager?,
        live: @escaping () -> StereoEQConfiguration,
        apply: @escaping (StereoEQConfiguration) throws -> Void
    ) {
        if self.undoManager !== undoManager { clear() }
        self.undoManager = undoManager
        self.live = live
        self.apply = apply
        undoManager?.levelsOfUndo = Self.depth
        expected = live()
    }

    /// Normalised comparison: ignores the parts of the configuration the history does not cover.
    static func normalized(_ configuration: StereoEQConfiguration) -> StereoEQConfiguration {
        var copy = configuration
        copy.bypassed = false
        copy.editChannel = .linked
        return copy
    }

    var isGestureOpen: Bool { gestureBefore != nil }

    // MARK: Recording

    /// Records one finished edit. A no-op edit is ignored. `coalesceKey` joins edits of the
    /// same field made within the coalescing window into one step.
    func record(
        before: StereoEQConfiguration,
        after: StereoEQConfiguration,
        coalesceKey: String? = nil
    ) {
        guard gestureBefore == nil else { return }
        let normalizedBefore = Self.normalized(before)
        let normalizedAfter = Self.normalized(after)
        defer { expected = after }
        guard normalizedBefore != normalizedAfter else { return }

        // Something outside the page changed the EQ before this edit: start afresh.
        if let expected, Self.normalized(expected) != normalizedBefore { clear() }

        let time = now()
        if let coalesceKey, coalesceKey == lastKey, let lastEntry,
           time.timeIntervalSince(lastTime) < Self.coalescingWindow,
           Self.normalized(lastEntry.after) == normalizedBefore {
            lastEntry.after = after
            lastTime = time
            return
        }

        let entry = Entry(before: before, after: after, name: Self.actionName(before: before, after: after))
        registerUndo(entry)
        undoEntries.append(entry)
        if undoEntries.count > Self.depth { undoEntries.removeFirst(undoEntries.count - Self.depth) }
        redoEntries.removeAll()
        lastEntry = entry
        lastKey = coalesceKey
        lastTime = time
    }

    /// Starts a drag: edits made until `endGesture` become one step.
    func beginGesture(before: StereoEQConfiguration) {
        guard gestureBefore == nil else { return }
        gestureBefore = before
    }

    /// Ends a drag and records it as a single step (nothing if the handle did not move).
    func endGesture(after: StereoEQConfiguration) {
        guard let before = gestureBefore else { return }
        gestureBefore = nil
        record(before: before, after: after)
    }

    /// Called whenever the live EQ may have changed. A change this history did not make
    /// (profile switch, import, Room Correction apply) clears it. Ignored during a drag.
    func observeLiveChange() {
        guard gestureBefore == nil, let live else { return }
        let current = live()
        if let expected, Self.normalized(expected) != Self.normalized(current) { clear() }
        expected = current
    }

    /// Drops every step. Called when the page goes away so no registration outlives it.
    func clear() {
        undoEntries.removeAll()
        redoEntries.removeAll()
        gestureBefore = nil
        lastEntry = nil
        lastKey = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: Slots (E27 S3b)

    /// Removes this history's steps from the undo manager and returns them, so the other A/B
    /// slot can have its own. The live EQ is not touched.
    func detachSteps() -> SlotSteps {
        let saved = SlotSteps(undo: undoEntries)
        undoEntries.removeAll()
        redoEntries.removeAll()
        gestureBefore = nil
        lastEntry = nil
        lastKey = nil
        undoManager?.removeAllActions(withTarget: self)
        return saved
    }

    /// Registers `steps` (oldest first) on the undo manager and re-bases on the live EQ.
    func attachSteps(_ steps: SlotSteps) {
        undoManager?.removeAllActions(withTarget: self)
        undoEntries = steps.undo
        redoEntries.removeAll()
        for entry in steps.undo { registerUndo(entry) }
        if let live { expected = live() }
    }

    /// The number of undo steps held (for tests).
    var undoStepCount: Int { undoEntries.count }

    // MARK: Names

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

    // MARK: Undo manager plumbing

    private func registerUndo(_ entry: Entry) {
        guard let undoManager else { return }
        let grouped = !undoManager.isUndoing && !undoManager.isRedoing
        if grouped { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(entry, toBefore: true) }
        }
        undoManager.setActionName(entry.name)
        if grouped { undoManager.endUndoGrouping() }
    }

    private func registerRedo(_ entry: Entry) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(entry, toBefore: false) }
        }
        undoManager.setActionName(entry.name)
    }

    /// Moves the live EQ from one side of `entry` to the other, if it is still on the side
    /// the entry expects; otherwise the history is stale and is cleared.
    private func restore(_ entry: Entry, toBefore: Bool) {
        lastEntry = nil
        lastKey = nil
        guard let live, let apply else { return }
        let current = live()
        let source = toBefore ? entry.after : entry.before
        guard Self.normalized(current) == Self.normalized(source) else {
            clear()
            expected = current
            return
        }
        var target = toBefore ? entry.before : entry.after
        target.bypassed = current.bypassed
        do {
            try apply(target)
        } catch {
            clear()
            expected = live()
            return
        }
        expected = live()
        if toBefore {
            undoEntries.removeAll { $0 === entry }
            redoEntries.append(entry)
            registerRedo(entry)
        } else {
            redoEntries.removeAll { $0 === entry }
            undoEntries.append(entry)
            registerUndo(entry)
        }
    }
}
