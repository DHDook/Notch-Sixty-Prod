import XCTest
@testable import NotchSixty

/// E13 S5: delay-separated HRTF interpolation under head tracking. The renderer's maths is covered by the core harness
/// (`test_binaural_interp.cpp`, a spherical-head model at the eight rates); these tests cover the production wiring:
/// the translator's tracking grid, its budget coarsening, the published stage parameters, pitch from the head pose, and a
/// long SOFA import through to a built graph.
final class UnifiedGraphBinauralInterpolationTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    private func spec(
        rate: Double, layout: OutputProgramLayout = .fiveOne, headTracking: Bool, asset: BinauralProfileAsset? = nil
    ) -> Result<UnifiedGraphSpec, UnifiedGraphFallbackReason> {
        var profile = HeadphoneDeviceProfileConfiguration()
        profile.programLayout = layout
        return UnifiedGraphTranslator.binauralSpec(
            asset: asset ?? BinauralProfileAsset.validationStereo(sampleRate: rate), layout: layout, profile: profile,
            outputChannels: 2, sampleRate: rate, headTracking: headTracking)
    }

    private func stage(_ built: UnifiedGraphSpec) throws -> UnifiedGraphStageSpec {
        try XCTUnwrap(built.stages.first { $0.stageId == N60_LSTAGE_BINAURAL })
    }

    // MARK: the tracking grid and its budget

    /// G14: the user-facing note says what the coarsened grid is, and is absent when the finest grid fits.
    func testTrackingNoteReportsTheCoarsenedGrid() throws {
        let translator = UnifiedGraphTranslator.self
        XCTAssertNil(translator.binauralTrackingNote(channels: 6, sampleRate: 48_000, tapCount: 8_192, elevationData: true))
        let note = try XCTUnwrap(
            translator.binauralTrackingNote(channels: 12, sampleRate: 192_000, tapCount: 48_000, elevationData: true))
        XCTAssertTrue(note.contains("30 degree yaw"), note)
        XCTAssertTrue(note.contains("4 head pitches"), note)
        let yawOnly = try XCTUnwrap(
            translator.binauralTrackingNote(channels: 12, sampleRate: 384_000, tapCount: 96_000, elevationData: true))
        XCTAssertTrue(yawOnly.contains("15 degree yaw") && yawOnly.contains("no head pitch"), yawOnly)
        XCTAssertNil(translator.binauralTrackingNote(channels: 12, sampleRate: 384_000, tapCount: 96_000, elevationData: false))
        XCTAssertNotNil(translator.binauralTrackingNote(channels: 64, sampleRate: 384_000, tapCount: 96_000, elevationData: true))
    }

    func testTrackingGridIsFullWhenItFitsAndCoarsensInStepsWhenItDoesNot() {
        let translator = UnifiedGraphTranslator.self
        let elevations = UInt32(translator.binauralElevationDegrees.count)
        // 5.1 at 48 kHz: 15 degree yaw by every elevation.
        var plan = translator.binauralTrackingPlan(channels: 6, earlyTaps: 960, elevationData: true)
        XCTAssertEqual(plan, .init(yawSets: 24, elevations: elevations, coarsened: false))
        // 7.1.4 at 192 kHz: the 4 elevations at 15 degrees exceed the budget, 30 degree yaw keeps the elevations.
        plan = translator.binauralTrackingPlan(channels: 12, earlyTaps: 3_840, elevationData: true)
        XCTAssertEqual(plan, .init(yawSets: 12, elevations: elevations, coarsened: true))
        // 7.1.4 at 384 kHz: yaw only at 15 degrees.
        plan = translator.binauralTrackingPlan(channels: 12, earlyTaps: 7_680, elevationData: true)
        XCTAssertEqual(plan, .init(yawSets: 24, elevations: 1, coarsened: true))
        // An asset with no elevation data starts at yaw only and is not "coarsened".
        plan = translator.binauralTrackingPlan(channels: 12, earlyTaps: 7_680, elevationData: false)
        XCTAssertEqual(plan, .init(yawSets: 24, elevations: 1, coarsened: false))
        // Nothing fits: refused.
        XCTAssertNil(translator.binauralTrackingPlan(channels: 64, earlyTaps: 7_680, elevationData: true))
        XCTAssertEqual(plan?.yawStepDegrees, 15)
    }

    func testTrackedGraphPublishesElevationSetsAndDelaysAtEveryRate() throws {
        let elevations = UnifiedGraphTranslator.binauralElevationDegrees.count
        for rate in Self.rates {
            let built = try spec(rate: rate, headTracking: true).get()
            let p = try stage(built).params
            let sets = Int(p[4])
            XCTAssertEqual(sets, 24 * elevations, "rate \(rate)")
            XCTAssertEqual(Int(p[11]), elevations, "rate \(rate)")
            let taps = Int(p[3]), tail = Int(p[10]), sources = 6
            XCTAssertEqual(p.count, 12 + sets * sources * 2 * taps + sources * 2 * tail + 2 + sets * sources * 2, "rate \(rate)")
            // A fixed head keeps the single, undelayed set; tracking adds the delay line's centre tap and nothing else.
            let fixed = try spec(rate: rate, headTracking: false).get()
            XCTAssertEqual(try stage(fixed).params[11], 0, "rate \(rate)")
            let host = try UnifiedGraphHost(spec: built)
            let fixedHost = try UnifiedGraphHost(spec: fixed)
            let added: Int = Int(host.latencyFrames) - Int(fixedHost.latencyFrames)
            let expected: Int = Int(N60_GRAPH_BINAURAL_FD_LATENCY)
            XCTAssertEqual(added, expected, "rate \(rate)")
            host.release()
            fixedHost.release()
        }
    }

    /// G16: a role-tagged BRIR captured at three head pitches publishes elevation sets; a level capture stays yaw only.
    func testCapturedAssetWithHeadTiltPublishesElevationSets() throws {
        let layout = OutputProgramLayout.fiveOne
        func asset(tilt: BRIRHeadTilt, rate: Double) throws -> BinauralProfileAsset {
            let taps = 256
            let device = AudioInputDevice(
                deviceID: 1, uid: "u", name: "m", nominalSampleRate: rate, availableSampleRateRanges: [])
            let roles = layout.roles.filter { $0 != .lowFrequencyEffects }
            let plan = BRIRCapturePlan(
                speakers: roles, headPositions: .one, headTilt: tilt, sampleRate: rate, tapCount: taps,
                leftEar: MeasurementSeat(device: device, channelIndex: 0),
                rightEar: MeasurementSeat(device: device, channelIndex: 1))
            let results = plan.steps.enumerated().map { index, step -> BRIRCaptureResult in
                var left = [Float](repeating: 0, count: taps)
                left[20 + index % 7] = 1
                var right = left
                right[24 + index % 5] = 0.8
                return BRIRCaptureResult(
                    role: step.role, headYawDegrees: step.headYawDegrees,
                    headPitchDegrees: step.headPitchDegrees, leftIR: left, rightIR: right)
            }
            var made = try BRIRCaptureAssembler.makeAsset(displayName: "T", plan: plan, results: results)
            // The 5.1 layout has an LFE channel the capture skips: reuse the centre response for it.
            if let centre = made.measurements.first(where: { $0.channelRole == .frontCenter }) {
                for m in made.measurements where m.channelRole == .frontCenter {
                    var lfe = m
                    lfe.channelRole = .lowFrequencyEffects
                    made.measurements.append(lfe)
                }
                _ = centre
            }
            return made
        }
        let elevations = UnifiedGraphTranslator.binauralElevationDegrees.count
        for rate in Self.rates {
            let tilted = try spec(rate: rate, layout: layout, headTracking: true, asset: try asset(tilt: .threePitches, rate: rate)).get()
            XCTAssertEqual(Int(try stage(tilted).params[11]), elevations, "rate \(rate)")
            let level = try spec(rate: rate, layout: layout, headTracking: true, asset: try asset(tilt: .level, rate: rate)).get()
            XCTAssertEqual(Int(try stage(level).params[11]), 1, "rate \(rate)")
        }
    }

    func testSevenOneFourAt384kCoarsensToYawOnlyAndStillBuilds() throws {
        let rate = 384_000.0
        var asset = BinauralProfileAsset.validationStereo(sampleRate: rate)
        let taps = Int(rate)
        asset.measurements = asset.measurements.map { source in
            var m = source
            var left = [Float](repeating: 0, count: taps), right = left
            left[0] = source.leftIR[0]
            right[0] = source.rightIR[0]
            m.leftIR = left
            m.rightIR = right
            return m
        }
        asset.tapCount = taps
        let built = try spec(rate: rate, layout: .sevenOneFour, headTracking: true, asset: asset).get()
        let p = try stage(built).params
        XCTAssertEqual(Int(p[4]), 24)
        XCTAssertEqual(Int(p[11]), 1)
        let host = try UnifiedGraphHost(spec: built)
        XCTAssertNoThrow(try host.setBinauralPose(yaw: 20, pitch: 10, roll: 0))
        host.release()
    }

    // MARK: head pitch

    /// Elevated measurements at the front-left speaker's azimuth, quieter than the level one, so a pitched head hears a
    /// different level than a level head.
    private func elevatedAsset(rate: Double) -> BinauralProfileAsset {
        var asset = BinauralProfileAsset.validationStereo(sampleRate: rate)
        func impulse(_ azimuth: Double, _ elevation: Double, _ left: Float, _ right: Float) -> BinauralMeasurement {
            var l = [Float](repeating: 0, count: asset.tapCount), r = l
            l[0] = left
            r[0] = right
            return BinauralMeasurement(
                azimuthDegrees: azimuth, elevationDegrees: elevation, distanceMeters: 1, leftIR: l, rightIR: r)
        }
        for elevation in [-60.0, -30.0, 30.0, 60.0] {
            for azimuth in [-30.0, 0.0, 30.0] {
                asset.measurements.append(impulse(azimuth, elevation, 0.3, 0.3))
            }
        }
        return asset
    }

    private func leftLevel(_ host: UnifiedGraphHost, rate: Double) throws -> Double {
        let block = 512
        let total = Int(rate * 0.3) / block * block
        var left: [Float] = []
        var position = 0
        while position < total {
            let tone = (0..<block).map { Float(0.25 * sin(2.0 * .pi * 1_000.0 * Double(position + $0) / rate)) }
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: 6)
            input[0] = tone
            left += try host.processOffline(input: input, frames: block)[0]
            position += block
        }
        return rms(left[(left.count * 3 / 4)...])
    }

    func testHeadPitchBlendsBetweenElevationSetsAtEveryRate() throws {
        for rate in Self.rates {
            let host = try UnifiedGraphHost(spec: try spec(rate: rate, headTracking: true, asset: elevatedAsset(rate: rate)).get())
            var level: [Double: Double] = [:]
            for pitch in [-30.0, -15.0, 0.0, 15.0, 30.0] {
                try host.setBinauralPose(yaw: 0, pitch: Float(pitch), roll: 0)
                level[pitch] = try leftLevel(host, rate: rate)
            }
            let base = try XCTUnwrap(level[0])
            XCTAssertGreaterThan(base, 0.01, "rate \(rate)")
            // The pitch whose image differs most from the level head: the elevated measurement takes over there.
            let sign: Double = abs(try XCTUnwrap(level[30]) - base) >= abs(try XCTUnwrap(level[-30]) - base) ? 1 : -1
            let end = try XCTUnwrap(level[sign * 30]), halfway = try XCTUnwrap(level[sign * 15])
            XCTAssertGreaterThan(abs(end - base), 0.1 * base, "pitch changes the image at \(rate)")
            let low = min(base, end), high = max(base, end)
            XCTAssertGreaterThan(halfway, low + 0.05 * (high - low), "pitch 15 is between the sets at \(rate)")
            XCTAssertLessThan(halfway, high - 0.05 * (high - low), "pitch 15 is between the sets at \(rate)")
            host.release()
        }
    }

    // MARK: G10: a long SOFA file through the importer's adapter to a built graph

    /// A synthetic GeneralFIR dataset one second long (the longest asset the graph takes) at every rate: the adapter
    /// converts it without a tap cap and the translator splits it into the early part and the shared tail.
    func testOneSecondSOFADatasetConvertsAndBuildsAtEveryRate() throws {
        for rate in Self.rates {
            let taps = Int(rate)
            let measurements = 2, receivers = 2
            var ir = [Float](repeating: 0, count: measurements * receivers * taps)
            for signal in 0..<(measurements * receivers) {
                ir[signal * taps + 32] = signal % receivers == 0 ? 1 : 0.4
                ir[signal * taps + taps / 2] = 0.2
            }
            let provenance = SOFAImportProvenance(
                sourceFileName: "long.sofa", sofaConvention: "GeneralFIR", sofaConventionVersion: "2.0", sofaVersion: "2.1",
                dataType: "FIR", roomType: "reverberant", sourceLicense: "Synthetic test fixture", title: "Long",
                measurementCount: measurements, receiverCount: receivers, emitterCount: 1, sourceTapCount: taps,
                delayBakeCommonOffsetSamples: 0, fractionalDelayKernelRadius: 0)
            let frame = try SOFAListenerFrame(
                position: .zero, view: SOFAVector3(x: 1, y: 0, z: 0), up: SOFAVector3(x: 0, y: 0, z: 1))
            let dataset = SOFAFIRDataset(
                sampleRate: rate, measurementCount: measurements, receiverCount: receivers, emitterCount: 1, tapCount: taps,
                emitterDependent: false, provenance: provenance, listenerFrames: [frame, frame],
                sourcePositions: [SOFAVector3(x: 0.87, y: 0.5, z: 0), SOFAVector3(x: 0.87, y: -0.5, z: 0)],
                emitterPositions: [.zero, .zero], delaysSamples: [Double](repeating: 0, count: measurements * receivers),
                impulseResponses: ir)
            let asset = try SOFABinauralAssetAdapter().makeAsset(from: dataset, sourceURL: URL(fileURLWithPath: "/tmp/long.sofa"))
            XCTAssertEqual(asset.tapCount, taps, "rate \(rate)")
            XCTAssertNoThrow(try asset.validate(), "rate \(rate)")
            let built = try spec(rate: rate, headTracking: true, asset: asset).get()
            let p = try stage(built).params
            // The first arrival (tap 32) is inside the 1 ms margin, so nothing is trimmed.
            XCTAssertEqual(Int(p[3]) + Int(p[10]), taps, "early plus tail is the whole response at \(rate)")
        }
    }
}
