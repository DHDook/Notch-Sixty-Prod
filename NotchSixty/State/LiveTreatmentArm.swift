import Foundation

/// The features whose live output is decided by an ARM switch.
enum LiveTreatmentFeature: String, CaseIterable, Sendable {
    /// Speaker ANC (Quiet Zone).
    case quietZone
    /// MIMO room treatment (E19 groundwork; the engine path adopts this switch in a later slice).
    case mimoRoomTreatment
}

/// Why a feature went (or is being taken) from armed to disarmed.
enum LiveTreatmentDisarmReason: String, Equatable, Sendable {
    case user
    case outputDeviceChanged
    case outputDeviceLost
    case sleep
    case sampleRateChanged
    case inputLost
    case microphoneInvalid
    case engineStopped
    case quit
    case transportReconfigured
    /// The howl / instability detector tripped (`N60AncGuard`).
    case instabilityTrip
    /// No new microphone analysis arrived within `LiveTreatmentSafeguards.analysisStallSeconds`.
    case microphoneStalled
    /// The selected measurement microphone changed.
    case inputDeviceChanged
    /// The output gain (volume, headroom) moved beyond `LiveTreatmentSafeguards.outputGainToleranceDB`.
    case outputGainChanged

    /// Shown in the UI after an automatic disarm. Nil for the user's own action.
    var message: String? {
        switch self {
        case .user: return nil
        case .outputDeviceChanged: return "Disarmed: the output device changed. Re-arm to continue."
        case .outputDeviceLost: return "Disarmed: the output device was lost. Re-arm to continue."
        case .sleep: return "Disarmed: the Mac went to sleep. Re-arm to continue."
        case .sampleRateChanged: return "Disarmed: the sample rate changed. Re-arm to continue."
        case .inputLost: return "Disarmed: a measurement microphone was lost. Re-arm to continue."
        case .microphoneInvalid: return "Disarmed: the microphone signal was invalid or silent. Re-arm to continue."
        case .engineStopped: return "Disarmed: audio processing stopped. Re-arm to continue."
        case .quit: return "Disarmed: Notch Sixty is quitting."
        case .transportReconfigured: return "Disarmed: the audio path was rebuilt. Re-arm to continue."
        case .instabilityTrip: return "Muted: instability detected. Re-arm to continue."
        case .microphoneStalled: return "Disarmed: the microphone analysis stopped updating. Re-arm to continue."
        case .inputDeviceChanged: return "Disarmed: the measurement microphone changed. Re-arm to continue."
        case .outputGainChanged: return "Disarmed: the output volume changed. Re-arm to continue."
        }
    }
}

/// Why the engine tore its transport down; the engine reports it, the arm switch decides.
enum TransportTeardownCause: Equatable, Sendable {
    case stop
    case quit
    case sleep
    case outputLost
    /// Device-driven or user-driven rebuild (rate change, route change).
    case reconfiguration
    /// The app's own low-latency profile switch. Does not disarm: arming itself causes it.
    case plannedProfileChange
    case other

    var disarmReason: LiveTreatmentDisarmReason? {
        switch self {
        case .stop, .other: return .engineStopped
        case .quit: return .quit
        case .sleep: return .sleep
        case .outputLost: return .outputDeviceLost
        case .reconfiguration: return .transportReconfigured
        case .plannedProfileChange: return nil
        }
    }
}

/// What the arm switch watches. Built by the controller from the engine and the microphone.
struct LiveTreatmentEnvironment: Equatable, Sendable {
    var outputDeviceUID: String?
    /// Output sample rate of the running transport; nil when there is none.
    var sampleRate: Double?
    var engineRunning: Bool
    /// False once the reference/error microphone path has failed.
    var inputAvailable: Bool
    /// Latest microphone level when a new measurement arrived since the last observation.
    var microphoneLevelDBFS: Double?
    /// Stable UID of the measurement microphone; nil when unknown (not compared).
    var inputDeviceUID: String? = nil
    /// Output gain from volume and headroom attenuation, dB (0 = unity).
    var outputGainDB: Double = 0
    /// Raw-signal fault in the latest microphone frames (frozen, clipped, offset).
    var microphoneSignalFault: MicrophoneSignalFault? = nil
    /// Live howl-guard trips on the current transport session (E4 S15). Any change from the
    /// value at arming means the guard tripped (a rebuilt session restarts the count).
    var howlGuardTripCount: UInt64 = 0
}

