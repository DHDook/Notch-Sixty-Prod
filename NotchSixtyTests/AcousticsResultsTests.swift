import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S20 (`e12.active-acoustics-page`): plain results, history, hold-to-compare and the event history lines.
@MainActor
final class AcousticsResultsTests: XCTestCase {
    private func tone(_ hz: Double, _ reduction: Double) -> ActiveQuietZoneToneTelemetry {
        ActiveQuietZoneToneTelemetry(
            frequencyHz: hz, disturbanceLevelDBFS: -40, residualLevelDBFS: -50, measuredReductionDB: reduction,
            predictedReductionDB: reduction, leftSourceLevelDBFS: -60, rightSourceLevelDBFS: -60)
    }

    private func target(mode: ActiveAcousticsPlaybackAdaptationMode, level: Double, clearance: Double = 0, hold: AmbientCompensationHoldReason? = nil) -> AmbientCompensationTarget {
        var t = AmbientCompensationTarget.unity
        t.mode = mode
        t.levelDB = level
        t.estimatedClearanceDB = clearance
        t.holdReason = hold
        return t
    }

    // MARK: Result lines

    func testQuietZoneLineFollowsTheMeasuredValuesAndHidesWithoutAMeasurement() {
        XCTAssertNil(AcousticsResultModel.quietZone(tones: []))
        let line = AcousticsResultModel.quietZone(tones: [tone(50, 9.2), tone(80, 3)])
        XCTAssertEqual(line?.text, "50 Hz hum: 9 dB quieter at your seat")
        XCTAssertEqual(line?.isEstimate, false)
        XCTAssertEqual(AcousticsResultModel.quietZone(tones: [tone(50, 12.4)])?.text, "50 Hz hum: 12 dB quieter at your seat")
        XCTAssertEqual(AcousticsResultModel.quietZone(tones: [tone(50, 0.2), tone(60, -3)])?.text,
                       "No measurable reduction at your seat yet")
    }

    func testPlaybackAdaptationLineFollowsTheAppliedTargetAndHidesWhenHeldOrIdle() {
        XCTAssertEqual(
            AcousticsResultModel.playbackAdaptation(target: target(mode: .conversationFocus, level: -2.2), monitoring: true)?.text,
            "Music turned down 2 dB for conversation")
        let reshaped = AcousticsResultModel.playbackAdaptation(
            target: target(mode: .conversationFocus, level: 0, clearance: 4.4), monitoring: true)
        XCTAssertEqual(reshaped?.isEstimate, true)
        XCTAssertTrue(reshaped?.displayText.hasSuffix("(estimate)") ?? false)
        XCTAssertNil(AcousticsResultModel.playbackAdaptation(target: target(mode: .conversationFocus, level: -2), monitoring: false))
        XCTAssertNil(AcousticsResultModel.playbackAdaptation(
            target: target(mode: .conversationFocus, level: -2, hold: .playbackModelRequired), monitoring: true))
        XCTAssertNil(AcousticsResultModel.playbackAdaptation(target: .unity, monitoring: true))
        XCTAssertNil(AcousticsResultModel.playbackAdaptation(target: target(mode: .musicFocus, level: 0.2), monitoring: true))
        XCTAssertEqual(
            AcousticsResultModel.playbackAdaptation(target: target(mode: .musicFocus, level: 3), monitoring: true)?.text,
            "Music turned up 3 dB to stay clear of room noise")
    }

