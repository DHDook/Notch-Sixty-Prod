import Foundation

// E25 S3: pure logic behind the wizard's Outputs and Speakers steps. Builds a `SystemArrangement` from the user's
// choices, migrates a schema-1 session, and lists the capability rows the Speakers step closes with. No SwiftUI,
// no engine, rate-free; nothing here runs on an audio thread.

/// What the Speakers step edits, before it becomes a `SystemArrangement`.
struct SystemSetupSpeakerChoices: Equatable, Sendable {
    var layout: OutputProgramLayout = .stereo
    var bass: BassHandling = .fullRange
    /// Physical subs, including subs a receiver drives (0 to 8).
    var subwooferCount = 0
    /// E26 S1: how a downstream receiver or powered sub handles bass. Kept only while bass is downstream.
    var receiverBass: ReceiverBass = .undeclared
}

enum SystemSetupArrangementPlanner {
    /// Channels the user can pick for the Outputs step: two up to what the device reports, never above it.
    static func channelChoices(detected: Int) -> [Int] {
        detected >= 2 ? Array(2...min(detected, 64)) : [2]
    }

    /// The bass handling choices that make sense for this many output channels and speakers.
    static func bassChoices(channelsInUse: Int, layout: OutputProgramLayout) -> [BassHandling] {
        var choices: [BassHandling] = [.fullRange]
        if channelsInUse == 2 {
            choices.append(.dspMonoToMains)
            choices.append(.downstreamReceiver)
            choices.append(.downstreamSubCrossover)
        } else {
            choices.append(.dspToSubOutputs)
        }
        return choices
    }

    static func title(_ bass: BassHandling) -> String {
        switch bass {
        case .fullRange: return "All speakers play full range"
        case .dspToSubOutputs: return "This app sends bass to subwoofer outputs"
        case .dspMonoToMains: return "Share the bass between the two speakers (mono bass)"
        case .downstreamReceiver: return "My receiver handles bass"
        case .downstreamSubCrossover: return "My powered subwoofer has its own crossover"
        }
    }

    /// Builds the arrangement for the choices. Output channels are assigned in layout order (non-LFE roles first,
    /// then one output per DSP-fed sub). Two channels with a wider layout means a receiver drives the other
    /// speakers from the two feeds.
    static func arrangement(
        deviceUID: String, detectedChannelCount: Int, channelsInUse: Int,
        choices: SystemSetupSpeakerChoices, keeping previous: SystemArrangement? = nil
    ) -> SystemArrangement {
        let inUse = max(2, detectedChannelCount > 0 ? min(channelsInUse, detectedChannelCount) : channelsInUse)
        let outputs = SystemOutputs(
            deviceUID: deviceUID, detectedChannelCount: detectedChannelCount, channelsInUse: inUse)
        func endpoint(_ index: Int) -> PhysicalOutputEndpoint {
            PhysicalOutputEndpoint(deviceUID: deviceUID, channelIndex: UInt32(index))
        }
        let roles = choices.layout.roles.filter { $0 != .lowFrequencyEffects }
        var speakers: [ArrangedSpeaker] = []
        var subOutputs: [PhysicalOutputEndpoint] = []
        var subCount = choices.subwooferCount
        var bass = choices.bass
        var layout = choices.layout
        if inUse == 2 {
            if bass == .dspToSubOutputs { bass = .fullRange }
            if !bass.isDownstream && layout != .stereo { layout = .stereo }
            let wide = roles.count > 2 && bass.isDownstream
            for (i, role) in roles.enumerated() {
                if wide {
                    speakers.append(ArrangedSpeaker(role: role, feed: .viaDownstream([0, 1])))
                } else if i < 2 {
                    speakers.append(ArrangedSpeaker(role: role, feed: .direct(endpoint(i))))
                }
            }
            if bass == .dspMonoToMains || bass == .fullRange { subCount = 0 }
        } else {
            for (i, role) in roles.enumerated() where i < inUse {
                speakers.append(ArrangedSpeaker(role: role, feed: .direct(endpoint(i))))
            }
            if bass == .dspToSubOutputs {
                subCount = min(max(subCount, 1), SystemArrangement.maxSubwoofers)
                subOutputs = (0..<subCount).map { endpoint(roles.count + $0) }
            } else {
                subCount = bass == .fullRange ? 0 : subCount
            }
        }
        var result = SystemArrangement(
            outputs: outputs, layout: layout, bass: bass, subwooferCount: subCount,
            subOutputs: subOutputs, speakers: speakers, realisation: previous?.realisation ?? .profile,
            stereoAlignment: previous?.stereoAlignment,
            receiverBass: bass.isDownstream && choices.receiverBass.isValid ? choices.receiverBass : .undeclared)
        if inUse >= 3 { result.stereoAlignment = nil }
        return result
    }

