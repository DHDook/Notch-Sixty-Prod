from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"pattern not found in {path}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))

# ---- C interface ---------------------------------------------------------
h = "NotchSixty/Audio/Realtime/N60Dynamics.h"
replace_once(h,
'''typedef struct {
    bool enabled;
    float thresholdDB;
    float ratio;
    float kneeWidthDB;
    float makeupGainDB;
    float attackCoefficient;
    float releaseCoefficient;
} N60CompressorSnapshot;
''',
'''typedef enum {
    N60CompressorTopologyFeedForward = 0,
    N60CompressorTopologyFeedBack = 1,
} N60CompressorTopology;

typedef struct {
    bool enabled;
    N60CompressorTopology topology;
    bool programDependentRelease;
    float thresholdDB;
    float ratio;
    float kneeWidthDB;
    float makeupGainDB;
    float attackCoefficient;
    float releaseCoefficient;
    float releaseFastCoefficient;
    float releaseSlowCoefficient;
    N60BiquadCoefficients sidechainHighPass;
} N60CompressorSnapshot;
''')

replace_once(h,
'''typedef struct {
    bool enabled;
    bool dynamicEQMode;
    double frequencyHz;
    float thresholdDB;
    float ratio;
    float attackCoefficient;
    float releaseCoefficient;
    N60BiquadCoefficients sidechainHighPass;
    N60BiquadCoefficients sidechainLowPass;
} N60DeEsserSnapshot;
''',
'''typedef struct {
    bool enabled;
    bool dynamicEQMode;
    double frequencyHz;
    float thresholdDB;
    float ratio;
    float rangeDB;
    float detectionQ;
    float attackCoefficient;
    float releaseCoefficient;
    N60BiquadCoefficients sidechainHighPass;
    N60BiquadCoefficients sidechainLowPass;
} N60DeEsserSnapshot;
''')

replace_once(h,
'''typedef struct {
    bool enabled;
    double lowMidFrequencyHz;
    double midHighFrequencyHz;
    N60CrossoverTopology topology;
    uint32_t sectionCount;
    float thresholdDB[N60_MULTIBAND_BAND_COUNT];
    float ratio;
    float kneeWidthDB;
    float attackCoefficient;
    float releaseCoefficient;
    N60BiquadCoefficients lowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients highPass[N60_MAX_CROSSOVER_SECTIONS];
} N60MultibandCompressorSnapshot;
''',
'''typedef struct {
    bool enabled;
    double lowMidFrequencyHz;
    double midHighFrequencyHz;
    N60CrossoverTopology lowTopology;
    N60CrossoverTopology highTopology;
    uint32_t lowSectionCount;
    uint32_t highSectionCount;
    float thresholdDB[N60_MULTIBAND_BAND_COUNT];
    float ratio[N60_MULTIBAND_BAND_COUNT];
    float kneeWidthDB[N60_MULTIBAND_BAND_COUNT];
    float makeupGainDB[N60_MULTIBAND_BAND_COUNT];
    float attackCoefficient[N60_MULTIBAND_BAND_COUNT];
    float releaseCoefficient[N60_MULTIBAND_BAND_COUNT];
    N60BiquadCoefficients sidechainHighPass[N60_MULTIBAND_BAND_COUNT];
    N60BiquadCoefficients lowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients highPass[N60_MAX_CROSSOVER_SECTIONS];
} N60MultibandCompressorSnapshot;
''')

replace_once(h,
'''    N60BiquadState deEsserLowPassLeft;
    N60BiquadState deEsserLowPassRight;
    float multibandGainDB[N60_MULTIBAND_BAND_COUNT];
    N60BiquadState multibandLowPassLeft[N60_MAX_CROSSOVER_SECTIONS];
''',
'''    N60BiquadState deEsserLowPassLeft;
    N60BiquadState deEsserLowPassRight;
    float multibandGainDB[N60_MULTIBAND_BAND_COUNT];
    N60BiquadState multibandSidechainLeft[N60_MULTIBAND_BAND_COUNT];
    N60BiquadState multibandSidechainRight[N60_MULTIBAND_BAND_COUNT];
    N60BiquadState multibandLowPassLeft[N60_MAX_CROSSOVER_SECTIONS];
''')
replace_once(h,
'''    N60BiquadState multibandHighPassLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState multibandHighPassRight[N60_MAX_CROSSOVER_SECTIONS];
    float compressorGainDB;
''',
'''    N60BiquadState multibandHighPassLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState multibandHighPassRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState compressorSidechainLeft;
    N60BiquadState compressorSidechainRight;
    float compressorGainDB;
''')

# Add advanced API prototypes while retaining backward-compatible setters.
replace_once(h,
'''bool N60DynamicsSnapshotSetDeEsser(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double frequencyHz,
    float thresholdDB,
    bool dynamicEQMode
);
''',
'''bool N60DynamicsSnapshotSetDeEsser(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double frequencyHz,
    float thresholdDB,
    bool dynamicEQMode
);

bool N60DynamicsSnapshotSetDeEsserAdvanced(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double frequencyHz,
    float thresholdDB,
    float ratio,
    float rangeDB,
    float detectionQ,
    float attackMs,
    float releaseMs,
    bool dynamicEQMode
);
''')

replace_once(h,
'''bool N60DynamicsSnapshotSetMultibandCompressor(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    N60CrossoverTopology topology,
    float lowThresholdDB,
    float midThresholdDB,
    float highThresholdDB
);
''',
'''bool N60DynamicsSnapshotSetMultibandCompressor(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    N60CrossoverTopology topology,
    float lowThresholdDB,
    float midThresholdDB,
    float highThresholdDB
);

bool N60DynamicsSnapshotSetMultibandCompressorAdvanced(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    N60CrossoverTopology lowTopology,
    N60CrossoverTopology highTopology,
    float lowThresholdDB,
    float midThresholdDB,
    float highThresholdDB,
    float lowRatio,
    float midRatio,
    float highRatio,
    float lowAttackMs,
    float midAttackMs,
    float highAttackMs,
    float lowReleaseMs,
    float midReleaseMs,
    float highReleaseMs,
    float lowKneeDB,
    float midKneeDB,
    float highKneeDB,
    float lowSidechainHPFHz,
    float midSidechainHPFHz,
    float highSidechainHPFHz,
    float lowMakeupDB,
    float midMakeupDB,
    float highMakeupDB
);
''')

