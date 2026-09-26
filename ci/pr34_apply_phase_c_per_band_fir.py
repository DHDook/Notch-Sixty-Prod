from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


def replace_region(text: str, start_marker: str, end_marker: str, replacement: str, label: str) -> str:
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f"Expected {label} start marker was not found")
    end = text.find(end_marker, start)
    if end < 0:
        raise SystemExit(f"Expected {label} end marker was not found")
    return text[:start] + replacement + text[end:]


# ---------------------------------------------------------------------------
# Core EQ model: a FIR band owns a typed user kernel but compiles no IIR section.
# ---------------------------------------------------------------------------
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
engine = replace_once(engine, "import Combine\nimport CoreAudio\n", "import Accelerate\nimport Combine\nimport CoreAudio\n", "Accelerate import")
engine = replace_once(engine, "    case tilt\n    case notch\n", "    case tilt\n    case fir\n    case notch\n", "FIR filter enum")
engine = replace_once(engine, '        case .tilt: return "Tilt"\n        case .notch: return "Notch"', '        case .tilt: return "Tilt"\n        case .fir: return "FIR"\n        case .notch: return "Notch"', "FIR display name")
engine = replace_once(engine, "        case .tilt: return N60BiquadFilterTypeTilt\n        case .notch: return N60BiquadFilterTypeNotch", "        case .tilt: return N60BiquadFilterTypeTilt\n        case .fir: preconditionFailure(\"FIR bands do not compile to biquad filter types\")\n        case .notch: return N60BiquadFilterTypeNotch", "FIR cType guard")

fir_model = '''
struct EQBandFIRKernel: Equatable, Sendable {
    var name: String
    var sampleRate: Double?
    var taps: [Float]
    var declaredLatencyFrames: UInt32

    init(
        name: String = "FIR",
        sampleRate: Double? = nil,
        taps: [Float],
        declaredLatencyFrames: UInt32 = 0
    ) {
        self.name = name
        self.sampleRate = sampleRate
        self.taps = taps
        self.declaredLatencyFrames = declaredLatencyFrames
    }

    func validate(forOutputSampleRate outputSampleRate: Double) throws {
        guard !taps.isEmpty, taps.count <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw EQConfigurationError.invalidFIRTapCount(taps.count)
        }
        guard taps.allSatisfy(\\.isFinite) else {
            throw EQConfigurationError.nonFiniteFIRTap
        }
        if let sampleRate {
            guard sampleRate.isFinite, abs(sampleRate - outputSampleRate) < 0.5 else {
                throw EQConfigurationError.firSampleRateMismatch(filter: sampleRate, output: outputSampleRate)
            }
        }
        guard declaredLatencyFrames < UInt32(taps.count) else {
            throw EQConfigurationError.invalidFIRDeclaredLatency(declaredLatencyFrames)
        }
    }

    var conservativeBoostDB: Double {
        let l1 = taps.reduce(0.0) { $0 + Double(abs($1)) }
        guard l1 > 1.0 else { return 0 }
        return 20.0 * log10(l1)
    }
}

struct EQFIRAggregate: Equatable, Sendable {
    var taps: [Float]
    var declaredLatencyFrames: UInt32

    static let identity = EQFIRAggregate(taps: [1.0], declaredLatencyFrames: 0)
}

enum EQFIRKernelCombiner {
    static func convolve(_ lhs: [Float], _ rhs: [Float]) throws -> [Float] {
        guard !lhs.isEmpty, !rhs.isEmpty,
              lhs.allSatisfy(\\.isFinite), rhs.allSatisfy(\\.isFinite) else {
            throw EQConfigurationError.nonFiniteFIRTap
        }
        let outputCount = lhs.count + rhs.count - 1
        guard outputCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw EQConfigurationError.combinedFIRTooLong(outputCount)
        }

        // vDSP's 1-D convolution returns the valid region. Zero-pad by M-1 on
        // both sides to obtain the complete linear convolution while keeping
        // this expensive control-plane operation out of the realtime thread.
        let kernel: [Float]
        let signal: [Float]
        if rhs.count <= lhs.count {
            kernel = rhs
            signal = lhs
        } else {
            kernel = lhs
            signal = rhs
        }
        let padding = kernel.count - 1
        var padded = [Float](repeating: 0, count: signal.count + 2 * padding)
        padded.replaceSubrange(padding..<(padding + signal.count), with: signal)
        let result: [Float] = vDSP.convolve(padded, withKernel: kernel)
        guard result.count == outputCount, result.allSatisfy(\\.isFinite) else {
            throw EQConfigurationError.nonFiniteFIRTap
        }
        return result
    }

    static func combine(_ lhs: EQFIRAggregate, _ rhs: EQFIRAggregate) throws -> EQFIRAggregate {
        let totalLatency = UInt64(lhs.declaredLatencyFrames) + UInt64(rhs.declaredLatencyFrames)
        guard totalLatency <= UInt64(UInt32.max) else {
            throw EQConfigurationError.invalidFIRDeclaredLatency(UInt32.max)
        }
        return EQFIRAggregate(
            taps: try convolve(lhs.taps, rhs.taps),
            declaredLatencyFrames: UInt32(totalLatency)
        )
    }

    static func cascade(_ kernels: [EQBandFIRKernel]) throws -> EQFIRAggregate {
        try kernels.reduce(.identity) { aggregate, kernel in
            try combine(
                aggregate,
                EQFIRAggregate(taps: kernel.taps, declaredLatencyFrames: kernel.declaredLatencyFrames)
            )
        }
    }
}

'''
marker = "struct EQBand: Identifiable, Equatable, Sendable {\n"
if "struct EQBandFIRKernel" not in engine:
    engine = engine.replace(marker, fir_model + marker, 1)

