from pathlib import Path
import re

ROOT = Path('.')

def read(path): return (ROOT / path).read_text()
def write(path, text): (ROOT / path).write_text(text)
def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f'anchor not found: {label}')
    return text.replace(old, new, 1)

# --- N60Protection.h ---
p = 'NotchSixty/Audio/Realtime/N60Protection.h'
s = read(p)
s = replace_once(s, '''typedef enum {\n    N60OversamplingFactor1x = 1,\n    N60OversamplingFactor2x = 2,\n    N60OversamplingFactor4x = 4,\n} N60OversamplingFactor;\n''', '''typedef enum {\n    N60OversamplingFactor1x = 1,\n    N60OversamplingFactor2x = 2,\n    N60OversamplingFactor4x = 4,\n} N60OversamplingFactor;\n\ntypedef enum {\n    N60GainRiderSpeedFast = 0,\n    N60GainRiderSpeedMedium = 1,\n    N60GainRiderSpeedSlow = 2,\n} N60GainRiderSpeed;\n''', 'protection speed enum')
s = replace_once(s, '''    N60ClipperCurveType clipperCurve;\n    float clipperCompensationLinear;\n\n    bool limiterEnabled;\n''', '''    N60ClipperCurveType clipperCurve;\n    float clipperCompensationLinear;\n    float clipperAsymmetryTrimDB;\n\n    bool limiterEnabled;\n''', 'clipper asymmetry field')
s = replace_once(s, '''    uint32_t limiterAttackHighSamples;\n    float limiterReleaseCoefficientHigh;\n} N60ProtectionSnapshot;\n''', '''    uint32_t limiterAttackHighSamples;\n    float limiterReleaseCoefficientHigh;\n    bool truePeakGuardEnabled;\n\n    bool gainRiderEnabled;\n    float gainRiderTargetGRDB;\n    float gainRiderMaxReductionDB;\n    N60GainRiderSpeed gainRiderSpeed;\n    float gainRiderMeasurementCoefficient;\n    float gainRiderResponseCoefficient;\n} N60ProtectionSnapshot;\n''', 'guard/rider fields')
s = replace_once(s, '''    float limiterGainReductionDB;\n    uint64_t limiterSafetyClampSamples;\n} N60ProtectionTelemetry;\n''', '''    float limiterGainReductionDB;\n    uint64_t limiterSafetyClampSamples;\n    float gainRiderAttenuationDB;\n    float sustainedLimiterGainReductionDB;\n    bool truePeakGuardActive;\n} N60ProtectionTelemetry;\n''', 'rider telemetry')
s = replace_once(s, '''bool N60ProtectionSnapshotSetSoftClipper(\n    N60ProtectionSnapshot *snapshot,\n    bool enabled,\n    float driveDB,\n    float thresholdDB,\n    float kneeSmooth,\n    N60ClipperCurveType curve,\n    bool autoCompensateGain\n);\n''', '''bool N60ProtectionSnapshotSetSoftClipper(\n    N60ProtectionSnapshot *snapshot,\n    bool enabled,\n    float driveDB,\n    float thresholdDB,\n    float kneeSmooth,\n    N60ClipperCurveType curve,\n    bool autoCompensateGain\n);\n\nbool N60ProtectionSnapshotSetSoftClipperAdvanced(\n    N60ProtectionSnapshot *snapshot,\n    bool enabled,\n    float driveDB,\n    float thresholdDB,\n    float kneeSmooth,\n    N60ClipperCurveType curve,\n    bool autoCompensateGain,\n    float asymmetryTrimDB\n);\n''', 'advanced clipper prototype')
s = replace_once(s, '''bool N60ProtectionSnapshotSetLimiter(\n    N60ProtectionSnapshot *snapshot,\n    bool enabled,\n    float ceilingDB,\n    float attackMs,\n    float releaseMs,\n    float lookAheadMs\n);\n''', '''bool N60ProtectionSnapshotSetLimiter(\n    N60ProtectionSnapshot *snapshot,\n    bool enabled,\n    float ceilingDB,\n    float attackMs,\n    float releaseMs,\n    float lookAheadMs\n);\n\nbool N60ProtectionSnapshotSetLimiterAdvanced(\n    N60ProtectionSnapshot *snapshot,\n    bool enabled,\n    float ceilingDB,\n    float attackMs,\n    float releaseMs,\n    float lookAheadMs,\n    bool truePeakGuardEnabled\n);\n\nbool N60ProtectionSnapshotSetGainRider(\n    N60ProtectionSnapshot *snapshot,\n    bool enabled,\n    float targetGainReductionDB,\n    float maxReductionDB,\n    N60GainRiderSpeed speed\n);\n''', 'advanced limiter prototype')
write(p, s)

