import XCTest
@testable import NotchSixty

/// E34 S4: one stopped/empty/busy rule and one dialog rule.
final class DesignStatesAndDialogsTests: XCTestCase {
    func testEveryLivePageShowsTheStoppedStateWhenAudioIsStopped() {
        for page in DesignLivePage.allCases {
            XCTAssertEqual(DesignPageStateRule.state(isRunning: false, hasContent: true), .stopped)
            XCTAssertTrue(page.stoppedMessage.hasPrefix("Audio is stopped."), "\(page)")
            XCTAssertTrue(page.stoppedMessage.contains("Start processing"), "\(page)")
        }
        XCTAssertEqual(MeterStoppedState.message, DesignLivePage.metersLevels.stoppedMessage)
    }

    func testStoppedWinsOverEmptyAndBusy() {
        XCTAssertEqual(DesignPageStateRule.state(isRunning: false, hasContent: false, isBusy: true), .stopped)
        XCTAssertEqual(DesignPageStateRule.state(isRunning: true, hasContent: false, isBusy: true), .busy)
        XCTAssertEqual(DesignPageStateRule.state(isRunning: true, hasContent: false), .empty)
        XCTAssertNil(DesignPageStateRule.state(isRunning: true, hasContent: true))
    }

    func testDestructiveActionsAskFirstAndErrorsAreInline() {
        XCTAssertEqual(DesignDialogRule.kind(for: .destructiveAction), .confirmationDialog)
        XCTAssertEqual(DesignDialogRule.kind(for: .recoverableError), .inlineMessage)
        XCTAssertEqual(DesignDialogRule.kind(for: .notice), .inlineMessage)
        XCTAssertEqual(DesignDialogRule.kind(for: .cannotContinue), .alert)
        for situation in DesignDialogSituation.allCases where situation != .cannotContinue {
            XCTAssertNotEqual(DesignDialogRule.kind(for: situation), .alert, "\(situation)")
        }
    }

    func testStateKindsKeepDistinctIconsAndLevels() {
        XCTAssertEqual(Set(DesignStateKind.allCases.map(\.iconName)).count, DesignStateKind.allCases.count)
        XCTAssertEqual(DesignStateKind.stopped.level, .attention)
        XCTAssertEqual(DesignStateKind.failed.level, .problem)
    }
}
