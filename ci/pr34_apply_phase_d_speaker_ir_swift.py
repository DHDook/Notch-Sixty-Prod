from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text()


def write(path: str, text: str) -> None:
    Path(path).write_text(text)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


# CoreAudio transport: expose the third prepared-program path.
path = "NotchSixty/Audio/CoreAudio/CoreAudioError.swift"
text = read(path)
text = replace_once(
    text,
    "    case convolutionProgramPreparationFailed\n    case roomCorrectionProgramPreparationFailed\n",
    "    case convolutionProgramPreparationFailed\n    case roomCorrectionProgramPreparationFailed\n    case speakerIRProgramPreparationFailed\n",
    "transport error case",
)
text = replace_once(
    text,
    "        case .roomCorrectionProgramPreparationFailed:\n            return \"Unable to prepare an inactive room-correction FIR program slot.\"\n",
    "        case .roomCorrectionProgramPreparationFailed:\n            return \"Unable to prepare an inactive room-correction FIR program slot.\"\n        case .speakerIRProgramPreparationFailed:\n            return \"Unable to prepare an inactive Speaker IR FIR program slot.\"\n",
    "transport error text",
)
room_method_tail = """        guard prepared else { throw CoreAudioTransportError.roomCorrectionProgramPreparationFailed }
        return info
    }

    func publishDSPGraph"""
speaker_method = """        guard prepared else { throw CoreAudioTransportError.roomCorrectionProgramPreparationFailed }
        return info
    }

    func prepareSpeakerIRProgram(
        slot: UInt32,
        leftTaps: [Float],
        rightTaps: [Float]? = nil,
        declaredLatencyFrames: UInt32
    ) throws -> N60ConvolutionProgramInfo {
        guard let bridge, !leftTaps.isEmpty else {
            throw CoreAudioTransportError.speakerIRProgramPreparationFailed
        }
        guard rightTaps == nil || rightTaps?.count == leftTaps.count else {
            throw CoreAudioTransportError.speakerIRProgramPreparationFailed
        }

        var info = N60ConvolutionProgramInfo()
        let prepared = leftTaps.withUnsafeBufferPointer { leftBuffer in
            if let rightTaps {
                return rightTaps.withUnsafeBufferPointer { rightBuffer in
                    N60RealtimeAudioBridgePrepareSpeakerIRProgram(
                        bridge,
                        slot,
                        leftBuffer.baseAddress!,
                        rightBuffer.baseAddress!,
                        UInt32(leftBuffer.count),
                        declaredLatencyFrames,
                        &info
                    )
                }
            }
            return N60RealtimeAudioBridgePrepareSpeakerIRProgram(
                bridge,
                slot,
                leftBuffer.baseAddress!,
                nil,
                UInt32(leftBuffer.count),
                declaredLatencyFrames,
                &info
            )
        }
        guard prepared else { throw CoreAudioTransportError.speakerIRProgramPreparationFailed }
        return info
    }

    func publishDSPGraph"""
text = replace_once(text, room_method_tail, speaker_method, "speaker transport method")
write(path, text)


# FIR policy: Speaker IR follows raw Global Bypass but owns its own slot.
path = "NotchSixty/Audio/StereoPlaybackControl.swift"
text = read(path)
room_policy = """    static func shouldPrepareRoomCorrection(
        roomCorrection: RoomCorrectionConfiguration,
        playback: PlaybackControlConfiguration
    ) -> Bool {
        !isRawBypassed(playback) && roomCorrection.enabled
    }
"""
text = replace_once(
    text,
    room_policy,
    room_policy + """
    static func shouldPrepareSpeakerIR(
        speakerIR: SpeakerIRConfiguration,
        playback: PlaybackControlConfiguration
    ) -> Bool {
        !isRawBypassed(playback) && speakerIR.enabled
    }
""",
    "speaker FIR policy",
)
write(path, text)


