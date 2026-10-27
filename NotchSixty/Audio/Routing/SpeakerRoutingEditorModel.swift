import Foundation

// E8 S6: the view model behind the routing and crossover editor. Pure value logic on a `SpeakerRoutingConfiguration`:
// templates, edits, validation messages and plotted responses. No Core Audio and no engine access; the view hands the
// finished configuration to the engine through `onCommit`. Plots call the same core filter design the graph stages use,
// so the plotted response equals the prediction at the device rate.

@MainActor
final class SpeakerRoutingEditorModel: ObservableObject {
    @Published private(set) var configuration: SpeakerRoutingConfiguration
    @Published var context: SpeakerRoutingContext

    /// E8 B3: linearisations taken off a way for the A side of an A/B, keyed by way. Session-only: the configuration
    /// holds nil while a way is bypassed, so nothing stale ever reaches a saved profile or the engine.
    @Published private(set) var bypassedLinearisations: [UUID: RoutedWayLinearisation] = [:]

    /// Called after every edit with the new configuration. The view wires this to the engine.
    var onCommit: ((SpeakerRoutingConfiguration) -> Void)?

    /// E8 A5: what the live session supplies besides the rate and lane counts. The profile's sub count is the floor of
    /// `context.subwoofers`; the lane names label new speakers; bass management gates the first/last subwoofer.
    private(set) var profileSubwoofers: Int
    private(set) var programLaneNames: [String] = []
    private(set) var bassManagementEnabled: Bool?

    init(
        configuration: SpeakerRoutingConfiguration = SpeakerRoutingConfiguration(enabled: false),
        context: SpeakerRoutingContext
    ) {
        self.configuration = configuration
        self.context = context
        self.profileSubwoofers = context.subwoofers
    }

    /// E8 A5: follows the live profile, layout and device rate without re-creating the model. Commits nothing.
    func updateContext(
        programLanes: Int, profileSubwoofers: Int, sampleRate: Double,
        programLaneNames: [String] = [], bassManagementEnabled: Bool? = nil
    ) {
        self.profileSubwoofers = profileSubwoofers
        self.programLaneNames = programLaneNames
        self.bassManagementEnabled = bassManagementEnabled
        var next = context
        next.programLanes = programLanes
        next.sampleRate = sampleRate
        next.subwoofers = max(profileSubwoofers, configuration.subwooferSourceCount)
        if next != context { context = next }
    }

    /// E8 A5: puts back the engine's configuration after a refused commit. Does not call `onCommit`; bypassed
    /// linearisations of ways that no longer exist are dropped.
    func revert(to configuration: SpeakerRoutingConfiguration) {
        self.configuration = configuration
        let ways = Set(configuration.speakers.flatMap { $0.ways.map(\.id) })
        bypassedLinearisations = bypassedLinearisations.filter { ways.contains($0.key) }
        refreshSubwoofers()
    }

    private func refreshSubwoofers() {
        let count = max(profileSubwoofers, configuration.subwooferSourceCount)
        if context.subwoofers != count { context.subwoofers = count }
    }

    // MARK: Whole-configuration edits

