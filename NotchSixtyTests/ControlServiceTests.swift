import SwiftUI
import XCTest
@testable import NotchSixty

/// E16 S1: the control service against a recording fake host, then against the production host and a real engine.
@MainActor
final class ControlServiceTests: XCTestCase {
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
        var systemRefusal: String?
        var calls: [String] = []
        var startError: Error?

        func outputName(forUID uid: String) -> String? { ["desk": "Desk DAC", "lounge": "Lounge DAC"][uid] }
        func startProcessing() async throws {
            calls.append("start")
            if let startError { throw startError }
            lifecycleState = .running
        }
        func stopProcessing() { calls.append("stop"); lifecycleState = .idle }
        func setVolume(_ level: Double) throws { calls.append("volume \(level)"); volumeLevel = level }
        func setMuted(_ muted: Bool) throws { calls.append("mute \(muted)"); isMuted = muted }
        func setBypassed(_ bypassed: Bool) throws { calls.append("bypass \(bypassed)"); isBypassed = bypassed }
        func setRoomCorrection(_ enabled: Bool) throws { calls.append("rc \(enabled)"); isRoomCorrectionEnabled = enabled }
        func selectPreset(_ id: UUID) async throws { calls.append("preset"); selectedPresetID = id }
        func selectSystem(_ id: UUID) -> String? {
            calls.append("system")
            if let systemRefusal { return systemRefusal }
            selectedSystemID = id
            return nil
        }
    }

    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    private func make(enabled: Bool = true) -> (FakeHost, ControlService) {
        let host = FakeHost()
        return (host, ControlService(host: host, isEnabled: { enabled }))
    }

    func testEveryCommandIsRefusedWhileTheFlagIsOffAndNothingIsCalled() async {
        let (host, service) = make(enabled: false)
        let commands: [ControlCommand] = [
            .selectSystem(UUID()), .selectPreset(UUID()), .setVolume(0.2), .stepVolume(0.1), .setMuted(true), .toggleMute,
            .setBypass(true), .setProcessing(true), .setProcessing(false), .setRoomCorrection(true), .readStatus
        ]
        for command in commands {
            let result = await service.perform(command)
            XCTAssertEqual(result, .refused(ControlRefusal.notAvailable), "\(command)")
        }
        XCTAssertTrue(host.calls.isEmpty)
    }

    func testSafeLaunchRefusesEverythingButProcessingOffAndStatus() async {
        let (host, service) = make()
        host.safeLaunchActive = true
        host.lifecycleState = .running
        for command: ControlCommand in [.setVolume(0.2), .setBypass(true), .setProcessing(true), .setRoomCorrection(true)] {
            let result = await service.perform(command)
            XCTAssertEqual(result, .refused(ControlRefusal.safeLaunch))
        }
        XCTAssertTrue(host.calls.isEmpty)
        let off = await service.perform(.setProcessing(false))
        XCTAssertEqual(off, .done)
        XCTAssertEqual(host.calls, ["stop"])
        if case .status = await service.perform(.readStatus) {} else { XCTFail("status is always readable") }
    }

    func testVolumeMuteBypassAndRoomCorrectionReachTheHost() async {
        let (host, service) = make()
        var result = await service.perform(.setVolume(0.8))
        XCTAssertEqual(result, .done)
        XCTAssertEqual(host.volumeLevel, 0.8)
        result = await service.perform(.stepVolume(0.5))
        XCTAssertEqual(host.volumeLevel, 1.0, "a step clamps to the range")
        result = await service.perform(.stepVolume(-2))
        XCTAssertEqual(host.volumeLevel, 0.0)
        result = await service.perform(.toggleMute)
        XCTAssertTrue(host.isMuted)
        result = await service.perform(.setMuted(false))
        XCTAssertFalse(host.isMuted)
        result = await service.perform(.setBypass(true))
        XCTAssertTrue(host.isBypassed)
        result = await service.perform(.setRoomCorrection(true))
        XCTAssertTrue(host.isRoomCorrectionEnabled)
        XCTAssertEqual(result, .done)
    }

    func testInvalidLevelsAreRefused() async {
        let (host, service) = make()
        for level in [-0.1, 1.1, .nan, .infinity] {
            let result = await service.perform(.setVolume(level))
            XCTAssertEqual(result, .refused(ControlRefusal.invalidLevel))
        }
        let step = await service.perform(.stepVolume(.nan))
        XCTAssertEqual(step, .refused(ControlRefusal.invalidLevel))
        XCTAssertTrue(host.calls.isEmpty)
    }

    func testProcessingOnStartsOnceAndRecoversAFailedEngine() async {
        let (host, service) = make()
        var result = await service.perform(.setProcessing(true))
        XCTAssertEqual(result, .done)
        XCTAssertEqual(host.calls, ["start"])
        result = await service.perform(.setProcessing(true))
        XCTAssertEqual(result, .done, "already processing")
        XCTAssertEqual(host.calls, ["start"])

        host.calls = []
        host.lifecycleState = .failed
        result = await service.perform(.setProcessing(true))
        XCTAssertEqual(host.calls, ["stop", "start"], "a failed engine is stopped first, as the remote does")

        host.lifecycleState = .stopping
        result = await service.perform(.setProcessing(true))
        XCTAssertEqual(result, .refused(ControlRefusal.busy))
    }

    func testStartFailureBecomesARefusalWithThePlainReason() async {
        let (host, service) = make()
        host.startError = Boom()
        let result = await service.perform(.setProcessing(true))
        XCTAssertEqual(result, .refused("boom"))
    }

    func testGraphChangesAreRefusedWhenTheEngineFailedOrIsBusy() async {
        let (host, service) = make()
        let system = ControlSystemInfo(id: UUID(), name: "Desk", outputUID: nil)
        let preset = ControlPresetInfo(id: UUID(), name: "Warm")
        host.systems = [system]
        host.presets = [preset]
        host.lifecycleState = .failed
        var result = await service.perform(.selectSystem(system.id))
        XCTAssertEqual(result, .refused(ControlRefusal.engineFailed))
        result = await service.perform(.selectPreset(preset.id))
        XCTAssertEqual(result, .refused(ControlRefusal.engineFailed))
        host.lifecycleState = .reconfiguring
        result = await service.perform(.selectPreset(preset.id))
        XCTAssertEqual(result, .refused(ControlRefusal.busy))
        XCTAssertTrue(host.calls.isEmpty)
        host.lifecycleState = .running
        result = await service.perform(.selectPreset(preset.id))
        XCTAssertEqual(result, .done)
        XCTAssertEqual(host.selectedPresetID, preset.id)
    }

    func testUnknownSystemAndPresetAreRefused() async {
        let (host, service) = make()
        var result = await service.perform(.selectSystem(UUID()))
        XCTAssertEqual(result, .refused(ControlRefusal.unknownSystem))
        result = await service.perform(.selectPreset(UUID()))
        XCTAssertEqual(result, .refused(ControlRefusal.unknownPreset))
        XCTAssertTrue(host.calls.isEmpty)
    }

    func testSystemBoundToAnotherOutputIsRefusedAndNeverMovesTheOutput() async {
        let (host, service) = make()
        let lounge = ControlSystemInfo(id: UUID(), name: "Lounge", outputUID: "lounge")
        host.systems = [lounge]
        let result = await service.perform(.selectSystem(lounge.id))
        XCTAssertEqual(result, .refused("This system is for Lounge DAC; choose it in Notch Sixty."))
        XCTAssertTrue(host.calls.isEmpty, "the profile was never applied")
        XCTAssertEqual(host.selectedOutputUID, "desk")
    }

    func testFollowModeAppliesTheSystemToTheCurrentDeviceWithoutRebinding() async {
        let (host, service) = make()
        host.isFollowingOutput = true
        let lounge = ControlSystemInfo(id: UUID(), name: "Lounge", outputUID: "lounge")
        host.systems = [lounge]
        let result = await service.perform(.selectSystem(lounge.id))
        XCTAssertEqual(result, .done)
        XCTAssertEqual(host.calls, ["system"])
        XCTAssertEqual(host.selectedOutputUID, "desk")
        XCTAssertEqual(host.systems.first?.outputUID, "lounge", "no binding changed")
    }

    func testSystemRefusalFromTheProfileControllerIsPassedOn() async {
        let (host, service) = make()
        let system = ControlSystemInfo(id: UUID(), name: "Desk", outputUID: "desk")
        host.systems = [system]
        host.systemRefusal = "Stop processing before selecting Desk; it is associated with a different output device."
        let result = await service.perform(.selectSystem(system.id))
        XCTAssertEqual(result.refusalReason, host.systemRefusal)
    }

    func testStatusSnapshotReadsTheHostAndTheTreatmentsAreReadOnlyText() async {
        let (host, service) = make()
        let system = ControlSystemInfo(id: UUID(), name: "Desk", outputUID: "desk")
        host.systems = [system]
        host.selectedSystemID = system.id
        host.quietZoneStatus = "On"
        let result = await service.perform(.readStatus)
        guard case .status(let snapshot) = result else { return XCTFail("expected a status") }
        XCTAssertEqual(snapshot.version, ControlStateSnapshot.currentVersion)
        XCTAssertEqual(snapshot.outputName, "Desk DAC")
        XCTAssertEqual(snapshot.system?.name, "Desk")
        XCTAssertEqual(snapshot.quietZoneStatus, "On")
        XCTAssertEqual(snapshot.roomTreatmentStatus, "Off")
        let data = try? JSONEncoder().encode(snapshot)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(ControlStateSnapshot.self, from: $0) }, snapshot)
        XCTAssertTrue(ControlStatusText.describe(snapshot).contains("system Desk"))
    }

    // MARK: Snapshot coalescing

    private final class TestClock: ControlClock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    func testSnapshotsAreCoalescedToTenPerSecondAndTheLastStateAlwaysArrives() {
        let (host, service) = make()
        let clock = TestClock()
        let publisher = ControlSnapshotPublisher(service: service, clock: clock)
        var received: [ControlStateSnapshot] = []
        let token = publisher.publisher.sink { received.append($0) }
        defer { token.cancel() }

        XCTAssertTrue(publisher.stateMayHaveChanged(), "the first state is sent")
        XCTAssertFalse(publisher.stateMayHaveChanged(), "unchanged state is not sent")
        for step in 1...20 {
            host.volumeLevel = Double(step) / 100
            clock.now += 0.004
            publisher.stateMayHaveChanged()
        }
        XCTAssertEqual(received.count, 1, "changes inside the 100 ms window are held")
        XCTAssertTrue(publisher.hasPending)
        XCTAssertFalse(publisher.flush(), "the window has not ended")
        clock.now += 0.1
        XCTAssertTrue(publisher.flush())
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.last?.volumeLevel, 0.2)
        XCTAssertFalse(publisher.hasPending)

        // Over a simulated second of constant change at 1 kHz, at most ten arrive.
        received = []
        for _ in 0..<1_000 {
            host.volumeLevel = (host.volumeLevel + 0.001).truncatingRemainder(dividingBy: 1)
            clock.now += 0.001
            publisher.stateMayHaveChanged()
            publisher.flush()
        }
        XCTAssertLessThanOrEqual(received.count, 11)
        XCTAssertGreaterThanOrEqual(received.count, 9)
    }

    // MARK: Production host

    private func realProduct(rate: Double) throws -> (ProductController, AudioIOEngine, ControlService) {
        let device = AudioOutputDevice(
            deviceID: 4_242, uid: "desk", name: "Desk DAC", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)])
        let other = AudioOutputDevice(
            deviceID: 4_243, uid: "lounge", name: "Lounge DAC", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)])
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [device, other]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "desk")
        let product = ProductController(audioEngine: engine)
        return (product, engine, product.makeControlService(flags: { FeatureFlags(
            policy: .launchArgumentOnly, arguments: ["-NotchSixtyFeatures", FeatureFlag.automation.id], environment: [:]) }))
    }

    func testSystemAndPresetSwitchAtEveryStandardRateKeepTheOutputAndItsRate() async throws {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let (product, engine, service) = try realProduct(rate: rate)
            let systemID = product.profiles.saveCurrentSystemProfile(named: "Desk \(rate)")
            let presetID = product.profiles.saveCurrentContentPreset(named: "Warm \(rate)")

            var result = await service.perform(.selectSystem(systemID))
            XCTAssertEqual(result, .done, "\(rate)")
            result = await service.perform(.selectPreset(presetID))
            XCTAssertEqual(result, .done, "\(rate)")
            XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "desk", "\(rate)")
            XCTAssertEqual(engine.outputDevices.first { $0.uid == "desk" }?.nominalSampleRate, rate)
            guard case .status(let snapshot) = await service.perform(.readStatus) else { return XCTFail("status") }
            XCTAssertEqual(snapshot.system?.id, systemID)
            XCTAssertEqual(snapshot.preset?.id, presetID)
        }
    }

    func testRealHostRefusesASystemBoundToAnotherOutputAndLeavesTheOutputAlone() async throws {
        let (product, engine, service) = try realProduct(rate: 48_000)
        let id = product.profiles.saveCurrentSystemProfile(named: "Lounge")
        product.profiles.useSelectedSystem(for: OutputKey(deviceUID: "lounge"))
        let result = await service.perform(.selectSystem(id))
        XCTAssertEqual(result, .refused(ControlRefusal.otherOutput("Lounge DAC")))
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "desk")
    }

    func testNoCommandArmsLiveTreatmentOrChangesTheOutput() async throws {
        let (product, engine, service) = try realProduct(rate: 48_000)
        let systemID = product.profiles.saveCurrentSystemProfile(named: "Desk")
        let presetID = product.profiles.saveCurrentContentPreset(named: "Warm")
        let commands: [ControlCommand] = [
            .selectSystem(systemID), .selectPreset(presetID), .setVolume(0.3), .stepVolume(0.1), .setMuted(true),
            .toggleMute, .setBypass(true), .setBypass(false), .setProcessing(false), .setRoomCorrection(true),
            .setRoomCorrection(false), .readStatus
        ]
        for command in commands { _ = await service.perform(command) }
        XCTAssertFalse(product.activeQuietZone.arm.isArmed)
        XCTAssertFalse(product.mimoTreatment.isArmed)
        XCTAssertEqual(engine.routeConfiguration.selectedOutputUID, "desk")
    }

    // MARK: Intents

    func testIntentsRefuseWhileTheFlagIsOffAndPerformThroughTheInstalledServiceWhenOn() async throws {
        defer { AutomationRuntime.shared.uninstall() }
        let host = FakeHost()
        let preset = ControlPresetInfo(id: UUID(), name: "Warm")
        host.presets = [preset]
        host.systems = [ControlSystemInfo(id: UUID(), name: "Desk", outputUID: nil)]

        var enabled = false
        AutomationRuntime.shared.install(
            service: ControlService(host: host, isEnabled: { enabled }), navigation: nil)

        var volume = SetVolumeIntent()
        volume.percent = 30
        do {
            _ = try await volume.perform()
            XCTFail("expected a refusal")
        } catch let error as ControlIntentError {
            XCTAssertEqual(error.message, ControlRefusal.notAvailable)
        }
        XCTAssertTrue(host.calls.isEmpty)

        enabled = true
        _ = try await volume.perform()
        XCTAssertEqual(host.volumeLevel, 0.3, accuracy: 1e-9)

        var change = ChangeVolumeIntent()
        change.percent = -10
        _ = try await change.perform()
        XCTAssertEqual(host.volumeLevel, 0.2, accuracy: 1e-9)

        var mute = SetMuteIntent()
        mute.muted = true
        _ = try await mute.perform()
        XCTAssertTrue(host.isMuted)

        var bypass = SetBypassIntent()
        bypass.bypassed = true
        _ = try await bypass.perform()
        XCTAssertTrue(host.isBypassed)

        var rc = SetRoomCorrectionIntent()
        rc.on = true
        _ = try await rc.perform()
        XCTAssertTrue(host.isRoomCorrectionEnabled)

        var processing = SetProcessingIntent()
        processing.on = true
        _ = try await processing.perform()
        XCTAssertEqual(host.lifecycleState, .running)

        var select = SelectPresetIntent()
        select.preset = ContentPresetEntity(id: preset.id, name: preset.name)
        _ = try await select.perform()
        XCTAssertEqual(host.selectedPresetID, preset.id)

        let status = try await GetStatusIntent().perform()
        XCTAssertTrue((status.value ?? "").hasPrefix("Processing"))

        let entities = try await PlaybackSystemQuery().suggestedEntities()
        XCTAssertEqual(entities.map(\.name), ["Desk"])
    }

    func testIntentRefusesBeforeTheAppHasInstalledAService() async {
        AutomationRuntime.shared.uninstall()
        var mute = SetMuteIntent()
        mute.muted = true
        do {
            _ = try await mute.perform()
            XCTFail("expected a refusal")
        } catch let error as ControlIntentError {
            XCTAssertEqual(error.message, AutomationRuntime.notReady)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testOpenQuietZoneOnlyNavigatesAndRefusesWhileTheFlagIsOff() {
        defer { AutomationRuntime.shared.uninstall() }
        let host = FakeHost()
        let navigation = ProductionNavigation()
        var enabled = false
        AutomationRuntime.shared.install(
            service: ControlService(host: host, isEnabled: { enabled }), navigation: navigation)
        XCTAssertEqual(AutomationRuntime.shared.openQuietZone(), .refused(ControlRefusal.notAvailable))
        XCTAssertEqual(navigation.selection, .dashboard)
        enabled = true
        XCTAssertEqual(AutomationRuntime.shared.openQuietZone(), .done)
        XCTAssertEqual(navigation.selection, .activeAcoustics)
        XCTAssertTrue(host.calls.isEmpty, "opening the page changes no control")
    }

    // MARK: Flags and remote panel

    func testFlagsAreRegisteredDarkAndNoAppShortcutsProviderExistsYet() {
        for flag in [FeatureFlag.automation, .localAPI] {
            XCTAssertTrue(FeatureFlag.all.contains(flag))
            XCTAssertFalse(flag.resolvedDefault)
            XCTAssertEqual(flag.epic, "E16")
        }
        XCTAssertEqual(MenuBarRemoteModel.automationControls(automationOn: false), [])
        XCTAssertEqual(
            Set(MenuBarRemoteModel.automationControls(automationOn: true)), Set(RemoteAutomationControl.allCases))
    }

    func testRemotePanelFitsAt300PointsWithTheNewControlsAndShowsNoneWhileOff() throws {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let product = ProductController(audioEngine: engine)
        func hosted(on: Bool) -> HostedPage {
            let flags = FeatureFlags(
                policy: .launchArgumentOnly,
                arguments: on ? ["-NotchSixtyFeatures", FeatureFlag.automation.id] : [], environment: [:])
            return HostedPage(ProductionRemotePanel(product: product, flags: flags), size: CGSize(width: 300, height: 1_000))
        }
        let off = hosted(on: false)
        XCTAssertNil(off.controls.first { $0.searchText.contains("Playback System") })

        let page = hosted(on: true)
        XCTAssertGreaterThan(page.controls(of: .toggle).count, off.controls(of: .toggle).count)
        for control in page.controls {
            let frame = control.view.convert(control.view.bounds, to: page.hosting)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, control.searchText)
            XCTAssertLessThanOrEqual(frame.maxX, 300.5, control.searchText)
        }
    }
}