# Product model and engine lifecycle.
path = "NotchSixty/Audio/AudioIOEngine.swift"
text = read(path)
speaker_models = r'''
struct SpeakerIRFilter: Equatable, Sendable {
    var name: String
    var sampleRate: Double?
    var leftTaps: [Float]
    var rightTaps: [Float]?
    var declaredLatencyFrames: UInt32

    static let validation = SpeakerIRFilter(
        name: "Deterministic Speaker IR validation",
        sampleRate: nil,
        leftTaps: [0.20, 0.60, 0.20],
        rightTaps: nil,
        declaredLatencyFrames: 1
    )

    func validateSampleRate(forOutputSampleRate outputSampleRate: Double) throws {
        guard let sampleRate else { return }
        guard sampleRate.isFinite,
              abs(sampleRate - outputSampleRate) < 0.5 else {
            throw SpeakerIRConfigurationError.sampleRateMismatch(
                filter: sampleRate,
                output: outputSampleRate
            )
        }
    }
}

struct SpeakerIRConfiguration: Equatable, Sendable {
    var enabled = false
    var filter: SpeakerIRFilter?
}

enum SpeakerIRConfigurationError: Error, LocalizedError, Equatable {
    case filterRequired
    case invalidTapCount(Int)
    case mismatchedStereoTapCount(left: Int, right: Int)
    case nonFiniteTap
    case sampleRateMismatch(filter: Double, output: Double)
    case invalidDeclaredLatency(UInt32)
    case convolutionProgramUnavailable
    case graphAttachmentFailed

    var errorDescription: String? {
        switch self {
        case .filterRequired:
            return "Speaker IR cannot be enabled until an impulse response is loaded."
        case .invalidTapCount(let count):
            return "Speaker IR tap count \(count) is outside the supported 1...\(Int(N60_CONVOLUTION_MAX_TAPS)) range."
        case .mismatchedStereoTapCount(let left, let right):
            return "Speaker IR left/right FIR lengths must match (left \(left), right \(right))."
        case .nonFiniteTap:
            return "Speaker IR coefficients must all be finite."
        case .sampleRateMismatch(let filter, let output):
            return "Speaker IR rate \(filter) Hz does not match the active output rate \(output) Hz."
        case .invalidDeclaredLatency(let frames):
            return "Speaker IR declared filter latency \(frames) frames exceeds the FIR length."
        case .convolutionProgramUnavailable:
            return "No safe Speaker IR FIR program slot is currently available."
        case .graphAttachmentFailed:
            return "Unable to attach the prepared Speaker IR to the DSP graph."
        }
    }
}

'''
text = replace_once(
    text,
    "struct EQConfiguration: Equatable, Sendable {\n",
    speaker_models + "struct EQConfiguration: Equatable, Sendable {\n",
    "speaker model",
)
text = replace_once(
    text,
    "private struct PreparedRoomCorrectionProgram {\n    let slot: UInt32\n    let programInfo: N60ConvolutionProgramInfo\n}\n",
    "private struct PreparedRoomCorrectionProgram {\n    let slot: UInt32\n    let programInfo: N60ConvolutionProgramInfo\n}\n\nprivate struct PreparedSpeakerIRProgram {\n    let slot: UInt32\n    let programInfo: N60ConvolutionProgramInfo\n}\n",
    "prepared speaker program",
)
text = replace_once(
    text,
    "    private var activeRoomCorrectionProgram: PreparedRoomCorrectionProgram?\n    private var nextRoomCorrectionProgramSlot: UInt32 = 0\n",
    "    private var activeRoomCorrectionProgram: PreparedRoomCorrectionProgram?\n    private var nextRoomCorrectionProgramSlot: UInt32 = 0\n    private var activeSpeakerIRProgram: PreparedSpeakerIRProgram?\n    private var nextSpeakerIRProgramSlot: UInt32 = 0\n",
    "speaker engine storage",
)
text = replace_once(
    text,
    "    @Published private(set) var roomCorrectionConfiguration = RoomCorrectionConfiguration()\n    @Published private(set) var linearPhaseDesignInfo: N60LinearPhaseEQDesignInfo?\n",
    "    @Published private(set) var roomCorrectionConfiguration = RoomCorrectionConfiguration()\n    @Published private(set) var speakerIRConfiguration = SpeakerIRConfiguration()\n    @Published private(set) var linearPhaseDesignInfo: N60LinearPhaseEQDesignInfo?\n",
    "speaker published state",
)
room_public = """    func replaceRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {
        try applyRoomCorrectionConfiguration(configuration)
    }
"""
text = replace_once(
    text,
    room_public,
    room_public + """
    func loadSpeakerIRValidationFilter() throws {
        var updated = speakerIRConfiguration
        updated.filter = .validation
        try applySpeakerIRConfiguration(updated)
    }

    func setSpeakerIREnabled(_ enabled: Bool) throws {
        var updated = speakerIRConfiguration
        updated.enabled = enabled
        try applySpeakerIRConfiguration(updated)
    }

    func clearSpeakerIRFilter() throws {
        var updated = speakerIRConfiguration
        updated.enabled = false
        updated.filter = nil
        try applySpeakerIRConfiguration(updated)
    }

    func replaceSpeakerIRConfiguration(_ configuration: SpeakerIRConfiguration) throws {
        try applySpeakerIRConfiguration(configuration)
    }
""",
    "speaker public controls",
)

