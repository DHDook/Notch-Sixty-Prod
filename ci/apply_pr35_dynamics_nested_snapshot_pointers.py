#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
path = ROOT / "NotchSixty/Audio/Realtime/N60Dynamics.c"
text = path.read_text()


def rewrite_function(start_marker: str, end_marker: str, transform):
    global text
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    block = text[start:end]
    new = transform(block)
    if new == block:
        raise RuntimeError(f"no changes made for {start_marker}")
    text = text[:start] + new + text[end:]


def replace_once(old: str, new: str, label: str):
    global text
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one anchor, found {count}")
    text = text.replace(old, new, 1)

# Small target-law helpers are audio-rate and should not copy even modest configs.
rewrite_function(
    "static float compressor_target_gain_db(",
    "\nstatic float expander_target_gain_db(",
    lambda b: b.replace("N60CompressorSnapshot snapshot", "const N60CompressorSnapshot *snapshot").replace("snapshot.", "snapshot->"),
)
rewrite_function(
    "static float expander_target_gain_db(",
    "\nstatic float process_filter_cascade(",
    lambda b: b.replace("N60ExpanderSnapshot snapshot", "const N60ExpanderSnapshot *snapshot").replace("snapshot.", "snapshot->"),
)

# Mains-notch/detector snapshots include fixed arrays. Keep them referenced from the
# immutable parent snapshot rather than materializing copies for every audio frame.
rewrite_function(
    "static bool mains_notch_runtime_matches_snapshot(",
    "\nstatic void copy_mains_notch_snapshot_to_current(",
    lambda b: b.replace("N60MainsNotchSnapshot snapshot", "const N60MainsNotchSnapshot *snapshot").replace("snapshot.", "snapshot->"),
)
rewrite_function(
    "static void copy_mains_notch_snapshot_to_current(",
    "\nstatic void promote_pending_mains_notch(",
    lambda b: b.replace("N60MainsNotchSnapshot snapshot", "const N60MainsNotchSnapshot *snapshot").replace("snapshot.", "snapshot->"),
)
rewrite_function(
    "static void schedule_mains_notch_retune(",
    "\nstatic void reset_mains_detector_window(",
    lambda b: b.replace("N60MainsNotchSnapshot snapshot", "const N60MainsNotchSnapshot *snapshot").replace("snapshot.", "snapshot->")
        .replace("copy_mains_notch_snapshot_to_current(runtime, snapshot)", "copy_mains_notch_snapshot_to_current(runtime, snapshot)")
        .replace("mains_notch_runtime_matches_snapshot(runtime, snapshot)", "mains_notch_runtime_matches_snapshot(runtime, snapshot)"),
)
rewrite_function(
    "static void process_mains_hum_detector(",
    "\nstatic float dynamics_compression_target(",
    lambda b: b.replace("N60MainsHumDetectorSnapshot snapshot", "const N60MainsHumDetectorSnapshot *snapshot").replace("snapshot.", "snapshot->"),
)

# Update audio-rate callers for the pointer helper contracts.
text = text.replace("compressor_target_gain_db(linear_to_db(detector), compressor)", "compressor_target_gain_db(linear_to_db(detector), &compressor)")
text = text.replace("compressor_target_gain_db(detectorDB, snapshot->compressor)", "compressor_target_gain_db(detectorDB, &snapshot->compressor)")
text = text.replace("expander_target_gain_db(detectorDB, snapshot->expander)", "expander_target_gain_db(detectorDB, &snapshot->expander)")
text = text.replace("process_mains_hum_detector(runtime, snapshot->mainsHumDetector, dryLeft, dryRight)", "process_mains_hum_detector(runtime, &snapshot->mainsHumDetector, dryLeft, dryRight)")
text = text.replace("schedule_mains_notch_retune(runtime, snapshot->mainsNotch, retuneFrames)", "schedule_mains_notch_retune(runtime, &snapshot->mainsNotch, retuneFrames)")

# Larger local sub-snapshot copies are also unnecessary. The parent snapshot is
# immutable for the full render callback, so take typed const pointers instead.
for func, next_marker, typename, local, member in [
    ("static void process_stereo_widener(", "\nstatic void process_loudness_match(", "N60StereoWidenerSnapshot", "widener", "stereoWidener"),
    ("static void process_loudness_contour(", "\nstatic void process_de_harsh(", "N60LoudnessContourSnapshot", "config", "loudnessContour"),
    ("static void process_dialogue_leveler(", "\nstatic void process_de_esser(", "N60DialogueLevelerSnapshot", "config", "dialogueLeveler"),
    ("static void process_multiband_compressor(", "\nvoid N60DynamicsProcessDynamicEQStereoFrame(", "N60MultibandCompressorSnapshot", "multiband", "multibandCompressor"),
]:
    def make_transform(typename=typename, local=local, member=member):
        def transform(block: str) -> str:
            old = f"    {typename} {local} = snapshot->{member};"
            new = f"    const {typename} *{local} = &snapshot->{member};"
            if old not in block:
                raise RuntimeError(f"local copy anchor missing: {old}")
            block = block.replace(old, new, 1)
            block = block.replace(f"{local}.", f"{local}->")
            return block
        return transform
    rewrite_function(func, next_marker, make_transform())

# Sanity checks: none of the known realtime by-value patterns should remain.
forbidden = [
    "compressor_target_gain_db(float detectorDB, N60CompressorSnapshot snapshot)",
    "expander_target_gain_db(float detectorDB, N60ExpanderSnapshot snapshot)",
    "mains_notch_runtime_matches_snapshot(const N60DynamicsRuntime *runtime, N60MainsNotchSnapshot snapshot)",
    "copy_mains_notch_snapshot_to_current(N60DynamicsRuntime *runtime, N60MainsNotchSnapshot snapshot)",
    "schedule_mains_notch_retune(N60DynamicsRuntime *runtime, N60MainsNotchSnapshot snapshot",
    "N60MainsHumDetectorSnapshot snapshot,",
    "N60StereoWidenerSnapshot widener = snapshot->stereoWidener;",
    "N60LoudnessContourSnapshot config = snapshot->loudnessContour;",
    "N60DialogueLevelerSnapshot config = snapshot->dialogueLeveler;",
    "N60MultibandCompressorSnapshot multiband = snapshot->multibandCompressor;",
]
for needle in forbidden:
    if needle in text:
        raise RuntimeError(f"realtime snapshot copy remains: {needle}")

path.write_text(text)
