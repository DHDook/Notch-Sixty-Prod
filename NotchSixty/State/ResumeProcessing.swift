import AppKit
import AVFoundation
import Combine
import Foundation

// E12 S24 (behind `e12.settings-page`): resume processing when the app opens, and the permission status rows.
// Swift only; the engine never reads the flag or these keys. Resume starts through the normal start path (with its
// normal fade-in) and never arms anything: `LiveTreatmentArm` is not persisted and stays off after every launch.

extension PreferenceKeys.Application {
    /// The Settings switch (owner decision 16: off by default).
    static let resumeProcessingOnOpen = "application.resumeProcessingOnOpen"
    /// True while a session is open (set at launch, cleared by a clean quit). Still true at the next launch means the
    /// last run ended without a clean quit (crash or force-quit).
    static let resumeSessionOpen = "application.resume.sessionOpen"
    /// True when the last clean quit happened while processing was running.
    static let resumeRunningAtCleanQuit = "application.resume.runningAtCleanQuit"
    /// The stable UID of the output at that clean quit.
    static let resumeOutputUID = "application.resume.outputUID"
    /// True once processing has run on this Mac (the only sign of system-audio permission macOS lets us read).
    static let systemAudioHasRun = "application.permissions.systemAudioHasRun"
}

/// Why processing was left stopped at launch. `message` is shown on the Dashboard.
enum ResumeSkipReason: Equatable, Sendable {
    case outputMissing
    case lastExitUnclean
    case startFailed(String)

    var message: String {
        switch self {
        case .outputMissing:
            return "Processing was not resumed because the output device from last time is not connected. Reconnect it and press Start."
        case .lastExitUnclean:
            return "Processing was not resumed because Notch Sixty did not close normally last time. Press Start when you are ready."
        case .startFailed(let detail):
            return "Processing could not be resumed: \(detail)"
        }
    }
}

enum ResumeDecision: Equatable, Sendable {
    case resume
    /// Stay stopped. `reason` is nil when nothing needs saying (switch off, or it was not running).
    case stayStopped(ResumeSkipReason?)
}

enum ResumePolicy {
    static func decide(
        switchOn: Bool,
        previousSessionClean: Bool,
        wasRunningAtCleanQuit: Bool,
        storedOutputUID: String?,
        currentOutputUID: String?,
        availableOutputUIDs: Set<String>
    ) -> ResumeDecision {
        guard switchOn else { return .stayStopped(nil) }
        // A crash or force-quit never counts as "was running", so a setup that crashes on start cannot loop.
        guard previousSessionClean else { return .stayStopped(.lastExitUnclean) }
        guard wasRunningAtCleanQuit else { return .stayStopped(nil) }
        guard let stored = storedOutputUID, stored == currentOutputUID, availableOutputUIDs.contains(stored) else {
            return .stayStopped(.outputMissing)
        }
        return .resume
    }
}

/// Persists the facts resume needs. Injectable defaults for tests.
struct ResumeProcessingStore {
    var defaults: UserDefaults = .standard
    typealias K = PreferenceKeys.Application

    struct Launch: Equatable {
        var previousSessionClean: Bool
        var wasRunningAtCleanQuit: Bool
        var outputUID: String?
    }

    var switchOn: Bool { defaults.bool(forKey: K.resumeProcessingOnOpen) }

    /// Reads what the last run left, then marks this session open and clears the running mark, so only a clean quit
    /// of this session can make the next launch resume.
    func beginSession() -> Launch {
        let launch = Launch(
            previousSessionClean: !defaults.bool(forKey: K.resumeSessionOpen),
            wasRunningAtCleanQuit: defaults.bool(forKey: K.resumeRunningAtCleanQuit),
            outputUID: defaults.string(forKey: K.resumeOutputUID))
        defaults.set(true, forKey: K.resumeSessionOpen)
        defaults.set(false, forKey: K.resumeRunningAtCleanQuit)
        return launch
    }

    func recordCleanQuit(running: Bool, outputUID: String?) {
        defaults.set(running, forKey: K.resumeRunningAtCleanQuit)
        defaults.set(outputUID, forKey: K.resumeOutputUID)
        defaults.set(false, forKey: K.resumeSessionOpen)
    }
}

/// What the coordinator needs from the product; tests inject a fake.
@MainActor
protocol ResumeTarget: AnyObject {
    var isProcessingRunning: Bool { get }
    var selectedOutputUID: String? { get }
    var availableOutputUIDs: Set<String> { get }
    func startProcessing() async throws
}

