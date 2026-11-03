import Foundation

// E25 S1: the one pure compiler from a `SystemArrangement` to the configurations the engine already understands.
// The rule that matters: two channels in use always compile to the stereo session, with no profile and no routing,
// so Quiet Zone and every stereo-session feature stay available. A profile or routing appears only when there is one
// output per speaker (three or more channels), exactly as before.

/// Why an arrangement cannot be compiled. Each case has a user-facing reason.
enum ArrangementIssue: Error, Equatable, Sendable, LocalizedError {
    case tooFewChannels(Int)
    case channelsExceedDevice(inUse: Int, detected: Int)
    case tooManySubwoofers(Int)
    case subCountMismatch(count: Int, outputs: Int)
    case subFeedNeedsThirdOutput
    case monoBassNeedsTwoChannels
    case subOutputsNotAllowed
    case endpointOutOfRange(PhysicalOutputEndpoint)
    case duplicateEndpoint(PhysicalOutputEndpoint)
    case missingSpeaker(OutputProgramRole)
    case speakerNotDirect(OutputProgramRole)
    case profileRejected(String)
    case alignment(StereoBassAlignmentIssue)

    var errorDescription: String? {
        switch self {
        case .tooFewChannels(let n):
            return "At least two output channels are needed (\(n) selected)."
        case .channelsExceedDevice(let inUse, let detected):
            return "\(inUse) output channels are selected but the device exposes \(detected)."
        case .tooManySubwoofers(let n):
            return "At most \(SystemArrangement.maxSubwoofers) subwoofers are supported (\(n) selected)."
        case .subCountMismatch(let count, let outputs):
            return "\(count) subwoofers are listed but \(outputs) sub outputs are assigned."
        case .subFeedNeedsThirdOutput:
            return "A subwoofer feed needs a third output. With two outputs, use mono bass or a downstream sub."
        case .monoBassNeedsTwoChannels:
            return "Mono bass on the pair runs on a two-channel system. With more outputs, feed a subwoofer instead."
        case .subOutputsNotAllowed:
            return "Sub outputs are only used when the DSP feeds the subwoofers."
        case .endpointOutOfRange(let e):
            return "Output \(e.channelIndex + 1) is outside the channels in use."
        case .duplicateEndpoint(let e):
            return "Output \(e.channelIndex + 1) is assigned twice."
        case .missingSpeaker(let role):
            return "\(role.displayName) has no output."
        case .speakerNotDirect(let role):
            return "\(role.displayName) must have its own output when each speaker has one."
        case .profileRejected(let text):
            return text
        case .alignment(let issue):
            return issue.errorDescription
        }
    }
}

/// What the compiler produces. `apply(to:)` writes it onto a playback system state.
struct CompiledArrangement: Equatable, Sendable {
    enum Session: Equatable, Sendable {
        /// The stereo session: Quiet Zone and all stereo features.
        case stereo
        /// An N-channel session from an Output Device Profile.
        case profile
        /// An N-channel session from a speaker routing.
        case routed
    }

    var session: Session
    /// The `bassManagement.enabled` value this arrangement requires.
    var bassManagementEnabled: Bool
    /// Mono bass on the pair (the recombined stereo crossover). Implies `session == .stereo`.
    var monoBassOnPair: Bool
    var outputDeviceProfile: OutputDeviceProfileConfiguration?
    var speakerRouting: SpeakerRoutingConfiguration?
    /// E25 S2: the stereo session's mono-bass filter and speaker feed calibration (two channels only). The mono-bass
    /// filter is kept only when mono bass is on the pair.
    var stereoAlignment: StereoBassAlignment?

    /// Writes the compiled configuration over the state's derived fields. Bass management keeps its frequency,
    /// slope and sub settings; only the switches the arrangement owns change. `outputRouting` (the legacy
    /// multi-device routes) is left alone.
    func apply(to state: PlaybackSystemState) -> PlaybackSystemState {
        var result = state
        result.bassManagement.enabled = bassManagementEnabled
        if monoBassOnPair {
            result.bassManagement.physicalOutputMode = nil
            result.bassManagement.monitorMode = .recombined
        }
        result.outputDeviceProfile = outputDeviceProfile
        result.speakerRouting = speakerRouting
        return result
    }
}

enum SystemArrangementCompiler {
    /// `existing` supplies calibration, optimiser and alignment records to keep when the arrangement recompiles
    /// the same profile (so editing the arrangement never discards a measured deployment).
    static func compile(
        _ arrangement: SystemArrangement,
        preserving existing: OutputDeviceProfileConfiguration? = nil
    ) -> Result<CompiledArrangement, ArrangementIssue> {
        do {
            return .success(try compileThrowing(arrangement, preserving: existing))
        } catch let issue as ArrangementIssue {
            return .failure(issue)
        } catch {
            return .failure(.profileRejected(error.localizedDescription))
        }
    }