    func replace(_ configuration: SpeakerRoutingConfiguration) {
        self.configuration = configuration
        refreshSubwoofers()
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

    /// The template the current configuration still has the shape of (nil when customised or empty).
    var currentTemplate: SpeakerRoutingTemplate? { SpeakerRoutingTemplate.detect(configuration) }

    /// E8 A1: builds a template onto one device, assigning outputs in channel order (mains first, low way to high, then
    /// subs) with the template's default corners.
    @discardableResult
    func applyTemplate(_ template: SpeakerRoutingTemplate, deviceUID: String) -> Bool {
        var channel: UInt32 = 0
        func next() -> PhysicalOutputEndpoint {
            defer { channel += 1 }
            return PhysicalOutputEndpoint(deviceUID: deviceUID, channelIndex: channel)
        }
        let names = ["Left", "Right"]
        let mains = (0..<min(2, context.programLanes)).map { lane in
            SpeakerRoutingTemplate.Main(
                lane: lane, name: names[lane], endpoints: (0..<template.waysPerMain).map { _ in next() })
        }
        let subs = (0..<context.subwoofers).map { _ in next() }
        return applyTemplate(template, mains: mains, subs: subs, crossoverHz: template.defaultCrossoverHz)
    }

    // MARK: Speakers and ways

    func addSpeaker(name: String, source: RoutingSource, endpoint: PhysicalOutputEndpoint) {
        mutate { $0.speakers.append(RoutedSpeaker(
            name: name, source: source, ways: [RoutedWay(name: name, endpoint: endpoint)])) }
    }

    /// Removes a speaker. Refused for the last speaker while routing is enabled (the engine would refuse an enabled
    /// routing with no speakers); a subwoofer speaker goes through `removeSubwoofer` so the sub sources stay contiguous.
    @discardableResult
    func removeSpeaker(_ id: UUID) -> Bool {
        guard removeSpeakerBlockReason(id) == nil,
              let speaker = configuration.speakers.first(where: { $0.id == id }) else { return false }
        if speaker.source.kind == .sub { return removeSubwoofer(index: speaker.source.index) == .done }
        mutate { $0.speakers.removeAll { $0.id == id } }
        return true
    }

    func removeSpeakerBlockReason(_ id: UUID) -> String? {
        guard let speaker = configuration.speakers.first(where: { $0.id == id }) else { return "Unknown speaker." }
        if configuration.enabled, configuration.speakers.count == 1 {
            return "Turn off the routing matrix to remove the last speaker."
        }
        if speaker.source.kind == .sub { return subwooferRemoveBlockReason(index: speaker.source.index) }
        return nil
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

    // MARK: Driver linearisation (E8 B3)

    enum LinearisationState: Equatable { case none, active, bypassed }

    /// One selectable driver: a way and the speaker that owns it. Feeds the Measurement Lab way picker.
    struct DriverChoice: Identifiable, Equatable {
        var id: UUID { wayID }
        var speakerID: UUID
        var wayID: UUID
        var source: RoutingSource
        var title: String
    }

    var driverChoices: [DriverChoice] {
        configuration.speakers.flatMap { speaker in
            speaker.ways.map { way in
                DriverChoice(
                    speakerID: speaker.id, wayID: way.id, source: speaker.source,
                    title: [speaker.name, way.name].filter { !$0.isEmpty }.joined(separator: " / "))
            }
        }
    }

    static func driverChoices(_ configuration: SpeakerRoutingConfiguration) -> [DriverChoice] {
        let model = SpeakerRoutingEditorModel(configuration: configuration, context: SpeakerRoutingContext(
            programLanes: 2, subwoofers: 0, sampleRate: 48_000))
        return model.driverChoices
    }

    func linearisationState(_ wayID: UUID) -> LinearisationState {
        if bypassedLinearisations[wayID] != nil { return .bypassed }
        let linearised = configuration.speakers.contains { $0.ways.contains { $0.id == wayID && $0.linearisation != nil } }
        return linearised ? .active : .none
    }

    /// Stores a near-field measurement on a way (the explicit user action; captures never deploy themselves). A fresh
    /// apply replaces any bypassed one. False for an unknown way.
    @discardableResult
    func applyLinearisation(_ linearisation: RoutedWayLinearisation, way wayID: UUID) -> Bool {
        guard let speaker = speakerID(ofWay: wayID) else { return false }
        bypassedLinearisations[wayID] = nil
        editWay(wayID, speaker: speaker) { $0.linearisation = linearisation }
        return true
    }

    /// Takes the linearisation off a way for good (also forgetting a bypassed one).
    func removeLinearisation(way wayID: UUID) {
        guard let speaker = speakerID(ofWay: wayID) else { return }
        bypassedLinearisations[wayID] = nil
        editWay(wayID, speaker: speaker) { $0.linearisation = nil }
    }

    /// A/B: true plays the way without its linearisation (A), false restores it (B). The measurement is kept in the
    /// model while bypassed. No-op for a way that has none.
    func setLinearisationBypassed(_ bypassed: Bool, way wayID: UUID) {
        guard let speaker = speakerID(ofWay: wayID) else { return }
        if bypassed {
            guard let current = configuration.speakers.first(where: { $0.id == speaker })?
                .ways.first(where: { $0.id == wayID })?.linearisation else { return }
            bypassedLinearisations[wayID] = current
            editWay(wayID, speaker: speaker) { $0.linearisation = nil }
        } else if let kept = bypassedLinearisations[wayID] {
            bypassedLinearisations[wayID] = nil
            editWay(wayID, speaker: speaker) { $0.linearisation = kept }
        }
    }

    /// Applies the newest qualified Lab driver capture for a way, searching `sessions` newest first.
    @discardableResult
    func applyLabCapture(
        wayID: UUID, sessions: [SpeakerMeasurementLabSession]
    ) throws -> SpeakerMeasurementLabDriverCaptureResult {
        var failure: Error = SpeakerMeasurementLabDriverCaptureError.protocolRequired
        for session in sessions.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            do {
                let result = try SpeakerMeasurementLabDriverCaptureAdapter().analyze(session: session, wayID: wayID)
                _ = applyLinearisation(result.linearisation, way: wayID)
                return result
            } catch SpeakerMeasurementLabDriverCaptureError.protocolRequired {
                continue
            } catch { failure = error }
        }
        throw failure
    }

    private func speakerID(ofWay wayID: UUID) -> UUID? {
        configuration.speakers.first { $0.ways.contains { $0.id == wayID } }?.id
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
        case .invalidLinearisation(let way): return "\(way): the driver measurement for linearisation is not usable."
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
        case .linearisationSkipped(let way, let reason):
            switch reason {
            case .lowLatencyMode: return "\(way): driver linearisation is off in low-latency mode."
            case .latencyCap(let ms):
                return "\(way): driver linearisation skipped; it would add \(Int(ms)) ms of latency to every output."
            case .designFailed: return "\(way): driver linearisation could not be designed from this measurement."
            }
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
        // E8 A5: a linear-phase way plays the cascade's magnitude with the shared delay removed, so its drawn phase is zero.
        if way.realisation == .fir, way.highPass != nil || way.lowPass != nil {
            (re, im) = ((re * re + im * im).squareRoot(), 0)
        }
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
        refreshSubwoofers()
        onCommit?(next)
    }

    private func mutateSpeaker(_ id: UUID, _ change: (inout RoutedSpeaker) -> Void) {
        mutate {
            guard let index = $0.speakers.firstIndex(where: { $0.id == id }) else { return }
            change(&$0.speakers[index])
        }
    }
}


// MARK: - E8 A5: add speakers and subwoofers, reassign outputs, linear-phase choice

/// The result of an edit that can be refused for a reason the user can act on.
enum RoutingEditOutcome: Error, Equatable {
    case done
    case refused(String)
}

/// One selectable physical output: a device channel, named for the picker.
struct RoutingOutputChoice: Identifiable, Equatable {
    var endpoint: PhysicalOutputEndpoint
    var title: String
    var connected: Bool
    var id: PhysicalOutputEndpoint { endpoint }