# --- N60Protection.c ---
p = 'NotchSixty/Audio/Realtime/N60Protection.c'
s = read(p)
s = replace_once(s, '''    uint64_t limiterSequence;\n    float limiterGain;\n\n    float peakDequeValue''', '''    uint64_t limiterSequence;\n    float limiterGain;\n    float gainRiderAttenuationDB;\n    float sustainedLimiterGainReductionDB;\n\n    float peakDequeValue''', 'runtime rider fields')
s = replace_once(s, '''static float linear_to_db(float linear) {\n    return 20.0f * log10f(fmaxf(linear, N60_EPSILON));\n}\n''', '''static float linear_to_db(float linear) {\n    return 20.0f * log10f(fmaxf(linear, N60_EPSILON));\n}\n\nstatic float coefficient_for_seconds(double sampleRate, float seconds) {\n    return expf(-1.0f / fmaxf(1.0f, seconds * (float)sampleRate));\n}\n''', 'seconds coefficient')
s = replace_once(s, '''    snapshot->effectiveFactor = snapshot->limiterEnabled\n        ? N60OversamplingFactor4x\n        : snapshot->oversamplingFactor;\n''', '''    snapshot->effectiveFactor = (snapshot->limiterEnabled && snapshot->truePeakGuardEnabled)\n        ? N60OversamplingFactor4x\n        : snapshot->oversamplingFactor;\n''', 'effective factor guard')
s = replace_once(s, '''    snapshot.clipperCompensationLinear = 1.0f;\n    snapshot.limiterCeilingLinear = db_to_linear(-0.2f);\n''', '''    snapshot.clipperCompensationLinear = 1.0f;\n    snapshot.clipperAsymmetryTrimDB = 0.0f;\n    snapshot.limiterCeilingLinear = db_to_linear(-0.2f);\n''', 'bypass clipper trim')
s = replace_once(s, '''    snapshot.limiterReleaseMs = 20.0f;\n    snapshot.limiterLookAheadMs = 2.0f;\n    refresh_derived_state(&snapshot);\n''', '''    snapshot.limiterReleaseMs = 20.0f;\n    snapshot.limiterLookAheadMs = 2.0f;\n    // Preserve the accepted PR27 limiter behavior: true-peak limiting uses the\n    // 4x reconstruction path unless the user explicitly disables TP Guard.\n    snapshot.truePeakGuardEnabled = true;\n    snapshot.gainRiderEnabled = false;\n    snapshot.gainRiderTargetGRDB = 3.0f;\n    snapshot.gainRiderMaxReductionDB = 6.0f;\n    snapshot.gainRiderSpeed = N60GainRiderSpeedMedium;\n    snapshot.gainRiderMeasurementCoefficient = coefficient_for_seconds(sampleRate, 1.0f);\n    snapshot.gainRiderResponseCoefficient = coefficient_for_seconds(sampleRate, 10.0f);\n    refresh_derived_state(&snapshot);\n''', 'bypass guard/rider defaults')

