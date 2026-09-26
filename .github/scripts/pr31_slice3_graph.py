from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"anchor not found: {label}")
    return text.replace(old, new, 1)

# -----------------------------------------------------------------------------
# Tighten standalone denoiser snapshot + RT stack use.
# -----------------------------------------------------------------------------
h = Path('NotchSixty/Audio/Realtime/N60SpectralDenoiser.h')
text = h.read_text()
text = replace_once(text,
    'typedef struct {\n    bool enabled;\n    N60DenoiserTuning tuning;\n',
    'typedef struct {\n    double sampleRate;\n    bool enabled;\n    N60DenoiserTuning tuning;\n',
    'denoiser snapshot sample rate')
h.write_text(text)

c = Path('NotchSixty/Audio/Realtime/N60SpectralDenoiser.c')
text = c.read_text()
text = replace_once(text,
    '    float previousEnhancedPower[N60_DENOISER_MAX_BINS];\n    float targetGain[N60_DENOISER_MAX_BINS];\n',
    '    float previousEnhancedPower[N60_DENOISER_MAX_BINS];\n    float linkedPower[N60_DENOISER_MAX_BINS];\n    float targetGain[N60_DENOISER_MAX_BINS];\n',
    'preallocated linked power scratch')
text = replace_once(text,
    '    N60SpectralDenoiserSnapshot snapshot = {0};\n    snapshot.enabled = false;\n',
    '    N60SpectralDenoiserSnapshot snapshot = {0};\n    snapshot.sampleRate = sampleRate;\n    snapshot.enabled = false;\n',
    'bypassed sample rate')
text = replace_once(text,
    '    N60SpectralDenoiserSnapshot configured = {0};\n    configured.enabled = enabled;\n',
    '    N60SpectralDenoiserSnapshot configured = {0};\n    configured.sampleRate = sampleRate;\n    configured.enabled = enabled;\n',
    'configured sample rate')
text = replace_once(text,
    '    if (!isfinite(sampleRate) || sampleRate < 8000.0 || sampleRate > 384000.0\n        || !quality_is_valid(snapshot.quality)',
    '    if (!isfinite(sampleRate) || sampleRate < 8000.0 || sampleRate > 384000.0\n        || !isfinite(snapshot.sampleRate) || fabs(snapshot.sampleRate - sampleRate) > 0.5\n        || !quality_is_valid(snapshot.quality)',
    'sample rate validity')
text = replace_once(text,
    '    memset(runtime->previousEnhancedPower, 0, sizeof(runtime->previousEnhancedPower));\n    memset(runtime->targetGain, 0, sizeof(runtime->targetGain));\n',
    '    memset(runtime->previousEnhancedPower, 0, sizeof(runtime->previousEnhancedPower));\n    memset(runtime->linkedPower, 0, sizeof(runtime->linkedPower));\n    memset(runtime->targetGain, 0, sizeof(runtime->targetGain));\n',
    'clear linked power scratch')
text = replace_once(text,
    '    float linkedPower[N60_DENOISER_MAX_BINS];\n    for (uint32_t bin = 0; bin < binCount; ++bin) {\n        float leftPower = bin_power(runtime->fftLeft[bin], bin, nyquistBin, windowSum);\n        float rightPower = bin_power(runtime->fftRight[bin], bin, nyquistBin, windowSum);\n        linkedPower[bin] = fmaxf(leftPower, rightPower);\n    }\n\n    update_profile(runtime, linkedPower, binCount, sampleRate, snapshot.hopSize);\n',
    '    for (uint32_t bin = 0; bin < binCount; ++bin) {\n        float leftPower = bin_power(runtime->fftLeft[bin], bin, nyquistBin, windowSum);\n        float rightPower = bin_power(runtime->fftRight[bin], bin, nyquistBin, windowSum);\n        runtime->linkedPower[bin] = fmaxf(leftPower, rightPower);\n    }\n\n    update_profile(runtime, runtime->linkedPower, binCount, sampleRate, snapshot.hopSize);\n',
    'linked power runtime scratch')
text = text.replace('linkedPower[bin]', 'runtime->linkedPower[bin]')
c.write_text(text)

# -----------------------------------------------------------------------------
# Dynamics snapshot owns the render-ready denoiser configuration.
# -----------------------------------------------------------------------------
h = Path('NotchSixty/Audio/Realtime/N60Dynamics.h')
text = h.read_text()
text = replace_once(text,
    '#include "N60Crossover.h"\n',
    '#include "N60Crossover.h"\n#include "N60SpectralDenoiser.h"\n',
    'dynamics denoiser include')
text = replace_once(text,
    '    N60MainsNotchSnapshot mainsNotch;\n    N60MainsHumDetectorSnapshot mainsHumDetector;\n    N60LoudnessMatchSnapshot loudnessMatch;\n',
    '    N60MainsNotchSnapshot mainsNotch;\n    N60MainsHumDetectorSnapshot mainsHumDetector;\n    N60SpectralDenoiserSnapshot spectralDenoiser;\n    N60LoudnessMatchSnapshot loudnessMatch;\n',
    'dynamics denoiser member')
