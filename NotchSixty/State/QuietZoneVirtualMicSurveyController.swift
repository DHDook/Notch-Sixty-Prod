import Combine
import Foundation

/// The speaker paths the survey needs for one tone: to the monitor microphone and to the ear position.
struct QuietZoneSurveyPaths: Equatable, Sendable {
    var monitorLeft: ActiveQuietZoneComplex
    var monitorRight: ActiveQuietZoneComplex
    var earLeft: ActiveQuietZoneComplex
    var earRight: ActiveQuietZoneComplex
}

/// E4 S26a: the monitor-to-ear ratio survey, run from the Quiet Zone card.
///
/// While Quiet Zone is running, the controller hands this object each window's uncancelled-noise phasors
/// (one per controlled tone, expressed against the canceller oscillator, which the S19 PLL keeps locked, so
/// phasors from different microphone positions share one phase frame). The listener places the microphone
/// at the monitor position, captures, then at the ear position, captures; the ratio per tone follows.
/// Measurement and control plane only: it never plays anything, never arms anything, and is never read
/// by the arm path. A finished survey is kept across launches (E4 G19, `QuietZoneSurveyPersistence`) and is trusted
/// again only when the monitor position and the ear position's measured speaker paths are unchanged; the listener's
/// "quiet the ear position" choice is never restored, so each launch starts with the monitor design.
@MainActor
final class QuietZoneVirtualMicSurveyController: ObservableObject {
    enum Visit: Equatable, Sendable { case monitor, ear }

    enum Phase: Equatable {
        case idle
        case capturing(Visit)
        case ready
    }

    /// Windows collected per visit. At about 4 windows per second this is a few seconds at each position.
    static let windowsPerVisit = 8

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = 0
    @Published private(set) var message = "Capture the noise at the monitor microphone, then at the ear position."
    @Published private(set) var tones: [QuietZoneEarTone] = []
    @Published private(set) var monitorCaptured = false
    @Published private(set) var ear: (id: UUID, name: String)?
    /// The listener's choice to design the quiet zone at the ear (needs a surveyed tone).
    @Published var useAtEar = false

    /// Set by the controller: paths for one tone and the chosen ear position.
    var paths: ((_ frequencyHz: Double, _ earPositionID: UUID) throws -> QuietZoneSurveyPaths)?
    /// Set by the controller: Room Correction positions that can serve as the ear position.
    var candidates: (() -> [(id: UUID, name: String)])?
    /// Set by the controller: the Room Correction position the monitor microphone sits at.
    var monitorID: (() -> UUID?)?
    /// True for an other-seat survey (E4 G21): a finished or reused survey switches itself on, because it only ever
    /// tightens the design (the output is scaled back so that seat does not get louder).
    var autoUse = false
    /// Called after the survey changed in a way worth saving (finished, discarded, restarted, other ear chosen).
    var onChanged: (() -> Void)?

    /// What is kept across launches for one survey.
    struct Stored: Codable, Equatable, Sendable {
        var earID: UUID
        var earName: String
        var monitorID: UUID?
        var tones: [QuietZoneEarTone]
    }

    /// A stored survey waiting for the room measurements to load so it can be checked.
    private var pending: Stored?

    private var monitorPhasors: [Double: [ActiveQuietZoneComplex]] = [:]
    private var earPhasors: [Double: [ActiveQuietZoneComplex]] = [:]
    private var windows = 0

    var isCapturing: Bool { if case .capturing = phase { return true } else { return false } }

    /// True when the controller should design at the ear.
    var isActive: Bool { useAtEar && !tones.isEmpty }

    var earPositionCandidates: [(id: UUID, name: String)] { candidates?() ?? [] }

    func selectEar(_ id: UUID?) {
        guard id != ear?.id else { return }
        discardSurvey()
        guard let id, let entry = earPositionCandidates.first(where: { $0.id == id }) else { ear = nil; return }
        ear = (entry.id, entry.name)
        onChanged?()
    }

