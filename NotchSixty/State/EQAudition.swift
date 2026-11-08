import AppKit
import Combine
import Foundation

/// E27 S3b: the "Listen" audition. A transient override of the rendered EQ: every lane becomes one
/// unity-peak band-pass at the audited band's frequency and Q, so the listener hears only that
/// region of the programme. It is an input to the render step (`StereoEQConfiguration.auditioned`),
/// never stored in the configuration, the profile or the undo history. Minimum phase only.
///
/// Realtime: Swift builds a normal graph snapshot from the substituted configuration and publishes
/// it through the usual path, so the audio thread sees nothing new (no allocation, no locks).
struct EQAuditionOverride: Equatable, Sendable {
    /// Q used for shelves and high/low-pass bands, which have no meaningful bandwidth of their own.
    static let defaultQ = 0.707
    /// An audition ends by itself after this long.
    static let maxDuration: TimeInterval = 30

    let frequencyHz: Double
    let q: Double

    init(frequencyHz: Double, q: Double) {
        self.frequencyHz = frequencyHz
        self.q = q
    }

    /// The override for `band`: its frequency, and its Q unless it is a shelf or HP/LP.
    init(band: EQBand) {
        switch band.type {
        case .lowShelf, .highShelf, .lowPass, .highPass, .tilt, .fir:
            self.init(frequencyHz: band.frequencyHz, q: Self.defaultQ)
        default:
            self.init(frequencyHz: band.frequencyHz, q: band.q)
        }
    }

    var band: EQBand {
        EQBand(type: .bandPass, frequencyHz: frequencyHz, gainDB: 0, q: q)
    }
}

extension StereoEQConfiguration {
    /// The configuration as rendered while auditioning `override`: one band-pass in each lane in
    /// use, minimum phase, not bypassed. The receiver is not changed.
    func auditioned(_ override: EQAuditionOverride) -> StereoEQConfiguration {
        var copy = self
        copy.phaseMode = .minimumPhase
        copy.bypassed = false
        let lane = [override.band]
        switch channelMode {
        case .linked: copy.linkedBands = lane
        case .independent:
            copy.leftBands = lane
            copy.rightBands = lane
        case .midSide:
            copy.midBands = lane
            copy.sideBands = lane
        }
        return copy
    }
}

/// Starts and ends the Listen audition on the engine (main actor). The override is an input to
/// the render step only; this controller never touches the stored EQ, the profile or the undo
/// history. It ends on release (`stop`), page leave, window close, transport stop (the engine
/// clears the override and `eqAudition` goes nil), and after `maxDuration`.
@MainActor
final class EQAuditionController: ObservableObject {
    @Published private(set) var active: EQAuditionOverride?
    @Published private(set) var lastErrorDescription: String?

    var maxDuration: TimeInterval = EQAuditionOverride.maxDuration
    private let engine: AudioIOEngine
    private var timer: Task<Void, Never>?
    private var engineObservation: AnyCancellable?
    private var windowObservation: NSObjectProtocol?

    init(engine: AudioIOEngine) {
        self.engine = engine
        engineObservation = engine.$eqAudition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    // Read the engine's current value: the delivered one may be stale (the
                    // subscription's initial nil arrives after an immediate start).
                    guard let self, self.engine.eqAudition == nil, self.active != nil else { return }
                    self.active = nil
                    self.timer?.cancel()
                    self.timer = nil
                }
            }
        windowObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
    }

    deinit {
        if let windowObservation { NotificationCenter.default.removeObserver(windowObservation) }
    }

    /// Listens to `band`. Moving to another band while listening just moves the filter.
    func start(band: EQBand) {
        start(EQAuditionOverride(band: band))
    }

    func start(_ override: EQAuditionOverride) {
        do {
            try engine.setEQAudition(override)
            active = override
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            return
        }
        timer?.cancel()
        let seconds = maxDuration
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// Ends the audition (button or key release, page leave, window close, time limit).
    func stop() {
        timer?.cancel()
        timer = nil
        guard active != nil || engine.eqAudition != nil else { return }
        active = nil
        do { try engine.setEQAudition(nil) } catch { lastErrorDescription = error.localizedDescription }
    }
}

/// E27 S4 (G14): what leaving the Equalizer page does, in one place so a test can drive it without a view.
/// Leaving ends the page's undo history, so no step outlives the view, and ends a held Listen audition so
/// the band-pass never keeps playing on another page.
@MainActor
enum EQPageLifecycle {
    static func leave(history: EQEditHistory, audition: EQAuditionController?) {
        history.clear()
        audition?.stop()
    }
}
