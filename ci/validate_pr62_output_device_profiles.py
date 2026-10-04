#!/usr/bin/env python3
"""Permanent PR62 guard for Output Device Profile semantics and persistence wiring."""

from __future__ import annotations

import pathlib
import platform
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROFILE = ROOT / "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift"
PRODUCT = ROOT / "NotchSixty/State/ProductProfiles.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
BRIDGING = ROOT / "NotchSixty/Audio/Realtime/NotchSixty-Bridging-Header.h"
REALTIME = ROOT / "NotchSixty/Audio/Realtime"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR62 validation failed: {message}")


def run_swift_behavior_harness() -> None:
    xcrun = shutil.which("xcrun")
    require(xcrun is not None, "xcrun is required on macOS")

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

    main = r'''
import Foundation

func endpoint(_ channel: UInt32, device: String = "avr") -> PhysicalOutputEndpoint {
    PhysicalOutputEndpoint(deviceUID: device, channelIndex: channel)
}

func expectError(_ expected: OutputDeviceProfileError, _ body: () throws -> Void) {
    do {
        try body()
        fatalError("Expected error \(expected)")
    } catch let error as OutputDeviceProfileError {
        precondition(error == expected, "Unexpected error \(error), expected \(expected)")
    } catch {
        fatalError("Unexpected non-profile error: \(error)")
    }
}

let avr = AudioOutputDevice(
    uid: "avr",
    outputChannelCount: 16,
    minimumSampleRate: 44_100,
    maximumSampleRate: 192_000
)

let layout = OutputProgramLayout.sevenOneFour
let speakers = layout.roles
    .filter { $0 != .lowFrequencyEffects }
    .enumerated()
    .map { SemanticSpeakerOutputAssignment(role: $0.element, destination: endpoint(UInt32($0.offset))) }
let subs = [
    PhysicalSubwooferOutputAssignment(index: 0, destination: endpoint(11)),
    PhysicalSubwooferOutputAssignment(index: 1, destination: endpoint(12)),
]
let profile = OutputDeviceProfileConfiguration(
    enabled: true,
    programLayout: layout,
    speakerAssignments: speakers,
    subwooferAssignments: subs,
    synchronizationMode: .automatic,
    referenceDeviceUID: "avr"
)
try profile.validateStructure(bassManagementEnabled: true)
let plan = try profile.makeLivePlan(
    availableDevices: [avr],
    sampleRate: 96_000,
    selectedOutputUID: "avr",
    bassManagementEnabled: true
)
precondition(plan.programLayout == .sevenOneFour)
precondition(plan.physicalChannelCount == 16)
precondition(plan.subwooferCount == 2)
precondition(!plan.usesMultiplePhysicalDevices)
var map = try plan.makeRealtimeOutputMap()
precondition(map.valid)
precondition(map.bassManagementEnabled)
precondition(map.subwooferCount == 2)
precondition(map.physicalChannelCount == 16)
withUnsafePointer(to: &map.physicalChannelForProgram) { tuple in
    tuple.withMemoryRebound(to: UInt32.self, capacity: Int(N60_MAX_PROGRAM_CHANNELS)) { channels in
        precondition(channels[3] == UInt32.max, "semantic LFE must remain unmapped after bass management")
    }
}
withUnsafePointer(to: &map.physicalChannelForSubwoofer) { tuple in
    tuple.withMemoryRebound(to: UInt32.self, capacity: Int(N60_MAX_SUBWOOFER_OUTPUTS)) { channels in
        precondition(channels[0] == 11)
        precondition(channels[1] == 12)
    }
}

// 3.1 is a valid custom semantic program layout even though the C core does not
// need another canonical enum identifier for it.
var threeOne = OutputProgramLayout.threeOne.realtimeLayout
precondition(threeOne.identifier == N60ProgramLayoutCustom)
precondition(threeOne.channelCount == 4)
precondition(N60ProgramChannelLayoutIsValid(&threeOne))

// A disabled/draft profile must fail closed at activation time.
var disabled = profile
disabled.enabled = false
expectError(.profileDisabled) {
    _ = try disabled.makeLivePlan(
        availableDevices: [avr],
        sampleRate: 96_000,
        selectedOutputUID: "avr",
        bassManagementEnabled: true
    )
}

// Native LFE can never be mapped to a physical speaker lane when PR55 bass
// management owns LFE -> Sub N routing.
var directLFE = profile
directLFE.speakerAssignments.append(
    SemanticSpeakerOutputAssignment(role: .lowFrequencyEffects, destination: endpoint(13))
)
expectError(.lfeMustBeUnmappedWhenBassManaged) {
    try directLFE.validateStructure(bassManagementEnabled: true)
}

// Conversely, bypassed bass management requires the semantic LFE lane to have
// an ordinary physical destination and forbids separate Sub N outputs.
let fiveOneSpeakers = OutputProgramLayout.fiveOne.roles.enumerated().map {
    SemanticSpeakerOutputAssignment(role: $0.element, destination: endpoint(UInt32($0.offset)))
}
let directFiveOne = OutputDeviceProfileConfiguration(
    enabled: true,
    programLayout: .fiveOne,
    speakerAssignments: fiveOneSpeakers
)
try directFiveOne.validateStructure(bassManagementEnabled: false)
var missingDirectLFE = directFiveOne
missingDirectLFE.speakerAssignments.removeAll { $0.role == .lowFrequencyEffects }
expectError(.lfePhysicalOutputRequired) {
    try missingDirectLFE.validateStructure(bassManagementEnabled: false)
}
var subsWithoutBass = directFiveOne
subsWithoutBass.subwooferAssignments = [
    PhysicalSubwooferOutputAssignment(index: 0, destination: endpoint(6))
]
expectError(.physicalSubwoofersRequireBassManagement) {
    try subsWithoutBass.validateStructure(bassManagementEnabled: false)
}

// Sub identities are dense and deterministic: Sub 1, Sub 2, ... with no gaps.
var sparseSubs = profile
sparseSubs.subwooferAssignments = [
    PhysicalSubwooferOutputAssignment(index: 0, destination: endpoint(11)),
    PhysicalSubwooferOutputAssignment(index: 2, destination: endpoint(12)),
]
expectError(.invalidPhysicalSubwooferIndex(2)) {
    try sparseSubs.validateStructure(bassManagementEnabled: true)
}

// Device capability checks happen before a route plan can become live.
expectError(.sampleRateUnsupported(deviceUID: "avr", sampleRate: 384_000)) {
    _ = try profile.makeLivePlan(
        availableDevices: [avr],
        sampleRate: 384_000,
        selectedOutputUID: "avr",
        bassManagementEnabled: true
    )
}
var badChannel = profile
badChannel.subwooferAssignments[1].destination.channelIndex = 16
expectError(.outputChannelUnavailable(deviceUID: "avr", channelIndex: 16, channelCount: 16)) {
    _ = try badChannel.makeLivePlan(
        availableDevices: [avr],
        sampleRate: 96_000,
        selectedOutputUID: "avr",
        bassManagementEnabled: true
    )
}

// Multiple hardware devices flatten deterministically in reference-device order;
// PR63 can hand this plan to the existing private Aggregate Device transport.
let leftDevice = AudioOutputDevice(
    uid: "left-box", outputChannelCount: 2,
    minimumSampleRate: 44_100, maximumSampleRate: 192_000
)
let rightDevice = AudioOutputDevice(
    uid: "right-box", outputChannelCount: 2,
    minimumSampleRate: 44_100, maximumSampleRate: 192_000
)
let stereoAcrossDevices = OutputDeviceProfileConfiguration(
    enabled: true,
    programLayout: .stereo,
    speakerAssignments: [
        SemanticSpeakerOutputAssignment(role: .frontLeft, destination: endpoint(0, device: "left-box")),
        SemanticSpeakerOutputAssignment(role: .frontRight, destination: endpoint(1, device: "right-box")),
    ],
    referenceDeviceUID: "left-box"
)
let aggregatePlan = try stereoAcrossDevices.makeLivePlan(
    availableDevices: [leftDevice, rightDevice],
    sampleRate: 48_000,
    selectedOutputUID: "left-box",
    bassManagementEnabled: false
)
precondition(aggregatePlan.orderedDeviceUIDs == ["left-box", "right-box"])
precondition(aggregatePlan.physicalChannelCount == 4)
precondition(aggregatePlan.usesMultiplePhysicalDevices)
precondition(aggregatePlan.programPhysicalChannels[0] == 0)
precondition(aggregatePlan.programPhysicalChannels[1] == 3)
_ = try aggregatePlan.makeRealtimeOutputMap()

print("PR62 Swift behavior harness passed")
'''

    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr62-") as directory:
        temp = pathlib.Path(directory)
        stubs_path = temp / "Stubs.swift"
        main_path = temp / "main.swift"
        binary = temp / "pr62-profile-harness"
        stubs_path.write_text(stubs, encoding="utf-8")
        main_path.write_text(main, encoding="utf-8")
        subprocess.run([
            xcrun,
            "swiftc",
            "-O",
            "-import-objc-header",
            str(BRIDGING),
            "-Xcc",
            f"-I{REALTIME}",
            str(stubs_path),
            str(PROFILE),
            str(main_path),
            "-framework",
            "CoreAudio",
            "-o",
            str(binary),
        ], check=True, cwd=ROOT)
        subprocess.run([str(binary)], check=True, cwd=ROOT)


