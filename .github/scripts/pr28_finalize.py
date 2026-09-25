from pathlib import Path

path = Path("NotchSixty/Audio/Realtime/N60Dynamics.c")
text = path.read_text()
old = '''    // Cascaded Butterworth-style biquads. Each section uses Q=1/sqrt(2),
    // yielding deterministic steep protection with no control-plane work in RT.
    for (uint32_t index = 0; index < sectionCount; ++index) {
        if (!N60BiquadDesign(
                N60BiquadFilterTypeHighPass,
                sampleRate,
                cutoffHz,
                0.0,
                0.7071067811865476,
                &configured.highPass[index])) return false;
    }
'''
new = '''    // Exact even-order Butterworth pole-pair Q values. For order N and
    // section k, Q = 1 / (2*cos((2k+1)*pi/(2N))). Coefficients are prepared
    // on the control plane; the realtime callback only consumes them.
    uint32_t order = sectionCount * 2;
    for (uint32_t index = 0; index < sectionCount; ++index) {
        double angle = ((2.0 * (double)index + 1.0) * M_PI) / (2.0 * (double)order);
        double q = 1.0 / (2.0 * cos(angle));
        if (!isfinite(q) || q <= 0.0
            || !N60BiquadDesign(
                N60BiquadFilterTypeHighPass,
                sampleRate,
                cutoffHz,
                0.0,
                q,
                &configured.highPass[index])) return false;
    }
'''
if old not in text:
    raise RuntimeError("missing infrasonic Q block")
path.write_text(text.replace(old, new, 1))

# pr28_expand.py uses a raw Python string for the generated Swift view, so its
# format specifier quotes need one final normalization pass after generation.
path = Path("NotchSixty/NotchSixtyApp.swift")
text = path.read_text()
text = text.replace('specifier: \\"%.0f\\"', 'specifier: "%.0f"')
text = text.replace('specifier: \\"%.2f\\"', 'specifier: "%.2f"')
path.write_text(text)
