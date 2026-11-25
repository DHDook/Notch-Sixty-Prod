import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E16 S2: the media-key controller, the hotkey controller and the Shortcuts tab, against fakes.
@MainActor
final class HotkeysAndMediaKeysTests: XCTestCase {
    private final class FakeMonitor: GlobalVolumeKeyMonitoring {
        var onKey: ((GlobalVolumeKeyAction, Bool) -> Void)?
        var state: GlobalVolumeKeyMonitoringState = .stopped
        var startCount = 0
        var stopCount = 0
        var failWithPermission = false
        func start() throws {
            startCount += 1
            if failWithPermission {
                state = .permissionRequired
                throw GlobalVolumeKeyMonitorError.permissionRequired
            }
            state = .active
        }
        func stop() { stopCount += 1; state = .stopped }
    }

    private final class FakeTarget: VolumeKeyTarget {
        var softwareVolumeKeyStep = MasterVolumeKeyStep.fraction(denominator: 16)
        var masterVolumeConfiguration = MasterVolumeConfiguration(level: 0.5, muted: false)
        var isSoftwareVolumeActive = true
        var onVolumeKeyRouteChange: ((Bool) -> Void)?
        var applied: [Double] = []
        func applySoftwareVolumeKey(level: Double) {
            applied.append(level)
            masterVolumeConfiguration.level = level
        }
    }

    private func makeKeys(enabled: Bool = true, active: Bool = true)
        -> (VolumeKeyController, FakeMonitor, FakeTarget, () -> [ControlCommand]) {
        let monitor = FakeMonitor()
        let target = FakeTarget()
        target.isSoftwareVolumeActive = active
        var commands: [ControlCommand] = []
        let controller = VolumeKeyController(
            target: target, monitor: monitor, perform: { commands.append($0) }, isEnabled: { enabled })
        return (controller, monitor, target, { commands })
    }

    // MARK: media keys

    func testMonitorRunsOnlyForSoftwareVolumeAndStopsWhenTheRouteLeavesIt() {
        let (keys, monitor, target, _) = makeKeys()
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(keys.monitoringState, .active)
        target.onVolumeKeyRouteChange?(false)
        XCTAssertEqual(monitor.state, .stopped, "an output change to a device with its own volume stops the monitor")
        XCTAssertEqual(keys.monitoringState, .stopped)
        target.onVolumeKeyRouteChange?(true)
        XCTAssertEqual(monitor.state, .active)

        let (_, hardware, _, _) = makeKeys(active: false)
        XCTAssertEqual(hardware.startCount, 0, "a device-volume output never starts the tap")
    }

    func testMissingInputMonitoringIsReportedNotThrown() {
        let monitor = FakeMonitor()
        monitor.failWithPermission = true
        let keys = VolumeKeyController(
            target: FakeTarget(), monitor: monitor, perform: { _ in }, isEnabled: { true })
        XCTAssertEqual(keys.monitoringState, .permissionRequired)
        XCTAssertTrue(ShortcutsSettingsContent.statusText(.permissionRequired).contains("Input Monitoring"))
    }

    func testUpAndDownUseTheConfiguredStepAndFineModifierUsesAQuarter() {
        let (keys, _, target, _) = makeKeys()
        keys.handle(.increment, fine: false)
        XCTAssertEqual(target.applied.last ?? 0, 0.5 + 1.0 / 16, accuracy: 1e-9)
        target.masterVolumeConfiguration.level = 0.5
        keys.handle(.decrement, fine: true)
        XCTAssertEqual(target.applied.last ?? 0, 0.5 - 1.0 / 64, accuracy: 1e-9)

        target.softwareVolumeKeyStep = .decibels(2)
        target.masterVolumeConfiguration.level = MasterVolumeConfiguration.level(forSoftwareTaperDB: -10)
        keys.handle(.decrement, fine: true)
        let db = MasterVolumeConfiguration.softwareTaperDB(forLevel: target.applied.last ?? 0) ?? 0
        XCTAssertEqual(db, -10.5, accuracy: 1e-6, "a 2 dB step quartered is 0.5 dB")
    }