start = s.index('bool N60ProtectionSnapshotSetSoftClipper(')
end = s.index('bool N60ProtectionSnapshotIsValid(', start)
new_setters = r'''bool N60ProtectionSnapshotSetSoftClipper(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float driveDB,
    float thresholdDB,
    float kneeSmooth,
    N60ClipperCurveType curve,
    bool autoCompensateGain
) {
    return N60ProtectionSnapshotSetSoftClipperAdvanced(
        snapshot, enabled, driveDB, thresholdDB, kneeSmooth, curve, autoCompensateGain, 0.0f);
}

bool N60ProtectionSnapshotSetSoftClipperAdvanced(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float driveDB,
    float thresholdDB,
    float kneeSmooth,
    N60ClipperCurveType curve,
    bool autoCompensateGain,
    float asymmetryTrimDB
) {
    if (snapshot == NULL
        || !isfinite(driveDB) || driveDB < 0.0f || driveDB > 12.0f
        || !isfinite(thresholdDB) || thresholdDB < -6.0f || thresholdDB > 0.0f
        || !isfinite(kneeSmooth) || kneeSmooth < 0.0f || kneeSmooth > 1.0f
        || !isfinite(asymmetryTrimDB) || asymmetryTrimDB < -3.0f || asymmetryTrimDB > 3.0f
        || curve < N60ClipperCurveQuadratic || curve > N60ClipperCurveAsymmetricTube) {
        return false;
    }
    snapshot->softClipperEnabled = enabled;
    snapshot->clipperDriveLinear = db_to_linear(driveDB);
    snapshot->clipperThresholdLinear = db_to_linear(thresholdDB);
    snapshot->clipperKneeSmooth = kneeSmooth;
    snapshot->clipperCurve = curve;
    snapshot->clipperCompensationLinear = autoCompensateGain ? 1.0f / snapshot->clipperDriveLinear : 1.0f;
    snapshot->clipperAsymmetryTrimDB = asymmetryTrimDB;
    refresh_derived_state(snapshot);
    return N60ProtectionSnapshotIsValid(snapshot);
}

bool N60ProtectionSnapshotSetLimiter(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float ceilingDB,
    float attackMs,
    float releaseMs,
    float lookAheadMs
) {
    return N60ProtectionSnapshotSetLimiterAdvanced(
        snapshot, enabled, ceilingDB, attackMs, releaseMs, lookAheadMs, true);
}

bool N60ProtectionSnapshotSetLimiterAdvanced(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float ceilingDB,
    float attackMs,
    float releaseMs,
    float lookAheadMs,
    bool truePeakGuardEnabled
) {
    if (snapshot == NULL
        || !isfinite(ceilingDB) || ceilingDB < -20.0f || ceilingDB > 0.0f
        || !isfinite(attackMs) || attackMs < 0.1f || attackMs > 50.0f
        || !isfinite(releaseMs) || releaseMs < 5.0f || releaseMs > 500.0f
        || !isfinite(lookAheadMs) || lookAheadMs < 0.0f || lookAheadMs > N60_PROTECTION_MAX_LOOKAHEAD_MS) {
        return false;
    }
    snapshot->limiterEnabled = enabled;
    snapshot->limiterCeilingLinear = db_to_linear(ceilingDB);
    snapshot->limiterAttackMs = attackMs;
    snapshot->limiterReleaseMs = releaseMs;
    snapshot->limiterLookAheadMs = lookAheadMs;
    snapshot->truePeakGuardEnabled = truePeakGuardEnabled;
    refresh_derived_state(snapshot);
    return N60ProtectionSnapshotIsValid(snapshot);
}

bool N60ProtectionSnapshotSetGainRider(
    N60ProtectionSnapshot *snapshot,
    bool enabled,
    float targetGainReductionDB,
    float maxReductionDB,
    N60GainRiderSpeed speed
) {
    if (snapshot == NULL
        || !isfinite(targetGainReductionDB) || targetGainReductionDB < 0.5f || targetGainReductionDB > 6.0f
        || !isfinite(maxReductionDB) || maxReductionDB < 3.0f || maxReductionDB > 12.0f
        || speed < N60GainRiderSpeedFast || speed > N60GainRiderSpeedSlow) return false;
    float seconds = speed == N60GainRiderSpeedFast ? 3.0f
        : (speed == N60GainRiderSpeedSlow ? 30.0f : 10.0f);
    snapshot->gainRiderEnabled = enabled;
    snapshot->gainRiderTargetGRDB = targetGainReductionDB;
    snapshot->gainRiderMaxReductionDB = maxReductionDB;
    snapshot->gainRiderSpeed = speed;
    snapshot->gainRiderMeasurementCoefficient = coefficient_for_seconds(snapshot->sampleRate, 1.0f);
    snapshot->gainRiderResponseCoefficient = coefficient_for_seconds(snapshot->sampleRate, seconds);
    return N60ProtectionSnapshotIsValid(snapshot);
}

'''
s = s[:start] + new_setters + s[end:]
s = replace_once(s, '''        && snapshot->clipperCurve <= N60ClipperCurveAsymmetricTube\n        && isfinite(snapshot->clipperCompensationLinear) && snapshot->clipperCompensationLinear > 0.0f\n        && isfinite(snapshot->limiterCeilingLinear)''', '''        && snapshot->clipperCurve <= N60ClipperCurveAsymmetricTube\n        && isfinite(snapshot->clipperCompensationLinear) && snapshot->clipperCompensationLinear > 0.0f\n        && isfinite(snapshot->clipperAsymmetryTrimDB)\n        && snapshot->clipperAsymmetryTrimDB >= -3.0f && snapshot->clipperAsymmetryTrimDB <= 3.0f\n        && isfinite(snapshot->gainRiderTargetGRDB) && snapshot->gainRiderTargetGRDB >= 0.5f && snapshot->gainRiderTargetGRDB <= 6.0f\n        && isfinite(snapshot->gainRiderMaxReductionDB) && snapshot->gainRiderMaxReductionDB >= 3.0f && snapshot->gainRiderMaxReductionDB <= 12.0f\n        && snapshot->gainRiderSpeed >= N60GainRiderSpeedFast && snapshot->gainRiderSpeed <= N60GainRiderSpeedSlow\n        && isfinite(snapshot->gainRiderMeasurementCoefficient) && snapshot->gainRiderMeasurementCoefficient >= 0.0f && snapshot->gainRiderMeasurementCoefficient < 1.0f\n        && isfinite(snapshot->gainRiderResponseCoefficient) && snapshot->gainRiderResponseCoefficient >= 0.0f && snapshot->gainRiderResponseCoefficient < 1.0f\n        && isfinite(snapshot->limiterCeilingLinear)''', 'snapshot validity extensions')
s = replace_once(s, '''static float soft_clip_sample(const N60ProtectionSnapshot *snapshot, float input) {\n    float driven = input * snapshot->clipperDriveLinear;\n    float sign = driven < 0.0f ? -1.0f : 1.0f;\n''', '''static float soft_clip_sample(const N60ProtectionSnapshot *snapshot, float input) {\n    // Equal-and-opposite half-cycle drive trim creates controllable even-order\n    // asymmetry without changing the nominal broadband drive setting. Zero trim\n    // is sample-identical to the PR27 clipper path.\n    float polarityTrimDB = input < 0.0f\n        ? -snapshot->clipperAsymmetryTrimDB\n        : snapshot->clipperAsymmetryTrimDB;\n    float driven = input * snapshot->clipperDriveLinear * db_to_linear(polarityTrimDB);\n    float sign = driven < 0.0f ? -1.0f : 1.0f;\n''', 'clipper asymmetry processing')