engine = replace_once(engine, "    var linkwitzTargetQ: Double\n    var dynamic: EQBandDynamicConfiguration\n", "    var linkwitzTargetQ: Double\n    var firKernel: EQBandFIRKernel?\n    var dynamic: EQBandDynamicConfiguration\n", "FIR band field")
engine = replace_once(engine, "        linkwitzTargetQ: Double = 0.707,\n        dynamic: EQBandDynamicConfiguration = EQBandDynamicConfiguration()\n", "        linkwitzTargetQ: Double = 0.707,\n        firKernel: EQBandFIRKernel? = nil,\n        dynamic: EQBandDynamicConfiguration = EQBandDynamicConfiguration()\n", "FIR initializer parameter")
engine = replace_once(engine, "        self.linkwitzTargetQ = linkwitzTargetQ\n        self.dynamic = dynamic\n", "        self.linkwitzTargetQ = linkwitzTargetQ\n        self.firKernel = firKernel\n        self.dynamic = dynamic\n", "FIR initializer assignment")
engine = replace_once(engine, "    func compiledSections(sampleRate: Double) throws -> [N60BiquadBandSnapshot] {\n", "    func compiledSections(sampleRate: Double) throws -> [N60BiquadBandSnapshot] {\n        if type == .fir { return [] }\n", "FIR IIR compiler bypass")

engine = replace_once(engine, "    case convolutionProgramUnavailable\n", "    case convolutionProgramUnavailable\n    case invalidFIRTapCount(Int)\n    case nonFiniteFIRTap\n    case firSampleRateMismatch(filter: Double, output: Double)\n    case invalidFIRDeclaredLatency(UInt32)\n    case combinedFIRTooLong(Int)\n    case mismatchedFIRDeclaredLatency(primary: UInt32, secondary: UInt32)\n", "FIR errors")
engine = replace_once(engine, "        case .convolutionProgramUnavailable:\n            return \"No safe FIR program slot is currently available.\"\n", "        case .convolutionProgramUnavailable:\n            return \"No safe FIR program slot is currently available.\"\n        case .invalidFIRTapCount(let count):\n            return \"Per-band FIR tap count \\(count) is outside the supported 1...\\(Int(N60_CONVOLUTION_MAX_TAPS)) range.\"\n        case .nonFiniteFIRTap:\n            return \"Per-band FIR coefficients must all be finite.\"\n        case .firSampleRateMismatch(let filter, let output):\n            return \"Per-band FIR rate \\(filter) Hz does not match the active output rate \\(output) Hz.\"\n        case .invalidFIRDeclaredLatency(let frames):\n            return \"Per-band FIR declared latency \\(frames) frames is invalid for its kernel.\"\n        case .combinedFIRTooLong(let count):\n            return \"Combined main-EQ FIR would require \\(count) taps, above the supported \\(Int(N60_CONVOLUTION_MAX_TAPS)).\"\n        case .mismatchedFIRDeclaredLatency(let primary, let secondary):\n            return \"Independent main-EQ FIR lanes must declare the same latency (primary \\(primary), secondary \\(secondary) frames).\"\n", "FIR error descriptions")

