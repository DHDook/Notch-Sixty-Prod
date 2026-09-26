from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"anchor not found: {label}")
    return text.replace(old, new, 1)

# The general EQ engine intentionally uses float coefficients/state. At 384 kHz,
# a 50/60 Hz high-Q cut places poles/zeros so close to z=1 that float coefficient
# quantization measurably reduces center depth. PR31 therefore uses a dedicated
# double-precision notch cascade for this numerically extreme, low-frequency tool.
# This is local to Mains Notch; the rest of the audio graph remains float.

h = Path('NotchSixty/Audio/Realtime/N60Dynamics.h')
text = h.read_text()
old = '''typedef struct {
    bool enabled;
    double fundamentalHz;
    uint32_t harmonicCount;
    float q;
    float depthsDB[N60_MAX_MAINS_HARMONICS];
    N60BiquadCoefficients filters[N60_MAX_MAINS_HARMONICS];
} N60MainsNotchSnapshot;
'''
new = '''typedef struct {
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
} N60MainsNotchCoefficients;

typedef struct {
    double z1;
    double z2;
} N60MainsNotchState;

typedef struct {
    bool enabled;
    double fundamentalHz;
    uint32_t harmonicCount;
    float q;
    float depthsDB[N60_MAX_MAINS_HARMONICS];
    N60MainsNotchCoefficients filters[N60_MAX_MAINS_HARMONICS];
} N60MainsNotchSnapshot;
'''
text = replace_once(text, old, new, 'double-precision notch snapshot')
text = text.replace(
    '    N60BiquadState mainsNotchLeft[N60_MAX_MAINS_HARMONICS];\n    N60BiquadState mainsNotchRight[N60_MAX_MAINS_HARMONICS];\n',
    '    N60MainsNotchState mainsNotchLeft[N60_MAX_MAINS_HARMONICS];\n    N60MainsNotchState mainsNotchRight[N60_MAX_MAINS_HARMONICS];\n',
    1,
)
h.write_text(text)

c = Path('NotchSixty/Audio/Realtime/N60Dynamics.c')
text = c.read_text()
anchor = '''static float process_filter_cascade(
    const N60BiquadCoefficients *coefficients,
    N60BiquadState *states,
    uint32_t sectionCount,
    float input
) {
    float output = input;
    for (uint32_t index = 0; index < sectionCount; ++index) {
        output = N60BiquadProcessSample(coefficients[index], &states[index], output);
    }
    return output;
}
'''
addition = anchor + '''
static N60MainsNotchCoefficients mains_notch_identity(void) {
    N60MainsNotchCoefficients coefficients = {
        .b0 = 1.0,
        .b1 = 0.0,
        .b2 = 0.0,
        .a1 = 0.0,
        .a2 = 0.0,
    };
    return coefficients;
}

static bool mains_notch_coefficients_are_finite(N60MainsNotchCoefficients coefficients) {
    return isfinite(coefficients.b0)
        && isfinite(coefficients.b1)
        && isfinite(coefficients.b2)
        && isfinite(coefficients.a1)
        && isfinite(coefficients.a2);
}

// Control-plane design for a narrow peaking cut. Double coefficients are kept
// through the realtime section because 50/60 Hz at 384 kHz is an unusually low
// normalized frequency where float coefficient quantization loses several dB of
// requested notch depth. This function is never called from the render callback.
static bool design_mains_notch(
    double sampleRate,
    double frequencyHz,
    double depthDB,
    double q,
    N60MainsNotchCoefficients *coefficients
) {
    if (coefficients == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz <= 0.0 || frequencyHz >= sampleRate * 0.5
        || !isfinite(depthDB) || depthDB < -40.0 || depthDB > 0.0
        || !isfinite(q) || q < 5.0 || q > 60.0) return false;

    double omega = 2.0 * M_PI * frequencyHz / sampleRate;
    double alpha = sin(omega) / (2.0 * q);
    double A = pow(10.0, depthDB / 40.0);
    double cosOmega = cos(omega);
    double a0 = 1.0 + alpha / A;
    if (!isfinite(a0) || fabs(a0) < 1.0e-20) return false;

    N60MainsNotchCoefficients designed = {
        .b0 = (1.0 + alpha * A) / a0,
        .b1 = (-2.0 * cosOmega) / a0,
        .b2 = (1.0 - alpha * A) / a0,
        .a1 = (-2.0 * cosOmega) / a0,
        .a2 = (1.0 - alpha / A) / a0,
    };
    if (!mains_notch_coefficients_are_finite(designed)) return false;
    *coefficients = designed;
    return true;
}

static float process_mains_notch_cascade(
    const N60MainsNotchCoefficients *coefficients,
    N60MainsNotchState *states,
    uint32_t sectionCount,
    float input
) {
    double output = (double)input;
    for (uint32_t index = 0; index < sectionCount; ++index) {
        N60MainsNotchCoefficients c = coefficients[index];
        N60MainsNotchState *state = &states[index];
        double next = c.b0 * output + state->z1;
        state->z1 = c.b1 * output - c.a1 * next + state->z2;
        state->z2 = c.b2 * output - c.a2 * next;
        output = next;
    }
    return (float)output;
}
'''
text = replace_once(text, anchor, addition, 'precision helpers')

text = text.replace(
    'snapshot.mainsNotch.filters[index] = N60BiquadCoefficientsMakeIdentity();',
    'snapshot.mainsNotch.filters[index] = mains_notch_identity();'
)
text = text.replace(
    'configured.filters[index] = N60BiquadCoefficientsMakeIdentity();',
    'configured.filters[index] = mains_notch_identity();'
)
old_design = '''        if (!N60BiquadDesign(
                N60BiquadFilterTypePeaking,
                sampleRate,
                harmonicHz,
                depthDB,
                q,
                &configured.filters[index])) return false;'''
new_design = '''        if (!design_mains_notch(
                sampleRate,
                harmonicHz,
                depthDB,
                q,
                &configured.filters[index])) return false;'''
text = replace_once(text, old_design, new_design, 'dedicated notch design')
text = text.replace(
    '|| !N60BiquadCoefficientsAreFinite(snapshot.mainsNotch.filters[index])) return false;',
    '|| !mains_notch_coefficients_are_finite(snapshot.mainsNotch.filters[index])) return false;',
    1,
)
text = text.replace(
    'float notchLeft = process_filter_cascade(\n        snapshot.mainsNotch.filters,',
    'float notchLeft = process_mains_notch_cascade(\n        snapshot.mainsNotch.filters,',
    1,
)
text = text.replace(
    'float notchRight = process_filter_cascade(\n        snapshot.mainsNotch.filters,',
    'float notchRight = process_mains_notch_cascade(\n        snapshot.mainsNotch.filters,',
    1,
)
c.write_text(text)

# Record why this isolated double-precision path exists.
prov = Path('docs/PROVENANCE.md')
text = prov.read_text()
needle = 'The first slice implements the static harmonic-notch signal path independently from standard parametric-biquad mathematics already present in the commercial engine.'
if needle in text and 'numerically extreme low normalized frequencies' not in text:
    text = text.replace(
        needle,
        needle + ' Mains-notch coefficients and states are intentionally double precision because 50/60 Hz high-Q filters at 384 kHz operate at numerically extreme low normalized frequencies; float coefficient quantization measurably reduces requested center depth.',
        1,
    )
prov.write_text(text)