marker = 'void N60ProtectionProcessStereoFrame(\n'
idx = s.index(marker)
rider_fn = r'''static void update_gain_rider(
    N60ProtectionRuntime *runtime,
    const N60ProtectionSnapshot *snapshot
) {
    float instantaneousGRDB = snapshot->limiterEnabled
        ? fmaxf(0.0f, -linear_to_db(fminf(runtime->limiterGain, 1.0f)))
        : 0.0f;
    runtime->sustainedLimiterGainReductionDB = instantaneousGRDB
        + snapshot->gainRiderMeasurementCoefficient
            * (runtime->sustainedLimiterGainReductionDB - instantaneousGRDB);

    float desiredAttenuationDB = 0.0f;
    if (snapshot->gainRiderEnabled && snapshot->limiterEnabled) {
        // Integral-style correction: once sustained limiter GR settles at the
        // requested target, attenuation is held instead of collapsing back to 0.
        float errorDB = runtime->sustainedLimiterGainReductionDB - snapshot->gainRiderTargetGRDB;
        desiredAttenuationDB = fminf(snapshot->gainRiderMaxReductionDB,
            fmaxf(0.0f, runtime->gainRiderAttenuationDB + errorDB));
    }
    runtime->gainRiderAttenuationDB = desiredAttenuationDB
        + snapshot->gainRiderResponseCoefficient
            * (runtime->gainRiderAttenuationDB - desiredAttenuationDB);
    runtime->telemetry.gainRiderAttenuationDB = runtime->gainRiderAttenuationDB;
    runtime->telemetry.sustainedLimiterGainReductionDB = runtime->sustainedLimiterGainReductionDB;
    runtime->telemetry.truePeakGuardActive = snapshot->limiterEnabled && snapshot->truePeakGuardEnabled;
}

'''
s = s[:idx] + rider_fn + s[idx:]
s = replace_once(s, '''    if (runtime == NULL || snapshot == NULL || left == NULL || right == NULL) return;\n\n    N60OversamplingFactor factor = snapshot->effectiveFactor;\n''', '''    if (runtime == NULL || snapshot == NULL || left == NULL || right == NULL) return;\n\n    update_gain_rider(runtime, snapshot);\n    float riderGain = db_to_linear(-runtime->gainRiderAttenuationDB);\n    *left *= riderGain;\n    *right *= riderGain;\n\n    N60OversamplingFactor factor = snapshot->effectiveFactor;\n''', 'rider pre-protection gain')
write(p, s)