    private static func compileThrowing(
        _ a: SystemArrangement,
        preserving existing: OutputDeviceProfileConfiguration?
    ) throws -> CompiledArrangement {
        let inUse = a.outputs.channelsInUse
        guard inUse >= 2 else { throw ArrangementIssue.tooFewChannels(inUse) }
        if a.outputs.detectedChannelCount > 0, inUse > a.outputs.detectedChannelCount {
            throw ArrangementIssue.channelsExceedDevice(inUse: inUse, detected: a.outputs.detectedChannelCount)
        }
        guard (0...SystemArrangement.maxSubwoofers).contains(a.subwooferCount) else {
            throw ArrangementIssue.tooManySubwoofers(a.subwooferCount)
        }

        if inUse == 2 {
            switch a.bass {
            case .dspToSubOutputs: throw ArrangementIssue.subFeedNeedsThirdOutput
            case .fullRange, .dspMonoToMains, .downstreamReceiver, .downstreamSubCrossover: break
            }
            guard a.subOutputs.isEmpty else { throw ArrangementIssue.subOutputsNotAllowed }
            for endpoint in a.speakers.compactMap(\.directEndpoint) where endpoint.channelIndex >= 2 {
                throw ArrangementIssue.endpointOutOfRange(endpoint)
            }
            var alignment = a.stereoAlignment
            if a.bass != .dspMonoToMains { alignment?.monoBassFilter = nil }
            if let issue = alignment?.issue { throw ArrangementIssue.alignment(issue) }
            if alignment?.isStandard == true && alignment?.monoBassFilter == nil { alignment = nil }
            return CompiledArrangement(
                session: .stereo,
                bassManagementEnabled: a.bass == .dspMonoToMains,
                monoBassOnPair: a.bass == .dspMonoToMains,
                outputDeviceProfile: nil,
                speakerRouting: nil,
                stereoAlignment: alignment)
        }

        // One output per speaker.
        if a.bass == .dspMonoToMains { throw ArrangementIssue.monoBassNeedsTwoChannels }
        let managed = a.bass == .dspToSubOutputs
        if managed {
            guard a.subOutputs.count == a.subwooferCount else {
                throw ArrangementIssue.subCountMismatch(count: a.subwooferCount, outputs: a.subOutputs.count)
            }
        } else if !a.subOutputs.isEmpty {
            throw ArrangementIssue.subOutputsNotAllowed
        }

        var seen = Set<PhysicalOutputEndpoint>()
        func check(_ endpoint: PhysicalOutputEndpoint) throws {
            guard Int(endpoint.channelIndex) < inUse else { throw ArrangementIssue.endpointOutOfRange(endpoint) }
            guard seen.insert(endpoint).inserted else { throw ArrangementIssue.duplicateEndpoint(endpoint) }
        }
        var assignments: [SemanticSpeakerOutputAssignment] = []
        for role in a.layout.roles {
            guard let speaker = a.speakers.first(where: { $0.role == role }) else {
                if role == .lowFrequencyEffects && managed { continue }
                throw ArrangementIssue.missingSpeaker(role)
            }
            guard case .direct(let endpoint) = speaker.feed else { throw ArrangementIssue.speakerNotDirect(role) }
            if role == .lowFrequencyEffects && managed { continue }
            try check(endpoint)
            assignments.append(SemanticSpeakerOutputAssignment(
                role: role, destination: endpoint,
                calibration: existing?.speakerAssignments.first { $0.role == role }?.calibration))
        }
        for endpoint in a.subOutputs { try check(endpoint) }

        switch a.realisation {
        case .profile:
            var profile = existing ?? OutputDeviceProfileConfiguration()
            profile.enabled = true
            profile.programLayout = a.layout
            profile.speakerAssignments = assignments
            profile.subwooferAssignments = a.subOutputs.enumerated().map { index, endpoint in
                PhysicalSubwooferOutputAssignment(
                    index: UInt32(index), destination: endpoint,
                    calibration: existing?.subwooferAssignments.first { $0.index == UInt32(index) }?.calibration)
            }
            do { try profile.validateStructure(bassManagementEnabled: managed) } catch {
                throw ArrangementIssue.profileRejected(error.localizedDescription)
            }
            return CompiledArrangement(
                session: .profile, bassManagementEnabled: managed, monoBassOnPair: false,
                outputDeviceProfile: profile, speakerRouting: nil)
        case .routing:
            let lanes = a.layout.roles.filter { $0 != .lowFrequencyEffects }
            let mains = assignments.compactMap { assignment -> SpeakerRoutingTemplate.Main? in
                guard let lane = lanes.firstIndex(of: assignment.role) else { return nil }
                return .init(lane: lane, name: assignment.role.displayName, endpoints: [assignment.destination])
            }
            guard let routing = SpeakerRoutingTemplate.mainsPlusSub.build(mains: mains, subs: a.subOutputs) else {
                throw ArrangementIssue.profileRejected("The speaker routing could not be built.")
            }
            return CompiledArrangement(
                session: .routed, bassManagementEnabled: !a.subOutputs.isEmpty, monoBassOnPair: false,
                outputDeviceProfile: nil, speakerRouting: routing)
        }
    }
}

extension ArrangedSpeaker {
    var directEndpoint: PhysicalOutputEndpoint? {
        if case .direct(let endpoint) = feed { return endpoint }
        return nil
    }
}