replace_once(h,
'''bool N60DynamicsSnapshotSetCompressor(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDB,
    float ratio,
    float kneeWidthDB,
    float attackMs,
    float releaseMs,
    float makeupGainDB
);
''',
'''bool N60DynamicsSnapshotSetCompressor(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDB,
    float ratio,
    float kneeWidthDB,
    float attackMs,
    float releaseMs,
    float makeupGainDB
);

bool N60DynamicsSnapshotSetCompressorAdvanced(
    N60DynamicsSnapshot * _Nonnull snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDB,
    float ratio,
    float kneeWidthDB,
    float attackMs,
    float releaseMs,
    float makeupGainDB,
    N60CompressorTopology topology,
    bool programDependentRelease,
    float sidechainHighPassHz
);
''')

# ---- C implementation ----------------------------------------------------
c = "NotchSixty/Audio/Realtime/N60Dynamics.c"
# Defaults: preserve accepted commercial behavior, but populate new fields.
replace_once(c,
'''    snapshot.deEsser.thresholdDB = -24.0f;
    snapshot.deEsser.ratio = N60_DEESSER_RATIO;
    snapshot.deEsser.attackCoefficient = coefficient_for_time_ms(sampleRate, N60_DEESSER_ATTACK_MS);
''',
'''    snapshot.deEsser.thresholdDB = -24.0f;
    snapshot.deEsser.ratio = N60_DEESSER_RATIO;
    snapshot.deEsser.rangeDB = -24.0f;
    snapshot.deEsser.detectionQ = 2.0f;
    snapshot.deEsser.attackCoefficient = coefficient_for_time_ms(sampleRate, N60_DEESSER_ATTACK_MS);
''')
replace_once(c,
'''    snapshot.multibandCompressor.topology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.multibandCompressor.sectionCount = 0;
    snapshot.multibandCompressor.thresholdDB[0] = -18.0f;
    snapshot.multibandCompressor.thresholdDB[1] = -18.0f;
    snapshot.multibandCompressor.thresholdDB[2] = -18.0f;
    snapshot.multibandCompressor.ratio = N60_MULTIBAND_RATIO;
    snapshot.multibandCompressor.kneeWidthDB = N60_MULTIBAND_KNEE_DB;
    snapshot.multibandCompressor.attackCoefficient = coefficient_for_time_ms(sampleRate, N60_MULTIBAND_ATTACK_MS);
    snapshot.multibandCompressor.releaseCoefficient = coefficient_for_time_ms(sampleRate, N60_MULTIBAND_RELEASE_MS);
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
''',
'''    snapshot.multibandCompressor.lowTopology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.multibandCompressor.highTopology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.multibandCompressor.lowSectionCount = 0;
    snapshot.multibandCompressor.highSectionCount = 0;
    for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) {
        snapshot.multibandCompressor.thresholdDB[band] = -18.0f;
        snapshot.multibandCompressor.ratio[band] = N60_MULTIBAND_RATIO;
        snapshot.multibandCompressor.kneeWidthDB[band] = N60_MULTIBAND_KNEE_DB;
        snapshot.multibandCompressor.makeupGainDB[band] = 0.0f;
        snapshot.multibandCompressor.attackCoefficient[band] = coefficient_for_time_ms(sampleRate, N60_MULTIBAND_ATTACK_MS);
        snapshot.multibandCompressor.releaseCoefficient[band] = coefficient_for_time_ms(sampleRate, N60_MULTIBAND_RELEASE_MS);
        snapshot.multibandCompressor.sidechainHighPass[band] = N60BiquadCoefficientsMakeIdentity();
    }
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
''')
replace_once(c,
'''    snapshot.compressor.enabled = false;
    snapshot.compressor.ratio = 1.0f;
    snapshot.compressor.attackCoefficient = coefficient_for_time_ms(sampleRate, 10.0f);
    snapshot.compressor.releaseCoefficient = coefficient_for_time_ms(sampleRate, 100.0f);
''',
'''    snapshot.compressor.enabled = false;
    snapshot.compressor.topology = N60CompressorTopologyFeedForward;
    snapshot.compressor.programDependentRelease = false;
    snapshot.compressor.ratio = 1.0f;
    snapshot.compressor.attackCoefficient = coefficient_for_time_ms(sampleRate, 10.0f);
    snapshot.compressor.releaseCoefficient = coefficient_for_time_ms(sampleRate, 100.0f);
    snapshot.compressor.releaseFastCoefficient = coefficient_for_time_ms(sampleRate, 50.0f);
    snapshot.compressor.releaseSlowCoefficient = coefficient_for_time_ms(sampleRate, 200.0f);
    snapshot.compressor.sidechainHighPass = N60BiquadCoefficientsMakeIdentity();
''')

