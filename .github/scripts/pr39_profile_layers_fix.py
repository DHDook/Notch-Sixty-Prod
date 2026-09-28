from pathlib import Path
import re


def add_codable(path: str, names: list[str]) -> None:
    p = Path(path)
    text = p.read_text()
    for name in names:
        pattern = re.compile(rf"((?:enum|struct)\s+{re.escape(name)}\s*:\s*[^\n{{]*?)Sendable(\s*{{)")
        match = pattern.search(text)
        if not match:
            raise SystemExit(f"Codable declaration target {name} not found in {path}")
        if "Codable" in match.group(0):
            continue
        text = text[:match.start()] + match.group(1) + "Codable, Sendable" + match.group(2) + text[match.end():]
    p.write_text(text)


add_codable(
    "NotchSixty/Audio/DynamicsConfiguration.swift",
    [
        "StereoProcessingMode",
        "StereoWidenerConfiguration",
        "DCOffsetFilterConfiguration",
        "InfrasonicSlope",
        "InfrasonicFilterConfiguration",
        "MainsRegion",
        "MainsNotchConfiguration",
        "SpectralDenoiserPreset",
        "SpectralDenoiserQuality",
        "SpectralDenoiserProfileCommand",
        "SpectralDenoiserConfiguration",
        "LoudnessMatchConfiguration",
        "LoudnessLevelSource",
        "LoudnessContourConfiguration",
        "DeHarshConfiguration",
        "DialogueVoiceGateConfiguration",
        "DialogueRelativeLevelerConfiguration",
        "DynamicEQDirection",
        "DynamicEQDetectorMode",
        "DynamicEQBandConfiguration",
        "DynamicEQConfiguration",
        "DeEsserConfiguration",
        "MultibandSlope",
        "MultibandCompressorConfiguration",
        "CompressorTopology",
        "CompressorConfiguration",
        "ExpanderConfiguration",
        "PauseGatePresetParameters",
        "PauseGatePreset",
        "PauseGateConfiguration",
        "OversamplingFactor",
        "SoftClipperCurve",
        "SoftClipperConfiguration",
        "LimiterConfiguration",
        "GainRiderSpeed",
        "GainRiderConfiguration",
        "AutomaticHeadroomConfiguration",
        "DynamicsConfiguration",
    ],
)

# Denoiser capture/reset are control-plane commands, not reusable preset state.
profiles_path = Path("NotchSixty/State/ProductProfiles.swift")
profiles = profiles_path.read_text()
old = '''        let gain = engine.gainConfiguration
        return ContentPresetState(
            stereoEQ: eq,
            inputPreampDB: gain.inputPreampDB,
            headroomAttenuationDB: gain.headroomAttenuationDB,
            dynamics: engine.dynamicsConfiguration
        )
'''
new = '''        let gain = engine.gainConfiguration
        var dynamics = engine.dynamicsConfiguration
        dynamics.spectralDenoiser.profileCommand = .none
        return ContentPresetState(
            stereoEQ: eq,
            inputPreampDB: gain.inputPreampDB,
            headroomAttenuationDB: gain.headroomAttenuationDB,
            dynamics: dynamics
        )
'''
if old not in profiles:
    raise SystemExit("Content preset capture block not found")
profiles_path.write_text(profiles.replace(old, new, 1))
