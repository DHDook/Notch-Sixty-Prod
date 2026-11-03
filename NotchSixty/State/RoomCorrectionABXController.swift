import Foundation

// E24 S9: drives a blind ABX of two room-correction designs from the setup flow's Save step.
//
// Main actor, control plane. Nothing here touches an audio thread: each press calls the engine through
// `RoomCorrectionABXPlaying`, which republishes the live graph (the core's silent warm-up and 20 ms crossfade is the
// switch). The hidden X assignment stays inside the `BlindABXSession`; published state never says which design X is,
// and the design names stay hidden until the trials and the preference answer are in.

@MainActor
final class RoomCorrectionABXController: ObservableObject {
    enum Selection: Equatable { case a, b, x }

    enum Phase: Equatable {
        case trials
        /// All trials are in; the preference question comes before the names are shown.
        case askingPreference
        case finished
        /// Playback stopped, the output changed or the player failed: the applied design is back (or being restored).
        case ended(String)
    }

    enum Preference: Equatable { case a, b, none }

    struct Result: Equatable {
        var correctCount: Int
        var trialCount: Int
        var pValue: Double
        var preferredDesignName: String?
        var logURL: URL
    }

    /// Candidate A is minimum phase, B is mixed phase. Names are revealed by `revealedNames` once finished.
    private let nameA = RoomCorrectionABXLog.minimumPhaseName
    private let nameB = RoomCorrectionABXLog.mixedPhaseName

    private let player: RoomCorrectionABXPlaying
    private let overrideA: RoomCorrectionABXOverride
    private let overrideB: RoomCorrectionABXOverride
    private let match: RoomCorrectionABXMatch
    private let seatCount: Int
    private let logDirectory: URL
    private let now: () -> Date
    private let nextAssignment: () -> Bool
    private var session: BlindABXSession

    /// Listening seats the run can be heard at (names of the measured seats, 1-based by position).
    let seatNames: [String]
    @Published var listeningSeatIndex = 0
    @Published private(set) var selection: Selection?
    @Published private(set) var phase: Phase = .trials
    @Published private(set) var completedTrials = 0
    @Published private(set) var heardX = false
    @Published private(set) var message: String?
    @Published private(set) var result: Result?
    @Published private(set) var isSwitching = false
    @Published private(set) var g3Passed = false
    @Published private(set) var seatsWithPassingLog = 0

    var totalTrials: Int { session.totalTrials }
    var currentTrialNumber: Int { session.currentTrialNumber }
    var matchSummary: String {
        let trim = abs(20 * log10(min(match.gainA, match.gainB)))
        return String(format: "Level matched within %.2f dB (trim %.1f dB); latency matched at %d frames.",
                      match.maxLaneResidualDB, trim, max(match.delayA, match.delayB))
    }
    var levelWarning: String? {
        guard match.hasLaneResidualWarning else { return nil }
        return String(format: "One speaker differs by %.1f dB between the designs after matching, so the comparison is not exactly level.",
                      match.maxLaneResidualDB)
    }
    var revealedNames: (a: String, b: String)? { phase == .finished ? (nameA, nameB) : nil }

    init(
        player: RoomCorrectionABXPlaying, a: RoomCorrectionLaneInstall, b: RoomCorrectionLaneInstall,
        match: RoomCorrectionABXMatch, seatCount: Int, seatNames: [String], logDirectory: URL,
        trialCount: Int = 16, initialAssignment: Bool = Bool.random(),
        nextAssignment: @escaping () -> Bool = { Bool.random() }, now: @escaping () -> Date = { Date() }
    ) throws {
        self.player = player
        overrideA = match.override(for: a, isA: true)
        overrideB = match.override(for: b, isA: false)
        self.match = match
        self.seatCount = seatCount
        self.seatNames = seatNames.isEmpty ? ["Main seat"] : seatNames
        self.logDirectory = logDirectory
        self.nextAssignment = nextAssignment
        self.now = now
        session = try BlindABXSession(trialCount: trialCount, initialAssignment: initialAssignment)
        refreshG3()
    }

    // MARK: Trials

    var canAnswer: Bool { phase == .trials && session.maySubmitChoice && !isSwitching }
    var canSwitch: Bool { phase == .trials && !isSwitching }

    /// A, B or X. X plays the hidden design and counts as heard; the published selection is `.x`.
    func select(_ choice: Selection) {
        guard phase == .trials else { return }
        refreshSwitching()
        guard !isSwitching else { message = "Wait for the switch to finish."; return }
        let target: RoomCorrectionABXOverride
        switch choice {
        case .a: target = overrideA
        case .b: target = overrideB
        case .x: target = session.currentHiddenXWasB ? overrideB : overrideA
        }
        do {
            try player.play(target)
            if choice == .x {
                try session.recordXPlayback()
                heardX = true
            }
            selection = choice
            message = nil
            refreshSwitching()
        } catch {
            message = error.localizedDescription
        }
    }

    /// "X is A" or "X is B". Refused until X has played.
    func answer(xIsB: Bool) {
        guard phase == .trials else { return }
        guard session.maySubmitChoice else {
            message = "Listen to X before answering."
            return
        }
        do {
            try session.submit(xIsB, nextAssignment: nextAssignment())
            completedTrials = session.completedTrials.count
            heardX = false
            selection = nil
            message = nil
            if session.isComplete { phase = .askingPreference }
        } catch {
            message = error.localizedDescription
        }
    }

    /// The preference question after the trials, then the log is written and the names are shown.
    func submitPreference(_ preference: Preference) {
        guard phase == .askingPreference else { return }
        let preferred: String?
        switch preference {
        case .a: preferred = nameA
        case .b: preferred = nameB
        case .none: preferred = nil
        }
        do {
            let seat = min(max(listeningSeatIndex, 0), seatNames.count - 1) + 1
            let log = try RoomCorrectionABXLog(
                session: session, match: match, designAName: nameA, designBName: nameB, seatCount: seatCount,
                listeningSeat: seat, preferredDesignName: preferred, date: now())
            let url = try log.write(to: logDirectory)
            result = Result(
                correctCount: log.correctCount, trialCount: log.trialCount, pValue: log.oneSidedExactPValue,
                preferredDesignName: preferred, logURL: url)
            phase = .finished
            message = nil
            refreshG3()
        } catch {
            message = "The result could not be saved: \(error.localizedDescription)"
        }
    }

    // MARK: Lifecycle

    /// Back to the applied design; the sheet's Close and Keep call this.
    func close() {
        if case .ended = phase { return }
        do { try player.restoreApplied() } catch { message = error.localizedDescription }
    }

    /// Called by the sheet on a timer: ends the run when playback stopped or the output changed (the engine has already
    /// dropped the override), and tracks the core's switching state.
    func refreshReadiness() {
        refreshSwitching()
        guard phase != .finished, !isEnded else { return }
        if let reason = player.unavailableReason {
            phase = .ended(reason)
            selection = nil
            try? player.restoreApplied()
        }
    }

    private var isEnded: Bool { if case .ended = phase { return true } else { return false } }

    private func refreshSwitching() { isSwitching = player.isSwitching }

    private func refreshG3() {
        let logs = RoomCorrectionABXLog.readAll(in: logDirectory)
            .filter { $0.designAName == nameA && $0.designBName == nameB }
        g3Passed = RoomCorrectionABXLog.gateG3(logs)
        seatsWithPassingLog = Set(logs.filter { $0.oneSidedExactPValue < 0.05 && $0.preferredDesignName == nameB }
            .compactMap(\.listeningSeat)).count
    }
}
