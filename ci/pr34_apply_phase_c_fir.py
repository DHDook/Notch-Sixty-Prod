from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Control-plane FIR cascade primitive: generic FFT convolution, never realtime.
# ---------------------------------------------------------------------------
header_path = Path("NotchSixty/Audio/Realtime/N60Convolution.h")
header = header_path.read_text()
declaration = '''// Control-plane only. Cascades two FIR kernels using an allocation-backed FFT.
// The result length is lhsCount + rhsCount - 1 and must not exceed the realtime
// convolver's fixed maximum tap budget.
bool N60FIRConvolveControlPlane(
    const float * _Nonnull lhs,
    uint32_t lhsCount,
    const float * _Nonnull rhs,
    uint32_t rhsCount,
    float * _Nonnull output,
    uint32_t outputCapacity
);

'''
if declaration not in header:
    marker = "N60PartitionedConvolver * _Nullable N60PartitionedConvolverCreate(void);\n"
    if marker not in header:
        raise SystemExit("Expected FIR control-plane declaration insertion point was not found")
    header = header.replace(marker, declaration + marker, 1)
header_path.write_text(header)

source_path = Path("NotchSixty/Audio/Realtime/N60Convolution.c")
source = source_path.read_text()
dynamic_fft = r'''static uint32_t next_power_of_two(uint32_t value) {
    uint32_t result = 1u;
    while (result < value) {
        if (result > UINT32_MAX / 2u) return 0u;
        result <<= 1u;
    }
    return result;
}

static void transform_dynamic(N60Complex *values, uint32_t count, bool inverse) {
    for (uint32_t index = 1u, reversed = 0u; index < count; ++index) {
        uint32_t bit = count >> 1u;
        for (; reversed & bit; bit >>= 1u) reversed ^= bit;
        reversed ^= bit;
        if (index < reversed) {
            N60Complex temporary = values[index];
            values[index] = values[reversed];
            values[reversed] = temporary;
        }
    }

    for (uint32_t length = 2u; length <= count; length <<= 1u) {
        double angle = (inverse ? 2.0 : -2.0) * N60_PI / (double)length;
        N60Complex step = {(float)cos(angle), (float)sin(angle)};
        uint32_t half = length >> 1u;
        for (uint32_t base = 0u; base < count; base += length) {
            N60Complex twiddle = {1.0f, 0.0f};
            for (uint32_t offset = 0u; offset < half; ++offset) {
                N60Complex even = values[base + offset];
                N60Complex odd = complex_multiply(values[base + offset + half], twiddle);
                values[base + offset] = (N60Complex){even.real + odd.real, even.imag + odd.imag};
                values[base + offset + half] = (N60Complex){even.real - odd.real, even.imag - odd.imag};
                twiddle = complex_multiply(twiddle, step);
            }
        }
        if (length == count) break;
    }

    if (inverse) {
        float scale = 1.0f / (float)count;
        for (uint32_t index = 0u; index < count; ++index) {
            values[index].real *= scale;
            values[index].imag *= scale;
        }
    }
}

'''
if dynamic_fft not in source:
    marker = "static size_t spectrum_storage_count(void) {\n"
    if marker not in source:
        raise SystemExit("Expected dynamic FFT insertion point was not found")
    source = source.replace(marker, dynamic_fft + marker, 1)

