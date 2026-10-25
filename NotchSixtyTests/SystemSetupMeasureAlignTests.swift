import Foundation
import XCTest
@testable import NotchSixty

/// E12 S4: numeric checks on the real designer and the Room Correction adapter. The synthetic room
/// has known per-speaker levels, arrival times and polarity, so recovery is checked against truth.
@MainActor
final class SystemSetupMeasureAlignTests: XCTestCase {
    private static let standardSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000
    ]

    private let seats = [
        MultichannelCalibrationSeat(name: "Main Seat"),
        MultichannelCalibrationSeat(name: "Seat 2"),
    ]

    private func profile(withSub: Bool = false) -> OutputDeviceProfileConfiguration {
        OutputDeviceProfileConfiguration(
            enabled: true,
            programLayout: .stereo,
            speakerAssignments: [
                SemanticSpeakerOutputAssignment(
                    role: .frontLeft, destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 0)),
                SemanticSpeakerOutputAssignment(
                    role: .frontRight, destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 1)),
            ],
            subwooferAssignments: withSub ? [
                PhysicalSubwooferOutputAssignment(
                    index: 0, destination: PhysicalOutputEndpoint(deviceUID: "dac", channelIndex: 2))
            ] : []
        )
    }

    private struct Truth {
        var levelDB: Double
        var arrivalFrames: Int
        var inverted = false
    }

    /// Flat, linear-phase responses with the given level, arrival and polarity.
    private func measurements(
        sampleRate: Double, truth: [OutputProgramRole: Truth], seatSkewFrames: Int = 0,
        seatList: [MultichannelCalibrationSeat]? = nil
    ) -> [MultichannelCalibrationMeasurement] {
        let frequencies = (0..<320).map { 10 * pow(2_200.0, Double($0) / 319) }
        var result: [MultichannelCalibrationMeasurement] = []
        for (seatIndex, seat) in (seatList ?? seats).enumerated() {
            for (role, item) in truth.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let frames = item.arrivalFrames + seatIndex * seatSkewFrames
                var impulse = [Float](repeating: 0, count: frames + 64)
                impulse[frames] = item.inverted ? -1 : 1
                let arrival = Double(frames) / sampleRate
                result.append(MultichannelCalibrationMeasurement(
                    seatID: seat.id, source: .speaker(role), sampleRate: sampleRate,
                    channel: RoomCorrectionChannelMeasurement(
                        capturedAt: Date(timeIntervalSince1970: 1_760_000_000 + Double(seatIndex) * 10
                            + (role == .frontRight ? 1 : 0)),
                        rawCapture: [], impulseResponse: impulse,
                        transferFunction: RoomCorrectionFrequencyResponse(
                            frequenciesHz: frequencies,
                            magnitudeDB: frequencies.map { _ in item.levelDB },
                            phaseRadians: frequencies.map { -2 * Double.pi * $0 * arrival }),
                        quality: RoomCorrectionMeasurementQuality(
                            clipped: false, playbackPeakDBFS: -18, capturePeakDBFS: -12,
                            estimatedNoiseFloorDBFS: -80, estimatedSNRDB: 60, sweepComplete: true,
                            directArrivalSeconds: arrival, usableLowHz: 15, usableHighHz: 20_000, warnings: []))))
            }
        }
        return result
    }

    private func row(_ alignment: SystemSetupAlignment, _ role: OutputProgramRole) throws -> SystemSetupAlignmentRow {
        try XCTUnwrap(alignment.rows.first { $0.source == .speaker(role) })
    }

    func testAlignmentRecoversLevelsDelaysAndPolarityAtEveryStandardRate() throws {
        for rate in Self.standardSampleRates {
            let leftFrames = Int((0.0050 * rate).rounded())
            let gapFrames = Int((0.0012 * rate).rounded())
            let truth: [OutputProgramRole: Truth] = [
                .frontLeft: Truth(levelDB: -6, arrivalFrames: leftFrames),
                .frontRight: Truth(levelDB: -9.2, arrivalFrames: leftFrames + gapFrames, inverted: true),
            ]
            let recorded = measurements(sampleRate: rate, truth: truth)
            let design = try MultichannelCalibrationDesigner().design(
                profile: profile(), bassManagementEnabled: false, seats: seats,
                measurements: recorded, sampleRate: rate)
            let alignment = SystemSetupAlignment.make(design: design, seats: seats, measurements: recorded)
            let left = try row(alignment, .frontLeft)
            let right = try row(alignment, .frontRight)

            // Level: the louder speaker is trimmed down by the 3.2 dB difference.
            XCTAssertEqual(left.levelDB - right.levelDB, -3.2, accuracy: 0.2, "\(rate) Hz level")
            // Delay: the earlier speaker waits for the later one, within one sample.
            XCTAssertEqual(
                (left.delayMilliseconds - right.delayMilliseconds) * rate / 1_000, Double(gapFrames),
                accuracy: 1.0, "\(rate) Hz delay")
            // Polarity: only the inverted source is flagged.
            XCTAssertFalse(left.polarityInverted, "\(rate) Hz")
            XCTAssertTrue(right.polarityInverted, "\(rate) Hz")
            XCTAssertEqual(alignment.invertedSources, [.speaker(.frontRight)])
            // Distance from the direct arrival at the main seat.
            XCTAssertEqual(
                try XCTUnwrap(left.distanceMetres), Double(leftFrames) / rate * 343, accuracy: 1e-9)
        }
    }

    func testDistanceShowsMetresAndFeet() {
        let row = SystemSetupAlignmentRow(
            source: .speaker(.frontLeft), levelDB: 0, delayMilliseconds: 0, polarityInverted: false,
            distanceMetres: 3.048)
        XCTAssertEqual(try XCTUnwrap(row.distanceFeet), 10, accuracy: 1e-9)
        XCTAssertEqual(row.distanceText, "3.05 m (10.0 ft)")
        var unknown = row
        unknown.distanceMetres = nil
        XCTAssertEqual(unknown.distanceText, "unknown")
    }

    func testTrialApplyChangesOnlyAlignmentAndRevertRestoresTheSnapshot() throws {
        let rate = 48_000.0
        let truth: [OutputProgramRole: Truth] = [
            .frontLeft: Truth(levelDB: -6, arrivalFrames: 240),
            .frontRight: Truth(levelDB: -8, arrivalFrames: 300),
        ]
        let recorded = measurements(sampleRate: rate, truth: truth)
        let design = try MultichannelCalibrationDesigner().design(
            profile: profile(), bassManagementEnabled: false, seats: seats,
            measurements: recorded, sampleRate: rate)
        let alignment = SystemSetupAlignment.make(design: design, seats: seats, measurements: recorded)

        var snapshot = profile()
        snapshot.speakerAssignments[0].calibration = SemanticSpeakerCalibration(eqBands: [OutputCalibrationEQBand(frequencyHz: 200, gainDB: -2, q: 2)])
        let trial = try alignment.applying(to: snapshot)
        XCTAssertNotEqual(trial, snapshot)
        XCTAssertEqual(trial.speakerAssignments[0].calibration?.eqBands, snapshot.speakerAssignments[0].calibration?.eqBands)
        XCTAssertEqual(trial.calibrationSummary, snapshot.calibrationSummary)
        XCTAssertEqual(trial.speakerAssignments[1].calibration?.eqBands, [])

        // The flow's snapshot is the original; restoring it is exact.
        var state = PlaybackSystemState()
        state.outputDeviceProfile = snapshot
        var flow = SystemSetupFlow()
        try flow.start(snapshot: state)
        XCTAssertEqual(try flow.cancel(), state)
    }

    func testMeasureProgressTracksSeatsAndSourcesInOrder() throws {
        let rate = 48_000.0
        let truth: [OutputProgramRole: Truth] = [
            .frontLeft: Truth(levelDB: -6, arrivalFrames: 240),
            .frontRight: Truth(levelDB: -6, arrivalFrames: 240),
        ]
        let all = measurements(sampleRate: rate, truth: truth)
        let sources: [MultichannelCalibrationSource] = [.speaker(.frontLeft), .speaker(.frontRight)]

        var progress = SystemSetupMeasureProgress(seats: seats, sources: sources, measurements: [])
        XCTAssertEqual(progress.totalCount, 4)
        XCTAssertEqual(progress.fraction, 0)
        XCTAssertEqual(progress.next?.seat.id, seats[0].id)
        XCTAssertEqual(progress.next?.source, .speaker(.frontLeft))

        // Main seat done, second seat has only its left speaker.
        progress.measurements = all.filter {
            $0.seatID == seats[0].id || $0.source == .speaker(.frontLeft)
        }
        XCTAssertEqual(progress.completedCount, 3)
        XCTAssertTrue(progress.isComplete(seats[0]))
        XCTAssertFalse(progress.isComplete(seats[1]))
        XCTAssertEqual(progress.next?.seat.id, seats[1].id)
        XCTAssertEqual(progress.next?.source, .speaker(.frontRight))

        // The flow refuses to leave Measure until every seat is whole.
        var choices = SystemSetupChoices()
        progress.apply(to: &choices)
        XCTAssertEqual(choices.seatNames, ["Main Seat", "Seat 2"])
        XCTAssertEqual(choices.measurementIDs.count, 1)

        progress.measurements = all
        progress.apply(to: &choices)
        XCTAssertTrue(progress.isComplete)
        XCTAssertEqual(choices.measurementIDs.count, 2)

        // Excluded seats are not measured and do not block completion.
        var excluded = progress
        excluded.seats[1].included = false
        excluded.apply(to: &choices)
        XCTAssertEqual(choices.seatNames, ["Main Seat"])
        XCTAssertEqual(choices.measurementIDs.count, 1)
    }

    // MARK: Adapter against Room Correction's own path

    private struct EmptyCatalog: OutputDeviceCataloging {
        func outputDevices() throws -> [AudioOutputDevice] { [] }
    }

    func testAdapterMatchesProjectBuiltThroughRoomCorrectionsOwnPath() throws {
        let rate = 96_000.0
        let truth: [OutputProgramRole: Truth] = [
            .frontLeft: Truth(levelDB: -6, arrivalFrames: 480),
            .frontRight: Truth(levelDB: -7.5, arrivalFrames: 500),
        ]
        let recorded = measurements(sampleRate: rate, truth: truth, seatSkewFrames: 20)
        let sweep = RoomCorrectionSweepSettings(
            sampleRate: rate, startFrequencyHz: 20, endFrequencyHz: 20_000, durationSeconds: 5,
            levelDBFS: -18, leadInSeconds: 0.5, tailSeconds: 1, fadeSeconds: 0.02)
        let mic = RoomCorrectionMicrophone(
            stableID: "mic-1", displayName: "Measurement Mic", manufacturer: nil, inputChannelIndex: 0,
            calibration: nil)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchSixty-E12S4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine(deviceCatalog: EmptyCatalog())
        let profiles = ProductProfileController(
            engine: engine, storageURL: root.appendingPathComponent("profiles-v1.json"))
        let controller = RoomCorrectionProjectController(
            profiles: profiles,
            store: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("RC", isDirectory: true)))
        for seat in seats {
            func channel(_ role: OutputProgramRole) -> RoomCorrectionChannelMeasurement {
                recorded.last { $0.seatID == seat.id && $0.source == .speaker(role) }!.channel
            }
            try controller.retainMeasurement(
                RoomCorrectionMeasurementAnalysis(sampleRate: rate, left: channel(.frontLeft), right: channel(.frontRight)),
                sweep: sweep, microphone: mic, name: seat.name)
        }
        let reference = try XCTUnwrap(controller.project)

        let adapted = try SystemSetupRoomProjectAdapter.project(
            playbackSystemID: reference.playbackSystemID, name: reference.name, seats: seats,
            measurements: recorded, sampleRate: rate, sweep: sweep, microphone: mic)

        XCTAssertEqual(adapted.measurements.count, reference.measurements.count)
        for (a, r) in zip(adapted.measurements, reference.measurements) {
            XCTAssertEqual(a.name, r.name)
            XCTAssertEqual(a.included, r.included)
            XCTAssertEqual(a.weight, r.weight)
            XCTAssertEqual(a.sampleRate, r.sampleRate)
            XCTAssertEqual(a.left, r.left)
            XCTAssertEqual(a.right, r.right)
        }
        XCTAssertEqual(adapted.sweep, reference.sweep)
        XCTAssertEqual(adapted.microphone, reference.microphone)
        XCTAssertEqual(adapted.aggregate?.leftResponse, reference.aggregate?.leftResponse)
        XCTAssertEqual(adapted.aggregate?.rightResponse, reference.aggregate?.rightResponse)
        XCTAssertNotNil(adapted.aggregate)
        try adapted.validateForPersistence()
    }

    func testAdapterNeedsBothFrontSpeakersAndMatchingRate() throws {
        let truth: [OutputProgramRole: Truth] = [.frontLeft: Truth(levelDB: -6, arrivalFrames: 240)]
        let recorded = measurements(sampleRate: 48_000, truth: truth)
        XCTAssertThrowsError(try SystemSetupRoomProjectAdapter.project(
            playbackSystemID: UUID(), name: "x", seats: seats, measurements: recorded,
            sampleRate: 48_000, sweep: nil, microphone: nil)) {
            XCTAssertEqual($0 as? SystemSetupRoomProjectAdapter.AdapterError, .noSeatHasBothFrontSpeakers)
        }
        let both: [OutputProgramRole: Truth] = [
            .frontLeft: Truth(levelDB: -6, arrivalFrames: 240), .frontRight: Truth(levelDB: -6, arrivalFrames: 240),
        ]
        XCTAssertThrowsError(try SystemSetupRoomProjectAdapter.project(
            playbackSystemID: UUID(), name: "x", seats: seats,
            measurements: measurements(sampleRate: 48_000, truth: both),
            sampleRate: 96_000, sweep: nil, microphone: nil)) {
            XCTAssertEqual($0 as? SystemSetupRoomProjectAdapter.AdapterError, .sampleRateMismatch(seat: "Main Seat"))
        }
    }

    // MARK: Level noise

    func testNoiseSettingsStartAtMinus40AndNeverPassTheCeiling() throws {
        var plan = SystemSetupLevelPlan()
        var settings = try plan.validatedGeneratorSettings()
        XCTAssertEqual(settings.kind, .bandLimitedPink)
        XCTAssertEqual(settings.levelDB, -40)
        for _ in 0..<40 {
            plan.raise()
            settings = try plan.validatedGeneratorSettings()
            XCTAssertLessThanOrEqual(settings.effectiveLevelDB, SignalGeneratorSettings.hardCeilingDB)
        }
        for rate in Self.standardSampleRates {
            let atRate = try plan.validatedGeneratorSettings(sampleRate: rate)
            XCTAssertNotNil(atRate.stageParams(active: true, sampleRate: rate), "\(rate) Hz")
        }
    }

    func testUnconnectedPlayerSaysWhyAndNeverPlays() throws {
        let player = UnconnectedSystemSetupNoisePlayer()
        XCTAssertThrowsError(try player.start(SystemSetupLevelPlan().generatorSettings())) {
            XCTAssertEqual($0 as? SystemSetupNoiseError, .engineHookUnavailable)
        }
        XCTAssertFalse(player.isPlaying)
    }
}
