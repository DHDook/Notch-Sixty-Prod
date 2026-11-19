import Foundation
import XCTest
@testable import NotchSixty

/// E33 S19 (G37): the reference-curve adapter and selection.
final class EQReferenceCurvesTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func response(rate: Double, offset: Double) -> RoomCorrectionFrequencyResponse {
        let top = rate * 0.49
        var frequencies: [Double] = []
        var f = 20.0
        while f < top { frequencies.append(f); f *= 1.25 }
        let magnitude = frequencies.map { 70 + offset + 6 * sin(log($0)) }
        return RoomCorrectionFrequencyResponse(frequenciesHz: frequencies, magnitudeDB: magnitude, phaseRadians: nil)
    }

    private func project(rate: Double, measuredAt: Date, designAt: Date?, withTarget: Bool = true) -> RoomCorrectionProject {
        var project = RoomCorrectionProject(playbackSystemID: UUID(), name: "Room")
        let measured = response(rate: rate, offset: 0)
        let channel = RoomCorrectionChannelMeasurement(
            capturedAt: measuredAt, rawCapture: [], impulseResponse: [], transferFunction: measured,
            quality: RoomCorrectionMeasurementQuality())
        project.measurements = [RoomCorrectionMeasurementPosition(
            name: "Main", sampleRate: rate, left: channel, right: channel)]
        let target = RoomCorrectionTargetCurve(name: "Flat", points: [
            RoomCorrectionTargetPoint(frequencyHz: 20, gainDB: 3),
            RoomCorrectionTargetPoint(frequencyHz: 1_000, gainDB: 0),
            RoomCorrectionTargetPoint(frequencyHz: 20_000, gainDB: -2),
        ])
        if withTarget { project.target = target }
        if let designAt {
            let design = RoomCorrectionDesign(
                name: "D", createdAt: designAt, sampleRate: rate,
                parameters: RoomCorrectionDesignParameters(
                    correctionLowHz: 25, correctionHighHz: 19_000, smoothingOctaves: 0.2,
                    maximumBoostDB: 6, maximumCutDB: 12, requestedTapCount: 1_024),
                target: withTarget ? target : nil,
                filter: RoomCorrectionFilter(
                    name: "D", sampleRate: rate, leftTaps: [1], rightTaps: [1], declaredLatencyFrames: 0),
                predictedLeftResponse: response(rate: rate, offset: -3),
                predictedRightResponse: response(rate: rate, offset: -3),
                recommendedHeadroomDB: 0, algorithmVersion: "test")
            project.designs = [design]
            project.selectedDesignID = design.id
        }
        return project
    }

    func testAdapterKeepsTheStoredResponseAtEveryRate() {
        for rate in rates {
            let stored = response(rate: rate, offset: 0)
            let curves = RoomCorrectionReferenceCurveSource(
                project: project(rate: rate, measuredAt: now, designAt: now)).referenceCurves(now: now)
            let measurement = curves.first { $0.kind == .measurement }
            XCTAssertEqual(measurement?.frequenciesHz, stored.frequenciesHz, "\(rate)")
            // Only the level moves: the shape is the stored one.
            let shift = zip(measurement?.gainDB ?? [], stored.magnitudeDB).map { $1 - $0 }
            XCTAssertEqual(shift.max() ?? 0, shift.min() ?? 1, accuracy: 1e-9, "\(rate)")
            XCTAssertEqual(curves.map(\.kind), [.measurement, .corrected, .target], "\(rate)")
            XCTAssertEqual(curves.last?.gainDB, [3, 0, -2])
        }
    }

    func testNoMeasurementShowsNoCurvesAndAnEmptyMenu() {
        XCTAssertTrue(RoomCorrectionReferenceCurveSource(project: nil).referenceCurves(now: now).isEmpty)
        var empty = RoomCorrectionProject(playbackSystemID: UUID(), name: "Empty")
        XCTAssertTrue(RoomCorrectionReferenceCurveSource(project: empty).referenceCurves(now: now).isEmpty)
        empty.measurements = project(rate: 48_000, measuredAt: now, designAt: nil, withTarget: false).measurements
        empty.measurements[0].included = false
        XCTAssertTrue(RoomCorrectionReferenceCurveSource(project: empty).referenceCurves(now: now).isEmpty)
    }

    func testOutOfDateMarks() {
        let old = now.addingTimeInterval(-40 * 24 * 3_600)
        let fresh = RoomCorrectionReferenceCurveSource(
            project: project(rate: 48_000, measuredAt: now, designAt: now)).referenceCurves(now: now)
        XCTAssertTrue(fresh.allSatisfy { !$0.isOutOfDate })
        let aged = RoomCorrectionReferenceCurveSource(
            project: project(rate: 48_000, measuredAt: old, designAt: old)).referenceCurves(now: now)
        XCTAssertTrue(aged.first { $0.kind == .measurement }!.isOutOfDate)
        XCTAssertTrue(aged.first { $0.kind == .corrected }!.isOutOfDate)
        // The seat was measured again after the design.
        let replaced = RoomCorrectionReferenceCurveSource(
            project: project(rate: 48_000, measuredAt: now, designAt: now.addingTimeInterval(-3_600)))
            .referenceCurves(now: now)
        XCTAssertFalse(replaced.first { $0.kind == .measurement }!.isOutOfDate)
        XCTAssertTrue(replaced.first { $0.kind == .corrected }!.isOutOfDate)
        XCTAssertTrue(replaced.first { $0.kind == .corrected }!.label.hasSuffix("out of date"))
    }

    func testSelectionRoundTripAndVisibility() {
        let chosen: Set<EQReferenceCurveKind> = [.target, .measurement]
        let raw = EQReferenceSelection.raw(from: chosen)
        XCTAssertEqual(raw, "measurement,target")
        XCTAssertEqual(EQReferenceSelection.kinds(from: raw), chosen)
        XCTAssertEqual(EQReferenceSelection.kinds(from: "junk,,target"), [.target])
        let curves = RoomCorrectionReferenceCurveSource(
            project: project(rate: 48_000, measuredAt: now, designAt: now)).referenceCurves(now: now)
        XCTAssertEqual(EQReferenceSelection.visible(curves, chosen: chosen).map(\.kind), [.measurement, .target])
        XCTAssertTrue(EQReferenceSelection.visible(curves, chosen: []).isEmpty)
    }

    /// Curves are not an input to the EQ: the compiled program for the same bands is the same before and after
    /// the curves are read.
    @MainActor
    func testReferenceCurvesLeaveTheEQProgramUnchanged() {
        let bands = [EQBand(type: .peaking, frequencyHz: 1_000, gainDB: -4, q: 2)]
        for rate in rates {
            let before = EQResponseCache().program(bands: bands, sampleRate: rate)
            _ = RoomCorrectionReferenceCurveSource(
                project: project(rate: rate, measuredAt: now, designAt: now)).referenceCurves(now: now)
            let after = EQResponseCache().program(bands: bands, sampleRate: rate)
            XCTAssertEqual(before.count, after.count)
            for (a, b) in zip(before, after) {
                XCTAssertEqual(a.b0, b.b0); XCTAssertEqual(a.a1, b.a1); XCTAssertEqual(a.a2, b.a2)
            }
        }
    }
}
