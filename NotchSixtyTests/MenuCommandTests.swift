import XCTest
@testable import NotchSixty

@MainActor
final class MenuCommandTests: XCTestCase {
    private final class FakeEngine: PlaybackMenuEngine {
        var lifecycleState: AudioLifecycleState = .running
        var playbackControlConfiguration = PlaybackControlConfiguration()
        var masterVolumeConfiguration = MasterVolumeConfiguration()
        var softwareVolumeKeyStep = MasterVolumeKeyStep.fraction(denominator: 16)
        var calls: [String] = []
        func stop() { calls.append("stop"); lifecycleState = .idle }
        func setGlobalDSPBypassed(_ bypassed: Bool) throws {
            calls.append("bypass \(bypassed)"); playbackControlConfiguration.globalBypassed = bypassed
        }
        func setAuditionMode(_ mode: AuditionMode) throws {
            calls.append("audition \(mode.rawValue)"); playbackControlConfiguration.auditionMode = mode
        }
        func setMasterVolumeLevel(_ level: Double) throws {
            calls.append("level"); masterVolumeConfiguration.level = level
        }
        func setMasterMuted(_ muted: Bool) throws {
            calls.append("mute \(muted)"); masterVolumeConfiguration.muted = muted
        }
    }

    private func make(_ engine: FakeEngine, started: @escaping () -> Void = {}) -> PlaybackMenuActions {
        PlaybackMenuActions(engine: engine, startProcessing: { started() })
    }

    func testBypassAndBeforeAfterToggle() async throws {
        let engine = FakeEngine()
        let actions = make(engine)
        try await actions.perform(.toggleBypass)
        XCTAssertTrue(engine.playbackControlConfiguration.globalBypassed)
        try await actions.perform(.toggleBypass)
        XCTAssertFalse(engine.playbackControlConfiguration.globalBypassed)
        try await actions.perform(.toggleBeforeAfter)
        XCTAssertEqual(engine.playbackControlConfiguration.auditionMode, .reference)
        try await actions.perform(.toggleBeforeAfter)
        XCTAssertEqual(engine.playbackControlConfiguration.auditionMode, .processed)
    }

    func testStartAndStopFollowLifecycle() async throws {
        let engine = FakeEngine()
        var starts = 0
        let actions = make(engine) { starts += 1 }
        XCTAssertFalse(actions.isEnabled(.start))
        try await actions.perform(.start)
        XCTAssertEqual(starts, 0)
        try await actions.perform(.stop)
        XCTAssertEqual(engine.calls, ["stop"])
        XCTAssertTrue(actions.isEnabled(.start))
        XCTAssertFalse(actions.isEnabled(.toggleBypass))
        try await actions.perform(.toggleBypass)
        XCTAssertEqual(engine.calls, ["stop"], "a disabled command does nothing")
        try await actions.perform(.start)
        XCTAssertEqual(starts, 1)
    }

    func testFailedStateStopsThenStarts() async throws {
        let engine = FakeEngine()
        engine.lifecycleState = .failed
        var starts = 0
        try await make(engine) { starts += 1 }.perform(.start)
        XCTAssertEqual(engine.calls, ["stop"])
        XCTAssertEqual(starts, 1)
    }

    func testSafeLaunchBlocksStart() async throws {
        let engine = FakeEngine()
        engine.lifecycleState = .idle
        var actions = make(engine)
        actions.safeLaunchActive = { true }
        XCTAssertFalse(actions.isEnabled(.start))
    }

    func testVolumeUsesKeyStepAndMute() async throws {
        let engine = FakeEngine()
        engine.masterVolumeConfiguration.level = 0.5
        let actions = make(engine)
        try await actions.perform(.volumeUp)
        XCTAssertEqual(engine.masterVolumeConfiguration.level, 0.5 + 1.0 / 16, accuracy: 1e-9)
        try await actions.perform(.volumeDown)
        XCTAssertEqual(engine.masterVolumeConfiguration.level, 0.5, accuracy: 1e-9)
        try await actions.perform(.toggleMute)
        XCTAssertTrue(engine.masterVolumeConfiguration.muted)
    }

    func testRealEngineBypassMatchesToolbarCall() async throws {
        let engine = AudioIOEngine()
        let before = engine.playbackControlConfiguration.globalBypassed
        // Not running: the menu refuses, exactly like the disabled toolbar button.
        let actions = PlaybackMenuActions(engine: engine, startProcessing: {})
        XCTAssertFalse(actions.isEnabled(.toggleBypass))
        try await actions.perform(.toggleBypass)
        XCTAssertEqual(engine.playbackControlConfiguration.globalBypassed, before)
        try await actions.perform(.toggleMute)
        XCTAssertTrue(engine.masterVolumeConfiguration.muted)
    }

    func testViewMenuShortcutsMatchSidebarPages() {
        XCTAssertEqual(ViewMenuPages.pages.count, 7)
        for (index, section) in ViewMenuPages.pages.enumerated() {
            let key = ViewMenuPages.shortcut(forPageAt: index)
            XCTAssertNotNil(key)
            XCTAssertEqual(ViewMenuPages.page(forShortcut: key!.character), section)
        }
        XCTAssertNil(ViewMenuPages.shortcut(forPageAt: 7))
        let sidebar = Set(ProductionSection.sidebarGroups(designLanguage: true).flatMap(\.sections) + [.dashboard])
        for page in ViewMenuPages.pages { XCTAssertTrue(sidebar.contains(page), "\(page) is not in the sidebar") }
    }

    func testPlaybackShortcutsAreUniqueAndAvoidExisting() {
        var seen = Set<String>()
        for command in PlaybackMenuCommand.allCases {
            let s = command.shortcut
            XCTAssertTrue(seen.insert("\(s.key.character)\(s.modifiers.rawValue)").inserted, "\(command) clashes")
            XCTAssertTrue(s.modifiers.contains(.command))
        }
    }
}
