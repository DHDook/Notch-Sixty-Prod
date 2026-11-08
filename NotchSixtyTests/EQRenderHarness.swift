import XCTest
@testable import NotchSixty

/// E27 S3b: renders a sine through the production stereo EQ path offline. The configuration goes
/// through `StereoEQConfiguration.makeGraphSnapshot` (what `setEQBypassed`, A/B and audition all
/// publish), the unified-graph translator and `UnifiedGraphHost`, and a change is applied with
/// `UnifiedGraphHost.apply` while the stream runs, exactly as the engine's republish does.
enum EQRenderHarness {
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    static let block = 64

    static func spec(
        _ eq: StereoEQConfiguration, rate: Double, preampDB: Double = 0, audition: EQAuditionOverride? = nil,
        taps: UnifiedGraphAnalyserTaps? = nil
    ) throws -> UnifiedGraphSpec {
        let rendered = audition.map { eq.auditioned($0) } ?? eq
        var snapshot = try rendered.makeGraphSnapshot(
            sampleRate: rate,
            gainConfiguration: DSPGainConfiguration(inputPreampDB: preampDB, headroomAttenuationDB: 0, outputGainDB: 0),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        var configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        configuration.analyserTaps = taps
        return try configuration.makeSpec()
    }

    struct Result {
        /// Left output for the whole run, and the index of the first sample after the switch.
        var output: [Float]
        var switchIndex: Int
        var rate: Double
    }

    /// Plays `frequency` at `amplitude` through `initial`, switches to each following spec after
    /// `settleSeconds` apart (the last one runs `tailSeconds`), and returns the left output.
    static func render(
        rate: Double, frequency: Double = 1_000, amplitude: Float = 0.5012,
        specs: [UnifiedGraphSpec], settleSeconds: Double = 0.15, tailSeconds: Double = 0.15
    ) throws -> Result {
        let host = try UnifiedGraphHost(spec: specs[0])
        var output: [Float] = []
        var position = 0
        var firstSwitch = 0
        func run(_ seconds: Double) throws {
            let end = position + (Int(rate * seconds) / block + 1) * block
            while position < end {
                let chunk = (0..<block).map {
                    amplitude * Float(sin(2.0 * .pi * frequency * Double(position + $0) / rate))
                }
                output += try host.processOffline(input: [chunk, chunk], frames: block)[0]
                position += block
            }
        }
        try run(settleSeconds)
        for (index, spec) in specs.dropFirst().enumerated() {
            if index == 0 { firstSwitch = position }
            try host.apply(spec, linearFade: true)
            try run(index == specs.count - 2 ? tailSeconds : settleSeconds)
        }
        return Result(output: output, switchIndex: firstSwitch, rate: rate)
    }

    static func maxStep(_ x: ArraySlice<Float>) -> Double {
        var best = 0.0
        var previous: Float?
        for value in x {
            if let previous { best = max(best, Double(abs(value - previous))) }
            previous = value
        }
        return best
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    static func peakConfiguration(gainDB: Double, frequency: Double = 1_000, q: Double = 1.0) -> StereoEQConfiguration {
        StereoEQConfiguration(linkedBands: [EQBand(type: .peaking, frequencyHz: frequency, gainDB: gainDB, q: q)])
    }
}