# Preserve Speaker IR in ordinary graph rebuilds that already preserve room correction.
multiline_room_attach = """            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
"""
multiline_room_plus_speaker = multiline_room_attach + """            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
"""
if "try attachActiveSpeakerIRProgramIfNeeded(\n                to: &graph,\n                playbackConfiguration: playbackControlConfiguration" not in text:
    count = text.count(multiline_room_attach)
    if count < 3:
        raise SystemExit(f"expected at least 3 standard room-correction attachment calls, found {count}")
    text = text.replace(multiline_room_attach, multiline_room_plus_speaker)

inline_room_attach = "            try attachActiveRoomCorrectionProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)\n"
inline_room_plus_speaker = inline_room_attach + "            try attachActiveSpeakerIRProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)\n"
if inline_room_plus_speaker not in text:
    count = text.count(inline_room_attach)
    if count < 1:
        raise SystemExit("expected at least one inline room-correction attachment call")
    text = text.replace(inline_room_attach, inline_room_plus_speaker)

# Playback bypass/unbypass can require preparing the independent slot.
playback_room_block = """                if roomCorrectionConfiguration.enabled {
                    guard let filter = roomCorrectionConfiguration.filter else {
                        throw RoomCorrectionConfigurationError.filterRequired
                    }
                    if activeRoomCorrectionProgram == nil {
                        activeRoomCorrectionProgram = try prepareRoomCorrectionProgram(filter, for: session)
                    }
                    try attachActiveRoomCorrectionProgramIfNeeded(
                        to: &graph,
                        playbackConfiguration: configuration
                    )
                }
"""
text = replace_once(
    text,
    playback_room_block,
    playback_room_block + """
                if speakerIRConfiguration.enabled {
                    guard let filter = speakerIRConfiguration.filter else {
                        throw SpeakerIRConfigurationError.filterRequired
                    }
                    if activeSpeakerIRProgram == nil {
                        activeSpeakerIRProgram = try prepareSpeakerIRProgram(filter, for: session)
                    }
                    try attachActiveSpeakerIRProgramIfNeeded(
                        to: &graph,
                        playbackConfiguration: configuration
                    )
                }
""",
    "speaker playback preparation",
)

# Changing room correction must not drop Speaker IR from the graph.
room_apply_eq_attach = """            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: stereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )

            if processingIsBypassed(playbackControlConfiguration) {
"""
text = replace_once(
    text,
    room_apply_eq_attach,
    """            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: stereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )

            if processingIsBypassed(playbackControlConfiguration) {
""",
    "room-change speaker preservation",
)