# Compatibility EQ validation treats FIR frequency/gain/Q as non-operative.
old_validate = '''    private func validateBand(_ band: EQBand, index: Int, sampleRate: Double) throws -> Bool {
        guard band.frequencyHz.isFinite,
              band.frequencyHz > 0,
              band.gainDB.isFinite,
              StereoEQConfiguration.bandGainRange.contains(band.gainDB),
              band.q.isFinite,
              band.q > 0 else {
            throw EQConfigurationError.invalidBand(index: index)
        }
'''
new_validate = '''    private func validateBand(_ band: EQBand, index: Int, sampleRate: Double) throws -> Bool {
        if band.type == .fir {
            if let kernel = band.firKernel { try kernel.validate(forOutputSampleRate: sampleRate) }
            guard !band.dynamic.enabled else { throw EQConfigurationError.invalidBand(index: index) }
            return true
        }
        guard band.frequencyHz.isFinite,
              band.frequencyHz > 0,
              band.gainDB.isFinite,
              StereoEQConfiguration.bandGainRange.contains(band.gainDB),
              band.q.isFinite,
              band.q > 0 else {
            throw EQConfigurationError.invalidBand(index: index)
        }
'''
engine = replace_once(engine, old_validate, new_validate, "compatibility FIR validation")
engine = replace_once(engine, "        for (index, band) in bands.enumerated() where band.enabled {\n            guard try validateBand(band, index: index, sampleRate: sampleRate) else { continue }\n            guard band.type != .allPass else {", "        for (index, band) in bands.enumerated() where band.enabled {\n            guard try validateBand(band, index: index, sampleRate: sampleRate) else { continue }\n            if band.type == .fir { continue }\n            guard band.type != .allPass else {", "compatibility linear FIR exclusion")

# Rename the main-EQ convolution ownership to include Linear and per-band FIR.
for old, new in [
    ("PreparedLinearPhaseProgram", "PreparedMainEQFIRProgram"),
    ("activeLinearPhaseProgram", "activeMainEQFIRProgram"),
    ("nextLinearPhaseProgramSlot", "nextMainEQFIRProgramSlot"),
    ("prepareLinearPhaseProgram", "prepareMainEQFIRProgram"),
    ("attachLinearPhaseProgram", "attachMainEQFIRProgram"),
    ("attachActiveLinearPhaseProgramIfNeeded", "attachActiveMainEQFIRProgramIfNeeded"),
    ("shouldPrepareLinearPhase", "shouldPrepareMainEQFIR"),
]:
    engine = engine.replace(old, new)

engine = engine.replace("    let designInfo: N60LinearPhaseEQDesignInfo\n", "    let designInfo: N60LinearPhaseEQDesignInfo?\n", 1)

# Storage validation allows a cleared FIR band and validates loaded kernels.
old_storage = '''            for (index, band) in bands.enumerated() where band.enabled {
                guard band.frequencyHz.isFinite,
                      band.frequencyHz > 0,
                      band.gainDB.isFinite,
                      StereoEQConfiguration.bandGainRange.contains(band.gainDB),
                      band.q.isFinite,
                      band.q > 0 else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
'''
new_storage = '''            for (index, band) in bands.enumerated() where band.enabled {
                if band.type == .fir {
                    if let kernel = band.firKernel {
                        try kernel.validate(forOutputSampleRate: transportSession?.outputFormat.sampleRate ?? 48_000)
                    }
                    guard !band.dynamic.enabled else { throw EQConfigurationError.invalidBand(index: index) }
                    continue
                }
                guard band.frequencyHz.isFinite,
                      band.frequencyHz > 0,
                      band.gainDB.isFinite,
                      StereoEQConfiguration.bandGainRange.contains(band.gainDB),
                      band.q.isFinite,
                      band.q > 0 else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
'''
engine = replace_once(engine, old_storage, new_storage, "live FIR storage validation")

