#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import platform
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROFILE = ROOT / "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift"
CALIBRATION = ROOT / "NotchSixty/Audio/Routing/OutputDeviceCalibration.swift"
BRIDGING = ROOT / "NotchSixty/Audio/Realtime/NotchSixty-Bridging-Header.h"
REALTIME = ROOT / "NotchSixty/Audio/Realtime"


def require(value: bool, message: str) -> None:
    if not value:
        raise SystemExit(f"PR64 profile behavior failed: {message}")


def main() -> None:
    if platform.system() != "Darwin":
        print("PR64 calibrated profile Swift harness skipped off macOS")
        return
    xcrun = shutil.which("xcrun")
    require(xcrun is not None, "xcrun is required")

    stubs = r'''
import Foundation

enum MultiOutputSynchronizationMode: String, Codable, Sendable {
    case automatic
    case aggregateDevice
    case softwarePLL
}

struct PhysicalOutputEndpoint: Codable, Equatable, Hashable, Sendable {
    var deviceUID: String
    var channelIndex: UInt32
}

struct AudioOutputDevice: Sendable {
    let uid: String
    let outputChannelCount: UInt32
    let minimumSampleRate: Double
    let maximumSampleRate: Double

    func supports(sampleRate: Double) -> Bool {
        sampleRate >= minimumSampleRate && sampleRate <= maximumSampleRate
    }
}
'''

    program = r'''
import Foundation

func endpoint(_ channel: UInt32) -> PhysicalOutputEndpoint {
    PhysicalOutputEndpoint(deviceUID: "avr", channelIndex: channel)
}

let device = AudioOutputDevice(
    uid: "avr", outputChannelCount: 16,
    minimumSampleRate: 44_100, maximumSampleRate: 192_000
)
let layout = OutputProgramLayout.sevenOneFour
let speakers = layout.roles.filter { $0 != .lowFrequencyEffects }.enumerated().map {
    SemanticSpeakerOutputAssignment(
        role: $0.element,
        destination: endpoint(UInt32($0.offset)),
        calibration: SemanticSpeakerCalibration(
            trimDB: $0.offset == 0 ? -2.5 : 0,
            delayMilliseconds: $0.offset == 0 ? 1.25 : 0,
            polarityInverted: false,
            eqBands: $0.offset == 0
                ? [OutputCalibrationEQBand(frequencyHz: 1000, gainDB: -2, q: 1)]
                : []
        )
    )
}
let subs = [
    PhysicalSubwooferOutputAssignment(
        index: 0, destination: endpoint(11),
        calibration: PhysicalSubwooferCalibration(
            gainDB: -1.5, delayMilliseconds: 2.0,
            polarityInverted: false,
            eqBands: [OutputCalibrationEQBand(frequencyHz: 55, gainDB: -3, q: 1.2)]
        )
    ),
    PhysicalSubwooferOutputAssignment(
        index: 1, destination: endpoint(12),
        calibration: PhysicalSubwooferCalibration(gainDB: -3.0, delayMilliseconds: 4.0)
    ),
]
let summary = MultichannelCalibrationDeploymentSummary(
    measuredAt: Date(timeIntervalSince1970: 100),
    deployedAt: Date(timeIntervalSince1970: 200),
    seatCount: 3,
    speakerCount: speakers.count,
    subwooferCount: 2,
    targetName: "Neutral",
    sampleRate: 96_000,
    maximumSpeakerErrorBeforeDB: 6.0,
    maximumSpeakerErrorAfterDB: 2.0,
    multiSubObjective: 1.2
)
let profile = OutputDeviceProfileConfiguration(
    enabled: true,
    programLayout: layout,
    speakerAssignments: speakers,
    subwooferAssignments: subs,
    referenceDeviceUID: "avr",
    calibrationSummary: summary
)
try profile.validateStructure(bassManagementEnabled: true)
precondition(profile.systemDisplayName == "7.2.4")
let plan = try profile.makeLivePlan(
    availableDevices: [device], sampleRate: 96_000,
    selectedOutputUID: "avr", bassManagementEnabled: true
)
precondition(plan.programLayout == .sevenOneFour)
precondition(plan.subwooferCount == 2)
precondition(plan.speakerCalibrations[.frontLeft]?.trimDB == -2.5)
precondition(plan.speakerCalibrations[.frontLeft]?.eqBands.count == 1)
precondition(plan.subwooferCalibrations[0]?.gainDB == -1.5)
precondition(plan.subwooferCalibrations[1]?.delayMilliseconds == 4.0)
_ = try plan.makeRealtimeOutputMap()

// Optional PR64 fields must not break pre-PR64 archives. Remove them from an
// encoded current profile and prove synthesized decoding fills nil.
let encoder = JSONEncoder()
let encoded = try encoder.encode(profile)
var root = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
root.removeValue(forKey: "calibrationSummary")
if var speakerObjects = root["speakerAssignments"] as? [[String: Any]] {
    for index in speakerObjects.indices { speakerObjects[index].removeValue(forKey: "calibration") }
    root["speakerAssignments"] = speakerObjects
}
if var subObjects = root["subwooferAssignments"] as? [[String: Any]] {
    for index in subObjects.indices { subObjects[index].removeValue(forKey: "calibration") }
    root["subwooferAssignments"] = subObjects
}
let legacyData = try JSONSerialization.data(withJSONObject: root)
let legacy = try JSONDecoder().decode(OutputDeviceProfileConfiguration.self, from: legacyData)
precondition(legacy.calibrationSummary == nil)
precondition(legacy.speakerAssignments.allSatisfy { $0.calibration == nil })
precondition(legacy.subwooferAssignments.allSatisfy { $0.calibration == nil })
try legacy.validateStructure(bassManagementEnabled: true)

// Positive digital calibration gain is forbidden by the product deployment contract.
var invalid = profile
invalid.speakerAssignments[0].calibration?.trimDB = 1.0
do {
    try invalid.validateStructure(bassManagementEnabled: true)
    fatalError("expected positive calibration trim to be rejected")
} catch OutputDeviceCalibrationError.invalidSpeakerCalibration {
    // expected
}

print("PR64 calibrated profile Swift behavior harness passed")
'''

    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr64-profile-") as directory:
        temp = pathlib.Path(directory)
        stubs_path = temp / "Stubs.swift"
        main_path = temp / "main.swift"
        binary = temp / "pr64-profile-harness"
        stubs_path.write_text(stubs, encoding="utf-8")
        main_path.write_text(program, encoding="utf-8")
        subprocess.run([
            xcrun, "swiftc", "-O",
            "-import-objc-header", str(BRIDGING),
            "-Xcc", f"-I{REALTIME}",
            str(stubs_path), str(CALIBRATION), str(PROFILE), str(main_path),
            "-framework", "CoreAudio", "-o", str(binary),
        ], check=True, cwd=ROOT)
        subprocess.run([str(binary)], check=True, cwd=ROOT)


if __name__ == "__main__":
    main()
