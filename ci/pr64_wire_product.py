#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one exact seam, found {count}: {old[:100]!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


app = Path("NotchSixty/NotchSixtyApp.swift")
root = Path("NotchSixty/UI/ProductionRootView.swift")
project = Path("NotchSixty.xcodeproj/project.pbxproj")

replace_once(
    app,
    '''    let calibration: RoomCorrectionCalibrationController\n    let roomCorrectionProjects: RoomCorrectionProjectController\n    private var audioEngineObservation: AnyCancellable?\n    private var calibrationObservation: AnyCancellable?\n''',
    '''    let calibration: RoomCorrectionCalibrationController\n    let multichannelCalibration: MultichannelCalibrationController\n    let roomCorrectionProjects: RoomCorrectionProjectController\n    private var audioEngineObservation: AnyCancellable?\n    private var calibrationObservation: AnyCancellable?\n    private var multichannelCalibrationObservation: AnyCancellable?\n'''
)

old_init = '''    init() {\n        let audioEngine = AudioIOEngine()\n        let profiles = ProductProfileController(engine: audioEngine)\n        self.audioEngine = audioEngine\n        self.profiles = profiles\n        self.calibration = RoomCorrectionCalibrationController(engine: audioEngine)\n        self.roomCorrectionProjects = RoomCorrectionProjectController(profiles: profiles)\n        observeAudioEngine()\n    }\n\n    init(audioEngine: AudioIOEngine) {\n        let profiles = ProductProfileController(engine: audioEngine)\n        self.audioEngine = audioEngine\n        self.profiles = profiles\n        self.calibration = RoomCorrectionCalibrationController(engine: audioEngine)\n        self.roomCorrectionProjects = RoomCorrectionProjectController(profiles: profiles)\n        observeAudioEngine()\n    }\n'''
new_init = '''    init() {\n        let audioEngine = AudioIOEngine()\n        let profiles = ProductProfileController(engine: audioEngine)\n        let calibration = RoomCorrectionCalibrationController(engine: audioEngine)\n        self.audioEngine = audioEngine\n        self.profiles = profiles\n        self.calibration = calibration\n        self.multichannelCalibration = MultichannelCalibrationController(\n            engine: audioEngine,\n            profiles: profiles,\n            microphone: calibration\n        )\n        self.roomCorrectionProjects = RoomCorrectionProjectController(profiles: profiles)\n        observeAudioEngine()\n    }\n\n    init(audioEngine: AudioIOEngine) {\n        let profiles = ProductProfileController(engine: audioEngine)\n        let calibration = RoomCorrectionCalibrationController(engine: audioEngine)\n        self.audioEngine = audioEngine\n        self.profiles = profiles\n        self.calibration = calibration\n        self.multichannelCalibration = MultichannelCalibrationController(\n            engine: audioEngine,\n            profiles: profiles,\n            microphone: calibration\n        )\n        self.roomCorrectionProjects = RoomCorrectionProjectController(profiles: profiles)\n        observeAudioEngine()\n    }\n'''
replace_once(app, old_init, new_init)

replace_once(
    app,
    '''        roomCorrectionProjects.prepareForUse()\n        calibration.prepareForUse()\n''',
    '''        roomCorrectionProjects.prepareForUse()\n        calibration.prepareForUse()\n        multichannelCalibration.prepareForUse()\n'''
)
replace_once(
    app,
    '''    func shutdownForTermination() {\n        calibration.cancelMeasurement()\n        audioEngine.shutdownForTermination()\n    }\n''',
    '''    func shutdownForTermination() {\n        multichannelCalibration.cancelMeasurement()\n        calibration.cancelMeasurement()\n        audioEngine.shutdownForTermination()\n    }\n'''
)
replace_once(
    app,
    '''        calibrationObservation = calibration.objectWillChange.sink { [weak self] _ in\n            self?.objectWillChange.send()\n        }\n''',
    '''        calibrationObservation = calibration.objectWillChange.sink { [weak self] _ in\n            self?.objectWillChange.send()\n        }\n        multichannelCalibrationObservation = multichannelCalibration.objectWillChange.sink { [weak self] _ in\n            self?.objectWillChange.send()\n        }\n'''
)

replace_once(
    root,
    '''    case activeCrossover\n    case roomCorrection\n''',
    '''    case activeCrossover\n    case speakerCalibration\n    case roomCorrection\n'''
)
replace_once(
    root,
    '''        case .activeCrossover: return "Active Crossover"\n        case .roomCorrection: return "Room Correction"\n''',
    '''        case .activeCrossover: return "Active Crossover"\n        case .speakerCalibration: return "Speaker Calibration"\n        case .roomCorrection: return "Room Correction"\n'''
)
replace_once(
    root,
    '''        case .activeCrossover: return "hifispeaker.2.fill"\n        case .roomCorrection: return "waveform.badge.magnifyingglass"\n''',
    '''        case .activeCrossover: return "hifispeaker.2.fill"\n        case .speakerCalibration: return "speaker.wave.3.fill"\n        case .roomCorrection: return "waveform.badge.magnifyingglass"\n'''
)
replace_once(
    root,
    '''        case .activeCrossover:\n            ProductionActiveCrossoverView(engine: engine, profiles: product.profiles)\n        case .roomCorrection:\n''',
    '''        case .activeCrossover:\n            ProductionActiveCrossoverView(engine: engine, profiles: product.profiles)\n        case .speakerCalibration:\n            ProductionMultichannelCalibrationWorkspace(\n                engine: engine,\n                calibration: product.multichannelCalibration,\n                microphone: product.calibration,\n                profiles: product.profiles\n            )\n        case .roomCorrection:\n'''
)