    func testRoomTreatmentLinesLabelThePredictionAnEstimateAndAddTheMeasuredChange() {
        typealias Decay = MIMOTreatmentController.SeatDecay
        XCTAssertTrue(AcousticsResultModel.roomTreatment(predicted: [], measured: []).isEmpty)
        let predicted = [Decay(id: 0, name: "A", beforeSeconds: 0.8, afterSeconds: 0.4)]
        let lines = AcousticsResultModel.roomTreatment(predicted: predicted, measured: [])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].isEstimate)
        XCTAssertEqual(lines[0].displayText, "Bass decay 0.80 s to 0.40 s at your seats (estimate)")
        let measured = [Decay(id: 0, name: "A", beforeSeconds: 0.8, afterSeconds: 0.5)]
        let both = AcousticsResultModel.roomTreatment(predicted: predicted, measured: measured)
        XCTAssertEqual(both.count, 2)
        XCTAssertFalse(both[1].isEstimate)
        XCTAssertEqual(both[1].text, "Measured after repeat measurement: bass decay 0.80 s to 0.50 s")
    }

    func testHistoryKeepsTheLastFiveDistinctResultsPerTab() {
        var history = AcousticsResultHistory()
        let now = Date()
        for hz in 0..<8 {
            history.record(AcousticsResultLine(text: "r\(hz)", isEstimate: false), tab: .quietZone, at: now)
            history.record(AcousticsResultLine(text: "r\(hz)", isEstimate: false), tab: .quietZone, at: now)
        }
        history.record(AcousticsResultLine(text: "other", isEstimate: false), tab: .roomTreatment, at: now)
        XCTAssertEqual(history.entries(for: .quietZone).map(\.line.text), ["r3", "r4", "r5", "r6", "r7"])
        XCTAssertEqual(history.entries(for: .roomTreatment).count, 1)
    }

    // MARK: Event history

    func testTreatmentSentencesAreEventsInPlainWordsAndNeverMerge() {
        let history = SessionEventHistory(store: nil)
        let now = Date()
        history.noteTreatment("Quiet Zone armed.", now: now)
        history.noteTreatment("Quiet Zone armed.", now: now)
        history.noteTreatment("You bypassed Room Treatment.", now: now)
        XCTAssertEqual(history.log.events.count, 3)
        XCTAssertEqual(history.log.events.map(\.kind), [.treatment, .treatment, .treatment])
        XCTAssertEqual(history.log.events[2].summary(timeText: "10:00:00"), "10:00:00 · You bypassed Room Treatment.")
        XCTAssertTrue(history.exportText().contains("You bypassed Room Treatment."))
    }

    func testEventWiringIsDarkWithTheFlagOffAndLiveWithItOn() {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let product = ProductController(audioEngine: engine)
        let history = SessionEventHistory(store: nil)
        let id = FeatureFlag.activeAcousticsPage.id
        let off = FeatureFlags(policy: .launchArgumentOnly, arguments: ["-NotchSixtyFeatures", "-\(id)"], environment: [:])
        product.activeQuietZone.onSessionEvent = nil
        ActiveAcousticsEventWiring.attach(quietZone: product.activeQuietZone, treatment: product.mimoTreatment, flags: off, history: history)
        XCTAssertNil(product.activeQuietZone.onSessionEvent)
        let on = FeatureFlags(policy: .launchArgumentOnly, arguments: ["-NotchSixtyFeatures", id], environment: [:])
        ActiveAcousticsEventWiring.attach(quietZone: product.activeQuietZone, treatment: product.mimoTreatment, flags: on, history: history)
        XCTAssertNotNil(product.activeQuietZone.onSessionEvent)
        product.activeQuietZone.onSessionEvent?("Quiet Zone armed.")
        product.mimoTreatment.onSessionEvent?("Room Treatment armed.")
        XCTAssertEqual(history.log.events.map(\.place), ["Quiet Zone armed.", "Room Treatment armed."])
    }

    // MARK: Compare

    func testQuietZoneCompareIsRefusedWhileDisarmedAndNeverChangesTheArmState() throws {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let quietZone = ProductController(audioEngine: engine).activeQuietZone
        XCTAssertFalse(quietZone.arm.isArmed)
        XCTAssertEqual(quietZone.compareUnavailableReason, "Turn Quiet Zone on to compare.")
        quietZone.setCompareHeld(true)
        XCTAssertFalse(quietZone.compareHeld, "compare needs an armed Quiet Zone")
        quietZone.setCompareHeld(false)
        XCTAssertFalse(quietZone.compareHeld)
        XCTAssertFalse(quietZone.arm.isArmed, "compare never arms")
    }

    func testAmbientCompareNeedsAdaptationOnAndEndsWhenMonitoringStops() throws {
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let ambient = ProductController(audioEngine: engine).ambientCompensation
        XCTAssertFalse(ambient.playbackAdaptationActive)
        ambient.setCompareHeld(true)
        XCTAssertFalse(ambient.compareHeld)
        let mode = ambient.playbackAdaptationMode
        ambient.setCompareHeld(false)
        XCTAssertEqual(ambient.playbackAdaptationMode, mode, "compare never changes the adaptation mode")
        ambient.stopMonitoring()
        XCTAssertFalse(ambient.compareHeld)
    }

    // MARK: Page

    func testHoldToCompareButtonReportsPressAndRelease() {
        var events: [Bool] = []
        let button = ProductionHoldToCompareButton(isHeld: false, disabledReason: nil, setHeld: { events.append($0) })
        let host = NSHostingView(rootView: button)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertTrue(events.isEmpty, "nothing fires until the user presses")
    }

    func testResultCardFitsAt1280And1920() {
        let lines = [AcousticsResultLine(text: "50 Hz hum: 9 dB quieter at your seat", isEstimate: false)]
        for width in [CGFloat(1_280), CGFloat(1_920)] {
            let card = ProductionAcousticsResultCard(
                lines: lines, emptyText: "none", history: [],
                compare: .init(isHeld: false, unavailableReason: nil, setHeld: { _ in }), compareNote: nil)
            let host = NSHostingView(rootView: card.frame(width: width - 80))
            host.frame = NSRect(x: 0, y: 0, width: width - 80, height: 400)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width - 80 + 0.5, "\(width)")
        }
    }
}
