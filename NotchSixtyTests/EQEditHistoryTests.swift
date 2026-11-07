import Foundation
import XCTest
@testable import NotchSixty

@MainActor
final class EQEditHistoryTests: XCTestCase {
    /// A fake engine: the live EQ is a plain value and `apply` writes it back.
    @MainActor private final class Harness {
        var state: StereoEQConfiguration
        let undoManager = UndoManager()
        var history: EQEditHistory!
        var clock = Date(timeIntervalSince1970: 1_000)

        init(bands: [EQBand]? = nil) {
            state = StereoEQConfiguration(linkedBands: bands ?? [
                EQBand(frequencyHz: 100, gainDB: 2, q: 1),
                EQBand(type: .lowShelf, frequencyHz: 5_000, gainDB: -3, q: 0.707),
            ])
            undoManager.groupsByEvent = false
            history = EQEditHistory(
                undoManager: undoManager,
                live: { [unowned self] in self.state },
                apply: { [unowned self] in self.state = $0 }
            )
            history.now = { [unowned self] in self.clock }
        }

        /// Applies `change` to the live state and records it, as the page does.
        func edit(key: String? = nil, _ change: (inout StereoEQConfiguration) -> Void) {
            let before = state
            change(&state)
            history.record(before: before, after: state, coalesceKey: key)
        }

        func undoAll() -> Int {
            var count = 0
            while undoManager.canUndo { undoManager.undo(); count += 1 }
            return count
        }
    }

    private func assertRoundTrip(
        _ name: String,
        bands: [EQBand]? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ change: (inout StereoEQConfiguration) -> Void
    ) {
        let h = Harness(bands: bands)
        let before = h.state
        h.edit(change)
        let after = h.state
        XCTAssertNotEqual(before, after, "\(name): the edit must change something", file: file, line: line)
        XCTAssertTrue(h.undoManager.canUndo, name, file: file, line: line)
        h.undoManager.undo()
        XCTAssertEqual(h.state, before, "\(name): undo", file: file, line: line)
        XCTAssertTrue(h.undoManager.canRedo, name, file: file, line: line)
        h.undoManager.redo()
        XCTAssertEqual(h.state, after, "\(name): redo", file: file, line: line)
        h.undoManager.undo()
        XCTAssertEqual(h.state, before, "\(name): second undo", file: file, line: line)
    }

    func testEveryCoveredEditRoundTripsExactly() {
        assertRoundTrip("move") { $0.linkedBands[0].frequencyHz = 133.7; $0.linkedBands[0].gainDB = 4.25 }
        assertRoundTrip("add") { $0.linkedBands.append(EQBand(frequencyHz: 900, gainDB: 1, q: 1)) }
        assertRoundTrip("remove") { $0.linkedBands.remove(at: 0) }
        assertRoundTrip("enable") { $0.linkedBands[1].enabled = false }
        assertRoundTrip("type") { $0.linkedBands[0].type = .highShelf }
        assertRoundTrip("frequency") { $0.linkedBands[1].frequencyHz = 6_300 }
        assertRoundTrip("gain") { $0.linkedBands[0].gainDB = -7.5 }
        assertRoundTrip("Q") { $0.linkedBands[0].q = 3.2 }
        assertRoundTrip("slope") { $0.linkedBands[1].slope = .db24 }
        assertRoundTrip("constant Q") { $0.linkedBands[0].constantQ = true }
        assertRoundTrip("Linkwitz target") {
            $0.linkedBands[0].type = .linkwitzTransform
            $0.linkedBands[0].linkwitzTargetHz = 32
            $0.linkedBands[0].linkwitzTargetQ = 0.9
        }
        assertRoundTrip("dynamic settings") {
            $0.linkedBands[0].dynamic.enabled = true
            $0.linkedBands[0].dynamic.thresholdDB = -30
            $0.linkedBands[0].dynamic.ratio = 4
            $0.linkedBands[0].dynamic.attackMs = 5
        }
        assertRoundTrip("channel mode") { $0.setChannelMode(.independent) }
        assertRoundTrip("channel mode to mid/side") { $0.setChannelMode(.midSide) }
        assertRoundTrip("phase mode") { $0.phaseMode = .linearPhase }
    }

    func testIndependentLaneEditRoundTripsAndKeepsTheOtherLane() {
        let h = Harness()
        h.edit { $0.setChannelMode(.independent) }
        h.edit { $0.leftBands[0].gainDB = 9 }
        let afterLeft = h.state
        XCTAssertEqual(afterLeft.rightBands[0].gainDB, 2)
        h.undoManager.undo()
        XCTAssertEqual(h.state.leftBands[0].gainDB, 2)
        h.undoManager.redo()
        XCTAssertEqual(h.state, afterLeft)
    }

