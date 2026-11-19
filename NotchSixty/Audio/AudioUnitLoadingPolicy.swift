import AudioToolbox
import AVFAudio
import Foundation

/// E33 S22 (`e33.page-enhancements`): how Audio Unit effects are loaded.
///
/// Flag off: unchanged. A component not reported sandbox-safe is rejected and the rest load in this process.
/// Flag on: every plug-in is instantiated with `.loadOutOfProcess` (the system hosts it in its own process), so the
/// sandbox-safe rejection is dropped (owner decision 26, 17 Nov 2026). There is no in-process option. No privileged
/// helper, no driver and no sandbox exception: the system's Audio Unit hosting service does the hosting.
///
/// Control plane only. The realtime render path is unchanged: a plug-in process that stops makes the render call fail,
/// which trips the stage's fault gate (dry audio at the reported latency) and quarantines the plug-in.
enum AudioUnitLoadingPolicy {
    /// Read process-wide (the offline and live builders run off the MainActor); the engine never reads the flag.
    nonisolated static var separateProcessEnabled: Bool {
        FeatureFlags.isEnabledProcessWide(.eqPageEnhancements)
    }

    nonisolated static func instantiationOptions(
        separateProcess: Bool = separateProcessEnabled
    ) -> AudioComponentInstantiationOptions {
        separateProcess ? .loadOutOfProcess : []
    }

    /// Plain sentence shown with a quarantined plug-in whose process stopped.
    static let processStoppedDescription =
        "The plug-in's own process stopped or failed to render. Audio keeps playing without it; its delay is kept so the rest stays in time."
}

/// Counts installed effects by the reason this app would reject them, so the size of the sandbox-safe limit is known.
/// A component can have several reasons; `onlySandbox` counts those whose only reason is the sandbox-safe flag, which is
/// exactly the set separate-process loading is expected to win back.
struct AudioUnitRejectionCensus: Equatable, Sendable {
    var total = 0
    var accepted = 0
    var notEffectKind = 0
    var failsValidation = 0
    var notSandboxSafe = 0
    var noChannelSupport = 0
    var onlySandbox = 0
    var acceptedSeparateProcess = 0

    init(
        descriptors: [AudioUnitComponentDescriptor],
        channelCount: Int
    ) {
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: channelCount,
            maximumFramesPerSlice: 512
        )
        for descriptor in descriptors {
            total += 1
            if descriptor.kind == .unsupported { notEffectKind += 1 }
            if !descriptor.passesAUVal { failsValidation += 1 }
            if !descriptor.sandboxSafe { notSandboxSafe += 1 }
            if !descriptor.supports(channelCount: channelCount) {
                noChannelSupport += 1
            }
            let today = descriptor.compatibility(
                for: format, separateProcess: false
            )
            let separate = descriptor.compatibility(
                for: format, separateProcess: true
            )
            if today.compatible { accepted += 1 }
            if separate.compatible { acceptedSeparateProcess += 1 }
            if !today.compatible, separate.compatible { onlySandbox += 1 }
        }
    }

    var summary: String {
        "installed=\(total) acceptedToday=\(accepted) "
            + "notEffectKind=\(notEffectKind) failsValidation=\(failsValidation) "
            + "notSandboxSafe=\(notSandboxSafe) noChannelSupport=\(noChannelSupport) "
            + "rejectedOnlyBySandboxFlag=\(onlySandbox) "
            + "acceptedWithSeparateProcess=\(acceptedSeparateProcess)"
    }
}
