#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count == 0 and new in text:
        return text
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


def transform_function(text: str, name: str, snapshot_type: str, extra=None) -> str:
    marker = f"void {name}("
    start = text.find(marker)
    if start < 0:
        raise RuntimeError(f"{name}: function not found")
    brace = text.find("{", start)
    if brace < 0:
        raise RuntimeError(f"{name}: opening brace not found")
    depth = 0
    end = None
    for index in range(brace, len(text)):
        ch = text[index]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = index + 1
                break
    if end is None:
        raise RuntimeError(f"{name}: closing brace not found")
    region = text[start:end]
    by_value = f"{snapshot_type} snapshot"
    by_pointer = f"const {snapshot_type} *snapshot"
    if by_pointer not in region:
        if region.count(by_value) != 1:
            raise RuntimeError(f"{name}: snapshot signature match count {region.count(by_value)}")
        region = region.replace(by_value, by_pointer, 1)
    region = region.replace("snapshot.", "snapshot->")
    if extra is not None:
        region = extra(region)
    return text[:start] + region + text[end:]


def patch_dynamic_eq_header() -> None:
    path = ROOT / "NotchSixty/Audio/Realtime/N60DynamicEQ.h"
    text = path.read_text()
    old = """void N60DynamicEQProcessStereoFrame(\n    N60DynamicEQRuntime *runtime,\n    N60DynamicEQSnapshot snapshot,\n    float *left,\n    float *right\n);"""
    new = """void N60DynamicEQProcessStereoFrame(\n    N60DynamicEQRuntime *runtime,\n    const N60DynamicEQSnapshot *snapshot,\n    float *left,\n    float *right\n);"""
    text = replace_once(text, old, new, "N60DynamicEQ.h process prototype")
    path.write_text(text)


def patch_dynamic_eq_source() -> None:
    path = ROOT / "NotchSixty/Audio/Realtime/N60DynamicEQ.c"
    text = path.read_text()
    for name in ("process_linked_stereo", "process_primary_mono", "process_secondary_mono"):
        # Static helpers use the same snapshot ownership rule even though the generic
        # function locator keys on a void declaration.
        marker = f"static void {name}("
        start = text.find(marker)
        if start < 0:
            raise RuntimeError(f"{name}: helper not found")
        brace = text.find("{", start)
        depth = 0
        end = None
        for index in range(brace, len(text)):
            if text[index] == "{": depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    end = index + 1
                    break
        if end is None:
            raise RuntimeError(f"{name}: helper closing brace not found")
        region = text[start:end]
        if "const N60DynamicEQSnapshot *snapshot" not in region:
            if region.count("N60DynamicEQSnapshot snapshot") != 1:
                raise RuntimeError(f"{name}: snapshot signature mismatch")
            region = region.replace("N60DynamicEQSnapshot snapshot", "const N60DynamicEQSnapshot *snapshot", 1)
        region = region.replace("snapshot.", "snapshot->")
        text = text[:start] + region + text[end:]

    text = transform_function(text, "N60DynamicEQProcessStereoFrame", "N60DynamicEQSnapshot")
    path.write_text(text)


def patch_dynamics_header() -> None:
    path = ROOT / "NotchSixty/Audio/Realtime/N60Dynamics.h"
    text = path.read_text()
    names = (
        "N60DynamicsProcessPreEQStereoFrame",
        "N60DynamicsProcessDynamicEQStereoFrame",
        "N60DynamicsProcessCoreStereoFrame",
        "N60DynamicsProcessCoreStereoFrameWithMasterGain",
        "N60DynamicsProcessPauseGateStereoFrame",
        "N60DynamicsProcessStereoFrame",
    )
    for name in names:
        marker = f"void {name}("
        start = text.find(marker)
        if start < 0:
            raise RuntimeError(f"{name}: prototype not found")
        end = text.find(");", start)
        if end < 0:
            raise RuntimeError(f"{name}: prototype end not found")
        end += 2
        region = text[start:end]
        if "const N60DynamicsSnapshot * _Nonnull snapshot" not in region:
            region = region.replace(
                "N60DynamicsSnapshot snapshot",
                "const N60DynamicsSnapshot * _Nonnull snapshot",
                1,
            )
        text = text[:start] + region + text[end:]
    path.write_text(text)


