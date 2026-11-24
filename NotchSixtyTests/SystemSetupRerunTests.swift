import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S31: the automatic level (decision 33; G62), the three shortcuts for a system that is already set up
/// (decision 36; G67) and the hosted layout checks of the entry card, the sheet footer and the Measure rows
/// (G85, G87; AGENTS.md section 13). `e12.setup-flow` is not graduated here (G88, G89, G86 stay open).
@MainActor
final class SystemSetupRerunTests: XCTestCase {
    private static var rates: [Double] { SystemSetupEndToEndTests.rates }

    // MARK: Automatic level, decision values

    func testRampStepsAreSmallAndStopAtTheTarget() {
        var auto = SystemSetupAutoLevel()
        guard case .raise(let first) = auto.decide(reading: 50, atCeiling: false) else { return XCTFail("raises") }
        XCTAssertEqual(first, SystemSetupLevelPlan.rampStepDB, "far from the target the step is the manual step")
        guard case .raise(let second) = auto.decide(reading: 50 + first, atCeiling: false) else { return XCTFail("raises") }
        XCTAssertLessThanOrEqual(second, SystemSetupLevelPlan.rampStepDB)
        guard case .raise(let near) = auto.decide(reading: 73.4 - 0.0, atCeiling: false) else { return XCTFail("raises") }
        XCTAssertEqual(near, 1.6, accuracy: 0.01, "near the target the step shrinks to the gap")
        XCTAssertGreaterThanOrEqual(near, SystemSetupAutoLevel.minimumStepDB)
        if case .finished = auto.decide(reading: 74.6, atCeiling: false) {} else { XCTFail("within tolerance finishes") }
    }

    func testRampStopsOnAFlatReadingAndOnTheCeilingAndOnNoReading() {
        var flat = SystemSetupAutoLevel()
        _ = flat.decide(reading: 40, atCeiling: false)
        if case .stopped(let why) = flat.decide(reading: 40.2, atCeiling: false) {
            XCTAssertTrue(why.contains("did not rise"), why)
        } else { XCTFail("a flat reading stops") }

        var top = SystemSetupAutoLevel()
        if case .stopped(let why) = top.decide(reading: 40, atCeiling: true) {
            XCTAssertTrue(why.contains("top level"), why)
        } else { XCTFail("the ceiling stops") }

        var silent = SystemSetupAutoLevel()
        var last = SystemSetupAutoLevel.Decision.wait
        for _ in 0..<SystemSetupAutoLevel.maximumEmptyLooks { last = silent.decide(reading: nil, atCeiling: false) }
        if case .stopped = last {} else { XCTFail("no reading stops") }
    }

    func testRaiseByNeverPassesTheCeiling() {
        var plan = SystemSetupLevelPlan()
        for _ in 0..<80 { plan.raise(byDB: 3) }
        XCTAssertEqual(plan.levelDB, SystemSetupLevelPlan.ceilingDB)
        plan.raise(byDB: 100)
        XCTAssertLessThanOrEqual(plan.levelDB, SystemSetupLevelPlan.ceilingDB)
        var small = SystemSetupLevelPlan()
        small.raise(byDB: 100)
        XCTAssertEqual(small.levelDB, SystemSetupLevelPlan.startLevelDB + SystemSetupLevelPlan.rampStepDB,
                       "one automatic step is never larger than the manual step")
    }

    // MARK: Automatic level through the production model at the eight rates

