import Foundation
import XCTest
@testable import NotchSixty

final class NativeSOFAImporterTests: XCTestCase {
    func testListenerFrameMapsSOFALeftToRendererNegativeAzimuth() throws {
        let frame = try SOFAListenerFrame(
            position: .zero,
            view: SOFAVector3(x: 1, y: 0, z: 0),
            up: SOFAVector3(x: 0, y: 0, z: 1)
        )

        let left = try frame.sphericalPosition(
            of: SOFAVector3(x: 0, y: 1, z: 0)
        )
        let right = try frame.sphericalPosition(
            of: SOFAVector3(x: 0, y: -1, z: 0)
        )

        XCTAssertEqual(left.azimuthDegrees, -90, accuracy: 1.0e-9)
        XCTAssertEqual(right.azimuthDegrees, 90, accuracy: 1.0e-9)
        XCTAssertEqual(left.elevationDegrees, 0, accuracy: 1.0e-9)
        XCTAssertEqual(left.distanceMeters, 1, accuracy: 1.0e-9)
    }

    func testIntegerDelayBakePreservesRelativeReceiverTiming() throws {
        let dataset = try makeDataset(
            delays: [-1, 0],
            emitterCount: 1,
            emitterDependent: false
        )
        let asset = try SOFABinauralAssetAdapter().makeAsset(
            from: dataset,
            sourceURL: URL(fileURLWithPath: "/tmp/integer.sofa")
        )

        XCTAssertEqual(asset.tapCount, dataset.tapCount + 1)
        XCTAssertEqual(asset.measurements[0].leftIR[0], 1, accuracy: 1.0e-6)
        XCTAssertEqual(asset.measurements[0].rightIR[1], 1, accuracy: 1.0e-6)
        XCTAssertEqual(
            asset.importProvenance?.delayBakeCommonOffsetSamples,
            1
        )
    }

    func testFractionalDelayBakeIsFiniteAndPreservesDCWeight() throws {
        let dataset = try makeDataset(
            delays: [0.5, 0],
            emitterCount: 1,
            emitterDependent: false
        )
        let asset = try SOFABinauralAssetAdapter().makeAsset(
            from: dataset,
            sourceURL: URL(fileURLWithPath: "/tmp/fractional.sofa")
        )

        let left = asset.measurements[0].leftIR
        XCTAssertTrue(left.allSatisfy(\.isFinite))
        XCTAssertEqual(
            left.reduce(0, +),
            1,
            accuracy: 0.002
        )
        XCTAssertEqual(
            asset.importProvenance?.fractionalDelayKernelRadius,
            SOFABinauralAssetAdapter.fractionalDelayKernelRadius
        )
    }

    func testBinauralAdapterRejectsMultipleEmittersWithoutLosingGenericDataset() throws {
        let dataset = try makeDataset(
            delays: [0, 0, 0, 0],
            emitterCount: 2,
            emitterDependent: true
        )
        XCTAssertNoThrow(try dataset.validate())

        XCTAssertThrowsError(
            try SOFABinauralAssetAdapter().makeAsset(
                from: dataset,
                sourceURL: URL(fileURLWithPath: "/tmp/multi-emitter.sofa")
            )
        ) { error in
            XCTAssertEqual(
                error as? SOFAImportError,
                .unsupportedEmitterCount(2)
            )
        }
    }

    func testNativeGeneratedSOFAFixtureLoadsEndToEnd() throws {
        guard let fixture = ProcessInfo.processInfo.environment[
            "PR85_SOFA_FIXTURE"
        ], !fixture.isEmpty else {
            throw XCTSkip("PR85_SOFA_FIXTURE is not configured.")
        }

        let url = URL(fileURLWithPath: fixture)
        let dataset = try NativeSOFAImporter().load(from: url)

        XCTAssertEqual(dataset.measurementCount, 2)
        XCTAssertEqual(dataset.receiverCount, 2)
        XCTAssertEqual(dataset.emitterCount, 1)
        XCTAssertEqual(dataset.tapCount, 8)
        XCTAssertEqual(dataset.sampleRate, 48_000, accuracy: 1.0e-9)
        XCTAssertEqual(
            dataset.provenance.sofaConvention,
            "SimpleFreeFieldHRIR"
        )
        XCTAssertEqual(dataset.provenance.sourceLicense, "CC0-1.0")

        let asset = try SOFABinauralAssetAdapter().makeAsset(
            from: dataset,
            sourceURL: url
        )
        XCTAssertEqual(asset.measurements.count, 2)
        XCTAssertEqual(
            asset.measurements[0].azimuthDegrees,
            -30,
            accuracy: 0.01
        )
        XCTAssertEqual(
            asset.measurements[1].azimuthDegrees,
            30,
            accuracy: 0.01
        )
        XCTAssertTrue(
            asset.measurements.flatMap(\.leftIR).allSatisfy(\.isFinite)
        )
        XCTAssertEqual(asset.importProvenance?.dataType, "FIR")
    }

    private func makeDataset(
        delays: [Double],
        emitterCount: Int,
        emitterDependent: Bool
    ) throws -> SOFAFIRDataset {
        let measurements = 1
        let receivers = 2
        let taps = 4
        let signalEmitters = emitterDependent ? emitterCount : 1
        let signalCount = measurements * receivers * signalEmitters

        XCTAssertEqual(delays.count, signalCount)
        var ir = [Float](repeating: 0, count: signalCount * taps)
        for signal in 0..<signalCount {
            ir[signal * taps] = 1
        }

        let provenance = SOFAImportProvenance(
            sourceFileName: "synthetic.sofa",
            sofaConvention: "GeneralFIR",
            sofaConventionVersion: "2.0",
            sofaVersion: "2.1",
            dataType: emitterDependent ? "FIR-E" : "FIR",
            roomType: "free field",
            sourceLicense: "Synthetic test fixture",
            title: "Synthetic",
            measurementCount: measurements,
            receiverCount: receivers,
            emitterCount: emitterCount,
            sourceTapCount: taps,
            delayBakeCommonOffsetSamples: 0,
            fractionalDelayKernelRadius: 0
        )
        let frame = try SOFAListenerFrame(
            position: .zero,
            view: SOFAVector3(x: 1, y: 0, z: 0),
            up: SOFAVector3(x: 0, y: 0, z: 1)
        )

        return SOFAFIRDataset(
            sampleRate: 48_000,
            measurementCount: measurements,
            receiverCount: receivers,
            emitterCount: emitterCount,
            tapCount: taps,
            emitterDependent: emitterDependent,
            provenance: provenance,
            listenerFrames: [frame],
            sourcePositions: [SOFAVector3(x: 1, y: 0, z: 0)],
            emitterPositions: Array(
                repeating: .zero,
                count: emitterCount
            ),
            delaysSamples: delays,
            impulseResponses: ir
        )
    }
}
