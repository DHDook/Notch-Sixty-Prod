import XCTest
@testable import NotchSixty

/// E13 S2: bring-your-own headphone responses, the extended fitter, Equalizer APO import and one-click Undo.
final class HeadphoneResponseFittingTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: helpers

    private func band(_ type: HeadphoneCorrectionFilterType, _ hz: Double, _ gain: Double, _ q: Double) -> HeadphoneCorrectionEQBand {
        HeadphoneCorrectionEQBand(enabled: true, type: type, frequencyHz: hz, gainDB: gain, q: q)
    }

    private func eqDB(_ bands: [HeadphoneCorrectionEQBand], _ hz: Double, rate: Double) -> Double {
        bands.reduce(0.0) { $0 + (HeadphoneAutoFitter.bandMagnitudeDB($1, frequencyHz: hz, sampleRate: rate) ?? 0) }
    }

    /// A record whose both ears are `base + shape(f)` over a dense log grid.
    private func record(_ name: String = "Test", left: (Double) -> Double, right: (Double) -> Double) throws -> HeadphoneResponseRecord {
        let freqs = (0 ... 240).map { 20.0 * pow(2, Double($0) / 24) }.filter { $0 <= 20_000 }
        return HeadphoneResponseRecord(
            name: name, left: HeadphoneResponseCurve(frequenciesHz: freqs, db: freqs.map(left)),
            right: HeadphoneResponseCurve(frequenciesHz: freqs, db: freqs.map(right)))
    }

    private func rmse(_ response: [Double], _ target: [Double], _ bands: [HeadphoneCorrectionEQBand], freqs: [Double],
                      rate: Double, upTo: Double) -> Double {
        let ref = freqs.indices.filter { freqs[$0] >= 250 && freqs[$0] <= 2_500 }
        let offset = ref.reduce(0.0) { $0 + response[$1] - target[$1] } / Double(ref.count)
        var s = 0.0, n = 0.0
        for i in freqs.indices where freqs[i] <= upTo {
            let e = target[i] + offset - response[i] - eqDB(bands, freqs[i], rate: rate)
            s += e * e; n += 1
        }
        return (s / n).squareRoot()
    }

    // MARK: fitter

    func testExactCaseFitsToWithinPointThreeDB() throws {
        let known = [band(.peaking, 120, 4, 1), band(.peaking, 800, -5, 2), band(.peaking, 2_500, 3, 1),
                     band(.peaking, 4_500, -6, 2), band(.peaking, 7_000, 3, 1)]
        let rate = 48_000.0
        let rec = try record(left: { -self.eqDB(known, $0, rate: rate) + 62 }, right: { -self.eqDB(known, $0, rate: rate) + 62 })
        let fit = try HeadphoneAutoFitter.fit(measurement: rec.measurement(target: nil, sampleRate: rate), sampleRate: rate)
        XCTAssertLessThanOrEqual(fit.leftRMSEAfterDB, 0.3, "left \(fit.leftRMSEAfterDB)")
        XCTAssertLessThanOrEqual(fit.rightRMSEAfterDB, 0.3)
    }

    func testSyntheticResponsesReachOneDBWithinTheBoostLimits() throws {
        let shapes: [(String, (Double) -> Double)] = [
            ("v-shaped", { 5 * exp(-pow(log2($0 / 80), 2) / 2) + 4 * exp(-pow(log2($0 / 9_000), 2) / 3) - 3 * exp(-pow(log2($0 / 3_000), 2) / 1) }),
            ("dark", { -6 * log2(max($0, 20) / 1_000) * 0.5 + 2 * exp(-pow(log2($0 / 5_500), 2) / 0.5) }),
            ("bumpy", { 3 * sin(log2($0 / 20) * 2.2) + 2 * exp(-pow(log2($0 / 400), 2) / 1.5) }),
        ]
        let rate = 96_000.0
        for (name, shape) in shapes {
            let rec = try record(name, left: shape, right: shape)
            let m = try rec.measurement(target: nil, sampleRate: rate)
            let fit = try HeadphoneAutoFitter.fit(measurement: m, sampleRate: rate)
            XCTAssertLessThanOrEqual(fit.leftRMSEAfterDB, 1.0, "\(name) L \(fit.leftRMSEAfterDB)")
            for b in fit.proposal.leftBands + fit.proposal.rightBands {
                XCTAssertGreaterThanOrEqual(b.gainDB, -12 - 1e-9)
                XCTAssertLessThanOrEqual(b.gainDB, (b.frequencyHz > 10_000 || b.type == .highShelf ? 3 : 6) + 1e-9, "\(name) \(b)")
            }
            XCTAssertLessThanOrEqual(fit.proposal.leftBands.count, 10)
        }
    }

    func testFitIsDeterministicAndRunsQuickly() throws {
        let shape: (Double) -> Double = { 4 * sin(log2($0 / 20) * 1.7) }
        let rec = try record(left: shape, right: { shape($0) * 0.8 })
        let m = try rec.measurement(target: nil, sampleRate: 48_000)
        let start = Date()
        let a = try HeadphoneAutoFitter.fit(measurement: m, sampleRate: 48_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        let b = try HeadphoneAutoFitter.fit(measurement: m, sampleRate: 48_000)
        XCTAssertEqual(a.proposal.leftBands, b.proposal.leftBands)
        XCTAssertEqual(a.proposal.rightBands, b.proposal.rightBands)
        XCTAssertEqual(a.leftRMSEAfterDB.bitPattern, b.leftRMSEAfterDB.bitPattern)
    }

    func testFitAtEveryRateValidatesAndPredictionMatchesAnIndependentBiquadEvaluation() throws {
        let shape: (Double) -> Double = { 4 * sin(log2($0 / 20) * 1.7) + 2 * exp(-pow(log2($0 / 3_000), 2)) }
        for rate in Self.rates {
            let rec = try record(left: shape, right: shape)
            let m = try rec.measurement(target: nil, sampleRate: rate)
            let fit = try HeadphoneAutoFitter.fit(measurement: m, sampleRate: rate)
            try fit.proposal.validate(sampleRate: rate)
            XCTAssertEqual(m.points.last!.frequencyHz <= min(20_000, rate * 0.45), true)
            XCTAssertLessThan(fit.leftRMSEAfterDB, fit.leftRMSEBeforeDB, "rate \(rate)")
            // The fitter's residual agrees with a fresh evaluation of the proposal on the same grid.
            let freqs = m.points.map(\.frequencyHz)
            let fresh = rmse(m.points.map(\.leftMagnitudeDB), m.points.map(\.targetMagnitudeDB),
                             fit.proposal.leftBands, freqs: freqs, rate: rate, upTo: 10_000)
            XCTAssertEqual(fresh, fit.leftRMSEAfterDB, accuracy: 1e-6, "rate \(rate)")
        }
    }

    func testHeadroomCoversPositiveGainAndIsRoundedUpToHalfADB() throws {
        let shape: (Double) -> Double = { -5 * exp(-pow(log2($0 / 700), 2)) - 4 * exp(-pow(log2($0 / 5_000), 2)) }
        let rec = try record(left: shape, right: shape)
        let rate = 48_000.0
        let fit = try HeadphoneAutoFitter.fit(measurement: rec.measurement(target: nil, sampleRate: rate), sampleRate: rate)
        var profile = HeadphoneDeviceProfileConfiguration()
        let applied = try profile.applyingFit(left: fit.proposal.leftBands, right: fit.proposal.rightBands,
                                              targetID: nil, targetName: nil, sampleRate: rate)
        XCTAssertGreaterThanOrEqual(applied.headroomAttenuationDB + 1e-9, applied.conservativeRequiredHeadroomDB)
        XCTAssertEqual(applied.headroomAttenuationDB * 2, (applied.headroomAttenuationDB * 2).rounded(), accuracy: 1e-12)
        XCTAssertLessThan(applied.headroomAttenuationDB - applied.conservativeRequiredHeadroomDB, 0.5 + 1e-9)
        XCTAssertEqual(fit.recommendedHeadroomDB, applied.headroomAttenuationDB)
        profile = applied
        XCTAssertNoThrow(try profile.validateStructure(sampleRate: rate))
    }

    func testRenderedHeadphoneStageMatchesTheFitterPredictionAtEveryRate() throws {
        let shape: (Double) -> Double = { 3 * sin(log2($0 / 20) * 1.5) }
        let tones = [100.0, 440, 1_000, 3_000, 6_000, 9_000]
        for rate in Self.rates {
            let rec = try record(left: shape, right: shape)
            let fit = try HeadphoneAutoFitter.fit(measurement: rec.measurement(target: nil, sampleRate: rate), sampleRate: rate)
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.spatialMode = .stereo
            profile = try profile.applyingFit(left: fit.proposal.leftBands, right: fit.proposal.rightBands,
                                              targetID: nil, targetName: nil, sampleRate: rate)
            let spec = try UnifiedGraphTranslator.stereoApplyHeadphone(
                spec: UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()]).makeSpec(),
                profile: profile).get().spec
            for hz in tones {
                let host = try UnifiedGraphHost(spec: spec)
                defer { host.release() }
                let block = 512
                let frames = Int(rate * 1.0) / block * block
                var out = [Float]()
                var done = 0
                while done < frames {
                    let tone = (done ..< done + block).map { Float(0.1 * sin(2 * .pi * hz * Double($0) / rate)) }
                    out += try host.processOffline(input: [tone, tone], frames: block)[0]
                    done += block
                }
                // Least-squares amplitude over the settled last quarter.
                // A whole number of cycles keeps the projection exact.
                let cycles = Int(0.3 * hz)
                let from = frames - Int((Double(cycles) * rate / hz).rounded())
                var sc = 0.0, ss = 0.0
                for i in from ..< frames {
                    let w = 2 * Double.pi * hz * Double(i) / rate
                    sc += Double(out[i]) * cos(w); ss += Double(out[i]) * sin(w)
                }
                let amplitude = 2 * (sc * sc + ss * ss).squareRoot() / Double(frames - from)
                XCTAssertGreaterThan(cycles, 10)
                let measured = 20 * log10(amplitude / 0.1)
                let predicted = profile.left.gainDB - profile.headroomAttenuationDB + eqDB(profile.left.eqBands, hz, rate: rate)
                XCTAssertEqual(measured, predicted, accuracy: 0.05, "rate \(rate) tone \(hz)")
            }
        }
    }

    // MARK: record, store, target

    func testStoreRoundTripsAndSkipsDamagedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HeadphoneResponseStore(directory: dir)
        let rec = try record("Cans", left: { _ in 0 }, right: { _ in 1 })
        try store.save(rec)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("bad.json"))
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.records.map(\.id), [rec.id])
        XCTAssertEqual(loaded.skipped, ["bad.json"])
    }

    func testMeasurementDefaultsAttributionAndUsesTheTargetOnTheGrid() throws {
        let rec = try record(left: { _ in 70 }, right: { _ in 70 })
        let target = RoomCorrectionTargetCurve(id: UUID(), name: "T", points: [
            RoomCorrectionTargetPoint(frequencyHz: 20, gainDB: 0), RoomCorrectionTargetPoint(frequencyHz: 20_000, gainDB: 6)])
        let m = try rec.measurement(target: target, sampleRate: 44_100)
        XCTAssertEqual(m.sourceAttribution, "User-supplied file")
        XCTAssertEqual(m.sourceLicense, "Local use")
        XCTAssertLessThanOrEqual(m.points.count, 240)
        XCTAssertLessThanOrEqual(m.points.last!.frequencyHz, 44_100 * 0.45)
        XCTAssertEqual(m.points.first!.leftMagnitudeDB, 0, accuracy: 1e-9, "common level removed")
        XCTAssertGreaterThan(m.points.last!.targetMagnitudeDB, 5)
    }

    func testLeftRightFilesBecomeOneStereoRecord() throws {
        func csv(_ db: Double) -> String { "frequency,raw\n20,\(db)\n1000,\(db)\n20000,\(db)\n" }
        let l = try FrequencyResponseImporter.parse(csv(1), sourceName: "Model X L")
        let r = try FrequencyResponseImporter.parse(csv(3), sourceName: "Model X R")
        let rec = try HeadphoneResponseRecord.make(from: [r, l])
        XCTAssertEqual(rec.left.db.first, 1)
        XCTAssertEqual(rec.right.db.first, 3)
        XCTAssertEqual(rec.name, "Model X")
        let both = try HeadphoneResponseRecord.make(from: [l])
        XCTAssertEqual(both.left, both.right)
        let other = try FrequencyResponseImporter.parse(csv(2), sourceName: "Different")
        XCTAssertThrowsError(try HeadphoneResponseRecord.make(from: [l, other]))
    }

    // MARK: Equalizer APO

    func testEqualizerAPOPresetParses() throws {
        let text = """
        Preamp: -5,5 dB
        Filter 1: ON LSC Fc 105 Hz Gain 4.0 dB Q 0.70
        Filter 2: ON PK Fc 1500 Hz Gain -2,5 dB Q 1.5
        Filter 3: OFF PK Fc 3000 Hz Gain 2 dB Q 2
        Filter 4: ON HSC Fc 10000 Hz Gain -3 dB Q 0.7
        Filter 5: ON LP Fc 18000 Hz
        """
        let p = try EqualizerAPOPresetImporter.parse(text)
        XCTAssertEqual(p.preampDB, -5.5)
        XCTAssertEqual(p.bands.map(\.type), [.lowShelf, .peaking, .highShelf])
        XCTAssertEqual(p.bands.map(\.gainDB), [4, -2.5, -3])
        XCTAssertEqual(p.issues.count, 2)
        let proposal = try EqualizerAPOPresetImporter.proposal(from: p, name: "Preset", sampleRate: 48_000)
        XCTAssertEqual(proposal.leftBands.count, 3)
        XCTAssertNotEqual(proposal.leftBands[0].id, proposal.rightBands[0].id)
        XCTAssertThrowsError(try EqualizerAPOPresetImporter.parse("Preamp: -3 dB\n"))
        let many = (1 ... 17).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 1 dB Q 1" }.joined(separator: "\n")
        XCTAssertThrowsError(try EqualizerAPOPresetImporter.parse(many))
    }

    // MARK: one click and Undo

    func testOneClickRecordsTheTargetAndUndoRestoresThePriorProfileExactly() throws {
        var prior = HeadphoneDeviceProfileConfiguration()
        prior.name = "Mine"; prior.left.gainDB = -1; prior.headroomAttenuationDB = 3
        prior.right.eqBands = [band(.peaking, 500, -2, 1)]
        let rate = 48_000.0
        let shape: (Double) -> Double = { 3 * sin(log2($0 / 20) * 1.5) }
        let fit = try HeadphoneAutoFitter.fit(measurement: record(left: shape, right: shape).measurement(target: nil, sampleRate: rate), sampleRate: rate)
        var session = HeadphoneOneClickSession()
        let id = UUID()
        let applied = try session.apply(fit, to: prior, targetID: id, targetName: "Flat", sampleRate: rate)
        XCTAssertTrue(applied.enabled)
        XCTAssertEqual(applied.targetCurve, .custom)
        XCTAssertEqual(applied.fittedTargetID, id)
        XCTAssertEqual(applied.fittedTargetName, "Flat")
        XCTAssertEqual(applied.name, "Mine")
        XCTAssertEqual(applied.left.gainDB, -1)
        XCTAssertTrue(session.canUndo)
        XCTAssertEqual(session.undo(), prior)
        XCTAssertFalse(session.canUndo)
        XCTAssertNil(session.undo())
    }

    func testOldProfilesDecodeWithoutTheTargetFields() throws {
        var profile = HeadphoneDeviceProfileConfiguration()
        profile.name = "Old"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json.removeValue(forKey: "fittedTargetID"); json.removeValue(forKey: "fittedTargetName")
        let decoded = try JSONDecoder().decode(HeadphoneDeviceProfileConfiguration.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, profile)
    }
}
