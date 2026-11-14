import XCTest
@testable import NotchSixty

/// E13 S6: BRIR capture processing, headphone compensation and schema-2 assets.
final class BRIRCaptureTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func device(_ id: UInt32) -> AudioInputDevice {
        AudioInputDevice(
            deviceID: id, uid: "uid-\(id)", name: "Ear mics \(id)", nominalSampleRate: 48_000,
            availableSampleRateRanges: []
        )
    }

    private func plan(
        rate: Double, tapCount: Int, speakers: [OutputProgramRole] = [.frontLeft, .frontRight],
        positions: BRIRHeadPositions = .one, rightDevice: UInt32 = 1
    ) -> BRIRCapturePlan {
        BRIRCapturePlan(
            speakers: speakers, headPositions: positions, sampleRate: rate, tapCount: tapCount,
            leftEar: MeasurementSeat(device: device(1), channelIndex: 0),
            rightEar: MeasurementSeat(device: device(rightDevice), channelIndex: 1)
        )
    }

    private final class FakeTransport: MultichannelCalibrationTransporting {
        let capture: MultichannelCalibrationCapture
        private(set) var cancelled = false
        init(_ capture: MultichannelCalibrationCapture) { self.capture = capture }
        func start() throws {}
        func snapshot() -> N60TargetedRoomMeasurementBridgeSnapshot? {
            var s = N60TargetedRoomMeasurementBridgeSnapshot()
            s.complete = true
            return s
        }
        func finishAndMaterialize() throws -> MultichannelCalibrationCapture { capture }
        func cancel() { cancelled = true }
    }

    /// A band-limited pulse (Ricker wavelet, peak near 2.5 kHz): no DC, nothing near Nyquist.
    private func ricker(rate: Double, centre: Int, gain: Float, into ir: inout [Float]) {
        let f0 = 2_500.0
        let half = Int(0.0015 * rate)
        for n in max(0, centre - half)...min(ir.count - 1, centre + half) {
            let t = Double(n - centre) / rate
            let a = Double.pi * Double.pi * f0 * f0 * t * t
            ir[n] += gain * Float((1 - 2 * a) * exp(-a))
        }
    }

    private func knownIR(rate: Double, frames: Int, directMs: Double, gain: Float) -> [Float] {
        var ir = [Float](repeating: 0, count: frames)
        let d = Int((directMs * 1e-3 * rate).rounded())
        ricker(rate: rate, centre: d, gain: gain, into: &ir)
        ricker(rate: rate, centre: d + Int(0.0017 * rate), gain: 0.4 * gain, into: &ir)
        ricker(rate: rate, centre: d + Int(0.0031 * rate), gain: -0.3 * gain, into: &ir)
        return ir
    }

    private func rms(_ x: [Float]) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) }) }

    private func errorDB(_ got: [Float], _ expected: [Float]) -> Double {
        XCTAssertEqual(got.count, expected.count)
        let diff = zip(got, expected).map { $0 - $1 }
        return 20 * log10(max(rms(diff), 1e-12) / rms(expected))
    }

    func testSyntheticTwoEarCaptureRebuildsKnownBRIRAtEveryRate() async throws {
        for rate in Self.rates {
            let taps = Int(0.008 * rate)
            let frames = Int(0.02 * rate)
            // Left ear hears the direct sound 0.35 ms before the right ear.
            let knownLeft = knownIR(rate: rate, frames: frames, directMs: 2.0, gain: 1.0)
            let knownRight = knownIR(rate: rate, frames: frames, directMs: 2.35, gain: 0.6)
            let sweep = try MeasurementCore.makeSweep(
                sampleRate: rate, startFrequencyHz: 20, endFrequencyHz: min(20_000, 0.45 * rate),
                durationSeconds: 0.25, levelDBFS: -12, fadeSeconds: 0.01, synchronised: true
            ).samples
            let start = Int(0.1 * rate)
            let total = start + sweep.count + Int(0.3 * rate)
            func heard(_ ir: [Float], seed: UInt32) -> [Float] {
                let wet = BRIRHeadphoneCompensation.convolve(sweep, with: ir, count: sweep.count + ir.count)
                var out = [Float](repeating: 0, count: total)
                var state = seed
                for i in 0..<total {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    out[i] = (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.0003
                    if i >= start, i - start < wet.count { out[i] += wet[i - start] }
                }
                return out
            }
            let fake = FakeTransport(MultichannelCalibrationCapture(
                samples: heard(knownLeft, seed: 1), seatSamples: [heard(knownRight, seed: 2)]))
            let p = plan(rate: rate, tapCount: taps)
            let pass = MultiMicPass(sweep: sweep, sweepStartFrame: start, referenceChirp: nil, chirpStartFrame: 0)
            let (left, right) = try await BRIRCaptureProcessor.capture(
                plan: p, pass: pass, timeoutSeconds: 5, makeTransport: { _, _ in fake })
            XCTAssertEqual(left.count, taps)

            let onset = Int((2.0e-3 * rate).rounded()) - p.preRollFrames
            func expected(_ known: [Float]) -> [Float] {
                var e = Array(known[onset..<(onset + taps)])
                BRIRCaptureProcessor.applyWindow(&e, preRollFrames: p.preRollFrames)
                return e
            }
            XCTAssertLessThan(errorDB(left, expected(knownLeft)), -50, "left at \(rate)")
            XCTAssertLessThan(errorDB(right, expected(knownRight)), -50, "right at \(rate)")

            // The interaural delay survives the common-onset trim.
            let peakL = left.indices.max { abs(left[$0]) < abs(left[$1]) }!
            let peakR = right.indices.max { abs(right[$0]) < abs(right[$1]) }!
            XCTAssertEqual(peakR - peakL, Int((0.35e-3 * rate).rounded()), accuracy: 1, "ITD at \(rate)")
        }
    }

    // MARK: - Headphone compensation

    private func headphone(rate: Double, extra: [ReferenceRoom] = [], jitterDB: Double = 0) -> (ir: [Float], rooms: [ReferenceRoom]) {
        let rooms = [
            ReferenceRoom(delayFrames: 0, resonanceHz: 3_000, gainDB: 5 + jitterDB, q: 1.0),
            ReferenceRoom(delayFrames: 0, resonanceHz: 120, gainDB: 4 - jitterDB, q: 0.8),
            ReferenceRoom(delayFrames: 0, resonanceHz: 9_000, gainDB: -4, q: 1.0),
        ] + extra
        var ir = [Float](repeating: 0, count: Int(0.25 * rate))
        ir[0] = 1
        for room in rooms { ir = room.render(ir, rate: rate) }
        return (ir, rooms)
    }

    private func response(_ taps: [Float], at hz: Double, rate: Double) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * hz / rate
        for (n, v) in taps.enumerated() {
            re += Double(v) * cos(w * Double(n))
            im -= Double(v) * sin(w * Double(n))
        }
        return 20 * log10(max(hypot(re, im), 1e-12))
    }

    func testCompensationFlattensKnownHeadphoneAtEveryRate() throws {
        for rate in Self.rates {
            let reseats = (0..<BRIRCapturePlan.compensationReseatCount).map {
                headphone(rate: rate, jitterDB: Double($0 - 2) * 0.25).ir
            }
            let comp = try BRIRHeadphoneCompensation.design(
                leftReseats: reseats, rightReseats: reseats, sampleRate: rate)
            let rooms = headphone(rate: rate).rooms
            var totals = [Double]()
            var freqs = [Double]()
            var f = 50.0
            while f <= 12_000 { freqs.append(f); f *= pow(2, 1.0 / 6.0) }
            for f in freqs {
                let hp = rooms.reduce(0.0) { $0 + $1.magnitudeDB(at: f, rate: rate) }
                totals.append(hp + response(comp.left, at: f, rate: rate))
            }
            let reference = zip(freqs, totals).filter { $0.0 >= 200 && $0.0 <= 2_000 }.map(\.1)
            let level = reference.reduce(0, +) / Double(reference.count)
            for (f, t) in zip(freqs, totals) {
                XCTAssertEqual(t, level, accuracy: 1.0, "\(Int(f)) Hz at \(rate)")
            }
        }
    }

    func testCompensationBoostLimitHoldsOnADeepNotch() throws {
        let rate = 48_000.0
        let notch = ReferenceRoom(delayFrames: 0, resonanceHz: 5_000, gainDB: -25, q: 3)
        let ir = headphone(rate: rate, extra: [notch]).ir
        let comp = try BRIRHeadphoneCompensation.design(leftReseats: [ir], rightReseats: [ir], sampleRate: rate)
        var peak = -Double.infinity
        var f = 20.0
        while f <= 20_000 { peak = max(peak, response(comp.left, at: f, rate: rate)); f *= pow(2, 1.0 / 12.0) }
        XCTAssertLessThanOrEqual(peak, BRIRHeadphoneCompensation.maximumBoostDB + 0.75)
        XCTAssertGreaterThan(peak, 6, "the notch is still partly filled")
    }

    func testCompensationRejectsSilentOrMismatchedInput() {
        XCTAssertThrowsError(try BRIRHeadphoneCompensation.design(
            leftReseats: [[Float](repeating: 0, count: 100)], rightReseats: [[Float](repeating: 0, count: 100)],
            sampleRate: 48_000))
        XCTAssertThrowsError(try BRIRHeadphoneCompensation.design(
            leftReseats: [[1]], rightReseats: [], sampleRate: 48_000))
    }

    // MARK: - Plan, asset and selection

    func testPlanValidationAndStepOrder() throws {
        let p = plan(rate: 48_000, tapCount: 512, positions: .three)
        XCTAssertNoThrow(try p.validate())
        XCTAssertEqual(p.steps.count, 6)
        XCTAssertEqual(p.steps.prefix(2).map(\.headYawDegrees), [-30, -30])
        XCTAssertEqual(p.steps.map(\.role).prefix(2), [.frontLeft, .frontRight])
        XCTAssertEqual(BRIRHeadPositions.five.yawDegrees.count, 5)

        XCTAssertThrowsError(try plan(rate: 48_000, tapCount: 512, rightDevice: 2).validate(), "two clocks")
        XCTAssertThrowsError(try plan(rate: 48_000, tapCount: 512, speakers: []).validate())
        XCTAssertThrowsError(try plan(rate: 48_000, tapCount: 512, speakers: [.lowFrequencyEffects]).validate())
        XCTAssertThrowsError(try plan(rate: 48_000, tapCount: 512, speakers: [.frontLeft, .frontLeft]).validate())
        // E13 S4: the cap is one second of taps, not 8192.
        XCTAssertNoThrow(try plan(rate: 48_000, tapCount: 9_000).validate(), "long responses are allowed")
        XCTAssertThrowsError(try plan(rate: 48_000, tapCount: 48_049).validate(), "above one second")
    }

    private func markedResults(_ p: BRIRCapturePlan) -> [BRIRCaptureResult] {
        p.steps.enumerated().map { index, step in
            var left = [Float](repeating: 0, count: p.tapCount)
            var right = left
            left[10 + index] = 1       // the marker position identifies the (role, yaw) pair
            right[40 + index] = 0.5
            return BRIRCaptureResult(
                role: step.role, headYawDegrees: step.headYawDegrees,
                headPitchDegrees: step.headPitchDegrees, leftIR: left, rightIR: right)
        }
    }

    /// G16: a capture at three head pitches records pitch, selects by role, yaw and pitch, and reports elevation sets.
    func testTiltedCaptureRecordsPitchAndSelectsByIt() throws {
        for rate in Self.rates {
            var p = plan(rate: rate, tapCount: 128, positions: .one)
            p.headTilt = .threePitches
            XCTAssertEqual(p.steps.count, 6)
            XCTAssertEqual(p.steps.map(\.headPitchDegrees), [-30, -30, 0, 0, 30, 30])
            let asset = try BRIRCaptureAssembler.makeAsset(displayName: "Mine", plan: p, results: markedResults(p))
            XCTAssertTrue(asset.providesElevationSets)
            XCTAssertEqual(asset.reference.hasElevationSets, true)
            func front(pitch: Double) throws -> Int {
                let prepared = try asset.prepare(
                    for: .stereo, headPose: N60HeadPose(yawDegrees: 0, pitchDegrees: pitch, rollDegrees: 0))
                let ir = prepared.leftIRs[0..<128]
                return ir.indices.max { ir[$0] < ir[$1] }! - ir.startIndex
            }
            XCTAssertEqual(try front(pitch: -40), 10, "nearest is -30 at \(rate)")
            XCTAssertEqual(try front(pitch: 5), 12)
            XCTAssertEqual(try front(pitch: 25), 14)

            // A level-only capture has no elevation sets and records no pitch.
            let level = plan(rate: rate, tapCount: 128, positions: .one)
            let flat = try BRIRCaptureAssembler.makeAsset(displayName: "Flat", plan: level, results: markedResults(level))
            XCTAssertFalse(flat.providesElevationSets)
            XCTAssertTrue(flat.measurements.allSatisfy { $0.headPitchDegrees == nil })
            // Results missing a pitch are an incomplete capture.
            var wrong = markedResults(p)
            wrong[0].headPitchDegrees = 10
            XCTAssertThrowsError(try BRIRCaptureAssembler.makeAsset(displayName: "x", plan: p, results: wrong))
        }
    }

    func testThreeYawAssetSelectsByRoleAndYaw() throws {
        for rate in Self.rates {
            let p = plan(rate: rate, tapCount: 128, positions: .three)
            let asset = try BRIRCaptureAssembler.makeAsset(
                displayName: "Mine", plan: p, results: markedResults(p))
            XCTAssertEqual(asset.schemaVersion, 2)
            XCTAssertEqual(asset.kind, .brir)
            XCTAssertEqual(asset.measurements.count, 6)

            func marker(_ yaw: Double) throws -> (front: Int, right: Int) {
                let prepared = try asset.prepare(
                    for: .stereo, headPose: N60HeadPose(yawDegrees: yaw, pitchDegrees: 0, rollDegrees: 0))
                func peak(_ ir: ArraySlice<Float>) -> Int { ir.indices.max { ir[$0] < ir[$1] }! - ir.startIndex }
                return (peak(prepared.leftIRs[0..<128]), peak(prepared.leftIRs[128..<256]))
            }
            // steps: yaw -30 (FL idx0, FR idx1), 0 (idx2, idx3), +30 (idx4, idx5).
            XCTAssertEqual(try marker(-40).front, 10, "yaw -40 picks -30")
            XCTAssertEqual(try marker(-40).right, 11)
            XCTAssertEqual(try marker(0).front, 12)
            XCTAssertEqual(try marker(0).right, 13)
            XCTAssertEqual(try marker(16).front, 14, "yaw 16 is nearer +30 than 0")
            XCTAssertEqual(try marker(90).right, 15, "beyond the range clamps to the last yaw")
            XCTAssertEqual(try asset.prepare(for: .stereo).leftIRs[0..<128].enumerated()
                .max { $0.element < $1.element }!.offset, 12, "default pose is yaw 0")
        }
    }

    func testSetIsNormalisedToUnitEnergyOnTheLoudestEar() throws {
        let p = plan(rate: 48_000, tapCount: 128, positions: .one)
        var results = markedResults(p)
        results[0].leftIR[10] = 4   // loudest ear
        let asset = try BRIRCaptureAssembler.makeAsset(displayName: "Mine", plan: p, results: results)
        let energies = asset.measurements.flatMap { [rms($0.leftIR), rms($0.rightIR)] }
        XCTAssertEqual(energies.max()!, 1.0, accuracy: 1e-5)
        XCTAssertEqual(asset.measurements[1].leftIR[11], 0.25, accuracy: 1e-5, "ratios are preserved")
    }

    func testIncompleteOrSilentCaptureProducesNoAsset() {
        let p = plan(rate: 48_000, tapCount: 128, positions: .three)
        var results = markedResults(p)
        results.removeLast()
        XCTAssertThrowsError(try BRIRCaptureAssembler.makeAsset(displayName: "x", plan: p, results: results)) {
            XCTAssertEqual($0 as? BRIRCaptureError, .incompleteCapture)
        }
        let silent = p.steps.map {
            BRIRCaptureResult(role: $0.role, headYawDegrees: $0.headYawDegrees,
                              leftIR: [Float](repeating: 0, count: 128), rightIR: [Float](repeating: 0, count: 128))
        }
        XCTAssertThrowsError(try BRIRCaptureAssembler.makeAsset(displayName: "x", plan: p, results: silent))
    }

    func testCompensationIsConvolvedIntoEveryBRIR() throws {
        let p = plan(rate: 48_000, tapCount: 128, positions: .one)
        var unit = [Float](repeating: 0, count: 8); unit[0] = 1
        var delayed = [Float](repeating: 0, count: 8); delayed[3] = 1
        let comp = BRIRHeadphoneCompensation(left: unit, right: delayed)
        let asset = try BRIRCaptureAssembler.makeAsset(
            displayName: "x", plan: p, results: markedResults(p), compensation: comp)
        let first = asset.measurements[0]
        XCTAssertGreaterThan(first.leftIR[10], 0, "left ear got the identity")
        XCTAssertGreaterThan(first.rightIR[43], 0, "right ear got the 3-frame delay")
        XCTAssertEqual(first.rightIR[40], 0, accuracy: 1e-7)
    }

    func testSchema1AssetsStillLoadAndSchema2RoundTrips() throws {
        var old = BinauralProfileAsset.validationStereo()
        old.schemaVersion = 1
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(BinauralProfileAsset.self, from: data)
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertNil(decoded.measurements[0].channelRole)
        XCTAssertNoThrow(try decoded.prepare(for: .stereo))

        var future = old; future.schemaVersion = 3
        XCTAssertThrowsError(try future.validate())
        var tagged = old   // a schema-1 file cannot carry roles
        tagged.measurements = tagged.measurements.map { var m = $0; m.channelRole = .frontLeft; return m }
        XCTAssertThrowsError(try tagged.validate())

        let p = plan(rate: 48_000, tapCount: 128, positions: .three)
        let asset = try BRIRCaptureAssembler.makeAsset(displayName: "Mine", plan: p, results: markedResults(p))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BinauralProfileAssetStore(rootURL: root)
        _ = try store.save(asset)
        XCTAssertEqual(try store.load(id: asset.id), asset)
    }
}
