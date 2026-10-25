import XCTest
@testable import NotchSixty

/// E6 S8b2d: the binaural headphone session's unified-graph spec. Behavioural: real graphs,
/// real audio blocks, every standard rate.
final class UnifiedGraphBinauralTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    private func spec(
        rate: Double,
        layout: OutputProgramLayout = .fiveOne,
        headTracking: Bool = false,
        profile: HeadphoneDeviceProfileConfiguration = HeadphoneDeviceProfileConfiguration(),
        outputChannels: UInt32 = 2,
        asset: BinauralProfileAsset? = nil
    ) -> Result<UnifiedGraphSpec, UnifiedGraphFallbackReason> {
        var profile = profile
        profile.programLayout = layout
        return UnifiedGraphTranslator.binauralSpec(
            asset: asset ?? BinauralProfileAsset.validationStereo(sampleRate: rate),
            layout: layout, profile: profile, outputChannels: outputChannels,
            sampleRate: rate, headTracking: headTracking
        )
    }

    /// Renders a 1 kHz tone on lane 0 only and returns (left ear RMS, right ear RMS) once settled.
    private func earLevels(host: UnifiedGraphHost, rate: Double, lanes: Int) throws -> (Double, Double) {
        let block = 512
        let total = Int(rate * 0.3) / block * block
        var left: [Float] = [], right: [Float] = []
        var position = 0
        while position < total {
            let tone = (0..<block).map {
                Float(0.25 * sin(2.0 * .pi * 1_000.0 * Double(position + $0) / rate))
            }
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: lanes)
            input[0] = tone
            let out = try host.processOffline(input: input, frames: block)
            left += out[0]; right += out[1]
            position += block
        }
        let start = left.count * 3 / 4
        return (rms(left[start...]), rms(right[start...]))
    }

    func testFallbackReasons() throws {
        let rate = 48_000.0
        guard case .failure(let missing) = UnifiedGraphTranslator.binauralSpec(
            asset: nil, layout: .fiveOne, profile: HeadphoneDeviceProfileConfiguration(),
            outputChannels: 2, sampleRate: rate, headTracking: false
        ) else { return XCTFail("nil asset must fall back") }
        XCTAssertEqual(missing, .binauralProfileMissing)

        guard case .failure(let notStereo) = spec(rate: rate, outputChannels: 6) else {
            return XCTFail("six-channel output must fall back")
        }
        XCTAssertEqual(notStereo, .binauralOutputNotStereo)

        guard case .failure(let stereoProgram) = spec(rate: rate, layout: .stereo) else {
            return XCTFail("a stereo program has nothing to virtualise")
        }
        XCTAssertEqual(stereoProgram, .noProgramLanes)

        var big = BinauralProfileAsset.validationStereo(sampleRate: rate)
        big.tapCount = Int(N60_GRAPH_BINAURAL_MAX_TAPS) + 1
        guard case .failure(let budget) = spec(rate: rate, asset: big) else {
            return XCTFail("an over-budget set must fall back")
        }
        XCTAssertEqual(budget, .binauralBudget)

        // E6 S9c2: the headphone profile's whole 0...30 dB headroom range is in the graph; the only DSP refusals left
        // are values the profile itself rejects (headroom above 30 dB, more than the legacy 16 EQ sections per side).
        var deep = HeadphoneDeviceProfileConfiguration()
        deep.headroomAttenuationDB = 27
        XCTAssertNoThrow(try spec(rate: rate, profile: deep).get())
        deep.headroomAttenuationDB = 30
        XCTAssertNoThrow(try spec(rate: rate, profile: deep).get())
        deep.headroomAttenuationDB = 31
        guard case .failure(let dsp) = spec(rate: rate, profile: deep) else {
            return XCTFail("a headroom above 30 dB must fall back")
        }
        XCTAssertEqual(dsp, .headphoneDSP)

        guard case .failure(let mismatch) = spec(
            rate: rate, asset: BinauralProfileAsset.validationStereo(sampleRate: 44_100)
        ) else { return XCTFail("an unconverted rate must fall back") }
        XCTAssertEqual(mismatch, .sampleRateMismatch)
    }

    /// The legacy headphone path allows 16 EQ sections per side (`N60_HEADPHONE_MAX_EQ_SECTIONS`); the graph takes
    /// all 16 at every rate and still refuses a 17th rather than silently dropping it.
    func testSixteenHeadphoneEQBandsPerSideBuildAndRenderAtEveryRate() throws {
        func bands(_ count: Int, _ rate: Double) -> [HeadphoneCorrectionEQBand] {
            (0..<count).map { index in
                var band = HeadphoneCorrectionEQBand()
                band.frequencyHz = min(100.0 * pow(1.28, Double(index)), rate * 0.4)
                band.gainDB = index.isMultiple(of: 2) ? 3 : -3
                band.q = 1.5
                return band
            }
        }
        for rate in Self.rates {
            var profile = HeadphoneDeviceProfileConfiguration()
            profile.headroomAttenuationDB = 12
            profile.left.eqBands = bands(16, rate)
            profile.right.eqBands = bands(16, rate)
            let built = try spec(rate: rate, profile: profile).get()
            let host = try UnifiedGraphHost(spec: built)
            let (left, right) = try earLevels(host: host, rate: rate, lanes: 6)
            XCTAssertGreaterThan(left, 0.0005, "rate \(rate)")
            XCTAssertGreaterThan(right, 0.0001, "rate \(rate)")
            host.release()

            profile.left.eqBands = bands(17, rate)
            guard case .failure(let reason) = spec(rate: rate, profile: profile) else {
                return XCTFail("a 17th band must fall back at rate \(rate)")
            }
            XCTAssertEqual(reason, .headphoneDSP, "rate \(rate)")
        }
    }

    func testBinauralGraphRendersEarLevelsAtEveryRate() throws {
        for rate in Self.rates {
            let built = try spec(rate: rate).get()
            XCTAssertEqual(built.inputChannels, 6, "rate \(rate)")
            // The core keeps the program lane count; the ears are lanes 0 and 1.
            XCTAssertEqual(built.outputChannels, 6, "rate \(rate)")
            let host = try UnifiedGraphHost(spec: built)
            XCTAssertGreaterThanOrEqual(host.latencyFrames, 128, "rate \(rate)")
            let (left, right) = try earLevels(host: host, rate: rate, lanes: 6)
            // Front-left sits at -30 degrees: the near (left) ear is five times the far ear.
            XCTAssertGreaterThan(left, 0.01, "rate \(rate)")
            XCTAssertEqual(left / max(right, 1e-9), 5.0, accuracy: 0.5, "rate \(rate)")
            host.release()
        }
    }

    func testHeadYawPostMovesTheImageAtEveryRate() throws {
        for rate in Self.rates {
            let built = try spec(rate: rate, headTracking: true).get()
            let host = try UnifiedGraphHost(spec: built)
            let (leftFront, rightFront) = try earLevels(host: host, rate: rate, lanes: 6)
            XCTAssertGreaterThan(leftFront, rightFront, "rate \(rate)")
            // Turning the head to face the source's side swings the image to the other ear.
            try host.setBinauralPose(yaw: -60, pitch: 0, roll: 0)
            let (leftTurned, rightTurned) = try earLevels(host: host, rate: rate, lanes: 6)
            XCTAssertNotEqual(leftTurned / max(rightTurned, 1e-9), leftFront / max(rightFront, 1e-9),
                              accuracy: 0.2, "rate \(rate)")
            host.release()
        }
    }

    func testPoseWithoutBinauralStageThrows() throws {
        let stereo = try UnifiedGraphTranslator.layoutSpec(
            layoutIdentifier: UInt32(N60_LAYOUT_STEREO.rawValue), sampleRate: 48_000
        )
        let host = try UnifiedGraphHost(spec: stereo)
        XCTAssertThrowsError(try host.setBinauralPose(yaw: 10, pitch: 0, roll: 0))
        host.release()
    }

    func testPoseIsRefusedWhenBuiltWithoutHeadTracking() throws {
        let host = try UnifiedGraphHost(spec: try spec(rate: 48_000, headTracking: false).get())
        XCTAssertThrowsError(try host.setBinauralPose(yaw: 30, pitch: 0, roll: 0))
        host.release()
    }

    func testYawWrapsAndRepeatedPoseIsUnchanged() throws {
        let host = try UnifiedGraphHost(spec: try spec(rate: 48_000, headTracking: true).get())
        XCTAssertEqual(try host.setBinauralPose(yaw: 190, pitch: 0, roll: 0), .posted(count: 3))
        XCTAssertEqual(try host.setBinauralPose(yaw: -170, pitch: 0, roll: 0), .unchanged)
        host.release()
    }
}