def dynamics_dynamic_extra(region: str) -> str:
    region = region.replace(
        "N60DynamicEQProcessStereoFrame(&runtime->dynamicEQ, snapshot->dynamicEQ, left, right);",
        "N60DynamicEQProcessStereoFrame(&runtime->dynamicEQ, &snapshot->dynamicEQ, left, right);",
    )
    return region


def patch_dynamics_source() -> None:
    path = ROOT / "NotchSixty/Audio/Realtime/N60Dynamics.c"
    text = path.read_text()
    names = (
        "N60DynamicsProcessPreEQStereoFrame",
        "N60DynamicsProcessDynamicEQStereoFrame",
        "N60DynamicsProcessCoreStereoFrame",
        "N60DynamicsProcessCoreStereoFrameWithMasterGain",
        "N60DynamicsProcessPauseGateStereoFrame",
        "N60DynamicsProcessStereoFrame",
    )
    for name in names:
        text = transform_function(
            text,
            name,
            "N60DynamicsSnapshot",
            dynamics_dynamic_extra if name == "N60DynamicsProcessDynamicEQStereoFrame" else None,
        )
    path.write_text(text)


def patch_render_kernel() -> None:
    path = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.c"
    text = path.read_text()
    for name in (
        "N60DynamicsProcessPreEQStereoFrame",
        "N60DynamicsProcessDynamicEQStereoFrame",
        "N60DynamicsProcessCoreStereoFrameWithMasterGain",
        "N60DynamicsProcessPauseGateStereoFrame",
    ):
        old = f"{name}(&kernel->dynamicsRuntime, context->snapshot.dynamics,"
        new = f"{name}(&kernel->dynamicsRuntime, &context->snapshot.dynamics,"
        if new not in text:
            count = text.count(old)
            if count != 1:
                raise RuntimeError(f"N60RenderKernel.c {name}: expected one call, found {count}")
            text = text.replace(old, new, 1)
    stale = """            // Dynamic EQ remains a linked physical-stereo stage. Mid/Side does\n            // not create independent M/S dynamic detectors."""
    current = """            // Dynamic EQ follows the active EQ channel domain: linked stereo,\n            // independent L/R, or independent Mid/Side lanes before decode."""
    if current not in text:
        text = replace_once(text, stale, current, "N60RenderKernel.c dynamic EQ comment")
    path.write_text(text)


def patch_swift_tests() -> None:
    tests = ROOT / "NotchSixtyTests"
    function_names = (
        "N60DynamicsProcessPreEQStereoFrame",
        "N60DynamicsProcessDynamicEQStereoFrame",
        "N60DynamicsProcessCoreStereoFrame",
        "N60DynamicsProcessCoreStereoFrameWithMasterGain",
        "N60DynamicsProcessPauseGateStereoFrame",
        "N60DynamicsProcessStereoFrame",
    )
    for path in tests.glob("*.swift"):
        text = path.read_text()
        original = text
        # Existing tests conventionally name the C snapshot `snapshot`. Make those
        # local values mutable so Swift can form a temporary pointer to them.
        if any(name in text for name in function_names):
            text = text.replace("let snapshot = N60DynamicsSnapshotMakeBypassed", "var snapshot = N60DynamicsSnapshotMakeBypassed")
            text = text.replace("let snapshot = try DynamicsConfiguration().makeSnapshot", "var snapshot = try DynamicsConfiguration().makeSnapshot")
            text = text.replace("let snapshot = try config.makeSnapshot", "var snapshot = try config.makeSnapshot")
            for name in function_names:
                text = text.replace(f"{name}(&runtime, snapshot,", f"{name}(&runtime, &snapshot,")
        if text != original:
            path.write_text(text)


def main() -> None:
    patch_dynamic_eq_header()
    patch_dynamic_eq_source()
    patch_dynamics_header()
    patch_dynamics_source()
    patch_render_kernel()
    patch_swift_tests()


if __name__ == "__main__":
    main()
