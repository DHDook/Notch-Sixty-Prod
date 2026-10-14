#!/usr/bin/env python3
"""PR117A safety + numerical closure guard for 384-kHz active crossovers."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
header = (ROOT / "NotchSixty/Audio/Realtime/N60Crossover.h").read_text()
bridge = (ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c").read_text()
biquad = (ROOT / "NotchSixty/Audio/Realtime/N60Biquad.h").read_text()
probe = (ROOT / "ci/acoustic_reference_lab/pr117_production_probe.c").read_text()
reference = (ROOT / "ci/validate_pr117_acoustic_reference_lab.py").read_text()

def require(condition: bool, reason: str) -> None:
    if not condition:
        raise SystemExit("PR117A precision guard failed: " + reason)

for symbol in (
    "N60CrossoverPreciseCoefficients",
    "N60CrossoverPreciseState",
    "N60CrossoverPreciseDesign(",
    "N60CrossoverPreciseProcessSample(",
    "const double omega",
    "double z1, z2",
    "N60BiquadFilterTypeAllPass",
):
    require(symbol in header, symbol + " absent")
require("N60BiquadDesign(" not in header,
        "legacy float coefficient design reused in speaker crossover")
require("N60CrossoverPreciseState lowerLowLeft" in bridge,
        "physical crossover state not upgraded to double")
require("N60CrossoverPreciseProcessSample(" in bridge,
        "physical crossover runtime not using precise filter")
require("float b0;" in biquad and "float z1;" in biquad,
        "other DSP float ABI changed unintentionally")
require("print_precise_coeff" in probe and "%.17g" in probe,
        "independent production probe truncates double precision")
require("384000" in reference and "352800" in reference,
        "high-rate matrix removed from independent reference")
require("0.018" in reference and "coherent LR sum" in reference,
        "crossover accuracy gate weakened")
require("0.005" in reference,
        "explicit dB bounded PEQ reference lost")
require("N60RealtimeAudioBridgeConfigureSpeakerBusSplitter" in bridge,
        "speaker bus configuration removed")
require("N60ProtectedSpeakerBusRenderProgram(" in bridge,
        "protected driver test path removed")
require("N60SpeakerCrossoverModeMainsSub" in header and
        "N60SpeakerCrossoverModeBiAmp" in header and
        "N60SpeakerCrossoverModeTriAmp" in header,
        "speaker crossover mode missing")

print("PR117A bounded crossover precision and runtime ownership: PASS")
if "--source-only" not in sys.argv:
    completed = subprocess.run(
        [sys.executable, "ci/validate_pr117_acoustic_reference_lab.py"],
        cwd=ROOT, check=False)
    raise SystemExit(completed.returncode)