    func testManyStepsUndoInReverseOrderAndRedoForward() {
        let h = Harness()
        var states = [h.state]
        for hertz in [110.0, 120, 130, 140] {
            h.edit { $0.linkedBands[0].frequencyHz = hertz }
            states.append(h.state)
        }
        for expected in states.dropLast().reversed() {
            h.undoManager.undo()
            XCTAssertEqual(h.state, expected)
        }
        for expected in states.dropFirst() {
            h.undoManager.redo()
            XCTAssertEqual(h.state, expected)
        }
    }

    func testDragIsOneStep() {
        let h = Harness()
        let original = h.state
        h.history.beginGesture(before: h.state)
        for step in 1...40 {
            // The page publishes while dragging; none of it is its own step, none is stale.
            h.state.linkedBands[0].frequencyHz = 100 + Double(step)
            h.state.linkedBands[0].gainDB = 2 + Double(step) / 10
            h.history.observeLiveChange()
        }
        XCTAssertTrue(h.history.isGestureOpen)
        XCTAssertFalse(h.undoManager.canUndo, "nothing is recorded until the drag ends")
        let dragged = h.state
        h.history.endGesture(after: h.state)
        XCTAssertFalse(h.history.isGestureOpen)
        XCTAssertEqual(h.undoAll(), 1)
        XCTAssertEqual(h.state, original)
        h.undoManager.redo()
        XCTAssertEqual(h.state, dragged)
    }

    func testDragThatDoesNotMoveRecordsNothing() {
        let h = Harness()
        h.history.beginGesture(before: h.state)
        h.history.endGesture(after: h.state)
        XCTAssertFalse(h.undoManager.canUndo)
    }

    func testRepeatedStepsOnOneFieldJoinWithinTheWindowOnly() {
        let h = Harness()
        let original = h.state
        for hertz in [101.0, 102, 103] {
            h.edit(key: "nudge.frequency") { $0.linkedBands[0].frequencyHz = hertz }
            h.clock.addTimeInterval(0.2)
        }
        XCTAssertEqual(h.state.linkedBands[0].frequencyHz, 103)
        // A different field does not join.
        h.edit(key: "nudge.gain") { $0.linkedBands[0].gainDB = 5 }
        // Nor does the same field after the window.
        h.clock.addTimeInterval(EQEditHistory.coalescingWindow + 0.1)
        h.edit(key: "nudge.gain") { $0.linkedBands[0].gainDB = 6 }
        XCTAssertEqual(h.undoAll(), 3)
        XCTAssertEqual(h.state, original)
    }

    func testEditsWithoutAKeyNeverJoin() {
        let h = Harness()
        h.edit { $0.linkedBands[0].q = 2 }
        h.edit { $0.linkedBands[0].q = 3 }
        XCTAssertEqual(h.undoAll(), 2)
    }

    func testOutsideChangeClearsTheHistoryInsteadOfBeingUndone() {
        let h = Harness()
        h.edit { $0.linkedBands[0].gainDB = 6 }
        // A profile switch (or import, or Room Correction apply) replaces the EQ.
        h.state.linkedBands = [EQBand(frequencyHz: 40, gainDB: -5, q: 2)]
        let outside = h.state
        XCTAssertTrue(h.undoManager.canUndo)
        h.history.observeLiveChange()
        XCTAssertFalse(h.undoManager.canUndo, "cleared as soon as the change is seen")
        XCTAssertFalse(h.undoManager.canRedo)
        XCTAssertEqual(h.state, outside)
    }

    func testUndoNeverOverwritesAnOutsideChangeEvenIfItIsNotSeenFirst() {
        let h = Harness()
        h.edit { $0.linkedBands[0].gainDB = 6 }
        h.state.linkedBands[1].frequencyHz = 7_777
        let outside = h.state
        h.undoManager.undo()
        XCTAssertEqual(h.state, outside, "stale undo is dropped")
        XCTAssertFalse(h.undoManager.canUndo)
        XCTAssertFalse(h.undoManager.canRedo)
    }

