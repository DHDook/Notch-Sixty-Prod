import Foundation
import XCTest
@testable import NotchSixty

/// E21 S10a: the Quiet Zone design maths in libn60core (n60/anc_design.h) against the Swift reference, flag path on and off.
final class QuietZoneDesignCoreParityTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func z(_ re: Double, _ im: Double = 0) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(real: re, imaginary: im)
    }

    private func band(_ hz: Double, leak: Double = 0.2, coherence: Double = 0.98) -> QuietZoneVirtualSeatBand {
        QuietZoneVirtualSeatBand(
            frequencyHz: hz, sourceToReference: z(1, 0.1), sourceToListener: z(0.02, 0.01),
            leftSecondaryAtListener: z(1, 0.05), rightSecondaryAtListener: z(0.9, -0.1),
            leftLeakageAtReference: z(leak), rightLeakageAtReference: z(leak), measuredCoherence: coherence)
    }

    /// Real-valued plant (the FIR compiler fixture): a short real-tap filter can represent its target.
    private func realBand(_ hz: Double) -> QuietZoneVirtualSeatBand {
        QuietZoneVirtualSeatBand(
            frequencyHz: hz, sourceToReference: z(1), sourceToListener: z(0.02),
            leftSecondaryAtListener: z(1), rightSecondaryAtListener: z(1),
            leftLeakageAtReference: z(0.2), rightLeakageAtReference: z(0.2), measuredCoherence: 0.98)
    }

    private func budget() -> QuietZoneFeedForwardBudget {
        QuietZoneFeedForwardBudget(
            readiness: .physicallyPlausible, acousticPreviewSeconds: 0.018, conservativePreviewSeconds: 0.016,
            antiNoisePathSeconds: 0.008, conservativeReserveSeconds: 0.007, geometryOnly: false,
            runtimeAvailable: false, explanation: "fixture")
    }

    private func close(_ a: ActiveQuietZoneComplex, _ b: ActiveQuietZoneComplex, _ tol: Double = 1e-9, line: UInt = #line) {
        XCTAssertEqual(a.real, b.real, accuracy: tol, line: line)
        XCTAssertEqual(a.imaginary, b.imaginary, accuracy: tol, line: line)
    }

    private func designs() throws -> (swift: QuietZoneVirtualSeatDesign, core: QuietZoneVirtualSeatDesign, model: [QuietZoneVirtualSeatBand]) {
        let model = [band(40), band(70), band(110)]
        var reference = QuietZoneVirtualSeatDesigner()
        reference.useCoreMaths = false
        var core = QuietZoneVirtualSeatDesigner()
        core.useCoreMaths = true
        return (try reference.design(measurements: model, budget: budget()), try core.design(measurements: model, budget: budget()), model)
    }

    func testSeatDesignMatchesSwiftReference() throws {
        let (a, b, _) = try designs()
        XCTAssertEqual(a.bands.count, b.bands.count)
        XCTAssertEqual(a.worstModeledReductionDB, b.worstModeledReductionDB, accuracy: 1e-6)
        XCTAssertEqual(a.minimumMeasuredCoherence, b.minimumMeasuredCoherence, accuracy: 1e-12)
        for (x, y) in zip(a.bands, b.bands) {
            close(x.leftFilter, y.leftFilter)
            close(x.rightFilter, y.rightFilter)
            close(x.predictedResidual, y.predictedResidual)
            XCTAssertEqual(x.modeledReductionDB, y.modeledReductionDB, accuracy: 1e-6)
        }
    }

    func testSeatDesignRefusesTheSameInputs() {
        var reference = QuietZoneVirtualSeatDesigner()
        reference.useCoreMaths = false
        var core = QuietZoneVirtualSeatDesigner()
        core.useCoreMaths = true
        let bad = [band(65, leak: 10), band(80, coherence: 0.3)]
        for model in [[band(65, leak: 10)], [band(65, coherence: 0.3)], bad] {
            var swiftError: Error?
            var coreError: Error?
            do { _ = try reference.design(measurements: model, budget: budget()) } catch { swiftError = error }
            do { _ = try core.design(measurements: model, budget: budget()) } catch { coreError = error }
            XCTAssertNotNil(swiftError)
            XCTAssertEqual(swiftError as? QuietZoneVirtualSeatError, coreError as? QuietZoneVirtualSeatError)
        }
    }

    func testCausalFIRMatchesSwiftReferenceAtEveryRate() throws {
        let model = [realBand(40), realBand(70), realBand(110)]
        let design = try QuietZoneVirtualSeatDesigner().design(measurements: model, budget: budget())
        for rate in rates {
            var reference = QuietZoneCausalFIRCompiler()
            reference.useCoreMaths = false
            var core = QuietZoneCausalFIRCompiler()
            core.useCoreMaths = true
            var a: QuietZoneCausalFIRCandidate?
            var b: QuietZoneCausalFIRCandidate?
            var ea: Error?
            var eb: Error?
            do { a = try reference.compile(design: design, measurements: model, budget: budget(), sampleRate: rate, tapCount: 16) } catch { ea = error }
            do { b = try core.compile(design: design, measurements: model, budget: budget(), sampleRate: rate, tapCount: 16) } catch { eb = error }
            // A short filter cannot represent 40-110 Hz at the high rates: both paths must refuse with the same error.
            XCTAssertEqual(ea as? QuietZoneCausalFIRError, eb as? QuietZoneCausalFIRError, "rate \(rate)")
            if rate == 48_000 { XCTAssertNotNil(a) }
            guard let a, let b else { continue }
            XCTAssertEqual(a.leftTaps.count, b.leftTaps.count)
            for (x, y) in zip(a.leftTaps + a.rightTaps, b.leftTaps + b.rightTaps) {
                XCTAssertEqual(x, y, accuracy: 1e-5, "rate \(rate)")
            }
            XCTAssertEqual(a.maximumRelativeFitError, b.maximumRelativeFitError, accuracy: 1e-6)
            XCTAssertFalse(b.liveDeploymentAuthorized)
        }
    }

    func testHALClockAnalysisMatchesSwiftReference() throws {
        func obs(rate: Double, jump: Int? = nil) -> [QuietZoneHALClockObservation] {
            (0..<12).map { i in
                let t = Double(i) * 0.25
                return QuietZoneHALClockObservation(
                    hostTimeSeconds: 5_000 + t, sampleFrame: 1_000_000 + t * rate + (jump.map { i >= $0 ? 128.0 : 0 } ?? 0))
            }
        }
        for jump in [nil, 6] as [Int?] {
            let trace = QuietZoneHALClockTrace(
                inputDeviceID: "mic", outputDeviceID: "dac", nominalSampleRate: 48_000,
                inputObservations: obs(rate: 48_000, jump: jump), outputObservations: obs(rate: 48_001))
            var reference = QuietZoneHALClockAnalyzer()
            reference.useCoreMaths = false
            var core = QuietZoneHALClockAnalyzer()
            core.useCoreMaths = true
            var a: QuietZoneHALClockHealth?
            var b: QuietZoneHALClockHealth?
            var ea: Error?
            var eb: Error?
            do { a = try reference.analyze(trace) } catch { ea = error }
            do { b = try core.analyze(trace) } catch { eb = error }
            XCTAssertEqual(ea as? QuietZoneHALClockError, eb as? QuietZoneHALClockError)
            if let a, let b {
                XCTAssertEqual(a.measuredOutputRateHz, b.measuredOutputRateHz, accuracy: 1e-6)
                XCTAssertEqual(a.relativeDriftPPM, b.relativeDriftPPM, accuracy: 1e-6)
                XCTAssertEqual(a.qualifiedForLoopbackBench, b.qualifiedForLoopbackBench)
            } else {
                XCTAssertNotNil(ea)
            }
        }
    }

    func testUpstreamLeadEstimatorAndAssessmentMatchSwiftReference() {
        for rate in [48_000.0, 192_000.0] {
            let lead = QuietZoneUpstreamLeadEstimator(sampleRate: rate, useCoreMaths: false)
            let core = QuietZoneUpstreamLeadEstimator(sampleRate: rate, useCoreMaths: true)
            var state: UInt64 = 0x1234
            func noise() -> Float {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
            }
            let delay = Int(0.004 * rate)
            var history = [Float](repeating: 0, count: delay + 1)
            var ref: [Float] = []
            var err: [Float] = []
            for i in 0..<Int(10 * rate) {
                let x = noise()
                history[i % history.count] = x
                ref.append(x)
                err.append(history[(i + 1) % history.count] * 0.8 + 0.05 * noise())
            }
            lead.ingest(reference: ref, error: err)
            core.ingest(reference: ref, error: err)
            XCTAssertEqual(lead.decimatedCount, core.decimatedCount)
            guard let a = lead.estimate(), let b = core.estimate() else { return XCTFail("no estimate at \(rate)") }
            XCTAssertEqual(a.leadSeconds, b.leadSeconds, accuracy: 1e-6)
            XCTAssertEqual(a.peakCorrelation, b.peakCorrelation, accuracy: 1e-4)

            let survey = [30.0, 60, 90, 120].map {
                QuietZoneFeedForwardSurveyBand(frequencyHz: $0, referenceToSeat: z(0.8), coherence: 0.95)
            }
            let x = QuietZoneUpstreamAssessment.assess(
                estimate: a, bands: survey, latencySeconds: 0.005, flightSeconds: 0.003, clockOffsetErrorSeconds: 0,
                useCoreMaths: false)
            let y = QuietZoneUpstreamAssessment.assess(
                estimate: a, bands: survey, latencySeconds: 0.005, flightSeconds: 0.003, clockOffsetErrorSeconds: 0,
                useCoreMaths: true)
            XCTAssertEqual(x.verdict, y.verdict)
            XCTAssertEqual(x.meanCoherence, y.meanCoherence, accuracy: 1e-9)
            XCTAssertEqual(x.predictedReductionDB ?? -1, y.predictedReductionDB ?? -1, accuracy: 1e-6)
        }
    }
}
