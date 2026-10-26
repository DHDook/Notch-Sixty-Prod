import Foundation

// E8 S6: the view model behind the routing and crossover editor. Pure value logic on a `SpeakerRoutingConfiguration`:
// templates, edits, validation messages and plotted responses. No Core Audio and no engine access; the view hands the
// finished configuration to the engine through `onCommit`. Plots call the same core filter design the graph stages use,
// so the plotted response equals the prediction at the device rate.

@MainActor
final class SpeakerRoutingEditorModel: ObservableObject {
    @Published private(set) var configuration: SpeakerRoutingConfiguration
    @Published var context: SpeakerRoutingContext

    /// Called after every edit with the new configuration. The view wires this to the engine.
    var onCommit: ((SpeakerRoutingConfiguration) -> Void)?

    init(
        configuration: SpeakerRoutingConfiguration = SpeakerRoutingConfiguration(enabled: false),
        context: SpeakerRoutingContext
    ) {
        self.configuration = configuration
        self.context = context
    }

    // MARK: Whole-configuration edits

    func replace(_ configuration: SpeakerRoutingConfiguration) {
        self.configuration = configuration
        onCommit?(configuration)
    }

    func setEnabled(_ enabled: Bool) {
        mutate { $0.enabled = enabled }
    }

    /// Builds a template into the configuration (keeping `enabled`). False when the inputs do not fit the template.
    @discardableResult
    func applyTemplate(
        _ template: SpeakerRoutingTemplate,
        mains: [SpeakerRoutingTemplate.Main],
        subs: [PhysicalOutputEndpoint] = [],
        crossoverHz: [Double] = []
    ) -> Bool {
        guard var built = template.build(mains: mains, subs: subs, crossoverHz: crossoverHz) else { return false }
        built.enabled = configuration.enabled
        replace(built)
        return true
    }

    // MARK: Speakers and ways

    func addSpeaker(name: String, source: RoutingSource, endpoint: PhysicalOutputEndpoint) {
        mutate { $0.speakers.append(RoutedSpeaker(
            name: name, source: source, ways: [RoutedWay(name: name, endpoint: endpoint)])) }
    }

    func removeSpeaker(_ id: UUID) {
        mutate { $0.speakers.removeAll { $0.id == id } }
    }

    func setSource(_ source: RoutingSource, speaker id: UUID) {
        mutateSpeaker(id) { $0.source = source }
    }

    /// Adds a way (up to `RoutedSpeaker.maxWays`). False at the limit or for an unknown speaker.
    @discardableResult
    func addWay(speaker id: UUID, endpoint: PhysicalOutputEndpoint) -> Bool {
        guard let speaker = configuration.speakers.first(where: { $0.id == id }),
              speaker.ways.count < RoutedSpeaker.maxWays else { return false }
        mutateSpeaker(id) { $0.ways.append(RoutedWay(name: "\($0.name) \($0.ways.count + 1)", endpoint: endpoint)) }
        return true
    }

    /// Removes a way; a speaker keeps at least one.
    @discardableResult
    func removeWay(_ wayID: UUID, speaker id: UUID) -> Bool {
        guard let speaker = configuration.speakers.first(where: { $0.id == id }), speaker.ways.count > 1 else { return false }
        mutateSpeaker(id) { $0.ways.removeAll { $0.id == wayID } }
        return true
    }

    func editWay(_ wayID: UUID, speaker id: UUID, _ change: (inout RoutedWay) -> Void) {
        mutateSpeaker(id) { speaker in
            guard let index = speaker.ways.firstIndex(where: { $0.id == wayID }) else { return }
            change(&speaker.ways[index])
        }
    }

    enum Edge { case highPass, lowPass }

    /// Sets (or with nil clears) one filter. A spec whose order the family does not offer snaps to the nearest order.
    func setFilter(_ spec: CrossoverCore.FilterSpec?, edge: Edge, way: UUID, speaker: UUID) {
        var fixed = spec
        if let s = spec, !s.family.orders.contains(s.order) {
            let orders = s.family.orders
            fixed?.order = orders.min { abs($0 - s.order) < abs($1 - s.order) } ?? s.order
        }
        editWay(way, speaker: speaker) {
            if edge == .highPass { $0.highPass = fixed } else { $0.lowPass = fixed }
        }
    }

    func addEQ(_ section: RoutingEQSection, way: UUID, speaker: UUID) {
        editWay(way, speaker: speaker) {
            if $0.eq.count < Int(N60_PEQ_MAX_SECTIONS) { $0.eq.append(section) }
        }
    }

    func removeEQ(at index: Int, way: UUID, speaker: UUID) {
        editWay(way, speaker: speaker) { if $0.eq.indices.contains(index) { $0.eq.remove(at: index) } }
    }

    // MARK: Matrix

    /// Sets the gain of the raw entry (source to output); adds it if absent.
    func setMatrixGain(source: RoutingSource, output: PhysicalOutputEndpoint, gain: Double) {
        mutate {
            if let index = $0.matrix.firstIndex(where: { $0.source == source && $0.output == output }) {
                $0.matrix[index].gain = gain
            } else {
                $0.matrix.append(RoutingMatrixEntry(source: source, output: output, gain: gain))
            }
        }
    }

    func removeMatrixEntry(source: RoutingSource, output: PhysicalOutputEndpoint) {
        mutate { $0.matrix.removeAll { $0.source == source && $0.output == output } }
    }

    /// One row of the matrix grid: each source against each output lane, with the gain a way or raw entry gives it.
    struct MatrixCell: Equatable {
        var source: RoutingSource
        var output: PhysicalOutputEndpoint
        /// Linear gain of a raw entry, nil when none. Way feeds are fixed at unity and shown, not edited here.
        var rawGain: Double?
        var fedByWay: Bool
    }