anchor = '''bool N60DynamicsSnapshotSetMainsHumDetector(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double searchCenterHz
);
'''
addition = anchor + '''
bool N60DynamicsSnapshotSetSpectralDenoiser(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    N60DenoiserTuning tuning,
    N60DenoiserQuality quality,
    float reductionAmount,
    float thresholdDBFS,
    bool protectedRangeEnabled,
    float protectedLowHz,
    float protectedHighHz,
    uint32_t profileRevision,
    N60DenoiserProfileCommand profileCommand
);
'''
text = replace_once(text, anchor, addition, 'dynamics denoiser setter declaration')
h.write_text(text)

c = Path('NotchSixty/Audio/Realtime/N60Dynamics.c')
text = c.read_text()
text = replace_once(text,
    '    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {\n        snapshot.mainsHumDetector.oscillatorStepCos[index] = 1.0f;\n        snapshot.mainsHumDetector.oscillatorStepSin[index] = 0.0f;\n    }\n\n    snapshot.loudnessMatch.enabled = false;\n',
    '    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {\n        snapshot.mainsHumDetector.oscillatorStepCos[index] = 1.0f;\n        snapshot.mainsHumDetector.oscillatorStepSin[index] = 0.0f;\n    }\n\n    snapshot.spectralDenoiser = N60SpectralDenoiserSnapshotMakeBypassed(sampleRate);\n\n    snapshot.loudnessMatch.enabled = false;\n',
    'dynamics denoiser default')
setter_anchor = '''bool N60DynamicsSnapshotSetLoudnessMatch(
    N60DynamicsSnapshot *snapshot,
'''
setter = '''bool N60DynamicsSnapshotSetSpectralDenoiser(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    N60DenoiserTuning tuning,
    N60DenoiserQuality quality,
    float reductionAmount,
    float thresholdDBFS,
    bool protectedRangeEnabled,
    float protectedLowHz,
    float protectedHighHz,
    uint32_t profileRevision,
    N60DenoiserProfileCommand profileCommand
) {
    if (snapshot == NULL) return false;
    N60SpectralDenoiserSnapshot configured = N60SpectralDenoiserSnapshotMakeBypassed(sampleRate);
    if (!N60SpectralDenoiserSnapshotConfigure(
            &configured,
            sampleRate,
            enabled,
            tuning,
            quality,
            reductionAmount,
            thresholdDBFS,
            protectedRangeEnabled,
            protectedLowHz,
            protectedHighHz,
            profileRevision,
            profileCommand)) return false;
    snapshot->spectralDenoiser = configured;
    return true;
}

'''+setter_anchor
text = replace_once(text, setter_anchor, setter, 'dynamics denoiser setter')
valid_anchor = '''    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {
        if (!isfinite(snapshot.mainsHumDetector.oscillatorStepCos[index])
            || !isfinite(snapshot.mainsHumDetector.oscillatorStepSin[index])) return false;
    }
    if (!isfinite(snapshot.loudnessMatch.targetLUFS)'''
valid_repl = '''    for (uint32_t index = 0; index < N60_MAINS_DETECTOR_BIN_COUNT; ++index) {
        if (!isfinite(snapshot.mainsHumDetector.oscillatorStepCos[index])
            || !isfinite(snapshot.mainsHumDetector.oscillatorStepSin[index])) return false;
    }
    if (!N60SpectralDenoiserSnapshotIsValid(snapshot.spectralDenoiser, snapshot.spectralDenoiser.sampleRate)) return false;
    if (!isfinite(snapshot.loudnessMatch.targetLUFS)'''
text = replace_once(text, valid_anchor, valid_repl, 'dynamics denoiser validity')
c.write_text(text)

# -----------------------------------------------------------------------------
# Swift product/control state and legacy-visible presets.
# -----------------------------------------------------------------------------
sw = Path('NotchSixty/Audio/DynamicsConfiguration.swift')
text = sw.read_text()
text = replace_once(text,
    '    case invalidMainsHumDetector\n    case invalidLoudnessMatch\n',
    '    case invalidMainsHumDetector\n    case invalidSpectralDenoiser\n    case invalidLoudnessMatch\n',
    'denoiser config error')
text = replace_once(text,
    '        case .invalidMainsHumDetector:\n            return "Mains Hum detector parameters are outside the supported production range."\n        case .invalidLoudnessMatch:\n',
    '        case .invalidMainsHumDetector:\n            return "Mains Hum detector parameters are outside the supported production range."\n        case .invalidSpectralDenoiser:\n            return "Spectral Denoiser parameters are outside the supported production range."\n        case .invalidLoudnessMatch:\n',
    'denoiser config error text')