# --- DynamicsConfiguration.swift ---
p = 'NotchSixty/Audio/DynamicsConfiguration.swift'
s = read(p)
s = replace_once(s, '''    case invalidSoftClipper\n    case invalidLimiter\n    case invalidOversampling\n''', '''    case invalidSoftClipper\n    case invalidLimiter\n    case invalidGainRider\n    case invalidAutomaticHeadroom\n    case invalidOversampling\n''', 'swift error cases')
s = replace_once(s, '''        case .invalidLimiter:\n            return "Limiter parameters are outside the supported production range."\n        case .invalidOversampling:\n''', '''        case .invalidLimiter:\n            return "Limiter parameters are outside the supported production range."\n        case .invalidGainRider:\n            return "Dynamic Gain Rider parameters are outside the supported production range."\n        case .invalidAutomaticHeadroom:\n            return "Automatic Headroom parameters are outside the supported production range."\n        case .invalidOversampling:\n''', 'swift error descriptions')
s = replace_once(s, '''    static let kneeRange = 0.0...1.0\n\n    var enabled = false\n''', '''    static let kneeRange = 0.0...1.0\n    static let asymmetryTrimRange = -3.0...3.0\n\n    var enabled = false\n''', 'clipper trim range')
s = replace_once(s, '''    var curve: SoftClipperCurve = .quadratic\n    var autoCompensateGain = true\n\n    func validate() throws {\n        guard driveDB.isFinite, Self.driveRange.contains(driveDB),\n              thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB),\n              kneeSmooth.isFinite, Self.kneeRange.contains(kneeSmooth) else {\n''', '''    var curve: SoftClipperCurve = .quadratic\n    var autoCompensateGain = true\n    var asymmetryTrimDB = 0.0\n\n    func validate() throws {\n        guard driveDB.isFinite, Self.driveRange.contains(driveDB),\n              thresholdDB.isFinite, Self.thresholdRange.contains(thresholdDB),\n              kneeSmooth.isFinite, Self.kneeRange.contains(kneeSmooth),\n              asymmetryTrimDB.isFinite, Self.asymmetryTrimRange.contains(asymmetryTrimDB) else {\n''', 'clipper trim config')
s = replace_once(s, '''    var releaseMs = 20.0\n    var lookAheadMs = 2.0\n\n    func validate() throws {\n''', '''    var releaseMs = 20.0\n    var lookAheadMs = 2.0\n    // True preserves the accepted PR27 behavior: limiter reconstruction is 4x.\n    var truePeakGuardEnabled = true\n\n    func validate() throws {\n''', 'TP guard config')
insert_after = '''struct LimiterConfiguration: Equatable, Sendable {'''
# Insert rider/headroom structs after the whole limiter struct by locating next DynamicsConfiguration.
pos = s.index('struct DynamicsConfiguration: Equatable, Sendable {')
extra = r'''enum GainRiderSpeed: String, CaseIterable, Identifiable, Sendable {
    case fast
    case medium
    case slow
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var cType: N60GainRiderSpeed {
        switch self {
        case .fast: return N60GainRiderSpeedFast
        case .medium: return N60GainRiderSpeedMedium
        case .slow: return N60GainRiderSpeedSlow
        }
    }
}

struct GainRiderConfiguration: Equatable, Sendable {
    static let targetRange = 0.5...6.0
    static let maxReductionRange = 3.0...12.0
    var enabled = false
    var targetGainReductionDB = 3.0
    var maxReductionDB = 6.0
    var speed: GainRiderSpeed = .medium

    func validate() throws {
        guard targetGainReductionDB.isFinite, Self.targetRange.contains(targetGainReductionDB),
              maxReductionDB.isFinite, Self.maxReductionRange.contains(maxReductionDB) else {
            throw DynamicsConfigurationError.invalidGainRider
        }
    }
}

struct AutomaticHeadroomConfiguration: Equatable, Sendable {
    static let maxAttenuationRange = 3.0...24.0
    // Disabled by default in the commercial validation build so accepted PR25–32
    // listening baselines are not silently attenuated; production presets can opt in.
    var enabled = false
    var maxAttenuationDB = 12.0

    func validate() throws {
        guard maxAttenuationDB.isFinite, Self.maxAttenuationRange.contains(maxAttenuationDB) else {
            throw DynamicsConfigurationError.invalidAutomaticHeadroom
        }
    }
}

'''
s = s[:pos] + extra + s[pos:]
s = replace_once(s, '''    var softClipper = SoftClipperConfiguration()\n    var limiter = LimiterConfiguration()\n    var oversampling: OversamplingFactor = .one\n''', '''    var softClipper = SoftClipperConfiguration()\n    var limiter = LimiterConfiguration()\n    var gainRider = GainRiderConfiguration()\n    var automaticHeadroom = AutomaticHeadroomConfiguration()\n    var oversampling: OversamplingFactor = .one\n''', 'dynamics protection fields')
s = replace_once(s, '''        try softClipper.validate()\n        try limiter.validate()\n        guard sampleRate.isFinite''', '''        try softClipper.validate()\n        try limiter.validate()\n        try gainRider.validate()\n        try automaticHeadroom.validate()\n        guard sampleRate.isFinite''', 'protection validations')
s = replace_once(s, '''        guard N60ProtectionSnapshotSetSoftClipper(\n            &snapshot,\n            softClipper.enabled,\n            Float(softClipper.driveDB),\n            Float(softClipper.thresholdDB),\n            Float(softClipper.kneeSmooth),\n            softClipper.curve.cType,\n            softClipper.autoCompensateGain\n        ) else { throw DynamicsConfigurationError.invalidSoftClipper }\n        guard N60ProtectionSnapshotSetLimiter(\n            &snapshot,\n            limiter.enabled,\n            Float(limiter.ceilingDB),\n            Float(limiter.attackMs),\n            Float(limiter.releaseMs),\n            Float(limiter.lookAheadMs)\n        ) else { throw DynamicsConfigurationError.invalidLimiter }\n        return snapshot\n''', '''        guard N60ProtectionSnapshotSetSoftClipperAdvanced(\n            &snapshot,\n            softClipper.enabled,\n            Float(softClipper.driveDB),\n            Float(softClipper.thresholdDB),\n            Float(softClipper.kneeSmooth),\n            softClipper.curve.cType,\n            softClipper.autoCompensateGain,\n            Float(softClipper.asymmetryTrimDB)\n        ) else { throw DynamicsConfigurationError.invalidSoftClipper }\n        guard N60ProtectionSnapshotSetLimiterAdvanced(\n            &snapshot,\n            limiter.enabled,\n            Float(limiter.ceilingDB),\n            Float(limiter.attackMs),\n            Float(limiter.releaseMs),\n            Float(limiter.lookAheadMs),\n            limiter.truePeakGuardEnabled\n        ) else { throw DynamicsConfigurationError.invalidLimiter }\n        guard N60ProtectionSnapshotSetGainRider(\n            &snapshot,\n            gainRider.enabled,\n            Float(gainRider.targetGainReductionDB),\n            Float(gainRider.maxReductionDB),\n            gainRider.speed.cType\n        ) else { throw DynamicsConfigurationError.invalidGainRider }\n        return snapshot\n''', 'advanced protection snapshot')
write(p, s)

