import Foundation

/// E28 S4: undo and redo for a page whose whole editable state is one `Equatable` value, registered
/// with the window's `UndoManager` (tests inject their own). Generalised from E27 S1's `EQEditHistory`
/// (which keeps its A/B slot handling). Each step is a (before, after) pair of whole values.
///
/// Rules (the same as the Equalizer page):
/// - Undo applies `before` only while the live state still equals `after`. If anything else changed it
///   (profile switch, import, another page), the history is cleared rather than undoing that change.
/// - `normalize` removes the parts that are not covered (for the Dynamics page, none).
/// - A drag is one step (`beginGesture` ... `endGesture`); repeated edits of the same field within
///   `coalescingWindow` join the previous step.
/// - Depth is 100 steps. A new edit discards the redo steps.
///
/// Main-thread only; it never touches the audio engine's realtime side.
@MainActor
final class EditHistory<State: Equatable> {
    static var depth: Int { 100 }
    static var coalescingWindow: TimeInterval { 0.75 }

    fileprivate final class Entry {
        let before: State
        var after: State
        let name: String

        init(before: State, after: State, name: String) {
            self.before = before
            self.after = after
            self.name = name
        }
    }

    /// The undo steps of one slot (E27 S3b A/B), set aside while another slot is active. Redo steps are not
    /// kept across a switch (an `UndoManager` cannot register a redo outside an undo).
    struct SlotSteps {
        fileprivate var undo: [Entry] = []
        init() {}
        var count: Int { undo.count }
    }

    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []

    private weak var undoManager: UndoManager?
    private var live: (() -> State)?
    private var apply: ((State) throws -> Void)?
    private let normalize: (State) -> State
    /// Menu wording derived from the two values, when the name cannot be known when a gesture begins (EQ).
    private let nameFor: ((State, State) -> String)?
    /// Adjusts the value an undo or redo applies, given the live value (EQ keeps the live bypass).
    private let adjustRestored: (State, State) -> State
    var now: () -> Date = Date.init

    private var expected: State?
    private var gestureBefore: State?
    private var gestureName: String?
    private var lastEntry: Entry?
    private var lastKey: String?
    private var lastTime = Date.distantPast

    init(
        normalize: @escaping (State) -> State = { $0 },
        nameFor: ((State, State) -> String)? = nil,
        adjustRestored: @escaping (State, State) -> State = { target, _ in target }
    ) {
        self.normalize = normalize
        self.nameFor = nameFor
        self.adjustRestored = adjustRestored
    }

    var undoCount: Int { undoEntries.count }
    var redoCount: Int { redoEntries.count }
    var isGestureOpen: Bool { gestureBefore != nil }

    /// Attaches the window's undo manager and the live-state accessors. Safe to call again.
    func configure(
        undoManager: UndoManager?,
        live: @escaping () -> State,
        apply: @escaping (State) throws -> Void
    ) {
        if self.undoManager !== undoManager { clear() }
        self.undoManager = undoManager
        self.live = live
        self.apply = apply
        undoManager?.levelsOfUndo = Self.depth
        expected = live()
    }

    // MARK: Recording

    /// Records one finished edit. A no-op edit is ignored. `coalesceKey` joins edits of the same
    /// field made within the coalescing window into one step.
    func record(before: State, after: State, name: String = "Edit", coalesceKey: String? = nil) {
        guard gestureBefore == nil else { return }
        let normalizedBefore = normalize(before)
        defer { expected = after }
        guard normalizedBefore != normalize(after) else { return }

        // Something outside the page changed the state before this edit: start afresh.
        if let expected, normalize(expected) != normalizedBefore { clear() }

        let time = now()
        if let coalesceKey, coalesceKey == lastKey, let lastEntry,
           time.timeIntervalSince(lastTime) < Self.coalescingWindow,
           normalize(lastEntry.after) == normalizedBefore {
            lastEntry.after = after
            lastTime = time
            return
        }

        let entry = Entry(before: before, after: after, name: nameFor?(before, after) ?? name)
        registerUndo(entry)
        undoEntries.append(entry)
        if undoEntries.count > Self.depth { undoEntries.removeFirst(undoEntries.count - Self.depth) }
        redoEntries.removeAll()
        lastEntry = entry
        lastKey = coalesceKey
        lastTime = time
    }

    /// Starts a drag: edits made until `endGesture` become one step.
    func beginGesture(before: State, name: String = "Edit") {
        guard gestureBefore == nil else { return }
        gestureBefore = before
        gestureName = name
    }

    /// Ends a drag and records it as a single step (nothing if the value did not move).
    func endGesture(after: State) {
        guard let before = gestureBefore else { return }
        let name = gestureName ?? "Edit"
        gestureBefore = nil
        gestureName = nil
        record(before: before, after: after, name: name)
    }

    /// Called whenever the live state may have changed. A change this history did not make clears it.
    /// Ignored during a drag.
    func observeLiveChange() {
        guard gestureBefore == nil, let live else { return }
        let current = live()
        if let expected, normalize(expected) != normalize(current) { clear() }
        expected = current
    }

    /// Removes this history's steps from the undo manager and returns them, so another slot can have its own.
    /// The live state is not touched.
    func detachSteps() -> SlotSteps {
        var saved = SlotSteps()
        saved.undo = undoEntries
        undoEntries.removeAll()
        redoEntries.removeAll()
        gestureBefore = nil
        gestureName = nil
        lastEntry = nil
        lastKey = nil
        undoManager?.removeAllActions(withTarget: self)
        return saved
    }

    /// Registers `steps` (oldest first) on the undo manager and re-bases on the live state.
    func attachSteps(_ steps: SlotSteps) {
        undoManager?.removeAllActions(withTarget: self)
        undoEntries = steps.undo
        redoEntries.removeAll()
        for entry in steps.undo { registerUndo(entry) }
        if let live { expected = live() }
    }

    /// Drops every step. Called when the page goes away so no registration outlives it.
    func clear() {
        undoEntries.removeAll()
        redoEntries.removeAll()
        gestureBefore = nil
        gestureName = nil
        lastEntry = nil
        lastKey = nil
        undoManager?.removeAllActions(withTarget: self)
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

    /// Moves the live state from one side of `entry` to the other, if it is still on the side the
    /// entry expects; otherwise the history is stale and is cleared.
    private func restore(_ entry: Entry, toBefore: Bool) {
        lastEntry = nil
        lastKey = nil
        guard let live, let apply else { return }
        let current = live()
        let source = toBefore ? entry.after : entry.before
        guard normalize(current) == normalize(source) else {
            clear()
            expected = current
            return
        }
        do {
            try apply(adjustRestored(toBefore ? entry.before : entry.after, current))
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