insert_anchor = 'struct LoudnessMatchConfiguration: Equatable, Sendable {\n'
insert = r'''enum SpectralDenoiserPreset: String, CaseIterable, Identifiable, Sendable {
    case natural
    case standard
    case aggressive
    case dehiss
    case custom

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .natural: return "Natural"
        case .standard: return "Standard"
        case .aggressive: return "Aggressive"
        case .dehiss: return "Dehiss"
        case .custom: return "Custom"
        }
    }

    var cType: N60DenoiserTuning {
        switch self {
        case .natural: return N60DenoiserTuningNatural
        case .aggressive: return N60DenoiserTuningAggressive
        case .dehiss: return N60DenoiserTuningDehiss
        case .custom: return N60DenoiserTuningCustom
        case .standard: return N60DenoiserTuningStandard
        }
    }
}

enum SpectralDenoiserQuality: String, CaseIterable, Identifiable, Sendable {
    case quality
    case high
    case ultra

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .quality: return "Quality"
        case .high: return "High"
        case .ultra: return "Ultra"
        }
    }
    var cType: N60DenoiserQuality {
        switch self {
        case .quality: return N60DenoiserQualityQuality
        case .high: return N60DenoiserQualityHigh
        case .ultra: return N60DenoiserQualityUltra
        }
    }
}

enum SpectralDenoiserProfileCommand: Equatable, Sendable {
    case none
    case capture
    case reset

    var cType: N60DenoiserProfileCommand {
        switch self {
        case .capture: return N60DenoiserProfileCommandCapture
        case .reset: return N60DenoiserProfileCommandReset
        case .none: return N60DenoiserProfileCommandNone
        }
    }
}

struct SpectralDenoiserConfiguration: Equatable, Sendable {
    static let reductionRange = 0.0...1.0
    static let thresholdRange = -96.0 ... -30.0
    static let protectedFrequencyRange = 0.0...20_000.0

    var enabled = false
    var preset: SpectralDenoiserPreset = .natural
    // Custom means visible user values have been edited. Preserve the last
    // named algorithm tuning so a tiny manual edit does not silently change
    // artifact-management behavior (especially Dehiss).
    var customBasePreset: SpectralDenoiserPreset = .natural
    var reductionAmount = 0.50
    var thresholdDBFS = -72.0
    var quality: SpectralDenoiserQuality = .high
    var protectedRangeEnabled = false
    var protectedLowHz = 0.0
    var protectedHighHz = 150.0
    var profileRevision: UInt32 = 0
    var profileCommand: SpectralDenoiserProfileCommand = .none

    var algorithmPreset: SpectralDenoiserPreset {
        preset == .custom ? customBasePreset : preset
    }

    mutating func applyPreset(_ value: SpectralDenoiserPreset) {
        guard value != .custom else {
            markCustom()
            return
        }
        preset = value
        customBasePreset = value
        quality = .high
        protectedLowHz = 0
        protectedHighHz = 150
        switch value {
        case .natural:
            thresholdDBFS = -72
            reductionAmount = 0.50
            protectedRangeEnabled = false
        case .standard:
            thresholdDBFS = -60
            reductionAmount = 0.50
            protectedRangeEnabled = false
        case .aggressive:
            thresholdDBFS = -48
            reductionAmount = 0.50
            protectedRangeEnabled = false
        case .dehiss:
            thresholdDBFS = -58
            reductionAmount = 0.40
            protectedRangeEnabled = true
        case .custom:
            break
        }
    }

    mutating func markCustom() {
        if preset != .custom {
            customBasePreset = preset
            preset = .custom
        }
    }

    mutating func requestProfileCapture() {
        profileRevision &+= 1
        profileCommand = .capture
    }

    mutating func resetProfile() {
        profileRevision &+= 1
        profileCommand = .reset
    }

    func validate(sampleRate: Double) throws {
        let nyquist = sampleRate * 0.5
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000,
              reductionAmount.isFinite, Self.reductionRange.contains(reductionAmount),
              thresholdDBFS.isFinite, Self.thresholdRange.contains(thresholdDBFS),
              protectedLowHz.isFinite, Self.protectedFrequencyRange.contains(protectedLowHz),
              protectedHighHz.isFinite, Self.protectedFrequencyRange.contains(protectedHighHz),
              protectedLowHz <= protectedHighHz,
              protectedHighHz < nyquist else {
            throw DynamicsConfigurationError.invalidSpectralDenoiser
        }
    }
}

''' + insert_anchor
text = replace_once(text, insert_anchor, insert, 'denoiser Swift configuration')
text = replace_once(text,
    '    var mainsNotch = MainsNotchConfiguration()\n    var loudnessMatch = LoudnessMatchConfiguration()\n',
    '    var mainsNotch = MainsNotchConfiguration()\n    var spectralDenoiser = SpectralDenoiserConfiguration()\n    var loudnessMatch = LoudnessMatchConfiguration()\n',
    'denoiser product state')
text = replace_once(text,
    '        try mainsNotch.validate()\n        try loudnessMatch.validate()\n',
    '        try mainsNotch.validate()\n        try spectralDenoiser.validate(sampleRate: sampleRate)\n        try loudnessMatch.validate()\n',
    'denoiser validation call')