    /// The survey to save: the live one, or one still waiting to be checked after a launch.
    var stored: Stored? {
        if let ear, !tones.isEmpty { return Stored(earID: ear.id, earName: ear.name, monitorID: monitorID?(), tones: tones) }
        return pending
    }

    var hasPendingRestore: Bool { pending != nil }

    /// Hands over a survey read from disk. It is checked and shown by `restoreIfPossible`.
    func offerStored(_ value: Stored?) {
        guard tones.isEmpty, !isCapturing else { return }
        pending = value
    }

    /// Shows a stored survey once the room measurements are loaded, and only if the ear position still exists, the
    /// monitor position is the same and the ear's speaker paths are what they were. Otherwise it is dropped with a
    /// message (after the measurements are available) or kept waiting (before).
    func restoreIfPossible() {
        guard let stored = pending, tones.isEmpty, ear == nil, !isCapturing, let paths,
              let entry = earPositionCandidates.first(where: { $0.id == stored.earID }) else { return }
        func close(_ a: ActiveQuietZoneComplex, _ b: ActiveQuietZoneComplex) -> Bool {
            let scale = max(a.magnitude, b.magnitude, 1.0e-12)
            return hypot(a.real - b.real, a.imaginary - b.imaginary) <= 1.0e-6 * scale
        }
        var changed = stored.monitorID != monitorID?() || stored.tones.isEmpty
        if !changed {
            for tone in stored.tones {
                guard tone.isFinite, let now = try? paths(tone.frequencyHz, stored.earID),
                      close(now.earLeft, tone.earLeft), close(now.earRight, tone.earRight) else { changed = true; break }
            }
        }
        pending = nil
        if changed {
            message = "The room measurements changed since the last survey, so it was not reused. Capture it again."
            onChanged?()
            return
        }
        ear = (entry.id, entry.name)
        tones = stored.tones
        useAtEar = autoUse
        phase = .ready
        message = "Reused the survey from last time (\(stored.tones.count) tone\(stored.tones.count == 1 ? "" : "s")). Switch on the quiet zone at the ear when you want it."
    }

    func beginVisit(_ visit: Visit) {
        guard ear != nil else { message = "Choose the Room Correction position that is at the ear first."; return }
        if visit == .ear, !monitorCaptured { message = "Capture at the monitor microphone first."; return }
        windows = 0
        progress = 0
        switch visit {
        case .monitor:
            pending = nil
            tones = []
            useAtEar = false
            monitorPhasors = [:]
            earPhasors = [:]
            monitorCaptured = false
            onChanged?()
        case .ear:
            earPhasors = [:]
        }
        phase = .capturing(visit)
        message = "Capturing at the \(visit == .monitor ? "monitor microphone" : "ear position"). Keep the microphone still. Quiet Zone must be on and cancelling."
    }

    func cancelVisit() {
        guard isCapturing else { return }
        phase = tones.isEmpty ? .idle : .ready
        message = "Capture cancelled."
    }

    /// One window of the controller's per-tone uncancelled-noise phasors (oscillator frame).
    func ingestWindow(_ phasors: [Double: ActiveQuietZoneComplex]) {
        guard case .capturing(let visit) = phase else { return }
        windows += 1
        for (frequency, phasor) in phasors where phasor.real.isFinite && phasor.imaginary.isFinite {
            switch visit {
            case .monitor: monitorPhasors[frequency, default: []].append(phasor)
            case .ear: earPhasors[frequency, default: []].append(phasor)
            }
        }
        progress = windows
        if windows >= Self.windowsPerVisit { finishVisit(visit) }
    }

    private func finishVisit(_ visit: Visit) {
        switch visit {
        case .monitor:
            monitorPhasors = monitorPhasors.filter { $0.value.count >= QuietZoneVirtualMicrophone.minimumRepeats }
            guard !monitorPhasors.isEmpty else {
                phase = .idle
                message = "No steady tone was present at the monitor microphone. Wait for Quiet Zone to find a tone and capture again."
                return
            }
            monitorCaptured = true
            phase = .idle
            message = "Monitor captured (\(monitorPhasors.count) tones). Move the microphone to the ear position, then capture there."
        case .ear:
            computeSurvey()
        }
    }

