import Foundation
import XCTest
@testable import NotchSixty

final class MIMORoomTreatmentFIRCompilerTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let sources: [MultichannelCalibrationSource] = [
        .subwoofer(0),
        .subwoofer(1),
    ]

    func testIdentityPlanCompilesToCenteredDiagonalImpulse() throws {
        let plan = makePlan { _, source, target in
            MIMORoomTreatmentComplexCoefficient(
                real: source == target ? 1 : 0,
                imaginary: 0
            )
        }

        let program = try MIMORoomTreatmentFIRCompiler().compile(plan: plan)
        XCTAssertTrue(program.simulationOnly)
        XCTAssertEqual(program.tapCount, 4_096)
        XCTAssertEqual(program.declaredLatencyFrames, 2_048)
        XCTAssertEqual(
            program.engineLatencyFrames,
            Int(N60_MIMO_FIR_PARTITION_FRAMES)
        )
        XCTAssertEqual(program.totalLatencyFrames, 2_304)

        for output in sources.indices {
            for input in sources.indices {
                var maximumMagnitude: Float = 0
                var maximumIndex = 0
                for tap in 0..<program.tapCount {
                    let value = try XCTUnwrap(program.tap(
                        outputSourceIndex: output,
                        inputTargetIndex: input,
                        tapIndex: tap
                    ))
                    if abs(value) > maximumMagnitude {
                        maximumMagnitude = abs(value)
                        maximumIndex = tap
                    }
                }
                if output == input {
                    XCTAssertEqual(maximumIndex, program.declaredLatencyFrames)
                    XCTAssertEqual(maximumMagnitude, 1, accuracy: 0.000_1)
                } else {
                    XCTAssertLessThan(maximumMagnitude, 0.000_1)
                }
            }
        }

        XCTAssertLessThanOrEqual(
            program.diagnostics.maximumCoefficientOvershootDB,
            0.01
        )
        XCTAssertLessThanOrEqual(
            program.diagnostics.maximumColumnPowerOvershootDB,
            0.01
        )
        XCTAssertLessThanOrEqual(
            program.diagnostics.maximumPerSourcePowerOvershootDB,
            0.01
        )
    }

    func testBoundedCrossCoupledPlanCompilesAndRunsThroughStandaloneRuntime() throws {
        let plan = makePlan { frequencyIndex, source, target in
            let frequency = [20.0, 40.0, 63.0, 100.0, 150.0][frequencyIndex]
            if source == target {
                let magnitude = frequency == 63 ? 0.88 : 0.93
                return MIMORoomTreatmentComplexCoefficient(
                    real: magnitude,
                    imaginary: 0
                )
            }
            let sign = source < target ? 1.0 : -1.0
            return MIMORoomTreatmentComplexCoefficient(
                real: 0.12,
                imaginary: sign * 0.05
            )
        }

        let compiled = try MIMORoomTreatmentFIRCompiler().compile(plan: plan)
        XCTAssertEqual(compiled.sources, sources)
        XCTAssertEqual(compiled.taps.count, 2 * 2 * 4_096)
        XCTAssertLessThanOrEqual(
            compiled.diagnostics.maximumCoefficientOvershootDB,
            0.35
        )
        XCTAssertLessThanOrEqual(
            compiled.diagnostics.maximumColumnPowerOvershootDB,
            0.35
        )
        XCTAssertLessThanOrEqual(
            compiled.diagnostics.maximumPerSourcePowerOvershootDB,
            0.35
        )

        var taps = compiled.taps
        guard let cProgram = taps.withUnsafeBufferPointer({ buffer in
            N60MIMOFIRProgramCreate(
                UInt32(sources.count),
                buffer.baseAddress!,
                UInt32(compiled.tapCount),
                UInt32(compiled.declaredLatencyFrames)
            )
        }) else {
            return XCTFail("Could not prepare standalone MIMO FIR program")
        }
        defer { N60MIMOFIRProgramDestroy(cProgram) }

        let info = N60MIMOFIRProgramGetInfo(cProgram)
        XCTAssertTrue(info.prepared)
        XCTAssertEqual(info.channelCount, 2)
        XCTAssertEqual(info.tapCount, 4_096)
        XCTAssertEqual(info.partitionCount, 16)
        XCTAssertEqual(info.engineLatencyFrames, 256)
        XCTAssertEqual(info.declaredLatencyFrames, 2_048)
        XCTAssertGreaterThan(info.kernelBytes, 0)
        XCTAssertGreaterThan(info.runtimeHistoryBytes, 0)

        guard let runtime = N60MIMOFIRRuntimeCreate(cProgram) else {
            return XCTFail("Could not prepare standalone MIMO FIR runtime")
        }
        defer { N60MIMOFIRRuntimeDestroy(runtime) }

        var input = [Float](repeating: 0, count: 2)
        var output = [Float](repeating: 0, count: 2)
        var observedFiniteEnergy = false
        let frames = compiled.totalLatencyFrames + compiled.tapCount + 512
        for frame in 0..<frames {
            input[0] = frame == 0 ? 0.5 : 0
            input[1] = 0
            let ok = input.withUnsafeBufferPointer { inputBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    N60MIMOFIRRuntimeProcessFrame(
                        runtime,
                        inputBuffer.baseAddress!,
                        outputBuffer.baseAddress!
                    )
                }
            }
            XCTAssertTrue(ok)
            XCTAssertTrue(output.allSatisfy(\.isFinite))
            if output.contains(where: { abs($0) > 1.0e-6 }) {
                observedFiniteEnergy = true
            }
        }
        XCTAssertTrue(observedFiniteEnergy)
    }

    func testCompilerRejectsMoreThanFourTreatmentActuators() throws {
        let fiveSources: [MultichannelCalibrationSource] = [
            .subwoofer(0),
            .subwoofer(1),
            .subwoofer(2),
            .subwoofer(3),
            .speaker(.frontLeft),
        ]
        let frequencies = [20.0, 40.0, 63.0, 100.0, 150.0]
        let results = frequencies.map { frequency in
            result(frequency: frequency)
        }
        var coefficients: [MIMORoomTreatmentComplexCoefficient] = []
        for _ in frequencies {
            for source in fiveSources.indices {
                for target in fiveSources.indices {
                    coefficients.append(
                        MIMORoomTreatmentComplexCoefficient(
                            real: source == target ? 1 : 0,
                            imaginary: 0
                        )
                    )
                }
            }
        }
        let plan = MIMORoomTreatmentPlan(
            sampleRate: sampleRate,
            sources: fiveSources,
            seatIDs: [],
            frequenciesHz: frequencies,
            frequencyResults: results,
            coefficients: coefficients,
            acceptedFrequencyCount: 0
        )

        XCTAssertThrowsError(
            try MIMORoomTreatmentFIRCompiler().compile(plan: plan)
        ) { error in
            XCTAssertEqual(
                error as? MIMORoomTreatmentFIRCompileError,
                .sourceCountUnsupported(5)
            )
        }
    }

    func testRealizedUnsafePlanIsRejectedEvenIfInputClaimsAcceptance() throws {
        let plan = makePlan { _, source, target in
            MIMORoomTreatmentComplexCoefficient(
                real: source == target ? 1.6 : 0.8,
                imaginary: 0
            )
        }
        XCTAssertThrowsError(
            try MIMORoomTreatmentFIRCompiler().compile(plan: plan)
        ) { error in
            guard case MIMORoomTreatmentFIRCompileError.denseSafetyViolation =
                error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testInvalidNonPowerOfTwoTapCountFailsClosed() throws {
        var configuration =
            MIMORoomTreatmentFIRCompileConfiguration.conservative
        configuration.tapCount = 3_000
        XCTAssertThrowsError(
            try MIMORoomTreatmentFIRCompiler().compile(
                plan: makePlan { _, source, target in
                    MIMORoomTreatmentComplexCoefficient(
                        real: source == target ? 1 : 0,
                        imaginary: 0
                    )
                },
                configuration: configuration
            )
        ) { error in
            XCTAssertEqual(
                error as? MIMORoomTreatmentFIRCompileError,
                .invalidTapCount(3_000)
            )
        }
    }

    private func makePlan(
        coefficient: (
            _ frequencyIndex: Int,
            _ sourceIndex: Int,
            _ targetIndex: Int
        ) -> MIMORoomTreatmentComplexCoefficient
    ) -> MIMORoomTreatmentPlan {
        let frequencies = [20.0, 40.0, 63.0, 100.0, 150.0]
        let results = frequencies.map { result(frequency: $0) }
        var coefficients: [MIMORoomTreatmentComplexCoefficient] = []
        for frequencyIndex in frequencies.indices {
            for source in sources.indices {
                for target in sources.indices {
                    coefficients.append(
                        coefficient(frequencyIndex, source, target)
                    )
                }
            }
        }
        return MIMORoomTreatmentPlan(
            sampleRate: sampleRate,
            sources: sources,
            seatIDs: [],
            frequenciesHz: frequencies,
            frequencyResults: results,
            coefficients: coefficients,
            acceptedFrequencyCount: frequencies.count
        )
    }

    private func result(
        frequency: Double
    ) -> MIMORoomTreatmentFrequencyResult {
        MIMORoomTreatmentFrequencyResult(
            frequencyHz: frequency,
            accepted: true,
            targetMagnitudeMean: 1,
            untreatedResidualPower: 1,
            candidateResidualPower: 0.5,
            candidateImprovementDB: 3,
            worstCaseRelativeDegradationDB: 0,
            maximumCoefficientMagnitude: 1,
            maximumColumnPower: 1,
            maximumPerSourcePower: 1,
            minimumAppliedSafetyScale: 1
        )
    }
}
