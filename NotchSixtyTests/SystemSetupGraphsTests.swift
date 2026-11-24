import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S30: the graphs, placement diagrams and plain terms of the guided setup. Pure values first, then the production
/// model on the synthetic reference room at the eight standard rates, then the steps hosted at the two owner sizes.
@MainActor
final class SystemSetupGraphsTests: XCTestCase {
    private static var rates: [Double] { SystemSetupEndToEndTests.rates }

    // MARK: Smoothing

    func testBandsStopBelowTheTopOfTheRateAtEveryRate() {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let centres = SystemSetupGraphBuilder.centres(sampleRate: rate)
            XCTAssertEqual(centres.first ?? 0, 20, accuracy: 1e-9, "\(rate)")
            XCTAssertLessThanOrEqual(centres.last ?? .infinity, min(20_000, rate * 0.45) * 1.0001, "\(rate)")
            XCTAssertGreaterThan(centres.last ?? 0, 10_000, "\(rate)")
            XCTAssertEqual(centres, centres.sorted(), "\(rate)")
        }
    }

    func testSmoothingKeepsAFlatResponseFlatAndNarrowsAPeak() {
        let centres = SystemSetupGraphBuilder.centres(sampleRate: 48_000)
        let f = (0..<4_000).map { 10 + Double($0) * 6 }
        let flat = SystemSetupGraphBuilder.bands(frequenciesHz: f, magnitudeDB: f.map { _ in -3 }, centres: centres)
        for value in flat where value.isFinite { XCTAssertEqual(value, -3, accuracy: 1e-9) }
        // A one-bin spike of +30 dB is averaged down over its sixth-octave band.
        var spiked = f.map { _ in 0.0 }
        spiked[Int((1_000 - 10) / 6)] = 30
        let smoothed = SystemSetupGraphBuilder.bands(frequenciesHz: f, magnitudeDB: spiked, centres: centres)
        XCTAssertLessThan(smoothed.compactMap { $0.isFinite ? $0 : nil }.max() ?? 99, 18, "a 30 dB one-bin spike is averaged down over its band")
        // Data that does not reach a band leaves it off the curve.
        let sparse = SystemSetupGraphBuilder.bands(frequenciesHz: [100, 200], magnitudeDB: [0, 6], centres: centres)
        XCTAssertTrue(sparse.first?.isNaN ?? false)
    }

    func testAverageSkipsMissingBands() {
        XCTAssertEqual(SystemSetupGraphBuilder.average([[1, .nan], [3, 5]]).first, 2)
        XCTAssertEqual(SystemSetupGraphBuilder.average([[1, .nan], [3, 5]]).last, 5)
    }

    // MARK: Plain terms and placement

    func testEveryListedTermHasAPlainLabelAndAnExplanationOnTheStepThatShowsIt() {
        let listed: [(SystemSetupTerm, String)] = [
            (.dBFS, "dBFS"), (.dBC, "dB(C)"), (.lfe, "LFE"), (.openSubPreout, "Open sub pre-out"),
            (.polarity, "Polarity"), (.errorNow, "Error now")]
        for (term, name) in listed {
            XCTAssertEqual(term.technicalName, name)
            XCTAssertGreaterThan(term.plainLabel.count, 3, name)
            XCTAssertNotEqual(term.plainLabel, term.technicalName, name)
            XCTAssertGreaterThan(term.explanation.count, 30, name)
            XCTAssertTrue(term.explanation.hasSuffix("."), name)
            XCTAssertTrue(SystemSetupStep.allCases.contains { SystemSetupTerm.terms(on: $0).contains(term) },
                          "\(name) is shown on a step, so that step lists its explanation")
        }
        for term in SystemSetupTerm.allCases {
            XCTAssertFalse(term.explanation.isEmpty, term.rawValue)
            XCTAssertTrue(SystemSetupStep.allCases.contains { SystemSetupTerm.terms(on: $0).contains(term) }, term.rawValue)
        }
    }

    func testSeatMarksPutTheMainSeatFirstAndKeepEverySeatInsideAndApart() {
        for count in 1...9 {
            let marks = SystemSetupPlacementGuidance.seatMarks(count: count)
            XCTAssertEqual(marks.count, count)
            XCTAssertEqual(marks.first, CGPoint(x: 0.5, y: 0.62))
            for mark in marks {
                XCTAssertTrue((0.05...0.95).contains(mark.x) && (0.05...0.95).contains(mark.y), "\(count): \(mark)")
            }
            for i in marks.indices { for j in marks.indices where j > i {
                XCTAssertGreaterThan(hypot(marks[i].x - marks[j].x, marks[i].y - marks[j].y), 0.1, "\(count)")
            } }
        }
        XCTAssertEqual(SystemSetupPlacementGuidance.seatMarks(count: 0).count, 1)
    }

    func testVerifyGraphNeedsTheBandedResponseAndDrawsPredictedAgainstMeasured() {
        let bare = SystemSetupVerificationReport(passed: true, predictedErrorDB: 1, measuredErrorDB: 1, sampleRate: 48_000)
        XCTAssertNil(SystemSetupGraphBuilder.verify(report: bare))
        var full = bare
        full.centresHz = [100, 200, 400]
        full.predictedDB = [0, 1, 0]
        full.measuredDB = [0.5, 1, -0.5]
        let graph = SystemSetupGraphBuilder.verify(report: full)
        XCTAssertEqual(graph?.curves.map(\.label), ["Predicted", "Measured with the correction on"])
        // A stored session without the new fields still decodes.
        let old = #"{"passed":true,"predictedErrorDB":1,"measuredErrorDB":2,"sampleRate":48000}"#
        XCTAssertNoThrow(try JSONDecoder().decode(SystemSetupVerificationReport.self, from: Data(old.utf8)))
    }

    // MARK: Production model at the eight rates

    private func drive(_ rig: OfflineSetupRig, label: String) async throws {
        let model = rig.model
        rig.chooseTwoPointOneThroughWizard()
        model.selectMicrophone(uid: OfflineSetupRig.inputUID)
        model.acceptSweepLevel(measuredSPLdBC: 75)
        model.next()
        model.next()
        XCTAssertEqual(model.step, .measure, "\(label): \(model.message ?? "")")
        model.prepareMeasure()
        model.addSeat()
        model.addSeat()
        await model.measureAll()
    }

    private func assertSane(_ graph: SystemSetupGraph?, rate: Double, label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let graph else { return XCTFail("\(label): no graph", file: file, line: line) }
        for curve in graph.curves {
            XCTAssertEqual(curve.frequenciesHz.count, curve.levelsDB.count, "\(label) \(curve.label)", file: file, line: line)
            XCTAssertTrue(curve.levelsDB.allSatisfy(\.isFinite), "\(label) \(curve.label)", file: file, line: line)
            XCTAssertLessThanOrEqual(curve.frequenciesHz.last ?? 0, rate * 0.45 * 1.0001, "\(label) \(curve.label)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(curve.frequenciesHz.first ?? 0, graph.lowHz - 1e-9, "\(label) \(curve.label)", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(graph.levelRangeDB.upperBound - graph.levelRangeDB.lowerBound, 20, label, file: file, line: line)
    }

    func testEachStepHasGraphDataAtEveryRateInSimpleAndExpertMode() async throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate)
            defer { rig.tearDown() }
            let label = "\(rate) Hz"
            try await drive(rig, label: label)
            let model = rig.model

            // Measure: the main seat in simple mode, every seat in expert mode.
            model.graphDetail = .simple
            let simple = try XCTUnwrap(model.measureGraph, label)
            XCTAssertEqual(simple.curves.count, 1, label)
            XCTAssertTrue(simple.hasSeatDetail, label)
            assertSane(simple, rate: rate, label: label)
            XCTAssertEqual(try XCTUnwrap(simple.curves.first).levelsDB.count, simple.curves[0].frequenciesHz.count)
            model.graphDetail = .expert
            let expert = try XCTUnwrap(model.measureGraph, label)
            XCTAssertEqual(expert.curves.count, 3, label)
            assertSane(expert, rate: rate, label: label)
            // The reference level reads 0 dB at the middle of the range for the main seat.
            let main = expert.curves[0]
            let middle = zip(main.frequenciesHz, main.levelsDB).filter { (200.0...2_000).contains($0.0) }.map(\.1)
            XCTAssertEqual(middle.reduce(0, +) / Double(max(middle.count, 1)), 0, accuracy: 1e-6, label)

            model.next()
            await model.computeAlignment()
            model.applyAlignment()
            model.next()
            model.computeBass()
            await model.applyBass()
            if let bass = model.bass, bass.mode == .jointOptimised {
                let layout = SyntheticReferenceRoom(rate: rate, seatCount: 3, sourcesPerSeat: 3)
                let range = PhysicalSubwooferCalibration.gainRangeDB
                rig.trialPlayer.subPaths = bass.rows.compactMap { row in
                    guard case .subwoofer(let index) = row.source else { return nil }
                    return OfflineTrialSweepPlayer.SubPath(
                        lane: 2 + Int(index), room: layout.room(measurement: 2, outputChannel: 2),
                        gainDB: min(range.upperBound, max(range.lowerBound, row.gainDB)),
                        delaySeconds: min(PhysicalSubwooferCalibration.delayRangeMilliseconds.upperBound, max(0, row.delayMilliseconds)) / 1_000,
                        inverted: row.polarityInverted)
                }
                // Bass: now against predicted, one pair in simple mode, a pair per seat in expert mode.
                model.graphDetail = .simple
                let bassSimple = try XCTUnwrap(model.bassGraph, "\(label): \(model.message ?? "")")
                XCTAssertEqual(bassSimple.curves.map(\.role), [.before, .predicted], label)
                assertSane(bassSimple, rate: rate, label: label)
                model.graphDetail = .expert
                XCTAssertEqual(try XCTUnwrap(model.bassGraph).curves.count, 2 * bass.seatNames.count, label)
            }

            model.next()
            model.prepareCorrection()
            XCTAssertNil(model.correctionGraph?.curves.first { $0.role == .predicted }, "nothing is predicted before Apply")
            await model.applyCorrection()
            XCTAssertTrue(model.choices.correctionApplied, "\(label): \(model.message ?? "")")
            model.graphDetail = .simple
            let correction = try XCTUnwrap(model.correctionGraph, label)
            XCTAssertEqual(Set(correction.curves.map(\.id)), ["measured", "target", "predicted"], label)
            assertSane(correction, rate: rate, label: label)
            model.graphDetail = .expert
            XCTAssertEqual(try XCTUnwrap(model.correctionGraph).curves.count, 3 + 2, "\(label): a curve per seat, the target and the prediction")

            // Reverting takes the prediction away with the correction.
            model.revertCorrection()
            model.graphDetail = .simple
            XCTAssertNil(model.correctionGraph?.curves.first { $0.role == .predicted }, label)
            await model.applyCorrection()

            rig.trialPlayer.mainDelaySeconds = rig.engine.roomCorrectionConfiguration.lanes?.laneDelays.first { $0.lane == 0 }?.seconds ?? 0
            model.next()
            XCTAssertEqual(model.step, .verify, "\(label): \(model.message ?? "")")
            model.runVerification()
            for _ in 0..<600 where model.isVerifying { try? await Task.sleep(for: .milliseconds(50)) }
            let verify = try XCTUnwrap(model.verifyGraph, "\(label): \(model.message ?? "")")
            XCTAssertEqual(verify.curves.map(\.id), ["predicted", "measured"], label)
            assertSane(verify, rate: rate, label: label)
        }
    }

    func testCorrectionGraphFromTheStereoFiltersOwnResponsesAndWithoutAPrediction() {
        let f = (1...2_000).map { Double($0) * 10 }
        let measured = RoomCorrectionFrequencyResponse(frequenciesHz: f, magnitudeDB: f.map { $0 < 100 ? 8 : 0 }, phaseRadians: nil)
        let predicted = RoomCorrectionFrequencyResponse(frequenciesHz: f, magnitudeDB: f.map { _ in 0 }, phaseRadians: nil)
        let graph = SystemSetupGraphBuilder.correction(
            seats: [], measurements: [], target: nil, prediction: .responses(predicted: predicted, measured: measured),
            sampleRate: 48_000, detail: .simple)
        XCTAssertEqual(Set(graph?.curves.map(\.id) ?? []), ["measured", "predicted"], "no target given, none drawn")
        let low = graph?.curves.first { $0.id == "measured" }
        XCTAssertGreaterThan(low?.levelsDB.first ?? 0, 6, "the bass bump is drawn")
        XCTAssertEqual(graph?.curves.first { $0.id == "predicted" }?.levelsDB.first ?? 99, 0, accuracy: 0.5)
        XCTAssertNil(SystemSetupGraphBuilder.correction(
            seats: [], measurements: [], target: nil, prediction: nil, sampleRate: 48_000, detail: .simple),
                     "no measurement, no graph")
    }

    // MARK: Screen fit (AGENTS.md section 13)

    func testGraphStepsFitAtTheOwnerSizesWithEveryGraphShown() async throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        try await drive(rig, label: "layout")
        let model = rig.model
        model.next()
        await model.computeAlignment()
        model.applyAlignment()
        model.next()
        model.computeBass()
        await model.applyBass()
        model.next()
        model.prepareCorrection()
        await model.applyCorrection()
        model.graphDetail = .expert
        let steps: [(String, AnyView)] = [
            ("measure", AnyView(SystemSetupMeasureStep(model: model))),
            ("bass", AnyView(SystemSetupBassStep(model: model))),
            ("correction", AnyView(SystemSetupCorrectionStep(model: model))),
            ("verify", AnyView(SystemSetupVerifyStep(model: model))),
            ("microphone", AnyView(SystemSetupMicrophoneStep(model: model))),
            ("alignment", AnyView(SystemSetupAlignmentStep(model: model)))
        ]
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            // The sheet's step column is narrower than the window; the narrowest column is checked as well.
            for width in [size.width, 640] {
                for (name, view) in steps {
                    let page = HostedPage(view.frame(width: width), size: CGSize(width: width, height: size.height))
                    var views = 0
                    func walk(_ v: NSView) {
                        let frame = v.convert(v.bounds, to: page.hosting)
                        if !(v is NSScroller), frame.width > 0 {
                            views += 1
                            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(name) \(type(of: v)) left of the page at \(width)")
                            XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(name) \(type(of: v)) past the page at \(width)")
                        }
                        v.subviews.forEach(walk)
                    }
                    walk(page.hosting)
                    XCTAssertGreaterThan(views, 1, "\(name) laid out at \(width)")
                }
            }
        }
    }
}