config_anchor = '''        guard N60DynamicsSnapshotSetMainsHumDetector(
            &snapshot,
            sampleRate,
            true,
            mainsNotch.region.fundamentalHz
        ) else { throw DynamicsConfigurationError.invalidMainsHumDetector }
        guard N60DynamicsSnapshotSetLoudnessMatch(
'''
config_repl = '''        guard N60DynamicsSnapshotSetMainsHumDetector(
            &snapshot,
            sampleRate,
            true,
            mainsNotch.region.fundamentalHz
        ) else { throw DynamicsConfigurationError.invalidMainsHumDetector }
        guard N60DynamicsSnapshotSetSpectralDenoiser(
            &snapshot,
            sampleRate,
            spectralDenoiser.enabled,
            spectralDenoiser.algorithmPreset.cType,
            spectralDenoiser.quality.cType,
            Float(spectralDenoiser.reductionAmount),
            Float(spectralDenoiser.thresholdDBFS),
            spectralDenoiser.protectedRangeEnabled,
            Float(spectralDenoiser.protectedLowHz),
            Float(spectralDenoiser.protectedHighHz),
            spectralDenoiser.profileRevision,
            spectralDenoiser.profileCommand.cType
        ) else { throw DynamicsConfigurationError.invalidSpectralDenoiser }
        guard N60DynamicsSnapshotSetLoudnessMatch(
'''
text = replace_once(text, config_anchor, config_repl, 'denoiser snapshot config')
sw.write_text(text)

# -----------------------------------------------------------------------------
# Graph latency accounting.
# -----------------------------------------------------------------------------
sw = Path('NotchSixty/Audio/StereoPlaybackControl.swift')
text = sw.read_text()
old = '''        graph.dynamics = try dynamicsConfiguration.makeSnapshot(sampleRate: sampleRate)
        graph.protection = try dynamicsConfiguration.makeProtectionSnapshot(sampleRate: sampleRate)
        let protectionLatency = UInt64(graph.protection.latencyFrames)
        let totalLatency = UInt64(graph.latencyFrames) + protectionLatency
'''
new = '''        graph.dynamics = try dynamicsConfiguration.makeSnapshot(sampleRate: sampleRate)
        graph.protection = try dynamicsConfiguration.makeProtectionSnapshot(sampleRate: sampleRate)
        let denoiserLatency = graph.dynamics.spectralDenoiser.enabled
            ? UInt64(graph.dynamics.spectralDenoiser.latencyFrames)
            : 0
        let protectionLatency = UInt64(graph.protection.latencyFrames)
        let totalLatency = UInt64(graph.latencyFrames) + denoiserLatency + protectionLatency
'''
text = replace_once(text, old, new, 'denoiser graph latency')
sw.write_text(text)

# -----------------------------------------------------------------------------
# Render kernel: allocate processor, chain after mains/before EQ, telemetry.
# -----------------------------------------------------------------------------
h = Path('NotchSixty/Audio/Realtime/N60RenderKernel.h')
text = h.read_text()
text = replace_once(text,
    '    float mainsDetectedFrequencyHz;\n    float mainsDetectionConfidence;\n    bool deEsserEnabled;\n',
    '    float mainsDetectedFrequencyHz;\n    float mainsDetectionConfidence;\n    bool spectralDenoiserEnabled;\n    N60DenoiserTuning spectralDenoiserTuning;\n    N60DenoiserQuality spectralDenoiserQuality;\n    uint32_t denoiserFFTSize;\n    uint32_t denoiserHopSize;\n    uint32_t denoiserLatencyFrames;\n    bool denoiserProfileReady;\n    bool denoiserCapturedProfile;\n    bool denoiserCaptureActive;\n    float denoiserCaptureProgress;\n    float denoiserEstimatedNoiseDBFS;\n    float denoiserMeanSuppressionDB;\n    float denoiserMaxSuppressionDB;\n    uint64_t denoiserSpectralFramesProcessed;\n    bool deEsserEnabled;\n',
    'denoiser diagnostics fields')
h.write_text(text)

c = Path('NotchSixty/Audio/Realtime/N60RenderKernel.c')
text = c.read_text()
text = replace_once(text,
    '    N60DynamicsRuntime dynamicsRuntime;\n    N60ProtectionRuntime *protectionRuntime;\n',
    '    N60DynamicsRuntime dynamicsRuntime;\n    N60SpectralDenoiserRuntime *denoiserRuntime;\n    N60ProtectionRuntime *protectionRuntime;\n',
    'denoiser runtime pointer')
text = replace_once(text,
    '    _Atomic uint32_t mainsDetectedFrequencyBits;\n    _Atomic uint32_t mainsDetectionConfidenceBits;\n    _Atomic uint32_t deEsserGainReductionBits;\n',
    '    _Atomic uint32_t mainsDetectedFrequencyBits;\n    _Atomic uint32_t mainsDetectionConfidenceBits;\n    _Atomic bool denoiserProfileReady;\n    _Atomic bool denoiserCapturedProfile;\n    _Atomic bool denoiserCaptureActive;\n    _Atomic uint32_t denoiserCaptureProgressBits;\n    _Atomic uint32_t denoiserEstimatedNoiseBits;\n    _Atomic uint32_t denoiserMeanSuppressionBits;\n    _Atomic uint32_t denoiserMaxSuppressionBits;\n    _Atomic uint64_t denoiserSpectralFramesProcessed;\n    _Atomic uint32_t deEsserGainReductionBits;\n',
    'denoiser atomics')
