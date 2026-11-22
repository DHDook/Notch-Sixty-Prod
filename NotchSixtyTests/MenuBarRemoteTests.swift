import XCTest
@testable import NotchSixty

/// E12 S13: the remote-control panel's host and control set. Pure, so every combination is driven directly.
final class MenuBarRemoteTests: XCTestCase {
    func testExactlyOneHostForEverySetting() {
        for flagOn in [false, true] {
            for tray in [false, true] {
                XCTAssertEqual(RemoteHost.visibleHosts(flagOn: flagOn, trayInserted: tray).count, 1)
            }
        }
        XCTAssertEqual(RemoteHost.resolve(flagOn: true, trayInserted: true), .menuBar)
        XCTAssertEqual(RemoteHost.resolve(flagOn: true, trayInserted: false), .toolbarPopover)
    }

    func testFlagOffKeepsTodaysPanelAndNoToolbarButton() {
        XCTAssertEqual(RemoteHost.resolve(flagOn: false, trayInserted: true), .legacyMenuBar)
        XCTAssertEqual(RemoteHost.resolve(flagOn: false, trayInserted: false), .legacyMenuBar)
        XCTAssertFalse(MenuBarRemoteModel.showsToolbarButton(flagOn: false, trayInserted: false))
        XCTAssertEqual(
            MenuBarRemoteModel.controls(for: .legacyMenuBar), [.processing, .preset, .openApp])
    }

    func testToolbarButtonOnlyWhenMenuBarItemIsOff() {
        XCTAssertFalse(MenuBarRemoteModel.showsToolbarButton(flagOn: true, trayInserted: true))
        XCTAssertTrue(MenuBarRemoteModel.showsToolbarButton(flagOn: true, trayInserted: false))
    }

    func testEverySurfaceRuleControlIsReachableWithMenuBarOnAndOff() {
        for tray in [true, false] {
            let host = RemoteHost.resolve(flagOn: true, trayInserted: tray)
            let controls = Set(MenuBarRemoteModel.controls(for: host))
            XCTAssertEqual(controls, Set(RemoteControl.allCases), "tray=\(tray)")
            for needed in [RemoteControl.volume, .mute, .balance, .output, .preset, .processing] {
                XCTAssertTrue(controls.contains(needed))
            }
        }
        XCTAssertEqual(
            MenuBarRemoteModel.controls(for: .menuBar), MenuBarRemoteModel.controls(for: .toolbarPopover))
    }

    func testSlotsAreNamedAndEmptyWithOwners() {
        XCTAssertEqual(Set(RemoteSlot.allCases.map(\.rawValue)).count, 5)
        for slot in RemoteSlot.allCases {
            XCTAssertEqual(slot.isFilled, slot == .beforeAfter)
            XCTAssertFalse(slot.owner.isEmpty)
        }
        XCTAssertEqual(RemoteSlot.beforeAfter.owner, "E12 S27")
    }

    func testOutputPickerOnlyWhileIdleAndBalanceReadout() {
        XCTAssertTrue(MenuBarRemoteModel.outputPickerEnabled(idle: true))
        XCTAssertFalse(MenuBarRemoteModel.outputPickerEnabled(idle: false))
        XCTAssertEqual(MenuBarRemoteModel.balanceReadout(0), "Centre")
        XCTAssertEqual(MenuBarRemoteModel.balanceReadout(-0.25), "L 25")
        XCTAssertEqual(MenuBarRemoteModel.balanceReadout(0.5), "R 50")
    }
}