# Replace de-esser setter with compatibility wrapper + advanced setter.
start = '''bool N60DynamicsSnapshotSetDeEsser(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double frequencyHz,
    float thresholdDB,
    bool dynamicEQMode
) {'''
idx = Path(c).read_text().find(start)
if idx < 0: raise SystemExit("deesser setter start not found")
text = Path(c).read_text()
end = text.find('\n}\n\nbool N60DynamicsSnapshotSetMultibandCompressor(', idx)
if end < 0: raise SystemExit("deesser setter end not found")
old = text[idx:end+3]
new = r'''bool N60DynamicsSnapshotSetDeEsser(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double frequencyHz,
    float thresholdDB,
    bool dynamicEQMode
) {
    return N60DynamicsSnapshotSetDeEsserAdvanced(
        snapshot, sampleRate, enabled, frequencyHz, thresholdDB,
        N60_DEESSER_RATIO, -24.0f, 2.0f,
        N60_DEESSER_ATTACK_MS, N60_DEESSER_RELEASE_MS, dynamicEQMode
    );
}

bool N60DynamicsSnapshotSetDeEsserAdvanced(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double frequencyHz,
    float thresholdDB,
    float ratio,
    float rangeDB,
    float detectionQ,
    float attackMs,
    float releaseMs,
    bool dynamicEQMode
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz < 2000.0 || frequencyHz > 10000.0
        || frequencyHz >= sampleRate * 0.45
        || !isfinite(thresholdDB) || thresholdDB < -60.0f || thresholdDB > 0.0f
        || !isfinite(ratio) || ratio < 1.0f || ratio > 20.0f
        || !isfinite(rangeDB) || rangeDB < -24.0f || rangeDB > 0.0f
        || !isfinite(detectionQ) || detectionQ < 0.5f || detectionQ > 8.0f
        || !isfinite(attackMs) || attackMs < 0.1f || attackMs > 100.0f
        || !isfinite(releaseMs) || releaseMs < 10.0f || releaseMs > 1000.0f) {
        return false;
    }

    // Detection-Q is expressed as inverse octave half-bandwidth. Q=2.0 yields
    // the accepted PR28 band (centre / sqrt(2) ... centre * sqrt(2)).
    double octaveHalfWidth = 1.0 / (double)detectionQ;
    double lowerFrequency = frequencyHz * pow(2.0, -octaveHalfWidth);
    double upperFrequency = frequencyHz * pow(2.0, octaveHalfWidth);
    upperFrequency = fmin(upperFrequency, sampleRate * 0.45);
    if (lowerFrequency <= 0.0 || upperFrequency <= lowerFrequency) return false;

    N60DeEsserSnapshot configured = {0};
    configured.enabled = enabled;
    configured.dynamicEQMode = dynamicEQMode;
    configured.frequencyHz = frequencyHz;
    configured.thresholdDB = thresholdDB;
    configured.ratio = ratio;
    configured.rangeDB = rangeDB;
    configured.detectionQ = detectionQ;
    configured.attackCoefficient = coefficient_for_time_ms(sampleRate, attackMs);
    configured.releaseCoefficient = coefficient_for_time_ms(sampleRate, releaseMs);
    if (!valid_coefficient(configured.attackCoefficient)
        || !valid_coefficient(configured.releaseCoefficient)
        || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, lowerFrequency, 0.0, 0.7071067811865476, &configured.sidechainHighPass)
        || !N60BiquadDesign(N60BiquadFilterTypeLowPass, sampleRate, upperFrequency, 0.0, 0.7071067811865476, &configured.sidechainLowPass)) {
        return false;
    }
    snapshot->deEsser = configured;
    return true;
}
'''
Path(c).write_text(text[:idx] + new + text[end+3:])

# Replace multiband setter similarly.
text = Path(c).read_text()
start = 'bool N60DynamicsSnapshotSetMultibandCompressor(\n'
idx = text.find(start)
end = text.find('\n}\n\nbool N60DynamicsSnapshotSetCompressor(', idx)
if idx < 0 or end < 0: raise SystemExit("multiband setter boundaries not found")
new = r'''bool N60DynamicsSnapshotSetMultibandCompressor(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    N60CrossoverTopology topology,
    float lowThresholdDB,
    float midThresholdDB,
    float highThresholdDB
) {
    return N60DynamicsSnapshotSetMultibandCompressorAdvanced(
        snapshot, sampleRate, enabled, lowMidFrequencyHz, midHighFrequencyHz,
        topology, topology,
        lowThresholdDB, midThresholdDB, highThresholdDB,
        N60_MULTIBAND_RATIO, N60_MULTIBAND_RATIO, N60_MULTIBAND_RATIO,
        N60_MULTIBAND_ATTACK_MS, N60_MULTIBAND_ATTACK_MS, N60_MULTIBAND_ATTACK_MS,
        N60_MULTIBAND_RELEASE_MS, N60_MULTIBAND_RELEASE_MS, N60_MULTIBAND_RELEASE_MS,
        N60_MULTIBAND_KNEE_DB, N60_MULTIBAND_KNEE_DB, N60_MULTIBAND_KNEE_DB,
        0.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 0.0f
    );
}

bool N60DynamicsSnapshotSetMultibandCompressorAdvanced(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    double lowMidFrequencyHz,
    double midHighFrequencyHz,
    N60CrossoverTopology lowTopology,
    N60CrossoverTopology highTopology,
    float lowThresholdDB,
    float midThresholdDB,
    float highThresholdDB,
    float lowRatio,
    float midRatio,
    float highRatio,
    float lowAttackMs,
    float midAttackMs,
    float highAttackMs,
    float lowReleaseMs,
    float midReleaseMs,
    float highReleaseMs,
    float lowKneeDB,
    float midKneeDB,
    float highKneeDB,
    float lowSidechainHPFHz,
    float midSidechainHPFHz,
    float highSidechainHPFHz,
    float lowMakeupDB,
    float midMakeupDB,
    float highMakeupDB
) {
    const float thresholds[3] = {lowThresholdDB, midThresholdDB, highThresholdDB};
    const float ratios[3] = {lowRatio, midRatio, highRatio};
    const float attacks[3] = {lowAttackMs, midAttackMs, highAttackMs};
    const float releases[3] = {lowReleaseMs, midReleaseMs, highReleaseMs};
    const float knees[3] = {lowKneeDB, midKneeDB, highKneeDB};
    const float sidechainHPF[3] = {lowSidechainHPFHz, midSidechainHPFHz, highSidechainHPFHz};
    const float makeup[3] = {lowMakeupDB, midMakeupDB, highMakeupDB};
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(lowMidFrequencyHz) || lowMidFrequencyHz < 40.0 || lowMidFrequencyHz > 250.0
        || !isfinite(midHighFrequencyHz) || midHighFrequencyHz < 1000.0 || midHighFrequencyHz > 8000.0
        || lowMidFrequencyHz >= midHighFrequencyHz || midHighFrequencyHz >= sampleRate * 0.45) return false;
    for (uint32_t band = 0; band < 3; ++band) {
        if (!isfinite(thresholds[band]) || thresholds[band] < -60.0f || thresholds[band] > 0.0f
            || !isfinite(ratios[band]) || ratios[band] < 1.0f || ratios[band] > 20.0f
            || !isfinite(attacks[band]) || attacks[band] < 1.0f || attacks[band] > 200.0f
            || !isfinite(releases[band]) || releases[band] < 10.0f || releases[band] > 1000.0f
            || !isfinite(knees[band]) || knees[band] < 0.0f || knees[band] > 20.0f
            || !isfinite(sidechainHPF[band]) || sidechainHPF[band] < 0.0f || sidechainHPF[band] > 300.0f
            || !isfinite(makeup[band]) || makeup[band] < -12.0f || makeup[band] > 12.0f) return false;
    }

    double lowQ[N60_MAX_CROSSOVER_SECTIONS] = {0};
    double highQ[N60_MAX_CROSSOVER_SECTIONS] = {0};
    uint32_t lowCount = 0, highCount = 0;
    if (!N60CrossoverTopologyQValues(lowTopology, lowQ, &lowCount)
        || !N60CrossoverTopologyQValues(highTopology, highQ, &highCount)) return false;

    N60MultibandCompressorSnapshot configured = {0};
    configured.enabled = enabled;
    configured.lowMidFrequencyHz = lowMidFrequencyHz;
    configured.midHighFrequencyHz = midHighFrequencyHz;
    configured.lowTopology = lowTopology;
    configured.highTopology = highTopology;
    configured.lowSectionCount = lowCount;
    configured.highSectionCount = highCount;
    for (uint32_t band = 0; band < 3; ++band) {
        configured.thresholdDB[band] = thresholds[band];
        configured.ratio[band] = ratios[band];
        configured.kneeWidthDB[band] = knees[band];
        configured.makeupGainDB[band] = makeup[band];
        configured.attackCoefficient[band] = coefficient_for_time_ms(sampleRate, attacks[band]);
        configured.releaseCoefficient[band] = coefficient_for_time_ms(sampleRate, releases[band]);
        configured.sidechainHighPass[band] = N60BiquadCoefficientsMakeIdentity();
        if (!valid_coefficient(configured.attackCoefficient[band])
            || !valid_coefficient(configured.releaseCoefficient[band])) return false;
        if (sidechainHPF[band] > 0.0f) {
            if (sidechainHPF[band] >= sampleRate * 0.45
                || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, sidechainHPF[band], 0.0, 0.7071067811865476, &configured.sidechainHighPass[band])) return false;
        }
    }
    for (uint32_t i = 0; i < N60_MAX_CROSSOVER_SECTIONS; ++i) {
        configured.lowPass[i] = N60BiquadCoefficientsMakeIdentity();
        configured.highPass[i] = N60BiquadCoefficientsMakeIdentity();
    }
    for (uint32_t i = 0; i < lowCount; ++i) {
        if (!N60BiquadDesign(N60BiquadFilterTypeLowPass, sampleRate, lowMidFrequencyHz, 0.0, lowQ[i], &configured.lowPass[i])) return false;
    }
    for (uint32_t i = 0; i < highCount; ++i) {
        if (!N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, midHighFrequencyHz, 0.0, highQ[i], &configured.highPass[i])) return false;
    }
    snapshot->multibandCompressor = configured;
    return true;
}
'''
Path(c).write_text(text[:idx] + new + text[end+3:])