    /// Every connected device's channels ("<Device> · Out n", up to `outputChannelCount`), then the current endpoint
    /// marked "not connected" when its device is absent or the channel is beyond the device's count.
    static func choices(devices: [AudioOutputDevice], current: PhysicalOutputEndpoint?) -> [RoutingOutputChoice] {
        var result: [RoutingOutputChoice] = devices.flatMap { device in
            (0..<device.outputChannelCount).map { channel in
                RoutingOutputChoice(
                    endpoint: PhysicalOutputEndpoint(deviceUID: device.uid, channelIndex: channel),
                    title: "\(device.name) · Out \(channel + 1)", connected: true)
            }
        }
        if let current, !result.contains(where: { $0.endpoint == current }) {
            result.append(RoutingOutputChoice(
                endpoint: current, title: "\(current.deviceUID) · Out \(current.channelIndex + 1) (not connected)",
                connected: false))
        }
        return result
    }
}

extension SpeakerRoutingEditorModel {
    enum EndpointMove: Equatable {
        case moved
        case swapped(UUID)
        case unchanged
    }

    enum RealisationChoice: Equatable { case iir, fir, mixed }

    // MARK: Free outputs

    /// The lowest channel of `deviceUID` below `channelCount` that no way and no raw matrix entry uses; nil when all are taken.
    func nextFreeEndpoint(deviceUID: String, channelCount: UInt32) -> PhysicalOutputEndpoint? {
        let used = Set(configuration.outputEndpoints.filter { $0.deviceUID == deviceUID }.map(\.channelIndex))
        return (0..<channelCount).first { !used.contains($0) }
            .map { PhysicalOutputEndpoint(deviceUID: deviceUID, channelIndex: $0) }
    }