def main() -> None:
    for path in (PROFILE, PRODUCT, PROJECT, BRIDGING):
        require(path.exists(), f"{path.name} is missing")

    profile = PROFILE.read_text(encoding="utf-8")
    product = PRODUCT.read_text(encoding="utf-8")
    project = PROJECT.read_text(encoding="utf-8")

    require("enum OutputProgramRole" in profile, "semantic program-role model is missing")
    require("enum OutputProgramLayout" in profile, "program-layout model is missing")
    require("case threeOne" in profile, "3.1 custom semantic layout is missing")
    require("2.1/2.2" in profile and "5.2/7.2" in profile,
            "program-layout versus physical-sub distinction is undocumented")
    require("lfeMustBeUnmappedWhenBassManaged" in profile,
            "native LFE / physical subwoofer separation is not enforced")
    require("PhysicalSubwooferOutputAssignment" in profile,
            "explicit Sub N output assignment is missing")
    require("N60LiveNChannelOutputMapCompile" in profile,
            "PR61 realtime output-map compiler is not connected")
    require("makeLivePlan" in profile, "device/profile activation plan compiler is missing")
    require("case profileDisabled" in profile and "guard enabled else" in profile,
            "disabled profiles do not fail closed at activation")
    require("softwarePLLSuperseded" in profile,
            "Aggregate Device synchronization policy is not preserved")

    require("OutputDeviceProfileConfiguration.swift in Sources" in project,
            "Output Device Profile source is not in the app target")
    require("var outputDeviceProfile: OutputDeviceProfileConfiguration?" in product,
            "PlaybackSystemState does not own Output Device Profile state")
    require("outputDeviceProfile: OutputDeviceProfileConfiguration? = nil" in product,
            "legacy archive-safe optional initializer is missing")
    require("selectedSystemOutputDeviceProfile" in product,
            "selected Playback System does not expose its Output Device Profile")
    require("replaceSelectedSystemOutputDeviceProfile" in product,
            "Playback System cannot persist Output Device Profile changes")
    require("legacyPhysicalRoutingConflict" in product,
            "legacy PR41 routing conflict is not guarded at profile mutation")
    require(
        "outputDeviceProfile: selectedSystemProfile?.state.outputDeviceProfile" in product
        or "outputDeviceProfile: engine.outputDeviceProfileConfiguration" in product,
        "profile capture does not preserve Output Device Profile state"
    )
    require("outputDeviceProfile.validateStructure" in product,
            "Playback System does not revalidate profile semantics when bass-management state changes")

    # PR62 deliberately retains schema v1: adding an Optional Codable field makes
    # pre-PR62 archives decode it as nil rather than discarding existing systems.
    require("struct PlaybackSystemState: Codable" in product, "PlaybackSystemState lost Codable")
    require("static let currentSchemaVersion = 1" in product,
            "PlaybackSystemState schema was bumped instead of using optional migration")

    if platform.system() == "Darwin":
        run_swift_behavior_harness()

    print("PR62 Output Device Profile validation passed")


if __name__ == "__main__":
    main()
