#!/usr/bin/env python3
"""PR117D: verify real SOFA fixture pipeline and the existing importer boundary.

Real HDF5 decoding and generated-fixture assertions execute on Apple Silicon
in XCTest. This script is a cheap inherited source/safety contract, not a
substitute for file import.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GEN = ROOT / "ci/generate_pr117d_sofa_fixtures.py"
TEST = ROOT / "NotchSixtyTests/NativeSOFAImporterTests.swift"
WORKFLOW = ROOT / ".github/workflows/pr117d-real-sofa-import.yml"
BRIDGE = ROOT / "NotchSixty/Audio/SOFA/N60SOFABridge.c"
IMPORTER = ROOT / "NotchSixty/Audio/SOFA/NativeSOFAImporter.swift"
GUARD = ROOT / "ci/validate_pr85_native_sofa.py"


def check(condition, message):
    if not condition:
        raise AssertionError("PR117D real SOFA regression contract: " + message)


g = GEN.read_text()
t = TEST.read_text()
w = WORKFLOW.read_text()
c = BRIDGE.read_text()
s = IMPORTER.read_text()
check(GUARD.is_file(), "inherited original importer contract absent")
for value in ("384000.", "48000.", "44100.", "np.nan",
              "Data.Delay", "Data.IR", "SourcePosition", "CC0-1.0"):
    check(value in g, "fixture missing " + value)
for name in (
    "testPR117DReal384kHzSOFAIntegerDelayAndPersistence",
    "testPR117DRealSOFAFractionalDelayIsBakedWithoutDroppingEnergy",
    "testPR117DRealSOFANegativeDelayPreservesRelativeTiming",
    "testPR117DRealSOFANonfiniteIRFailsClosed",
    "PR117D_SOFA_FIXTURE_DIR",
    "BinauralProfileAssetStore",
):
    check(name in t, "native test missing " + name)
for key in ("netCDF4", "numpy", "xcodebuild", "PR117D_SOFA_FIXTURE_DIR"):
    check(key in w, "macOS real-file CI missing " + key)
# A full cumulative XCTest invocation is a stronger acceptance gate than
# invoking only the NativeSOFAImporterTests class. Do not demand an obsolete
# "-only-testing" string when the consolidated batch intentionally runs ALL
# tests with PR85/PR117D fixture environment variables configured.
focused_sofa = "NativeSOFAImporterTests" in w
all_tests = (
    "xcodebuild" in w and "test" in w
    and "-only-testing:" not in w
    and "PR85_SOFA_FIXTURE" in w
    and "PR117D_SOFA_FIXTURE_DIR" in w
)
check(focused_sofa or all_tests,
      "macOS real-file acceptance needs targeted SOFA or full XCTest")
for key in ("N60SOFAStatusNonFiniteData", "mysofa_tocartesian",
            "N60_SOFA_MAX_FILE_BYTES"):
    check(key in c, "read-side safety missing " + key)
for key in ("delayBakeCommonOffsetSamples", "fractionalDelayKernelRadius",
            "NativeSOFAImporter", "SOFABinauralAssetAdapter"):
    check(key in s, "normalization boundary missing " + key)
check("mysofa_load" not in (ROOT / "NotchSixty/Audio/Realtime/N60BinauralRenderer.h").read_text(),
      "SOFA parser unexpectedly called on realtime thread")
check(not list(ROOT.rglob("*.sofa")), "generated SOFA data cannot be checked into repository")
print("PR117D real-file SOFA fixture and inherited import ownership: PASS")
