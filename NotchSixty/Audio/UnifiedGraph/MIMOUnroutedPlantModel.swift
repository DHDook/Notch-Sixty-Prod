import Accelerate
import Foundation

// E19 S8 remainder (G33, G34): the unrouted treatment's plant model, built from the published graph configuration.
//
// - Downstream chain (design note 2): the linear stages after the MIMO stage of one lane, as taps at the graph rate: the
//   speaker-feed gain and polarity, the output trim, the lane delay (including the calibration delay and a sub's delay) and,
//   on a two-lane graph, the room correction and speaker-IR convolvers. The measured plant is the raw per-output capture
//   convolved with this chain.
// - Upstream feeds: the programme's small-signal response from the graph input to each lane at the stage, rendered offline
//   from the same configuration with the downstream terms reset. Bass management, crossovers and EQ make the feeds unequal,
//   so the prediction uses them instead of one equal feed on every source.
// - Arrival onset (G6): the first sample of a plant that reaches a fraction of its peak.
// - Default support (G34): from the capture's -10 dB point.
//
// Control plane only: allocates and renders offline (about 0.5 s of audio), so it runs off the main actor. Never on an audio
// callback; it publishes, stages and arms nothing.
enum MIMOUnroutedPlantModel {
    /// Fraction of a plant's peak that marks the direct arrival (-20 dB).
    static let onsetFraction: Float = 0.1
    static let feedSeconds = 0.5
    static let impulseAmplitude: Float = 0.05

    // MARK: Downstream chain

    /// The linear chain of graph lane `lane` (program lanes first, then subs) after the MIMO stage. Always at least one tap.
    static func downstreamChain(of configuration: UnifiedGraphConfiguration, lane: Int) -> [Float] {
        let rate = configuration.sampleRate
        var gain: Float = 1
        var delay = 0.0
        if lane < configuration.lanes.count {
            let spec = configuration.lanes[lane]
            gain = spec.outputGain
            if spec.polarityInverted { gain = -gain }
            let base = spec.fractionalDelayFrames
                ?? (spec.delayMilliseconds * 0.001 * rate).rounded() + Double(spec.delayFrames)
            delay = base + spec.calibrationDelayFrames
        } else if let subs = configuration.bassManagement?.subwoofers, lane - configuration.lanes.count < subs.count {
            delay = (subs[lane - configuration.lanes.count].delayMilliseconds * 0.001 * rate).rounded()
        }
        gain *= configuration.outputProtection?.trimGain(lane: lane) ?? 1
        var chain = fractionalDelay(delay, gain: gain)
        if lane < 2, configuration.lanes.count == 2 {
            for program in [configuration.stereoStages.roomFIR, configuration.stereoStages.speakerIR] {
                guard let program else { continue }
                let taps = lane == 1 ? (program.right ?? program.left) : program.left
                if !taps.isEmpty { chain = convolve(chain, taps) }
            }
        }
        return chain
    }

    /// A delay of `frames` (linear interpolation of the fraction) with a gain.
    static func fractionalDelay(_ frames: Double, gain: Float) -> [Float] {
        let delay = max(0, frames.isFinite ? frames : 0)
        let whole = Int(delay.rounded(.down))
        let fraction = Float(delay - Double(whole))
        var taps = [Float](repeating: 0, count: whole + (fraction > 1e-6 ? 2 : 1))
        taps[whole] = gain * (1 - fraction)
        if fraction > 1e-6 { taps[whole + 1] = gain * fraction }
        return taps
    }