# --- StereoPlaybackControl.swift: predictive headroom before EQ ---
p = 'NotchSixty/Audio/StereoPlaybackControl.swift'
s = read(p)
anchor = '''    func makeGraphSnapshot(\n        sampleRate: Double,\n'''
helper = r'''    private func conservativeAutomaticHeadroomDB(
        dynamics: DynamicsConfiguration
    ) -> Double {
        guard dynamics.automaticHeadroom.enabled else { return 0 }

        func channelBoost(_ bands: [EQBand]) -> Double {
            bands.lazy.filter(\.enabled).reduce(0.0) { partial, band in
                partial + max(0.0, band.gainDB)
            }
        }
        let staticBoost: Double
        if bypassed {
            staticBoost = 0
        } else {
            switch channelMode {
            case .linked: staticBoost = channelBoost(linkedBands)
            case .independent: staticBoost = max(channelBoost(leftBands), channelBoost(rightBands))
            }
        }

        let dynamicBoost = dynamics.dynamicEQ.enabled
            ? dynamics.dynamicEQ.bands.lazy.filter(\.enabled).reduce(0.0) { partial, band in
                let staticPart = max(0.0, band.staticGainDB)
                let dynamicPart = band.direction == .cutOnly ? 0.0 : max(0.0, band.maxBoostDB)
                return partial + staticPart + dynamicPart
            }
            : 0.0
        return min(dynamics.automaticHeadroom.maxAttenuationDB, staticBoost + dynamicBoost)
    }

'''
s = replace_once(s, anchor, helper + anchor, 'auto headroom helper')
s = replace_once(s, '''        graph.inputGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.inputPreampDB)\n        graph.headroomGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.headroomAttenuationDB)\n        graph.outputGainLinear''', '''        graph.inputGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.inputPreampDB)\n        let automaticHeadroomDB = playbackConfiguration.globalBypassed\n            ? 0.0 : conservativeAutomaticHeadroomDB(dynamics: dynamicsConfiguration)\n        graph.headroomGainLinear = DSPGainConfiguration.linearGain(\n            forDB: gainConfiguration.headroomAttenuationDB - automaticHeadroomDB)\n        graph.outputGainLinear''', 'apply predictive headroom')
write(p, s)