fir_function = r'''bool N60FIRConvolveControlPlane(
    const float *lhs,
    uint32_t lhsCount,
    const float *rhs,
    uint32_t rhsCount,
    float *output,
    uint32_t outputCapacity
) {
    if (lhs == NULL || rhs == NULL || output == NULL || lhsCount == 0u || rhsCount == 0u) return false;
    uint64_t required64 = (uint64_t)lhsCount + (uint64_t)rhsCount - 1u;
    if (required64 == 0u || required64 > N60_CONVOLUTION_MAX_TAPS || required64 > outputCapacity) return false;
    uint32_t required = (uint32_t)required64;
    for (uint32_t index = 0u; index < lhsCount; ++index) if (!isfinite(lhs[index])) return false;
    for (uint32_t index = 0u; index < rhsCount; ++index) if (!isfinite(rhs[index])) return false;

    uint32_t fftCount = next_power_of_two(required);
    if (fftCount == 0u) return false;
    N60Complex *left = calloc(fftCount, sizeof(N60Complex));
    N60Complex *right = calloc(fftCount, sizeof(N60Complex));
    if (left == NULL || right == NULL) {
        free(left);
        free(right);
        return false;
    }

    for (uint32_t index = 0u; index < lhsCount; ++index) left[index].real = lhs[index];
    for (uint32_t index = 0u; index < rhsCount; ++index) right[index].real = rhs[index];
    transform_dynamic(left, fftCount, false);
    transform_dynamic(right, fftCount, false);
    for (uint32_t index = 0u; index < fftCount; ++index) left[index] = complex_multiply(left[index], right[index]);
    transform_dynamic(left, fftCount, true);

    bool valid = true;
    for (uint32_t index = 0u; index < required; ++index) {
        output[index] = left[index].real;
        if (!isfinite(output[index])) valid = false;
    }
    free(left);
    free(right);
    return valid;
}

'''
if fir_function not in source:
    marker = "N60PartitionedConvolver *N60PartitionedConvolverCreate(void) {\n"
    if marker not in source:
        raise SystemExit("Expected FIR convolution implementation insertion point was not found")
    source = source.replace(marker, fir_function + marker, 1)
source_path.write_text(source)


# ---------------------------------------------------------------------------
# Swift EQ model: FIR is a real band type with its own kernel asset.
# ---------------------------------------------------------------------------
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
engine = replace_once(engine, "    case tilt\n    case notch", "    case tilt\n    case fir\n    case notch", "FIR filter enum")
engine = replace_once(
    engine,
    '        case .tilt: return "Tilt"\n        case .notch: return "Notch"',
    '        case .tilt: return "Tilt"\n        case .fir: return "FIR"\n        case .notch: return "Notch"',
    "FIR display name",
)
engine = replace_once(
    engine,
    "        case .tilt: return N60BiquadFilterTypeTilt\n        case .notch: return N60BiquadFilterTypeNotch",
    '''        case .tilt: return N60BiquadFilterTypeTilt
        case .fir:
            preconditionFailure("FIR EQ bands are convolution assets, not biquad filter types.")
        case .notch: return N60BiquadFilterTypeNotch''',
    "FIR non-biquad mapping",
)

kernel_model = r'''struct EQFIRKernel: Equatable, Sendable {
    var name: String
    var sampleRate: Double?
    var taps: [Float]

    init(name: String, sampleRate: Double? = nil, taps: [Float]) {
        self.name = name
        self.sampleRate = sampleRate
        self.taps = taps
    }

    func validate(for outputSampleRate: Double) throws {
        guard !taps.isEmpty, taps.count <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw EQConfigurationError.invalidFIRTapCount(taps.count)
        }
        guard taps.allSatisfy(\.isFinite) else {
            throw EQConfigurationError.nonFiniteFIRTap
        }
        if let sampleRate {
            guard sampleRate.isFinite, sampleRate > 0, abs(sampleRate - outputSampleRate) < 0.5 else {
                throw EQConfigurationError.firSampleRateMismatch(filter: sampleRate, output: outputSampleRate)
            }
        }
    }

    var conservativeBoostDB: Double {
        let l1 = taps.reduce(0.0) { $0 + abs(Double($1)) }
        guard l1 > 1.0 else { return 0.0 }
        return 20.0 * log10(l1)
    }

    static func validation(sampleRate: Double? = nil) -> EQFIRKernel {
        EQFIRKernel(name: "Validation FIR", sampleRate: sampleRate, taps: [0.25, 0.5, 0.25])
    }
}

enum EQFIRCompiler {
    static func cascade(base: [Float] = [1.0], kernels: [EQFIRKernel]) throws -> [Float] {
        guard !base.isEmpty, base.allSatisfy(\.isFinite) else {
            throw EQConfigurationError.nonFiniteFIRTap
        }
        var combined = base
        for kernel in kernels {
            let outputCount64 = UInt64(combined.count) + UInt64(kernel.taps.count) - 1
            guard outputCount64 <= UInt64(N60_CONVOLUTION_MAX_TAPS) else {
                throw EQConfigurationError.firTapBudgetExceeded(Int(outputCount64))
            }
            let outputCount = Int(outputCount64)
            var output = [Float](repeating: 0, count: outputCount)
            let ok = combined.withUnsafeBufferPointer { lhs in
                kernel.taps.withUnsafeBufferPointer { rhs in
                    output.withUnsafeMutableBufferPointer { destination in
                        N60FIRConvolveControlPlane(
                            lhs.baseAddress!, UInt32(lhs.count),
                            rhs.baseAddress!, UInt32(rhs.count),
                            destination.baseAddress!, UInt32(destination.count)
                        )
                    }
                }
            }
            guard ok else { throw EQConfigurationError.firCascadeFailed }
            combined = output
        }
        return combined
    }
}

'''
if kernel_model not in engine:
    marker = "struct EQBand: Identifiable, Equatable, Sendable {\n"
    if marker not in engine:
        raise SystemExit("Expected EQFIRKernel insertion point was not found")
    engine = engine.replace(marker, kernel_model + marker, 1)