enum LiveTreatmentArmError: Error, Equatable, LocalizedError {
    case engineNotRunning
    case outputUnknown

    var errorDescription: String? {
        switch self {
        case .engineNotRunning: return "Start audio processing before arming."
        case .outputUnknown: return "Select an output device before arming."
        }
    }
}

/// The per-feature ARM switch (owner decision, 27 Oct 2026). It replaces the evidence-based
/// authorisation path: live output may run only while armed.
///
/// - Starts disarmed on every launch and is never persisted: there is no stored state to read.
/// - Arming is one explicit call, `arm(environment:)`.
/// - Any automatic disarm (device change or loss, sleep, rate change, input loss, invalid or
///   silent microphone, engine stop, quit, instability trip) leaves the switch disarmed and
///   latched until the user arms again.
/// - Control plane only (main actor). The realtime path receives the resulting target through
///   the normal snapshot; it never sees this object.
@MainActor
final class LiveTreatmentArm: ObservableObject {
    let feature: LiveTreatmentFeature

    @Published private(set) var isArmed = false
    /// Why the last disarm happened; cleared by the next `arm`. Non-user reasons mean the
    /// switch is latched off until the user re-arms.
    @Published private(set) var lastDisarmReason: LiveTreatmentDisarmReason?

    /// Called once per armed-to-disarmed transition, with the reason. The owner fades its
    /// output out over `LiveTreatmentSafeguards.rampMilliseconds(for:)`.
    var onDisarm: ((LiveTreatmentDisarmReason) -> Void)?

    private var baseline: LiveTreatmentEnvironment?
    private var silentSince: Date?
    private var lastAnalysisAt: Date?

    init(feature: LiveTreatmentFeature) {
        self.feature = feature
    }

    /// True when a non-user event disarmed the switch and the user has not armed again.
    var latchedByEvent: Bool {
        guard let lastDisarmReason else { return false }
        return lastDisarmReason != .user
    }

    var statusMessage: String? { lastDisarmReason?.message }

    /// The single arming action. Requires a running engine and a known output, which become
    /// the baseline the switch then guards.
    func arm(environment: LiveTreatmentEnvironment, now: Date = Date()) throws {
        guard environment.engineRunning, environment.sampleRate != nil else {
            throw LiveTreatmentArmError.engineNotRunning
        }
        guard environment.outputDeviceUID != nil else {
            throw LiveTreatmentArmError.outputUnknown
        }
        baseline = environment
        silentSince = nil
        lastAnalysisAt = now
        lastDisarmReason = nil
        isArmed = true
    }

    /// Disarms. Safe to call at any time; only the first call after arming has an effect.
    func disarm(_ reason: LiveTreatmentDisarmReason) {
        guard isArmed else { return }
        isArmed = false
        baseline = nil
        silentSince = nil
        lastAnalysisAt = nil
        lastDisarmReason = reason
        onDisarm?(reason)
    }

    /// The howl detector reported a trip. Mutes and latches.
    func reportInstabilityTrip() {
        disarm(.instabilityTrip)
    }