text = replace_once(text,
    '        || !N60DynamicsSnapshotIsValid(snapshot.dynamics)\n        || !N60ProtectionSnapshotIsValid(&snapshot.protection)\n',
    '        || !N60DynamicsSnapshotIsValid(snapshot.dynamics)\n        || !N60SpectralDenoiserSnapshotIsValid(snapshot.dynamics.spectralDenoiser, snapshot.sampleRate)\n        || !N60ProtectionSnapshotIsValid(&snapshot.protection)\n',
    'denoiser graph validity')
create_anchor = '''    kernel->protectionRuntime = N60ProtectionRuntimeCreate();
    if (kernel->protectionRuntime == NULL) {
        N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);
        N60PartitionedConvolverDestroy(kernel->convolver);
        free(kernel);
        return NULL;
    }
    N60DSPGraphSnapshot initial = N60DSPGraphSnapshotMakeUnity(48000.0);
'''
create_repl = '''    kernel->protectionRuntime = N60ProtectionRuntimeCreate();
    if (kernel->protectionRuntime == NULL) {
        N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);
        N60PartitionedConvolverDestroy(kernel->convolver);
        free(kernel);
        return NULL;
    }
    kernel->denoiserRuntime = N60SpectralDenoiserCreate();
    if (kernel->denoiserRuntime == NULL) {
        N60ProtectionRuntimeDestroy(kernel->protectionRuntime);
        N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);
        N60PartitionedConvolverDestroy(kernel->convolver);
        free(kernel);
        return NULL;
    }
    N60DSPGraphSnapshot initial = N60DSPGraphSnapshotMakeUnity(48000.0);
'''
text = replace_once(text, create_anchor, create_repl, 'denoiser allocation')
text = replace_once(text,
    '    if (kernel == NULL) return;\n    N60ProtectionRuntimeDestroy(kernel->protectionRuntime);\n',
    '    if (kernel == NULL) return;\n    N60SpectralDenoiserDestroy(kernel->denoiserRuntime);\n    N60ProtectionRuntimeDestroy(kernel->protectionRuntime);\n',
    'denoiser destroy')
text = replace_once(text,
    '    N60DynamicsRuntimeReset(&kernel->dynamicsRuntime);\n    N60ProtectionRuntimeReset(kernel->protectionRuntime);\n',
    '    N60DynamicsRuntimeReset(&kernel->dynamicsRuntime);\n    N60SpectralDenoiserReset(kernel->denoiserRuntime);\n    N60ProtectionRuntimeReset(kernel->protectionRuntime);\n',
    'denoiser reset')
text = replace_once(text,
    '    atomic_store_explicit(&kernel->roomCorrectionProgramMisses, 0, memory_order_relaxed);\n    atomic_store_explicit(&kernel->inputPeakLeftBits, 0, memory_order_relaxed);\n',
    '    atomic_store_explicit(&kernel->roomCorrectionProgramMisses, 0, memory_order_relaxed);\n    atomic_store_explicit(&kernel->denoiserProfileReady, false, memory_order_relaxed);\n    atomic_store_explicit(&kernel->denoiserCapturedProfile, false, memory_order_relaxed);\n    atomic_store_explicit(&kernel->denoiserCaptureActive, false, memory_order_relaxed);\n    atomic_store_explicit(&kernel->denoiserCaptureProgressBits, 0, memory_order_relaxed);\n    atomic_store_explicit(&kernel->denoiserEstimatedNoiseBits, float_to_bits(-120.0f), memory_order_relaxed);\n    atomic_store_explicit(&kernel->denoiserMeanSuppressionBits, 0, memory_order_relaxed);\n    atomic_store_explicit(&kernel->denoiserMaxSuppressionBits, 0, memory_order_relaxed);\n    atomic_store_explicit(&kernel->denoiserSpectralFramesProcessed, 0, memory_order_relaxed);\n    atomic_store_explicit(&kernel->inputPeakLeftBits, 0, memory_order_relaxed);\n',
    'denoiser reset atomics')