engine = replace_once(
    engine,
    "    var linkwitzTargetQ: Double\n    var dynamic: EQBandDynamicConfiguration",
    "    var linkwitzTargetQ: Double\n    var firKernel: EQFIRKernel?\n    var dynamic: EQBandDynamicConfiguration",
    "FIR band state",
)
engine = replace_once(
    engine,
    "        linkwitzTargetQ: Double = 0.707,\n        dynamic: EQBandDynamicConfiguration = EQBandDynamicConfiguration()",
    "        linkwitzTargetQ: Double = 0.707,\n        firKernel: EQFIRKernel? = nil,\n        dynamic: EQBandDynamicConfiguration = EQBandDynamicConfiguration()",
    "FIR band initializer",
)
engine = replace_once(
    engine,
    "        self.linkwitzTargetQ = linkwitzTargetQ\n        self.dynamic = dynamic",
    "        self.linkwitzTargetQ = linkwitzTargetQ\n        self.firKernel = firKernel\n        self.dynamic = dynamic",
    "FIR band initializer assignment",
)
engine = replace_once(
    engine,
    "        if type == .linkwitzTransform {",
    '''        if type == .fir {
            return []
        }

        if type == .linkwitzTransform {''',
    "FIR compiled-section bypass",
)

engine = replace_once(
    engine,
    "    case convolutionProgramUnavailable\n",
    '''    case convolutionProgramUnavailable
    case firKernelRequired
    case invalidFIRTapCount(Int)
    case nonFiniteFIRTap
    case firSampleRateMismatch(filter: Double, output: Double)
    case firTapBudgetExceeded(Int)
    case firCascadeFailed
''',
    "FIR EQ errors",
)
engine = replace_once(
    engine,
    '''        case .convolutionProgramUnavailable:
            return "No safe FIR program slot is currently available."
''',
    '''        case .convolutionProgramUnavailable:
            return "No safe FIR program slot is currently available."
        case .firKernelRequired:
            return "FIR EQ bands require an impulse-response kernel before they can be enabled."
        case .invalidFIRTapCount(let count):
            return "FIR EQ tap count \(count) is outside the supported 1...\(Int(N60_CONVOLUTION_MAX_TAPS)) range."
        case .nonFiniteFIRTap:
            return "FIR EQ coefficients must all be finite."
        case .firSampleRateMismatch(let filter, let output):
            return "FIR EQ kernel rate \(filter) Hz does not match the active output rate \(output) Hz."
        case .firTapBudgetExceeded(let count):
            return "The cascaded EQ FIR would require \(count) taps, exceeding the \(Int(N60_CONVOLUTION_MAX_TAPS))-tap realtime budget."
        case .firCascadeFailed:
            return "Unable to compile the active per-band FIR kernels into the EQ convolution program."
''',
    "FIR EQ error descriptions",
)

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
            guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
            try kernel.validate(for: sampleRate)
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

