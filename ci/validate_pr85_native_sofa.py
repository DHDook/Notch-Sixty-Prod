#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs/PR85_NATIVE_SOFA_AES69.md"
BRIDGE_H = ROOT / "NotchSixty/Audio/SOFA/N60SOFABridge.h"
BRIDGE_C = ROOT / "NotchSixty/Audio/SOFA/N60SOFABridge.c"
IMPORTER = ROOT / "NotchSixty/Audio/SOFA/NativeSOFAImporter.swift"
ASSET = ROOT / "NotchSixty/Audio/Routing/BinauralProfileAsset.swift"
PBX = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
BRIDGING = ROOT / "NotchSixty/Audio/Realtime/NotchSixty-Bridging-Header.h"
TESTS = ROOT / "NotchSixtyTests/NativeSOFAImporterTests.swift"
GENERATOR = ROOT / "ci/generate_pr85_sofa_fixture.py"
VENDOR = ROOT / "NotchSixty/Audio/SOFA/Vendor/libmysofa"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR85 validation failed: {message}")


doc = DOC.read_text()
bridge_h = BRIDGE_H.read_text()
bridge_c = BRIDGE_C.read_text()
importer = IMPORTER.read_text()
asset = ASSET.read_text()
pbx = PBX.read_text()
bridging = BRIDGING.read_text()
tests = TESTS.read_text()

require((VENDOR / "LICENSE").exists(), "vendored BSD license is missing")
license_text = (VENDOR / "LICENSE").read_text()
require(
    "Redistribution and use in source and binary forms" in license_text,
    "vendored libmysofa license is not the expected BSD notice",
)
require(
    "v1.3.4" in (VENDOR / "README_NOTCH_SIXTY.md").read_text(),
    "vendored libmysofa provenance is not pinned to v1.3.4",
)

for path in (
    "hrtf/reader.c",
    "hrtf/tools.c",
    "hrtf/spherical.c",
    "hrtf/mysofa.h",
    "hdf/reader.h",
    "hdf/superblock.c",
    "hdf/dataobject.c",
    "hdf/btree.c",
    "hdf/fractalhead.c",
    "hdf/gunzip.c",
    "hdf/gcol.c",
):
    require((VENDOR / path).exists(), f"vendored reader file missing: {path}")

for token in (
    "N60SOFADocumentOpen",
    "N60SOFADocumentGetMetadata",
    "N60SOFADocumentCopySourcePosition",
    "N60SOFADocumentCopyEmitterPosition",
    "N60SOFADocumentGetDelaySamples",
    "N60SOFADocumentCopyImpulseResponse",
):
    require(token in bridge_h, f"native bridge API missing {token}")

for token in (
    'strcmp(dataType, "FIR")',
    'strcmp(dataType, "FIR-E")',
    "N60_SOFA_MAX_FILE_BYTES",
    "N60_SOFA_MAX_IR_VALUES",
    "N60SOFASafeMultiply",
    "mysofa_tocartesian",
    "N60SOFAStatusNonFiniteData",
):
    require(token in bridge_c, f"native reader hardening missing {token}")

for token in (
    "struct SOFAFIRDataset",
    "struct NativeSOFAImporter",
    "struct SOFABinauralAssetAdapter",
    "SOFAListenerFrame",
    "delayBakeCommonOffsetSamples",
    "fractionalDelayKernelRadius",
    "lanczos",
    "N60_BINAURAL_MAX_TAPS",
):
    require(token in importer, f"Swift SOFA normalization missing {token}")

require(
    'sourceURL.pathExtension.lowercased() == "sofa"' in asset,
    "asset store does not route native .sofa import",
)
require(
    "NativeSOFAImporter()" in asset
    and "SOFABinauralAssetAdapter()" in asset,
    "asset store bypasses native SOFA normalization boundary",
)
require(
    "importProvenance: SOFAImportProvenance? = nil" in asset,
    "normalized assets do not retain optional SOFA provenance",
)

for token in (
    "NativeSOFAImporter.swift in Sources",
    "N60SOFABridge.c in Sources",
    "libmysofa reader.c in Sources",
    '"-lz"',
):
    require(token in pbx, f"Xcode integration missing {token}")
require(
    '#import "../SOFA/N60SOFABridge.h"' in bridging,
    "Swift bridging header does not expose SOFA bridge",
)

for token in (
    "testListenerFrameMapsSOFALeftToRendererNegativeAzimuth",
    "testIntegerDelayBakePreservesRelativeReceiverTiming",
    "testFractionalDelayBakeIsFiniteAndPreservesDCWeight",
    "testBinauralAdapterRejectsMultipleEmittersWithoutLosingGenericDataset",
    "testNativeGeneratedSOFAFixtureLoadsEndToEnd",
):
    require(token in tests, f"SOFA test coverage missing {token}")
require(GENERATOR.exists(), "license-clean generated SOFA fixture script missing")

sofa_files = list(ROOT.rglob("*.sofa"))
require(
    not sofa_files,
    "repository must not redistribute unreviewed SOFA datasets: "
    + ", ".join(str(path.relative_to(ROOT)) for path in sofa_files),
)

for phrase in (
    "SimpleFreeFieldHRIR",
    "GeneralFIR",
    "GeneralFIR-E",
    "Data.Delay",
    "realtime",
    "BSD-3-Clause",
):
    require(phrase in doc, f"PR85 contract missing {phrase}")

# Prevent the realtime source directory from growing a hidden SOFA parser.
for path in (ROOT / "NotchSixty/Audio/Realtime").glob("*"):
    if path.is_file():
        text = path.read_text(errors="ignore").lower()
        require(
            "mysofa_load" not in text and "hdf5" not in text,
            f"realtime source unexpectedly parses SOFA/HDF: {path.name}",
        )

print("PR85 native AES69/SOFA infrastructure validation passed")
