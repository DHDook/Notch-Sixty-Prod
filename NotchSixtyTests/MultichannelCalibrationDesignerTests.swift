import Foundation
import XCTest
@testable import NotchSixty

/// The multichannel calibration designer deploys attenuation only: whatever the
/// measured room does, every PEQ cut, speaker trim and Sub gain is at or below
/// 0 dB and inside the Output Device Profile ranges, at every standard rate.
final class MultichannelCalibrationDesignerTests: XCTestCase {
    private static let standardSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000
    ]

    private let seats = [
        MultichannelCalibrationSeat(name: "Centre"),
        MultichannelCalibrationSeat(name: "Left of centre", weight: 0.5),
    ]

    private func stereoWithSubProfile(subs: Int = 1) -> OutputDeviceProfileConfiguration {
        OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 0)
                ),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight,
                    destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 1)
                ),
            ],
            subwooferAssignments: (0..<subs).map {
                PhysicalSubwooferOutputAssignment(
                    index: UInt32($0),
                    destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: UInt32(2 + $0))
                )
            }
        )
    }

    /// Log-frequency Gaussian bump in dB.
    private func bump(_ frequency: Double, centre: Double, gainDB: Double, octaves: Double) -> Double {
        let distance = log2(frequency / centre) / octaves
        return gainDB * exp(-0.5 * distance * distance)
    }

    /// Synthetic room response: speakers have peaks and a dip in the midrange
    /// (with `speakerRollOffHz`, also a steep low-frequency roll-off); the Sub
    /// rolls off above 120 Hz with a strong room mode and a null. Seat 2 shifts
    /// every feature so the seats disagree.
    private func magnitudeDB(
        source: MultichannelCalibrationSource,
        seat: Int,
        frequency f: Double,
        speakerRollOffHz: Double
    ) -> Double {
        let shift = seat == 0 ? 1.0 : 1.12
        switch source {
        case .speaker(let role):
            let side = role == .frontLeft ? 0.0 : 1.5
            let rollOff = f < speakerRollOffHz ? -24 * log2(speakerRollOffHz / f) : 0
            return -6 + rollOff
                + bump(f, centre: 180 * shift, gainDB: 9 + side, octaves: 0.25)
                + bump(f, centre: 2_200 * shift, gainDB: -7, octaves: 0.3)
                + bump(f, centre: 9_000, gainDB: 4, octaves: 0.4)
        case .subwoofer:
            let rollOff = f > 120 ? -24 * log2(f / 120) : 0
            return -4 + rollOff
                + bump(f, centre: 42 * shift, gainDB: 12, octaves: 0.15)
                + bump(f, centre: 78 * shift, gainDB: -10, octaves: 0.12)
        }
    }

    private func measurements(
        sampleRate: Double,
        speakerRollOffHz: Double = 18,
        subs: Int = 1
    ) -> [MultichannelCalibrationMeasurement] {
        let frequencies = (0..<320).map { 10 * pow(2_200.0, Double($0) / 319) } // 10 Hz ... 22 kHz
        let sources: [(MultichannelCalibrationSource, Double)] = [
            (.speaker(.frontLeft), 0.0050),
            (.speaker(.frontRight), 0.0052),
        ] + (0..<subs).map { (MultichannelCalibrationSource.subwoofer(UInt32($0)), 0.0071 + 0.0003 * Double($0)) }
        var result: [MultichannelCalibrationMeasurement] = []
        for (seatIndex, seat) in seats.enumerated() {
            for (source, arrival) in sources {
                let seatArrival = arrival + Double(seatIndex) * 0.0004
                var impulse = [Float](repeating: 0, count: Int(seatArrival * sampleRate) + 8)
                impulse[Int((seatArrival * sampleRate).rounded())] = 1
                result.append(MultichannelCalibrationMeasurement(
                    seatID: seat.id,
                    source: source,
                    sampleRate: sampleRate,
                    channel: RoomCorrectionChannelMeasurement(
                        capturedAt: Date(timeIntervalSince1970: 1_760_000_000),
                        rawCapture: [],
                        impulseResponse: impulse,
                        transferFunction: RoomCorrectionFrequencyResponse(
                            frequenciesHz: frequencies,
                            magnitudeDB: frequencies.map {
                                magnitudeDB(source: source, seat: seatIndex, frequency: $0, speakerRollOffHz: speakerRollOffHz)
                            },
                            phaseRadians: frequencies.map { -2 * Double.pi * $0 * 0.0002 }
                        ),
                        quality: RoomCorrectionMeasurementQuality(
                            clipped: false,
                            playbackPeakDBFS: -18,
                            capturePeakDBFS: -12,
                            estimatedNoiseFloorDBFS: -80,
                            estimatedSNRDB: 60,
                            sweepComplete: true,
                            directArrivalSeconds: seatArrival,
                            usableLowHz: 15,
                            usableHighHz: 20_000,
                            warnings: []
                        )
                    )
                ))
            }
        }
        return result
    }

    private func design(
        sampleRate: Double,
        speakerRollOffHz: Double = 18
    ) throws -> MultichannelCalibrationDesign {
        try MultichannelCalibrationDesigner().design(
            profile: stereoWithSubProfile(),
            bassManagementEnabled: true,
            seats: seats,
            measurements: measurements(sampleRate: sampleRate, speakerRollOffHz: speakerRollOffHz),
            sampleRate: sampleRate
        )
    }

    /// E8 A4: the designer takes 8 subs and returns a valid, attenuation-only calibration for each, at every rate.
    func testEightSubwoofersEachGetACalibrationAtEveryStandardRate() throws {
        for rate in Self.standardSampleRates {
            for count in [5, 8] {
                let profile = stereoWithSubProfile(subs: count)
                let design = try MultichannelCalibrationDesigner().design(
                    profile: profile,
                    bassManagementEnabled: true,
                    seats: seats,
                    measurements: measurements(sampleRate: rate, subs: count),
                    sampleRate: rate
                )
                XCTAssertEqual(design.subwoofers.map(\.index), (0..<count).map { UInt32($0) }, "\(rate) Hz")
                for sub in design.subwoofers {
                    XCTAssertLessThanOrEqual(sub.calibration.gainDB, 0, "\(rate) Hz Sub \(sub.index + 1)")
                    XCTAssertNoThrow(try sub.calibration.validate(sampleRate: rate), "\(rate) Hz")
                }
                XCTAssertEqual(design.summary.subwooferCount, count, "\(rate) Hz")
                XCTAssertNoThrow(try design.summary.validate(), "\(rate) Hz")
                let applied = try design.applying(to: profile)
                XCTAssertNoThrow(try applied.validateStructure(bassManagementEnabled: true), "\(rate) Hz")
            }
        }
    }

    func testDesignDeploysAttenuationOnlyAtEveryStandardRate() throws {
        for rate in Self.standardSampleRates {
            let design = try design(sampleRate: rate)
            XCTAssertEqual(design.speakers.count, 2, "\(rate) Hz")
            XCTAssertEqual(design.subwoofers.count, 1, "\(rate) Hz")

            // The synthetic peaks must actually be corrected, otherwise the
            // attenuation-only assertions below would be vacuous.
            let speakerBands = design.speakers.flatMap(\.calibration.eqBands)
            XCTAssertFalse(speakerBands.isEmpty, "\(rate) Hz: speaker peaks were not corrected")
            XCTAssertTrue(speakerBands.contains { $0.gainDB < -1 }, "\(rate) Hz")

            for speaker in design.speakers {
                let calibration = speaker.calibration
                XCTAssertLessThanOrEqual(calibration.trimDB, 0, "\(rate) Hz \(speaker.role)")
                XCTAssertTrue(SemanticSpeakerCalibration.trimRangeDB.contains(calibration.trimDB))
                XCTAssertNoThrow(try calibration.validate(sampleRate: rate))
                for band in calibration.eqBands {
                    XCTAssertLessThanOrEqual(band.gainDB, 0, "\(rate) Hz \(speaker.role) \(band)")
                    XCTAssertTrue(OutputCalibrationEQBand.gainRangeDB.contains(band.gainDB))
                    XCTAssertTrue(OutputCalibrationEQBand.qRange.contains(band.q))
                    XCTAssertLessThan(band.frequencyHz, rate / 2)
                }
            }
            for sub in design.subwoofers {
                let calibration = sub.calibration
                XCTAssertLessThanOrEqual(calibration.gainDB, 0, "\(rate) Hz Sub \(sub.index + 1)")
                XCTAssertTrue(PhysicalSubwooferCalibration.gainRangeDB.contains(calibration.gainDB))
                XCTAssertNoThrow(try calibration.validate(sampleRate: rate))
                for band in calibration.eqBands {
                    XCTAssertLessThanOrEqual(band.gainDB, 0, "\(rate) Hz Sub \(band)")
                    XCTAssertTrue(OutputCalibrationEQBand.gainRangeDB.contains(band.gainDB))
                }
            }

            // Applying the design keeps the profile structurally valid.
            let applied = try design.applying(to: stereoWithSubProfile())
            XCTAssertNoThrow(try applied.validateStructure(bassManagementEnabled: true), "\(rate) Hz")
        }
    }

    /// The attenuation-only speaker PEQ fitter must skip bins that need boost
    /// (here a speaker roll-off below 45 Hz) instead of stopping there, so the
    /// +9 dB midrange peak is still cut.
    func testAttenuationOnlyFitterStillCutsPeaksWhenDeepDipsExist() throws {
        for rate in Self.standardSampleRates {
            let design = try design(sampleRate: rate, speakerRollOffHz: 45)
            for speaker in design.speakers {
                XCTAssertTrue(speaker.calibration.eqBands.allSatisfy { $0.gainDB <= 0 }, "\(rate) Hz")
            }
            XCTAssertTrue(
                design.speakers.allSatisfy { speaker in
                    speaker.calibration.eqBands.contains { $0.gainDB < -1 && abs(log2($0.frequencyHz / 180)) < 0.5 }
                },
                "\(rate) Hz: the 180 Hz peak was not cut"
            )
        }
    }

    func testSubCorrectionStaysBelowSubwooferMaximumFrequency() throws {
        for rate in [48_000.0, 96_000, 384_000] {
            let design = try design(sampleRate: rate)
            let bands = design.subwoofers.flatMap(\.calibration.eqBands)
            XCTAssertFalse(bands.isEmpty, "\(rate) Hz: the 42 Hz room mode was not corrected")
            for band in bands {
                XCTAssertLessThanOrEqual(
                    band.frequencyHz,
                    MultichannelCalibrationDesigner.subwooferMaximumFrequencyHz,
                    "\(rate) Hz"
                )
            }
        }
    }

    func testInvalidSampleRateOrDisabledProfileThrows() {
        let valid = measurements(sampleRate: 48_000)
        for rate in [0.0, .nan, -48_000, .infinity] {
            XCTAssertThrowsError(try MultichannelCalibrationDesigner().design(
                profile: stereoWithSubProfile(),
                bassManagementEnabled: true,
                seats: seats,
                measurements: valid,
                sampleRate: rate
            ), "\(rate)")
        }

        var disabled = stereoWithSubProfile()
        disabled.enabled = false
        XCTAssertThrowsError(try MultichannelCalibrationDesigner().design(
            profile: disabled,
            bassManagementEnabled: true,
            seats: seats,
            measurements: valid,
            sampleRate: 48_000
        )) { error in
            XCTAssertEqual(error as? OutputDeviceCalibrationError, .profileRequired)
        }
    }

    func testMeasurementsAtAnotherRateAreRejected() {
        XCTAssertThrowsError(try MultichannelCalibrationDesigner().design(
            profile: stereoWithSubProfile(),
            bassManagementEnabled: true,
            seats: seats,
            measurements: measurements(sampleRate: 48_000),
            sampleRate: 96_000
        )) { error in
            XCTAssertEqual(
                error as? OutputDeviceCalibrationError,
                .sampleRateMismatch(expected: 96_000, actual: 48_000)
            )
        }
    }
}