process_anchor = '''        N60DynamicsProcessPreEQStereoFrame(&kernel->dynamicsRuntime, context->snapshot.dynamics, &left, &right);

        if (!context->snapshot.eqBypassed) {
'''
process_repl = '''        N60DynamicsProcessPreEQStereoFrame(&kernel->dynamicsRuntime, context->snapshot.dynamics, &left, &right);

        N60SpectralDenoiserProcessStereoFrame(
            kernel->denoiserRuntime,
            context->snapshot.dynamics.spectralDenoiser,
            context->snapshot.sampleRate,
            left,
            right,
            &left,
            &right
        );

        if (!context->snapshot.eqBypassed) {
'''
text = replace_once(text, process_anchor, process_repl, 'denoiser graph position')
telemetry_anchor = '''        N60DynamicsTelemetry telemetry = N60DynamicsRuntimeTelemetry(&kernel->dynamicsRuntime);
        atomic_store_explicit(&kernel->mainsDetectedFrequencyBits, float_to_bits(telemetry.mainsDetectedFrequencyHz), memory_order_relaxed);
        atomic_store_explicit(&kernel->mainsDetectionConfidenceBits, float_to_bits(telemetry.mainsDetectionConfidence), memory_order_relaxed);
'''
telemetry_repl = telemetry_anchor + '''        N60SpectralDenoiserTelemetry denoiser = N60SpectralDenoiserRuntimeTelemetry(kernel->denoiserRuntime);
        atomic_store_explicit(&kernel->denoiserProfileReady, denoiser.profileReady, memory_order_relaxed);
        atomic_store_explicit(&kernel->denoiserCapturedProfile, denoiser.capturedProfile, memory_order_relaxed);
        atomic_store_explicit(&kernel->denoiserCaptureActive, denoiser.captureActive, memory_order_relaxed);
        atomic_store_explicit(&kernel->denoiserCaptureProgressBits, float_to_bits(denoiser.captureProgress), memory_order_relaxed);
        atomic_store_explicit(&kernel->denoiserEstimatedNoiseBits, float_to_bits(denoiser.estimatedNoiseDBFS), memory_order_relaxed);
        atomic_store_explicit(&kernel->denoiserMeanSuppressionBits, float_to_bits(denoiser.meanSuppressionDB), memory_order_relaxed);
        atomic_store_explicit(&kernel->denoiserMaxSuppressionBits, float_to_bits(denoiser.maxSuppressionDB), memory_order_relaxed);
        atomic_store_explicit(&kernel->denoiserSpectralFramesProcessed, denoiser.spectralFramesProcessed, memory_order_relaxed);
'''
text = replace_once(text, telemetry_anchor, telemetry_repl, 'denoiser telemetry publish')
context_diag_anchor = '''        diagnostics.mainsDetectedFrequencyHz = bits_to_float(atomic_load_explicit(&kernel->mainsDetectedFrequencyBits, memory_order_relaxed));
        diagnostics.mainsDetectionConfidence = bits_to_float(atomic_load_explicit(&kernel->mainsDetectionConfidenceBits, memory_order_relaxed));
        diagnostics.deEsserEnabled = context.snapshot.dynamics.deEsser.enabled;
'''
context_diag_repl = '''        diagnostics.mainsDetectedFrequencyHz = bits_to_float(atomic_load_explicit(&kernel->mainsDetectedFrequencyBits, memory_order_relaxed));
        diagnostics.mainsDetectionConfidence = bits_to_float(atomic_load_explicit(&kernel->mainsDetectionConfidenceBits, memory_order_relaxed));
        diagnostics.spectralDenoiserEnabled = context.snapshot.dynamics.spectralDenoiser.enabled;
        diagnostics.spectralDenoiserTuning = context.snapshot.dynamics.spectralDenoiser.tuning;
        diagnostics.spectralDenoiserQuality = context.snapshot.dynamics.spectralDenoiser.quality;
        diagnostics.denoiserFFTSize = context.snapshot.dynamics.spectralDenoiser.fftSize;
        diagnostics.denoiserHopSize = context.snapshot.dynamics.spectralDenoiser.hopSize;
        diagnostics.denoiserLatencyFrames = context.snapshot.dynamics.spectralDenoiser.enabled
            ? context.snapshot.dynamics.spectralDenoiser.latencyFrames : 0;
        diagnostics.deEsserEnabled = context.snapshot.dynamics.deEsser.enabled;
'''
text = replace_once(text, context_diag_anchor, context_diag_repl, 'denoiser configured diagnostics')
load_anchor = '''    diagnostics.mainsDetectedFrequencyHz = bits_to_float(atomic_load_explicit(&kernel->mainsDetectedFrequencyBits, memory_order_relaxed));
    diagnostics.mainsDetectionConfidence = bits_to_float(atomic_load_explicit(&kernel->mainsDetectionConfidenceBits, memory_order_relaxed));
    diagnostics.deEsserGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->deEsserGainReductionBits, memory_order_relaxed));
'''
load_repl = '''    diagnostics.mainsDetectedFrequencyHz = bits_to_float(atomic_load_explicit(&kernel->mainsDetectedFrequencyBits, memory_order_relaxed));
    diagnostics.mainsDetectionConfidence = bits_to_float(atomic_load_explicit(&kernel->mainsDetectionConfidenceBits, memory_order_relaxed));
    diagnostics.denoiserProfileReady = atomic_load_explicit(&kernel->denoiserProfileReady, memory_order_relaxed);
    diagnostics.denoiserCapturedProfile = atomic_load_explicit(&kernel->denoiserCapturedProfile, memory_order_relaxed);
    diagnostics.denoiserCaptureActive = atomic_load_explicit(&kernel->denoiserCaptureActive, memory_order_relaxed);
    diagnostics.denoiserCaptureProgress = bits_to_float(atomic_load_explicit(&kernel->denoiserCaptureProgressBits, memory_order_relaxed));
    diagnostics.denoiserEstimatedNoiseDBFS = bits_to_float(atomic_load_explicit(&kernel->denoiserEstimatedNoiseBits, memory_order_relaxed));
    diagnostics.denoiserMeanSuppressionDB = bits_to_float(atomic_load_explicit(&kernel->denoiserMeanSuppressionBits, memory_order_relaxed));
    diagnostics.denoiserMaxSuppressionDB = bits_to_float(atomic_load_explicit(&kernel->denoiserMaxSuppressionBits, memory_order_relaxed));
    diagnostics.denoiserSpectralFramesProcessed = atomic_load_explicit(&kernel->denoiserSpectralFramesProcessed, memory_order_relaxed);
    diagnostics.deEsserGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->deEsserGainReductionBits, memory_order_relaxed));
'''
text = replace_once(text, load_anchor, load_repl, 'denoiser telemetry diagnostics')
c.write_text(text)