    private func waitForAutoLevel(_ model: SystemSetupFlowModel) async {
        for _ in 0..<400 where model.autoLevelRunning { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A simulated microphone: the reading follows the level with a fixed room gain, so a loud room reaches the target.
    func testAutoLevelReachesTheTargetAndNeverPassesTheCeilingAtEveryRate() async throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate)
            defer { rig.tearDown() }
            let model = rig.model
            let label = "\(rate) Hz"
            model.begin()
            model.chooseOutput(uid: OfflineSetupRig.outputUID)
            model.autoLevelSettle = .zero
            let gain = 100.0  // reading = level + 100: -40 dBFS reads 60, target 75 needs about -25
            model.autoLevelReading = { model.level.levelDB + gain }
            var highest = model.level.levelDB
            model.startAutoLevel()
            XCTAssertTrue(model.noiseIsPlaying, "\(label): the noise starts with the automatic level: \(model.message ?? "")")
            while model.autoLevelRunning {
                highest = max(highest, model.level.levelDB)
                try? await Task.sleep(for: .milliseconds(1))
            }
            highest = max(highest, model.level.levelDB)
            XCTAssertFalse(model.autoLevelRunning, label)
            XCTAssertLessThanOrEqual(highest, SystemSetupLevelPlan.ceilingDB, label)
            XCTAssertEqual(model.level.levelDB + gain, SystemSetupLevelPlan.targetSPLdBC, accuracy: SystemSetupAutoLevel.toleranceDB + 0.01, label)
            XCTAssertTrue(model.autoLevelStatus?.contains("reads about") == true, "\(label): \(model.autoLevelStatus ?? "")")
            model.stopNoise()
        }
    }

    func testAutoLevelStopsAtTheCeilingWhenTheRoomIsTooQuiet() async throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate)
            defer { rig.tearDown() }
            let model = rig.model
            model.begin()
            model.chooseOutput(uid: OfflineSetupRig.outputUID)
            model.autoLevelSettle = .zero
            model.autoLevelReading = { model.level.levelDB + 40 }  // never reaches 75 before -6 dBFS
            model.startAutoLevel()
            await waitForAutoLevel(model)
            XCTAssertEqual(model.level.levelDB, SystemSetupLevelPlan.ceilingDB, "\(rate) Hz: stops at the ceiling")
            XCTAssertTrue(model.autoLevelStatus?.contains("top level") == true, "\(rate) Hz: \(model.autoLevelStatus ?? "")")
            model.stopNoise()
        }
    }

    func testAutoLevelStopsOnAReadingThatDoesNotRiseAndOnStop() async throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let model = rig.model
        model.begin()
        model.chooseOutput(uid: OfflineSetupRig.outputUID)
        model.autoLevelSettle = .zero
        model.autoLevelReading = { 50 }
        model.startAutoLevel()
        await waitForAutoLevel(model)
        XCTAssertTrue(model.autoLevelStatus?.contains("did not rise") == true, model.autoLevelStatus ?? "")
        XCTAssertLessThan(model.level.levelDB, SystemSetupLevelPlan.ceilingDB)
        model.stopNoise()

        // Stop button: the settle is long, so Stop lands before the first look.
        model.autoLevelSettle = .seconds(30)
        let before = model.level.levelDB
        model.startAutoLevel()
        XCTAssertTrue(model.autoLevelRunning)
        model.stopAutoLevel()
        XCTAssertFalse(model.autoLevelRunning)
        XCTAssertEqual(model.level.levelDB, before, "Stop leaves the level where it was")
        XCTAssertTrue(model.autoLevelStatus?.hasPrefix("Stopped") == true)
        model.stopNoise()
    }

    func testManualRaiseAndLowerStayAndStartLevelsAreUnchanged() {
        var plan = SystemSetupLevelPlan()
        XCTAssertEqual(plan.levelDB, -40)
        plan.raise()
        XCTAssertEqual(plan.levelDB, -37)
        plan.lower()
        XCTAssertEqual(plan.levelDB, -40)
        plan.selectTarget(.allProgram(includeLFE: true), isLFE: false)
        XCTAssertEqual(plan.levelDB, SystemSetupLevelPlan.lfeStartLevelDB)
    }

    // MARK: Shortcuts

    private func rerunModel(_ rig: OfflineSetupRig, _ name: String) -> SystemSetupFlowModel {
        SystemSetupFlowModel(
            engine: rig.engine, profiles: rig.profiles, microphone: rig.microphone, calibration: rig.calibration,
            sessions: SystemSetupSessionStore(directory: rig.root.appendingPathComponent("rerun-sessions-\(name)")),
            roomProjectsDirectory: rig.root.appendingPathComponent("RoomCorrection"),
            abxDirectory: rig.root.appendingPathComponent("ABX"), abxSwitchHold: 0)
    }

    /// Measures every seat through the first model, leaving the measurements with the calibration controller.
    private func measured(_ rig: OfflineSetupRig, label: String) async -> Int {
        let model = rig.model
        rig.chooseTwoPointOneThroughWizard()
        model.selectMicrophone(uid: OfflineSetupRig.inputUID)
        model.acceptSweepLevel(measuredSPLdBC: 75)
        model.next()
        model.next()
        model.prepareMeasure()
        model.addSeat()
        await model.measureAll()
        XCTAssertFalse(rig.calibration.measurements.isEmpty, "\(label): \(model.message ?? "")")
        return rig.calibration.measurements.count
    }

    func testEachShortcutOpensAtItsStepWithTheRestKeptAtEveryRate() async throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate)
            defer { rig.tearDown() }
            let label = "\(rate) Hz"
            let count = await measured(rig, label: label)
            let uid = rig.model.choices.outputUID

            // Change the sound: Correction, the measurements kept, nothing measured.
            let sound = rerunModel(rig, "sound")
            sound.begin(entry: .changeSound)
            XCTAssertTrue(sound.isRunning, label)
            XCTAssertEqual(sound.step, .correction, "\(label): \(sound.message ?? "")")
            XCTAssertEqual(rig.calibration.measurements.count, count, "\(label): Change the sound measures nothing and drops nothing")
            XCTAssertEqual(sound.choices.measurementIDs.count, sound.choices.seatNames.count, label)
            XCTAssertEqual(sound.choices.outputUID, uid, label)
            XCTAssertTrue(sound.flow.completed.isSuperset(of: [.output, .topology, .microphone, .measure]), label)
            XCTAssertFalse(sound.isMeasuring, label)

            // Measure again: Microphone and level, old measurements dropped, output and speakers kept.
            let again = rerunModel(rig, "again")
            again.begin(entry: .measureAgain)
            XCTAssertEqual(again.step, .microphone, "\(label): \(again.message ?? "")")
            XCTAssertTrue(rig.calibration.measurements.isEmpty, "\(label): the old measurements are dropped")
            XCTAssertEqual(again.choices.outputUID, uid, label)
            XCTAssertNotNil(again.choices.arrangement, label)
            XCTAssertTrue(again.flow.completed.isSuperset(of: [.output, .topology]), label)
            again.cancel()
        }
    }

    func testChangeSpeakersOpensAtSpeakersAndChangeTheSoundNeedsKeptMeasurements() async throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        // No measurements: Change the sound says so and stays at the start.
        let empty = rerunModel(rig, "empty")
        empty.begin(entry: .changeSound)
        XCTAssertEqual(empty.step, .output)
        XCTAssertTrue(empty.message?.contains("Measure again") == true, empty.message ?? "")
        empty.cancel()

        _ = await measured(rig, label: "48 kHz")
        let speakers = rerunModel(rig, "speakers")
        speakers.begin(entry: .changeSpeakers)
        XCTAssertEqual(speakers.step, .topology, speakers.message ?? "")
        XCTAssertTrue(rig.calibration.measurements.isEmpty, "the routing may change, so the old measurements go")
        XCTAssertTrue(speakers.flow.completed.contains(.output))
        speakers.cancel()
    }

    func testEntryPolicyOffersTheShortcutsOnlyForAVerifiedSystemWithTheFlagOn() {
        let design = UUID()
        let summary = RoomCorrectionCalibrationSummary(
            projectID: UUID(), activeDesignID: design, designDate: Date(timeIntervalSince1970: 0),
            positionCount: 3, correctionLowHz: 20, correctionHighHz: 300, targetName: "Flat",
            smoothingOctaves: 1.0 / 6, maximumBoostDB: 3, maximumCutDB: 12,
            recommendedHeadroomDB: 6, algorithmVersion: "t")
        func availability(offers: Bool, status: SystemCalibrationStatus) -> SystemSetupEntryPolicy.Availability {
            SystemSetupEntryPolicy.availability(
                outputName: "Speakers", outputUID: "uid", state: nil, calibration: status, offersShortcuts: offers)
        }
        XCTAssertEqual(availability(offers: true, status: .verified(summary)), .setUp)
        XCTAssertEqual(availability(offers: false, status: .verified(summary)), .hidden)
        XCTAssertEqual(availability(offers: true, status: .notCalibrated), .offer)
        XCTAssertEqual(SystemSetupEntry.allCases.filter { $0 != .fresh }.map(\.startStep), [.microphone, .correction, .topology])
    }

    // MARK: Screen fit (G85, G87; AGENTS.md section 13)

    private let sizes = [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)]

    func testEntryCardRowsFitAtBothSizes() {
        for availability in [SystemSetupEntryPolicy.Availability.offer, .setUp, .headphonesPointer] {
            for size in sizes {
                let card = SystemSetupEntryCard(
                    availability: availability, start: {}, startQuick: {}, openHeadphones: {}, startEntry: { _ in })
                let page = HostedPage(ScrollView { card.padding(28) }, size: size)
                XCTAssertLessThanOrEqual(page.hosting.fittingSize.width, size.width, "\(availability) at \(size.width)")
                let shown = HostedPage(card.padding(28), size: size)
                for control in shown.controls {
                    let frame = control.view.convert(control.view.bounds, to: shown.hosting)
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(availability) control past the width at \(size.width)")
                }
            }
        }
    }

    func testSetupSheetFooterFitsInQuickAndShortcutRunsAtBothSizes() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let product = ProductController(audioEngine: rig.engine)
        for preset in [SystemSetupPreset.quick, .full] {
            for size in sizes {
                let view = ProductionSystemSetupFlowView(
                    engine: rig.engine, profiles: rig.profiles, microphone: rig.microphone,
                    calibration: rig.calibration, advisor: product.roomTreatmentAdvisor, preset: preset)
                let page = HostedPage(view, size: size)
                XCTAssertLessThanOrEqual(page.hosting.fittingSize.width, size.width, "\(preset) at \(size.width)")
                var views = 0
                func walk(_ v: NSView) {
                    let frame = v.convert(v.bounds, to: page.hosting)
                    if !(v is NSScroller), frame.width > 0 {
                        views += 1
                        XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(type(of: v)) left of the sheet")
                        XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(type(of: v)) past the sheet at \(size.width)")
                    }
                    v.subviews.forEach(walk)
                }
                walk(page.hosting)
                XCTAssertGreaterThan(views, 12)
            }
        }
    }

    func testMeasureStepSeatRowsWithVerdictsFitAtBothSizes() async throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let model = rig.model
        model.verdictsEnabled = true
        _ = await measured(rig, label: "48 kHz")
        model.addSeat()
        await model.measureAll()
        XCTAssertFalse(model.seatVerdicts.isEmpty, "the verdict line is present on the seat rows")
        for size in sizes {
            let page = HostedPage(
                ScrollView { SystemSetupMeasureStep(model: model).padding(20) }.frame(width: size.width, height: size.height),
                size: size)
            XCTAssertLessThanOrEqual(page.hosting.fittingSize.width, size.width, "Measure rows at \(size.width)")
            for control in page.controls {
                let frame = control.view.convert(control.view.bounds, to: page.hosting)
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(control.label) past the page at \(size.width)")
            }
        }
    }
}