# Public control-plane load/clear API. File decoding/persistence remains in the later persistence milestone.
api_marker = "    func removeEQBand(id: UUID) throws {\n"
fir_api = '''    func loadEQBandFIRKernel(id: UUID, kernel: EQBandFIRKernel) throws {
        let validationRate = transportSession?.outputFormat.sampleRate ?? kernel.sampleRate ?? 48_000
        try kernel.validate(forOutputSampleRate: validationRate)
        var updated = stereoEQConfiguration
        guard var band = updated.editableBands.first(where: { $0.id == id }) else { return }
        band.type = .fir
        band.firKernel = kernel
        band.dynamic.enabled = false
        updated.updateEditableBand(band)
        try applyStereoEQConfiguration(updated)
    }

    func clearEQBandFIRKernel(id: UUID) throws {
        var updated = stereoEQConfiguration
        guard var band = updated.editableBands.first(where: { $0.id == id }) else { return }
        band.firKernel = nil
        updated.updateEditableBand(band)
        try applyStereoEQConfiguration(updated)
    }

    func loadEQBandFIRValidationKernel(id: UUID, sampleRate: Double) throws {
        let taps: [Float] = [0.125, 0.25, 0.25, 0.25, 0.125]
        try loadEQBandFIRKernel(
            id: id,
            kernel: EQBandFIRKernel(
                name: "Validation FIR",
                sampleRate: sampleRate,
                taps: taps,
                declaredLatencyFrames: 2
            )
        )
    }

'''
if "func loadEQBandFIRKernel" not in engine:
    engine = engine.replace(api_marker, fir_api + api_marker, 1)

# Replace the old Linear-only preparation with a main-EQ FIR program builder.
start_marker = "    private func prepareMainEQFIRProgram(\n"
end_marker = "    private func validateRoomCorrectionFilter(\n"
new_prepare = '''    private func prepareMainEQFIRProgram(
        _ configuration: StereoEQConfiguration,
        for session: CoreAudioTransportSession
    ) throws -> PreparedMainEQFIRProgram {
        let sampleRate = session.outputFormat.sampleRate
        let primaryChannel: EQEditChannel
        let secondaryChannel: EQEditChannel?
        switch configuration.channelMode {
        case .linked:
            primaryChannel = .linked
            secondaryChannel = nil
        case .independent:
            primaryChannel = .left
            secondaryChannel = .right
        case .midSide:
            primaryChannel = .mid
            secondaryChannel = .side
        }

        func userAggregate(_ channel: EQEditChannel) throws -> EQFIRAggregate {
            let kernels = try configuration.perBandFIRKernels(for: channel, sampleRate: sampleRate)
            return try EQFIRKernelCombiner.cascade(kernels)
        }

        let primaryUser = try userAggregate(primaryChannel)
        var primaryAggregate: EQFIRAggregate
        var designInfo: N60LinearPhaseEQDesignInfo?
        if configuration.phaseMode == .linearPhase {
            let tapCount = Int(N60LinearPhaseEQRecommendedTapCount(sampleRate))
            guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            let design = try designLinearPhaseTaps(
                configuration,
                channel: primaryChannel,
                sampleRate: sampleRate,
                tapCount: tapCount
            )
            designInfo = design.info
            primaryAggregate = try EQFIRKernelCombiner.combine(
                EQFIRAggregate(taps: design.taps, declaredLatencyFrames: design.info.groupDelayFrames),
                primaryUser
            )
        } else {
            primaryAggregate = primaryUser
        }

        var secondaryAggregate: EQFIRAggregate?
        if let secondaryChannel {
            let secondaryUser = try userAggregate(secondaryChannel)
            if configuration.phaseMode == .linearPhase {
                let tapCount = Int(N60LinearPhaseEQRecommendedTapCount(sampleRate))
                let design = try designLinearPhaseTaps(
                    configuration,
                    channel: secondaryChannel,
                    sampleRate: sampleRate,
                    tapCount: tapCount
                )
                guard design.info.groupDelayFrames == designInfo?.groupDelayFrames else {
                    throw EQConfigurationError.linearPhaseDesignFailed
                }
                secondaryAggregate = try EQFIRKernelCombiner.combine(
                    EQFIRAggregate(taps: design.taps, declaredLatencyFrames: design.info.groupDelayFrames),
                    secondaryUser
                )
            } else {
                secondaryAggregate = secondaryUser
            }
        }

        if let secondaryAggregate,
           secondaryAggregate.declaredLatencyFrames != primaryAggregate.declaredLatencyFrames {
            throw EQConfigurationError.mismatchedFIRDeclaredLatency(
                primary: primaryAggregate.declaredLatencyFrames,
                secondary: secondaryAggregate.declaredLatencyFrames
            )
        }

        var leftTaps = primaryAggregate.taps
        var rightTaps = secondaryAggregate?.taps
        if var right = rightTaps {
            let commonCount = max(leftTaps.count, right.count)
            guard commonCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
                throw EQConfigurationError.combinedFIRTooLong(commonCount)
            }
            if leftTaps.count < commonCount {
                leftTaps += [Float](repeating: 0, count: commonCount - leftTaps.count)
            }
            if right.count < commonCount {
                right += [Float](repeating: 0, count: commonCount - right.count)
            }
            rightTaps = right
        }

        let slot = nextMainEQFIRProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareConvolutionProgram(
                slot: slot,
                leftTaps: leftTaps,
                rightTaps: rightTaps,
                declaredLatencyFrames: primaryAggregate.declaredLatencyFrames
            )
        } catch {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        nextMainEQFIRProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedMainEQFIRProgram(
            slot: slot,
            programInfo: programInfo,
            designInfo: designInfo
        )
    }

'''
engine = replace_region(engine, start_marker, end_marker, new_prepare, "main EQ FIR preparation")