    func testFlagOffKeepsTodaysBehaviour() {
        let (keys, _, target, commands) = makeKeys(enabled: false)
        var indicator = 0
        keys.onLevelChanged = { indicator += 1 }
        keys.handle(.increment, fine: true)
        XCTAssertEqual(target.applied.last ?? 0, 0.5 + 1.0 / 16, accuracy: 1e-9, "no fine step with the flag off")
        keys.handle(.mute, fine: false)
        XCTAssertTrue(commands().isEmpty, "the mute key does nothing with the flag off")
        XCTAssertEqual(indicator, 0, "no indicator with the flag off")
    }

    func testMuteKeyGoesThroughTheControlServiceAndShowsTheIndicator() async {
        let (keys, _, _, commands) = makeKeys()
        var indicator = 0
        keys.onLevelChanged = { indicator += 1 }
        keys.handle(.mute, fine: false)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(commands(), [.toggleMute])
        XCTAssertEqual(indicator, 1)
    }

    func testKeysDoNothingOnAHardwareVolumeOutput() {
        let (keys, _, target, commands) = makeKeys()
        target.isSoftwareVolumeActive = false
        keys.handle(.increment, fine: false)
        keys.handle(.mute, fine: false)
        XCTAssertTrue(target.applied.isEmpty)
        XCTAssertTrue(commands().isEmpty)
    }

    func testQuarteredStepKeepsLevelsOnTheDecibelGrid() {
        XCTAssertEqual(MasterVolumeKeyStep.fraction(denominator: 32).quartered, .fraction(denominator: 128))
        XCTAssertEqual(MasterVolumeKeyStep.decibels(1).quartered, .decibels(0.25))
        XCTAssertTrue(MasterVolumeKeyStep.decibels(1).quartered.isValid)
    }

    // MARK: hotkeys

    private final class FakeRegistrar: GlobalHotkeyRegistering {
        var onPress: ((UInt32) -> Void)?
        var registered: [UInt32: HotkeyBinding] = [:]
        var refuse: Set<UInt32> = []
        func register(id: UInt32, binding: HotkeyBinding) -> HotkeyRegistrationResult {
            if refuse.contains(binding.keyCode) { return .failed("taken") }
            registered[id] = binding
            return .registered
        }
        func unregisterAll() { registered = [:] }
    }

    private final class FakeHost: ControlHost {
        var safeLaunchActive = false
        var lifecycleState: AudioLifecycleState = .idle
        var isFollowingOutput = false
        var selectedOutputUID: String? = "desk"
        var systems: [ControlSystemInfo] = []
        var presets: [ControlPresetInfo] = []
        var selectedSystemID: UUID?
        var selectedPresetID: UUID?
        var volumeLevel = 0.5
        var isMuted = false
        var volumeControlMode = "softwareDSP"
        var isBypassed = false
        var isRoomCorrectionEnabled = false
        var quietZoneStatus = "Off"
        var roomTreatmentStatus = "Off"
        var calls: [String] = []
        func outputName(forUID uid: String) -> String? { "Desk" }
        func startProcessing() async throws { calls.append("start"); lifecycleState = .running }
        func stopProcessing() { calls.append("stop"); lifecycleState = .idle }
        func setVolume(_ level: Double) throws { calls.append("volume"); volumeLevel = level }
        func setMuted(_ muted: Bool) throws { calls.append("mute \(muted)"); isMuted = muted }
        func setBypassed(_ bypassed: Bool) throws { calls.append("bypass \(bypassed)"); isBypassed = bypassed }
        func setRoomCorrection(_ enabled: Bool) throws { calls.append("rc \(enabled)"); isRoomCorrectionEnabled = enabled }
        func selectPreset(_ id: UUID) async throws { calls.append("preset"); selectedPresetID = id }
        func selectSystem(_ id: UUID) -> String? { nil }
    }

    private struct Rig {
        var hotkeys: HotkeyController
        var registrar: FakeRegistrar
        var host: FakeHost
        var defaults: UserDefaults
        var suite: String
    }