# Replace compressor setter with wrapper + advanced.
text = Path(c).read_text()
start = 'bool N60DynamicsSnapshotSetCompressor(\n'
idx = text.find(start)
end = text.find('\n}\n\nbool N60DynamicsSnapshotSetExpander(', idx)
if idx < 0 or end < 0: raise SystemExit("compressor setter boundaries not found")
new = r'''bool N60DynamicsSnapshotSetCompressor(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDB,
    float ratio,
    float kneeWidthDB,
    float attackMs,
    float releaseMs,
    float makeupGainDB
) {
    return N60DynamicsSnapshotSetCompressorAdvanced(
        snapshot, sampleRate, enabled, thresholdDB, ratio, kneeWidthDB,
        attackMs, releaseMs, makeupGainDB,
        N60CompressorTopologyFeedForward, false, 0.0f
    );
}

bool N60DynamicsSnapshotSetCompressorAdvanced(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    float thresholdDB,
    float ratio,
    float kneeWidthDB,
    float attackMs,
    float releaseMs,
    float makeupGainDB,
    N60CompressorTopology topology,
    bool programDependentRelease,
    float sidechainHighPassHz
) {
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(thresholdDB) || thresholdDB < -96.0f || thresholdDB > 0.0f
        || !isfinite(ratio) || ratio < 1.0f || ratio > 100.0f
        || !isfinite(kneeWidthDB) || kneeWidthDB < 0.0f || kneeWidthDB > 24.0f
        || !isfinite(attackMs) || attackMs < 0.05f || attackMs > 1000.0f
        || !isfinite(releaseMs) || releaseMs < 1.0f || releaseMs > 5000.0f
        || !isfinite(makeupGainDB) || makeupGainDB < -24.0f || makeupGainDB > 24.0f
        || (topology != N60CompressorTopologyFeedForward && topology != N60CompressorTopologyFeedBack)
        || !isfinite(sidechainHighPassHz) || sidechainHighPassHz < 0.0f || sidechainHighPassHz > 300.0f) return false;

    N60CompressorSnapshot configured = {0};
    configured.enabled = enabled;
    configured.topology = topology;
    configured.programDependentRelease = programDependentRelease;
    configured.thresholdDB = thresholdDB;
    configured.ratio = ratio;
    configured.kneeWidthDB = kneeWidthDB;
    configured.makeupGainDB = makeupGainDB;
    configured.attackCoefficient = coefficient_for_time_ms(sampleRate, attackMs);
    configured.releaseCoefficient = coefficient_for_time_ms(sampleRate, releaseMs);
    configured.releaseFastCoefficient = coefficient_for_time_ms(sampleRate, fmaxf(releaseMs * 0.5f, 1.0f));
    configured.releaseSlowCoefficient = coefficient_for_time_ms(sampleRate, fminf(releaseMs * 2.0f, 5000.0f));
    configured.sidechainHighPass = N60BiquadCoefficientsMakeIdentity();
    if (!valid_coefficient(configured.attackCoefficient)
        || !valid_coefficient(configured.releaseCoefficient)
        || !valid_coefficient(configured.releaseFastCoefficient)
        || !valid_coefficient(configured.releaseSlowCoefficient)) return false;
    if (sidechainHighPassHz > 0.0f) {
        if (sidechainHighPassHz >= sampleRate * 0.45
            || !N60BiquadDesign(N60BiquadFilterTypeHighPass, sampleRate, sidechainHighPassHz, 0.0, 0.7071067811865476, &configured.sidechainHighPass)) return false;
    }
    snapshot->compressor = configured;
    return true;
}
'''
Path(c).write_text(text[:idx] + new + text[end+3:])