replace_once(
    project,
    '''\t\tF64000000000000000000003 /* MultichannelCalibrationTransport.swift in Sources */ = {isa = PBXBuildFile; fileRef = F64000000000000000000013 /* MultichannelCalibrationTransport.swift */; };\n''',
    '''\t\tF64000000000000000000003 /* MultichannelCalibrationTransport.swift in Sources */ = {isa = PBXBuildFile; fileRef = F64000000000000000000013 /* MultichannelCalibrationTransport.swift */; };\n\t\tF64000000000000000000004 /* MultichannelCalibrationController.swift in Sources */ = {isa = PBXBuildFile; fileRef = F64000000000000000000014 /* MultichannelCalibrationController.swift */; };\n\t\tF64000000000000000000005 /* ProductionMultichannelCalibrationWorkspace.swift in Sources */ = {isa = PBXBuildFile; fileRef = F64000000000000000000015 /* ProductionMultichannelCalibrationWorkspace.swift */; };\n'''
)
replace_once(
    project,
    '''\t\tF64000000000000000000013 /* MultichannelCalibrationTransport.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MultichannelCalibrationTransport.swift; sourceTree = "<group>"; };\n''',
    '''\t\tF64000000000000000000013 /* MultichannelCalibrationTransport.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MultichannelCalibrationTransport.swift; sourceTree = "<group>"; };\n\t\tF64000000000000000000014 /* MultichannelCalibrationController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MultichannelCalibrationController.swift; sourceTree = "<group>"; };\n\t\tF64000000000000000000015 /* ProductionMultichannelCalibrationWorkspace.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionMultichannelCalibrationWorkspace.swift; sourceTree = "<group>"; };\n'''
)
replace_once(
    project,
    '''\t\tA20000000000000000000054 /* State */ = {isa = PBXGroup; children = (A20000000000000000000025 /* AudioLifecycleState.swift */, A2000000000000000000002B /* ProductProfiles.swift */, A2000000000000000000002D /* RoomCorrectionCalibrationController.swift */, A2000000000000000000002F /* RoomCorrectionProjectController.swift */,); path = State; sourceTree = "<group>"; };\n''',
    '''\t\tA20000000000000000000054 /* State */ = {isa = PBXGroup; children = (A20000000000000000000025 /* AudioLifecycleState.swift */, A2000000000000000000002B /* ProductProfiles.swift */, F64000000000000000000014 /* MultichannelCalibrationController.swift */, A2000000000000000000002D /* RoomCorrectionCalibrationController.swift */, A2000000000000000000002F /* RoomCorrectionProjectController.swift */,); path = State; sourceTree = "<group>"; };\n'''
)
replace_once(
    project,
    '''\t\tA40000000000000000000050 /* UI */ = {isa = PBXGroup; children = (A40000000000000000000020 /* ProductionRootView.swift */, A40000000000000000000021 /* ProductionEqualizerView.swift */, A40000000000000000000022 /* ProductionDynamicsView.swift */, A40000000000000000000023 /* ProductionDynamicsTelemetryView.swift */, A40000000000000000000024 /* ProductionMetersView.swift */, A40000000000000000000025 /* ProductionAnalysisViews.swift */, A40000000000000000000026 /* ProductionProfileToolbar.swift */, A40000000000000000000027 /* ProductionRoomCorrectionWorkspace.swift */,); path = UI; sourceTree = "<group>"; };\n''',
    '''\t\tA40000000000000000000050 /* UI */ = {isa = PBXGroup; children = (A40000000000000000000020 /* ProductionRootView.swift */, A40000000000000000000021 /* ProductionEqualizerView.swift */, A40000000000000000000022 /* ProductionDynamicsView.swift */, A40000000000000000000023 /* ProductionDynamicsTelemetryView.swift */, A40000000000000000000024 /* ProductionMetersView.swift */, A40000000000000000000025 /* ProductionAnalysisViews.swift */, A40000000000000000000026 /* ProductionProfileToolbar.swift */, F64000000000000000000015 /* ProductionMultichannelCalibrationWorkspace.swift */, A40000000000000000000027 /* ProductionRoomCorrectionWorkspace.swift */,); path = UI; sourceTree = "<group>"; };\n'''
)
replace_once(
    project,
    '''\t\t\t\tF64000000000000000000003 /* MultichannelCalibrationTransport.swift in Sources */,\n\t\t\t\tA20000000000000000000015 /* AudioLifecycleState.swift in Sources */,\n''',
    '''\t\t\t\tF64000000000000000000003 /* MultichannelCalibrationTransport.swift in Sources */,\n\t\t\t\tF64000000000000000000004 /* MultichannelCalibrationController.swift in Sources */,\n\t\t\t\tF64000000000000000000005 /* ProductionMultichannelCalibrationWorkspace.swift in Sources */,\n\t\t\t\tA20000000000000000000015 /* AudioLifecycleState.swift in Sources */,\n'''
)

print("PR64 product wiring patch applied")
