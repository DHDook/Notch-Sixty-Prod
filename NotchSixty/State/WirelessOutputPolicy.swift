import Foundation

/// E15 S6 (design note 15, owner question Q6, built to the recommendation): what Notch Sixty does differently on a
/// wireless output (Bluetooth, Bluetooth LE, AirPlay). Pure, Swift only, and behind `e15.follow-output`: every entry
/// point takes `flagOn` so the flag-off path is the unchanged behaviour. Nothing here arms anything; it only refuses.
///
/// - The rate is the device's nominal rate, never changed and never resampled by the app.
/// - A new Playback System made for a wireless device starts with low-latency defaults (minimum-phase room correction,
///   no linear-phase EQ); an existing system is never rewritten and gets a note when it adds more than 20 ms.
/// - Quiet Zone, feed-forward ANC, MIMO room treatment and measurements are refused, because the device's own delay
///   varies and anti-noise or a measured delay cannot be trusted across it.
enum WirelessOutputPolicy {
    /// The most delay Notch Sixty's own DSP should add on a wireless output (Q6b).
    static let latencyBudgetMilliseconds = 20.0
    /// A Bluetooth rate below this means the headset profile (a microphone is open).
    static let headsetModeBelowHz = 32_000.0

    /// True when `transport` is wireless and the epic flag is on.
    static func applies(_ transport: OutputTransportKind?, flagOn: Bool) -> Bool {
        flagOn && transport?.isWireless == true
    }

    // MARK: Refusals (reason `.wirelessOutput`)

    static let liveTreatmentRefusal =
        "Not available on a wireless output: its delay changes, so anti-noise cannot be timed. Choose a wired output."
    static let measurementRefusal =
        "Not available on a wireless output: its delay changes, so a measurement would not match what you hear. Choose a wired output."

    // MARK: Rate note

    /// "Headset mode (a microphone is open)" for a Bluetooth output running below 32 kHz; nil otherwise. The engine runs
    /// at the device's own rate: this is information only and never changes or resamples anything.
    static func rateNote(transport: OutputTransportKind?, nominalRateHz: Double?, flagOn: Bool) -> String? {
        guard flagOn, let transport, transport == .bluetooth || transport == .bluetoothLE,
              let rate = nominalRateHz, rate > 0, rate < headsetModeBelowHz else { return nil }
        return "Bluetooth is in headset mode (a microphone is open) at \(Self.rateText(rate)). Audio plays at that rate with no resampling."
    }

    private static func rateText(_ hz: Double) -> String {
        hz.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(hz / 1000)) kHz" : String(format: "%.1f kHz", hz / 1000)
    }

    // MARK: New-system defaults

    /// The choices a new Playback System starts with on a wireless output.
    struct NewSystemDefaults: Equatable {
        var correctionMode: SystemSetupCorrectionMode
        var eqPhaseMode: EQPhaseMode
        var budgetMilliseconds: Double
    }

    /// nil when the output is not wireless or the flag is off (the normal defaults apply).
    static func newSystemDefaults(transport: OutputTransportKind?, flagOn: Bool) -> NewSystemDefaults? {
        guard applies(transport, flagOn: flagOn) else { return nil }
        return NewSystemDefaults(correctionMode: .video, eqPhaseMode: .minimumPhase, budgetMilliseconds: latencyBudgetMilliseconds)
    }

    /// The room-correction mode to preselect when a new system is set up on this output.
    static func defaultCorrectionMode(transport: OutputTransportKind?, flagOn: Bool) -> SystemSetupCorrectionMode {
        newSystemDefaults(transport: transport, flagOn: flagOn)?.correctionMode ?? .default
    }

    /// The delay, in milliseconds, that `defaults` adds at `sampleRate`: the room-correction budget of the chosen mode
    /// (zero for minimum phase). Minimum-phase EQ adds none. Used to show the defaults stay inside the budget.
    static func addedLatencyMilliseconds(of defaults: NewSystemDefaults) -> Double {
        let correction = defaults.correctionMode.latencyMode.budgetSeconds * 1000
        return correction
    }

    // MARK: Over-budget note for an existing system

    /// "Adds 45 ms on top of the Bluetooth delay" when the running graph adds more than the budget on a wireless output;
    /// nil otherwise. `latencyFrames` is the graph's reported latency (E31's total replaces it when E31 exists).
    static func overBudgetNote(
        latencyFrames: UInt32?, sampleRate: Double?, transport: OutputTransportKind?, flagOn: Bool
    ) -> String? {
        guard applies(transport, flagOn: flagOn), let transport, let latencyFrames, let sampleRate, sampleRate > 0 else { return nil }
        let ms = Double(latencyFrames) / sampleRate * 1000
        guard ms > latencyBudgetMilliseconds else { return nil }
        return "This Playback System adds \(Int(ms.rounded())) ms on top of the \(transport.wirelessName) delay. Linear-phase EQ and long room-correction filters add the most."
    }
}