    private func makeHotkeys(enabled: Bool = true, suite: String? = nil) throws -> Rig {
        let suite = suite ?? "e16s2-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let registrar = FakeRegistrar()
        let host = FakeHost()
        let service = ControlService(host: host, isEnabled: { enabled })
        let hotkeys = HotkeyController(
            registrar: registrar, defaults: defaults, service: { service },
            volumeStep: { .fraction(denominator: 16) }, isEnabled: { enabled })
        return Rig(hotkeys: hotkeys, registrar: registrar, host: host, defaults: defaults, suite: suite)
    }

    private let cmdOpt = HotkeyBinding.commandBit | HotkeyBinding.optionBit

    func testNothingIsAssignedByDefault() throws {
        let rig = try makeHotkeys()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        XCTAssertTrue(rig.hotkeys.bindings.isEmpty)
        XCTAssertTrue(rig.registrar.registered.isEmpty)
    }

    func testAssignPersistsRegistersAndSurvivesRelaunch() throws {
        let rig = try makeHotkeys()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        let binding = HotkeyBinding(keyCode: 46, modifiers: cmdOpt)
        XCTAssertNil(rig.hotkeys.assign(binding, to: .mute))
        XCTAssertEqual(rig.registrar.registered[HotkeyController.hotkeyID(.mute)], binding)
        XCTAssertEqual(binding.display, "⌥⌘M")

        let again = try makeHotkeys(suite: rig.suite)
        XCTAssertEqual(again.hotkeys.bindings[.mute], binding)
        XCTAssertEqual(again.registrar.registered.count, 1, "stored shortcuts register at launch")

        rig.hotkeys.clear(.mute)
        XCTAssertTrue(rig.registrar.registered.isEmpty)
        XCTAssertNil(try makeHotkeys(suite: rig.suite).hotkeys.bindings[.mute])
    }

    func testConflictsAndBareKeysAreRefusedWithAReason() throws {
        let rig = try makeHotkeys()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        let binding = HotkeyBinding(keyCode: 46, modifiers: cmdOpt)
        XCTAssertNil(rig.hotkeys.assign(binding, to: .mute))
        let clash = rig.hotkeys.assign(binding, to: .bypass)
        XCTAssertTrue(clash?.contains("Mute on or off") ?? false, "\(clash ?? "nil")")
        XCTAssertNil(rig.hotkeys.bindings[.bypass])
        XCTAssertNotNil(rig.hotkeys.assign(HotkeyBinding(keyCode: 0, modifiers: HotkeyBinding.shiftBit), to: .bypass))
        XCTAssertNotNil(rig.hotkeys.assign(HotkeyBinding(keyCode: 0, modifiers: 0), to: .bypass))

        rig.registrar.refuse = [12]
        let taken = rig.hotkeys.assign(HotkeyBinding(keyCode: 12, modifiers: cmdOpt), to: .bypass)
        XCTAssertEqual(taken, "taken", "the registration refusal reaches the user")
        XCTAssertNil(rig.hotkeys.bindings[.bypass])
        XCTAssertEqual(rig.hotkeys.bindings[.mute], binding, "the earlier shortcut is untouched")
    }

    func testFlagOffRegistersNothingAndDispatchRefuses() async throws {
        let rig = try makeHotkeys(enabled: false)
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        rig.defaults.set(
            try JSONEncoder().encode([HotkeyAction.mute.rawValue: HotkeyBinding(keyCode: 46, modifiers: cmdOpt)]),
            forKey: HotkeyController.defaultsKey)
        let off = try makeHotkeys(enabled: false, suite: rig.suite)
        XCTAssertFalse(off.hotkeys.bindings.isEmpty)
        XCTAssertTrue(off.registrar.registered.isEmpty)
        let result = await off.hotkeys.dispatch(.mute)
        XCTAssertEqual(result, .refused(ControlRefusal.notAvailable))
        XCTAssertTrue(off.host.calls.isEmpty)
    }

