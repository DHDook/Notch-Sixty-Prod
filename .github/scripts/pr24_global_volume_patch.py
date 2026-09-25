from pathlib import Path


def replace(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"pattern not found in {path}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))


engine = "NotchSixty/Audio/AudioIOEngine.swift"

replace(
    engine,
    "    private let masterVolumeController: any MasterVolumeDeviceControlling\n    private var lifecycle: AudioLifecycleStateMachine",
    "    private let masterVolumeController: any MasterVolumeDeviceControlling\n    private let globalVolumeKeyMonitor: any GlobalVolumeKeyMonitoring\n    private var lifecycle: AudioLifecycleStateMachine",
)

replace(
    engine,
    "    @Published private(set) var masterVolumeCapabilities = MasterVolumeDeviceCapabilities.softwareOnly\n    @Published private(set) var gainConfiguration",
    "    @Published private(set) var masterVolumeCapabilities = MasterVolumeDeviceCapabilities.softwareOnly\n    @Published private(set) var globalVolumeKeyMonitoringState: GlobalVolumeKeyMonitoringState = .stopped\n    @Published private(set) var gainConfiguration",
)

replace(
    engine,
    "        eventMonitor: AudioHardwareEventMonitor = AudioHardwareEventMonitor(),\n        masterVolumeController: any MasterVolumeDeviceControlling = CoreAudioMasterVolumeController()\n    ) {\n        self.deviceCatalog = deviceCatalog\n        self.routeConfiguration = initialRouteConfiguration\n        self.eventMonitor = eventMonitor\n        self.masterVolumeController = masterVolumeController",
    "        eventMonitor: AudioHardwareEventMonitor = AudioHardwareEventMonitor(),\n        masterVolumeController: any MasterVolumeDeviceControlling = CoreAudioMasterVolumeController(),\n        globalVolumeKeyMonitor: any GlobalVolumeKeyMonitoring = CoreHIDGlobalVolumeKeyMonitor()\n    ) {\n        self.deviceCatalog = deviceCatalog\n        self.routeConfiguration = initialRouteConfiguration\n        self.eventMonitor = eventMonitor\n        self.masterVolumeController = masterVolumeController\n        self.globalVolumeKeyMonitor = globalVolumeKeyMonitor",
)

replace(
    engine,
    "        masterVolumeController.onExternalChange = { [weak self] in self?.handleMasterVolumeDeviceChange() }\n    }",
    "        masterVolumeController.onExternalChange = { [weak self] in self?.handleMasterVolumeDeviceChange() }\n        globalVolumeKeyMonitor.onVolumeIncrement = { [weak self] in self?.handleGlobalVolumeKey(delta: 1.0 / 16.0) }\n        globalVolumeKeyMonitor.onVolumeDecrement = { [weak self] in self?.handleGlobalVolumeKey(delta: -1.0 / 16.0) }\n    }",
)

replace(
    engine,
    "            masterVolumeController.stopMonitoring()\n            masterVolumeCapabilities = .softwareOnly\n            return",
    "            masterVolumeController.stopMonitoring()\n            globalVolumeKeyMonitor.stop()\n            globalVolumeKeyMonitoringState = .stopped\n            masterVolumeCapabilities = .softwareOnly\n            return",
)

replace(
    engine,
    "        masterVolumeController.stopMonitoring()\n        eventMonitor.stop()",
    "        masterVolumeController.stopMonitoring()\n        globalVolumeKeyMonitor.stop()\n        globalVolumeKeyMonitoringState = .stopped\n        eventMonitor.stop()",
)

replace(
    engine,
    "    private func syncMasterVolumeMonitorToSelectedOutput() throws {\n        guard let output = selectedOutputDevice else {\n            masterVolumeController.stopMonitoring()\n            masterVolumeCapabilities = .softwareOnly\n            return\n        }\n        try masterVolumeController.monitor(deviceID: output.deviceID)\n        try synchronizeMasterVolumeFromSelectedDevice()\n    }",
    "    private func syncMasterVolumeMonitorToSelectedOutput() throws {\n        guard let output = selectedOutputDevice else {\n            masterVolumeController.stopMonitoring()\n            globalVolumeKeyMonitor.stop()\n            globalVolumeKeyMonitoringState = .stopped\n            masterVolumeCapabilities = .softwareOnly\n            return\n        }\n        try masterVolumeController.monitor(deviceID: output.deviceID)\n        try synchronizeMasterVolumeFromSelectedDevice()\n        syncGlobalVolumeKeyMonitor()\n    }",
)

replace(
    engine,
    "    private func handleMasterVolumeDeviceChange() {\n        do {\n            try synchronizeMasterVolumeFromSelectedDevice()\n            lastErrorDescription = nil\n        } catch {\n            lastErrorDescription = error.localizedDescription\n        }\n    }",
    """    private func handleMasterVolumeDeviceChange() {
        do {
            try synchronizeMasterVolumeFromSelectedDevice()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func syncGlobalVolumeKeyMonitor() {
        globalVolumeKeyMonitor.stop()
        globalVolumeKeyMonitoringState = .stopped
        guard masterVolumeCapabilities.controlMode == .softwareDSP else { return }
        do {
            try globalVolumeKeyMonitor.start()
            globalVolumeKeyMonitoringState = globalVolumeKeyMonitor.state
        } catch {
            globalVolumeKeyMonitoringState = globalVolumeKeyMonitor.state
            // Input Monitoring is a keyboard-control capability, not an audio-route
            // requirement. Keep the selected output usable and surface permission
            // state independently instead of failing refresh/recovery.
        }
    }

    private func handleGlobalVolumeKey(delta: Double) {
        guard masterVolumeCapabilities.controlMode == .softwareDSP else { return }
        let level = min(
            max(masterVolumeConfiguration.level + delta, MasterVolumeConfiguration.levelRange.lowerBound),
            MasterVolumeConfiguration.levelRange.upperBound
        )
        guard abs(level - masterVolumeConfiguration.level) > 0.000_001 else { return }
        var updated = masterVolumeConfiguration
        updated.level = level
        do {
            try applyMasterVolumeConfiguration(updated, writeDevice: false)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }""",
)

tests = "NotchSixtyTests/StereoPlaybackControlTests.swift"
replace(
    tests,
    "    func testMasterMuteFallsBackToSoftwareWhenDeviceHasNoWritableMute() {",
    """    func testFixedVolumeDeviceUsesSoftwareMasterGainForKeyboardFallback() {
        let fixedVolume = MasterVolumeDeviceCapabilities(
            volumeReadable: false,
            volumeWritable: false,
            muteReadable: true,
            muteWritable: true
        )
        XCTAssertEqual(fixedVolume.controlMode, .softwareDSP)
        XCTAssertEqual(
            MasterVolumeConfiguration(level: 0.375, muted: false).softwareGain(for: fixedVolume),
            0.375,
            accuracy: 0.000_001
        )
    }

    func testMasterMuteFallsBackToSoftwareWhenDeviceHasNoWritableMute() {""",
)

doc = Path("docs/MASTER_VOLUME_CONTROL.md")
doc.write_text(
    doc.read_text()
    + """

## Fixed-volume output keyboard fallback

When the selected physical output exposes no writable device volume (for example a fixed-output USB DAC), Notch Sixty keeps the physical device selected and uses the existing smoothed software master gain as the volume authority. A passive public IOKit HID listener observes Consumer Control Volume Increment/Decrement usages and maps them to 1/16-scale master-volume steps. The listener is active only in software-DSP volume mode, never seizes or suppresses keyboard events, and requires the user's macOS Input Monitoring permission. Missing permission does not invalidate the audio route; it is tracked as a separate keyboard-control capability. Native writable device volume remains preferred when available. The legacy virtual/HAL driver architecture is not reintroduced.
"""
)