    /// Compares the live environment with the one captured at arming. `now` is injectable so
    /// the silence timer is deterministic in tests.
    func observe(_ environment: LiveTreatmentEnvironment, now: Date = Date()) {
        guard isArmed, let baseline else { return }

        if !environment.engineRunning || environment.sampleRate == nil {
            disarm(.engineStopped)
        } else if environment.outputDeviceUID == nil {
            disarm(.outputDeviceLost)
        } else if environment.outputDeviceUID != baseline.outputDeviceUID {
            disarm(.outputDeviceChanged)
        } else if let rate = environment.sampleRate, let was = baseline.sampleRate,
                  abs(rate - was) >= 0.5 {
            disarm(.sampleRateChanged)
        } else if !environment.inputAvailable {
            disarm(.inputLost)
        } else if let uid = baseline.inputDeviceUID, environment.inputDeviceUID != uid {
            disarm(.inputDeviceChanged)
        } else if environment.outputGainDB.isNaN
                    || abs(environment.outputGainDB - baseline.outputGainDB)
                        > LiveTreatmentSafeguards.outputGainToleranceDB {
            disarm(.outputGainChanged)
        } else if environment.howlGuardTripCount != baseline.howlGuardTripCount {
            reportInstabilityTrip()
        } else if environment.microphoneSignalFault != nil {
            disarm(.microphoneInvalid)
        } else if let level = environment.microphoneLevelDBFS {
            lastAnalysisAt = now
            observeMicrophone(level: level, now: now)
        } else if let last = lastAnalysisAt,
                  now.timeIntervalSince(last) >= LiveTreatmentSafeguards.analysisStallSeconds {
            // No new analysis: a frozen or starved microphone path must not leave the arm on.
            disarm(.microphoneStalled)
        }
    }

    private func observeMicrophone(level: Double, now: Date) {
        // Digital silence reads as -infinity and is handled by the silence timer below;
        // NaN and +infinity are a broken signal.
        guard !level.isNaN, level != .infinity else {
            disarm(.microphoneInvalid)
            return
        }
        if level <= LiveTreatmentSafeguards.silentMicrophoneFloorDBFS {
            let since = silentSince ?? now
            silentSince = since
            if now.timeIntervalSince(since) >= LiveTreatmentSafeguards.silentMicrophoneSeconds {
                disarm(.microphoneInvalid)
            }
        } else {
            silentSince = nil
        }
    }

    /// The engine tore its transport down. Disarms unless the cause was the app's own
    /// planned profile change.
    func transportTornDown(_ cause: TransportTeardownCause) {
        guard let reason = cause.disarmReason else { return }
        disarm(reason)
    }
}

/// A fault in the raw error-microphone signal that makes live cancellation unsafe (E4 S12).
enum MicrophoneSignalFault: String, Equatable, Sendable {
    /// Non-finite samples.
    case nonFinite
    /// A block of identical non-zero samples: a stuck or frozen capture buffer.
    case frozen
    /// A large share of samples at full scale.
    case clipped
    /// A large constant offset: a broken or disconnected capture path.
    case directCurrentOffset
}

/// Pure plausibility checks on one block of microphone frames. Control plane only.
enum MicrophoneSignalCheck {
    static let minimumFrames = 64
    /// Samples at or above this magnitude count as clipped.
    static let clipMagnitude: Float = 0.999
    /// Fraction of clipped samples that faults the block.
    static let clippedFraction = 0.01
    /// Mean offset (linear full scale) that faults the block: about -20 dBFS.
    static let offsetLimit = 0.1

    static func assess(_ frames: [Float]) -> MicrophoneSignalFault? {
        guard frames.count >= minimumFrames else { return nil }
        var sum = 0.0
        var clipped = 0
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        for sample in frames {
            guard sample.isFinite else { return .nonFinite }
            sum += Double(sample)
            if abs(sample) >= clipMagnitude { clipped += 1 }
            low = min(low, sample)
            high = max(high, sample)
        }
        // All-zero blocks are digital silence, handled by the silence floor, not "frozen".
        if low == high, low != 0 { return .frozen }
        if Double(clipped) / Double(frames.count) >= clippedFraction { return .clipped }
        if abs(sum / Double(frames.count)) >= offsetLimit { return .directCurrentOffset }
        return nil
    }
}
