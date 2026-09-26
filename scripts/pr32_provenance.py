from pathlib import Path

p = Path('docs/PROVENANCE.md')
text = p.read_text()
marker = '## PR32 — Dynamics parity closure and dialogue processing'
if marker in text:
    raise SystemExit('PR32 provenance already present')
append = r'''

## PR32 — Dynamics parity closure and dialogue processing

- **Classification:** specification-derived / original commercial implementation.
- **Behavioral references:** historical Notch Sixty configuration and UI were used only to inventory externally observable control names, ranges, defaults, modes, and intended behavior for compressor topology/release/sidechain, De-Esser control depth, multiband control depth, and dialogue-relative leveling.
- **Excluded implementation references:** historical `DynamicsProcessor`, `DialogueRelativeLeveler`, historical dynamics helper implementations, and historical DSP tests were not used as coding templates, translated, or adapted.
- **Commercial implementation basis:** standard feed-forward/feed-back dynamics concepts, one-pole envelope smoothing, detector-only high-pass filtering, standard digital biquad mathematics, linked-stereo gain computation, RMS/power-domain level comparison, and independently derived bounded modulation-energy confidence estimation.
- **Slice 1:** extends the existing proprietary C dynamics core with compressor feed-forward/feed-back topology, precomputed program-dependent release behavior, detector-only sidechain HPF, De-Esser ratio/range/Q/timing controls, and independent/per-band multiband control depth. Existing accepted defaults remain neutral/compatible where practical.
- **Slice 2:** independently implements a dialogue-relative leveler that compares smoothed full-program energy with smoothed dialogue-band energy, reacts to excess masking gap, applies bounded boost only to the extracted dialogue band, and optionally scales correction with a speech-like syllabic-modulation confidence measure. The linked gain decision preserves stereo image.
- **Realtime contract:** fixed/preallocated state; immutable/precomputed snapshots; no allocation/free, locks, logging, file/device/UI access, filter design, or coefficient construction in the render callback; zero added algorithmic latency for PR32 stages.
- **Validation:** deterministic coverage includes high-rate finite operation, new-parameter validation, feed-back compressor stability, bounded De-Esser attenuation, multiband independent controls, dialogue disabled transparency, program gating, relative-masking response, maximum-boost bounds, and voice-confidence bounds. Full integration suites were green before the hardware gate.
- **Residual audit:** `docs/PR32_DYNAMICS_PARITY_AUDIT.md` explicitly routes remaining required observable items rather than silently omitting them. General Dynamic EQ, Dynamic Gain Rider/auto-headroom, explicit True-Peak Guard semantics, clipper asymmetry trim, per-band loudness, De-Harsh, and EQ/DSP automatic-headroom compensation are assigned to the immediately following parity PR before optimization.
'''
p.write_text(text.rstrip() + append.rstrip() + '\n')
print('PR32 provenance appended')