# --- ProtectionTests.swift ---
p = 'NotchSixtyTests/ProtectionTests.swift'
s = read(p)
insert = s.rfind('\n}')
new_tests = r'''

    func testTruePeakGuardControlsForcedFourTimesPath() {
        var guarded = N60ProtectionSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60ProtectionSnapshotSetOversamplingFactor(&guarded, N60OversamplingFactor1x))
        XCTAssertTrue(N60ProtectionSnapshotSetLimiterAdvanced(&guarded, true, -1, 0.1, 50, 2, true))
        XCTAssertEqual(guarded.effectiveFactor, N60OversamplingFactor4x)

        var unguarded = N60ProtectionSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60ProtectionSnapshotSetOversamplingFactor(&unguarded, N60OversamplingFactor2x))
        XCTAssertTrue(N60ProtectionSnapshotSetLimiterAdvanced(&unguarded, true, -1, 0.1, 50, 2, false))
        XCTAssertEqual(unguarded.effectiveFactor, N60OversamplingFactor2x)
    }

    func testClipperAsymmetryTrimIsBoundedAndZeroTrimPreservesSymmetry() {
        for trim: Float in [0, 3, -3] {
            var snapshot = N60ProtectionSnapshotMakeBypassed(96_000)
            XCTAssertTrue(N60ProtectionSnapshotSetSoftClipperAdvanced(
                &snapshot, true, 6, -2, 1, N60ClipperCurveQuadratic, false, trim))
            guard let runtime = N60ProtectionRuntimeCreate() else { return XCTFail("runtime") }
            defer { N60ProtectionRuntimeDestroy(runtime) }
            var positive: Float = 0.7
            var positiveRight = positive
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &positive, &positiveRight)
            N60ProtectionRuntimeReset(runtime)
            var negative: Float = -0.7
            var negativeRight = negative
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &negative, &negativeRight)
            XCTAssertTrue(positive.isFinite && negative.isFinite)
            XCTAssertLessThanOrEqual(abs(positive), 1.000_001)
            XCTAssertLessThanOrEqual(abs(negative), 1.000_001)
            if trim == 0 {
                XCTAssertEqual(abs(positive), abs(negative), accuracy: 0.000_001)
            } else {
                XCTAssertGreaterThan(abs(abs(positive) - abs(negative)), 0.005)
            }
        }
    }

    func testGainRiderIgnoresTransientButRespondsToSustainedLimiting() {
        var snapshot = N60ProtectionSnapshotMakeBypassed(48_000)
        XCTAssertTrue(N60ProtectionSnapshotSetLimiterAdvanced(&snapshot, true, -1, 0.1, 20, 1, true))
        XCTAssertTrue(N60ProtectionSnapshotSetGainRider(&snapshot, true, 1.0, 6.0, N60GainRiderSpeedFast))
        guard let runtime = N60ProtectionRuntimeCreate() else { return XCTFail("runtime") }
        defer { N60ProtectionRuntimeDestroy(runtime) }

        for frame in 0..<48_000 {
            let amp: Float = frame < 240 ? 1.4 : 0.2
            var left = amp * Float(sin(2 * Double.pi * 997 * Double(frame) / 48_000))
            var right = -left
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
        }
        let afterTransient = N60ProtectionRuntimeTelemetry(runtime).gainRiderAttenuationDB
        XCTAssertLessThan(afterTransient, 0.15)

        for frame in 0..<(48_000 * 5) {
            var left = Float(1.5 * sin(2 * Double.pi * 997 * Double(frame) / 48_000))
            var right = -left
            N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
        }
        let telemetry = N60ProtectionRuntimeTelemetry(runtime)
        XCTAssertGreaterThan(telemetry.gainRiderAttenuationDB, 0.25)
        XCTAssertLessThanOrEqual(telemetry.gainRiderAttenuationDB, 6.001)
        XCTAssertGreaterThan(telemetry.sustainedLimiterGainReductionDB, 0)
    }

    func testGainRiderSpeedOrdering() {
        func attenuation(_ speed: N60GainRiderSpeed) -> Float {
            var snapshot = N60ProtectionSnapshotMakeBypassed(48_000)
            XCTAssertTrue(N60ProtectionSnapshotSetLimiterAdvanced(&snapshot, true, -1, 0.1, 20, 0.5, false))
            XCTAssertTrue(N60ProtectionSnapshotSetGainRider(&snapshot, true, 0.5, 6.0, speed))
            guard let runtime = N60ProtectionRuntimeCreate() else { return -1 }
            defer { N60ProtectionRuntimeDestroy(runtime) }
            for frame in 0..<(48_000 * 3) {
                var left = Float(1.5 * sin(2 * Double.pi * 997 * Double(frame) / 48_000))
                var right = -left
                N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right)
            }
            return N60ProtectionRuntimeTelemetry(runtime).gainRiderAttenuationDB
        }
        let fast = attenuation(N60GainRiderSpeedFast)
        let medium = attenuation(N60GainRiderSpeedMedium)
        let slow = attenuation(N60GainRiderSpeedSlow)
        XCTAssertGreaterThan(fast, medium)
        XCTAssertGreaterThan(medium, slow)
    }

    func testGainProtectionConfigurationValidAt384k() throws {
        var config = DynamicsConfiguration()
        config.softClipper.asymmetryTrimDB = 3
        config.limiter.enabled = true
        config.limiter.truePeakGuardEnabled = true
        config.gainRider.enabled = true
        config.gainRider.targetGainReductionDB = 3
        config.gainRider.maxReductionDB = 6
        config.gainRider.speed = .slow
        config.automaticHeadroom.enabled = true
        config.automaticHeadroom.maxAttenuationDB = 24
        let snapshot = try config.makeProtectionSnapshot(sampleRate: 384_000)
        XCTAssertTrue(N60ProtectionSnapshotIsValid(&snapshot))
        XCTAssertEqual(snapshot.effectiveFactor, N60OversamplingFactor4x)
    }
'''
s = s[:insert] + new_tests + s[insert:]
write(p, s)