# -----------------------------------------------------------------------------
# Swift diagnostics bridge.
# -----------------------------------------------------------------------------
sw = Path('NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift')
text = sw.read_text()
text = replace_once(text,
    '    let mainsDetectedFrequencyHz: Float\n    let mainsDetectionConfidence: Float\n    let deEsserEnabled: Bool\n',
    '    let mainsDetectedFrequencyHz: Float\n    let mainsDetectionConfidence: Float\n    let spectralDenoiserEnabled: Bool\n    let spectralDenoiserTuning: N60DenoiserTuning\n    let spectralDenoiserQuality: N60DenoiserQuality\n    let denoiserFFTSize: UInt32\n    let denoiserHopSize: UInt32\n    let denoiserLatencyFrames: UInt32\n    let denoiserProfileReady: Bool\n    let denoiserCapturedProfile: Bool\n    let denoiserCaptureActive: Bool\n    let denoiserCaptureProgress: Float\n    let denoiserEstimatedNoiseDBFS: Float\n    let denoiserMeanSuppressionDB: Float\n    let denoiserMaxSuppressionDB: Float\n    let denoiserSpectralFramesProcessed: UInt64\n    let deEsserEnabled: Bool\n',
    'Swift denoiser diagnostics fields')
text = replace_once(text,
    '        mainsDetectedFrequencyHz = diagnostics.mainsDetectedFrequencyHz\n        mainsDetectionConfidence = diagnostics.mainsDetectionConfidence\n        deEsserEnabled = diagnostics.deEsserEnabled\n',
    '        mainsDetectedFrequencyHz = diagnostics.mainsDetectedFrequencyHz\n        mainsDetectionConfidence = diagnostics.mainsDetectionConfidence\n        spectralDenoiserEnabled = diagnostics.spectralDenoiserEnabled\n        spectralDenoiserTuning = diagnostics.spectralDenoiserTuning\n        spectralDenoiserQuality = diagnostics.spectralDenoiserQuality\n        denoiserFFTSize = diagnostics.denoiserFFTSize\n        denoiserHopSize = diagnostics.denoiserHopSize\n        denoiserLatencyFrames = diagnostics.denoiserLatencyFrames\n        denoiserProfileReady = diagnostics.denoiserProfileReady\n        denoiserCapturedProfile = diagnostics.denoiserCapturedProfile\n        denoiserCaptureActive = diagnostics.denoiserCaptureActive\n        denoiserCaptureProgress = diagnostics.denoiserCaptureProgress\n        denoiserEstimatedNoiseDBFS = diagnostics.denoiserEstimatedNoiseDBFS\n        denoiserMeanSuppressionDB = diagnostics.denoiserMeanSuppressionDB\n        denoiserMaxSuppressionDB = diagnostics.denoiserMaxSuppressionDB\n        denoiserSpectralFramesProcessed = diagnostics.denoiserSpectralFramesProcessed\n        deEsserEnabled = diagnostics.deEsserEnabled\n',
    'Swift denoiser diagnostics init')
sw.write_text(text)

# -----------------------------------------------------------------------------
# Audio engine profile commands and structural graph transitions.
# -----------------------------------------------------------------------------
sw = Path('NotchSixty/Audio/AudioIOEngine.swift')
text = sw.read_text()
insert_anchor = '''    func replaceDynamicsConfiguration(_ configuration: DynamicsConfiguration) throws {
'''
methods = '''    func applySpectralDenoiserPreset(_ preset: SpectralDenoiserPreset) throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.applyPreset(preset)
        try replaceDynamicsConfiguration(updated)
    }

    func captureSpectralNoiseProfile() throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.requestProfileCapture()
        try replaceDynamicsConfiguration(updated)
    }

    func resetSpectralNoiseProfile() throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.resetProfile()
        try replaceDynamicsConfiguration(updated)
    }

''' + insert_anchor
text = replace_once(text, insert_anchor, methods, 'denoiser engine controls')
old = '''            let protectionStructureChanged = oldProtection.latencyFrames != newProtection.latencyFrames
                || oldProtection.effectiveFactor != newProtection.effectiveFactor
                || oldProtection.limiterEnabled != newProtection.limiterEnabled
                || dynamicsConfiguration.softClipper.enabled != configuration.softClipper.enabled
            if protectionStructureChanged {
'''
new = '''            let protectionStructureChanged = oldProtection.latencyFrames != newProtection.latencyFrames
                || oldProtection.effectiveFactor != newProtection.effectiveFactor
                || oldProtection.limiterEnabled != newProtection.limiterEnabled
                || dynamicsConfiguration.softClipper.enabled != configuration.softClipper.enabled
            let denoiserStructureChanged = dynamicsConfiguration.spectralDenoiser.enabled != configuration.spectralDenoiser.enabled
                || dynamicsConfiguration.spectralDenoiser.quality != configuration.spectralDenoiser.quality
            if protectionStructureChanged || denoiserStructureChanged {
'''
text = replace_once(text, old, new, 'denoiser structural transition')
sw.write_text(text)

