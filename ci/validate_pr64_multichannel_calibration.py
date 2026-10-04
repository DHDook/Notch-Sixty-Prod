#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift"
CALIBRATION = ROOT / "NotchSixty/Audio/Routing/OutputDeviceCalibration.swift"
DESIGNER = ROOT / "NotchSixty/Audio/MultichannelCalibrationDesigner.swift"
SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
TRANSPORT = ROOT / "NotchSixty/Audio/CoreAudio/MultichannelCalibrationTransport.swift"
ANALYZER = ROOT / "NotchSixty/Audio/RoomCorrectionMeasurementAnalyzer.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"


def require(value: bool, message: str) -> None:
    if not value:
        raise SystemExit(f"PR64 validation failed: {message}")


def main() -> None:
    for path in (PROFILE, CALIBRATION, DESIGNER, SESSION, TRANSPORT, ANALYZER, PROJECT):
        require(path.exists(), f"missing {path}")

    profile = PROFILE.read_text()
    calibration = CALIBRATION.read_text()
    designer = DESIGNER.read_text()
    session = SESSION.read_text()
    transport = TRANSPORT.read_text()
    analyzer = ANALYZER.read_text()
    project = PROJECT.read_text()

    require("var calibration: SemanticSpeakerCalibration?" in profile,
            "speaker calibration is not persisted with semantic assignment")
    require("var calibration: PhysicalSubwooferCalibration?" in profile,
            "subwoofer calibration is not persisted with physical Sub N assignment")
    require("var calibrationSummary: MultichannelCalibrationDeploymentSummary?" in profile,
            "profile deployment summary is missing")
    require("speakerCalibrations:" in profile and "subwooferCalibrations:" in profile,
            "live route plan does not carry calibration")

    require("gainRangeDB = -18.0...0.0" in calibration,
            "deployed PEQ is not attenuation-only")
    require("trimRangeDB = -24.0...0.0" in calibration,
            "speaker trim is not attenuation-only")
    require("gainRangeDB = -24.0...0.0" in calibration,
            "subwoofer gain is not attenuation-only")

    require("correctionSettings.maximumBoostDB = 0" in designer,
            "speaker designer permits positive correction boost")
    require("settings.maximumGainDB = 0" in designer and "settings.maximumEQDB = 0" in designer,
            "multi-sub deployment permits positive digital gain")
    require("subOptimizationFrequencies" in designer and "subFrequencies" in designer,
            "multi-sub optimizer is not isolated to a low-frequency matrix")
    require("N60MultiSubOptimize(\n                    &subMatrix" in designer,
            "multi-sub optimizer still targets the full-range speaker matrix")
    require("latestSubArrival" in designer and "speakerReference" in designer,
            "speaker/sub timing domains are not reconciled")

    require("N60ProgramLaneGraphSetDelayMs" in session,
            "live speaker delay calibration is not deployed")
    require("N60ProgramLaneGraphSetEQBand" in session,
            "live speaker PEQ calibration is not deployed")
    require("N60SubwooferOutputSetDelayMs" in session,
            "live subwoofer delay calibration is not deployed")
    require("N60SubwooferOutputSetUserEQBand" in session,
            "live subwoofer EQ calibration is not deployed")
    require("calibratedPolarity" in session,
            "live subwoofer polarity calibration is not composed")

    require("N60TargetedRoomMeasurementBridgeCreate" in transport,
            "targeted measurement transport does not use the PR58 realtime bridge")
    require("N60TargetedRoomMeasurementIOProc" in transport,
            "targeted measurement IOProc is not connected")
    require("physicalOutputChannelIndex" in transport,
            "targeted transport does not own an explicit physical output lane")
    require("routePlan.orderedDeviceUIDs" in transport,
            "targeted transport does not preserve the Output Device Profile device order")
    require("kAudioSubDeviceDriftCompensationKey" in transport,
            "multi-device calibration aggregate lacks drift-compensation policy")
    require("originalSampleRates" in transport and "restore calibration device sample rate" in transport,
            "temporary measurement sample-rate changes are not restored")
    require("snapshot.unsupportedBufferLayouts == 0" in transport,
            "unsupported callback layouts are not fail-closed before materialization")

    require("func analyzeSingleChannel(" in analyzer,
            "targeted one-speaker measurement analysis entry point is missing")

    require("OutputDeviceCalibration.swift in Sources" in project,
            "OutputDeviceCalibration.swift is not in app target")
    require("MultichannelCalibrationDesigner.swift in Sources" in project,
            "MultichannelCalibrationDesigner.swift is not in app target")
    require("MultichannelCalibrationTransport.swift in Sources" in project,
            "MultichannelCalibrationTransport.swift is not in app target")

    print("PR64 multichannel calibration integration validation passed")


if __name__ == "__main__":
    main()