    func testStaleRedoIsDroppedToo() {
        let h = Harness()
        h.edit { $0.linkedBands[0].gainDB = 6 }
        h.undoManager.undo()
        h.state.linkedBands[1].frequencyHz = 7_777
        let outside = h.state
        h.undoManager.redo()
        XCTAssertEqual(h.state, outside, "a stale redo never overwrites the outside change")
        // UndoManager may keep items it was mid-way through; they stay inert (each is stale).
        if h.undoManager.canRedo { h.undoManager.redo() }
        if h.undoManager.canUndo { h.undoManager.undo() }
        if h.undoManager.canRedo { h.undoManager.redo() }
        XCTAssertEqual(h.state, outside)
    }

    func testEditAfterAnUnseenOutsideChangeStartsAFreshHistory() {
        let h = Harness()
        h.edit { $0.linkedBands[0].gainDB = 6 }
        h.state.linkedBands[1].frequencyHz = 7_777
        h.edit { $0.linkedBands[0].q = 4 }
        XCTAssertEqual(h.undoAll(), 1, "the earlier step belongs to a state that no longer exists")
        XCTAssertEqual(h.state.linkedBands[1].frequencyHz, 7_777)
    }

    func testBypassAndEditLaneAreNotCoveredAndDoNotMakeTheHistoryStale() {
        let h = Harness()
        h.edit { $0.setChannelMode(.independent) }
        h.edit { $0.leftBands[0].gainDB = 9 }
        // The user flips bypass and the edit-lane picker; neither is an undo step.
        h.state.bypassed = true
        h.state.editChannel = .right
        h.history.observeLiveChange()
        XCTAssertTrue(h.undoManager.canUndo)
        h.undoManager.undo()
        XCTAssertEqual(h.state.leftBands[0].gainDB, 2, "the left-lane edit is undone")
        XCTAssertTrue(h.state.bypassed, "undo keeps the live bypass state")
        h.undoManager.redo()
        XCTAssertEqual(h.state.leftBands[0].gainDB, 9)
        XCTAssertTrue(h.state.bypassed)
    }

    func testNewEditClearsRedo() {
        let h = Harness()
        h.edit { $0.linkedBands[0].gainDB = 6 }
        h.undoManager.undo()
        XCTAssertTrue(h.undoManager.canRedo)
        h.edit { $0.linkedBands[0].gainDB = -6 }
        XCTAssertFalse(h.undoManager.canRedo)
    }

    func testDepthIsCappedAtOneHundred() {
        let h = Harness()
        let first = h.state
        for index in 1...130 {
            h.edit { $0.linkedBands[0].frequencyHz = 100 + Double(index) }
        }
        XCTAssertEqual(h.undoAll(), EQEditHistory.depth)
        XCTAssertEqual(EQEditHistory.depth, 100)
        // The 30 oldest steps were dropped, so the first state is out of reach.
        XCTAssertNotEqual(h.state, first)
        XCTAssertEqual(h.state.linkedBands[0].frequencyHz, 130)
    }

    func testClearDropsEverything() {
        let h = Harness()
        h.edit { $0.linkedBands[0].gainDB = 6 }
        h.edit { $0.linkedBands[0].gainDB = 7 }
        h.undoManager.undo()
        h.history.clear()
        XCTAssertFalse(h.undoManager.canUndo)
        XCTAssertFalse(h.undoManager.canRedo)
    }

    func testNoOpEditIsNotRecorded() {
        let h = Harness()
        h.edit { _ in }
        h.edit { $0.bypassed = true }
        XCTAssertFalse(h.undoManager.canUndo)
    }

    func testActionNames() {
        let base = StereoEQConfiguration(linkedBands: [EQBand()])
        var added = base
        added.linkedBands.append(EQBand())
        var removed = base
        removed.linkedBands = []
        var channels = base
        channels.setChannelMode(.midSide)
        var phase = base
        phase.phaseMode = .linearPhase
        var edited = base
        edited.linkedBands[0].gainDB = 3
        XCTAssertEqual(EQEditHistory.actionName(before: base, after: added), "Add EQ Band")
        XCTAssertEqual(EQEditHistory.actionName(before: base, after: removed), "Remove EQ Band")
        XCTAssertEqual(EQEditHistory.actionName(before: base, after: channels), "Change EQ Channels")
        XCTAssertEqual(EQEditHistory.actionName(before: base, after: phase), "Change EQ Phase")
        XCTAssertEqual(EQEditHistory.actionName(before: base, after: edited), "Edit EQ Band")
        let h = Harness()
        h.edit { $0.linkedBands.append(EQBand()) }
        XCTAssertEqual(h.undoManager.undoActionName, "Add EQ Band")
    }
}
