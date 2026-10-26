import Foundation
import XCTest
@testable import NotchSixty

/// E12 S5: the Bass and Correction steps on the real E10 designers. Bass runs on a synthetic room
/// with modal rings at every standard rate; correction is compared with a design made through
/// Room Correction's own controller from the same measurements.
@MainActor
final class SystemSetupBassCorrectTests: XCTestCase {
    private static let standardSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000
    ]

    private struct EmptyCatalog: OutputDeviceCataloging {
        func outputDevices() throws -> [AudioOutputDevice] { [] }
    }

    private let seats = (1...4).map { MultichannelCalibrationSeat(name: "Seat \($0)") }
    private let sources: [MultichannelCalibrationSource] = [
        .speaker(.frontLeft), .speaker(.frontRight), .subwoofer(0), .subwoofer(1),
    ]

    /// 2 mains and 2 subs at 4 seats: delayed direct sounds plus separable modal rings.
    private func bassRoom(rate: Double) -> [[RoomCorrectionCore.SeatImpulseResponse]] {
        let frames = Int(rate * 0.5)
        let modes: [Double] = [31, 44, 58, 73, 96, 112]
        let sourceDelay: [Double] = [0, 0.0004, 0.0031, 0.0046]
        let tau = 0.12 / log(1000.0)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / 4_503_599_627_370_496.0 - 1.0
        }
        let seatGain = (0..<4).map { _ in modes.map { _ in next() } }
        let sourceGain = (0..<4).map { _ in modes.map { _ in 0.35 + 0.65 * next() } }
        return (0..<4).map { source in
            (0..<4).map { seat in
                var ir = [Float](repeating: 0, count: frames)
                let arrival = (sourceDelay[source] + 0.0035 * Double(seat) / 10 + 0.004) * rate
                ir[Int(arrival.rounded())] = 0.1
                for (index, mode) in modes.enumerated() {
                    let amplitude = 0.012 * (48_000 / rate) * seatGain[seat][index] * sourceGain[source][index]
                    var i = Int(arrival) + 1
                    while i < frames {
                        let t = (Double(i) - arrival) / rate
                        if t > 6 * tau { break }
                        ir[i] += Float(amplitude * exp(-t / tau) * sin(2 * .pi * mode * t))
                        i += 1
                    }
                }
                return .init(samples: ir, arrivalFrames: arrival, weight: 1)
            }
        }
    }

    private func quality(arrivalSeconds: Double) -> RoomCorrectionMeasurementQuality {
        RoomCorrectionMeasurementQuality(
            clipped: false, playbackPeakDBFS: -18, capturePeakDBFS: -12, estimatedNoiseFloorDBFS: -80,
            estimatedSNRDB: 60, sweepComplete: true, directArrivalSeconds: arrivalSeconds,
            usableLowHz: 15, usableHighHz: 20_000, warnings: [])
    }

    private func bassMeasurements(rate: Double) -> [MultichannelCalibrationMeasurement] {
        let room = bassRoom(rate: rate)
        var result: [MultichannelCalibrationMeasurement] = []
        for (channel, source) in sources.enumerated() {
            for (seatIndex, seat) in seats.enumerated() {
                let response = room[channel][seatIndex]
                result.append(MultichannelCalibrationMeasurement(
                    seatID: seat.id, source: source, sampleRate: rate,
                    channel: RoomCorrectionChannelMeasurement(
                        capturedAt: Date(timeIntervalSince1970: 1_760_000_000), rawCapture: [],
                        impulseResponse: response.samples, transferFunction: nil,
                        quality: quality(arrivalSeconds: response.arrivalFrames / rate))))
            }
        }
        return result
    }

    private func design(rate: Double, allowed: Bool = true) throws -> SystemSetupBassDesign {
        try SystemSetupBassDesign.make(
            sources: sources, seats: seats, measurements: bassMeasurements(rate: rate), sampleRate: rate,
            crossoverHz: 80, jointBassAllowed: allowed)
    }

    private func profile() -> OutputDeviceProfileConfiguration {
        func endpoint(_ channel: UInt32) -> PhysicalOutputEndpoint { .init(deviceUID: "dac", channelIndex: channel) }
        var speakerFL = SemanticSpeakerOutputAssignment(role: .frontLeft, destination: endpoint(0))
        speakerFL.calibration = SemanticSpeakerCalibration(trimDB: -2, delayMilliseconds: 1.5)
        return OutputDeviceProfileConfiguration(
            enabled: true, programLayout: .stereo,
            speakerAssignments: [speakerFL, SemanticSpeakerOutputAssignment(role: .frontRight, destination: endpoint(1))],
            subwooferAssignments: [
                PhysicalSubwooferOutputAssignment(index: 0, destination: endpoint(2)),
                PhysicalSubwooferOutputAssignment(index: 1, destination: endpoint(3)),
            ])
    }

    // MARK: Bass

    func testJointBassLowersPredictedSeatVarianceAtEveryStandardRate() throws {
        for rate in Self.standardSampleRates {
            let result = try design(rate: rate)
            XCTAssertEqual(result.mode, .jointOptimised, "\(rate) Hz")
            let before = try XCTUnwrap(result.seatSpreadBeforeDB)
            let after = try XCTUnwrap(result.seatSpreadAfterDB)
            XCTAssertLessThan(after, before, "\(rate) Hz: \(before) dB before, \(after) dB after")
            XCTAssertEqual(result.seatMeanBeforeDB.count, seats.count)
            XCTAssertEqual(result.seatMeanAfterDB.count, seats.count)
            XCTAssertEqual(result.rows.map(\.source), sources)
        }
    }

    func testBassFallsBackToSubAlignmentWhenJointBassIsNotAllowed() throws {
        let result = try design(rate: 48_000, allowed: false)
        XCTAssertEqual(result.mode, .subAlignmentOnly)
        XCTAssertNil(result.report)
        XCTAssertTrue(result.rows.isEmpty)
        let base = profile()
        XCTAssertEqual(try result.applying(to: base), base)
    }

    func testBassWithoutSubwooferNeedsNoDesign() throws {
        let result = try SystemSetupBassDesign.make(
            sources: [.speaker(.frontLeft), .speaker(.frontRight)], seats: seats,
            measurements: bassMeasurements(rate: 48_000), sampleRate: 48_000, crossoverHz: 80,
            jointBassAllowed: true)
        XCTAssertEqual(result.mode, .subAlignmentOnly)
    }

    func testBassApplyChangesOnlySubwooferGainDelayAndPolarity() throws {
        let result = try design(rate: 48_000)
        let base = profile()
        let applied = try result.applying(to: base)
        XCTAssertEqual(applied.speakerAssignments, base.speakerAssignments)
        for row in result.rows {
            guard case .subwoofer(let index) = row.source else { continue }
            let calibration = try XCTUnwrap(applied.subwooferAssignments.first { $0.index == index }?.calibration)
            XCTAssertEqual(calibration.polarityInverted, row.polarityInverted)
            XCTAssertEqual(calibration.delayMilliseconds, max(0, row.delayMilliseconds), accuracy: 1e-9)
            XCTAssertTrue(PhysicalSubwooferCalibration.gainRangeDB.contains(calibration.gainDB))
        }
        // Reverting is replacing with the snapshot.
        XCTAssertEqual(base.subwooferAssignments.compactMap(\.calibration).count, 0)
    }

    func testBassNeedsEveryMeasurement() throws {
        var recorded = bassMeasurements(rate: 48_000)
        recorded.removeAll { $0.seatID == seats[1].id && $0.source == .subwoofer(0) }
        XCTAssertThrowsError(try SystemSetupBassDesign.make(
            sources: sources, seats: seats, measurements: recorded, sampleRate: 48_000, crossoverHz: 80,
            jointBassAllowed: true)) { error in
            XCTAssertEqual(error as? SystemSetupBassError,
                           .missingMeasurement(seat: "Seat 2", source: "Sub 1"))
        }
    }

    // MARK: Correction

    func testModesAndKinds() {
        XCTAssertEqual(SystemSetupCorrectionMode.default, .music)
        XCTAssertEqual(SystemSetupCorrectionMode.music.latencyMode, .music50ms)
        XCTAssertEqual(SystemSetupCorrectionMode.video.latencyMode, .video)
        XCTAssertEqual(SystemSetupCorrectionMode.music.designKind(mixedPhaseAllowed: true), .mixedPhase)
        // Mixed phase not allowed (flag off): minimum phase only, whichever mode is chosen.
        XCTAssertEqual(SystemSetupCorrectionMode.music.designKind(mixedPhaseAllowed: false), .minimumPhase)
        XCTAssertEqual(SystemSetupCorrectionMode.video.designKind(mixedPhaseAllowed: true), .minimumPhase)
    }

    func testTargetLibraryDefaultsToAPlainLanguageNaturalCurve() {
        XCTAssertEqual(SystemSetupCorrectionTarget.default.title, "Natural")
        XCTAssertEqual(SystemSetupCorrectionTarget.all.count, RoomCorrectionBuiltInTarget.allCases.count)
        XCTAssertEqual(Set(SystemSetupCorrectionTarget.all.map(\.title)).count, SystemSetupCorrectionTarget.all.count)
        XCTAssertTrue(SystemSetupCorrectionTarget.all.allSatisfy { !$0.detail.isEmpty })
    }

    private func rippledMeasurements(
        rate: Double, seatList: [MultichannelCalibrationSeat]
    ) -> [MultichannelCalibrationMeasurement] {
        let frequencies = (0..<320).map { 10 * pow(2_200.0, Double($0) / 319) }
        var result: [MultichannelCalibrationMeasurement] = []
        for (seatIndex, seat) in seatList.enumerated() {
            for role in [OutputProgramRole.frontLeft, .frontRight] {
                let phase = Double(seatIndex) * 0.7 + (role == .frontRight ? 0.4 : 0)
                result.append(MultichannelCalibrationMeasurement(
                    seatID: seat.id, source: .speaker(role), sampleRate: rate,
                    channel: RoomCorrectionChannelMeasurement(
                        capturedAt: Date(timeIntervalSince1970: 1_760_000_000 + Double(seatIndex) * 10
                            + (role == .frontRight ? 1 : 0)),
                        rawCapture: [], impulseResponse: [1, 0, 0, 0],
                        transferFunction: RoomCorrectionFrequencyResponse(
                            frequenciesHz: frequencies,
                            magnitudeDB: frequencies.map { 5 * sin(log($0) * 2.1 + phase) },
                            phaseRadians: frequencies.map { _ in 0 }),
                        quality: quality(arrivalSeconds: 0.005))))
            }
        }
        return result
    }

    private func controller(root: URL, name: String) -> RoomCorrectionProjectController {
        let engine = AudioIOEngine(deviceCatalog: EmptyCatalog())
        let profiles = ProductProfileController(
            engine: engine, storageURL: root.appendingPathComponent("\(name)-profiles.json"))
        return RoomCorrectionProjectController(
            profiles: profiles,
            store: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent(name, isDirectory: true)))
    }

    func testCorrectionDesignEqualsOneMadeInTheRoomCorrectionWorkspace() throws {
        let rate = 96_000.0
        let recorded = rippledMeasurements(rate: rate, seatList: Array(seats.prefix(2)))
        let sweep = RoomCorrectionSweepSettings(
            sampleRate: rate, startFrequencyHz: 20, endFrequencyHz: 20_000, durationSeconds: 5,
            levelDBFS: -18, leadInSeconds: 0.5, tailSeconds: 1, fadeSeconds: 0.02)
        let mic = RoomCorrectionMicrophone(
            stableID: "mic-1", displayName: "Measurement Mic", manufacturer: nil, inputChannelIndex: 0,
            calibration: nil)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-E12S5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The workspace's path: retain each seat's left and right pass, pick the target, design.
        let workspace = controller(root: root, name: "workspace")
        for seat in seats.prefix(2) {
            func channel(_ role: OutputProgramRole) -> RoomCorrectionChannelMeasurement {
                recorded.last { $0.seatID == seat.id && $0.source == .speaker(role) }!.channel
            }
            try workspace.retainMeasurement(
                RoomCorrectionMeasurementAnalysis(sampleRate: rate, left: channel(.frontLeft), right: channel(.frontRight)),
                sweep: sweep, microphone: mic, name: seat.name)
        }
        try workspace.setTarget(SystemSetupCorrectionTarget.default.curve)
        let expected = try workspace.generateDesign(parameters: SystemSetupCorrectionPlan.defaultParameters)

        // The flow's path: one adapter from the same seat records, same target, same parameters.
        let flow = controller(root: root, name: "flow")
        let project = try SystemSetupRoomProjectAdapter.project(
            playbackSystemID: try XCTUnwrap(flow.selectedPlaybackSystemID), name: "Guided Setup",
            seats: Array(seats.prefix(2)), measurements: recorded, sampleRate: rate, sweep: sweep, microphone: mic)
        try flow.adoptProject(project)
        try flow.setTarget(SystemSetupCorrectionTarget.default.curve)
        let actual = try flow.generateDesign(parameters: SystemSetupCorrectionPlan.defaultParameters)

        XCTAssertEqual(actual.filter, expected.filter)
        XCTAssertEqual(actual.predictedLeftResponse, expected.predictedLeftResponse)
        XCTAssertEqual(actual.predictedRightResponse, expected.predictedRightResponse)
        XCTAssertEqual(actual.recommendedHeadroomDB, expected.recommendedHeadroomDB)

        let report = try flow.verification(for: actual)
        let predictions = SystemSetupSeatPrediction.make(from: report)
        XCTAssertEqual(predictions.map(\.name), ["Seat 1", "Seat 2"])
    }

    func testAdoptingAProjectForAnotherSystemIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-E12S5b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let flow = controller(root: root, name: "flow")
        let stranger = RoomCorrectionProject(playbackSystemID: UUID(), name: "Other", createdAt: Date(), modifiedAt: Date())
        XCTAssertThrowsError(try flow.adoptProject(stranger))
    }
}