room_apply_function_end = """        roomCorrectionConfiguration = configuration
        lastErrorDescription = nil
    }

    private func designLinearPhaseTaps"""
speaker_apply = r'''        roomCorrectionConfiguration = configuration
        lastErrorDescription = nil
    }

    private func applySpeakerIRConfiguration(_ configuration: SpeakerIRConfiguration) throws {
        if configuration.enabled && configuration.filter == nil {
            throw SpeakerIRConfigurationError.filterRequired
        }

        if let session = transportSession {
            var graph = try stereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: bassManagementConfiguration,
                dynamicsConfiguration: dynamicsConfiguration,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: stereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )

            if processingIsBypassed(playbackControlConfiguration) {
                if let filter = configuration.filter {
                    try validateSpeakerIRFilter(
                        filter,
                        outputSampleRate: session.outputFormat.sampleRate
                    )
                }
                try session.publishDSPGraph(graph)
                activeSpeakerIRProgram = nil
            } else if configuration.enabled {
                guard let filter = configuration.filter else {
                    throw SpeakerIRConfigurationError.filterRequired
                }
                let preparedProgram = try prepareSpeakerIRProgram(filter, for: session)
                try attachSpeakerIRProgram(preparedProgram, to: &graph)
                try session.transitionDSPGraph(graph)
                activeSpeakerIRProgram = preparedProgram
            } else {
                if activeSpeakerIRProgram != nil {
                    try session.transitionDSPGraph(graph)
                } else {
                    try session.publishDSPGraph(graph)
                }
                activeSpeakerIRProgram = nil
            }
        } else {
            activeSpeakerIRProgram = nil
        }

        speakerIRConfiguration = configuration
        lastErrorDescription = nil
    }

    private func designLinearPhaseTaps'''
text = replace_once(text, room_apply_function_end, speaker_apply, "speaker apply configuration")

# Speaker filter validation/preparation mirrors the proven room-correction control plane
# while remaining a distinct prepared-program store.
room_prepare_function_end = """        nextRoomCorrectionProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedRoomCorrectionProgram(slot: slot, programInfo: programInfo)
    }

    private func attachEQFIRProgram"""
speaker_helpers = r'''        nextRoomCorrectionProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedRoomCorrectionProgram(slot: slot, programInfo: programInfo)
    }

    private func validateSpeakerIRFilter(
        _ filter: SpeakerIRFilter,
        outputSampleRate: Double
    ) throws {
        let tapCount = filter.leftTaps.count
        guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw SpeakerIRConfigurationError.invalidTapCount(tapCount)
        }
        if let rightTaps = filter.rightTaps, rightTaps.count != tapCount {
            throw SpeakerIRConfigurationError.mismatchedStereoTapCount(left: tapCount, right: rightTaps.count)
        }
        guard filter.leftTaps.allSatisfy(\.isFinite),
              filter.rightTaps?.allSatisfy(\.isFinite) ?? true else {
            throw SpeakerIRConfigurationError.nonFiniteTap
        }
        try filter.validateSampleRate(forOutputSampleRate: outputSampleRate)
        guard filter.declaredLatencyFrames < UInt32(tapCount) else {
            throw SpeakerIRConfigurationError.invalidDeclaredLatency(filter.declaredLatencyFrames)
        }
    }

    private func prepareSpeakerIRProgram(
        _ filter: SpeakerIRFilter,
        for session: CoreAudioTransportSession
    ) throws -> PreparedSpeakerIRProgram {
        try validateSpeakerIRFilter(filter, outputSampleRate: session.outputFormat.sampleRate)

        let slot = nextSpeakerIRProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareSpeakerIRProgram(
                slot: slot,
                leftTaps: filter.leftTaps,
                rightTaps: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames
            )
        } catch {
            throw SpeakerIRConfigurationError.convolutionProgramUnavailable
        }
        nextSpeakerIRProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedSpeakerIRProgram(slot: slot, programInfo: programInfo)
    }

    private func attachEQFIRProgram'''