    private func freeEndpoint(on device: AudioOutputDevice?) -> Result<PhysicalOutputEndpoint, RoutingEditOutcome> {
        guard let device else { return .failure(.refused("Select an output device first.")) }
        guard let endpoint = nextFreeEndpoint(deviceUID: device.uid, channelCount: device.outputChannelCount) else {
            return .failure(.refused("All \(device.outputChannelCount) outputs of \(device.name) are in use."))
        }
        return .success(endpoint)
    }

    /// Adds a way on the speaker's device (else the selected output) at the lowest free channel.
    @discardableResult
    func addWayOnFreeOutput(speaker id: UUID, devices: [AudioOutputDevice], selected: AudioOutputDevice?) -> RoutingEditOutcome {
        guard let speaker = configuration.speakers.first(where: { $0.id == id }) else { return .refused("Unknown speaker.") }
        guard speaker.ways.count < RoutedSpeaker.maxWays else {
            return .refused("A speaker can have at most \(RoutedSpeaker.maxWays) ways.")
        }
        let uid = speaker.ways.first?.endpoint.deviceUID
        let device = devices.first { $0.uid == uid } ?? selected
        switch freeEndpoint(on: device) {
        case .failure(let refusal): return refusal
        case .success(let endpoint): return addWay(speaker: id, endpoint: endpoint) ? .done : .refused("Could not add a way.")
        }
    }

    // MARK: Speakers

    /// The program lane a new speaker reads: the first no speaker reads, else lane 0.
    var nextSpeakerSource: RoutingSource {
        let read = Set(configuration.speakers.filter { $0.source.kind == .program }.map(\.source.index))
        return .program((0..<max(0, context.programLanes)).first { !read.contains($0) } ?? 0)
    }

    func newSpeakerName(for source: RoutingSource) -> String {
        var base: String?
        if programLaneNames.indices.contains(source.index), !programLaneNames[source.index].isEmpty {
            base = programLaneNames[source.index]
        } else if context.programLanes == 2, source.index < 2 {
            base = ["Left", "Right"][source.index]
        }
        if let base, !configuration.speakers.contains(where: { $0.name == base }) { return base }
        return "Speaker \(configuration.speakers.count + 1)"
    }

    /// Adds one unfiltered way on the selected output's lowest free channel.
    @discardableResult
    func addSpeakerOnFreeOutput(selected: AudioOutputDevice?) -> RoutingEditOutcome {
        guard context.programLanes > 0 else { return .refused("The program layout has no lanes.") }
        switch freeEndpoint(on: selected) {
        case .failure(let refusal): return refusal
        case .success(let endpoint):
            let source = nextSpeakerSource
            addSpeaker(name: newSpeakerName(for: source), source: source, endpoint: endpoint)
            return .done
        }
    }

    // MARK: Subwoofers

    var subwooferSpeakers: [RoutedSpeaker] { configuration.speakers.filter { $0.source.kind == .sub } }

    /// Why a sub cannot be added now (the engine's reason while routing is enabled), else nil.
    var subwooferAddBlockReason: String? {
        let count = configuration.subwooferSourceCount
        if count >= SubwooferLimit.graph {
            return "Sub \(count + 1) cannot be added: the limit is \(SubwooferLimit.graph) subwoofers."
        }
        if configuration.enabled, count == 0, bassManagementEnabled == false {
            return "It reads subwoofer sources, so bass management must be on."
        }
        return nil
    }

    func subwooferRemoveBlockReason(index: Int) -> String? {
        if configuration.enabled, bassManagementEnabled == true,
           configuration.speakers.filter({ $0.source.kind == .sub }).count <= 1,
           configuration.subwooferSourceCount <= 1 {
            return "Bass management is on but no speaker would read a subwoofer source."
        }
        return nil
    }

    /// Adds "Sub n", source `.sub(n - 1)`, one unfiltered way on the selected output's lowest free channel.
    @discardableResult
    func addSubwooferOnFreeOutput(selected: AudioOutputDevice?) -> RoutingEditOutcome {
        if let reason = subwooferAddBlockReason { return .refused(reason) }
        switch freeEndpoint(on: selected) {
        case .failure(let refusal): return refusal
        case .success(let endpoint):
            let index = configuration.subwooferSourceCount
            let name = "Sub \(index + 1)"
            mutate { $0.speakers.append(RoutedSpeaker(
                name: name, source: .sub(index), ways: [RoutedWay(name: name, endpoint: endpoint)])) }
            return .done
        }
    }