    private func computeSurvey() {
        guard let earID = ear?.id, let paths else {
            phase = .idle
            message = "No acoustic model is available for the ear position."
            return
        }
        var out: [QuietZoneEarTone] = []
        var skipped: [String] = []
        for frequency in monitorPhasors.keys.sorted() {
            guard let match = earPhasors.first(where: { abs($0.key - frequency) < 0.01 }),
                  match.value.count >= QuietZoneVirtualMicrophone.minimumRepeats else {
                skipped.append(String(format: "%.1f Hz absent at the ear", frequency))
                continue
            }
            do {
                let p = try paths(frequency, earID)
                let survey = try QuietZoneVirtualMicrophone.survey(
                    monitor: [QuietZoneVirtualMicVisit(frequencyHz: frequency, phasors: monitorPhasors[frequency] ?? [])],
                    ear: [QuietZoneVirtualMicVisit(frequencyHz: frequency, phasors: match.value)],
                    monitorSecondary: [p.monitorLeft + p.monitorRight],
                    earSecondary: [p.earLeft + p.earRight])
                guard let tone = survey.tones.first else { continue }
                out.append(QuietZoneEarTone(
                    frequencyHz: frequency, ratio: tone.ratio,
                    earLeft: p.earLeft, earRight: p.earRight,
                    effectiveSecondary: tone.effectiveSecondary))
            } catch {
                skipped.append(String(format: "%.1f Hz: %@", frequency, Self.describe(error)))
            }
        }
        tones = out
        useAtEar = autoUse && !out.isEmpty
        defer { onChanged?() }
        if out.isEmpty {
            phase = .idle
            message = "No tone could be surveyed (" + skipped.joined(separator: "; ") + "). Capture again."
        } else {
            phase = .ready
            message = "Surveyed \(out.count) tone\(out.count == 1 ? "" : "s"). Move the microphone back to the monitor position, then switch on the quiet zone at the ear."
                + (skipped.isEmpty ? "" : " Skipped: " + skipped.joined(separator: "; ") + ".")
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? QuietZoneVirtualMicError {
        case .tooFewRepeats: return "too few readings"
        case .unsteadyNoise: return "noise not steady"
        case .monitorTooQuiet: return "too quiet at the monitor"
        case .implausibleRatio: return "ear and monitor too far apart"
        case .noAuthorityAtEar: return "speakers cannot be told apart at the ear"
        case .mismatchedTones: return "tones do not match"
        case nil: return error.localizedDescription
        }
    }

    func discardSurvey() {
        pending = nil
        defer { onChanged?() }
        tones = []
        useAtEar = false
        monitorCaptured = false
        monitorPhasors = [:]
        earPhasors = [:]
        phase = .idle
        progress = 0
        message = "Capture the noise at the monitor microphone, then at the ear position."
    }

    /// E4 S26b: when set and following the head, the head position picks the ear tone instead of the one fixed survey.
    private(set) var headFollow: QuietZoneHeadFollowController?
    /// E4 S27: with the zone chooser attached, head follow picks the tone only in follow mode. Always true without it.
    var headFollowGate: () -> Bool = { true }

    func attachHeadFollow(_ follow: QuietZoneHeadFollowController?) {
        headFollow = follow
        objectWillChange.send()
    }

    /// The surveyed tone for a controlled frequency, or nil when none lies within 0.5 Hz of it. While head follow has a
    /// fresh pose inside the saved positions, the tone is blended for the head's position; otherwise the fixed survey.
    func earTone(near frequencyHz: Double) -> QuietZoneEarTone? {
        guard isActive else { return nil }
        guard let fixed = tones.min(by: { abs($0.frequencyHz - frequencyHz) < abs($1.frequencyHz - frequencyHz) }),
              abs(fixed.frequencyHz - frequencyHz) <= 0.5 else { return nil }
        guard headFollowGate() else { return fixed }
        return headFollow?.tone(near: frequencyHz) ?? fixed
    }
}
