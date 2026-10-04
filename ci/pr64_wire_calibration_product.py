#!/usr/bin/env python3
from pathlib import Path

APP = Path("NotchSixty/NotchSixtyApp.swift")
ROOT = Path("NotchSixty/UI/ProductionRootView.swift")


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one anchor, found {count}: {old[:120]!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")

# ProductController owns exactly one shared microphone controller; the new
# multichannel campaign reuses it rather than creating a second permission/device UX.
replace_once(
    APP,
    '''    let profiles: ProductProfileController
    let calibration: RoomCorrectionCalibrationController
    let roomCorrectionProjects: RoomCorrectionProjectController
    private var audioEngineObservation: AnyCancellable?
    private var calibrationObservation: AnyCancellable?
''',
    '''    let profiles: ProductProfileController
    let calibration: RoomCorrectionCalibrationController
    let multichannelCalibration: MultichannelCalibrationController
    let roomCorrectionProjects: RoomCorrectionProjectController
    private var audioEngineObservation: AnyCancellable?
    private var calibrationObservation: AnyCancellable?
    private var multichannelCalibrationObservation: AnyCancellable?
'''
)

replace_once(
    APP,
    '''    init() {
        let audioEngine = AudioIOEngine()
        let profiles = ProductProfileController(engine: audioEngine)
        self.audioEngine = audioEngine
        self.profiles = profiles
        self.calibration = RoomCorrectionCalibrationController(engine: audioEngine)
        self.roomCorrectionProjects = RoomCorrectionProjectController(profiles: profiles)
        observeAudioEngine()
    }
''',
    '''    init() {
        let audioEngine = AudioIOEngine()
        let profiles = ProductProfileController(engine: audioEngine)
        let calibration = RoomCorrectionCalibrationController(engine: audioEngine)
        self.audioEngine = audioEngine
        self.profiles = profiles
        self.calibration = calibration
        self.multichannelCalibration = MultichannelCalibrationController(
            engine: audioEngine,
            profiles: profiles,
            microphone: calibration
        )
        self.roomCorrectionProjects = RoomCorrectionProjectController(profiles: profiles)
        observeAudioEngine()
    }
'''
)

replace_once(
    APP,
    '''    init(audioEngine: AudioIOEngine) {
        let profiles = ProductProfileController(engine: audioEngine)
        self.audioEngine = audioEngine
        self.profiles = profiles
        self.calibration = RoomCorrectionCalibrationController(engine: audioEngine)
        self.roomCorrectionProjects = RoomCorrectionProjectController(profiles: profiles)
        observeAudioEngine()
    }
''',
    '''    init(audioEngine: AudioIOEngine) {
        let profiles = ProductProfileController(engine: audioEngine)
        let calibration = RoomCorrectionCalibrationController(engine: audioEngine)
        self.audioEngine = audioEngine
        self.profiles = profiles
        self.calibration = calibration
        self.multichannelCalibration = MultichannelCalibrationController(
            engine: audioEngine,
            profiles: profiles,
            microphone: calibration
        )
        self.roomCorrectionProjects = RoomCorrectionProjectController(profiles: profiles)
        observeAudioEngine()
    }
'''
)

replace_once(
    APP,
    '''        roomCorrectionProjects.prepareForUse()
        calibration.prepareForUse()
    }

    func shutdownForTermination() {
        calibration.cancelMeasurement()
        audioEngine.shutdownForTermination()
    }
''',
    '''        roomCorrectionProjects.prepareForUse()
        calibration.prepareForUse()
        multichannelCalibration.prepareForUse()
    }

    func shutdownForTermination() {
        multichannelCalibration.cancelMeasurement()
        calibration.cancelMeasurement()
        audioEngine.shutdownForTermination()
    }
'''
)

replace_once(
    APP,
    '''        calibrationObservation = calibration.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
''',
    '''        calibrationObservation = calibration.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        multichannelCalibrationObservation = multichannelCalibration.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
'''
)

# Add an appliance-style top-level workspace rather than exposing a DAW-like
# per-channel matrix in the normal listening screens.
replace_once(
    ROOT,
    '''    case activeCrossover
    case roomCorrection
''',
    '''    case activeCrossover
    case speakerCalibration
    case roomCorrection
'''
)
replace_once(
    ROOT,
    '''        case .activeCrossover: return "Active Crossover"
        case .roomCorrection: return "Room Correction"
''',
    '''        case .activeCrossover: return "Active Crossover"
        case .speakerCalibration: return "Speaker Calibration"
        case .roomCorrection: return "Room Correction"
'''
)
replace_once(
    ROOT,
    '''        case .activeCrossover: return "hifispeaker.2.fill"
        case .roomCorrection: return "waveform.badge.magnifyingglass"
''',
    '''        case .activeCrossover: return "hifispeaker.2.fill"
        case .speakerCalibration: return "scope"
        case .roomCorrection: return "waveform.badge.magnifyingglass"
'''
)
replace_once(
    ROOT,
    '''        case .activeCrossover:
            ProductionActiveCrossoverView(engine: engine, profiles: product.profiles)
        case .roomCorrection:
            ProductionRoomCorrectionWorkspace(
''',
    '''        case .activeCrossover:
            ProductionActiveCrossoverView(engine: engine, profiles: product.profiles)
        case .speakerCalibration:
            ProductionMultichannelCalibrationWorkspace(
                engine: engine,
                calibration: product.multichannelCalibration,
                microphone: product.calibration,
                profiles: product.profiles
            )
        case .roomCorrection:
            ProductionRoomCorrectionWorkspace(
'''
)

print("PR64 speaker calibration product wiring applied")