    /// Full linear convolution, by FFT when the product is large.
    static func convolve(_ a: [Float], _ b: [Float]) -> [Float] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let count = a.count + b.count - 1
        if min(a.count, b.count) <= 32 {
            let (short, long) = a.count <= b.count ? (a, b) : (b, a)
            var out = [Float](repeating: 0, count: count)
            for (index, weight) in short.enumerated() where weight != 0 {
                for t in 0..<long.count { out[index + t] += weight * long[t] }
            }
            return out
        }
        var size = 1
        while size < count { size <<= 1 }
        let log2n = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        func spectrum(_ input: [Float]) -> ([Float], [Float]) {
            var padded = input + [Float](repeating: 0, count: size - input.count)
            var re = [Float](repeating: 0, count: size / 2), im = [Float](repeating: 0, count: size / 2)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    padded.withUnsafeMutableBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            return (re, im)
        }
        var (ar, ai) = spectrum(a)
        let (br, bi) = spectrum(b)
        // The packed real transform keeps DC in realp[0] and Nyquist in imagp[0]; both multiply as real numbers.
        let dc = ar[0] * br[0], nyquist = ai[0] * bi[0]
        for k in 0..<(size / 2) {
            let re = ar[k] * br[k] - ai[k] * bi[k]
            let im = ar[k] * bi[k] + ai[k] * br[k]
            ar[k] = re; ai[k] = im
        }
        ar[0] = dc; ai[0] = nyquist
        var out = [Float](repeating: 0, count: size)
        ar.withUnsafeMutableBufferPointer { r in
            ai.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(size / 2))
                    }
                }
            }
        }
        // Each forward real transform carries a factor 2 and the inverse a factor size.
        var scale = 1 / Float(size * 4)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(size))
        return Array(out.prefix(count))
    }

    // MARK: Upstream feeds

    /// The configuration with every term downstream of the MIMO stage reset, so a render shows the feed at the stage.
    static func upstreamConfiguration(of configuration: UnifiedGraphConfiguration) -> UnifiedGraphConfiguration {
        var up = configuration
        up.mimo = nil
        // E19 G46: a routed graph's feed at the stage is on the source lanes, before ROUTE, so a render stops there.
        up.routing = nil
        up.deltaAudition = false
        up.stereoStages.roomFIR = nil
        up.stereoStages.speakerIR = nil
        up.outputProtection = nil
        for index in up.lanes.indices {
            up.lanes[index].outputGain = 1
            up.lanes[index].polarityInverted = false
            up.lanes[index].delayMilliseconds = 0
            up.lanes[index].delayFrames = 0
            up.lanes[index].fractionalDelayFrames = nil
            up.lanes[index].calibrationDelayFrames = 0
        }
        if var bass = up.bassManagement {
            for index in bass.subwoofers.indices { bass.subwoofers[index].delayMilliseconds = 0 }
            up.bassManagement = bass
        }
        return up
    }

    /// The programme feed at the stage of each of `lanes`: a unit impulse on every graph input rendered through the upstream
    /// configuration. Offline; throws when the graph cannot be built.
    static func upstreamFeeds(of configuration: UnifiedGraphConfiguration, lanes: [Int]) throws -> [[Float]] {
        let up = upstreamConfiguration(of: configuration)
        let host = try UnifiedGraphHost(spec: try up.makeSpec())
        defer { host.release() }
        let block = 512
        let frames = (Int(feedSeconds * up.sampleRate) + block - 1) / block * block
        var out = [[Float]](repeating: [], count: Int(host.outputChannels))
        var position = 0
        while position < frames {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: Int(host.inputChannels))
            if position == 0 { for channel in 0..<input.count { input[channel][0] = impulseAmplitude } }
            let rendered = try host.processOffline(input: input, frames: block)
            for lane in 0..<rendered.count { out[lane] += rendered[lane] }
            position += block
        }
        return lanes.map { lane in
            guard lane < out.count else { return [0] }
            return trimmed(out[lane].map { $0 / impulseAmplitude })
        }
    }

    /// Drops the silent tail; keeps at least one sample.
    static func trimmed(_ response: [Float]) -> [Float] {
        let peak = response.map { abs($0) }.max() ?? 0
        guard peak > 0 else { return [0] }
        var end = response.count
        while end > 1, abs(response[end - 1]) < peak * 1e-6 { end -= 1 }
        return Array(response[..<end])
    }

    // MARK: Arrival and support

    /// Onset of the direct sound in seconds (G6): the first sample at or above `onsetFraction` of the peak. nil for silence.
    static func arrivalSeconds(of plant: [Float], sampleRate: Double) -> Double? {
        let peak = plant.map { abs($0) }.max() ?? 0
        guard peak > 0, let index = plant.firstIndex(where: { abs($0) >= peak * onsetFraction }) else { return nil }
        return Double(index) / sampleRate
    }

    /// Default support (G34): the low edge from the median -10 dB point of the seat captures (15 Hz when none falls that far),
    /// the high edge the planner's 150 Hz.
    static func defaultSupportHz(captures: [[Float]], sampleRate: Double) -> ClosedRange<Double> {
        let window = MIMORoutedTreatmentPlanner.defaultSupportHz
        let points = captures.map { MIMORoutedTreatmentPlanner.minusTenDBPoint(of: $0, sampleRate: sampleRate) }.sorted()
        guard !points.isEmpty else { return window }
        let low = min(max(points[points.count / 2], window.lowerBound), 60)
        return low...window.upperBound
    }
}
