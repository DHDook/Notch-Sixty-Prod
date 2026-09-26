from pathlib import Path

path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
text = path.read_text()

old = """    float balanceGainLeftLinear;
    float balanceGainRightLinear;
    bool eqBypassed;
    bool eqMidSideMode;
    uint32_t eqBandCount;
    uint32_t eqLeftBandCount;
    uint32_t eqRightBandCount;
"""
new = """    float balanceGainLeftLinear;
    float balanceGainRightLinear;
    bool eqBypassed;
    bool eqMidSideMode;
    bool mixedPhaseEnabled;
    uint32_t mixedPhaseCorrectionSectionCount;
    uint32_t eqBandCount;
    uint32_t eqLeftBandCount;
    uint32_t eqRightBandCount;
"""

if new not in text:
    if old not in text:
        raise SystemExit("Expected N60RenderKernelDiagnostics EQ block was not found")
    text = text.replace(old, new, 1)

path.write_text(text)
print("PR34 Mixed Phase diagnostics bridge is present.")