    func testEveryActionDispatchesToTheControlService() async throws {
        let rig = try makeHotkeys()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        let first = UUID(), second = UUID(), third = UUID()
        rig.host.presets = [first, second, third].enumerated().map { ControlPresetInfo(id: $1, name: "P\($0)") }
        rig.host.selectedPresetID = first

        _ = await rig.hotkeys.dispatch(.processing)
        XCTAssertEqual(rig.host.calls.last, "start")
        _ = await rig.hotkeys.dispatch(.processing)
        XCTAssertEqual(rig.host.calls.last, "stop")
        _ = await rig.hotkeys.dispatch(.bypass)
        XCTAssertTrue(rig.host.isBypassed)
        _ = await rig.hotkeys.dispatch(.roomCorrection)
        XCTAssertTrue(rig.host.isRoomCorrectionEnabled)
        _ = await rig.hotkeys.dispatch(.mute)
        XCTAssertTrue(rig.host.isMuted)
        _ = await rig.hotkeys.dispatch(.volumeUp)
        XCTAssertEqual(rig.host.volumeLevel, 0.5 + 1.0 / 16, accuracy: 1e-9)
        _ = await rig.hotkeys.dispatch(.volumeDown)
        XCTAssertEqual(rig.host.volumeLevel, 0.5, accuracy: 1e-9)

        _ = await rig.hotkeys.dispatch(.nextPreset)
        XCTAssertEqual(rig.host.selectedPresetID, second)
        _ = await rig.hotkeys.dispatch(.previousPreset)
        XCTAssertEqual(rig.host.selectedPresetID, first)
        _ = await rig.hotkeys.dispatch(.previousPreset)
        XCTAssertEqual(rig.host.selectedPresetID, third, "wraps round")
        rig.host.presets = []
        let none = await rig.hotkeys.dispatch(.nextPreset)
        XCTAssertNotNil(none.refusalReason)
    }

    func testNoActionCanArmOrChooseAnOutput() {
        // The actions are a closed list of ControlService commands; none is an arm or output command.
        XCTAssertEqual(HotkeyAction.allCases.count, 8)
        XCTAssertFalse(HotkeyAction.allCases.contains { $0.rawValue.lowercased().contains("arm") || $0.rawValue.contains("output") })
    }

    func testModifierBitsFollowTheEventFlags() {
        XCTAssertEqual(
            ShortcutsSettingsContent.carbonModifiers([.command, .option]), HotkeyBinding.commandBit | HotkeyBinding.optionBit)
        XCTAssertEqual(ShortcutsSettingsContent.carbonModifiers([]), 0)
    }

    // MARK: Settings

    func testShortcutsTabIsHiddenWhileTheFlagIsOffAndFitsBothScreens() throws {
        XCTAssertFalse(SettingsTab.visible(automationEnabled: false).contains(.shortcuts))
        XCTAssertEqual(SettingsTab.shortcuts.cardTitles(offersDeveloperSwitch: false), ShortcutsSettingsContent.cardTitles)

        let rig = try makeHotkeys()
        defer { rig.defaults.removePersistentDomain(forName: rig.suite) }
        for (index, action) in HotkeyAction.allCases.prefix(3).enumerated() {
            rig.hotkeys.assign(HotkeyBinding(keyCode: UInt32(index) + 20, modifiers: cmdOpt), to: action)
        }
        let keys = VolumeKeyController(
            target: FakeTarget(), monitor: FakeMonitor(), perform: { _ in }, isEnabled: { true })
        let preferences = ApplicationPreferences(defaults: rig.defaults)
        let view = ShortcutsSettingsView(hotkeys: rig.hotkeys, volumeKeys: keys, preferences: preferences)
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            let page = HostedPage(view.padding(DesignSpacing.xl.pt), size: size)
            for control in page.controls {
                let frame = control.view.convert(control.view.bounds, to: page.hosting)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(control.searchText) at \(size.width)")
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(control.searchText) at \(size.width)")
            }
        }
        let narrow = NSHostingView(rootView: view.frame(width: 520))
        narrow.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        narrow.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(narrow.fittingSize.width, 520.5)
    }

    func testMediaKeyIndicatorDefaultsOnAndIsStored() throws {
        let suite = "e16s2-pref-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ApplicationPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showMediaKeyIndicator)
        preferences.showMediaKeyIndicator = false
        XCTAssertFalse(ApplicationPreferences(defaults: defaults).showMediaKeyIndicator)
    }
}