text = replace_once(text, room_prepare_function_end, speaker_helpers, "speaker validation/preparation")

room_attach_helper_end = """        try attachRoomCorrectionProgram(activeRoomCorrectionProgram, to: &graph)
    }

    private func start(resetProcessingSessionCounters: Bool) throws {"""
speaker_attach_helpers = """        try attachRoomCorrectionProgram(activeRoomCorrectionProgram, to: &graph)
    }

    private func attachSpeakerIRProgram(
        _ program: PreparedSpeakerIRProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetSpeakerIRProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw SpeakerIRConfigurationError.graphAttachmentFailed
        }
    }

    private func attachActiveSpeakerIRProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              speakerIRConfiguration.enabled else { return }
        guard let activeSpeakerIRProgram else {
            throw SpeakerIRConfigurationError.convolutionProgramUnavailable
        }
        try attachSpeakerIRProgram(activeSpeakerIRProgram, to: &graph)
    }

    private func start(resetProcessingSessionCounters: Bool) throws {"""
text = replace_once(text, room_attach_helper_end, speaker_attach_helpers, "speaker attach helpers")

# Build/teardown lifecycle.
text = replace_once(
    text,
    "        activeRoomCorrectionProgram = nil\n        nextRoomCorrectionProgramSlot = 0\n        var graph = try stereoEQConfiguration.makeGraphSnapshot(\n",
    "        activeRoomCorrectionProgram = nil\n        nextRoomCorrectionProgramSlot = 0\n        activeSpeakerIRProgram = nil\n        nextSpeakerIRProgramSlot = 0\n        var graph = try stereoEQConfiguration.makeGraphSnapshot(\n",
    "speaker build reset",
)
build_room_block = """        if roomCorrectionConfiguration.enabled {
            guard let filter = roomCorrectionConfiguration.filter else {
                throw RoomCorrectionConfigurationError.filterRequired
            }
            try validateRoomCorrectionFilter(filter, outputSampleRate: session.outputFormat.sampleRate)
            if FIRUpdatePolicy.shouldPrepareRoomCorrection(
                roomCorrection: roomCorrectionConfiguration,
                playback: playbackControlConfiguration
            ) {
                let preparedProgram = try prepareRoomCorrectionProgram(filter, for: session)
                activeRoomCorrectionProgram = preparedProgram
                try attachRoomCorrectionProgram(preparedProgram, to: &graph)
            }
        }
"""
text = replace_once(
    text,
    build_room_block,
    build_room_block + """
        if speakerIRConfiguration.enabled {
            guard let filter = speakerIRConfiguration.filter else {
                throw SpeakerIRConfigurationError.filterRequired
            }
            try validateSpeakerIRFilter(filter, outputSampleRate: session.outputFormat.sampleRate)
            if FIRUpdatePolicy.shouldPrepareSpeakerIR(
                speakerIR: speakerIRConfiguration,
                playback: playbackControlConfiguration
            ) {
                let preparedProgram = try prepareSpeakerIRProgram(filter, for: session)
                activeSpeakerIRProgram = preparedProgram
                try attachSpeakerIRProgram(preparedProgram, to: &graph)
            }
        }
""",
    "speaker build preparation",
)
text = replace_once(
    text,
    "        activeEQFIRProgram = nil\n        activeRoomCorrectionProgram = nil\n    }\n",
    "        activeEQFIRProgram = nil\n        activeRoomCorrectionProgram = nil\n        activeSpeakerIRProgram = nil\n    }\n",
    "speaker teardown",
)
write(path, text)