# The compatibility Linear Phase projection must ignore FIR bands because the
# live engine compiles them into its EQ convolution program separately.
engine = replace_once(
    engine,
    '''            guard band.type != .allPass else {
                throw EQConfigurationError.allPassRequiresMinimumPhase
            }
            for section in try band.compiledSections(sampleRate: sampleRate) {
''',
    '''            guard band.type != .allPass else {
                throw EQConfigurationError.allPassRequiresMinimumPhase
            }
            if band.type == .fir { continue }
            for section in try band.compiledSections(sampleRate: sampleRate) {
''',
    "compatibility Linear Phase FIR exclusion",
)

# Rename the EQ-stage FIR state so it accurately covers Linear Phase and
# per-band FIR instead of only the historical Linear Phase use.
replacements = {
    "PreparedLinearPhaseProgram": "PreparedEQFIRProgram",
    "activeLinearPhaseProgram": "activeEQFIRProgram",
    "nextLinearPhaseProgramSlot": "nextEQFIRProgramSlot",
    "prepareLinearPhaseProgram": "prepareEQFIRProgram",
    "attachLinearPhaseProgram": "attachEQFIRProgram",
    "attachActiveLinearPhaseProgramIfNeeded": "attachActiveEQFIRProgramIfNeeded",
    "preparedLinearProgram": "preparedEQFIRProgram",
    "leavingLinearPhase": "leavingEQFIR",
    "enteringOrReplacingLinearPhase": "enteringOrReplacingEQFIR",
}
for old, new in replacements.items():
    engine = engine.replace(old, new)

engine = replace_once(
    engine,
    '''private struct PreparedEQFIRProgram {
    let slot: UInt32
    let programInfo: N60ConvolutionProgramInfo
    let designInfo: N60LinearPhaseEQDesignInfo
}
''',
    '''private struct PreparedEQFIRProgram {
    let slot: UInt32
    let programInfo: N60ConvolutionProgramInfo
    let designInfo: N60LinearPhaseEQDesignInfo?
}
''',
    "generic EQ FIR prepared program",
)

# Replace the program preparation implementation with a lane-aware cascade.
pattern = re.compile(
    r"    private func prepareEQFIRProgram\([\s\S]*?\n    \}\n\n    private func validateRoomCorrectionFilter",
    re.MULTILINE,
)
match = pattern.search(engine)
if not match:
    raise SystemExit("Expected EQ FIR preparation function was not found")
new_prepare = r'''    private func prepareLaneEQFIRTaps(
        _ configuration: StereoEQConfiguration,
        channel: EQEditChannel,
        sampleRate: Double
    ) throws -> (taps: [Float], declaredLatencyFrames: UInt32, designInfo: N60LinearPhaseEQDesignInfo?) {
        let baseTaps: [Float]
        let declaredLatency: UInt32
        let designInfo: N60LinearPhaseEQDesignInfo?
        if configuration.phaseMode == .linearPhase {
            let tapCount = Int(N60LinearPhaseEQRecommendedTapCount(sampleRate))
            guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            let design = try designLinearPhaseTaps(
                configuration,
                channel: channel,
                sampleRate: sampleRate,
                tapCount: tapCount
            )
            baseTaps = design.taps
            declaredLatency = design.info.groupDelayFrames
            designInfo = design.info
        } else {
            baseTaps = [1.0]
            declaredLatency = 0
            designInfo = nil
        }

        let kernels = try configuration.firKernels(for: channel, sampleRate: sampleRate)
        return (
            try EQFIRCompiler.cascade(base: baseTaps, kernels: kernels),
            declaredLatency,
            designInfo
        )
    }

    private func prepareEQFIRProgram(
        _ configuration: StereoEQConfiguration,
        for session: CoreAudioTransportSession
    ) throws -> PreparedEQFIRProgram {
        let sampleRate = session.outputFormat.sampleRate
        let primaryChannel: EQEditChannel
        switch configuration.channelMode {
        case .linked: primaryChannel = .linked
        case .independent: primaryChannel = .left
        case .midSide: primaryChannel = .mid
        }
        var primary = try prepareLaneEQFIRTaps(
            configuration,
            channel: primaryChannel,
            sampleRate: sampleRate
        )

        var secondaryTaps: [Float]?
        if configuration.channelMode != .linked {
            let secondaryChannel: EQEditChannel = configuration.channelMode == .midSide ? .side : .right
            var secondary = try prepareLaneEQFIRTaps(
                configuration,
                channel: secondaryChannel,
                sampleRate: sampleRate
            )
            guard secondary.declaredLatencyFrames == primary.declaredLatencyFrames else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            let commonCount = max(primary.taps.count, secondary.taps.count)
            if primary.taps.count < commonCount {
                primary.taps.append(contentsOf: repeatElement(0, count: commonCount - primary.taps.count))
            }
            if secondary.taps.count < commonCount {
                secondary.taps.append(contentsOf: repeatElement(0, count: commonCount - secondary.taps.count))
            }
            secondaryTaps = secondary.taps
        }

        let slot = nextEQFIRProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareConvolutionProgram(
                slot: slot,
                leftTaps: primary.taps,
                rightTaps: secondaryTaps,
                declaredLatencyFrames: primary.declaredLatencyFrames
            )
        } catch {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        nextEQFIRProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedEQFIRProgram(
            slot: slot,
            programInfo: programInfo,
            designInfo: primary.designInfo
        )
    }

    private func validateRoomCorrectionFilter'''
