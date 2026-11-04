import Combine
import Foundation

// E25 S8b (flag `e25.outputs-and-speakers`): the Speakers-tab control for a wider program source. It writes
// `SystemArrangement.foldDown` and calls `applyProgramFoldDown`. Control plane only (main actor); the capture-time
// fold itself is the S8a transport.

/// What the controller needs from the engine. `AudioIOEngine` conforms; tests inject a fake.
@MainActor
protocol ProgramFoldDownEngine: AnyObject {
    var programSourceCandidates: [AudioOutputDevice] { get }
    var programSourceSelectedOutput: AudioOutputDevice? { get }
    func applyProgramFoldDown(_ plan: ProgramFoldDownPlan?) throws
}

extension AudioIOEngine: ProgramFoldDownEngine {
    var programSourceCandidates: [AudioOutputDevice] { outputDevices }
    var programSourceSelectedOutput: AudioOutputDevice? { selectedOutputDevice }
}

@MainActor
final class ProgramSourceController: ObservableObject {
    @Published private(set) var lastError: String?

    private let engine: any ProgramFoldDownEngine
    private let profiles: ProductProfileController
    /// Swift reads the flag here; tests replace it.
    var isFlagEnabled: () -> Bool = { FeatureFlags().isEnabled(.outputsAndSpeakers) }

    init(engine: any ProgramFoldDownEngine, profiles: ProductProfileController) {
        self.engine = engine
        self.profiles = profiles
    }

    var arrangement: SystemArrangement? { profiles.selectedSystemProfile?.state.systemArrangement }

    /// Shown for the two-channel classes (B to E). Direct multi-output (class A) has its own routing and no fold.
    var isVisible: Bool {
        guard isFlagEnabled(), let arrangement else { return false }
        return arrangement.arrangementClass != .a
    }

    /// A stereo program has nothing to fold: the choices are shown but disabled.
    var foldApplies: Bool { (arrangement?.layout ?? .stereo) != .stereo }

    var foldDown: ProgramFoldDown { arrangement?.foldDown ?? ProgramFoldDown() }

    /// Devices that can carry the program: every output except the selected speaker output (that one is the DAC).
    var candidates: [AudioOutputDevice] {
        let selected = engine.programSourceSelectedOutput?.uid
        return engine.programSourceCandidates.filter { $0.uid != selected }
    }

    var resolution: ProgramSourceResolution {
        guard let arrangement else { return .upstreamFold }
        return foldDown.resolveSource(
            layout: arrangement.layout, availableDevices: engine.programSourceCandidates,
            sampleRate: engine.programSourceSelectedOutput?.nominalSampleRate ?? 0)
    }

    /// The plain-language state of the source, and the advice that goes with it.
    var resolutionText: String {
        guard foldApplies else {
            return "Your program layout is stereo, so there is nothing to fold. Choose a 5.1 or 7.1 layout in the setup wizard to fold a wider source."
        }
        switch resolution {
        case .upstreamFold:
            return "No wider source is set, so your player or macOS folds the program to two channels before it reaches Notch Sixty."
        case .source(let uid):
            let name = engine.programSourceCandidates.first { $0.uid == uid }?.name ?? uid
            return "Folding \(name) onto your two speaker feeds. Set the macOS output to \(name) so the player sends the full program there."
        case .waitForDevice(let uid):
            return "Waiting for the program source (\(uid)) to return. Notch Sixty never switches to another device."
        case .channelCountMismatch(let expected, let actual):
            return "The program source has \(actual) channels but your \(arrangement?.layout.displayName ?? "layout") program needs \(expected)."
        case .sampleRateUnsupported(let rate):
            return "The program source does not offer \(Int(rate)) Hz, the speaker output's rate. The fold never resamples."
        }
    }

    static let rebuildNote = "Changing the source, LFE or headroom restarts audio briefly and turns Quiet Zone off."

    var lfeNote: String {
        switch foldDown.lfe {
        case .drop: return "The LFE channel is not folded (ITU default)."
        case .foldPlus10dBWithLimiter: return "The LFE channel joins both feeds at +10 dB, with an output limiter at -1 dBFS."
        }
    }

    // MARK: - Edits

    func setSource(uid: String?) { edit { $0.programSourceDeviceUID = uid } }
    func setLFE(_ mode: FoldDownLFEMode) { edit { $0.lfe = mode } }
    func setHeadroom(_ headroom: FoldDownHeadroom) { edit { $0.headroom = headroom } }

    private func edit(_ change: (inout ProgramFoldDown) -> Void) {
        guard isVisible, foldApplies, var arrangement else { return }
        let previous = arrangement
        var fold = arrangement.foldDown ?? ProgramFoldDown()
        change(&fold)
        arrangement.foldDown = fold == ProgramFoldDown() ? nil : fold
        guard arrangement != previous else { return }
        do {
            try profiles.replaceSelectedSystemArrangement(arrangement)
            try engine.applyProgramFoldDown(ProgramFoldDownPlan(layout: arrangement.layout, foldDown: fold))
            lastError = nil
            objectWillChange.send()
        } catch {
            // Stored state and the engine go back together.
            try? profiles.replaceSelectedSystemArrangement(previous)
            let priorFold = previous.foldDown ?? ProgramFoldDown()
            try? engine.applyProgramFoldDown(ProgramFoldDownPlan(layout: previous.layout, foldDown: priorFold))
            lastError = error.localizedDescription
            objectWillChange.send()
        }
    }
}
