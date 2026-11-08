import XCTest
@testable import NotchSixty

/// E27 S3b: A/B slots, loudness match and the Listen audition override.
final class EQComparisonTests: XCTestCase {
    private func eq(_ gain: Double, f: Double = 1_000) -> StereoEQConfiguration {
        EQRenderHarness.peakConfiguration(gainDB: gain, frequency: f)
    }

    func testSlotsRoundTripEachSlotExactly() {
        let a = eq(3), b = eq(-4, f: 250)
        var slots = EQComparisonSlots(live: a)
        slots.store(b, in: .b)
        let onB = slots.switchTo(.b, live: a)
        XCTAssertEqual(onB.linkedBands, b.linkedBands)
        let onA = slots.switchTo(.a, live: onB)
        XCTAssertEqual(onA.linkedBands, a.linkedBands)
        XCTAssertEqual(slots.switchTo(.b, live: onA).linkedBands, b.linkedBands)
        XCTAssertEqual(slots.configuration(.a).linkedBands, a.linkedBands)
    }

    func testSwitchKeepsLiveBypassAndCopyTargetsOtherSlot() {
        let a = eq(3), b = eq(-4)
        var slots = EQComparisonSlots(live: a)
        slots.store(b, in: .b)
        var bypassed = a
        bypassed.bypassed = true
        XCTAssertTrue(slots.switchTo(.b, live: bypassed).bypassed)
        XCTAssertNil(slots.copy(from: .b, live: b))  // copies B over A (inactive): nothing to publish
        XCTAssertEqual(slots.configuration(.a).linkedBands, b.linkedBands)
        let published = slots.copy(from: .a, live: b)  // copies A over active B
        XCTAssertEqual(published?.linkedBands, b.linkedBands)
    }

    func testLoudnessMatchReadsBroadbandShelfAtEveryRate() {
        let flat = StereoEQConfiguration()
        let shelf = StereoEQConfiguration(
            linkedBands: [EQBand(type: .highShelf, frequencyHz: 20, gainDB: 6, q: 0.707)])
        for rate in EQRenderHarness.rates {
            let d = EQLoudnessMatch.differenceDB(shelf, flat, rate: rate)
            XCTAssertEqual(d, 6.0, accuracy: 0.1, "rate \(rate)")
            XCTAssertEqual(EQLoudnessMatch.differenceDB(flat, shelf, rate: rate), -d, accuracy: 1e-9)
        }
        var bypassed = shelf
        bypassed.bypassed = true
        XCTAssertEqual(EQLoudnessMatch.differenceDB(bypassed, flat, rate: 48_000), 0, accuracy: 1e-9)
    }

    func testAuditionLeavesStoredEQUntouchedAndIsMinimumPhaseBandPass() {
        var stored = eq(9, f: 2_000)
        stored.phaseMode = .linearPhase
        let copy = stored
        let rendered = stored.auditioned(EQAuditionOverride(band: stored.linkedBands[0]))
        XCTAssertEqual(stored, copy)
        XCTAssertEqual(rendered.phaseMode, .minimumPhase)
        XCTAssertEqual(rendered.linkedBands.count, 1)
        XCTAssertEqual(rendered.linkedBands[0].type, .bandPass)
        XCTAssertEqual(rendered.linkedBands[0].frequencyHz, 2_000)
        let shelf = EQBand(type: .lowShelf, frequencyHz: 100, gainDB: 5, q: 3)
        XCTAssertEqual(EQAuditionOverride(band: shelf).q, 0.707)
    }

    func testAuditionStartAndStopMeetStepCriterionAndNeverRaisePeak() throws {
        for rate in EQRenderHarness.rates {
            let stored = eq(12)
            let normal = try EQRenderHarness.spec(stored, rate: rate)
            let audition = try EQRenderHarness.spec(
                stored, rate: rate, audition: EQAuditionOverride(frequencyHz: 1_000, q: 1))
            for (specs, label) in [([normal, audition], "start"), ([audition, normal], "stop")] {
                let r = try EQRenderHarness.render(rate: rate, specs: specs)
                let s = r.switchIndex
                let settled = Int(rate * 0.1)
                let allowed = max(
                    EQRenderHarness.maxStep(r.output[(s - settled)..<s]),
                    EQRenderHarness.maxStep(r.output[(r.output.count - settled)...])) + 1e-4
                let window = r.output[(s - 1)..<min(r.output.count, s + Int(rate * 0.04))]
                XCTAssertLessThanOrEqual(EQRenderHarness.maxStep(window), allowed, "audition \(label) \(rate)")
            }
            // Unity-peak band-pass at the tone: the audition never raises the peak above the input.
            let r = try EQRenderHarness.render(rate: rate, specs: [audition])
            let peak = r.output.suffix(Int(rate * 0.05)).map { abs($0) }.max() ?? 0
            XCTAssertLessThanOrEqual(peak, 0.5012 * 1.01, "audition peak \(rate)")
        }
    }

    func testABToggleMeetsStepCriterionAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let a = try EQRenderHarness.spec(eq(12), rate: rate)
            let b = try EQRenderHarness.spec(eq(-6, f: 1_000), rate: rate)
            let r = try EQRenderHarness.render(rate: rate, specs: [a, b])
            let s = r.switchIndex
            let settled = Int(rate * 0.1)
            let allowed = max(
                EQRenderHarness.maxStep(r.output[(s - settled)..<s]),
                EQRenderHarness.maxStep(r.output[(r.output.count - settled)...])) + 1e-4
            let window = r.output[(s - 1)..<min(r.output.count, s + Int(rate * 0.04))]
            XCTAssertLessThanOrEqual(EQRenderHarness.maxStep(window), allowed, "A/B \(rate)")
        }
    }
}
