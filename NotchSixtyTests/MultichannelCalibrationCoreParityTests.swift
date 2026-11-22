import Foundation
import XCTest
@testable import NotchSixty

/// E21 S7a: the core's multichannel calibration alignment maths against the Swift and legacy C maths it replaces under
/// `e21.core-designers`, for 1 to 8 subs at the eight standard device rates (parity protocol, design note 9d). This is
/// also the recorded behaviour of the designer (E8 found no goldens): the flag-off designer is the reference.
final class MultichannelCalibrationCoreParityTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let seats = [
        MultichannelCalibrationSeat(name: "Centre"),
        MultichannelCalibrationSeat(name: "Left of centre", weight: 0.5),
        MultichannelCalibrationSeat(name: "Right", weight: 0.75),
    ]

    private func profile(subs: Int) -> OutputDeviceProfileConfiguration {
        OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(role: .frontLeft, destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 0)),
                SemanticSpeakerOutputAssignment(role: .frontRight, destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 1)),
            ],
            subwooferAssignments: (0..<subs).map {
                PhysicalSubwooferOutputAssignment(
                    index: UInt32($0), destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: UInt32(2 + $0)))
            })
    }

    private func bump(_ f: Double, _ centre: Double, _ gain: Double, _ octaves: Double) -> Double {
        let d = log2(f / centre) / octaves
        return gain * exp(-0.5 * d * d)
    }

    private func measurements(rate: Double, subs: Int) -> [MultichannelCalibrationMeasurement] {
        let frequencies = (0..<320).map { 10 * pow(2_200.0, Double($0) / 319) }
        let sources: [(MultichannelCalibrationSource, Double)] = [
            (.speaker(.frontLeft), 0.0050), (.speaker(.frontRight), 0.0057),
        ] + (0..<subs).map { (MultichannelCalibrationSource.subwoofer(UInt32($0)), 0.0071 + 0.0004 * Double($0)) }
        var result: [MultichannelCalibrationMeasurement] = []
        for (seatIndex, seat) in seats.enumerated() {
            for (source, arrival) in sources {
                let seatArrival = arrival + Double(seatIndex) * 0.0003
                var impulse = [Float](repeating: 0, count: Int(seatArrival * rate) + 24)
                let at = Int((seatArrival * rate).rounded())
                impulse[at] = source == .speaker(.frontRight) ? -1 : 1
                let shift = 1.0 + 0.07 * Double(seatIndex)
                let magnitude: (Double) -> Double = { f in
                    switch source {
                    case .speaker(let role):
                        return -6 + (role == .frontLeft ? 0 : 2.5) + self.bump(f, 180 * shift, 9, 0.25)
                            + self.bump(f, 2_200 * shift, -7, 0.3)
                    case .subwoofer(let index):
                        return -4 + Double(index) * 0.8 + (f > 120 ? -24 * log2(f / 120) : 0)
                            + self.bump(f, 42 * shift, 12, 0.15) + self.bump(f, 78 * shift, -10, 0.12)
                    }
                }
                result.append(MultichannelCalibrationMeasurement(
                    seatID: seat.id, source: source, sampleRate: rate,
                    channel: RoomCorrectionChannelMeasurement(
                        capturedAt: Date(timeIntervalSince1970: 1_760_000_000), rawCapture: [], impulseResponse: impulse,
                        transferFunction: RoomCorrectionFrequencyResponse(
                            frequenciesHz: frequencies, magnitudeDB: frequencies.map(magnitude),
                            phaseRadians: frequencies.map { -2 * Double.pi * $0 * 0.0002 }),
                        quality: RoomCorrectionMeasurementQuality(
                            clipped: false, playbackPeakDBFS: -18, capturePeakDBFS: -12, estimatedNoiseFloorDBFS: -80,
                            estimatedSNRDB: 60, sweepComplete: true, directArrivalSeconds: seatArrival, usableLowHz: 15,
                            usableHighHz: 20_000, warnings: []))))
            }
        }
        return result
    }

    private func design(rate: Double, subs: Int, core: Bool) throws -> MultichannelCalibrationDesign {
        var designer = MultichannelCalibrationDesigner()
        designer.useCoreMaths = core
        let date = Date(timeIntervalSince1970: 1_760_000_100)
        return try designer.design(
            profile: profile(subs: subs), bassManagementEnabled: true, seats: seats,
            measurements: measurements(rate: rate, subs: subs), sampleRate: rate, measuredAt: date, deployedAt: date)
    }

    func testDesignerPicksUpTheFlagAtConstruction() {
        XCTAssertEqual(MultichannelCalibrationDesigner().useCoreMaths, FeatureFlags.isEnabledProcessWide(.coreDesigners))
    }

    /// Whole designer, flag off against flag on: same delays, polarities, trims, band lists and Sub settings.
    func testDesignerMatchesAcrossOneToEightSubsAtEveryRate() throws {
        for rate in rates {
            for subs in 1...8 {
                let swift = try design(rate: rate, subs: subs, core: false)
                let core = try design(rate: rate, subs: subs, core: true)
                let label = "\(rate) Hz, \(subs) subs"
                XCTAssertEqual(core.speakers.count, swift.speakers.count, label)
                for (a, b) in zip(core.speakers, swift.speakers) {
                    XCTAssertEqual(a.role, b.role, label)
                    XCTAssertEqual(a.calibration.polarityInverted, b.calibration.polarityInverted, label)
                    XCTAssertEqual(a.calibration.delayMilliseconds, b.calibration.delayMilliseconds, accuracy: 1e-6, label)
                    XCTAssertEqual(a.calibration.trimDB, b.calibration.trimDB, accuracy: 1e-6, label)
                    XCTAssertEqual(a.calibration.eqBands, b.calibration.eqBands, label)
                }
                XCTAssertEqual(core.subwoofers.count, subs, label)
                for (a, b) in zip(core.subwoofers, swift.subwoofers) {
                    XCTAssertEqual(a.index, b.index, label)
                    XCTAssertEqual(a.calibration.polarityInverted, b.calibration.polarityInverted, label)
                    XCTAssertEqual(a.calibration.delayMilliseconds, b.calibration.delayMilliseconds, accuracy: 1e-6, label)
                    XCTAssertEqual(a.calibration.gainDB, b.calibration.gainDB, accuracy: 1e-6, label)
                    XCTAssertEqual(a.calibration.eqBands, b.calibration.eqBands, label)
                }
                XCTAssertEqual(core.summary, swift.summary, label)
            }
        }
    }

    /// Recorded behaviour of the designer at 48 kHz: the speaker alignment follows the weighted arrivals, the right
    /// speaker (negative impulse) is inverted, and the Subs stay attenuation-only.
    func testRecordedBehaviourAt48k() throws {
        for core in [false, true] {
            let design = try design(rate: 48_000, subs: 2, core: core)
            let left = try XCTUnwrap(design.speakers.first { $0.role == .frontLeft })
            let right = try XCTUnwrap(design.speakers.first { $0.role == .frontRight })
            XCTAssertFalse(left.calibration.polarityInverted)
            XCTAssertTrue(right.calibration.polarityInverted)
            // Weighted arrivals: left 5.0 ms + 0.3 ms * (0.5 / 2.25 ... ) is nearer than right by 0.7 ms.
            XCTAssertEqual(left.calibration.delayMilliseconds - right.calibration.delayMilliseconds, 0.7, accuracy: 0.05, "core \(core)")
            XCTAssertTrue(design.subwoofers.allSatisfy { $0.calibration.gainDB <= 0 })
        }
    }

    /// The alignment plan against the legacy C one, per source.
    func testAlignmentMatchesLegacyPlanAtEveryRate() throws {
        for rate in rates {
            for subs in [1, 4, 8] {
                let freqs = MultichannelCalibrationCore.grid(minimumHz: 20, maximumHz: min(20_000, rate * 0.48), count: 128)
                var matrix = freqs.withUnsafeBufferPointer {
                    N60MultichannelCalibrationMatrixMake(rate, profile(subs: subs).programLayout.realtimeLayout, UInt32(subs), 3, $0.baseAddress, 128)
                }
                XCTAssertGreaterThan(matrix.sourceCount, 0)
                let zeros = [Float](repeating: 0, count: 128)
                for (seat, weight) in [Float(1), 0.5, 0.75].enumerated() {
                    XCTAssertTrue(N60MultichannelCalibrationSetSeat(&matrix, UInt32(seat), true, weight))
                    for source in 0..<Int(matrix.sourceCount) {
                        XCTAssertTrue(N60MultichannelCalibrationSetResponse(
                            &matrix, UInt32(source), UInt32(seat), UInt32(240 + 7 * source + 11 * seat),
                            source % 2 == 1 ? -1 : 1, Float(-30 + 3 * source - seat), zeros, zeros))
                    }
                }
                var legacy = N60SpeakerAlignmentPlan()
                XCTAssertTrue(N60MultichannelCalibrationMakeSpeakerAlignmentPlan(&matrix, &legacy))
                let kinds = (0..<Int(matrix.sourceCount)).map { source in
                    withUnsafePointer(to: &matrix.sources) { tuple in
                        tuple.withMemoryRebound(to: N60CalibrationSourceDescriptor.self, capacity: Int(N60_CALIBRATION_MAX_SOURCES)) {
                            $0[source].kind == N60CalibrationSourceKindProgramSpeaker
                        }
                    }
                }
                let flat = MultichannelCalibrationDesigner.flatten(&matrix, sources: Array(0..<Int(matrix.sourceCount)))
                let core = try XCTUnwrap(MultichannelCalibrationCore.align(
                    weights: flat.weights, isSpeaker: kinds, arrival: flat.arrival, polarity: flat.polarity, level: flat.level))
                XCTAssertEqual(core.referenceArrivalFrame, legacy.referenceArrivalFrame, "\(rate) Hz")
                XCTAssertEqual(core.commonLevelDB, legacy.commonLevelDB, accuracy: 1e-5, "\(rate) Hz")
                withUnsafePointer(to: &legacy.sources) { tuple in
                    tuple.withMemoryRebound(to: N60SpeakerAlignmentResult.self, capacity: Int(N60_CALIBRATION_MAX_SOURCES)) { sources in
                        for index in 0..<Int(matrix.sourceCount) {
                            let a = core.sources[index], b = sources[index]
                            XCTAssertEqual(a.valid, b.valid, "\(rate) Hz source \(index)")
                            XCTAssertEqual(a.delayFrames, b.delayFrames)
                            XCTAssertEqual(a.polarityInverted, b.polarityInverted)
                            XCTAssertEqual(a.trimDB, b.trimDB, accuracy: 1e-5)
                            XCTAssertEqual(a.weightedArrivalFrame, b.weightedArrivalFrame, accuracy: 1e-3)
                            XCTAssertEqual(a.weightedLevelDB, b.weightedLevelDB, accuracy: 1e-5)
                            XCTAssertEqual(a.seatVarianceDBSquared, b.seatVarianceDBSquared, accuracy: 1e-5)
                        }
                    }
                }
            }
        }
    }

    /// The optimiser against the legacy C `N60MultiSubOptimize` on the same matrix: same discrete choices (delay, gain and
    /// polarity per sub), the same objective within 0.05 dB-squared relative, EQ targets within one EQ step.
    func testSubOptimiserMatchesLegacyAtEveryRateForOneToEightSubs() throws {
        for rate in rates {
            for subs in 1...8 {
                let freqs = MultichannelCalibrationCore.grid(minimumHz: 20, maximumHz: min(200, rate * 0.48), count: 48)
                var matrix = freqs.withUnsafeBufferPointer {
                    N60MultichannelCalibrationMatrixMake(rate, profile(subs: subs).programLayout.realtimeLayout, UInt32(subs), 3, $0.baseAddress, 48)
                }
                XCTAssertGreaterThan(matrix.sourceCount, 0)
                for (seat, weight) in [Float(1), 0.5, 0.75].enumerated() {
                    XCTAssertTrue(N60MultichannelCalibrationSetSeat(&matrix, UInt32(seat), true, weight))
                    for source in 0..<Int(matrix.sourceCount) {
                        let magnitude = freqs.enumerated().map { index, _ -> Float in
                            -4 + 0.7 * Float(source) + 6 * exp(-pow((Float(index) - 14 - 3 * Float(seat)) / 5, 2))
                        }
                        let phase = freqs.indices.map { Float(0.2 * Double(source)) - 0.01 * Float($0) + 0.1 * Float(seat) }
                        XCTAssertTrue(N60MultichannelCalibrationSetResponse(
                            &matrix, UInt32(source), UInt32(seat), UInt32(rate * (0.005 + 0.0006 * Double(source) + 0.0003 * Double(seat))),
                            1, -20, magnitude, phase))
                    }
                }
                XCTAssertTrue(N60MultichannelCalibrationMatrixIsValid(&matrix, UInt32(subs)))
                var settings = N60MultiSubOptimizationSettingsMakeDefault()
                settings.maximumGainDB = 0
                settings.maximumEQDB = 0
                let target = [Float](repeating: -2, count: freqs.count)
                var legacy = N60MultiSubOptimizationResult()
                XCTAssertTrue(target.withUnsafeBufferPointer { N60MultiSubOptimize(&matrix, UInt32(subs), $0.baseAddress!, settings, &legacy) })
                let core = try XCTUnwrap(MultichannelCalibrationCore.optimiseSubs(
                    matrix: &matrix, subCount: subs, targetDB: target, settings: settings))
                let label = "\(rate) Hz, \(subs) subs"
                func values<T>(_ tuple: inout some Any, _ type: T.Type, _ count: Int) -> [T] {
                    withUnsafePointer(to: &tuple) { $0.withMemoryRebound(to: T.self, capacity: count) { Array(UnsafeBufferPointer(start: $0, count: count)) } }
                }
                var lg = legacy.gainDB, cg = core.gainDB, ld = legacy.additionalDelayMs, cd = core.additionalDelayMs
                var lp = legacy.polarityInverted, cp = core.polarityInverted
                XCTAssertEqual(values(&cg, Float.self, subs), values(&lg, Float.self, subs), label)
                XCTAssertEqual(values(&cd, Float.self, subs), values(&ld, Float.self, subs), label)
                XCTAssertEqual(values(&cp, Bool.self, subs), values(&lp, Bool.self, subs), label)
                XCTAssertEqual(core.objective, legacy.objective, accuracy: max(1e-4, 0.0005 * abs(legacy.objective)), label)
                XCTAssertEqual(core.weightedTargetErrorDBSquared, legacy.weightedTargetErrorDBSquared, accuracy: 0.05, label)
                XCTAssertEqual(core.seatVarianceDBSquared, legacy.seatVarianceDBSquared, accuracy: 0.05, label)
                XCTAssertEqual(core.searchStartsRun, legacy.searchStartsRun, label)
                XCTAssertEqual(core.searchBudgetExhausted, legacy.searchBudgetExhausted, label)
                var le = legacy.perSubEQTargetDB, ce = core.perSubEQTargetDB
                let flatLegacy = values(&le, Float.self, Int(N60_CALIBRATION_MAX_SUBWOOFERS * N60_CALIBRATION_MAX_FREQUENCY_BINS))
                let flatCore = values(&ce, Float.self, Int(N60_CALIBRATION_MAX_SUBWOOFERS * N60_CALIBRATION_MAX_FREQUENCY_BINS))
                XCTAssertEqual(flatCore, flatLegacy, label)
            }
        }
    }

    /// The evaluation budget stops the core search the same way it stops the legacy one.
    func testSubOptimiserHonoursTheIterationCap() throws {
        let freqs = MultichannelCalibrationCore.grid(minimumHz: 20, maximumHz: 200, count: 32)
        var matrix = freqs.withUnsafeBufferPointer {
            N60MultichannelCalibrationMatrixMake(96_000, profile(subs: 4).programLayout.realtimeLayout, 4, 2, $0.baseAddress, 32)
        }
        for seat in 0..<2 {
            XCTAssertTrue(N60MultichannelCalibrationSetSeat(&matrix, UInt32(seat), true, 1))
            for source in 0..<Int(matrix.sourceCount) {
                let magnitude = freqs.indices.map { Float(-3 + 4 * sin(0.3 * Double($0) + Double(source))) }
                let phase = freqs.indices.map { -0.05 * Float($0) + 0.3 * Float(source + seat) }
                XCTAssertTrue(N60MultichannelCalibrationSetResponse(&matrix, UInt32(source), UInt32(seat), 480 + UInt32(40 * source), 1, -20, magnitude, phase))
            }
        }
        var settings = N60MultiSubOptimizationSettingsMakeDefault()
        settings.searchStarts = 64
        settings.searchRounds = 64
        settings.searchEvaluationBudget = 2_000
        settings.eqSearchEvaluationBudget = 2_000
        let target = [Float](repeating: 0, count: freqs.count)
        let capped = try XCTUnwrap(MultichannelCalibrationCore.optimiseSubs(matrix: &matrix, subCount: 4, targetDB: target, settings: settings))
        XCTAssertTrue(capped.searchBudgetExhausted)
        XCTAssertLessThan(capped.searchStartsRun, 64)
        XCTAssertTrue(capped.eqSearchBudgetExhausted)
        var legacy = N60MultiSubOptimizationResult()
        XCTAssertTrue(target.withUnsafeBufferPointer { N60MultiSubOptimize(&matrix, 4, $0.baseAddress!, settings, &legacy) })
        XCTAssertEqual(capped.searchStartsRun, legacy.searchStartsRun)
        XCTAssertEqual(capped.searchEvaluations, legacy.searchEvaluations)
    }
}