    var matrixSources: [RoutingSource] {
        (0..<max(0, context.programLanes)).map { RoutingSource.program($0) }
            + (0..<max(0, context.subwoofers)).map { RoutingSource.sub($0) }
    }

    var matrixCells: [[MatrixCell]] {
        let outputs = configuration.outputEndpoints
        return matrixSources.map { source in
            outputs.map { output in
                MatrixCell(
                    source: source, output: output,
                    rawGain: configuration.matrix.first { $0.source == source && $0.output == output }?.gain,
                    fedByWay: configuration.speakers.contains {
                        $0.source == source && $0.ways.contains { $0.endpoint == output }
                    })
            }
        }
    }

    // MARK: Validation

    var validation: SpeakerRoutingValidation { configuration.validate(in: context) }

    /// Plain-language lines for the validation result, errors first.
    var messages: [String] {
        let v = validation
        return v.errors.map(Self.describe) + v.warnings.map(Self.describe)
    }

    static func describe(_ error: SpeakerRoutingError) -> String {
        switch error {
        case .noSpeakers: return "Add at least one speaker."
        case .speakerWayCount(let speaker, let count):
            return "\(speaker) has \(count) ways; a speaker needs 1 to \(RoutedSpeaker.maxWays)."
        case .sourceOutOfRange(let source):
            return "\(sourceName(source)) is not available in the current layout."
        case .endpointReused(let endpoint):
            return "Output channel \(endpoint.channelIndex + 1) is used by more than one way."
        case .channelCap(let lanes):
            return "The routing needs \(lanes) lanes; the limit is \(SpeakerRoutingConfiguration.maxGraphLanes)."
        case .invalidFilter(let way, let reason):
            return "\(way): the filter \(reason) is not valid at this sample rate."
        case .invalidTrim(let way): return "\(way): trim must be between -60 and +24 dB."
        case .invalidDelay(let way): return "\(way): delay must be zero or more."
        case .invalidEQ(let way): return "\(way): an EQ section is out of range."
        case .invalidLimiter(let way): return "\(way): a limiter setting is out of range."
        case .matrixGainOutOfRange: return "A matrix gain is out of range."
        case .tooManyEntries(let endpoint):
            return "Output channel \(endpoint.channelIndex + 1) has more than \(N60_ROUTE_MAX_ENTRIES) feeds."
        case .invalidSampleRate: return "The device sample rate is not valid."
        }
    }

    static func describe(_ warning: SpeakerRoutingWarning) -> String {
        switch warning {
        case .bandGap(let speaker, let lower, let upper):
            return "\(speaker): nothing covers \(Int(lower)) to \(Int(upper)) Hz."
        case .bandOverlap(let speaker, let lower, let upper):
            return "\(speaker): ways overlap between \(Int(upper)) and \(Int(lower)) Hz."
        case .firRealisedAsIIR(let way):
            return "\(way): linear-phase is off in low-latency mode; it plays as its minimum-phase equivalent."
        case .unroutedSource(let source):
            return "\(sourceName(source)) feeds nothing."
        }
    }

    static func sourceName(_ source: RoutingSource) -> String {
        source.kind == .program ? "Program lane \(source.index + 1)" : "Subwoofer \(source.index + 1)"
    }

    // MARK: Plots

    /// Complex response of one way (crossover filters, trim and polarity) at `hz`. Driver EQ is not included, so
    /// the plot is the crossover prediction.
    func wayResponse(_ way: RoutedWay, atHz hz: Double) -> (re: Double, im: Double)? {
        var re = 1.0, im = 0.0
        do {
            for (spec, high) in [(way.highPass, true), (way.lowPass, false)] {
                guard let spec else { continue }
                let r = try CrossoverCore.design(spec, highPass: high, sampleRate: context.sampleRate)
                    .response(atHz: hz)
                (re, im) = (re * r.re - im * r.im, re * r.im + im * r.re)
            }
        } catch { return nil }
        let gain = pow(10, way.trimDB / 20) * (way.polarityInverted ? -1 : 1)
        return (re * gain, im * gain)
    }

    func wayMagnitudeDB(_ way: RoutedWay, atHz hz: Double) -> Double? {
        guard let r = wayResponse(way, atHz: hz) else { return nil }
        return 20 * log10(max(1e-12, (r.re * r.re + r.im * r.im).squareRoot()))
    }

    /// The complex sum of a speaker's ways, in dB.
    func summedMagnitudeDB(_ speaker: RoutedSpeaker, atHz hz: Double) -> Double? {
        var re = 0.0, im = 0.0
        for way in speaker.ways {
            guard let r = wayResponse(way, atHz: hz) else { return nil }
            re += r.re
            im += r.im
        }
        return 20 * log10(max(1e-12, (re * re + im * im).squareRoot()))
    }

    /// Log-spaced plot frequencies, 20 Hz to the lesser of 20 kHz and 0.45 of the rate.
    func plotFrequencies(points: Int = 200) -> [Double] {
        let top = min(20_000, 0.45 * context.sampleRate)
        let low = 20.0
        guard points > 1, top > low else { return [low] }
        return (0..<points).map { low * pow(top / low, Double($0) / Double(points - 1)) }
    }

    private func mutate(_ change: (inout SpeakerRoutingConfiguration) -> Void) {
        var next = configuration
        change(&next)
        guard next != configuration else { return }
        configuration = next
        onCommit?(next)
    }

    private func mutateSpeaker(_ id: UUID, _ change: (inout RoutedSpeaker) -> Void) {
        mutate {
            guard let index = $0.speakers.firstIndex(where: { $0.id == id }) else { return }
            change(&$0.speakers[index])
        }
    }
}
