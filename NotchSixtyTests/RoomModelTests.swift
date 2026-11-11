import XCTest
@testable import NotchSixty

/// E29 S1: the read-only room model index. Every existing record appears exactly once, the staleness rule flips on
/// each stamp, timing tier none is magnitude-only, and the maths is rate-free at all eight standard rates.
final class RoomModelTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func channel(_ ir: [Float] = [1, 0.5, 0.25]) -> RoomCorrectionChannelMeasurement {
        var q = RoomCorrectionMeasurementQuality()
        q.sweepComplete = true
        return RoomCorrectionChannelMeasurement(
            capturedAt: date, rawCapture: [], impulseResponse: ir, transferFunction: nil, quality: q)
    }

    private func position(_ name: String, rate: Double, fp: String? = nil, gain: Double? = nil)
        -> RoomCorrectionMeasurementPosition
    {
        RoomCorrectionMeasurementPosition(
            name: name, sampleRate: rate, left: channel(), right: channel(),
            ancBassFingerprint: fp.map(AncBassPathFingerprint.init(value:)), outputGainDBAtMeasurement: gain)
    }

    private func record(_ name: String, channel: String, seat: String?, rate: Double, tier: String?) -> MeasurementRecord {
        var r = MeasurementRecord(name: name, createdAt: date, sampleRate: rate)
        r.channel = channel
        r.seat = seat
        r.timingTier = tier
        r.calibrationName = "UMIK-1"
        r.quality.sweepComplete = true
        return r
    }

    private func combined(_ s: CombinedAncPathRecord.Source, _ d: CombinedAncPathRecord.Destination, rate: Double)
        -> CombinedAncPathRecord
    {
        CombinedAncPathRecord(
            source: s, destination: d, windowSeconds: 1, sampleRate: rate,
            fingerprint: AncBassPathFingerprint(value: "fp"), impulseResponse: [1, 0, 0])
    }

    func testEveryExistingRecordAppearsExactlyOnce() {
        let p1 = position("Main seat", rate: 48_000), p2 = position("Left seat", rate: 48_000)
        let lib = [
            record("Sub at main", channel: "Sub", seat: "Main seat", rate: 48_000, tier: "loopback"),
            record("Left at left", channel: "Left", seat: "left seat", rate: 96_000, tier: nil),
        ]
        let anc = [combined(.feedLeft, .seatMicrophone, rate: 48_000), combined(.subLane, .referenceMicrophone, rate: 48_000)]
        let model = RoomModelAdapter.build(RoomModelAdapterInput(positions: [p1, p2], library: lib, combinedAncRecords: anc))
        XCTAssertEqual(model.paths.count, 2 * 2 + 2 + 2)
        let origins = model.paths.map(\.origin)
        XCTAssertEqual(Set(origins).count, origins.count)
        for p in [p1, p2] {
            for ch in ["left", "right"] {
                XCTAssertEqual(origins.filter { $0 == .roomCorrectionPosition(id: p.id, channel: ch) }.count, 1)
            }
        }
        for r in lib { XCTAssertEqual(origins.filter { $0 == .measurementRecord(id: r.id) }.count, 1) }
        XCTAssertEqual(Set(model.paths.map(\.id)).count, model.paths.count)
        // "left seat" in the library joins the room-correction seat of the same name: one point, not two.
        XCTAssertEqual(model.points.filter { $0.kind == .seat && $0.name.lowercased() == "left seat" }.count, 1)
        XCTAssertEqual(model.paths(to: p2.id).count, 3)
        XCTAssertEqual(model.point(p1.id)?.name, "Main seat")
    }

    func testIdentifiersAreStableAcrossBuilds() {
        let input = RoomModelAdapterInput(
            positions: [position("A", rate: 48_000)], library: [record("x", channel: "Left", seat: "A", rate: 48_000, tier: nil)],
            combinedAncRecords: [combined(.feedRight, .seatMicrophone, rate: 48_000)])
        let a = RoomModelAdapter.build(input), b = RoomModelAdapter.build(input)
        XCTAssertEqual(a, b)
    }

    func testSourceAndReceiverQueries() throws {
        let p = position("Seat", rate: 48_000)
        let model = RoomModelAdapter.build(RoomModelAdapterInput(
            positions: [p], library: [record("s", channel: "Subwoofer", seat: "Seat", rate: 48_000, tier: "reference")]))
        let sub = try XCTUnwrap(model.points.first { $0.kind == .subLane })
        let left = try XCTUnwrap(model.points.first { $0.name == RoomModelAdapter.leftFeedName })
        XCTAssertEqual(model.paths(from: sub.id).count, 1)
        XCTAssertEqual(model.paths(from: left.id, to: p.id).count, 1)
        XCTAssertEqual(model.paths(from: sub.id, to: left.id).count, 0)
    }

    func testStalenessFlipsOnEachStamp() {
        let stamps = RoomPathStamps(
            bassFingerprint: .init(value: "a"), arrangementRevision: "r1", outputDeviceUID: "dev1",
            outputGainDB: -10, calibrationName: "UMIK-1")
        let path = RoomPath(
            id: UUID(), source: UUID(), receiver: UUID(), origin: .measurementRecord(id: UUID()), sampleRate: 48_000,
            timingTier: .loopback, sessionID: "s", stamps: stamps, hasImpulseResponse: true, qualityOK: true)
        let same = RoomModelContext(
            bassFingerprint: .init(value: "a"), bassPathActive: true, arrangementRevision: "r1", outputDeviceUID: "dev1",
            outputGainDB: -10.3, calibrationName: "UMIK-1")
        XCTAssertEqual(RoomModelRule.state(of: path, in: same), .measured)
        var c = same; c.bassFingerprint = .init(value: "b")
        XCTAssertEqual(RoomModelRule.staleReasons(of: path, in: c), [.bassPath])
        c = same; c.arrangementRevision = "r2"
        XCTAssertEqual(RoomModelRule.staleReasons(of: path, in: c), [.arrangement])
        c = same; c.outputDeviceUID = "dev2"
        XCTAssertEqual(RoomModelRule.staleReasons(of: path, in: c), [.outputDevice])
        c = same; c.outputGainDB = -6
        XCTAssertEqual(RoomModelRule.staleReasons(of: path, in: c), [.outputGain])
        c = same; c.calibrationName = "Other"
        XCTAssertEqual(RoomModelRule.staleReasons(of: path, in: c), [.calibration])
        c = RoomModelContext(bassFingerprint: .init(value: "x"), arrangementRevision: "r9", outputDeviceUID: "d", outputGainDB: 0, calibrationName: "z")
        XCTAssertEqual(Set(RoomModelRule.staleReasons(of: path, in: c)), Set(RoomPathStaleReason.allCases))
        XCTAssertEqual(RoomModelRule.staleMessage, "Your speakers or bass settings changed. Measure this seat again.")
    }

    func testUnstampedPathIsStaleOnlyWhereABassPathIsInPlay() {
        let path = RoomPath(
            id: UUID(), source: UUID(), receiver: UUID(), origin: .measurementRecord(id: UUID()), sampleRate: 48_000,
            timingTier: .none, stamps: RoomPathStamps(), hasImpulseResponse: true, qualityOK: true)
        XCTAssertEqual(RoomModelRule.state(of: path, in: RoomModelContext(bassPathActive: false)), .measured)
        XCTAssertEqual(RoomModelRule.state(of: path, in: RoomModelContext(bassPathActive: true)), .stale([.bassPath]))
        XCTAssertEqual(
            RoomModelRule.state(of: path, in: RoomModelContext(bassFingerprint: .init(value: "a"), bassPathActive: true)),
            .stale([.bassPath]))
    }

    func testAdapterCarriesStampsFromExistingRecords() throws {
        let p = position("Seat", rate: 48_000, fp: "fp1", gain: -12)
        let model = RoomModelAdapter.build(RoomModelAdapterInput(positions: [p]))
        let path = try XCTUnwrap(model.paths.first)
        XCTAssertEqual(path.stamps.bassFingerprint?.value, "fp1")
        XCTAssertEqual(path.stamps.outputGainDB, -12)
        XCTAssertEqual(RoomModelRule.state(of: path, in: RoomModelContext(bassFingerprint: .init(value: "fp2"))), .stale([.bassPath]))
        XCTAssertEqual(RoomModelRule.state(of: path, in: RoomModelContext(bassFingerprint: .init(value: "fp1"), outputGainDB: -12)), .measured)
    }

    func testTimingTierNoneIsMagnitudeOnly() {
        func path(_ tier: RoomTimingTier, rate: Double = 48_000, session: String? = "s") -> RoomPath {
            RoomPath(
                id: UUID(), source: UUID(), receiver: UUID(), origin: .measurementRecord(id: UUID()), sampleRate: rate,
                timingTier: tier, sessionID: session, stamps: RoomPathStamps(), hasImpulseResponse: true, qualityOK: true)
        }
        XCTAssertTrue(path(.loopback).phaseComparable(with: path(.reference)))
        XCTAssertFalse(path(.none).phaseComparable(with: path(.loopback)))
        XCTAssertFalse(path(.loopback).phaseComparable(with: path(.loopback, rate: 96_000)))
        XCTAssertFalse(path(.loopback).phaseComparable(with: path(.loopback, session: "t")))
        XCTAssertFalse(path(.loopback, session: nil).phaseComparable(with: path(.loopback, session: nil)))
        XCTAssertEqual(RoomTimingTier(storedName: "Loopback"), .loopback)
        XCTAssertEqual(RoomTimingTier(storedName: nil), .none)
        XCTAssertEqual(RoomTimingTier(storedName: "garbage"), .none)

        let model = RoomModelAdapter.build(RoomModelAdapterInput(
            library: [record("a", channel: "Left", seat: "S", rate: 48_000, tier: nil),
                      record("b", channel: "Right", seat: "S", rate: 48_000, tier: "loopback")]))
        let report = model.completeness(in: RoomModelContext())
        XCTAssertEqual(report.magnitudeOnlyPathIDs.count, 1)
    }

    func testAllEightRatesAreKeptAndQueryable() {
        for fs in rates {
            let model = RoomModelAdapter.build(RoomModelAdapterInput(
                positions: [position("Seat", rate: fs)],
                combinedAncRecords: [combined(.feedLeft, .seatMicrophone, rate: fs)]))
            XCTAssertTrue(model.paths.allSatisfy { $0.sampleRate == fs }, "rate \(fs)")
            XCTAssertEqual(model.paths.count, 3)
            XCTAssertEqual(model.completeness(in: RoomModelContext()).stalePathIDs.count, 0)
        }
    }

    func testCompletenessReport() throws {
        let p = position("Seat", rate: 48_000)
        var input = RoomModelAdapterInput(positions: [p])
        input.enteredPositions = ["left speaker": RoomPosition(x: 1, y: 0, z: 1, source: .typed, uncertaintyMetres: nil)]
        input.surveyPoints = [try surveyed(x: 2, y: 3, z: 1.1)]
        let model = RoomModelAdapter.build(input)
        let r = model.completeness(in: RoomModelContext())
        let unpositioned = Set(r.unpositionedPointIDs)
        XCTAssertTrue(unpositioned.contains(p.id))
        XCTAssertFalse(unpositioned.contains(try XCTUnwrap(model.points.first { $0.name == RoomModelAdapter.leftFeedName }).id))
        XCTAssertEqual(model.points.filter { $0.kind == .surveyPoint }.count, 1)
        XCTAssertEqual(model.points.first { $0.kind == .surveyPoint }?.position?.z, 1.1)
        XCTAssertEqual(r.seatsWithoutPathIDs, [])

        let lonely = RoomModel(points: [RoomPoint(id: UUID(), kind: .seat, name: "Empty", position: nil)])
        XCTAssertEqual(lonely.completeness(in: RoomModelContext()).seatsWithoutPathIDs.count, 1)
    }

    func testPositionDistanceAndEmptyInput() {
        let a = RoomPosition(x: 0, y: 0, z: 0, source: .typed, uncertaintyMetres: nil)
        let b = RoomPosition(x: 3, y: 4, z: 0, source: .acousticLocate, uncertaintyMetres: 0.02)
        XCTAssertEqual(a.distance(to: b), 5, accuracy: 1e-12)
        XCTAssertEqual(RoomModelAdapter.build(RoomModelAdapterInput()), RoomModel())
    }

    private func surveyed(x: Double, y: Double, z: Double) throws -> QuietZoneSurveyedPosition {
        let tone = QuietZoneVirtualMicTone(
            frequencyHz: 100, ratio: .zero, effectiveSecondary: .zero, earSecondary: .zero)
        return QuietZoneSurveyedPosition(x: x, y: y, z: z, microphone: QuietZoneVirtualMicrophone(tones: [tone]))
    }
}
