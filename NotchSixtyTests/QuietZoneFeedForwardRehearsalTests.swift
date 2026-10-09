import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneFeedForwardRehearsalTests: XCTestCase {
    private func candidate() -> QuietZoneCausalFIRCandidate {
        QuietZoneCausalFIRCandidate(
            sampleRate: 48_000,
            leftTaps: [0.01, 0, 0],
            rightTaps: [0.01, 0, 0],
            worstPredictedReductionDB: 2,
            maximumRelativeFitError: 0.05,
            maximumReferenceEchoFraction: 0.01
        )
    }

    private func sample(
        host: UInt64, base: Double, offset: UInt32
    ) -> N60FeedForwardReferenceFrame {
        var f = N60FeedForwardReferenceFrame()
        f.sample = 0.3
        f.firstFrameHostTime = host
        f.firstFrameSampleTime = base
        f.frameOffset = offset
        return f
    }

    func testCallbackReferenceFramesEnterDryRunButNeverPlayback() throws {
        let rehearsal = try QuietZoneFeedForwardRehearsal(candidate: candidate())
        let frames = (0..<128).map {
            sample(host: 50_000, base: 1_000, offset: UInt32($0))
        }
        let snapshot = try rehearsal.rehearse(frames)
        XCTAssertEqual(snapshot.processedReferenceFrames, 128)
        XCTAssertEqual(snapshot.lastInputSampleTime, 1127)
        XCTAssertEqual(snapshot.timingFaults, 0)
        XCTAssertFalse(snapshot.outputConnected)
        rehearsal.stop()
    }

    func testGapInReferenceStreamImmediatelyStopsRehearsal() throws {
        let rehearsal = try QuietZoneFeedForwardRehearsal(candidate: candidate())
        _ = try rehearsal.rehearse([
            sample(host: 100, base: 200, offset: 0),
            sample(host: 100, base: 200, offset: 1)
        ])
        XCTAssertThrowsError(try rehearsal.rehearse([
            sample(host: 200, base: 205, offset: 0)
        ]))
        XCTAssertEqual(rehearsal.snapshot().timingFaults, 1)
        XCTAssertThrowsError(try rehearsal.rehearse([
            sample(host: 201, base: 206, offset: 0)
        ]))
    }

    func testClockRewindCannotBeIgnored() throws {
        let rehearsal = try QuietZoneFeedForwardRehearsal(candidate: candidate())
        _ = try rehearsal.rehearse([
            sample(host: 200, base: 500, offset: 0)
        ])
        XCTAssertThrowsError(try rehearsal.rehearse([
            sample(host: 199, base: 501, offset: 0)
        ]))
    }

    func testRejectsInvalidOrOverBudgetCoefficients() {
        var invalid = candidate()
        invalid.leftTaps = [0.2]
        invalid.rightTaps = [0.2]
        XCTAssertThrowsError(
            try QuietZoneFeedForwardRehearsal(candidate: invalid)
        )
    }
}