# -----------------------------------------------------------------------------
# Graph-integrated tests: latency, reconstruction/Reference alignment, boundedness.
# -----------------------------------------------------------------------------
tests = Path('NotchSixtyTests/NotchSixtyTests.swift')
text = tests.read_text()
append = r'''

extension NotchSixtyTests {
    func testSpectralDenoiserGraphLatencyTracksQualityOnlyWhenEnabled() throws {
        for (quality, expected) in [
            (SpectralDenoiserQuality.quality, UInt32(1024)),
            (.high, UInt32(2048)),
            (.ultra, UInt32(4096)),
        ] {
            var dynamics = DynamicsConfiguration()
            dynamics.spectralDenoiser.enabled = true
            dynamics.spectralDenoiser.quality = quality
            let graph = try StereoEQConfiguration().makeGraphSnapshot(
                sampleRate: 96_000,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: BassManagementConfiguration(),
                dynamicsConfiguration: dynamics,
                playbackConfiguration: PlaybackControlConfiguration()
            )
            XCTAssertEqual(graph.latencyFrames, expected)
            XCTAssertEqual(graph.dynamics.spectralDenoiser.latencyFrames, expected)

            dynamics.spectralDenoiser.enabled = false
            let bypassed = try StereoEQConfiguration().makeGraphSnapshot(
                sampleRate: 96_000,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: BassManagementConfiguration(),
                dynamicsConfiguration: dynamics,
                playbackConfiguration: PlaybackControlConfiguration()
            )
            XCTAssertEqual(bypassed.latencyFrames, 0)
        }
    }

    func testSpectralDenoiserGraphUnityBeforeProfileReadyMatchesLatencyReference() throws {
        guard let processedKernel = N60RenderKernelCreate(), let referenceKernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernels")
            return
        }
        defer {
            N60RenderKernelDestroy(processedKernel)
            N60RenderKernelDestroy(referenceKernel)
        }

        var dynamics = DynamicsConfiguration()
        dynamics.spectralDenoiser.enabled = true
        dynamics.spectralDenoiser.quality = .quality
        dynamics.spectralDenoiser.thresholdDBFS = -72
        let processedGraph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: dynamics,
            playbackConfiguration: PlaybackControlConfiguration(auditionMode: .processed)
        )
        let referenceGraph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 48_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: dynamics,
            playbackConfiguration: PlaybackControlConfiguration(auditionMode: .reference)
        )
        XCTAssertTrue(N60RenderKernelPublishSnapshot(processedKernel, processedGraph))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(referenceKernel, referenceGraph))

        let totalFrames = 22_000
        var squaredError = 0.0
        var squaredReference = 0.0
        var measured = 0
        for frame in 0..<totalFrames {
            let source = Float(0.25 * sin(2.0 * Double.pi * 997.0 * Double(frame) / 48_000.0))
            var processedLeft: Float = 0
            var processedRight: Float = 0
            var referenceLeft: Float = 0
            var referenceRight: Float = 0
            N60RenderKernelProcessStereoFrame(processedKernel, source, source * 0.7, &processedLeft, &processedRight)
            N60RenderKernelProcessStereoFrame(referenceKernel, source, source * 0.7, &referenceLeft, &referenceRight)
            if frame > Int(processedGraph.latencyFrames + processedGraph.dynamics.spectralDenoiser.hopSize + 256) {
                let error = Double(processedLeft - referenceLeft)
                squaredError += error * error
                squaredReference += Double(referenceLeft * referenceLeft)
                measured += 1
            }
        }
        XCTAssertGreaterThan(measured, 1000)
        let normalizedError = sqrt(squaredError / max(squaredReference, 1.0e-20))
        XCTAssertLessThan(normalizedError, 0.0025, "WOLA unity path should track latency-matched Reference before adaptive profile becomes active")
    }

    func testSpectralDenoiserGraphStaysFiniteAt384k() throws {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }
        var dynamics = DynamicsConfiguration()
        dynamics.spectralDenoiser.enabled = true
        dynamics.spectralDenoiser.quality = .ultra
        dynamics.spectralDenoiser.applyPreset(.natural)
        let graph = try StereoEQConfiguration().makeGraphSnapshot(
            sampleRate: 384_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: dynamics,
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        var state: UInt32 = 0xCAFEBABE
        var maxMagnitude: Float = 0
        for _ in 0..<30_000 {
            state = state &* 1_664_525 &+ 1_013_904_223
            let sample = (Float(state & 0xFFFF) / 32_767.5 - 1) * 0.1
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, -sample * 0.8, &left, &right)
            XCTAssertTrue(left.isFinite)
            XCTAssertTrue(right.isFinite)
            maxMagnitude = max(maxMagnitude, abs(left), abs(right))
        }
        XCTAssertLessThan(maxMagnitude, 1.0)
        XCTAssertEqual(N60RenderKernelGetDiagnostics(kernel).denoiserLatencyFrames, 4096)
    }
}
'''
if 'testSpectralDenoiserGraphLatencyTracksQualityOnlyWhenEnabled' not in text:
    text += append
tests.write_text(text)