    /// Speaker choices a stored arrangement describes, to pre-fill the step.
    static func choices(from arrangement: SystemArrangement) -> SystemSetupSpeakerChoices {
        SystemSetupSpeakerChoices(
            layout: arrangement.layout, bass: arrangement.bass, subwooferCount: arrangement.subwooferCount,
            receiverBass: arrangement.receiverBass)
    }

    /// Design note 8: a schema-1 session carries a topology; it becomes an arrangement. 2.1 and 2.2 become DSP
    /// subwoofer outputs when the device has the channels, otherwise mono bass on the pair with a note (the session
    /// then resumes at Speakers).
    static func migrate(
        topology: SystemSetupTopology, deviceUID: String, detectedChannelCount: Int
    ) -> (arrangement: SystemArrangement, note: String?, resumeAtSpeakers: Bool) {
        switch topology {
        case .stereo:
            let a = arrangement(
                deviceUID: deviceUID, detectedChannelCount: detectedChannelCount, channelsInUse: 2,
                choices: SystemSetupSpeakerChoices())
            return (a, nil, false)
        case .twoPointOne, .twoPointTwo:
            let subs = topology == .twoPointOne ? 1 : 2
            let needed = 2 + subs
            if detectedChannelCount >= needed {
                let a = arrangement(
                    deviceUID: deviceUID, detectedChannelCount: detectedChannelCount, channelsInUse: needed,
                    choices: SystemSetupSpeakerChoices(layout: .stereo, bass: .dspToSubOutputs, subwooferCount: subs))
                return (a, nil, false)
            }
            let a = arrangement(
                deviceUID: deviceUID, detectedChannelCount: detectedChannelCount, channelsInUse: 2,
                choices: SystemSetupSpeakerChoices(layout: .stereo, bass: .dspMonoToMains, subwooferCount: 0))
            return (a, "This output has only two channels, so the subwoofer is set to mono bass on the pair. Check the Speakers step.", true)
        }
    }

    /// Features the Speakers step's closing card lists, in this order.
    static let summaryFeatures: [SystemFeature] = [
        .stereoPlayback, .monoBassOnPair, .dspSubFeed, .widerProgram, .perFeedCalibration, .subAlignment,
        .multiSubOptimiser, .roomCorrection,
    ]

    /// Matrix rows for the arrangement: every row carries its reason when unavailable.
    static func capabilityRows(
        _ arrangement: SystemArrangement, deviceChannelCount: Int
    ) -> [(feature: SystemFeature, availability: CapabilityAvailability)] {
        summaryFeatures.map {
            ($0, SystemCapabilityMatrix.evaluate($0, arrangement: arrangement, deviceChannelCount: deviceChannelCount))
        }
    }

    /// The arrangement's compile outcome as a user message, nil when it compiles.
    static func refusal(_ arrangement: SystemArrangement, preserving: OutputDeviceProfileConfiguration?) -> String? {
        if case .failure(let issue) = SystemArrangementCompiler.compile(arrangement, preserving: preserving) {
            return issue.errorDescription ?? "This arrangement cannot be used."
        }
        return nil
    }
}