# Attach whichever main-EQ FIR program the current graph requires.
old_attach_guard = '''    private func attachActiveMainEQFIRProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        stereoConfiguration: StereoEQConfiguration,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              stereoConfiguration.phaseMode == .linearPhase,
              !stereoConfiguration.bypassed else { return }
        guard let activeMainEQFIRProgram else {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        try attachMainEQFIRProgram(activeMainEQFIRProgram, to: &graph)
    }
'''
new_attach_guard = '''    private func attachActiveMainEQFIRProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        stereoConfiguration: StereoEQConfiguration,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard FIRUpdatePolicy.shouldPrepareMainEQFIR(
            stereoEQ: stereoConfiguration,
            playback: playbackConfiguration
        ) else { return }
        guard let activeMainEQFIRProgram else {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        try attachMainEQFIRProgram(activeMainEQFIRProgram, to: &graph)
    }
'''
engine = replace_once(engine, old_attach_guard, new_attach_guard, "main EQ FIR attach policy")

# Full EQ replacement now rotates the main FIR for either Linear mode or loaded FIR bands.
apply_start = "    private func applyStereoEQConfiguration(_ configuration: StereoEQConfiguration) throws {\n"
apply_end = "    private func applyPlaybackControlConfiguration(_ configuration: PlaybackControlConfiguration) throws {\n"
new_apply = '''    private func applyStereoEQConfiguration(_ configuration: StereoEQConfiguration) throws {
        try validateStereoEQStorage(configuration)

        if let session = transportSession {
            var graph = try configuration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: bassManagementConfiguration,
                dynamicsConfiguration: dynamicsConfiguration,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )

            if processingIsBypassed(playbackControlConfiguration) {
                try session.publishDSPGraph(graph)
                activeMainEQFIRProgram = nil
                linearPhaseDesignInfo = nil
            } else {
                var preparedMainProgram: PreparedMainEQFIRProgram?
                if FIRUpdatePolicy.shouldPrepareMainEQFIR(
                    stereoEQ: configuration,
                    playback: playbackControlConfiguration
                ) {
                    let prepared = try prepareMainEQFIRProgram(configuration, for: session)
                    preparedMainProgram = prepared
                    linearPhaseDesignInfo = prepared.designInfo
                    try attachMainEQFIRProgram(prepared, to: &graph)
                } else {
                    linearPhaseDesignInfo = nil
                }

                try attachActiveRoomCorrectionProgramIfNeeded(
                    to: &graph,
                    playbackConfiguration: playbackControlConfiguration
                )

                let mainFIRStructureChanged = activeMainEQFIRProgram != nil || preparedMainProgram != nil
                if mainFIRStructureChanged {
                    try session.transitionDSPGraph(graph)
                } else {
                    try session.publishDSPGraph(graph)
                }
                activeMainEQFIRProgram = preparedMainProgram
            }
        } else {
            activeMainEQFIRProgram = nil
            linearPhaseDesignInfo = nil
        }

        stereoEQConfiguration = configuration
        eqConfiguration = legacyEQConfiguration(from: configuration)
        lastErrorDescription = nil
    }

'''
engine = replace_region(engine, apply_start, apply_end, new_apply, "live EQ FIR update")