# Validation blocks.
replace_once(c,
'''        || snapshot.deEsser.ratio < 1.0f
        || !valid_coefficient(snapshot.deEsser.attackCoefficient)
''',
'''        || snapshot.deEsser.ratio < 1.0f || snapshot.deEsser.ratio > 20.0f
        || !isfinite(snapshot.deEsser.rangeDB) || snapshot.deEsser.rangeDB < -24.0f || snapshot.deEsser.rangeDB > 0.0f
        || !isfinite(snapshot.deEsser.detectionQ) || snapshot.deEsser.detectionQ < 0.5f || snapshot.deEsser.detectionQ > 8.0f
        || !valid_coefficient(snapshot.deEsser.attackCoefficient)
''')

# Replace multiband snapshot validation block.
text = Path(c).read_text()
old = '''    if (!isfinite(snapshot.multibandCompressor.lowMidFrequencyHz)
        || !isfinite(snapshot.multibandCompressor.midHighFrequencyHz)
        || snapshot.multibandCompressor.lowMidFrequencyHz >= snapshot.multibandCompressor.midHighFrequencyHz
        || snapshot.multibandCompressor.sectionCount > N60_MAX_CROSSOVER_SECTIONS
        || snapshot.multibandCompressor.ratio < 1.0f
        || !isfinite(snapshot.multibandCompressor.kneeWidthDB)
        || !valid_coefficient(snapshot.multibandCompressor.attackCoefficient)
        || !valid_coefficient(snapshot.multibandCompressor.releaseCoefficient)) return false;
    for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) {
        if (!isfinite(snapshot.multibandCompressor.thresholdDB[band])
            || snapshot.multibandCompressor.thresholdDB[band] < -60.0f
            || snapshot.multibandCompressor.thresholdDB[band] > 0.0f) return false;
    }
    for (uint32_t index = 0; index < snapshot.multibandCompressor.sectionCount; ++index) {
        if (!N60BiquadCoefficientsAreFinite(snapshot.multibandCompressor.lowPass[index])
            || !N60BiquadCoefficientsAreFinite(snapshot.multibandCompressor.highPass[index])) return false;
    }
'''
new = '''    if (!isfinite(snapshot.multibandCompressor.lowMidFrequencyHz)
        || !isfinite(snapshot.multibandCompressor.midHighFrequencyHz)
        || snapshot.multibandCompressor.lowMidFrequencyHz >= snapshot.multibandCompressor.midHighFrequencyHz
        || snapshot.multibandCompressor.lowSectionCount > N60_MAX_CROSSOVER_SECTIONS
        || snapshot.multibandCompressor.highSectionCount > N60_MAX_CROSSOVER_SECTIONS) return false;
    for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) {
        if (!isfinite(snapshot.multibandCompressor.thresholdDB[band])
            || snapshot.multibandCompressor.thresholdDB[band] < -60.0f || snapshot.multibandCompressor.thresholdDB[band] > 0.0f
            || !isfinite(snapshot.multibandCompressor.ratio[band]) || snapshot.multibandCompressor.ratio[band] < 1.0f || snapshot.multibandCompressor.ratio[band] > 20.0f
            || !isfinite(snapshot.multibandCompressor.kneeWidthDB[band]) || snapshot.multibandCompressor.kneeWidthDB[band] < 0.0f || snapshot.multibandCompressor.kneeWidthDB[band] > 20.0f
            || !isfinite(snapshot.multibandCompressor.makeupGainDB[band]) || snapshot.multibandCompressor.makeupGainDB[band] < -12.0f || snapshot.multibandCompressor.makeupGainDB[band] > 12.0f
            || !valid_coefficient(snapshot.multibandCompressor.attackCoefficient[band])
            || !valid_coefficient(snapshot.multibandCompressor.releaseCoefficient[band])
            || !N60BiquadCoefficientsAreFinite(snapshot.multibandCompressor.sidechainHighPass[band])) return false;
    }
    for (uint32_t index = 0; index < snapshot.multibandCompressor.lowSectionCount; ++index) {
        if (!N60BiquadCoefficientsAreFinite(snapshot.multibandCompressor.lowPass[index])) return false;
    }
    for (uint32_t index = 0; index < snapshot.multibandCompressor.highSectionCount; ++index) {
        if (!N60BiquadCoefficientsAreFinite(snapshot.multibandCompressor.highPass[index])) return false;
    }
'''
if old not in text: raise SystemExit("multiband validation block not found")
Path(c).write_text(text.replace(old,new,1))

replace_once(c,
'''    if (snapshot.compressor.ratio < 1.0f || snapshot.compressor.ratio > 100.0f
        || !isfinite(snapshot.compressor.thresholdDB)
''',
'''    if (snapshot.compressor.ratio < 1.0f || snapshot.compressor.ratio > 100.0f
        || (snapshot.compressor.topology != N60CompressorTopologyFeedForward && snapshot.compressor.topology != N60CompressorTopologyFeedBack)
        || !isfinite(snapshot.compressor.thresholdDB)
''')
replace_once(c,
'''        || !valid_coefficient(snapshot.compressor.attackCoefficient)
        || !valid_coefficient(snapshot.compressor.releaseCoefficient)) return false;
''',
'''        || !valid_coefficient(snapshot.compressor.attackCoefficient)
        || !valid_coefficient(snapshot.compressor.releaseCoefficient)
        || !valid_coefficient(snapshot.compressor.releaseFastCoefficient)
        || !valid_coefficient(snapshot.compressor.releaseSlowCoefficient)
        || !N60BiquadCoefficientsAreFinite(snapshot.compressor.sidechainHighPass)) return false;
''')

# De-esser range clamp.
replace_once(c,
'''    float targetDB = dynamics_compression_target(
        detector,
        snapshot.deEsser.enabled,
        snapshot.deEsser.thresholdDB,
        snapshot.deEsser.ratio,
        3.0f
    );
''',
'''    float targetDB = dynamics_compression_target(
        detector,
        snapshot.deEsser.enabled,
        snapshot.deEsser.thresholdDB,
        snapshot.deEsser.ratio,
        3.0f
    );
    targetDB = fmaxf(targetDB, snapshot.deEsser.rangeDB);
''')

