from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# Prepared-coefficient publication API. This is a control-plane path used by
# Linkwitz Transform now and by the compiled multi-section EQ program next.
header_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
header = header_path.read_text()
declarations = '''bool N60DSPGraphSnapshotSetEQPreparedBandForChannels(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t bandIndex,
    uint8_t channelMask,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients coefficients,
    bool enabled
);
bool N60DSPGraphSnapshotSetEQPreparedBand(
    N60DSPGraphSnapshot * _Nonnull snapshot,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients coefficients,
    bool enabled
);
'''
if declarations not in header:
    marker = '''bool N60DSPGraphSnapshotSetCrossover(
'''
    if marker not in header:
        raise SystemExit("Expected prepared-EQ declaration insertion point was not found")
    header = header.replace(marker, declarations + marker, 1)
header_path.write_text(header)

source_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
source = source_path.read_text()
functions = '''bool N60DSPGraphSnapshotSetEQPreparedBandForChannels(
    N60DSPGraphSnapshot *snapshot,
    uint32_t bandIndex,
    uint8_t channelMask,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients coefficients,
    bool enabled
) {
    if (snapshot == NULL || bandIndex >= N60_MAX_EQ_RENDER_SLOTS) return false;
    if (enabled && !channel_mask_is_valid(channelMask)) return false;
    if (enabled && (!isfinite(frequencyHz) || frequencyHz <= 0.0
        || frequencyHz >= snapshot->sampleRate * 0.5
        || !isfinite(gainDB)
        || !isfinite(q) || q <= 0.0
        || !N60BiquadCoefficientsAreFinite(coefficients))) {
        return false;
    }

    N60BiquadBandSnapshot band = {0};
    band.enabled = enabled;
    band.type = type;
    band.frequencyHz = frequencyHz;
    band.gainDB = gainDB;
    band.q = q;
    band.coefficients = enabled ? coefficients : N60BiquadCoefficientsMakeIdentity();
    snapshot->eqBands[bandIndex] = band;
    snapshot->eqBandChannelMasks[bandIndex] = enabled ? channelMask : 0;
    if (snapshot->eqBandCount <= bandIndex) snapshot->eqBandCount = bandIndex + 1;
    return true;
}

bool N60DSPGraphSnapshotSetEQPreparedBand(
    N60DSPGraphSnapshot *snapshot,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients coefficients,
    bool enabled
) {
    return N60DSPGraphSnapshotSetEQPreparedBandForChannels(
        snapshot, bandIndex, N60_EQ_CHANNEL_STEREO, type,
        frequencyHz, gainDB, q, coefficients, enabled
    );
}

'''
if functions not in source:
    marker = '''bool N60DSPGraphSnapshotSetEQBandForChannels(
'''
    if marker not in source:
        raise SystemExit("Expected prepared-EQ implementation insertion point was not found")
    source = source.replace(marker, functions + marker, 1)
source_path.write_text(source)

# Linear-phase magnitude projection can consume an already-designed, immutable
# control-plane biquad. This keeps Linkwitz's four physical parameters out of the
# realtime representation and reuses exactly the same transfer function.
linear_path = Path("NotchSixty/Audio/Realtime/N60LinearPhaseEQ.h")
linear = linear_path.read_text()
linear = replace_once(
    linear,
    '''    double gainDB;
    double q;
} N60LinearPhaseEQBand;''',
    '''    double gainDB;
    double q;
    bool usesPreparedCoefficients;
    N60BiquadCoefficients preparedCoefficients;
} N60LinearPhaseEQBand;''',
    "Linear-Phase prepared fields",
)
old = '''        N60BiquadBandSnapshot snapshot = {0};
        if (!N60BiquadBandSnapshotMake(
                bands[index].type,
                sampleRate,
                bands[index].frequencyHz,
                bands[index].gainDB,
                bands[index].q,
                true,
                &snapshot)) {
            return false;
        }
        designedBands[designedCount++] = snapshot;
'''
new = '''        N60BiquadBandSnapshot snapshot = {0};
        if (bands[index].usesPreparedCoefficients) {
            if (!isfinite(bands[index].frequencyHz) || bands[index].frequencyHz <= 0.0
                || bands[index].frequencyHz >= sampleRate * 0.5
                || !isfinite(bands[index].gainDB)
                || !isfinite(bands[index].q) || bands[index].q <= 0.0
                || !N60BiquadCoefficientsAreFinite(bands[index].preparedCoefficients)) {
                return false;
            }
            snapshot.enabled = true;
            snapshot.type = bands[index].type;
            snapshot.frequencyHz = bands[index].frequencyHz;
            snapshot.gainDB = bands[index].gainDB;
            snapshot.q = bands[index].q;
            snapshot.coefficients = bands[index].preparedCoefficients;
        } else if (!N60BiquadBandSnapshotMake(
                bands[index].type,
                sampleRate,
                bands[index].frequencyHz,
                bands[index].gainDB,
                bands[index].q,
                true,
                &snapshot)) {
            return false;
        }
        designedBands[designedCount++] = snapshot;
'''
linear = replace_once(linear, old, new, "Linear-Phase prepared branch")
linear_path.write_text(linear)

print("PR34 Phase A core integration applied/verified.")
