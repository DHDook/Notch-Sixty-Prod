import Foundation
import XCTest
@testable import NotchSixty

final class QuietZoneHardwareClockCaptureTests: XCTestCase {
    private func collector() throws -> QuietZoneHardwareClockAccumulator {
        try QuietZoneHardwareClockAccumulator(
            microphoneID: "microphone-A", outputID: "DAC-B",
            sampleRate: 48_000
        )
    }

    func testSyntheticConcurrentStableTracesAreBenchOnly() throws {
        var trace = try collector()
        for index in 0..<12 {
            let time = 100 + Double(index) * 0.25
            let frame = 12_000 + Double(index) * 12_000
            try trace.addInput(hostSeconds: time, sampleFrame: frame)
            try trace.addOutput(hostSeconds: time + 0.001, sampleFrame: frame)
        }
        let evidence = try trace.qualify()
        XCTAssertTrue(evidence.health.qualifiedForLoopbackBench)
        XCTAssertFalse(evidence.liveANCQualified)
        XCTAssertFalse(evidence.health.physicalLatencyMeasured)
        XCTAssertEqual(evidence.trace.inputDeviceID, "microphone-A")
        XCTAssertEqual(evidence.trace.outputDeviceID, "DAC-B")
    }

    func testNonOverlappingSnapshotsNeverQualify() throws {
        var trace = try collector()
        for index in 0..<12 {
            let frame = Double(index) * 12_000
            try trace.addInput(
                hostSeconds: 100 + Double(index) * 0.25, sampleFrame: frame
            )
            try trace.addOutput(
                hostSeconds: 104 + Double(index) * 0.25, sampleFrame: frame
            )
        }
        XCTAssertThrowsError(try trace.qualify())
    }

    func testReplayedTimestampsAndDiscontinuityFailClosed() throws {
        var trace = try collector()
        try trace.addInput(hostSeconds: 100, sampleFrame: 1_000)
        XCTAssertThrowsError(try trace.addInput(
            hostSeconds: 100, sampleFrame: 1_000
        ))
        XCTAssertThrowsError(try trace.addInput(
            hostSeconds: 101, sampleFrame: 900
        ))
        XCTAssertThrowsError(try trace.addOutput(
            hostSeconds: .nan, sampleFrame: 1_000
        ))
        XCTAssertEqual(trace.input.count, 1)
    }

    func testIndependentClockDriftIsRejected() throws {
        var trace = try collector()
        for index in 0..<12 {
            let time = 100 + Double(index) * 0.25
            try trace.addInput(
                hostSeconds: time,
                sampleFrame: 1_000 + Double(index) * 12_000
            )
            try trace.addOutput(
                hostSeconds: time,
                sampleFrame: 1_000 + Double(index) * 12_005
            )
        }
        XCTAssertThrowsError(try trace.qualify())
    }

    func testIncompleteClockCaptureCannotClaimPhysicalLatency() throws {
        var trace = try collector()
        try trace.addInput(hostSeconds: 100, sampleFrame: 1_000)
        try trace.addOutput(hostSeconds: 100, sampleFrame: 1_000)
        XCTAssertThrowsError(try trace.qualify())
    }
}