# --- StereoPlaybackControlTests.swift ---
p = 'NotchSixtyTests/StereoPlaybackControlTests.swift'
s = read(p)
insert = s.rfind('\n}')
new_test = r'''

    func testAutomaticHeadroomAddsPredictiveAttenuationAndRespectsCap() throws {
        var eq = StereoEQConfiguration()
        eq.linkedBands = [
            EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1, enabled: true),
            EQBand(type: .peaking, frequencyHz: 3_000, gainDB: 6, q: 1, enabled: true),
        ]
        var dynamics = DynamicsConfiguration()
        dynamics.automaticHeadroom.enabled = true
        dynamics.automaticHeadroom.maxAttenuationDB = 8
        let graph = try eq.makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: dynamics,
            playbackConfiguration: PlaybackControlConfiguration())
        let expected = Float(pow(10.0, -8.0 / 20.0))
        XCTAssertEqual(graph.headroomGainLinear, expected, accuracy: 0.000_001)
    }
'''
s = s[:insert] + new_test + s[insert:]
write(p, s)

# --- PR33 plan + provenance ---
p = 'docs/PR33_RESIDUAL_DYNAMICS_PARITY.md'
s = read(p)
s += r'''

## Slice 2 commercial semantics

The gain/protection controls share a single ownership model:

- **Predictive EQ/DSP headroom** is a control-plane pre-EQ attenuation. It is capped by the visible 3–24 dB maximum and is never applied during raw Global Bypass. The validation implementation is deliberately disabled by default so PR25–32 accepted listening baselines are not silently changed.
- **Dynamic Gain Rider** is a slow pre-protection attenuation driven only by sustained limiter gain reduction. Target GR is 0.5–6 dB, maximum rider cut is 3–12 dB, and Fast/Medium/Slow correspond to approximately 3/10/30 second response constants. It does not chase isolated transient peaks.
- **TP Guard** is an explicit limiter reconstruction-quality mode. ON preserves the accepted PR27 4x true-peak reconstruction path; OFF lets the limiter use the selected 1x/2x/4x protection factor instead of silently forcing 4x.
- **Clipper Asymmetry Trim** is an independent ±3 dB half-cycle drive trim around the existing clipper curve. Zero is sample-identical to the established clipper behavior.

No new limiter or duplicate hidden master-gain stage is introduced.
'''
write(p, s)

p = 'docs/PROVENANCE.md'
s = read(p)
s += r'''

## PR33 Slice 2 — gain/protection integration

Classification: **specification-derived / independently authored commercial implementation**.

Behavioral inventory references are limited to observable legacy configuration/UI state: Dynamic Gain Rider enable/target/max-cut/Fast-Medium-Slow controls; the distinct TP Guard toggle; ±3 dB clipper asymmetry trim; and EQ Headroom Compensation enable/3–24 dB maximum attenuation. Historical gain-rider, limiter, clipper, or EQ-headroom DSP implementations and historical DSP tests are not implementation references.

The commercial algorithms are derived independently from standard level/envelope smoothing, oversampled peak protection, bounded gain-riding, and pre-EQ gain-staging principles. The realtime path remains fixed/preallocated and performs no allocation, locking, logging, file/device/UI access, or coefficient/filter design.
'''
write(p, s)

print('PR33 Slice 2 patch applied')
