import AppKit
import CryptoKit
import XCTest
@testable import NotchSixty

final class ProductionInformationArchitectureTests: XCTestCase {
    func testProcessingStatusReadsStoppedWhenTheEngineIsNotRunning() {
        // Bypass is irrelevant once the tap is torn down.
        for bypassed in [false, true] {
            let stopped = ProductionProcessingStatus(lifecycleState: .idle, bypassed: bypassed)
            XCTAssertEqual(stopped.title, "Stopped")
            XCTAssertEqual(stopped.tone, .stopped)
        }
        XCTAssertEqual(ProductionProcessingStatus(lifecycleState: .running, bypassed: false).tone, .active)
        XCTAssertEqual(ProductionProcessingStatus(lifecycleState: .running, bypassed: true).tone, .bypassed)
        XCTAssertEqual(ProductionProcessingStatus(lifecycleState: .failed, bypassed: false).tone, .failed)
        for state in [AudioLifecycleState.requestingPermission, .creatingTap, .creatingAggregate,
                      .openingOutput, .starting, .reconfiguring, .recoveringOutput, .stopping] {
            XCTAssertEqual(
                ProductionProcessingStatus(lifecycleState: state, bypassed: true).tone,
                .transitioning,
                "\(state)"
            )
        }
        // Every tone reads differently, so colour is never the only cue.
        let titles = Set(AudioLifecycleState.allCases.flatMap { state in
            [false, true].map { ProductionProcessingStatus(lifecycleState: state, bypassed: $0).title }
        })
        XCTAssertTrue(titles.isSuperset(of: ["Active", "Bypassed", "Stopped", "Failed"]))
    }

    func testFlatVUSweepKeepsTheScaleAndCentresOnVertical() {
        XCTAssertEqual(ProductionVUScale.sweepDegrees, 54)
        // Symmetric about straight up (270°), so the needle rests and peaks
        // at matching tilts.
        XCTAssertEqual(ProductionVUScale.startAngleDegrees + ProductionVUScale.sweepDegrees / 2, 270)
        XCTAssertEqual(ProductionVUScale.angle(forVU: ProductionVUScale.minimumVU), 243)
        XCTAssertEqual(ProductionVUScale.angle(forVU: ProductionVUScale.maximumVU), 297)
        XCTAssertEqual(ProductionVUScale.normalizedPosition(forVU: 0), 0.790, accuracy: 1e-12)
    }

    func testVolumeFeedbackRoundingAndMuteSemantics() {
        XCTAssertEqual(VolumeFeedbackPresentation.percentage(0), 0)
        XCTAssertEqual(VolumeFeedbackPresentation.percentage(0.678), 68)
        XCTAssertEqual(VolumeFeedbackPresentation.percentage(1), 100)
        XCTAssertEqual(VolumeFeedbackPresentation.percentage(-0.5), 0)
        XCTAssertEqual(VolumeFeedbackPresentation.percentage(1.5), 100)
        XCTAssertEqual(VolumeFeedbackPresentation.percentage(.nan), 0)
        XCTAssertEqual(VolumeFeedbackPresentation.readout(level: 0.678, muted: false), "68%")
        XCTAssertEqual(VolumeFeedbackPresentation.readout(level: 0.678, muted: true), "Muted")
    }

    func testDecibelVolumeReadoutClimbsToZeroAtFullScale() {
        XCTAssertEqual(VolumeFeedbackPresentation.readout(level: 1, muted: false, decibels: true), "0 dB")
        let twelveDown = MasterVolumeConfiguration.level(forSoftwareTaperDB: -12)
        XCTAssertEqual(VolumeFeedbackPresentation.readout(level: twelveDown, muted: false, decibels: true), "−12 dB")
        let halfDown = MasterVolumeConfiguration.level(forSoftwareTaperDB: -0.5)
        XCTAssertEqual(VolumeFeedbackPresentation.readout(level: halfDown, muted: false, decibels: true), "−0.5 dB")
        XCTAssertEqual(VolumeFeedbackPresentation.readout(level: 0, muted: false, decibels: true), "−∞ dB")
        XCTAssertEqual(VolumeFeedbackPresentation.readout(level: 0.5, muted: true, decibels: true), "Muted")
        XCTAssertEqual(VolumeFeedbackPresentation.readout(level: 0.678, muted: false), "68%")

        // Half-dB mode keeps one decimal so the menu bar readout never resizes.
        let tenths = { (db: Double) in
            VolumeFeedbackPresentation.readout(
                level: MasterVolumeConfiguration.level(forSoftwareTaperDB: db),
                muted: false,
                decibels: true,
                alwaysTenths: true
            )
        }
        XCTAssertEqual(tenths(-27), "−27.0 dB")
        XCTAssertEqual(tenths(-27.5), "−27.5 dB")
        XCTAssertEqual(tenths(0), "0.0 dB")
    }

    /// The menu bar reserves the widest template's width; every readout a
    /// mode can show must fit inside it, or the tray item would resize.
    func testMenuBarReadoutsFitTheirReservedWidth() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        func reserved(decibels: Bool, tenths: Bool) -> CGFloat {
            VolumeFeedbackPresentation.readoutWidthTemplates(decibels: decibels, alwaysTenths: tenths)
                .map(width).max() ?? 0
        }

        let percentSlot = reserved(decibels: false, tenths: false)
        for percent in 0...100 {
            let text = VolumeFeedbackPresentation.readout(level: Double(percent) / 100, muted: false)
            XCTAssertLessThanOrEqual(width(text), percentSlot + 0.01, text)
        }