# Swift diagnostics wrapper keeps the third slot independently observable.
path = "NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift"
text = read(path)
text = replace_once(
    text,
    "    let convolutionProgramMisses: UInt64\n    let roomCorrectionProgramMisses: UInt64\n",
    "    let convolutionProgramMisses: UInt64\n    let roomCorrectionProgramMisses: UInt64\n    let speakerIRProgramMisses: UInt64\n",
    "speaker diagnostics misses property",
)
text = replace_once(
    text,
    "    let roomCorrectionDeclaredLatencyFrames: UInt32\n    let inputMeter: StereoMeterReading\n",
    "    let roomCorrectionDeclaredLatencyFrames: UInt32\n    let speakerIREnabled: Bool\n    let speakerIRProgramSlot: UInt32\n    let speakerIRProgramGeneration: UInt64\n    let speakerIRTapCount: UInt32\n    let speakerIRPartitionCount: UInt32\n    let speakerIREngineLatencyFrames: UInt32\n    let speakerIRDeclaredLatencyFrames: UInt32\n    let inputMeter: StereoMeterReading\n",
    "speaker diagnostics properties",
)
text = replace_once(
    text,
    "        convolutionProgramMisses = diagnostics.convolutionProgramMisses\n        roomCorrectionProgramMisses = diagnostics.roomCorrectionProgramMisses\n",
    "        convolutionProgramMisses = diagnostics.convolutionProgramMisses\n        roomCorrectionProgramMisses = diagnostics.roomCorrectionProgramMisses\n        speakerIRProgramMisses = diagnostics.speakerIRProgramMisses\n",
    "speaker diagnostics misses init",
)
text = replace_once(
    text,
    "        roomCorrectionDeclaredLatencyFrames = diagnostics.roomCorrectionDeclaredLatencyFrames\n        inputMeter = StereoMeterReading(diagnostics.inputMeter)\n",
    "        roomCorrectionDeclaredLatencyFrames = diagnostics.roomCorrectionDeclaredLatencyFrames\n        speakerIREnabled = diagnostics.speakerIREnabled\n        speakerIRProgramSlot = diagnostics.speakerIRProgramSlot\n        speakerIRProgramGeneration = diagnostics.speakerIRProgramGeneration\n        speakerIRTapCount = diagnostics.speakerIRTapCount\n        speakerIRPartitionCount = diagnostics.speakerIRPartitionCount\n        speakerIREngineLatencyFrames = diagnostics.speakerIREngineLatencyFrames\n        speakerIRDeclaredLatencyFrames = diagnostics.speakerIRDeclaredLatencyFrames\n        inputMeter = StereoMeterReading(diagnostics.inputMeter)\n",
    "speaker diagnostics init",
)
write(path, text)


# Product ownership snapshot: persistence/import remains a later milestone, but the
# current product model must not omit the active speaker-processing state.
path = "NotchSixty/NotchSixtyApp.swift"
text = read(path)
text = replace_once(
    text,
    "    var dynamics: DynamicsConfiguration\n    var roomCorrection: RoomCorrectionConfiguration\n",
    "    var dynamics: DynamicsConfiguration\n    var roomCorrection: RoomCorrectionConfiguration\n    var speakerIR: SpeakerIRConfiguration\n",
    "product speaker property",
)
text = replace_once(
    text,
    "        dynamics: DynamicsConfiguration = DynamicsConfiguration(),\n        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration()\n",
    "        dynamics: DynamicsConfiguration = DynamicsConfiguration(),\n        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration(),\n        speakerIR: SpeakerIRConfiguration = SpeakerIRConfiguration()\n",
    "product speaker initializer",
)
text = replace_once(
    text,
    "        self.dynamics = dynamics\n        self.roomCorrection = roomCorrection\n",
    "        self.dynamics = dynamics\n        self.roomCorrection = roomCorrection\n        self.speakerIR = speakerIR\n",
    "product speaker assignment",
)
text = replace_once(
    text,
    "                dynamics: audioEngine.dynamicsConfiguration,\n                roomCorrection: audioEngine.roomCorrectionConfiguration\n",
    "                dynamics: audioEngine.dynamicsConfiguration,\n                roomCorrection: audioEngine.roomCorrectionConfiguration,\n                speakerIR: audioEngine.speakerIRConfiguration\n",
    "product speaker snapshot",
)
write(path, text)


