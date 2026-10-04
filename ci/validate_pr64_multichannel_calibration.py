#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift"
CALIBRATION = ROOT / "NotchSixty/Audio/Routing/OutputDeviceCalibration.swift"
DESIGNER = ROOT / "NotchSixty/Audio/MultichannelCalibrationDesigner.swift"
SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
TRANSPORT = ROOT / "NotchSixty/Audio/CoreAudio/MultichannelCalibrationTransport.swift"
CONTROLLER = ROOT / "NotchSixty/State/MultichannelCalibrationController.swift"
ANALYZER = ROOT / "NotchSixty/Audio/RoomCorrectionMeasurementAnalyzer.swift"
WORKSPACE = ROOT / "NotchSixty/UI/ProductionMultichannelCalibrationWorkspace.swift"
ROOT_VIEW = ROOT / "NotchSixty/UI/ProductionRootView.swift"
APP = ROOT / "NotchSixty/NotchSixtyApp.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"


def require(value: bool, message: str) -> None:
    if not value:
        raise SystemExit(f"PR64 validation failed: {message}")


def main() -> None:
    paths = (
        PROFILE, CALIBRATION, DESIGNER, SESSION, TRANSPORT, CONTROLLER,
        ANALYZER, WORKSPACE, ROOT_VIEW, APP, PROJECT,
    )
    for path in paths:
        require(path.exists(), f"missing {path}")

    profile = PROFILE.read_text()
    calibration = CALIBRATION.read_text()
    designer = DESIGNER.read_text()
    session = SESSION.read_text()
    transport = TRANSPORT.read_text()
    controller = CONTROLLER.read_text()
    analyzer = ANALYZER.read_text()
    workspace = WORKSPACE.read_text()
    root_view = ROOT_VIEW.read_text()
    app = APP.read_text()
    project = PROJECT.read_text()

    # Persistent Output Device Profile ownership and live deployment.
    require("var calibration: SemanticSpeakerCalibration?" in profile,
            "speaker calibration is not persisted with semantic assignment")
    require("var calibration: PhysicalSubwooferCalibration?" in profile,
            "subwoofer calibration is not persisted with physical Sub N assignment")
    require("var calibrationSummary: MultichannelCalibrationDeploymentSummary?" in profile,
            "profile deployment summary is missing")
    require("speakerCalibrations:" in profile and "subwooferCalibrations:" in profile,
            "live route plan does not carry calibration")

    # Product-safe correction policy: no positive digital calibration gain.
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

    # PR58 algorithms are used in the correct acoustic domains.
    require("subOptimizationFrequencies" in designer and "subFrequencies" in designer,
            "multi-sub optimizer is not isolated to a low-frequency matrix")
    require("N60MultiSubOptimize(\n                    &subMatrix" in designer,
            "multi-sub optimizer still targets the full-range speaker matrix")
    require("latestSubArrival" in designer and "speakerReference" in designer,
            "speaker/sub timing domains are not reconciled")

    # Live graph consumes the deployed calibration.
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

    # Targeted measurement transport is explicit and fail-closed.
    require("N60TargetedRoomMeasurementBridgeCreate" in transport,
            "targeted measurement transport does not use the PR58 realtime bridge")
    require("N60TargetedRoomMeasurementIOProc" in transport,
            "targeted measurement IOProc is not connected")
    require("physicalOutputChannelIndex" in transport,
            "targeted transport does not own an explicit physical output lane")
    require("routePlan.orderedDeviceUIDs" in transport,
            "targeted transport does not preserve Output Device Profile device order")
    require("kAudioSubDeviceDriftCompensationKey" in transport,
            "multi-device calibration aggregate lacks drift-compensation policy")
    require("originalSampleRates" in transport and "restore calibration device sample rate" in transport,
            "temporary measurement sample-rate changes are not restored")
    require("physicalInputChannelCount" in transport
            and "read physical measurement microphone channel count" in transport,
            "physical microphone channel is not validated before aggregate flattening")
    require("snapshot.unsupportedBufferLayouts == 0" in transport,
            "unsupported callback layouts are not fail-closed before materialization")
    require("func analyzeSingleChannel(" in analyzer,
            "targeted one-speaker measurement analysis entry point is missing")

    # Source x seat campaign, persistence, compact storage, and deployment.
    require("final class MultichannelCalibrationController" in controller,
            "campaign controller is missing")
    require("MultichannelCalibrationCampaignStore" in controller,
            "campaign persistence is missing")
    require("profile.programLayout.roles" in controller and ".filter { $0 != .lowFrequencyEffects }" in controller,
            "native LFE is being treated as a physical measurement source")
    require("profile.subwooferAssignments" in controller and "MultichannelCalibrationSource.subwoofer" in controller,
            "physical Sub N sources are not included in the campaign")
    require("engine.lifecycleState == .idle" in controller,
            "measurement does not require normal playback to be idle")
    require("compact.rawCapture = []" in controller,
            "campaign persistence retains full raw sweep buffers")
    require("multichannelCalibrationRoutingSignature" in controller,
            "campaign does not bind measurements to physical routing identity")
    require("profiles.replaceSelectedSystemOutputDeviceProfile(updated)" in controller,
            "calibration deployment bypasses Playback System profile ownership")
    require("finishMeasurementIfComplete() async throws" in controller,
            "asynchronous measure/analyze progression is missing")

    # Shipping product UI/ownership wiring.
    require('Text("Speaker Calibration")' in workspace,
            "speaker calibration workspace is missing its product surface")
    require("Measure Next" in workspace and "Generate Design" in workspace
            and "Deploy to Playback System" in workspace,
            "workspace does not expose measure/design/deploy workflow")
    require("case speakerCalibration" in root_view,
            "Speaker Calibration is not a production sidebar section")
    require("ProductionMultichannelCalibrationWorkspace(" in root_view,
            "production root does not open the calibration workspace")
    require("let multichannelCalibration: MultichannelCalibrationController" in app,
            "ProductController does not own the campaign controller")
    require("multichannelCalibration.prepareForUse()" in app,
            "campaign is not prepared with product startup")
    require("multichannelCalibration.cancelMeasurement()" in app,
            "campaign transport is not cancelled on app termination")

    # Build-system membership is explicit in this project.
    for source in (
        "OutputDeviceCalibration.swift in Sources",
        "MultichannelCalibrationDesigner.swift in Sources",
        "MultichannelCalibrationTransport.swift in Sources",
        "MultichannelCalibrationController.swift in Sources",
        "ProductionMultichannelCalibrationWorkspace.swift in Sources",
    ):
        require(source in project, f"{source.removesuffix(' in Sources')} is not in app target")

    print("PR64 multichannel calibration workflow validation passed")


if __name__ == "__main__":
    main()