# Multiband processing: counts + per-band sidechain and params.
replace_once(c, '    if (multiband.sectionCount == 0) return;\n', '    if (multiband.lowSectionCount == 0 || multiband.highSectionCount == 0) return;\n')
replace_once(c,
'''        multiband.lowPass,
        runtime->multibandLowPassLeft,
        multiband.sectionCount,
''',
'''        multiband.lowPass,
        runtime->multibandLowPassLeft,
        multiband.lowSectionCount,
''')
replace_once(c,
'''        multiband.lowPass,
        runtime->multibandLowPassRight,
        multiband.sectionCount,
''',
'''        multiband.lowPass,
        runtime->multibandLowPassRight,
        multiband.lowSectionCount,
''')
replace_once(c,
'''        multiband.highPass,
        runtime->multibandHighPassLeft,
        multiband.sectionCount,
''',
'''        multiband.highPass,
        runtime->multibandHighPassLeft,
        multiband.highSectionCount,
''')
replace_once(c,
'''        multiband.highPass,
        runtime->multibandHighPassRight,
        multiband.sectionCount,
''',
'''        multiband.highPass,
        runtime->multibandHighPassRight,
        multiband.highSectionCount,
''')
replace_once(c,
'''    for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) {
        float detector = fmaxf(fabsf(bandLeft[band]), fabsf(bandRight[band]));
        float targetDB = dynamics_compression_target(
            detector,
            multiband.enabled,
            multiband.thresholdDB[band],
            multiband.ratio,
            multiband.kneeWidthDB
        );
        float coefficient = !multiband.enabled
            ? snapshot.bypassTransitionCoefficient
            : (targetDB < runtime->multibandGainDB[band]
                ? multiband.attackCoefficient
                : multiband.releaseCoefficient);
''',
'''    for (uint32_t band = 0; band < N60_MULTIBAND_BAND_COUNT; ++band) {
        float detectorLeft = N60BiquadProcessSample(multiband.sidechainHighPass[band], &runtime->multibandSidechainLeft[band], bandLeft[band]);
        float detectorRight = N60BiquadProcessSample(multiband.sidechainHighPass[band], &runtime->multibandSidechainRight[band], bandRight[band]);
        float detector = fmaxf(fabsf(detectorLeft), fabsf(detectorRight));
        float targetDB = dynamics_compression_target(
            detector,
            multiband.enabled,
            multiband.thresholdDB[band],
            multiband.ratio[band],
            multiband.kneeWidthDB[band]
        );
        if (multiband.enabled) targetDB += multiband.makeupGainDB[band];
        float coefficient = !multiband.enabled
            ? snapshot.bypassTransitionCoefficient
            : (targetDB < runtime->multibandGainDB[band]
                ? multiband.attackCoefficient[band]
                : multiband.releaseCoefficient[band]);
''')

# Compressor detector/topology/sidechain + program dependent release.
replace_once(c,
'''    float detector = fmaxf(fabsf(*left), fabsf(*right));
    float detectorDB = linear_to_db(detector);

    float compressorTargetDB = compressor_target_gain_db(detectorDB, snapshot.compressor);
    float compressorCoefficient;
    if (!snapshot.compressor.enabled) {
        compressorCoefficient = snapshot.bypassTransitionCoefficient;
    } else {
        compressorCoefficient = compressorTargetDB < runtime->compressorGainDB
            ? snapshot.compressor.attackCoefficient
            : snapshot.compressor.releaseCoefficient;
    }
''',
'''    float detectorFeedGain = snapshot.compressor.topology == N60CompressorTopologyFeedBack
        ? db_to_linear(runtime->compressorGainDB) : 1.0f;
    float compressorDetectorLeft = N60BiquadProcessSample(
        snapshot.compressor.sidechainHighPass, &runtime->compressorSidechainLeft, *left * detectorFeedGain);
    float compressorDetectorRight = N60BiquadProcessSample(
        snapshot.compressor.sidechainHighPass, &runtime->compressorSidechainRight, *right * detectorFeedGain);
    float detector = fmaxf(fabsf(compressorDetectorLeft), fabsf(compressorDetectorRight));
    float detectorDB = linear_to_db(detector);

    float compressorTargetDB = compressor_target_gain_db(detectorDB, snapshot.compressor);
    float compressorCoefficient;
    if (!snapshot.compressor.enabled) {
        compressorCoefficient = snapshot.bypassTransitionCoefficient;
    } else if (compressorTargetDB < runtime->compressorGainDB) {
        compressorCoefficient = snapshot.compressor.attackCoefficient;
    } else if (snapshot.compressor.programDependentRelease) {
        float depth = clampf(-runtime->compressorGainDB / 12.0f, 0.0f, 1.0f);
        compressorCoefficient = snapshot.compressor.releaseFastCoefficient
            + depth * (snapshot.compressor.releaseSlowCoefficient - snapshot.compressor.releaseFastCoefficient);
    } else {
        compressorCoefficient = snapshot.compressor.releaseCoefficient;
    }
''')

# ---- Swift control plane -------------------------------------------------
s = "NotchSixty/Audio/DynamicsConfiguration.swift"
replace_once(s,
'''struct DeEsserConfiguration: Equatable, Sendable {
    static let frequencyRange = 2_000.0...10_000.0
    static let thresholdRange = -60.0...0.0

    var enabled = false
    var frequencyHz = 6_500.0
    var thresholdDB = -24.0
    var dynamicEQMode = true

    func validate() throws {
        guard frequencyHz.isFinite, Self.frequencyRange.contains(frequencyHz),
              thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB) else {
            throw DynamicsConfigurationError.invalidDeEsser
        }
    }
}
''',
'''struct DeEsserConfiguration: Equatable, Sendable {
    static let frequencyRange = 2_000.0...10_000.0
    static let thresholdRange = -60.0...0.0
    static let ratioRange = 1.0...20.0
    static let rangeRange = -24.0...0.0
    static let detectionQRange = 0.5...8.0
    static let attackRange = 0.1...100.0
    static let releaseRange = 10.0...1_000.0

    var enabled = false
    var frequencyHz = 6_500.0
    var thresholdDB = -24.0
    var ratio = 4.0
    var rangeDB = -24.0
    var detectionQ = 2.0
    var attackMs = 1.0
    var releaseMs = 50.0
    var dynamicEQMode = true

    func validate() throws {
        guard frequencyHz.isFinite, Self.frequencyRange.contains(frequencyHz),
              thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB),
              ratio.isFinite, Self.ratioRange.contains(ratio),
              rangeDB.isFinite, Self.rangeRange.contains(rangeDB),
              detectionQ.isFinite, Self.detectionQRange.contains(detectionQ),
              attackMs.isFinite, Self.attackRange.contains(attackMs),
              releaseMs.isFinite, Self.releaseRange.contains(releaseMs) else {
            throw DynamicsConfigurationError.invalidDeEsser
        }
    }
}
''')