    /// Removes sub `index` (its speakers and raw feeds) and renumbers the higher subs down by one in speakers, matrix
    /// entries and the default "Sub n" names, so the sources stay contiguous.
    @discardableResult
    func removeSubwoofer(index: Int) -> RoutingEditOutcome {
        if let reason = subwooferRemoveBlockReason(index: index) { return .refused(reason) }
        func shifted(_ source: RoutingSource) -> RoutingSource {
            source.kind == .sub && source.index > index ? .sub(source.index - 1) : source
        }
        func renamed(_ name: String) -> String {
            guard name.hasPrefix("Sub "), let n = Int(name.dropFirst(4)), n - 1 > index else { return name }
            return "Sub \(n - 1)"
        }
        mutate {
            $0.speakers.removeAll { $0.source == .sub(index) }
            $0.matrix.removeAll { $0.source == .sub(index) }
            for s in $0.speakers.indices {
                $0.speakers[s].source = shifted($0.speakers[s].source)
                if $0.speakers[s].source.kind == .sub {
                    $0.speakers[s].name = renamed($0.speakers[s].name)
                    for w in $0.speakers[s].ways.indices { $0.speakers[s].ways[w].name = renamed($0.speakers[s].ways[w].name) }
                }
            }
            for m in $0.matrix.indices { $0.matrix[m].source = shifted($0.matrix[m].source) }
        }
        return .done
    }

    // MARK: Output reassignment

    /// Moves a way to `endpoint`. A way already there swaps places with it, in one edit. Raw matrix entries stay on
    /// their physical output, and each way keeps its filters, EQ and linearisation (the driver did not change).
    @discardableResult
    func setEndpoint(_ endpoint: PhysicalOutputEndpoint, way wayID: UUID, speaker id: UUID) -> EndpointMove {
        guard let current = configuration.speakers.first(where: { $0.id == id })?
            .ways.first(where: { $0.id == wayID })?.endpoint, current != endpoint else { return .unchanged }
        let other = configuration.speakers.flatMap(\.ways).first { $0.endpoint == endpoint }?.id
        mutate {
            for s in $0.speakers.indices {
                for w in $0.speakers[s].ways.indices {
                    let wayID2 = $0.speakers[s].ways[w].id
                    if wayID2 == wayID { $0.speakers[s].ways[w].endpoint = endpoint }
                    else if wayID2 == other { $0.speakers[s].ways[w].endpoint = current }
                }
            }
        }
        return other.map(EndpointMove.swapped) ?? .moved
    }

    // MARK: Linear phase

    /// A speaker's crossover realisation over its filtered ways; nil when none is filtered (a sub, a full-range speaker).
    func realisationChoice(_ speaker: RoutedSpeaker) -> RealisationChoice? {
        let filtered = speaker.ways.filter { $0.highPass != nil || $0.lowPass != nil }
        guard let first = filtered.first else { return nil }
        return filtered.allSatisfy { $0.realisation == first.realisation } ? (first.realisation == .fir ? .fir : .iir) : .mixed
    }

    /// Sets the realisation on all of a speaker's filtered ways, so their sum stays coherent.
    func setRealisation(_ realisation: RoutingRealisation, speaker id: UUID) {
        mutateSpeaker(id) { speaker in
            for w in speaker.ways.indices where speaker.ways[w].highPass != nil || speaker.ways[w].lowPass != nil {
                speaker.ways[w].realisation = realisation
            }
        }
    }

    /// The group delay a speaker's linear-phase ways share at the current rate (the compiler's value: the largest
    /// automatic choice), and whether the plan is two-band. nil when no way is linear phase.
    func linearPhaseLatency(_ speaker: RoutedSpeaker) -> (frames: Int, twoBand: Bool)? {
        let fir = speaker.ways.filter { $0.realisation == .fir && ($0.highPass != nil || $0.lowPass != nil) }
        guard !fir.isEmpty else { return nil }
        let rate = context.sampleRate
        var delay = 0
        for way in fir {
            guard let plan = try? CrossoverCore.linearPhasePlan(highPass: way.highPass, lowPass: way.lowPass, sampleRate: rate)
            else { return nil }
            delay = max(delay, plan.groupDelayFrames)
        }
        let twoBand = fir.contains {
            (try? CrossoverCore.linearPhasePlan(
                highPass: $0.highPass, lowPass: $0.lowPass, sampleRate: rate, groupDelayFrames: delay))?.twoBand == true
        }
        return (delay, twoBand)
    }
}