# Validation UI. File import and resource persistence are intentionally deferred.
path = "NotchSixty/ContentView.swift"
text = read(path)
text = replace_once(
    text,
    "    private var roomCorrectionEnabledBinding: Binding<Bool> {\n        Binding(\n            get: { engine.roomCorrectionConfiguration.enabled },\n            set: { try? engine.setRoomCorrectionEnabled($0) }\n        )\n    }\n",
    "    private var roomCorrectionEnabledBinding: Binding<Bool> {\n        Binding(\n            get: { engine.roomCorrectionConfiguration.enabled },\n            set: { try? engine.setRoomCorrectionEnabled($0) }\n        )\n    }\n\n    private var speakerIREnabledBinding: Binding<Bool> {\n        Binding(\n            get: { engine.speakerIRConfiguration.enabled },\n            set: { try? engine.setSpeakerIREnabled($0) }\n        )\n    }\n",
    "speaker UI binding",
)
text = replace_once(
    text,
    "            crossoverValidationView\n            roomCorrectionValidationView\n            eqValidationView\n",
    "            crossoverValidationView\n            roomCorrectionValidationView\n            speakerIRValidationView\n            eqValidationView\n",
    "speaker UI placement",
)
room_view_end = r'''    @ViewBuilder
    private var eqValidationView: some View {
'''
speaker_view = r'''    @ViewBuilder
    private var speakerIRValidationView: some View {
        let filter = engine.speakerIRConfiguration.filter
        let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speaker IR runtime validation").font(.headline)
                Spacer()
                Button("Load Validation IR") {
                    try? engine.loadSpeakerIRValidationFilter()
                }
                Button("Clear") {
                    try? engine.clearSpeakerIRFilter()
                }
                .disabled(filter == nil)
                Toggle("Enable", isOn: speakerIREnabledBinding)
                    .toggleStyle(.switch)
                    .disabled(filter == nil)
            }

            if let filter {
                Text("Loaded: \(filter.name) — \(filter.leftTaps.count) taps / declared latency \(filter.declaredLatencyFrames) frame\(filter.declaredLatencyFrames == 1 ? "" : "s")")
                    .font(.caption)
            } else {
                Text("No Speaker IR loaded. The independent global Speaker IR slot is bypassed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Realtime: \(diagnostics?.speakerIREnabled == true ? "enabled" : "bypassed") • \(diagnostics?.speakerIRTapCount ?? 0) taps • program generation \(diagnostics?.speakerIRProgramGeneration ?? 0)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text("Speaker IR is a third independent global convolution workflow, separate from main-EQ/per-band FIR and room correction. This PR validates the current stereo runtime contract; WAV/AIFF import and resource persistence remain in the later persistence milestone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var eqValidationView: some View {
'''
text = replace_once(text, room_view_end, speaker_view, "speaker validation view")
write(path, text)