# replace multiband config whole block through before CompressorConfiguration
text = Path(s).read_text()
idx = text.find('struct MultibandCompressorConfiguration: Equatable, Sendable {')
end = text.find('\nstruct CompressorConfiguration: Equatable, Sendable {', idx)
if idx < 0 or end < 0: raise SystemExit('Swift multiband block not found')
new = r'''struct MultibandCompressorConfiguration: Equatable, Sendable {
    static let lowMidFrequencyRange = 40.0...250.0
    static let midHighFrequencyRange = 1_000.0...8_000.0
    static let thresholdRange = -60.0...0.0
    static let ratioRange = 1.0...20.0
    static let attackRange = 1.0...200.0
    static let releaseRange = 10.0...1_000.0
    static let kneeRange = 0.0...20.0
    static let sidechainRange = 0.0...300.0
    static let makeupRange = -12.0...12.0

    var enabled = false
    var lowMidFrequencyHz = 120.0
    var midHighFrequencyHz = 3_500.0
    var lowMidSlope: MultibandSlope = .gentle
    var midHighSlope: MultibandSlope = .gentle
    var lowThresholdDB = -18.0
    var midThresholdDB = -18.0
    var highThresholdDB = -18.0
    var lowRatio = 3.0
    var midRatio = 3.0
    var highRatio = 3.0
    var lowAttackMs = 10.0
    var midAttackMs = 10.0
    var highAttackMs = 10.0
    var lowReleaseMs = 150.0
    var midReleaseMs = 150.0
    var highReleaseMs = 150.0
    var lowKneeDB = 6.0
    var midKneeDB = 6.0
    var highKneeDB = 6.0
    var lowSidechainHighPassHz = 0.0
    var midSidechainHighPassHz = 0.0
    var highSidechainHighPassHz = 0.0
    var lowMakeupGainDB = 0.0
    var midMakeupGainDB = 0.0
    var highMakeupGainDB = 0.0

    // Compatibility convenience for the previous shared slope control.
    var slope: MultibandSlope {
        get { lowMidSlope }
        set { lowMidSlope = newValue; midHighSlope = newValue }
    }

    func validate() throws {
        let thresholds = [lowThresholdDB, midThresholdDB, highThresholdDB]
        let ratios = [lowRatio, midRatio, highRatio]
        let attacks = [lowAttackMs, midAttackMs, highAttackMs]
        let releases = [lowReleaseMs, midReleaseMs, highReleaseMs]
        let knees = [lowKneeDB, midKneeDB, highKneeDB]
        let sidechains = [lowSidechainHighPassHz, midSidechainHighPassHz, highSidechainHighPassHz]
        let makeups = [lowMakeupGainDB, midMakeupGainDB, highMakeupGainDB]
        guard lowMidFrequencyHz.isFinite, Self.lowMidFrequencyRange.contains(lowMidFrequencyHz),
              midHighFrequencyHz.isFinite, Self.midHighFrequencyRange.contains(midHighFrequencyHz),
              lowMidFrequencyHz < midHighFrequencyHz,
              thresholds.allSatisfy({ $0.isFinite && Self.thresholdRange.contains($0) }),
              ratios.allSatisfy({ $0.isFinite && Self.ratioRange.contains($0) }),
              attacks.allSatisfy({ $0.isFinite && Self.attackRange.contains($0) }),
              releases.allSatisfy({ $0.isFinite && Self.releaseRange.contains($0) }),
              knees.allSatisfy({ $0.isFinite && Self.kneeRange.contains($0) }),
              sidechains.allSatisfy({ $0.isFinite && Self.sidechainRange.contains($0) }),
              makeups.allSatisfy({ $0.isFinite && Self.makeupRange.contains($0) }) else {
            throw DynamicsConfigurationError.invalidMultibandCompressor
        }
    }
}
'''
Path(s).write_text(text[:idx] + new + text[end:])

# compressor enum + config
replace_once(s,
'''struct CompressorConfiguration: Equatable, Sendable {
''',
'''enum CompressorTopology: String, CaseIterable, Identifiable, Sendable {
    case feedForward
    case feedBack
    var id: String { rawValue }
    var displayName: String { self == .feedForward ? "Feed-Forward" : "Feed-Back" }
    var cType: N60CompressorTopology { self == .feedForward ? N60CompressorTopologyFeedForward : N60CompressorTopologyFeedBack }
}

struct CompressorConfiguration: Equatable, Sendable {
''')
replace_once(s,
'''    static let makeupRange = -24.0...24.0

    var enabled = false
''',
'''    static let makeupRange = -24.0...24.0
    static let sidechainHighPassRange = 0.0...300.0

    var enabled = false
''')
replace_once(s,
'''    var makeupGainDB = 0.0

    func validate() throws {
''',
'''    var makeupGainDB = 0.0
    var topology: CompressorTopology = .feedForward
    var programDependentRelease = false
    var sidechainHighPassHz = 0.0

    func validate() throws {
''')
replace_once(s,
'''              releaseMs.isFinite, Self.releaseRange.contains(releaseMs),
              makeupGainDB.isFinite, Self.makeupRange.contains(makeupGainDB) else {
''',
'''              releaseMs.isFinite, Self.releaseRange.contains(releaseMs),
              makeupGainDB.isFinite, Self.makeupRange.contains(makeupGainDB),
              sidechainHighPassHz.isFinite, Self.sidechainHighPassRange.contains(sidechainHighPassHz) else {
''')

# Swift snapshot calls.
replace_once(s,
'''        guard N60DynamicsSnapshotSetDeEsser(
            &snapshot,
            sampleRate,
            deEsser.enabled,
            deEsser.frequencyHz,
            Float(deEsser.thresholdDB),
            deEsser.dynamicEQMode
        ) else { throw DynamicsConfigurationError.invalidDeEsser }
''',
'''        guard N60DynamicsSnapshotSetDeEsserAdvanced(
            &snapshot,
            sampleRate,
            deEsser.enabled,
            deEsser.frequencyHz,
            Float(deEsser.thresholdDB),
            Float(deEsser.ratio),
            Float(deEsser.rangeDB),
            Float(deEsser.detectionQ),
            Float(deEsser.attackMs),
            Float(deEsser.releaseMs),
            deEsser.dynamicEQMode
        ) else { throw DynamicsConfigurationError.invalidDeEsser }
''')