engine = engine[:match.start()] + new_prepare + engine[match.end():]

# Active attachment is required for either Linear Phase or any active per-band FIR.
engine = replace_once(
    engine,
    '''        guard !processingIsBypassed(playbackConfiguration),
              stereoConfiguration.phaseMode == .linearPhase,
              !stereoConfiguration.bypassed else { return }
''',
    '''        guard !processingIsBypassed(playbackConfiguration),
              stereoConfiguration.requiresEQFIRProgram,
              !stereoConfiguration.bypassed else { return }
''',
    "generic EQ FIR attachment guard",
)

# Live storage validation treats FIR as a kernel asset rather than a parametric band.
old_storage_guard = '''            for (index, band) in bands.enumerated() where band.enabled {
                guard band.frequencyHz.isFinite,
                      band.frequencyHz > 0,
                      band.gainDB.isFinite,
                      StereoEQConfiguration.bandGainRange.contains(band.gainDB),
                      band.q.isFinite,
                      band.q > 0 else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
'''
new_storage_guard = '''            for (index, band) in bands.enumerated() where band.enabled {
                if band.type == .fir {
                    guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
                    try kernel.validate(for: transportSession?.outputFormat.sampleRate ?? 48_000)
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
engine = replace_once(engine, old_storage_guard, new_storage_guard, "live FIR storage validation")

# Generalize the runtime preparation condition and the structural transition logic.
engine = engine.replace("FIRUpdatePolicy.shouldPrepareLinearPhase(", "FIRUpdatePolicy.shouldPrepareEQFIR(")
engine = replace_once(
    engine,
    '''                var preparedEQFIRProgram: PreparedEQFIRProgram?
                if configuration.phaseMode == .linearPhase && !configuration.bypassed {
                    let prepared = try prepareEQFIRProgram(configuration, for: session)
                    preparedEQFIRProgram = prepared
                    linearPhaseDesignInfo = prepared.designInfo
                    try attachEQFIRProgram(prepared, to: &graph)
                } else {
                    linearPhaseDesignInfo = nil
                }
''',
    '''                var preparedEQFIRProgram: PreparedEQFIRProgram?
                if configuration.requiresEQFIRProgram && !configuration.bypassed {
                    let prepared = try prepareEQFIRProgram(configuration, for: session)
                    preparedEQFIRProgram = prepared
                    linearPhaseDesignInfo = prepared.designInfo
                    try attachEQFIRProgram(prepared, to: &graph)
                } else {
                    linearPhaseDesignInfo = nil
                }