# Build path already renamed; make its policy and optional design-info semantics correct.
engine = engine.replace("            linearPhaseDesignInfo = preparedProgram.designInfo\n", "            linearPhaseDesignInfo = preparedProgram.designInfo\n")

engine_path.write_text(engine)


# ---------------------------------------------------------------------------
# Stereo model extracts per-lane FIR kernels and excludes them from IIR/linear designers.
# ---------------------------------------------------------------------------
stereo_path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
stereo = stereo_path.read_text()
old_validation = '''        for (index, band) in bands.enumerated() where band.enabled {
            guard band.frequencyHz.isFinite,
                  band.frequencyHz > 0,
                  band.gainDB.isFinite,
                  Self.bandGainRange.contains(band.gainDB),
                  band.q.isFinite,
                  band.q > 0 else {
                throw EQConfigurationError.invalidBand(index: index)
            }
'''
new_validation = '''        for (index, band) in bands.enumerated() where band.enabled {
            if band.type == .fir {
                if let kernel = band.firKernel { try kernel.validate(forOutputSampleRate: sampleRate) }
                guard !band.dynamic.enabled else { throw EQConfigurationError.invalidBand(index: index) }
                result.append(band)
                continue
            }
            guard band.frequencyHz.isFinite,
                  band.frequencyHz > 0,
                  band.gainDB.isFinite,
                  Self.bandGainRange.contains(band.gainDB),
                  band.q.isFinite,
                  band.q > 0 else {
                throw EQConfigurationError.invalidBand(index: index)
            }
'''
stereo = replace_once(stereo, old_validation, new_validation, "stereo FIR validation")

helper_marker = "    private func conservativeAutomaticHeadroomDB(\n"
helpers = '''    var hasEnabledPerBandFIR: Bool {
        func containsLoadedFIR(_ bands: [EQBand]) -> Bool {
            bands.contains { $0.enabled && $0.type == .fir && $0.firKernel != nil }
        }
        switch channelMode {
        case .linked:
            return containsLoadedFIR(linkedBands)
        case .independent:
            return containsLoadedFIR(leftBands) || containsLoadedFIR(rightBands)
        case .midSide:
            return containsLoadedFIR(midBands) || containsLoadedFIR(sideBands)
        }
    }

    func perBandFIRKernels(for channel: EQEditChannel, sampleRate: Double) throws -> [EQBandFIRKernel] {
        let source: [EQBand]
        switch channelMode {
        case .linked:
            source = linkedBands
        case .independent:
            source = channel == .right ? rightBands : leftBands
        case .midSide:
            source = channel == .side ? sideBands : midBands
        }
        return try validatedEnabledBands(source, sampleRate: sampleRate).compactMap { band in
            guard band.type == .fir else { return nil }
            return band.firKernel
        }
    }

'''
if "var hasEnabledPerBandFIR" not in stereo:
    stereo = stereo.replace(helper_marker, helpers + helper_marker, 1)

old_boost = '''        func channelBoost(_ bands: [EQBand]) -> Double {
            bands.lazy.filter(\\.enabled).reduce(0.0) { partial, band in
                partial + max(0.0, band.gainDB)
            }
        }
'''
new_boost = '''        func channelBoost(_ bands: [EQBand]) -> Double {
            bands.lazy.filter(\\.enabled).reduce(0.0) { partial, band in
                if band.type == .fir {
                    return partial + (band.firKernel?.conservativeBoostDB ?? 0)
                }
                return partial + max(0.0, band.gainDB)
            }
        }
'''
stereo = replace_once(stereo, old_boost, new_boost, "FIR automatic headroom")