@MainActor
final class ResumeProcessingCoordinator: ObservableObject {
    /// Why the last launch left processing stopped; the Dashboard shows it.
    @Published private(set) var skippedReason: ResumeSkipReason?
    private let store: ResumeProcessingStore
    private let defaults: UserDefaults
    private var didBegin = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store = ResumeProcessingStore(defaults: defaults)
    }

    /// Called once per launch, after the product is prepared. With the flag off nothing is read or written.
    func resumeIfNeeded(target: ResumeTarget, flagEnabled: Bool) async {
        guard flagEnabled, !didBegin else { return }
        didBegin = true
        let launch = store.beginSession()
        let decision = ResumePolicy.decide(
            switchOn: store.switchOn,
            previousSessionClean: launch.previousSessionClean,
            wasRunningAtCleanQuit: launch.wasRunningAtCleanQuit,
            storedOutputUID: launch.outputUID,
            currentOutputUID: target.selectedOutputUID,
            availableOutputUIDs: target.availableOutputUIDs)
        switch decision {
        case .stayStopped(let reason):
            skippedReason = reason
        case .resume:
            guard !target.isProcessingRunning else { return }
            do { try await target.startProcessing() } catch {
                skippedReason = .startFailed(error.localizedDescription)
            }
        }
    }

    /// Called from the clean-quit path before the engine stops. Does nothing when the session was never begun
    /// (flag off), so the keys stay untouched.
    func recordCleanQuit(target: ResumeTarget) {
        guard didBegin else { return }
        store.recordCleanQuit(running: target.isProcessingRunning, outputUID: target.selectedOutputUID)
    }

    /// Remembers that processing has run, the one sign of system-audio permission macOS lets us read.
    func noteProcessingRan(target: ResumeTarget) {
        if target.isProcessingRunning { defaults.set(true, forKey: PreferenceKeys.Application.systemAudioHasRun) }
    }
}

extension ProductController: ResumeTarget {
    var isProcessingRunning: Bool { audioEngine.lifecycleState == .running }
    var selectedOutputUID: String? { audioEngine.routeConfiguration.selectedOutputUID }
    var availableOutputUIDs: Set<String> { Set(audioEngine.outputDevices.map(\.uid)) }

    func resumeProcessingIfNeeded() async {
        await resume.resumeIfNeeded(
            target: self, flagEnabled: FeatureFlags.isEnabledProcessWide(.settingsPage))
    }
}

// MARK: Permission status

enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case systemAudio, microphone, camera
    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemAudio: return "System Audio"
        case .microphone: return "Measurement Microphone"
        case .camera: return "Camera (head tracking)"
        }
    }

    var explanation: String {
        switch self {
        case .systemAudio: return "macOS asks for this when Notch Sixty first needs to hear your Mac's audio."
        case .microphone: return "macOS asks for this only when you start a measurement that uses a microphone."
        case .camera: return "macOS asks for this only when you turn on head tracking. The camera image never leaves this Mac."
        }
    }

    /// The Privacy & Security pane that holds this permission.
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .systemAudio: anchor = "Privacy_AudioCapture"
        case .microphone: anchor = "Privacy_Microphone"
        case .camera: anchor = "Privacy_Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

enum PermissionState: Equatable, Sendable {
    case granted, denied, notAskedYet
    /// macOS gives no way to read this one; shown with an explanation, never as "denied".
    case unknown

    var label: String {
        switch self {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .notAskedYet: return "Not asked yet"
        case .unknown: return "Asked when needed"
        }
    }

    init(_ status: MicrophonePermissionStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notAskedYet
        case .denied, .restricted: self = .denied
        }
    }

    init(video status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notAskedYet
        default: self = .denied
        }
    }
}

protocol PermissionStatusReading {
    func state(for kind: PermissionKind) -> PermissionState
}

/// Reads the real statuses. System audio has no public status call, so it reads "Allowed" once audio has been
/// processed on this Mac and "Asked when needed" before that.
struct SystemPermissionStatusReader: PermissionStatusReading {
    var defaults: UserDefaults = .standard

    func state(for kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone:
            return PermissionState(AVFoundationMicrophonePermissionClient().currentStatus())
        case .camera:
            return PermissionState(video: AVCaptureDevice.authorizationStatus(for: .video))
        case .systemAudio:
            return defaults.bool(forKey: PreferenceKeys.Application.systemAudioHasRun) ? .granted : .unknown
        }
    }
}

@MainActor
final class PermissionStatusModel: ObservableObject {
    @Published private(set) var states: [PermissionKind: PermissionState] = [:]
    private let reader: PermissionStatusReading
    private let openURL: (URL) -> Void

    init(reader: PermissionStatusReading = SystemPermissionStatusReader(),
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.reader = reader
        self.openURL = openURL
        refresh()
    }

    /// Called when the Settings window becomes active.
    func refresh() {
        states = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, reader.state(for: $0)) })
    }

    func state(_ kind: PermissionKind) -> PermissionState { states[kind] ?? .unknown }
    func openSystemSettings(for kind: PermissionKind) { openURL(kind.settingsURL) }
}
