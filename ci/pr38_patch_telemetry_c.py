from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path, old, new):
    p = ROOT / path
    text = p.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"patch anchor count {text.count(old)} for {path}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


def apply():
    replace_once(
        "NotchSixty/Audio/Realtime/N60RenderKernel.h",
        "    float limiterGainReductionDB;\n    uint64_t limiterSafetyClampSamples;",
        "    float limiterGainReductionDB;\n    float gainRiderAttenuationDB;\n    float sustainedLimiterGainReductionDB;\n    bool truePeakGuardActive;\n    uint64_t limiterSafetyClampSamples;",
    )
    replace_once(
        "NotchSixty/Audio/Realtime/N60RenderKernel.c",
        "    _Atomic uint32_t limiterGainReductionBits;\n    _Atomic uint64_t limiterSafetyClampSamples;",
        "    _Atomic uint32_t limiterGainReductionBits;\n    _Atomic uint32_t gainRiderAttenuationBits;\n    _Atomic uint32_t sustainedLimiterGainReductionBits;\n    _Atomic bool truePeakGuardActive;\n    _Atomic uint64_t limiterSafetyClampSamples;",
    )
    replace_once(
        "NotchSixty/Audio/Realtime/N60RenderKernel.c",
        "        atomic_store_explicit(&kernel->limiterGainReductionBits, float_to_bits(protection.limiterGainReductionDB), memory_order_relaxed);\n        atomic_fetch_add_explicit(&kernel->limiterSafetyClampSamples, protection.limiterSafetyClampSamples, memory_order_relaxed);",
        "        atomic_store_explicit(&kernel->limiterGainReductionBits, float_to_bits(protection.limiterGainReductionDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->gainRiderAttenuationBits, float_to_bits(protection.gainRiderAttenuationDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->sustainedLimiterGainReductionBits, float_to_bits(protection.sustainedLimiterGainReductionDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->truePeakGuardActive, protection.truePeakGuardActive, memory_order_relaxed);\n        atomic_fetch_add_explicit(&kernel->limiterSafetyClampSamples, protection.limiterSafetyClampSamples, memory_order_relaxed);",
    )
    replace_once(
        "NotchSixty/Audio/Realtime/N60RenderKernel.c",
        "    diagnostics.limiterGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->limiterGainReductionBits, memory_order_relaxed));\n    diagnostics.limiterSafetyClampSamples = atomic_load_explicit(&kernel->limiterSafetyClampSamples, memory_order_relaxed);",
        "    diagnostics.limiterGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->limiterGainReductionBits, memory_order_relaxed));\n    diagnostics.gainRiderAttenuationDB = bits_to_float(atomic_load_explicit(&kernel->gainRiderAttenuationBits, memory_order_relaxed));\n    diagnostics.sustainedLimiterGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->sustainedLimiterGainReductionBits, memory_order_relaxed));\n    diagnostics.truePeakGuardActive = atomic_load_explicit(&kernel->truePeakGuardActive, memory_order_relaxed);\n    diagnostics.limiterSafetyClampSamples = atomic_load_explicit(&kernel->limiterSafetyClampSamples, memory_order_relaxed);",
    )
