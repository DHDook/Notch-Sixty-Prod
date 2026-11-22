import Combine
import Foundation

// E24 S9: drives a blind ABX of two room-correction designs from the setup flow's Save step.
//
// Main actor, control plane. Nothing here touches an audio thread: each press calls the engine through
// `RoomCorrectionABXPlaying`, which republishes the live graph (the core's silent warm-up and 20 ms crossfade is the
// switch). The hidden X assignment stays inside the `BlindABXSession`; published state never says which design X is,
// and the design names stay hidden until the trials and the preference answer are in.

@MainActor
final class RoomCorrectionABXController: ObservableObject {
    // E12 S26: trials, switching, level matching and restore are the comparison service's; this class keeps the
    // room-correction specifics (the two design names, the preference question, the log and gate G3).
    typealias Selection = BlindComparisonService.Selection
    typealias Phase = BlindComparisonService.Phase

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

    private let service: BlindComparisonService
    private let match: RoomCorrectionABXMatch
    private let seatCount: Int
    private let logDirectory: URL
    private let now: () -> Date
    private var forwarding: AnyCancellable?

    /// Listening seats the run can be heard at (names of the measured seats, 1-based by position).
    let seatNames: [String]
    @Published var listeningSeatIndex = 0
    @Published private(set) var result: Result?
    @Published private(set) var g3Passed = false
    @Published private(set) var seatsWithPassingLog = 0

    var selection: Selection? { service.selection }
    var phase: Phase { service.phase }
    var completedTrials: Int { service.completedTrials }
    var heardX: Bool { service.heardX }
    var message: String? { service.message }
    var isSwitching: Bool { service.isSwitching }
    var totalTrials: Int { service.totalTrials }
    var currentTrialNumber: Int { service.currentTrialNumber }
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
    var revealedNames: (a: String, b: String)? { service.revealedNames }

    init(
        player: RoomCorrectionABXPlaying, a: RoomCorrectionLaneInstall, b: RoomCorrectionLaneInstall,
        match: RoomCorrectionABXMatch, seatCount: Int, seatNames: [String], logDirectory: URL,
        trialCount: Int = 16, initialAssignment: Bool = Bool.random(),
        nextAssignment: @escaping () -> Bool = { Bool.random() }, now: @escaping () -> Date = { Date() },
        switchHold: TimeInterval = ComparisonSwitchTiming.fixedSeconds
    ) throws {
        let overrideA = match.override(for: a, isA: true)
        let overrideB = match.override(for: b, isA: false)
        self.match = match
        self.seatCount = seatCount
        self.seatNames = seatNames.isEmpty ? ["Main seat"] : seatNames
        self.logDirectory = logDirectory
        self.now = now
        let level = ComparisonLevelMatch(
            levelADB: match.levelADB, levelBDB: match.levelBDB, gainA: match.gainA, gainB: match.gainB,
            remainingDifferenceDB: match.maxLaneResidualDB, isApproximate: false)
        service = try BlindComparisonService(
            engine: player,
            a: ComparisonSide(name: RoomCorrectionABXLog.minimumPhaseName) { try player.play(overrideA) },
            b: ComparisonSide(name: RoomCorrectionABXLog.mixedPhaseName) { try player.play(overrideB) },
            match: level, trialCount: trialCount, initialAssignment: initialAssignment,
            nextAssignment: nextAssignment, switchHold: switchHold)
        forwarding = service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        refreshG3()
    }

    // MARK: Trials

    var canAnswer: Bool { service.canAnswer }
    var canSwitch: Bool { service.canSwitch }

    /// A, B or X. X plays the hidden design and counts as heard; the published selection is `.x`.
    func select(_ choice: Selection) { service.select(choice) }

    /// "X is A" or "X is B". Refused until X has played.
    func answer(xIsB: Bool) { service.answer(xIsB: xIsB) }

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
                session: service.session, match: match, designAName: nameA, designBName: nameB, seatCount: seatCount,
                listeningSeat: seat, preferredDesignName: preferred, date: now())
            let url = try log.write(to: logDirectory)
            result = Result(
                correctCount: log.correctCount, trialCount: log.trialCount, pValue: log.oneSidedExactPValue,
                preferredDesignName: preferred, logURL: url)
            service.finish()
            refreshG3()
        } catch {
            service.setMessage("The result could not be saved: \(error.localizedDescription)")
        }
    }

    // MARK: Lifecycle

    /// Back to the applied design; the sheet's Close and Keep call this.
    func close() { service.close() }

    /// Called by the sheet on a timer: ends the run when playback stopped or the output changed, and tracks the
    /// core's switching state.
    func refreshReadiness() { service.refreshReadiness() }

    private func refreshG3() {
        let logs = RoomCorrectionABXLog.readAll(in: logDirectory)
            .filter { $0.designAName == nameA && $0.designBName == nameB }
        g3Passed = RoomCorrectionABXLog.gateG3(logs)
        seatsWithPassingLog = Set(logs.filter { $0.oneSidedExactPValue < 0.05 && $0.preferredDesignName == nameB }
            .compactMap(\.listeningSeat)).count
    }
}
