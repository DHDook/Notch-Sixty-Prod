import Foundation

// E8 S5: the per-driver measurement tools, expressed on routed ways instead of the legacy bus modes. Control plane only;
// nothing here runs in an audio callback. The excitation is rendered through the same unified graph the way will play
// through (ROUTE, XOVER, DELAY, PROTECTION), so the crossover, the driver EQ, the delay and the limiter stay in the path.

extension RoutedWay {
    /// A measurement sweep must start this far above a way's high-pass corner and stop this far below its low-pass
    /// corner, so the driver is never excited near or below its protection corner.
    static let protectedGuardFactor = 1.5

    /// The highest high-pass corner in effect: the way's own, or an extra high-pass section in its EQ (the migrated
    /// tri-amp high way carries its upper high-pass there).
    var effectiveHighPassHz: Double? {
        let eqCorners = eq.filter { $0.type == 4 }.map(\.frequencyHz)
        return ([highPass?.cornerHz].compactMap { $0 } + eqCorners).max()
    }

    /// The band a protected excitation may cover, or nil when the way has too little room (under 1.7:1).
    func protectedPassband(sampleRate: Double) -> ClosedRange<Double>? {
        var low = 30.0
        var high = min(16_000.0, sampleRate * 0.42)
        if let corner = effectiveHighPassHz { low = max(low, corner * Self.protectedGuardFactor) }
        if let corner = lowPass?.cornerHz { high = min(high, corner / Self.protectedGuardFactor) }
        guard low.isFinite, high.isFinite, high > low * 1.7 else { return nil }
        return low...high
    }

    /// A way can be excited for measurement only when it is band-limited and limiter-protected.
    var isProtectedMeasurementCandidate: Bool {
        (highPass != nil || lowPass != nil || effectiveHighPassHz != nil) && limiter != nil
    }
}

extension RoutedSpeaker {
    /// Neighbouring ways ordered by band, for crossover-sum summaries (what the legacy bi-amp and tri-amp pair lists
    /// spelled out per bus).
    var adjacentWayPairs: [(lower: RoutedWay, upper: RoutedWay)] {
        let ordered = ways.sorted {
            ($0.effectiveHighPassHz ?? 0, $0.lowPass?.cornerHz ?? .infinity)
                < ($1.effectiveHighPassHz ?? 0, $1.lowPass?.cornerHz ?? .infinity)
        }
        return zip(ordered, ordered.dropFirst()).map { (lower: $0, upper: $1) }
    }
}

enum SpeakerRoutingProtectedExcitationError: Error, Equatable {
    case invalidOptions
    case invalidSampleRate
    case wayNotFound
    case wayNotProtected
    case excitationTooHot(Double)
    case invalidExcitation
    case invalidRouting
    case renderFailed
    case silentProtectedOutput
}

struct SpeakerRoutingProtectedExcitation: Equatable, Sendable {
    var wayID: UUID
    var sampleRate: Double
    var sourceFrameCount: Int
    var renderedSamples: [Float]
    var inputPeakDBFS: Double
    var renderedPeakDBFS: Double
    var passband: ClosedRange<Double>?
    /// The way exactly as it was rendered, for capture provenance.
    var way: RoutedWay

    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
}

struct SpeakerRoutingProtectedExcitationCompiler: Sendable {
    func compile(
        monoSamples: [Float],
        sampleRate: Double,
        routing: SpeakerRoutingConfiguration,
        wayID: UUID,
        options: SpeakerMeasurementLabProtectedExcitationOptions = .init()
    ) throws -> SpeakerRoutingProtectedExcitation {
        guard options.validate() else { throw SpeakerRoutingProtectedExcitationError.invalidOptions }
        guard sampleRate.isFinite, (16_000...384_000).contains(sampleRate) else {
            throw SpeakerRoutingProtectedExcitationError.invalidSampleRate
        }
        guard let way = routing.speakers.flatMap(\.ways).first(where: { $0.id == wayID }) else {
            throw SpeakerRoutingProtectedExcitationError.wayNotFound
        }
        guard way.isProtectedMeasurementCandidate else { throw SpeakerRoutingProtectedExcitationError.wayNotProtected }
        guard !monoSamples.isEmpty, monoSamples.allSatisfy(\.isFinite) else {
            throw SpeakerRoutingProtectedExcitationError.invalidExcitation
        }
        let peak = monoSamples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 1.0e-8 else { throw SpeakerRoutingProtectedExcitationError.invalidExcitation }
        let peakDBFS = 20 * log10(Double(peak))
        guard peakDBFS <= options.maximumInputPeakDBFS + 1.0e-6 else {
            throw SpeakerRoutingProtectedExcitationError.excitationTooHot(peakDBFS)
        }

        // One mono program lane feeding only the target way; its crossover, EQ, trim, polarity, delay and limiter stay.
        var isolated = way
        isolated.endpoint = PhysicalOutputEndpoint(deviceUID: "measurement", channelIndex: 0)
        let single = SpeakerRoutingConfiguration(
            enabled: true,
            speakers: [RoutedSpeaker(id: wayID, name: "Measurement", source: .program(0), ways: [isolated])])
        let base = UnifiedGraphConfiguration(sampleRate: sampleRate, lanes: [UnifiedGraphLane()])
        let rendered: [Float]
        do {
            let config = try SpeakerRoutingCompiler.compile(single, onto: base)
            let host = try UnifiedGraphHost(spec: try config.makeSpec())
            defer { host.release() }
            let flush = max(1, Int((options.flushSeconds * sampleRate).rounded(.up)))
            let total = monoSamples.count + flush
            let block = 512
            var output: [Float] = []
            output.reserveCapacity(total)
            var position = 0
            while position < total {
                let end = min(position + block, total)
                var chunk = [Float](repeating: 0, count: block)
                for index in position..<max(position, min(end, monoSamples.count)) { chunk[index - position] = monoSamples[index] }
                var planar = [[Float]](repeating: [Float](repeating: 0, count: block), count: Int(host.inputChannels))
                planar[0] = chunk
                let result = try host.processOffline(input: planar, frames: block)
                output += result[Int(host.outputChannels) - 1][0..<(end - position)]
                position = end
            }
            rendered = output
        } catch is SpeakerRoutingCompileError {
            throw SpeakerRoutingProtectedExcitationError.invalidRouting
        } catch {
            throw SpeakerRoutingProtectedExcitationError.renderFailed
        }
        guard rendered.allSatisfy(\.isFinite) else { throw SpeakerRoutingProtectedExcitationError.renderFailed }
        let renderedPeak = rendered.reduce(Float(0)) { max($0, abs($1)) }
        guard renderedPeak > 1.0e-9 else { throw SpeakerRoutingProtectedExcitationError.silentProtectedOutput }
        return SpeakerRoutingProtectedExcitation(
            wayID: wayID, sampleRate: sampleRate, sourceFrameCount: monoSamples.count, renderedSamples: rendered,
            inputPeakDBFS: peakDBFS, renderedPeakDBFS: 20 * log10(Double(renderedPeak)),
            passband: way.protectedPassband(sampleRate: sampleRate), way: way)
    }
}

extension SpeakerMeasurementLabCapabilityPlanner {
    /// The routed counterpart of the protected-driver readiness check: the way exists, is band-limited and has its
    /// limiter on.
    static func protectedWayReady(routing: SpeakerRoutingConfiguration?, wayID: UUID) -> Bool {
        guard let routing, routing.enabled,
              let way = routing.speakers.flatMap(\.ways).first(where: { $0.id == wayID }) else { return false }
        return way.isProtectedMeasurementCandidate
    }
}