# Regression: prove three FIR workflows are genuinely independent and additive.
path = "NotchSixtyTests/NotchSixtyTests.swift"
text = read(path)
test_anchor = "    func testCrosstalkCancellationGraphPublishesAuditedDefaults() throws {\n"
speaker_tests = r'''    func testSpeakerIRIsThirdIndependentGlobalConvolutionSlot() {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        let eqTaps: [Float] = [0.25, 0.5, 0.25]
        let roomTaps: [Float] = [0.2, 0.6, 0.2]
        let speakerTaps: [Float] = [0.1, 0.4, 0.4, 0.1]
        var eqInfo = N60ConvolutionProgramInfo()
        var roomInfo = N60ConvolutionProgramInfo()
        var speakerInfo = N60ConvolutionProgramInfo()

        XCTAssertTrue(eqTaps.withUnsafeBufferPointer { taps in
            N60RenderKernelPrepareConvolutionProgram(
                kernel, 0, taps.baseAddress!, nil, UInt32(taps.count), 0, &eqInfo
            )
        })
        XCTAssertTrue(roomTaps.withUnsafeBufferPointer { taps in
            N60RenderKernelPrepareRoomCorrectionProgram(
                kernel, 1, taps.baseAddress!, nil, UInt32(taps.count), 1, &roomInfo
            )
        })
        XCTAssertTrue(speakerTaps.withUnsafeBufferPointer { taps in
            N60RenderKernelPrepareSpeakerIRProgram(
                kernel, 2, taps.baseAddress!, nil, UInt32(taps.count), 2, &speakerInfo
            )
        })

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&graph, 0, eqInfo, true))
        XCTAssertTrue(N60DSPGraphSnapshotSetRoomCorrectionProgram(&graph, 1, roomInfo, true))
        XCTAssertTrue(N60DSPGraphSnapshotSetSpeakerIRProgram(&graph, 2, speakerInfo, true))

        let expectedLatency = eqInfo.engineLatencyFrames + eqInfo.declaredLatencyFrames
            + roomInfo.engineLatencyFrames + roomInfo.declaredLatencyFrames
            + speakerInfo.engineLatencyFrames + speakerInfo.declaredLatencyFrames
        XCTAssertEqual(graph.latencyFrames, expectedLatency)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        let diagnostics = N60RenderKernelGetDiagnostics(kernel)
        XCTAssertTrue(diagnostics.convolutionEnabled)
        XCTAssertTrue(diagnostics.roomCorrectionEnabled)
        XCTAssertTrue(diagnostics.speakerIREnabled)
        XCTAssertEqual(diagnostics.convolutionProgramSlot, 0)
        XCTAssertEqual(diagnostics.roomCorrectionProgramSlot, 1)
        XCTAssertEqual(diagnostics.speakerIRProgramSlot, 2)
        XCTAssertEqual(diagnostics.convolutionProgramGeneration, eqInfo.generation)
        XCTAssertEqual(diagnostics.roomCorrectionProgramGeneration, roomInfo.generation)
        XCTAssertEqual(diagnostics.speakerIRProgramGeneration, speakerInfo.generation)
        XCTAssertEqual(diagnostics.latencyFrames, expectedLatency)
        XCTAssertEqual(diagnostics.speakerIRProgramMisses, 0)
    }

    func testSpeakerIRPublishRejectsUnpreparedGeneration() {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        let taps: [Float] = [0.2, 0.6, 0.2]
        var info = N60ConvolutionProgramInfo()
        XCTAssertTrue(taps.withUnsafeBufferPointer { buffer in
            N60RenderKernelPrepareSpeakerIRProgram(
                kernel, 0, buffer.baseAddress!, nil, UInt32(buffer.count), 1, &info
            )
        })
        var stale = info
        stale.generation &+= 1
        var graph = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetSpeakerIRProgram(&graph, 0, stale, true))
        XCTAssertFalse(N60RenderKernelPublishSnapshot(kernel, graph))
    }

    func testSpeakerIRPolicyKeepsRawBypassRaw() {
        var configuration = SpeakerIRConfiguration()
        configuration.enabled = true
        configuration.filter = .validation
        XCTAssertTrue(FIRUpdatePolicy.shouldPrepareSpeakerIR(
            speakerIR: configuration,
            playback: PlaybackControlConfiguration()
        ))
        XCTAssertFalse(FIRUpdatePolicy.shouldPrepareSpeakerIR(
            speakerIR: configuration,
            playback: PlaybackControlConfiguration(globalBypassed: true)
        ))
    }

'''
text = replace_once(text, test_anchor, speaker_tests + test_anchor, "speaker tests")
write(path, text)

print("PR34 Speaker IR Swift/product/UI/tests integration staged.")
