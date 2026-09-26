from pathlib import Path

# C diagnostics contract.
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

# Swift diagnostics wrapper. Keep the public app-level snapshot in lock-step
# with the C diagnostics so validation UI never reaches around the wrapper.
path = Path("NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift")
text = path.read_text()

old = """    let balanceGainLeftLinear: Float
    let balanceGainRightLinear: Float
    let eqBypassed: Bool
    let eqBandCount: UInt32
"""
new = """    let balanceGainLeftLinear: Float
    let balanceGainRightLinear: Float
    let eqBypassed: Bool
    let mixedPhaseEnabled: Bool
    let mixedPhaseCorrectionSectionCount: UInt32
    let eqBandCount: UInt32
"""
if new not in text:
    if old not in text:
        raise SystemExit("Expected Swift RenderKernelDiagnostics declaration block was not found")
    text = text.replace(old, new, 1)

old = """        balanceGainLeftLinear = diagnostics.balanceGainLeftLinear
        balanceGainRightLinear = diagnostics.balanceGainRightLinear
        eqBypassed = diagnostics.eqBypassed
        eqBandCount = diagnostics.eqBandCount
"""
new = """        balanceGainLeftLinear = diagnostics.balanceGainLeftLinear
        balanceGainRightLinear = diagnostics.balanceGainRightLinear
        eqBypassed = diagnostics.eqBypassed
        mixedPhaseEnabled = diagnostics.mixedPhaseEnabled
        mixedPhaseCorrectionSectionCount = diagnostics.mixedPhaseCorrectionSectionCount
        eqBandCount = diagnostics.eqBandCount
"""
if new not in text:
    if old not in text:
        raise SystemExit("Expected Swift RenderKernelDiagnostics initializer block was not found")
    text = text.replace(old, new, 1)

path.write_text(text)
print("PR34 Mixed Phase C and Swift diagnostics bridges are present.")