''',
    "live EQ FIR preparation",
)
engine = replace_once(
    engine,
    '''                let leavingEQFIR = activeEQFIRProgram != nil
                    && (configuration.phaseMode != .linearPhase || configuration.bypassed)
''',
    '''                let leavingEQFIR = activeEQFIRProgram != nil
                    && (!configuration.requiresEQFIRProgram || configuration.bypassed)
''',
    "EQ FIR transition exit",
)
engine_path.write_text(engine)


# ---------------------------------------------------------------------------
# Stereo configuration: lane FIR ownership and preparation policy.
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
                guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
                try kernel.validate(for: sampleRate)
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

stereo = replace_once(
    stereo,
    '''        func channelBoost(_ bands: [EQBand]) -> Double {
            bands.lazy.filter(\.enabled).reduce(0.0) { partial, band in
                partial + max(0.0, band.gainDB)
            }
        }
''',
    '''        func channelBoost(_ bands: [EQBand]) -> Double {
            bands.lazy.filter(\.enabled).reduce(0.0) { partial, band in
                if band.type == .fir {
                    return partial + (band.firKernel?.conservativeBoostDB ?? 0.0)
                }
                return partial + max(0.0, band.gainDB)
            }
        }
''',
    "FIR automatic headroom bound",
)

stereo = replace_once(
    stereo,
    '''    private func publishMinimumPhaseBand(
        _ band: EQBand,
        into graph: inout N60DSPGraphSnapshot,
        renderIndex: inout UInt32,
        channelMask: UInt8? = nil
    ) throws {
        for section in try band.compiledSections(sampleRate: graph.sampleRate) {
''',
    '''    private func publishMinimumPhaseBand(
        _ band: EQBand,
        into graph: inout N60DSPGraphSnapshot,
        renderIndex: inout UInt32,
        channelMask: UInt8? = nil
    ) throws {
        if band.type == .fir { return }
        for section in try band.compiledSections(sampleRate: graph.sampleRate) {
''',
    "minimum-phase FIR convolution routing",
)

fir_lane_helpers = r'''    var requiresEQFIRProgram: Bool {
        guard !bypassed else { return false }
        if phaseMode == .linearPhase { return true }
        let activeBanks: [[EQBand]]
        switch channelMode {
        case .linked: activeBanks = [linkedBands]
        case .independent: activeBanks = [leftBands, rightBands]
        case .midSide: activeBanks = [midBands, sideBands]
        }
        return activeBanks.contains { bands in
            bands.contains { $0.enabled && $0.type == .fir }
        }
    }

    func firKernels(for channel: EQEditChannel, sampleRate: Double) throws -> [EQFIRKernel] {
        let source: [EQBand]
        switch channelMode {
        case .linked: source = linkedBands
        case .independent: source = channel == .right ? rightBands : leftBands
        case .midSide: source = channel == .side ? sideBands : midBands
        }
        let bands = try validatedEnabledBands(source, sampleRate: sampleRate)
        return try bands.compactMap { band in
            guard band.type == .fir else { return nil }
            guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
            try kernel.validate(for: sampleRate)
            return kernel
        }
    }

'''
if fir_lane_helpers not in stereo:
    marker = "    func makeGraphSnapshot(\n"
    if marker not in stereo:
        raise SystemExit("Expected FIR lane-helper insertion point was not found")
    stereo = stereo.replace(marker, fir_lane_helpers + marker, 1)

# Linear phase designer handles non-FIR bands; FIR kernels are cascaded later.
stereo = replace_once(
    stereo,
    '''        guard !bands.contains(where: { $0.type == .allPass }) else {
            throw EQConfigurationError.allPassRequiresMinimumPhase
        }
        var result: [N60LinearPhaseEQBand] = []
''',
    '''        guard !bands.contains(where: { $0.type == .allPass }) else {
            throw EQConfigurationError.allPassRequiresMinimumPhase
        }
        var result: [N60LinearPhaseEQBand] = []
''',
    "Linear Phase FIR split marker",
)
# compiledSections returns [] for FIR, so no additional projection is emitted.

old_policy = '''    static func shouldPrepareLinearPhase(
        stereoEQ: StereoEQConfiguration,
        playback: PlaybackControlConfiguration
    ) -> Bool {
        !isRawBypassed(playback)
            && stereoEQ.phaseMode == .linearPhase
            && !stereoEQ.bypassed
    }
'''
new_policy = '''    static func shouldPrepareLinearPhase(
        stereoEQ: StereoEQConfiguration,
        playback: PlaybackControlConfiguration
    ) -> Bool {
        !isRawBypassed(playback)
            && stereoEQ.phaseMode == .linearPhase
            && !stereoEQ.bypassed
    }

    static func shouldPrepareEQFIR(
        stereoEQ: StereoEQConfiguration,
        playback: PlaybackControlConfiguration
    ) -> Bool {
        !isRawBypassed(playback) && stereoEQ.requiresEQFIRProgram
    }
'''
stereo = replace_once(stereo, old_policy, new_policy, "generic EQ FIR update policy")
stereo_path.write_text(stereo)


# ---------------------------------------------------------------------------
# Validation UI: FIR gets kernel controls, not parametric controls.
# ---------------------------------------------------------------------------
view_path = Path("NotchSixty/ContentView.swift")
view = view_path.read_text()
view = replace_once(
    view,
    'TextField("Hz", value: binding.frequencyHz, format: .number.precision(.fractionLength(0...1))).frame(width: 85)',
    'TextField("Hz", value: binding.frequencyHz, format: .number.precision(.fractionLength(0...1))).frame(width: 85).disabled(band.type == .fir)',
    "FIR frequency control disable",
)
view = replace_once(
    view,
    ".disabled(band.type == .linkwitzTransform)",
    ".disabled(band.type == .linkwitzTransform || band.type == .fir)",
    "FIR gain control disable",
)
view = replace_once(
    view,
    ".disabled(band.type == .tilt)",
    ".disabled(band.type == .tilt || band.type == .fir)",
    "FIR Q control disable",
)
fir_ui = r'''            if band.type == .fir {
                HStack(spacing: 8) {
                    Text("FIR kernel").frame(width: 82, alignment: .leading).foregroundStyle(.secondary)
                    if let kernel = band.firKernel {
                        Text("\(kernel.name) / \(kernel.taps.count) taps")
                            .monospacedDigit()
                    } else {
                        Text("No kernel loaded").foregroundStyle(.secondary)
                    }
                    Button("Load Validation FIR") {
                        var updated = binding.wrappedValue
                        updated.firKernel = .validation(sampleRate: engine.diagnosticsSnapshot().outputSampleRate)
                        binding.wrappedValue = updated
                    }
                    Button("Clear") {
                        var updated = binding.wrappedValue
                        updated.firKernel = nil
                        binding.wrappedValue = updated
                    }
                    .disabled(band.firKernel == nil)
                }
                Text("Per-band FIR is compiled off the realtime thread into the dedicated EQ convolution stage; room correction remains a separate FIR stage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
            }

'''
if fir_ui not in view:
    marker = "            if band.type == .linkwitzTransform {\n"
    if marker not in view:
        raise SystemExit("Expected FIR validation UI insertion point was not found")
    view = view.replace(marker, fir_ui + marker, 1)
view = replace_once(
    view,
    '''                if sanitized.type != .peaking {
                    sanitized.constantQ = false
                    sanitized.dynamic.enabled = false
                }
''',
    '''                if sanitized.type != .peaking {
                    sanitized.constantQ = false
                    sanitized.dynamic.enabled = false
                }
                if sanitized.type != .fir {
                    // Keep a loaded FIR asset attached to the band so switching
                    // types for comparison does not destroy user state.
                }
''',
    "FIR binding preservation",
)
view = view.replace('"Linear FIR",', '"EQ FIR",')
view_path.write_text(view)


# ---------------------------------------------------------------------------
# Regression tests for the FIR asset, cascade, lane ownership, and policy.
# ---------------------------------------------------------------------------
tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
tests_to_add = r'''    func testPerBandFIRKernelValidationAndCascade() throws {
        let first = EQFIRKernel(name: "First", taps: [1, 1])
        let second = EQFIRKernel(name: "Second", taps: [1, -1])
        try first.validate(for: 384_000)
        try second.validate(for: 384_000)
        let combined = try EQFIRCompiler.cascade(kernels: [first, second])
        XCTAssertEqual(combined.count, 3)
        XCTAssertEqual(combined[0], 1, accuracy: 0.000_01)
        XCTAssertEqual(combined[1], 0, accuracy: 0.000_01)
        XCTAssertEqual(combined[2], -1, accuracy: 0.000_01)
    }

    func testPerBandFIRRequiresKernelAndHonorsSampleRate() throws {
        let missing = EQBand(type: .fir, firKernel: nil)
        let missingConfiguration = StereoEQConfiguration(linkedBands: [missing])
        XCTAssertThrowsError(
            try missingConfiguration.makeGraphSnapshot(
                sampleRate: 96_000,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: BassManagementConfiguration(),
                playbackConfiguration: PlaybackControlConfiguration()
            )
        )

        let mismatched = EQBand(
            type: .fir,
            firKernel: EQFIRKernel(name: "48k", sampleRate: 48_000, taps: [1])
        )
        let mismatchedConfiguration = StereoEQConfiguration(linkedBands: [mismatched])
        XCTAssertThrowsError(try mismatchedConfiguration.firKernels(for: .linked, sampleRate: 96_000))
    }

    func testPerBandFIRUsesEQConvolutionPolicyInMinimumPhaseAndAllChannelModes() throws {
        let fir = EQBand(type: .fir, firKernel: .validation())
        let playback = PlaybackControlConfiguration()

        let linked = StereoEQConfiguration(phaseMode: .minimumPhase, linkedBands: [fir])
        XCTAssertTrue(linked.requiresEQFIRProgram)
        XCTAssertTrue(FIRUpdatePolicy.shouldPrepareEQFIR(stereoEQ: linked, playback: playback))
        XCTAssertEqual(try linked.firKernels(for: .linked, sampleRate: 384_000).count, 1)

        let independent = StereoEQConfiguration(
            channelMode: .independent,
            editChannel: .left,
            phaseMode: .minimumPhase,
            leftBands: [fir],
            rightBands: [],
            independentSeeded: true
        )
        XCTAssertTrue(independent.requiresEQFIRProgram)
        XCTAssertEqual(try independent.firKernels(for: .left, sampleRate: 192_000).count, 1)
        XCTAssertEqual(try independent.firKernels(for: .right, sampleRate: 192_000).count, 0)

        let midSide = StereoEQConfiguration(
            channelMode: .midSide,
            editChannel: .mid,
            phaseMode: .minimumPhase,
            midBands: [fir],
            sideBands: [],
            midSideSeeded: true
        )
        XCTAssertTrue(midSide.requiresEQFIRProgram)
        XCTAssertEqual(try midSide.firKernels(for: .mid, sampleRate: 96_000).count, 1)
        XCTAssertEqual(try midSide.firKernels(for: .side, sampleRate: 96_000).count, 0)
    }

    func testLinearPhaseProjectionExcludesPerBandFIRBecauseItIsCascadedSeparately() throws {
        let peak = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 3, q: 1)
        let fir = EQBand(type: .fir, firKernel: .validation())
        let configuration = StereoEQConfiguration(
            phaseMode: .linearPhase,
            linkedBands: [peak, fir]
        )
        let projected = try configuration.linearPhaseBands(for: .linked, sampleRate: 96_000)
        XCTAssertEqual(projected.count, 1)
        XCTAssertTrue(configuration.requiresEQFIRProgram)
    }

'''
if "testPerBandFIRKernelValidationAndCascade" not in tests:
    marker = "    func testMidSideModelPublishesDedicatedLanesInMinimumAndLinearPhase() throws {\n"
    if marker not in tests:
        raise SystemExit("Expected per-band FIR test insertion point was not found")
    tests = tests.replace(marker, tests_to_add + marker, 1)
tests_path.write_text(tests)

print("PR34 Phase C per-band FIR integration applied.")