        for step in [0.5, 1, 1.5, 3] {
            let tenths = step.rounded() != step
            let slot = reserved(decibels: true, tenths: tenths)
            var db = 0.0
            while db >= -80 {
                let text = VolumeFeedbackPresentation.readout(
                    level: MasterVolumeConfiguration.level(forSoftwareTaperDB: db),
                    muted: false,
                    decibels: true,
                    alwaysTenths: tenths
                )
                XCTAssertLessThanOrEqual(width(text), slot + 0.01, text)
                db -= step
            }
            for text in ["−∞ dB"] {
                XCTAssertLessThanOrEqual(width(text), slot + 0.01, text)
            }
        }
    }

    /// Percent modes mark the fader in percent; the dB modes use dB labels,
    /// and the loudness taper halves the level every 10 dB.
    func testFaderMarksAndTheLoudnessTaper() throws {
        XCTAssertEqual(VolumeFeedbackPresentation.faderTickPercents, [0, 25, 50, 75, 100])
        XCTAssertEqual(VolumeFeedbackPresentation.faderTickLabel(0), "0")
        XCTAssertEqual(VolumeFeedbackPresentation.faderTickLabel(-20), "−20")
        XCTAssertEqual(VolumeFeedbackPresentation.faderTickLabel(nil), "−∞")
        XCTAssertEqual(MasterVolumeConfiguration.level(forSoftwareTaperDB: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(MasterVolumeConfiguration.level(forSoftwareTaperDB: -10), 0.5, accuracy: 1e-12)
        XCTAssertEqual(MasterVolumeConfiguration.level(forSoftwareTaperDB: -20), 0.25, accuracy: 1e-12)
        XCTAssertEqual(MasterVolumeConfiguration.level(forSoftwareTaperDB: -30), 0.125, accuracy: 1e-12)
        XCTAssertEqual(MasterVolumeConfiguration.level(forSoftwareTaperDB: -.infinity), 0)
    }

    func testDecibelKeyStepsLandOnTheStepGridBetweenSilenceAndZero() throws {
        func db(_ level: Double) throws -> Double {
            try XCTUnwrap(MasterVolumeConfiguration.softwareTaperDB(forLevel: level))
        }
        let oneDB = MasterVolumeKeyStep.decibels(1)
        XCTAssertEqual(try db(oneDB.level(afterPress: -1, from: 1)), -1, accuracy: 1e-9)
        XCTAssertEqual(oneDB.level(afterPress: 1, from: 1), 1, "capped at 0 dB")

        // Off-grid levels snap to the next whole step in the pressed direction.
        let offGrid = MasterVolumeConfiguration.level(forSoftwareTaperDB: -12.3)
        XCTAssertEqual(try db(oneDB.level(afterPress: 1, from: offGrid)), -12, accuracy: 1e-9)
        XCTAssertEqual(try db(oneDB.level(afterPress: -1, from: offGrid)), -13, accuracy: 1e-9)

        var level = 1.0
        for _ in 0..<4 { level = MasterVolumeKeyStep.decibels(0.5).level(afterPress: -1, from: level) }
        XCTAssertEqual(try db(level), -2, accuracy: 1e-9, "four half-dB presses")
        for _ in 0..<4 { level = MasterVolumeKeyStep.decibels(0.5).level(afterPress: 1, from: level) }
        XCTAssertEqual(level, 1, accuracy: 1e-9)

        let floor = MasterVolumeConfiguration.level(forSoftwareTaperDB: MasterVolumeKeyStep.decibelFloor)
        let fourDB = MasterVolumeKeyStep.decibels(4)
        XCTAssertEqual(fourDB.level(afterPress: -1, from: floor), 0, "below the floor is silence")
        XCTAssertEqual(fourDB.level(afterPress: 1, from: 0), floor, accuracy: 1e-12, "up from silence")
        XCTAssertEqual(fourDB.level(afterPress: -1, from: 0), 0)
    }

    func testFractionKeyStepsAndStepValidationAreUnchanged() {
        XCTAssertEqual(MasterVolumeKeyStep.fraction(denominator: 16).level(afterPress: -1, from: 1), 15.0 / 16, accuracy: 1e-12)
        XCTAssertEqual(MasterVolumeKeyStep.fraction(denominator: 64).level(afterPress: 1, from: 1), 1)
        XCTAssertEqual(MasterVolumeKeyStep.fraction(denominator: 16).level(afterPress: -1, from: 0), 0)
        XCTAssertTrue(MasterVolumeKeyStep.fraction(denominator: 32).isValid)
        XCTAssertFalse(MasterVolumeKeyStep.fraction(denominator: 10).isValid)
        XCTAssertTrue(MasterVolumeKeyStep.decibels(0.5).isValid)
        XCTAssertFalse(MasterVolumeKeyStep.decibels(0).isValid)
        XCTAssertFalse(MasterVolumeKeyStep.decibels(.nan).isValid)
    }

    func testVolumeStepResolutionKeepsStoredValuesAndMapsDecibelSteps() {
        // Raw values are persisted in UserDefaults and backups.
        XCTAssertEqual(ApplicationVolumeStepResolution.standard.rawValue, 16)
        XCTAssertEqual(ApplicationVolumeStepResolution.fine.rawValue, 32)
        XCTAssertEqual(ApplicationVolumeStepResolution.precision.rawValue, 64)
        XCTAssertEqual(ApplicationVolumeStepResolution.fine.keyStep, .fraction(denominator: 32))
        XCTAssertFalse(ApplicationVolumeStepResolution.fine.usesDecibels)
        XCTAssertEqual(
            ApplicationVolumeStepResolution.decibelSteps.map(\.keyStep),
            [.decibels(0.5), .decibels(1), .decibels(1.5), .decibels(3)]
        )
        XCTAssertEqual(
            ApplicationVolumeStepResolution.allCases.filter(\.readoutShowsTenths),
            [.halfDecibel, .oneAndHalfDecibels]
        )
        // The first dB build stored 2 and 4 dB; they map to the nearest steps.
        XCTAssertEqual(ApplicationVolumeStepResolution(storedValue: -20), .oneAndHalfDecibels)
        XCTAssertEqual(ApplicationVolumeStepResolution(storedValue: -40), .threeDecibels)
        XCTAssertEqual(ApplicationVolumeStepResolution(storedValue: 32), .fine)
        XCTAssertNil(ApplicationVolumeStepResolution(storedValue: 7))
        XCTAssertTrue(ApplicationVolumeStepResolution.decibelSteps.allSatisfy(\.usesDecibels))
        XCTAssertEqual(
            Set(ApplicationVolumeStepResolution.fractions + ApplicationVolumeStepResolution.decibelSteps),
            Set(ApplicationVolumeStepResolution.allCases)
        )
        for resolution in ApplicationVolumeStepResolution.allCases {
            XCTAssertTrue(resolution.keyStep.isValid, "\(resolution)")
        }
    }

    func testUserGuideListsALoneSameNameArticleWithoutAHeading() throws {
        let gettingStarted = ProductionUserGuideCatalog.articles.filter { $0.category == .gettingStarted }
        XCTAssertEqual(gettingStarted.map(\.title), ["Getting Started"])
        XCTAssertFalse(ProductionUserGuideCategory.gettingStarted.showsSidebarHeader(for: gettingStarted))

        let processing = ProductionUserGuideCatalog.articles.filter { $0.category == .processing }
        XCTAssertTrue(ProductionUserGuideCategory.processing.showsSidebarHeader(for: processing))
        XCTAssertFalse(ProductionUserGuideCategory.processing.showsSidebarHeader(for: []))
    }

    func testVolumePopupLayoutPlacesGlassPopupBesideOrOverTheSystemPopup() {
        // 1920 × 1080 display with a 30 pt menu bar, as measured on macOS 27.
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1050)
        let system = SystemVolumePopupGeometry.frame(in: visible)
        XCTAssertEqual(system, CGRect(x: 1481, y: 901, width: 352, height: 149))

        let bottom = VolumePopupLayoutFixture.make(.bottomCenter, cover: false, visible)
        XCTAssertEqual(bottom.style, .glass)
        XCTAssertEqual(bottom.frame.midX, visible.midX, accuracy: 0.001)
        XCTAssertEqual(bottom.frame.minY, visible.minY + 84, accuracy: 0.001)
        XCTAssertEqual(
            VolumePopupLayoutFixture.make(.bottomCenter, cover: true, visible),
            bottom,
            "cover only applies at Top Right"
        )

        let beside = VolumePopupLayoutFixture.make(.topRight, cover: false, visible)
        XCTAssertEqual(beside.style, .glass)
        XCTAssertFalse(beside.frame.intersects(system), "glass popup sits beside the system one")
        XCTAssertEqual(beside.frame.maxX, system.minX - 8, accuracy: 0.001)
        XCTAssertEqual(beside.frame.midY, system.midY, accuracy: 0.001)
        XCTAssertTrue(visible.contains(beside.frame))

        let cover = VolumePopupLayoutFixture.make(.topRight, cover: true, visible)
        XCTAssertEqual(cover.style, .solidGlass)
        XCTAssertEqual(cover.frame.width, system.width, accuracy: 0.001)
        XCTAssertEqual(cover.frame.minX, system.minX, accuracy: 0.001)
        XCTAssertEqual(cover.frame.maxY, system.maxY - VolumeFeedbackPopupLayout.coverTopInset, accuracy: 0.001, "just under the menu bar")
        XCTAssertEqual(cover.frame.height, VolumeFeedbackPopupLayout.coverHeight, accuracy: 0.001)
        XCTAssertLessThan(cover.frame.height, system.height, "tighter than the system frame")
        XCTAssertTrue(system.contains(cover.frame))
        XCTAssertGreaterThan(cover.level.rawValue, SystemVolumePopupGeometry.windowLevel.rawValue)
        XCTAssertGreaterThan(cover.displayDuration, SystemVolumePopupGeometry.displayDuration)
    }

    /// While another app is full screen, Follow macOS Popup moves to the top
    /// centre with the system popup, beside it or covering it.
    func testFollowMacOSPopupMovesToTopCentreWhileAnotherAppIsFullScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1050)
        let system = SystemVolumePopupGeometry.fullScreenFrame(in: screen)
        XCTAssertEqual(system.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(system.maxY, screen.maxY, accuracy: 0.001)

        let cover = VolumePopupLayoutFixture.make(.topRight, cover: true, visible, fullScreen: screen)
        XCTAssertEqual(cover.style, .solidGlass)
        XCTAssertEqual(cover.frame.midX, screen.midX, accuracy: 0.001)
        XCTAssertTrue(system.contains(cover.frame))

        let beside = VolumePopupLayoutFixture.make(.topRight, cover: false, visible, fullScreen: screen)
        XCTAssertFalse(beside.frame.intersects(system))
        XCTAssertEqual(beside.frame.maxX, system.minX - 8, accuracy: 0.001)
        XCTAssertTrue(screen.contains(beside.frame))

        XCTAssertEqual(
            VolumePopupLayoutFixture.make(.bottomCenter, cover: false, visible, fullScreen: screen),
            VolumePopupLayoutFixture.make(.bottomCenter, cover: false, visible),
            "Bottom Center ignores full screen"
        )
        XCTAssertEqual(VolumeFeedbackPopupPosition.topRight.displayName, "Follow macOS Popup")
    }

    /// Full screen is a normal-layer window of the frontmost app covering the
    /// screen's whole frame, in CG top-left coordinates, on that screen only.
    func testFullScreenDetectorMatchesOnlyTheFrontmostAppCoveringTheScreen() {
        func window(pid: pid_t, layer: Int = 0, _ rect: CGRect) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: NSNumber(value: pid),
                kCGWindowLayer as String: NSNumber(value: layer),
                kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary,
            ]
        }
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // A 1440 × 900 display above the primary one, in AppKit coordinates.
        let upper = CGRect(x: 0, y: 1080, width: 1440, height: 900)
        func isFullScreen(_ windows: [[String: Any]], on screen: CGRect) -> Bool {
            FullScreenAppDetector.isFullScreen(
                windows: windows,
                ownerPID: 42,
                screenFrame: screen,
                primaryScreenHeight: primary.height
            )
        }

        let fullScreen = window(pid: 42, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertTrue(isFullScreen([fullScreen], on: primary))
        XCTAssertFalse(isFullScreen([fullScreen], on: upper), "only the screen the popup is on")
        XCTAssertTrue(isFullScreen([window(pid: 42, CGRect(x: 0, y: -900, width: 1440, height: 900))], on: upper))

        XCTAssertFalse(isFullScreen([window(pid: 7, CGRect(x: 0, y: 0, width: 1920, height: 1080))], on: primary), "another app")
        XCTAssertFalse(isFullScreen([window(pid: 42, layer: 25, CGRect(x: 0, y: 0, width: 1920, height: 1080))], on: primary), "overlay layer")
        XCTAssertFalse(isFullScreen([window(pid: 42, CGRect(x: 0, y: 30, width: 1920, height: 1050))], on: primary), "zoomed, not full screen")
        XCTAssertFalse(isFullScreen([[kCGWindowOwnerPID as String: NSNumber(value: 42)]], on: primary), "no bounds")
    }

    @MainActor
    func testVolumePopupPreferencesPersistAcrossLaunchesAndBackups() throws {
        let suite = "NotchSixty-VolumePopup-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ApplicationPreferences(defaults: defaults)
        XCTAssertFalse(first.showVolumePopup)
        XCTAssertEqual(first.volumePopupPosition, .bottomCenter)
        XCTAssertFalse(first.coverSystemVolumePopup)
        first.showVolumePopup = true
        first.coverSystemVolumePopup = true
        XCTAssertFalse(first.coversSystemVolumePopup, "cover needs Top Right")
        first.volumePopupPosition = .topRight
        XCTAssertTrue(first.coversSystemVolumePopup)

        let relaunched = ApplicationPreferences(defaults: defaults)
        XCTAssertTrue(relaunched.showVolumePopup)
        XCTAssertEqual(relaunched.volumePopupPosition, .topRight)
        XCTAssertTrue(relaunched.coverSystemVolumePopup)

        var snapshot = relaunched.makeBackupSnapshot()
        XCTAssertEqual(snapshot.volumePopupPosition, "topRight")
        XCTAssertEqual(snapshot.coverSystemVolumePopup, true)

        relaunched.volumePopupPosition = .bottomCenter
        try relaunched.restoreBackupSnapshot(snapshot)
        XCTAssertEqual(relaunched.volumePopupPosition, .topRight)

        snapshot.volumePopupPosition = "nowhere"
        relaunched.volumePopupPosition = .bottomCenter
        try relaunched.restoreBackupSnapshot(snapshot)
        XCTAssertEqual(
            relaunched.volumePopupPosition, .bottomCenter,
            "an unknown position in a backup leaves the current choice alone"
        )
    }

    func testVolumeFeedbackBackupFieldsAreOptionalForLegacySnapshots() throws {
        let json = #"{"appearance":"system","presence":"both","volumeStepResolution":16,"schemaVersion":1}"#
        let decoded = try JSONDecoder().decode(
            NotchSixtyBackupPreferences.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(decoded.showVolumeInMenuBar)
        XCTAssertNil(decoded.showVolumePopup)
        try decoded.validate()
        var updated = decoded
        updated.showVolumeInMenuBar = false
        updated.showVolumePopup = true
        let roundtrip = try JSONDecoder().decode(
            NotchSixtyBackupPreferences.self,
            from: JSONEncoder().encode(updated)
        )
        XCTAssertEqual(roundtrip.showVolumeInMenuBar, false)
        XCTAssertEqual(roundtrip.showVolumePopup, true)
    }

    func testDashboardIsStandaloneAndEverySectionIsReachable() {
        let grouped =
            ProductionSection.playback
            + ProductionSection.systemAreaSections
            + ProductionSection.systemAreaTools
            + ProductionSection.extensions

        XCTAssertFalse(grouped.contains(.dashboard))
        XCTAssertEqual(Set(grouped).count, grouped.count)
        XCTAssertEqual(
            Set(grouped.map { $0.systemAreaDestination.section }
                + ProductionSection.developerTools + [.dashboard])
                .union(ProductionSection.allCases.filter { $0.systemAreaDestination.section == .system }),
            Set(ProductionSection.allCases),
            "every section is in the sidebar or the Developer menu (.system is the System area row)"
        )
        XCTAssertTrue(Set(grouped).isDisjoint(with: ProductionSection.developerTools))
    }

    func testPlaybackGroupContainsOnlyContentFacingDailyControls() {
        XCTAssertEqual(
            ProductionSection.playback,
            [.equalizer, .dynamics, .meters]
        )
    }

    func testSystemAreaGroupsContainTheSystemRowAndAcoustics() {
        XCTAssertEqual(ProductionSection.systemAreaSections, [.system, .headphones, .activeAcoustics])
        XCTAssertEqual(ProductionSection.systemAreaTools, [.blindListening])
    }

    func testSidebarGroupsLeaveDeveloperToolsToTheDeveloperMenu() {
        let groups = ProductionSection.sidebarGroups()
        XCTAssertEqual(groups.map(\.title), ["Playback", "System", "Tools", "Extensions"])
        XCTAssertEqual(
            groups.map(\.sections),
            [
                ProductionSection.playback,
                ProductionSection.systemAreaSections,
                ProductionSection.systemAreaTools,
                ProductionSection.extensions,
            ]
        )
    }

    func testSidebarKeepsASelectedDeveloperToolVisible() {
        for tool in ProductionSection.developerTools {
            let groups = ProductionSection.sidebarGroups(selection: tool)
            XCTAssertEqual(groups.last?.title, "Developer")
            XCTAssertEqual(groups.last?.sections, [tool])
        }
        let groups = ProductionSection.sidebarGroups(selection: .equalizer)
        XCTAssertFalse(groups.map(\.title).contains("Developer"))
    }

    func testDeveloperToolsKeepTheirTitles() {
        XCTAssertEqual(
            ProductionSection.developerTools.map(\.title),
            ["Hardware Acceptance", "Acoustic Research"]
        )
    }

    func testDynamicsNavigatorListsEveryProcessorOnce() {
        let modules = ProductionDynamicsLayout.groups.flatMap(\.modules)
        XCTAssertEqual(modules.count, ProductionDynamicsModule.allCases.count)
        XCTAssertEqual(Set(modules), Set(ProductionDynamicsModule.allCases))
    }

    /// The order the engine runs these processors: input headroom gain, the
    /// pre-EQ stages, then core dynamics after room correction, the pause
    /// gate, and protection (`docs/DSP_KERNEL.md`, `N60Dynamics.c`,
    /// `N60Protection.c`). Oversampling sets the protection stage's rate.
    func testDynamicsNavigatorFollowsTheEngineStageOrder() {
        let engineOrder: [ProductionDynamicsModule] = [
            .automaticHeadroom,
            .dcOffset, .infrasonic, .mainsHum, .denoiser,
            .stereoMode, .stereoWidener,
            .loudnessMatch, .loudnessContour, .dialogueLeveler,
            .deHarsh, .deEsser,
            .multiband, .compressor, .expander,
            .pauseGate,
            .gainRider, .softClipper, .limiter, .oversampling,
        ]
        XCTAssertEqual(ProductionDynamicsLayout.groups.flatMap(\.modules), engineOrder)
    }

    func testDynamicsNavigatorFoldsOnlyNicheProcessorsAndNotesTheEQBoundary() {
        let groups = ProductionDynamicsLayout.groups
        XCTAssertEqual(
            groups.map(\.title),
            ["Input & Clean-up", "Stereo", "Level & Dialogue", "Tone", "Dynamics", "Output"]
        )
        XCTAssertEqual(
            Set(groups.flatMap(\.more)),
            [.dcOffset, .denoiser, .deEsser, .expander, .oversampling]
        )
        for group in groups {
            XCTAssertFalse(group.shown.isEmpty, "\(group.title) needs a visible processor")
        }
        XCTAssertEqual(groups[0].note, "Runs before EQ and room correction.")
        XCTAssertEqual(groups[1].note, "Runs after EQ and room correction.")
        XCTAssertEqual(groups.dropFirst(2).compactMap(\.note), [])
    }

    func testFoldedMoreRowShowsABadgeWhenAProcessorUnderItIsOn() throws {
        let input = try XCTUnwrap(ProductionDynamicsLayout.groups.first)
        XCTAssertFalse(input.moreHasActiveModule { _ in false })
        XCTAssertTrue(input.moreHasActiveModule { $0 == .denoiser })
        XCTAssertFalse(
            input.moreHasActiveModule { $0 == .mainsHum },
            "a visible processor that is on does not badge More"
        )
    }

    func testMeasurementLabTabsCoverEveryModeOnce() {
        let measure = SpeakerMeasurementLabTab.measure.modes
        let advanced = SpeakerMeasurementLabTab.advanced.modes
        XCTAssertEqual(measure, [.wholeSpeakerOnAxis, .subwooferNearField, .coherentMainsSubTiming])
        XCTAssertEqual(advanced, [.wholeSpeakerOffAxis, .protectedDriverNearField, .driverNearField])
        XCTAssertEqual(SpeakerMeasurementLabTab.analysis.modes, [], "Analysis has no protocol modes")
        XCTAssertEqual(
            SpeakerMeasurementLabTab.allCases, [.measure, .analysis, .advanced], "Analysis sits between Measure and Advanced")
        XCTAssertEqual(Set(measure + advanced), Set(SpeakerMeasurementLabMode.allCases))
        XCTAssertEqual(measure.count + advanced.count, SpeakerMeasurementLabMode.allCases.count)
        XCTAssertEqual(
            SpeakerMeasurementLabTab.tab(for: SpeakerMeasurementLabProtocolDraft().mode),
            .measure,
            "a new protocol draft starts in the Measure tab"
        )
    }

    func testExtensionsGroupContainsPluginRackEntryPoint() {
        XCTAssertEqual(
            ProductionSection.extensions,
            [.plugins]
        )
    }

    func testRenamedAndNewTitlesMatchProductLanguage() {
        XCTAssertEqual(ProductionSection.dashboard.title, "Dashboard")
        XCTAssertEqual(ProductionSection.speakers.title, "Speakers")
        XCTAssertEqual(
            ProductionSection.measurementLab.title,
            "Measurement Lab"
        )
        XCTAssertEqual(
            ProductionSection.activeAcoustics.title,
            "Active Acoustics"
        )
        XCTAssertEqual(
            ProductionSection.roomAdvisor.title,
            "Room Advisor"
        )
        XCTAssertEqual(
            ProductionSection.blindListening.title,
            "Blind Listening"
        )
        XCTAssertEqual(
            ProductionSection.acousticResearch.title,
            "Acoustic Research"
        )
        XCTAssertEqual(
            ProductionSection.hardwareAcceptance.title,
            "Hardware Acceptance"
        )
        XCTAssertEqual(ProductionSection.plugins.title, "Plug-ins")
    }

    func testActiveAcousticsUXRequiresCalibrationBeforeTimingReview() {
        let snapshot = ActiveAcousticsCommissioningUXSnapshot(
            calibrationPlanned: false,
            timingReadiness: .missingMeasurements
        )

        XCTAssertEqual(snapshot.state, .calibrationRequired)
        XCTAssertEqual(snapshot.timingCaption, "MEASUREMENTS REQUIRED")
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
        XCTAssertFalse(snapshot.emergencyMuteHardwareVerified)
        XCTAssertFalse(snapshot.liveANCOutputAuthorized)
    }

    func testPhysicallyPlausibleTimingStillRequiresHardwareVerification() {
        let snapshot = ActiveAcousticsCommissioningUXSnapshot(
            calibrationPlanned: true,
            timingReadiness: .physicallyPlausible
        )

        XCTAssertEqual(snapshot.state, .timingPlausibleHardwareRequired)
        XCTAssertEqual(snapshot.timingCaption, "DIAGNOSTIC PASS")
        XCTAssertTrue(snapshot.nextAction.contains("PR99 A/B/A"))
        XCTAssertFalse(snapshot.liveANCOutputAuthorized)
    }

    func testNonCausalTimingNeverLooksReady() {
        let snapshot = ActiveAcousticsCommissioningUXSnapshot(
            calibrationPlanned: true,
            timingReadiness: .nonCausal
        )

        XCTAssertEqual(snapshot.state, .timingUnqualified)
        XCTAssertEqual(snapshot.timingCaption, "NON-CAUSAL")
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
    }


    func testConsolidatedDiagnosticsKeepPhysicalGatesSeparate() {
        let budget = QuietZoneFeedForwardBudget(
            readiness: .physicallyPlausible,
            acousticPreviewSeconds: 0.020,
            conservativePreviewSeconds: 0.015,
            antiNoisePathSeconds: 0.010,
            conservativeReserveSeconds: 0.005,
            geometryOnly: false,
            runtimeAvailable: false,
            explanation: "Synthetic diagnostic fixture"
        )
        let snapshot = ActiveAcousticsDiagnosticsUXSnapshot(
            calibration: nil,
            budget: budget
        )

        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "causality" })?.disposition,
            .diagnosticPass
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "acoustic" })?.disposition,
            .hardwareRequired
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "mute" })?.disposition,
            .hardwareRequired
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "output" })?.disposition,
            .disconnected
        )
        XCTAssertGreaterThan(snapshot.unresolvedCount, 0)
    }

    func testConsolidatedDiagnosticsExposeMissingCommissioningRecords() {
        let snapshot = ActiveAcousticsDiagnosticsUXSnapshot(
            calibration: nil,
            budget: .missing
        )

        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "plan" })?.disposition,
            .blocked
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "clock" })?.disposition,
            .blocked
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "path" })?.disposition,
            .blocked
        )
        XCTAssertTrue(snapshot.headline.contains("blockers"))
    }


    func testPhysicalCampaignPlanPreservesABAAndEvidenceCounts() {
        let campaign = ActiveAcousticsPhysicalCampaignUXSnapshot()

        XCTAssertEqual(campaign.visits.map(\.positionLabel), ["A", "B", "A"])
        XCTAssertEqual(campaign.totalSourceCaptures, 9)
        XCTAssertEqual(campaign.totalFaultWitnesses, 15)
        XCTAssertFalse(campaign.physicalVerificationComplete)
        XCTAssertFalse(campaign.instrumentProvenanceAuthenticated)
        XCTAssertFalse(campaign.liveOutputAuthorized)
    }


    private func makePhysicalEvidencePackage(
        validDigest: Bool = true
    ) throws -> QuietZonePhysicalEvidencePackage {
        let rig = QuietZoneHardwareCalibrationRig(
            projectID: UUID(),
            microphoneID: "test-mic",
            microphoneChannel: 0,
            outputDeviceID: "test-dac",
            routeID: "route-1",
            sampleRate: 96_000,
            clockID: "clock-1",
            triggerID: "fixture-1"
        )
        let campaign = QuietZonePhysicalVerificationReview(
            rig: rig,
            sessionIDs: [UUID(), UUID(), UUID()],
            firstPrimaryReductionDB: 5.0,
            neighboringSeatReductionDB: 2.0,
            returningPrimaryReductionDB: 4.6,
            worstMeasuredBandReductionDB: 1.0,
            largestPrimaryBaselineDifferenceDB: 0.7,
            primaryReductionRepeatDifferenceDB: 0.4,
            worstReportedShutdownSeconds: 0.050,
            uniqueExternalLaunchCount: 24
        )
        let rows = [["SCHEMA", "PR99_PHYSICAL_EVIDENCE", "1"]]
        let data = try JSONEncoder().encode(rows)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let actualDigest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let digest = validDigest
            ? actualDigest
            : String(repeating: "0", count: 64)
        return QuietZonePhysicalEvidencePackage(
            schemaVersion: 1,
            canonicalJSON: json,
            sha256Hex: digest,
            frequencyResults: [
                .init(
                    frequencyHz: 40,
                    primaryFirstReductionDB: 5.0,
                    neighboringSeatReductionDB: 2.0,
                    primaryReturnReductionDB: 4.6,
                    primaryRepeatDifferenceDB: 0.4,
                    worstObservedReductionDB: 2.0,
                    primaryFourBaselineSpanDB: 0.5
                ),
                .init(
                    frequencyHz: 80,
                    primaryFirstReductionDB: 4.0,
                    neighboringSeatReductionDB: 1.5,
                    primaryReturnReductionDB: 3.8,
                    primaryRepeatDifferenceDB: 0.2,
                    worstObservedReductionDB: 1.5,
                    primaryFourBaselineSpanDB: 0.7
                ),
                .init(
                    frequencyHz: 120,
                    primaryFirstReductionDB: 3.5,
                    neighboringSeatReductionDB: 1.0,
                    primaryReturnReductionDB: 3.2,
                    primaryRepeatDifferenceDB: 0.3,
                    worstObservedReductionDB: 1.0,
                    primaryFourBaselineSpanDB: 0.6
                ),
            ],
            campaignReview: campaign,
            maximumPrimaryBandRepeatDifferenceDB: 0.4,
            worstFrequencyReductionDB: 1.0,
            rawSourceLaunchCount: 9,
            rawFaultWitnessCount: 15
        )
    }



    private func makeReviewPacket(
        for package: QuietZonePhysicalEvidencePackage,
        includeRecords: Bool = true
    ) -> QuietZoneExternalReviewPacket {
        let reviews: [QuietZoneExternalReviewAcknowledgment] =
            includeRecords
                ? [
                    .init(
                        role: .acoustics,
                        reviewerID: "acoustics-reviewer",
                        evidenceSHA256Hex: package.sha256Hex,
                        reviewedAt: Date(timeIntervalSince1970: 1_000),
                        decision: .recommendFurtherHardwareReview,
                        notes: "Numerical acoustic evidence reviewed."
                    ),
                    .init(
                        role: .electricalSafety,
                        reviewerID: "safety-reviewer",
                        evidenceSHA256Hex: package.sha256Hex,
                        reviewedAt: Date(timeIntervalSince1970: 1_030),
                        decision: .recommendFurtherHardwareReview,
                        notes: "Fault witness metadata reviewed."
                    ),
                ]
                : []

        return QuietZoneExternalReviewPacket(
            evidenceSHA256Hex: package.sha256Hex,
            reviews: reviews,
            numericalAcceptance: true,
            independentRolesAcknowledged: true
        )
    }

    func testPhysicalEvidenceUXWaitsForRealCampaign() {
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: nil,
            reviewPacket: nil
        )

        XCTAssertEqual(snapshot.state, .awaitingCampaign)
        XCTAssertTrue(snapshot.curvePoints.isEmpty)
        XCTAssertNil(snapshot.initialPrimaryReductionDB)
        XCTAssertFalse(snapshot.digestIntegrityVerified)
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
        XCTAssertFalse(snapshot.emergencyMuteHardwareVerified)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testPhysicalEvidenceUXShowsVerifiedNumericalPackageWithoutAuthorizingANC()
        throws {
        let package = try makePhysicalEvidencePackage()
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: nil
        )

        XCTAssertEqual(snapshot.state, .numericalEvidenceAvailable)
        XCTAssertTrue(snapshot.digestIntegrityVerified)
        XCTAssertEqual(snapshot.curvePoints.count, 3)
        XCTAssertEqual(snapshot.initialPrimaryReductionDB, 5.0)
        XCTAssertEqual(snapshot.neighboringSeatReductionDB, 2.0)
        XCTAssertEqual(snapshot.returningPrimaryReductionDB, 4.6)
        XCTAssertEqual(snapshot.worstSeatReductionDB, 2.0)
        XCTAssertEqual(snapshot.worstFrequencyReductionDB, 1.0)
        XCTAssertEqual(snapshot.largestPrimaryBaselineDifferenceDB, 0.7)
        XCTAssertFalse(snapshot.independentRolesAcknowledged)
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testPhysicalEvidenceUXSuppressesTamperedPackageMetrics() throws {
        let package = try makePhysicalEvidencePackage(validDigest: false)
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: nil
        )

        XCTAssertEqual(snapshot.state, .invalidPackage)
        XCTAssertFalse(snapshot.digestIntegrityVerified)
        XCTAssertTrue(snapshot.curvePoints.isEmpty)
        XCTAssertNil(snapshot.initialPrimaryReductionDB)
        XCTAssertNil(snapshot.worstFrequencyReductionDB)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testTwoRoleReviewStillDoesNotAuthenticatePhysicalEvidence() throws {
        let package = try makePhysicalEvidencePackage()
        let packet = makeReviewPacket(for: package)
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: packet
        )

        XCTAssertEqual(snapshot.state, .roleReviewAcknowledged)
        XCTAssertTrue(snapshot.independentRolesAcknowledged)
        XCTAssertFalse(snapshot.instrumentEvidenceAuthenticated)
        XCTAssertFalse(snapshot.physicalAttenuationVerified)
        XCTAssertFalse(snapshot.emergencyMuteHardwareVerified)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testClaimedReviewBoolWithoutRoleRecordsIsNotAccepted() throws {
        let package = try makePhysicalEvidencePackage()
        let packet = makeReviewPacket(for: package, includeRecords: false)
        let snapshot = ActiveAcousticsPhysicalEvidenceUXSnapshot(
            package: package,
            reviewPacket: packet
        )

        XCTAssertEqual(snapshot.state, .numericalEvidenceAvailable)
        XCTAssertFalse(snapshot.independentRolesAcknowledged)
        XCTAssertFalse(snapshot.liveOutputAuthorized)
    }

    func testEvidenceProvenanceShowsDigestValidRecordButNotAuthentication()
        throws {
        let package = try makePhysicalEvidencePackage()
        let packet = makeReviewPacket(for: package)
        let provenance = ActiveAcousticsEvidenceProvenanceUXSnapshot(
            package: package,
            reviewPacket: packet
        )

        XCTAssertEqual(provenance.microphoneID, "test-mic")
        XCTAssertEqual(provenance.microphoneChannel, 0)
        XCTAssertEqual(provenance.outputDeviceID, "test-dac")
        XCTAssertEqual(provenance.routeID, "route-1")
        XCTAssertEqual(provenance.sampleRate, 96_000)
        XCTAssertEqual(provenance.clockID, "clock-1")
        XCTAssertEqual(provenance.triggerID, "fixture-1")
        XCTAssertEqual(provenance.sessionCount, 3)
        XCTAssertEqual(provenance.sourceCaptureCount, 9)
        XCTAssertEqual(provenance.faultWitnessCount, 15)
        XCTAssertEqual(
            Set(provenance.acknowledgedReviewRoles),
            Set(["Acoustics", "Electrical safety"])
        )
        XCTAssertFalse(provenance.reviewerIdentityCryptographicallyVerified)
        XCTAssertFalse(provenance.instrumentEvidenceIndependentlyAuthenticated)
        XCTAssertFalse(provenance.liveOutputAuthorized)
    }


    func testUserGuideCoversEveryProductionWorkspace() {
        XCTAssertTrue(
            ProductionUserGuideCatalog.uncoveredProductionSections.isEmpty
        )

        for section in ProductionSection.allCases {
            let articleID = ProductionUserGuideCatalog.articleID(for: section)
            XCTAssertNotNil(
                ProductionUserGuideCatalog.article(id: articleID),
                "Missing guide article for \(section.title)"
            )
        }
    }

    func testUserGuideIdentifiersAreStableAndUnique() {
        let articles = ProductionUserGuideCatalog.articles
        XCTAssertEqual(
            Set(articles.map(\.id)).count,
            articles.count
        )

        for article in articles {
            XCTAssertEqual(
                Set(article.sections.map(\.id)).count,
                article.sections.count,
                "Duplicate section ID in \(article.id)"
            )
            XCTAssertEqual(
                Set(article.formulas.map(\.id)).count,
                article.formulas.count,
                "Duplicate formula ID in \(article.id)"
            )
        }
    }

    func testUserGuideSearchFindsFeatureMathAndSafetyLanguage() {
        XCTAssertTrue(
            ProductionUserGuideCatalog.search("compressor ratio")
                .contains { $0.id == "dynamics" }
        )
        XCTAssertTrue(
            ProductionUserGuideCatalog.search("transfer function impulse")
                .contains { $0.id == "measurement-lab" }
        )
        XCTAssertTrue(
            ProductionUserGuideCatalog.search("physical evidence H08")
                .contains { $0.id == "hardware-acceptance" }
        )
        XCTAssertTrue(
            ProductionUserGuideCatalog.search("causality budget")
                .contains { $0.id == "active-acoustics" }
        )
    }

    func testMathBearingGuideArticlesExplainFormulaScope() throws {
        let requiredMathArticles = [
            "dashboard",
            "equalizer",
            "dynamics",
            "meters",
            "speakers",
            "headphones",
            "speaker-calibration",
            "measurement-lab",
            "room-correction",
            "active-acoustics",
            "room-advisor",
            "math-reference",
        ]

        for id in requiredMathArticles {
            let article = try XCTUnwrap(
                ProductionUserGuideCatalog.article(id: id)
            )
            XCTAssertFalse(article.formulas.isEmpty, id)
            for formula in article.formulas {
                XCTAssertFalse(formula.expression.isEmpty, formula.id)
                XCTAssertFalse(formula.explanation.isEmpty, formula.id)
                XCTAssertFalse(formula.scope.title.isEmpty, formula.id)
            }
        }
    }

    func testGuideKeepsSoftwareAndPhysicalAuthorityDistinct() throws {
        let acceptance = try XCTUnwrap(
            ProductionUserGuideCatalog.article(id: "hardware-acceptance")
        )
        XCTAssertTrue(
            acceptance.searchableText.contains("ci test labeled pass")
        )
        XCTAssertTrue(
            acceptance.searchableText.contains("physical-hardware evidence")
        )
        XCTAssertTrue(
            acceptance.searchableText.contains("independent physical review")
        )
    }


    @MainActor
    func testReferenceNavigatorRoutesGuideAndDSPDeepLinks() {
        let navigator = ProductionReferenceNavigator()

        navigator.openGuide(articleID: "room-correction")
        XCTAssertEqual(navigator.mode, .userGuide)
        XCTAssertEqual(navigator.selectedArticleID, "room-correction")
        XCTAssertNil(navigator.selectedFormulaID)

        navigator.openDSPReference(
            articleID: "dynamics",
            formulaID: "compressor-ratio"
        )
        XCTAssertEqual(navigator.mode, .dspReference)
        XCTAssertEqual(navigator.selectedArticleID, "dynamics")
        XCTAssertEqual(navigator.selectedFormulaID, "compressor-ratio")
    }

    @MainActor
    func testReferenceNavigatorStartsInGuideAndFiltersDSPModeToMathArticles() throws {
        let navigator = ProductionReferenceNavigator()
        XCTAssertEqual(navigator.mode, .userGuide)
        XCTAssertEqual(
            navigator.articles(matching: "").count,
            ProductionUserGuideCatalog.articles.count
        )

        let plain = try XCTUnwrap(
            ProductionUserGuideCatalog.articles.first { $0.formulas.isEmpty }
        )
        navigator.openGuide(articleID: plain.id)
        XCTAssertEqual(navigator.displayedArticle(matching: "")?.id, plain.id)

        // Switching to DSP Reference with an equation-free selection falls
        // back to the first math article instead of showing an empty pane.
        navigator.mode = .dspReference
        let math = navigator.articles(matching: "")
        XCTAssertFalse(math.isEmpty)
        XCTAssertTrue(math.allSatisfy { !$0.formulas.isEmpty })
        XCTAssertEqual(navigator.displayedArticle(matching: "")?.id, math.first?.id)

        navigator.openDSPReference(articleID: "dynamics")
        XCTAssertEqual(navigator.displayedArticle(matching: "")?.id, "dynamics")
        XCTAssertNil(
            navigator.displayedArticle(matching: "zzzz-no-such-term-zzzz")
        )
    }

    func testWorkflowVocabularySeparatesDraftAndLiveRecoverySemantics() {
        XCTAssertEqual(
            Set(ProductionWorkflowTerm.allCases.map(\.rawValue)),
            Set(["Preview", "Apply", "Verify", "Revert", "Rollback", "Deploy"])
        )
        XCTAssertTrue(
            ProductionWorkflowTerm.preview.definition
                .contains("without changing saved or live playback state")
        )
        XCTAssertTrue(
            ProductionWorkflowTerm.revert.definition
                .contains("before a live Apply")
        )
        XCTAssertTrue(
            ProductionWorkflowTerm.rollback.definition
                .contains("after a live or saved change")
        )
        XCTAssertTrue(
            ProductionWorkflowTerm.verify.definition
                .contains("fresh evidence")
        )
    }

    func testReferenceSearchFindsWorkflowAndDSPGlossaryTerms() {
        let workflow = ProductionUserGuideCatalog.search("rollback evidence")
        XCTAssertTrue(workflow.contains { $0.id == "workflow-glossary" })

        let dsp = ProductionUserGuideCatalog.search("dBTP headroom")
        XCTAssertTrue(dsp.contains { $0.id == "workflow-glossary" })

        let coherence = ProductionUserGuideCatalog.search("coherence confidence")
        XCTAssertTrue(coherence.contains { $0.id == "workflow-glossary" })
    }


    func testRoomCorrectionReferenceMatchesMinimumPhaseImplementation() throws {
        let article = try XCTUnwrap(
            ProductionUserGuideCatalog.article(id: "room-correction")
        )
        let formula = try XCTUnwrap(
            article.formulas.first { $0.id == "minimum-phase-fir" }
        )

        XCTAssertTrue(formula.title.contains("Minimum-phase"))
        XCTAssertTrue(formula.explanation.contains("causal minimum-phase"))
        XCTAssertTrue(formula.expression.contains("IFFT"))
        XCTAssertTrue(
            formula.explanation.contains("not a symmetric linear-phase FIR")
        )
    }


    func testABAuditionStateContainsOnlySafeContentDSP() {
        let audition = ContentABAuditionState(
            contentState: ContentPresetState()
        )
        let labels = Set(
            Mirror(reflecting: audition).children.compactMap { $0.label }
        )

        XCTAssertEqual(
            labels,
            Set([
                "stereoEQ",
                "inputPreampDB",
                "headroomAttenuationDB",
                "dynamics",
            ])
        )
        XCTAssertFalse(labels.contains("audioUnitRack"))
        XCTAssertFalse(labels.contains("outputRouting"))
        XCTAssertFalse(labels.contains("bassManagement"))
        XCTAssertFalse(labels.contains("roomCorrection"))
        XCTAssertFalse(labels.contains("speakerIR"))
        XCTAssertFalse(labels.contains("speakerDriverProcessing"))
        XCTAssertFalse(labels.contains("outputGainDB"))
    }

    func testABAuditionMergePreservesCurrentAudioUnitRack() {
        let base = ContentPresetState()
        let audition = ContentABAuditionState(
            stereoEQ: StereoEQConfiguration(),
            inputPreampDB: -3.0,
            headroomAttenuationDB: -1.5,
            dynamics: DynamicsConfiguration()
        )

        let merged = audition.merging(into: base)

        XCTAssertEqual(merged.stereoEQ, audition.stereoEQ)
        XCTAssertEqual(merged.inputPreampDB, -3.0)
        XCTAssertEqual(merged.headroomAttenuationDB, -1.5)
        XCTAssertEqual(merged.dynamics, audition.dynamics)
        XCTAssertEqual(merged.audioUnitRack, base.audioUnitRack)
    }

    func testABSystemBoundaryFailsClosedOnIdentityAndStateDrift() {
        let systemID = UUID()
        let state = PlaybackSystemState()
        let boundary = ContentABSystemBoundary(
            selectedSystemProfileID: systemID,
            systemState: state
        )

        XCTAssertEqual(
            boundary.compatibility(
                currentSystemProfileID: systemID,
                currentSystemState: state
            ),
            .ready
        )

        XCTAssertEqual(
            boundary.compatibility(
                currentSystemProfileID: UUID(),
                currentSystemState: state
            ),
            .playbackSystemChanged
        )

        var changedState = state
        changedState.outputGainDB = -1.0
        XCTAssertEqual(
            boundary.compatibility(
                currentSystemProfileID: systemID,
                currentSystemState: changedState
            ),
            .playbackSystemStateChanged
        )
    }

    func testABSlotsHaveStableIdentityAndOpposites() {
        XCTAssertEqual(ContentABSlot.allCases, [.a, .b])
        XCTAssertEqual(ContentABSlot.a.displayName, "A")
        XCTAssertEqual(ContentABSlot.b.displayName, "B")
        XCTAssertEqual(ContentABSlot.a.opposite, .b)
        XCTAssertEqual(ContentABSlot.b.opposite, .a)
    }


    func testABLoudnessMatchOnlyAttenuatesTheLouderCapture() throws {
        let plan = try XCTUnwrap(
            ContentABLoudnessMatchPlan.make(
                aLUFS: -14.0,
                bLUFS: -17.0
            )
        )

        XCTAssertEqual(plan.referenceLUFS, -17.0, accuracy: 0.0001)
        XCTAssertEqual(plan.attenuationA_DB, -3.0, accuracy: 0.0001)
        XCTAssertEqual(plan.attenuationB_DB, 0.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(plan.attenuationA_DB, 0)
        XCTAssertLessThanOrEqual(plan.attenuationB_DB, 0)
    }

    func testABLoudnessMatchIsBoundedAndRequiresValidSignal() throws {
        let bounded = try XCTUnwrap(
            ContentABLoudnessMatchPlan.make(
                aLUFS: -10.0,
                bLUFS: -30.0
            )
        )
        XCTAssertEqual(
            bounded.attenuationA_DB,
            -ContentABLoudnessMatchPlan.maximumAttenuationDB,
            accuracy: 0.0001
        )
        XCTAssertEqual(bounded.attenuationB_DB, 0, accuracy: 0.0001)

        XCTAssertNil(
            ContentABLoudnessMatchPlan.make(
                aLUFS: nil,
                bLUFS: -18
            )
        )
        XCTAssertNil(
            ContentABLoudnessMatchPlan.make(
                aLUFS: -70,
                bLUFS: -18
            )
        )
    }

    func testABSnapshotCanCarryMeasuredLoudnessWithoutBroadeningAuditionState() throws {
        let snapshot = ContentABSnapshot(
            sourceContentPresetID: nil,
            sourceContentPresetName: "Fixture",
            loudnessReferenceLUFS: -18.5,
            auditionState: ContentABAuditionState(
                contentState: ContentPresetState()
            ),
            systemBoundary: ContentABSystemBoundary(
                selectedSystemProfileID: nil,
                systemState: PlaybackSystemState()
            )
        )

        XCTAssertEqual(
            try XCTUnwrap(snapshot.loudnessReferenceLUFS),
            -18.5,
            accuracy: 0.0001
        )

        let labels = Set(
            Mirror(reflecting: snapshot.auditionState)
                .children.compactMap { $0.label }
        )
        XCTAssertEqual(
            labels,
            Set([
                "stereoEQ",
                "inputPreampDB",
                "headroomAttenuationDB",
                "dynamics",
            ])
        )
    }


    @MainActor
    func testBackupRestoreMarksUnavailablePlaybackHardwareForMapping()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profiles = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: root.appendingPathComponent("profiles.json")
        )
        let content = ContentPreset(
            name: "Backup Content",
            origin: .user,
            state: ContentPresetState()
        )
        let system = PlaybackSystemProfile(
            name: "Backup System",
            state: PlaybackSystemState(
                associatedOutputUID: "missing-output"
            )
        )
        let snapshot = ProductProfileBackupSnapshot(
            contentPresets: [content],
            systemProfiles: [system],
            selectedContentPresetID: content.id,
            selectedSystemProfileID: system.id
        )

        let report = try profiles.restoreBackupSnapshot(
            snapshot,
            availableOutputUIDs: []
        )

        XCTAssertEqual(
            report.hardwareMappingRequiredSystemIDs,
            [system.id]
        )
        XCTAssertNil(profiles.selectedSystemProfileID)
        let requirement = try XCTUnwrap(
            profiles.hardwareMappingRequirement(for: system.id)
        )
        XCTAssertEqual(
            requirement.importedDeviceUIDs,
            ["missing-output"]
        )
    }

    @MainActor
    func testBackupRestoreKeepsKnownHardwareEligibleWithoutRemapping()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profiles = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: root.appendingPathComponent("profiles.json")
        )
        let content = ContentPreset(
            name: "Backup Content",
            origin: .user,
            state: ContentPresetState()
        )
        let system = PlaybackSystemProfile(
            name: "Known System",
            state: PlaybackSystemState(
                associatedOutputUID: "known-output"
            )
        )
        let snapshot = ProductProfileBackupSnapshot(
            contentPresets: [content],
            systemProfiles: [system],
            selectedContentPresetID: content.id,
            selectedSystemProfileID: system.id
        )

        let report = try profiles.restoreBackupSnapshot(
            snapshot,
            availableOutputUIDs: ["known-output"]
        )

        XCTAssertTrue(
            report.hardwareMappingRequiredSystemIDs.isEmpty
        )
        XCTAssertEqual(profiles.selectedSystemProfileID, system.id)
        XCTAssertNil(
            profiles.hardwareMappingRequirement(for: system.id)
        )
    }

    func testBackupPreferencesExcludeOSOwnedLaunchState() throws {
        let preferences = NotchSixtyBackupPreferences(
            appearance: "dark",
            presence: "both",
            volumeStepResolution: 64
        )
        XCTAssertNoThrow(try preferences.validate())

        let labels = Set(
            Mirror(reflecting: preferences).children
                .compactMap { $0.label }
        )
        XCTAssertFalse(labels.contains("launchAtLogin"))
        XCTAssertFalse(labels.contains("launchAtLoginEnabled"))
        XCTAssertFalse(labels.contains("permissions"))

        let invalid = NotchSixtyBackupPreferences(
            appearance: "invalid",
            presence: "both",
            volumeStepResolution: 64
        )
        XCTAssertThrowsError(try invalid.validate())
    }

    @MainActor
    func testBackupInspectionRejectsDomainTampering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let profiles = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: root.appendingPathComponent("profiles.json")
        )
        let backup = NotchSixtyBackupService(
            profiles: profiles,
            roomStore: RoomCorrectionProjectStore(
                rootDirectory: root.appendingPathComponent(
                    "room",
                    isDirectory: true
                )
            ),
            labStore: SpeakerMeasurementLabSessionStore(
                rootDirectory: root.appendingPathComponent(
                    "lab",
                    isDirectory: true
                )
            ),
            binauralStore: BinauralProfileAssetStore(
                rootURL: root.appendingPathComponent(
                    "binaural",
                    isDirectory: true
                )
            )
        )
        let preferences = NotchSixtyBackupPreferences(
            appearance: "dark",
            presence: "both",
            volumeStepResolution: 32
        )

        let original = try backup.exportData(
            preferences: preferences,
            appVersion: "1.0",
            appBuild: "1",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertNoThrow(try backup.inspect(original))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original)
                as? [String: Any]
        )
        var profilesJSON = try XCTUnwrap(
            object["profiles"] as? [String: Any]
        )
        var presets = try XCTUnwrap(
            profilesJSON["contentPresets"]
                as? [[String: Any]]
        )
        XCTAssertFalse(presets.isEmpty)
        presets[0]["name"] = "Tampered"
        profilesJSON["contentPresets"] = presets
        object["profiles"] = profilesJSON

        let tampered = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try backup.inspect(tampered)
        ) { error in
            guard let backupError =
                    error as? NotchSixtyBackupError,
                  case .integrityMismatch(let domain) =
                    backupError else {
                return XCTFail(
                    "Expected integrity mismatch, got \(error)"
                )
            }
            XCTAssertEqual(domain, "profiles")
        }
    }


    @MainActor
    func testLocalOfflineRoutingDoesNotAcquireImportMappingGate()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("profiles.json")
        let profiles = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: storageURL
        )
        let routing = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: [
                SpeakerOutputRoute(
                    name: "Left Main",
                    bus: .leftFullRange,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "offline-main-dac",
                        channelIndex: 0
                    )
                ),
                SpeakerOutputRoute(
                    name: "Right Main",
                    bus: .rightFullRange,
                    destination: PhysicalOutputEndpoint(
                        deviceUID: "offline-main-dac",
                        channelIndex: 1
                    )
                ),
            ],
            synchronizationMode: .softwarePLL,
            referenceDeviceUID: "offline-main-dac"
        )

        try profiles.replaceSelectedSystemOutputRouting(routing)
        XCTAssertNil(
            profiles.selectedSystemHardwareMappingRequirement
        )

        let restored = ProductProfileController(
            engine: AudioIOEngine(),
            storageURL: storageURL
        )
        XCTAssertEqual(
            restored.selectedSystemProfile?.state.outputRouting,
            routing
        )
        XCTAssertNil(
            restored.selectedSystemHardwareMappingRequirement
        )
    }


    func testInstanceLockAdmitsOneHolderAndReleasesWhenItEnds() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "instance-lock-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("instance.lock")

        do {
            // The holder lives only in this scope, like a process lifetime.
            guard case .acquired(let holder) = ProductInstanceLock.acquire(
                at: url
            ) else {
                return XCTFail("First instance must acquire the lock")
            }
            guard case .heldByAnotherInstance = ProductInstanceLock.acquire(
                at: url
            ) else {
                return XCTFail("A second instance must see the live holder")
            }
            withExtendedLifetime(holder) {}
        }

        guard case .acquired = ProductInstanceLock.acquire(at: url) else {
            return XCTFail("The lock must be free once its holder ends")
        }
    }

    func testTestHostNeverTouchesTheInstalledAppRecoveryRecord() {
        XCTAssertTrue(ProductProcessEnvironment.isHostingTests)
        XCTAssertNil(ProductRecoveryStore.forCurrentProcess().storageURL)
    }

    @MainActor
    func testRecoveryDetectsUncleanPriorLaunchButNotCleanTermination()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr113b-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recovery.json")
        let store = ProductRecoveryStore(storageURL: url)

        let first = ProductRecoveryController(store: store)
        first.prepareForLaunch(
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertFalse(first.safeLaunchActive)

        let afterUnclean = ProductRecoveryController(store: store)
        afterUnclean.prepareForLaunch(
            now: Date(timeIntervalSince1970: 200)
        )
        XCTAssertTrue(afterUnclean.safeLaunchActive)
        XCTAssertTrue(
            afterUnclean.safeLaunchReasons.contains(
                .uncleanTermination
            )
        )

        afterUnclean.markCleanTermination()

        let afterClean = ProductRecoveryController(store: store)
        afterClean.prepareForLaunch(
            now: Date(timeIntervalSince1970: 300)
        )
        XCTAssertFalse(afterClean.safeLaunchActive)
        XCTAssertFalse(
            afterClean.safeLaunchReasons.contains(
                .uncleanTermination
            )
        )
    }

    @MainActor
    func testRecoveryRepeatedFailuresTriggerSafeLaunchThreshold()
        throws {
        let controller = ProductRecoveryController(
            store: ProductRecoveryStore(storageURL: nil)
        )
        controller.prepareForLaunch()

        controller.recordStartFailure(
            .audioStart,
            description: "first"
        )
        XCTAssertFalse(controller.safeLaunchActive)

        controller.recordStartFailure(
            .audioStart,
            description: "second"
        )
        XCTAssertTrue(controller.safeLaunchActive)
        XCTAssertTrue(
            controller.safeLaunchReasons.contains(
                .repeatedAudioStartFailures
            )
        )

        controller.openNormally()
        XCTAssertFalse(controller.safeLaunchActive)

        let plugInController = ProductRecoveryController(
            store: ProductRecoveryStore(storageURL: nil)
        )
        plugInController.prepareForLaunch()
        plugInController.recordStartFailure(
            .plugInStart,
            description: "plug-in one"
        )
        XCTAssertFalse(plugInController.safeLaunchActive)
        plugInController.recordStartFailure(
            .plugInStart,
            description: "plug-in two"
        )
        XCTAssertTrue(
            plugInController.safeLaunchReasons.contains(
                .repeatedPlugInFailures
            )
        )
    }

    @MainActor
    func testRecoveryOnlyHealthyNormalStartUpdatesLastKnownGood()
        throws {
        let controller = ProductRecoveryController(
            store: ProductRecoveryStore(storageURL: nil)
        )
        controller.prepareForLaunch()

        let firstPreset = ContentPreset(
            name: "Known Good",
            origin: .user,
            state: ContentPresetState()
        )
        let firstSnapshot = ProductProfileBackupSnapshot(
            contentPresets: [firstPreset],
            systemProfiles: [],
            selectedContentPresetID: firstPreset.id,
            selectedSystemProfileID: nil
        )

        controller.recordSuccessfulStart(
            profiles: firstSnapshot,
            plugInChainHealthy: true,
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(
            try controller.lastKnownGoodSnapshot()
                .contentPresets.first?.name,
            "Known Good"
        )

        let secondPreset = ContentPreset(
            name: "Bypassed Candidate",
            origin: .user,
            state: ContentPresetState()
        )
        let secondSnapshot = ProductProfileBackupSnapshot(
            contentPresets: [secondPreset],
            systemProfiles: [],
            selectedContentPresetID: secondPreset.id,
            selectedSystemProfileID: nil
        )

        controller.openWithPlugInsBypassed()
        controller.recordSuccessfulStart(
            profiles: secondSnapshot,
            plugInChainHealthy: true,
            now: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(
            try controller.lastKnownGoodSnapshot()
                .contentPresets.first?.name,
            "Known Good"
        )

        controller.openNormally()
        controller.recordSuccessfulStart(
            profiles: secondSnapshot,
            plugInChainHealthy: false,
            now: Date(timeIntervalSince1970: 300)
        )
        XCTAssertEqual(
            try controller.lastKnownGoodSnapshot()
                .contentPresets.first?.name,
            "Known Good"
        )
    }


    @MainActor
    func testRecoveryUnreadableStateRequiresSafeLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr113b-recovery-corrupt-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let url = root.appendingPathComponent("recovery.json")
        try Data("not-json".utf8).write(to: url)

        let controller = ProductRecoveryController(
            store: ProductRecoveryStore(storageURL: url)
        )
        controller.prepareForLaunch()

        XCTAssertTrue(controller.safeLaunchActive)
        XCTAssertTrue(
            controller.safeLaunchReasons.contains(
                .recoveryStateUnreadable
            )
        )
        XCTAssertNotNil(
            controller.lastPersistenceErrorDescription
        )
    }

    @MainActor
    func testRecoveryPlugInBypassIsTransientAcrossCleanLaunch()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr113b-recovery-bypass-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recovery.json")
        let store = ProductRecoveryStore(storageURL: url)

        let first = ProductRecoveryController(store: store)
        first.prepareForLaunch()
        first.openWithPlugInsBypassed()
        XCTAssertTrue(first.plugInsBypassedForThisLaunch)
        first.markCleanTermination()

        let second = ProductRecoveryController(store: store)
        second.prepareForLaunch()
        XCTAssertFalse(second.safeLaunchActive)
        XCTAssertFalse(second.plugInsBypassedForThisLaunch)
    }

    @MainActor
    func testRecoveryStateIsMachineLocalAndHasNoReleaseAuthority()
        throws {
        let labels = Set(
            Mirror(
                reflecting: ProductRecoveryPersistentState()
            ).children.compactMap { $0.label }
        )
        XCTAssertFalse(labels.contains("physicalAcceptanceComplete"))
        XCTAssertFalse(labels.contains("releaseAcceptanceComplete"))
        XCTAssertFalse(labels.contains("mayMergeIntoMain"))
        XCTAssertFalse(labels.contains("liveFeedForwardANCAuthorized"))
    }


    func testHeadroomAssistantReconstructsPeakBeforeGainRider() {
        var evidence = HeadroomAssistantEvidence()
        let inputLinear =
            Float(pow(10.0, -3.0 / 20.0))

        for index in 0..<20 {
            evidence.ingest(
                inputTruePeakLinear: inputLinear,
                outputTruePeakLinear: inputLinear,
                limiterGainReductionDB: 0.2,
                sustainedLimiterGainReductionDB: 0.1,
                gainRiderAttenuationDB: 2.0,
                truePeakGuardActive: true,
                cumulativeSafetyClampSamples: 0,
                initialSafetyClampSamples: 0,
                elapsedSeconds: 10.0 + Double(index) * 0.1
            )
        }

        XCTAssertEqual(
            evidence.maximumMeasuredInputTruePeakDBTP ?? 0,
            -3.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            evidence.maximumPreRiderTruePeakDBTP ?? 0,
            -1.0,
            accuracy: 0.001
        )
        XCTAssertTrue(evidence.isSufficientForRecommendation)
    }

    func testHeadroomAssistantNeverReclaimsExistingAttenuation() {
        var evidence = HeadroomAssistantEvidence()
        evidence.observationSeconds = 30
        evidence.sampleCount = 30
        evidence.maximumPreRiderTruePeakDBTP = -6
        evidence.maximumMeasuredInputTruePeakDBTP = -6
        evidence.truePeakGuardObserved = true

        let recommendation =
            HeadroomAssistantRecommendation.make(
                evidence: evidence,
                currentHeadroomAttenuationDB: -4,
                targetPeakDBTP: -1
            )

        XCTAssertEqual(
            recommendation.disposition,
            .currentReserveSufficient
        )
        XCTAssertEqual(
            recommendation.recommendedHeadroomAttenuationDB,
            -4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation.additionalAttenuationDB,
            0,
            accuracy: 0.0001
        )
        XCTAssertFalse(recommendation.canApply)
    }

    func testHeadroomAssistantUsesLargestReserveNeedPlusClampReserve() {
        var evidence = HeadroomAssistantEvidence()
        evidence.observationSeconds = 30
        evidence.sampleCount = 30
        evidence.maximumPreRiderTruePeakDBTP = -0.2
        evidence.maximumMeasuredInputTruePeakDBTP = -0.2
        evidence.maximumSustainedLimiterGainReductionDB = 1.0
        evidence.maximumLimiterGainReductionDB = 2.0
        evidence.safetyClampSamples = 4
        evidence.truePeakGuardObserved = true

        let recommendation =
            HeadroomAssistantRecommendation.make(
                evidence: evidence,
                currentHeadroomAttenuationDB: -1,
                targetPeakDBTP: -1
            )

        // Peak need is 0.8 dB. Sustained-limiter need is 0.5 dB.
        // Use the larger need, then add the 0.5 dB clamp reserve.
        XCTAssertEqual(
            recommendation.peakDrivenAttenuationDB,
            0.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation
                .sustainedLimiterDrivenAttenuationDB,
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation.safetyClampReserveDB,
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation.additionalAttenuationDB,
            1.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation.recommendedHeadroomAttenuationDB,
            -2.3,
            accuracy: 0.0001
        )
        XCTAssertTrue(recommendation.canApply)
    }

    func testHeadroomAssistantRequiresAuthoritativeRepresentativeEvidence() {
        var tooShort = HeadroomAssistantEvidence()
        tooShort.observationSeconds = 5
        tooShort.sampleCount = 30
        tooShort.maximumPreRiderTruePeakDBTP = 0
        tooShort.truePeakGuardObserved = true

        XCTAssertEqual(
            HeadroomAssistantRecommendation.make(
                evidence: tooShort,
                currentHeadroomAttenuationDB: 0
            ).disposition,
            .insufficientEvidence
        )

        var noTruePeakGuard = tooShort
        noTruePeakGuard.observationSeconds = 30
        noTruePeakGuard.truePeakGuardObserved = false

        XCTAssertEqual(
            HeadroomAssistantRecommendation.make(
                evidence: noTruePeakGuard,
                currentHeadroomAttenuationDB: 0
            ).disposition,
            .insufficientEvidence
        )
    }

    func testHeadroomAssistantRangeLimitFailsConservatively() {
        var evidence = HeadroomAssistantEvidence()
        evidence.observationSeconds = 30
        evidence.sampleCount = 30
        evidence.maximumPreRiderTruePeakDBTP = 6.0
        evidence.maximumMeasuredInputTruePeakDBTP = 6.0
        evidence.maximumSustainedLimiterGainReductionDB = 12.0
        evidence.safetyClampSamples = 10
        evidence.truePeakGuardObserved = true

        let recommendation =
            HeadroomAssistantRecommendation.make(
                evidence: evidence,
                currentHeadroomAttenuationDB: -47.5,
                targetPeakDBTP: -1.0
            )

        XCTAssertEqual(recommendation.disposition, .rangeLimited)
        XCTAssertEqual(
            recommendation.recommendedHeadroomAttenuationDB,
            DSPGainConfiguration
                .headroomAttenuationRange.lowerBound,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            recommendation.additionalAttenuationDB,
            0.5,
            accuracy: 0.0001
        )
        XCTAssertTrue(recommendation.rangeLimited)
        XCTAssertTrue(recommendation.canApply)
    }

    @MainActor
    func testHeadroomAssistantRejectsOpenABAuditionSession()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr113b-headroom-ab-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = AudioIOEngine()
        let profiles = ProductProfileController(
            engine: engine,
            storageURL:
                root.appendingPathComponent("profiles.json")
        )
        let comparison =
            ContentABComparisonController(profiles: profiles)
        comparison.capture(.a)
        await comparison.audition(.a)
        XCTAssertNotNil(comparison.sessionBaseline)

        let assistant = HeadroomAssistantController(
            engine: engine,
            profiles: profiles,
            abComparison: comparison
        )
        XCTAssertThrowsError(
            try assistant.startObservation()
        ) { error in
            XCTAssertEqual(
                error as? HeadroomAssistantError,
                .abComparisonActive
            )
        }

        await comparison.endAudition(
            restoringBaseline: false
        )
    }

    @MainActor
    func testHeadroomAssistantBoundaryFailsClosedOnContentDrift()
        throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pr113b-headroom-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = AudioIOEngine()
        let profiles = ProductProfileController(
            engine: engine,
            storageURL:
                root.appendingPathComponent("profiles.json")
        )
        let boundary =
            HeadroomAssistantBoundary(profiles: profiles)

        XCTAssertTrue(boundary.matches(profiles))
        try engine.setHeadroomAttenuationDB(-1.0)
        XCTAssertFalse(boundary.matches(profiles))
        XCTAssertTrue(
            boundary.matches(
                profiles,
                expectedHeadroomAttenuationDB: -1.0
            )
        )
    }


    func testGettingStartedCoversNonIntrusiveFirstSessionPath()
        throws {
        let article = try XCTUnwrap(
            ProductionUserGuideCatalog.article(
                id: "getting-started"
            )
        )
        let searchable = article.searchableText

        for token in [
            "system audio",
            "measurement microphone",
            "screen & system audio recording",
            "conservative listening level",
            "needs mapping",
            "start processing",
            "headroom assistant",
            "content preset",
            "a/b",
            "measurement lab",
            "room correction",
            "backup & restore",
            ".n60backup",
            "safe launch",
            "restore last known good",
            "copy diagnostics",
            "physical hardware-acceptance",
        ] {
            XCTAssertTrue(
                searchable.contains(token),
                "Getting Started is missing \(token)"
            )
        }

        XCTAssertGreaterThanOrEqual(
            article.sections.count,
            7
        )
    }

}

private enum VolumePopupLayoutFixture {
    static func make(
        _ position: VolumeFeedbackPopupPosition,
        cover: Bool,
        _ visible: CGRect,
        fullScreen: CGRect? = nil
    ) -> VolumeFeedbackPopupLayout {
        VolumeFeedbackPopupLayout.make(
            position: position,
            coverSystemPopup: cover,
            visibleFrame: visible,
            fullScreenFrame: fullScreen
        )
    }
}