# Linear designer sees only the analytic EQ sections; user FIR is cascaded later.
stereo = replace_once(stereo, "        for (index, band) in bands.enumerated() {\n            do {\n                for section in try band.compiledSections(sampleRate: sampleRate) {", "        for (index, band) in bands.enumerated() {\n            if band.type == .fir { continue }\n            do {\n                for section in try band.compiledSections(sampleRate: sampleRate) {", "linear FIR exclusion")

# Main-EQ FIR policy applies in Linear Phase or whenever the active lane has a loaded FIR band.
stereo = stereo.replace("    static func shouldPrepareMainEQFIR(\n        stereoEQ: StereoEQConfiguration,\n        playback: PlaybackControlConfiguration\n    ) -> Bool {\n        !isRawBypassed(playback)\n            && stereoEQ.phaseMode == .linearPhase\n            && !stereoEQ.bypassed\n    }", "    static func shouldPrepareMainEQFIR(\n        stereoEQ: StereoEQConfiguration,\n        playback: PlaybackControlConfiguration\n    ) -> Bool {\n        !isRawBypassed(playback)\n            && !stereoEQ.bypassed\n            && (stereoEQ.phaseMode == .linearPhase || stereoEQ.hasEnabledPerBandFIR)\n    }")
stereo_path.write_text(stereo)


# ---------------------------------------------------------------------------
# Validation UI: FIR is a kernel slot, not a frequency/gain/Q/slope band.
# ---------------------------------------------------------------------------
content_path = Path("NotchSixty/ContentView.swift")
content = content_path.read_text()
content = replace_once(content, 'TextField("Hz", value: binding.frequencyHz, format: .number.precision(.fractionLength(0...1))).frame(width: 85)\n                Text("Hz").foregroundStyle(.secondary)', 'TextField("Hz", value: binding.frequencyHz, format: .number.precision(.fractionLength(0...1)))\n                    .frame(width: 85)\n                    .disabled(band.type == .fir)\n                Text("Hz").foregroundStyle(.secondary)', "FIR frequency disable")
content = replace_once(content, "                    .disabled(band.type == .linkwitzTransform)\n", "                    .disabled(band.type == .linkwitzTransform || band.type == .fir)\n", "FIR gain disable")
content = replace_once(content, "                    .disabled(band.type == .tilt)\n", "                    .disabled(band.type == .tilt || band.type == .fir)\n", "FIR Q disable")
fir_ui_marker = "            if band.type == .linkwitzTransform {\n"
fir_ui = '''            if band.type == .fir {
                HStack(spacing: 8) {
                    Text("FIR kernel").frame(width: 82, alignment: .leading).foregroundStyle(.secondary)
                    Text(band.firKernel?.name ?? "No kernel loaded")
                        .monospaced()
                    if let kernel = band.firKernel {
                        Text("\\(kernel.taps.count) taps / declared \\(kernel.declaredLatencyFrames) frames")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Load validation FIR") {
                        try? engine.loadEQBandFIRValidationKernel(id: band.id, sampleRate: currentDSPRate)
                    }
                    Button("Clear") { try? engine.clearEQBandFIRKernel(id: band.id) }
                        .disabled(band.firKernel == nil)
                }
                Text("Frequency, gain, Q, and slope are intentionally non-operative for FIR bands. Resource-backed IR file import/persistence is handled by the later persistence milestone; this PR34 surface validates the per-band kernel slot and realtime pipeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
            }

'''
if "Load validation FIR" not in content:
    content = content.replace(fir_ui_marker, fir_ui + fir_ui_marker, 1)
content = content.replace('diagnosticRow(\n                    "Linear FIR",', 'diagnosticRow(\n                    "Main EQ FIR",')
content_path.write_text(content)