old = '''        guard N60DynamicsSnapshotSetMultibandCompressor(
            &snapshot,
            sampleRate,
            multibandCompressor.enabled,
            multibandCompressor.lowMidFrequencyHz,
            multibandCompressor.midHighFrequencyHz,
            multibandCompressor.slope.cType,
            Float(multibandCompressor.lowThresholdDB),
            Float(multibandCompressor.midThresholdDB),
            Float(multibandCompressor.highThresholdDB)
        ) else { throw DynamicsConfigurationError.invalidMultibandCompressor }
'''
new = '''        guard N60DynamicsSnapshotSetMultibandCompressorAdvanced(
            &snapshot,
            sampleRate,
            multibandCompressor.enabled,
            multibandCompressor.lowMidFrequencyHz,
            multibandCompressor.midHighFrequencyHz,
            multibandCompressor.lowMidSlope.cType,
            multibandCompressor.midHighSlope.cType,
            Float(multibandCompressor.lowThresholdDB), Float(multibandCompressor.midThresholdDB), Float(multibandCompressor.highThresholdDB),
            Float(multibandCompressor.lowRatio), Float(multibandCompressor.midRatio), Float(multibandCompressor.highRatio),
            Float(multibandCompressor.lowAttackMs), Float(multibandCompressor.midAttackMs), Float(multibandCompressor.highAttackMs),
            Float(multibandCompressor.lowReleaseMs), Float(multibandCompressor.midReleaseMs), Float(multibandCompressor.highReleaseMs),
            Float(multibandCompressor.lowKneeDB), Float(multibandCompressor.midKneeDB), Float(multibandCompressor.highKneeDB),
            Float(multibandCompressor.lowSidechainHighPassHz), Float(multibandCompressor.midSidechainHighPassHz), Float(multibandCompressor.highSidechainHighPassHz),
            Float(multibandCompressor.lowMakeupGainDB), Float(multibandCompressor.midMakeupGainDB), Float(multibandCompressor.highMakeupGainDB)
        ) else { throw DynamicsConfigurationError.invalidMultibandCompressor }
'''
replace_once(s,old,new)
replace_once(s,
'''        guard N60DynamicsSnapshotSetCompressor(
            &snapshot,
            sampleRate,
            compressor.enabled,
            Float(compressor.thresholdDB),
            Float(compressor.ratio),
            Float(compressor.kneeWidthDB),
            Float(compressor.attackMs),
            Float(compressor.releaseMs),
            Float(compressor.makeupGainDB)
        ) else { throw DynamicsConfigurationError.invalidCompressor }
''',
'''        guard N60DynamicsSnapshotSetCompressorAdvanced(
            &snapshot,
            sampleRate,
            compressor.enabled,
            Float(compressor.thresholdDB),
            Float(compressor.ratio),
            Float(compressor.kneeWidthDB),
            Float(compressor.attackMs),
            Float(compressor.releaseMs),
            Float(compressor.makeupGainDB),
            compressor.topology.cType,
            compressor.programDependentRelease,
            Float(compressor.sidechainHighPassHz)
        ) else { throw DynamicsConfigurationError.invalidCompressor }
''')

# ---- Tests ---------------------------------------------------------------
t = Path("NotchSixtyTests/DynamicsTests.swift")
text = t.read_text()
insert = r'''

    func testPR32AdvancedCompressorSidechainAndTopologyAreFinite() {
        for rate in [48_000.0, 96_000.0, 384_000.0] {
            for topology in [N60CompressorTopologyFeedForward, N60CompressorTopologyFeedBack] {
                var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
                XCTAssertTrue(N60DynamicsSnapshotSetCompressorAdvanced(
                    &snapshot, rate, true, -24, 4, 6, 5, 200, 0,
                    topology, true, 120
                ))
                var runtime = N60DynamicsRuntime()
                N60DynamicsRuntimeReset(&runtime)
                for frame in 0..<Int(rate * 0.1) {
                    var left = Float(0.55 * sin(2 * Double.pi * 1000 * Double(frame) / rate))
                    var right = left * 0.5
                    N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
                    XCTAssertTrue(left.isFinite && right.isFinite)
                }
            }
        }
    }

    func testPR32DeEsserRangeBoundsReduction() {
        let rate = 48_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetDeEsserAdvanced(
            &snapshot, rate, true, 6_500, -50, 20, -6, 2, 1, 50, false
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        for frame in 0..<48_000 {
            var left = Float(0.7 * sin(2 * Double.pi * 6500 * Double(frame) / rate))
            var right = left
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
        }
        XCTAssertLessThanOrEqual(N60DynamicsRuntimeTelemetry(&runtime).deEsserGainReductionDB, 6.05)
    }

    func testPR32MultibandIndependentControlsStayFiniteAndLinked() {
        let rate = 96_000.0
        var snapshot = N60DynamicsSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetMultibandCompressorAdvanced(
            &snapshot, rate, true, 120, 3_500,
            N60CrossoverTopologyLinkwitzRiley24, N60CrossoverTopologyLinkwitzRiley48,
            -24, -20, -18,
            2, 4, 8,
            40, 20, 5,
            300, 150, 50,
            3, 6, 9,
            0, 80, 150,
            0, 1, -1
        ))
        var runtime = N60DynamicsRuntime()
        N60DynamicsRuntimeReset(&runtime)
        for frame in 0..<48_000 {
            let x = Float(0.25 * sin(2 * Double.pi * 6000 * Double(frame) / rate))
            var left = x
            var right = x * 0.5
            N60DynamicsProcessStereoFrame(&runtime, snapshot, &left, &right)
            XCTAssertTrue(left.isFinite && right.isFinite)
        }
    }

    func testPR32ControlRangesRejectInvalidValues() {
        var config = DynamicsConfiguration()
        config.compressor.sidechainHighPassHz = 301
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))
        config = DynamicsConfiguration()
        config.deEsser.detectionQ = 8.1
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))
        config = DynamicsConfiguration()
        config.multibandCompressor.highRatio = 21
        XCTAssertThrowsError(try config.makeSnapshot(sampleRate: 96_000))
    }
'''
pos = text.rfind('\n}')
if pos < 0: raise SystemExit('DynamicsTests closing brace not found')
t.write_text(text[:pos] + insert + text[pos:])

print('PR32 Slice 1 patch applied')