# ---------------------------------------------------------------------------
# XCTest coverage for kernel ownership, exact cascade, bounds, policy, and rates.
# ---------------------------------------------------------------------------
tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
fir_tests = r'''
    func testPerBandFIRKernelCascadeIsExactAndSumsDeclaredLatency() throws {
        let first = EQBandFIRKernel(
            name: "A", sampleRate: 48_000, taps: [0.5, 0.5], declaredLatencyFrames: 1
        )
        let second = EQBandFIRKernel(
            name: "B", sampleRate: 48_000, taps: [1.0, -1.0], declaredLatencyFrames: 0
        )
        try first.validate(forOutputSampleRate: 48_000)
        try second.validate(forOutputSampleRate: 48_000)
        let aggregate = try EQFIRKernelCombiner.cascade([first, second])
        XCTAssertEqual(aggregate.taps.count, 3)
        XCTAssertEqual(aggregate.taps[0], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(aggregate.taps[1], 0.0, accuracy: 0.000_001)
        XCTAssertEqual(aggregate.taps[2], -0.5, accuracy: 0.000_001)
        XCTAssertEqual(aggregate.declaredLatencyFrames, 1)
    }

    func testPerBandFIRRejectsSampleRateMismatchAndCombinedOverflow() throws {
        let kernel = EQBandFIRKernel(name: "96k", sampleRate: 96_000, taps: [1.0])
        XCTAssertThrowsError(try kernel.validate(forOutputSampleRate: 48_000))

        let half = Int(N60_CONVOLUTION_MAX_TAPS) / 2 + 1
        let lhs = [Float](repeating: 0, count: half)
        let rhs = [Float](repeating: 0, count: half)
        XCTAssertThrowsError(try EQFIRKernelCombiner.convolve(lhs, rhs))
    }

    func testPerBandFIRUsesMainEQConvolverInMinimumPhase() throws {
        let fir = EQBandFIRKernel(
            name: "Minimum FIR", sampleRate: 48_000, taps: [0.25, 0.5, 0.25], declaredLatencyFrames: 1
        )
        let band = EQBand(type: .fir, firKernel: fir)
        let configuration = StereoEQConfiguration(
            channelMode: .linked,
            phaseMode: .minimumPhase,
            linkedBands: [band]
        )
        XCTAssertTrue(configuration.hasEnabledPerBandFIR)
        XCTAssertTrue(FIRUpdatePolicy.shouldPrepareMainEQFIR(
            stereoEQ: configuration,
            playback: PlaybackControlConfiguration()
        ))
        let graph = try configuration.makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertEqual(graph.eqBandCount, 0, "FIR bands must not consume IIR render slots")
        XCTAssertEqual(try configuration.perBandFIRKernels(for: .linked, sampleRate: 48_000), [fir])
    }

    func testPerBandFIRIsExcludedFromLinearAnalyticBandDesignerThrough384k() throws {
        for rate in [48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            let fir = EQBandFIRKernel(name: "FIR", sampleRate: rate, taps: [0.25, 0.5, 0.25], declaredLatencyFrames: 1)
            let analytic = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 2, q: 1.0)
            let userFIR = EQBand(type: .fir, firKernel: fir)
            let configuration = StereoEQConfiguration(
                channelMode: .linked,
                phaseMode: .linearPhase,
                linkedBands: [analytic, userFIR]
            )
            let linearBands = try configuration.linearPhaseBands(for: .linked, sampleRate: rate)
            XCTAssertFalse(linearBands.isEmpty)
            XCTAssertEqual(try configuration.perBandFIRKernels(for: .linked, sampleRate: rate), [fir])
        }
    }

    func testClearedPerBandFIRIsAValidNoOpSlot() throws {
        let band = EQBand(type: .fir, firKernel: nil)
        let configuration = StereoEQConfiguration(
            channelMode: .linked,
            phaseMode: .minimumPhase,
            linkedBands: [band]
        )
        XCTAssertFalse(configuration.hasEnabledPerBandFIR)
        XCTAssertFalse(FIRUpdatePolicy.shouldPrepareMainEQFIR(
            stereoEQ: configuration,
            playback: PlaybackControlConfiguration()
        ))
        _ = try configuration.makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
    }

'''
if "testPerBandFIRKernelCascadeIsExactAndSumsDeclaredLatency" not in tests:
    marker = "    func testBootstrapTestBundleRuns() {\n"
    if marker not in tests:
        raise SystemExit("Expected FIR XCTest insertion point was not found")
    tests = tests.replace(marker, fir_tests + marker, 1)
tests_path.write_text(tests)

print("PR34 per-band FIR parity integration applied.")
