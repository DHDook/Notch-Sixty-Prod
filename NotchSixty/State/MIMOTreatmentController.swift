import Foundation

/// E19 S8: one speaker or sub the treatment can use, as the engine's running layout names it.
struct MIMOTreatmentSourceInfo: Equatable, Sendable {
    var source: MultichannelCalibrationSource
    /// Graph lane: program lanes first, then sub lanes.
    var lane: Int
    var name: String
    /// E19 S9: for a routed speaker, the names of the ways that play in the default treatment range (design note 10); empty when unrouted.
    var inBandWays: [String] = []
}

/// What the Room Treatment screen's controller needs from the engine. `AudioIOEngine` conforms in
/// `AudioIOEngine+MIMOTreatmentHost.swift`; tests pass a fake. Nothing here arms by itself: `requestArm` is the one user action
/// and keeps its gates (`MIMOGraphTreatment`), and live treatment keeps `LiveTreatmentArm` and the written permit path.
@MainActor
protocol MIMOTreatmentHost: AnyObject {
    var treatment: MIMOGraphTreatment { get }
    var sampleRate: Double? { get }
    func treatmentContext() -> MIMOGraphTreatment.Context
    func treatmentSources() -> [MIMOTreatmentSourceInfo]
    /// The graph the stage will join (headroom model, chain digest); nil when audio is not running.
    func treatmentGraphConfiguration() -> UnifiedGraphConfiguration?
    /// Stages the design, live when the graph is running (a restage disarms; it never arms).
    func stageTreatment(_ stage: UnifiedGraphMIMOStage, configuration: UnifiedGraphConfiguration) throws
    func issueTreatmentPermit(
        verification: MIMOTreatmentVerificationResult?, acceptance: MIMORoomTreatmentHardwareAcceptance?
    ) -> Result<MIMOGraphTreatment.Permit, MIMOTreatmentPermitRefusal>
    func requestTreatmentArm() async throws
    func disarmTreatment()
    /// The held stage readback; reading it resets nothing (E19 G27).
    func treatmentReadback() -> n60_mimo_readback?
    func hardwareAcceptance() -> MIMORoomTreatmentHardwareAcceptance?
    /// E19 S10: the active speaker routing (nil when unrouted). A routed session is designed per speaker, over its in-band ways.
    func treatmentRouting() -> SpeakerRoutingConfiguration?
    /// E19 S10 (G36): the raw per-way captures of the routed speakers, one per in-band way and seat.
    func treatmentWayCaptures() -> [MIMORoutedWayCapture]
}

extension MIMOTreatmentHost {
    func treatmentRouting() -> SpeakerRoutingConfiguration? { nil }
    func treatmentWayCaptures() -> [MIMORoutedWayCapture] { [] }
}

/// E19 S8: the Room Treatment screen's model. It turns the user's settings and the stored seat measurements into a design
/// request, runs the designer and the headroom checks, stages the result, shows the predicted decay per seat before and after,
/// asks for a permit (refusals shown by name) and forwards the Arm and Bypass buttons. Control plane, main actor.
@MainActor
final class MIMOTreatmentController: ObservableObject {
    struct SourceRow: Identifiable, Equatable {
        var id: Int { lane }
        let lane: Int
        let source: MultichannelCalibrationSource
        let name: String
        var included = true
        var supportLowHz = 25.0
        var supportHighHz = 150.0
        /// True once the user set the range; until then a design derives it from the captures' -10 dB point (G34).
        var supportEdited = false
        /// Ways of a routed speaker that receive the treatment delta; empty when unrouted. Other ways get exactly zero.
        var inBandWays: [String] = []
    }

    enum DecayTarget: Equatable {
        /// The room's 500 Hz to 1 kHz T30 clamped to 0.15 to 0.4 s (owner decision D2).
        case automatic
        case seconds(Double)
    }

    enum Phase: Equatable {
        case idle
        case designing
        case designed
        case failed(String)
    }

    struct SeatDecay: Identifiable, Equatable {
        var id: Int
        var name: String
        /// Median third-octave T30 (T20 when T30 is not reliable) from 25 to 160 Hz; nil when none was reliable.
        var beforeSeconds: Double?
        var afterSeconds: Double?
    }

    struct SourceReadout: Identifiable, Equatable {
        var id: Int
        var name: String
        var included: Bool
        /// The gain this source's output may add (dB), after the chain headroom budget.
        var headroomBudgetDB: Double?
        var designedPeakGainDB: Double?
        var designedThermalDB: Double?
        /// Live, since the stage was armed: worst delta over program power ratio (dB) and the peak delta (dBFS).
        var liveBoundRatioDB: Double?
        var livePeakDeltaDBFS: Double?
    }

    struct GateLine: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var passed: Bool
    }

    static let tauRangeMilliseconds = 0.0...20.0
    static let decayRangeSeconds = 0.05...2.0

    @Published private(set) var rows: [SourceRow] = []
    @Published var tauMilliseconds = MIMOTreatmentRealisationLimits.recommendedTauSeconds * 1_000
    @Published var decayTarget: DecayTarget = .automatic
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var seatDecays: [SeatDecay] = []
    @Published private(set) var readout: [SourceReadout] = []
    @Published private(set) var gates: [GateLine] = []
    @Published private(set) var designAdvice: [String] = []
    @Published private(set) var permitRefusals: [String] = []
    @Published private(set) var armMessage: String?
    @Published private(set) var designedDecaySeconds: Double?
    @Published private(set) var isArmed = false
    @Published private(set) var armStateLabel = "Off"

    private let host: MIMOTreatmentHost
    private let flags: FeatureFlags
    private let seatsProvider: () -> [MultichannelCalibrationSeat]
    private let baselineProvider: () -> [MultichannelCalibrationMeasurement]
    private let treatedProvider: () -> [MultichannelCalibrationMeasurement]
    private let limits: MIMOTreatmentRealisationLimits
    private let taps: Int
    private var designedSeatIDs: [UUID] = []
    private var designedSources: [MultichannelCalibrationSource] = []
    private var baselineLow: [[Float]] = []
    private var predictedLow: [[Float]] = []
    /// Sample rate of the decay analysis responses (the low rate times `analysisUpsample`).
    private var lowRate = 0.0
    private var analysisUpsample = 1
    private var designedBudgets: [Int: Double] = [:]
    /// Routed designs: graph lane of a speaker's source to its row in the stage (empty when unrouted).
    private var designedRoutedSlots: [Int: Int] = [:]
    private var designedPeaks: [Int: Double] = [:]
    private var designedThermal: [Int: Double] = [:]

    init(
        host: MIMOTreatmentHost, flags: FeatureFlags,
        seats: @escaping () -> [MultichannelCalibrationSeat],
        baseline: @escaping () -> [MultichannelCalibrationMeasurement],
        treated: @escaping () -> [MultichannelCalibrationMeasurement] = { [] },
        limits: MIMOTreatmentRealisationLimits = .standard, taps: Int = MIMOTreatmentRequest.defaultTaps
    ) {
        self.limits = limits
        self.taps = taps
        self.host = host
        self.flags = flags
        seatsProvider = seats
        baselineProvider = baseline
        treatedProvider = treated
    }

    var isAvailable: Bool { flags.isEnabled(.mimoTreatment) }

    /// The note for a bass time target below 10 ms (E19 G14): recommends 15 ms.
    var shortTauNote: String? { MIMOTreatmentRealisationLimits.shortTauNote(tau: tauMilliseconds / 1_000) }

    var canDesign: Bool { isAvailable && phase != .designing && rows.contains { $0.included } }
    /// Arm and Bypass work only with a permit for the staged design; the gates then decide the arm itself.
    var permitHeld: Bool { host.treatment.permit != nil }
    var canArm: Bool { isAvailable && permitHeld && !isArmed }
    var canBypass: Bool { isAvailable && isArmed }

    // MARK: Settings

    /// Rebuilds the source list from the running layout, keeping the user's edits for sources that remain.
    func refreshSources() {
        let measured = Set(baselineProvider().map(\.source))
        let infos = host.treatmentSources().filter { measured.contains($0.source) }.sorted { $0.lane < $1.lane }
        let old = Dictionary(uniqueKeysWithValues: rows.map { ($0.lane, $0) })
        rows = infos.map { info in
            if var existing = old[info.lane], existing.source == info.source {
                existing.inBandWays = info.inBandWays
                return existing
            }
            return SourceRow(lane: info.lane, source: info.source, name: info.name, inBandWays: info.inBandWays)
        }
    }

    func setIncluded(_ included: Bool, lane: Int) { update(lane) { $0.included = included } }
    func setSupport(lowHz: Double, highHz: Double, lane: Int) {
        update(lane) { $0.supportLowHz = lowHz; $0.supportHighHz = highHz; $0.supportEdited = true }
    }

    private func update(_ lane: Int, _ body: (inout SourceRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.lane == lane }) else { return }
        body(&rows[index])
    }

    func setTau(milliseconds: Double) {
        tauMilliseconds = min(max(milliseconds, Self.tauRangeMilliseconds.lowerBound), Self.tauRangeMilliseconds.upperBound)
    }

    // MARK: Design

    enum InputError: Error, Equatable, LocalizedError {
        case audioNotRunning
        case noSeats
        case noSources
        case sampleRateMismatch(measured: Double, engine: Double)
        case missingMeasurement(source: String, seat: String)
        case headroom(String)
        case plantModel(String)

        var errorDescription: String? {
            switch self {
            case .audioNotRunning: return "Start audio processing first: the design reads the output headroom from the running graph."
            case .noSeats: return "No included seat has measurements."
            case .noSources: return "Include at least one measured speaker or subwoofer."
            case .sampleRateMismatch(let measured, let engine):
                return String(format: "The seats were measured at %.1f kHz but audio runs at %.1f kHz. Re-measure at the running rate.", measured / 1_000, engine / 1_000)
            case .missingMeasurement(let source, let seat): return "\(source) has no measurement at \(seat)."
            case .headroom(let text): return text
            case .plantModel(let text): return "The downstream chain or programme feed could not be built: \(text)"
            }
        }
    }

    /// The decay target as a T60 for the request: the owner's D2 default from the room, or the user's value.
    static func automaticDecaySeconds(baselineByIR: [[Float]], sampleRate: Double) -> Double {
        var values: [Double] = []
        for ir in baselineByIR {
            guard let bands = try? MeasurementCore.analyzeDecay(
                impulseResponse: ir, sampleRate: sampleRate, bandsPerOctave: 1, minCentreHz: 500, maxCentreHz: 1_000) else { continue }
            values += bands.filter { $0.flags & UInt32(N60_MEASURE_DECAY_FLAG_T30_RANGE) == 0 && $0.t30Seconds > 0 }.map(\.t30Seconds)
        }
        guard !values.isEmpty else { return 0.3 }
        let sorted = values.sorted()
        return min(max(sorted[sorted.count / 2], 0.15), 0.4)
    }

    func design() async {
        guard isAvailable else { phase = .failed(MIMORoomTreatmentCoreDesignError.featureOff.localizedDescription); return }
        phase = .designing
        permitRefusals = []
        armMessage = nil
        do {
            try await runDesign()
            phase = .designed
        } catch {
            phase = .failed(Self.describe(error))
        }
        refreshReadout()
    }

    private func runDesign() async throws {
        guard let configuration = host.treatmentGraphConfiguration(), let rate = host.sampleRate else { throw InputError.audioNotRunning }
        let seats = seatsProvider().filter { $0.included && $0.weight > 0 }
        if let routing = host.treatmentRouting(), routing.enabled {
            try await runRoutedDesign(routing: routing, configuration: configuration, rate: rate, seats: seats)
            return
        }
        let measurements = baselineProvider()
        var active = rows
        guard !active.isEmpty else { throw InputError.noSources }
        guard !seats.isEmpty else { throw InputError.noSeats }
        if let off = measurements.first(where: { abs($0.sampleRate - rate) > 0.5 }) {
            throw InputError.sampleRateMismatch(measured: off.sampleRate, engine: rate)
        }
        // G33: the plant is the raw capture through the lane's known chain downstream of the stage, with the arrival onset
        // (G6); the prediction uses the real programme feed at the stage. G34: unedited ranges come from the -10 dB point.
        var raw: [[[Float]]] = []
        for row in active {
            var perSeat: [[Float]] = []
            for seat in seats {
                guard let found = measurements.last(where: { $0.seatID == seat.id && $0.source == row.source }),
                      !found.channel.impulseResponse.isEmpty
                else { throw InputError.missingMeasurement(source: row.name, seat: seat.name) }
                perSeat.append(found.channel.impulseResponse)
            }
            raw.append(perSeat)
        }
        let rowLanes = active.map(\.lane)
        let model: PlantModel
        do {
            model = try await Task.detached(priority: .userInitiated) {
                try Self.buildPlantModel(raw: raw, lanes: rowLanes, configuration: configuration, rate: rate)
            }.value
        } catch {
            throw InputError.plantModel(String(describing: error))
        }
        for (index, row) in active.enumerated() where !row.supportEdited {
            rows[index].supportLowHz = model.support[index].lowerBound
            rows[index].supportHighHz = model.support[index].upperBound
        }
        active = rows
        let floatPlants = model.plants
        var plants: [[MIMOTreatmentPlant?]] = []
        for (s, perSeat) in floatPlants.enumerated() {
            plants.append(perSeat.enumerated().map { MIMOTreatmentPlant(program: $1, injection: nil, arrivalSeconds: model.arrivals[s][$0]) })
        }
        let seatBaselines = (0..<seats.count).map { seat in Self.sum(floatPlants.map { $0[seat] }) }
        let decay: Double
        switch decayTarget {
        case .automatic: decay = Self.automaticDecaySeconds(baselineByIR: seatBaselines, sampleRate: rate)
        case .seconds(let seconds): decay = min(max(seconds, Self.decayRangeSeconds.lowerBound), Self.decayRangeSeconds.upperBound)
        }
        var request = MIMOTreatmentRequest(
            sampleRate: rate,
            sources: active.map {
                var spec = MIMOTreatmentSourceSpec()
                spec.excluded = !$0.included
                spec.supportLowHz = $0.supportLowHz
                spec.supportHighHz = $0.supportHighHz
                return spec
            },
            seats: seats.map { MIMOTreatmentSeatSpec(included: true, weight: $0.weight) }, plants: plants)
        request.tauSeconds = tauMilliseconds / 1_000
        request.decaySeconds = decay
        request.taps = taps
        let lanes = active.map(\.lane)
        do {
            request = try await MIMOGraphHeadroom.budgetedRequest(request, configuration: configuration, sourceLanes: lanes)
        } catch let failure as MIMOGraphHeadroom.Failure {
            throw InputError.headroom(Self.describe(failure))
        }
        let designRequest = request
        let designLimits = limits
        let result = try await Task.detached(priority: .userInitiated) {
            try MIMORoomTreatmentCoreDesigner.designUnchecked(designRequest, limits: designLimits)
        }.value
        var stage = try UnifiedGraphMIMOStage(filters: result.filters, sourceLanes: lanes)
        stage.supportRangesHz = active.flatMap { [$0.supportLowHz, $0.supportHighHz] }
        do {
            try await MIMOGraphHeadroom.verifyDesignedStage(configuration: configuration, stage: stage)
        } catch let failure as MIMOGraphHeadroom.Failure {
            throw InputError.headroom(Self.describe(failure))
        }
        try host.stageTreatment(stage, configuration: configuration)

        designedDecaySeconds = decay
        designAdvice = result.summary.advice
        designedSeatIDs = seats.map(\.id)
        designedRoutedSlots = [:]
        designedSources = active.map(\.source)
        designedBudgets = Dictionary(uniqueKeysWithValues: zip(lanes, request.sources.map(\.gainLimitDB)))
        designedPeaks = Dictionary(uniqueKeysWithValues: zip(lanes, result.summary.peakGainDB))
        designedThermal = Dictionary(uniqueKeysWithValues: zip(lanes, result.summary.thermalDB))
        try await predict(seatPlants: floatPlants, filters: result.filters, seats: seats, rate: rate, feeds: model.feeds)
    }

    /// E19 S10: the routed design. The planner (design note 10) turns the way captures into the request, the stage carries the
    /// speaker table, and the headroom check runs on every injection lane. Never arms; a failure leaves the previous stage alone.
    private func runRoutedDesign(
        routing: SpeakerRoutingConfiguration, configuration: UnifiedGraphConfiguration, rate: Double, seats: [MultichannelCalibrationSeat]
    ) async throws {
        guard !seats.isEmpty else { throw InputError.noSeats }
        let infos = host.treatmentSources()
        let programLanes = infos.filter { if case .speaker = $0.source { return true } else { return false } }.count
        let subwoofers = infos.count - programLanes
        func lane(_ speaker: RoutedSpeaker) -> Int { speaker.source.kind == .program ? speaker.source.index : programLanes + speaker.source.index }
        var settings = MIMORoutedTreatmentSettings()
        settings.tauSeconds = tauMilliseconds / 1_000
        settings.taps = taps
        for speaker in routing.speakers {
            guard let row = rows.first(where: { $0.lane == lane(speaker) }) else { continue }
            if !row.included { settings.excluded.insert(speaker.id) }
            if row.supportLowHz != 25 || row.supportHighHz != 150 { settings.supportOverrides[speaker.id] = row.supportLowHz...row.supportHighHz }
        }
        if settings.excluded.count == routing.speakers.count { throw InputError.noSources }
        var plan: MIMORoutedTreatmentPlan
        do {
            plan = try await MIMORoutedTreatmentPlanner.plan(
                routing: routing, sampleRate: rate, programLanes: programLanes, subwoofers: subwoofers, seats: seats,
                captures: host.treatmentWayCaptures(), settings: settings)
        } catch let refusal as MIMORoutedTreatmentRefusal {
            throw InputError.headroom(refusal.localizedDescription)
        }
        // Zero plants stand in for excluded speakers so every source has a row in the prediction.
        var floatPlants: [[[Float]]] = []
        for source in plan.request.plants {
            floatPlants.append(source.map { $0?.program ?? [] })
        }
        let longest = floatPlants.flatMap { $0 }.map(\.count).max() ?? 1
        floatPlants = floatPlants.map { $0.map { $0.isEmpty ? [Float](repeating: 0, count: max(longest, 1)) : $0 } }
        let seatBaselines = (0..<seats.count).map { seat in Self.sum(floatPlants.map { $0[seat] }) }
        let decay: Double
        switch decayTarget {
        case .automatic: decay = Self.automaticDecaySeconds(baselineByIR: seatBaselines, sampleRate: rate)
        case .seconds(let seconds): decay = min(max(seconds, Self.decayRangeSeconds.lowerBound), Self.decayRangeSeconds.upperBound)
        }
        plan.request.decaySeconds = decay
        let designRequest = plan.request
        let designLimits = limits
        let result = try await Task.detached(priority: .userInitiated) {
            try MIMORoomTreatmentCoreDesigner.designUnchecked(designRequest, limits: designLimits)
        }.value
        let firstOutputLane = programLanes + subwoofers
        var stage = try UnifiedGraphMIMOStage(filters: result.filters, routed: UnifiedGraphMIMOStage.Routed.make(
            routing: routing, plan: plan, firstOutputLane: firstOutputLane))
        stage.supportRangesHz = plan.speakers.flatMap { [$0.supportLowHz, $0.supportHighHz] }
        do {
            try await MIMOGraphHeadroom.verifyDesignedStage(configuration: configuration, stage: stage)
        } catch let failure as MIMOGraphHeadroom.Failure {
            throw InputError.headroom(Self.describe(failure))
        }
        try host.stageTreatment(stage, configuration: configuration)

        let lanes = plan.speakers.map(\.lane)
        designedRoutedSlots = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($0.element, $0.offset) })
        designedDecaySeconds = decay
        designAdvice = result.summary.advice
        designedSeatIDs = seats.map(\.id)
        designedSources = rows.filter { row in lanes.contains(row.lane) }.map(\.source)
        designedBudgets = Dictionary(uniqueKeysWithValues: zip(lanes, plan.speakers.map(\.gainLimitDB)))
        designedPeaks = Dictionary(uniqueKeysWithValues: zip(lanes, result.summary.peakGainDB))
        designedThermal = Dictionary(uniqueKeysWithValues: zip(lanes, result.summary.thermalDB))
        try await predict(seatPlants: floatPlants, filters: result.filters, seats: seats, rate: rate, feeds: nil)
    }

    /// Low-rate baseline and predicted seat responses for the decay readout and the verifier.
    /// Everything the unrouted design reads from the graph and the captures, built off the main actor.
    struct PlantModel: Sendable {
        var plants: [[[Float]]]
        var arrivals: [[Double?]]
        var support: [ClosedRange<Double>]
        /// The programme's response at the stage per source, at the graph rate.
        var feeds: [[Float]]
    }

    nonisolated static func buildPlantModel(
        raw: [[[Float]]], lanes: [Int], configuration: UnifiedGraphConfiguration, rate: Double
    ) throws -> PlantModel {
        let feeds = try MIMOUnroutedPlantModel.upstreamFeeds(of: configuration, lanes: lanes)
        var plants: [[[Float]]] = []
        var arrivals: [[Double?]] = []
        var support: [ClosedRange<Double>] = []
        for (index, lane) in lanes.enumerated() {
            let chain = MIMOUnroutedPlantModel.downstreamChain(of: configuration, lane: lane)
            let through = raw[index].map { MIMOUnroutedPlantModel.convolve($0, chain) }
            plants.append(through)
            arrivals.append(through.map { MIMOUnroutedPlantModel.arrivalSeconds(of: $0, sampleRate: rate) })
            support.append(MIMOUnroutedPlantModel.defaultSupportHz(captures: raw[index], sampleRate: rate))
        }
        return PlantModel(plants: plants, arrivals: arrivals, support: support, feeds: feeds)
    }

    /// Per-source filters at the low rate: the stage adds E on top of the tau-delayed direct path, and each source's lane
    /// carries its own feed at the stage, so source s plays tau-delay of u_s plus the sum over r of E(s,r) through u_r. With
    /// `feeds` nil every source carries the same unit feed.
    nonisolated static func predictedFilters(filters: MIMOTreatmentFilterSet, feeds: [[Float]]?, rate: Double) throws -> (feed: [[Float]], treated: [[Float]]) {
        let sources = filters.sourceCount
        let taps = filters.tapCount
        let tauIndex = Int((filters.tauSeconds * filters.lowRateHz).rounded())
        let unit: [Float] = [1]
        let low: [[Float]] = try (0..<sources).map { source in
            guard let feeds, source < feeds.count else { return unit }
            let decimated = MIMOUnroutedPlantModel.trimmed(try decimate(feeds[source], rate: rate))
            return Array(decimated.prefix(256))
        }
        var treated: [[Float]] = []
        for s in 0..<sources {
            var f = [Float](repeating: 0, count: max(taps, tauIndex + 1) + 256)
            for (t, v) in low[s].enumerated() { f[tauIndex + t] += v }
            for r in 0..<sources {
                let base = (s * sources + r) * taps
                let u = low[r]
                for t in 0..<taps {
                    let e = filters.taps[base + t]
                    if e == 0 { continue }
                    for (k, v) in u.enumerated() { f[t + k] += e * v }
                }
            }
            treated.append(f)
        }
        return (low, treated)
    }

    private func predict(
        seatPlants: [[[Float]]], filters: MIMOTreatmentFilterSet, seats: [MultichannelCalibrationSeat], rate: Double, feeds: [[Float]]?
    ) async throws {
        let factor = Self.analysisFactor(lowRateHz: filters.lowRateHz)
        lowRate = filters.lowRateHz * Double(factor)
        analysisUpsample = factor
        let sources = filters.sourceCount
        let seatCount = seats.count
        let (base, predicted) = try await Task.detached(priority: .userInitiated) { () throws -> ([[Float]], [[Float]]) in
            let (feed, perSource) = try Self.predictedFilters(filters: filters, feeds: feeds, rate: rate)
            var base: [[Float]] = []
            var predicted: [[Float]] = []
            for seat in 0..<seatCount {
                let lowPlants = try (0..<sources).map { try Self.decimate(seatPlants[$0][seat], rate: rate) }
                base.append(Self.upsample(try MeasurementCore.predictTreatedIR(plants: lowPlants, filters: feed), by: factor))
                predicted.append(Self.upsample(try MeasurementCore.predictTreatedIR(plants: lowPlants, filters: perSource), by: factor))
            }
            return (base, predicted)
        }.value
        baselineLow = base
        predictedLow = predicted
        let verified = MIMOTreatmentVerifier.verify(
            baseline: base, predicted: predicted, measured: nil, spatial: nil, sampleRate: lowRate)
        seatDecays = seats.enumerated().map { index, seat in
            SeatDecay(
                id: index, name: seat.name, beforeSeconds: Self.median(verified.baselineBands[safe: index]),
                afterSeconds: Self.median(verified.predictedBands[safe: index]))
        }
    }

    // MARK: Permit and arming

    /// Verifies the staged design (predicted decay, the treated repeat measurement when one exists, the seat-to-seat
    /// criteria) and asks the engine for a permit. Every refusal is listed by name; nothing arms.
    func requestPermit() {
        permitRefusals = []
        armMessage = nil
        guard host.treatment.stage != nil else { permitRefusals = [MIMOTreatmentPermitRefusal.noStagedDesign.reason]; return }
        let treated = treatedProvider()
        var measuredLow: [[Float]]?
        var spatial: MIMORoomTreatmentVerificationReport?
        if !treated.isEmpty, let rate = host.sampleRate {
            let seats = seatsProvider().filter { designedSeatIDs.contains($0.id) }
            let ordered = designedSeatIDs.compactMap { id in seats.first { $0.id == id } }
            let summed = ordered.map { seat in
                Self.sum(designedSources.compactMap { source in
                    treated.last { $0.seatID == seat.id && $0.source == source }?.channel.impulseResponse
                })
            }
            if summed.allSatisfy({ !$0.isEmpty }), let low = try? summed.map({ Self.upsample(try Self.decimate($0, rate: rate), by: analysisUpsample) }) {
                measuredLow = low
                spatial = try? MIMORoomTreatmentVerifier().verify(
                    sources: designedSources, seats: ordered, baselineMeasurements: baselineProvider(),
                    treatedMeasurements: treated, sampleRate: rate)
            }
        }
        let verification = MIMOTreatmentVerifier.verify(
            baseline: baselineLow, predicted: predictedLow, measured: measuredLow, spatial: spatial, sampleRate: lowRate)
        if case .failure(let refusal) = host.issueTreatmentPermit(verification: verification, acceptance: host.hardwareAcceptance()) {
            switch refusal {
            case .verificationFailed(let failures): permitRefusals = failures.map(\.reason)
            default: permitRefusals = [refusal.reason]
            }
        }
        refreshReadout()
    }

    func arm() async {
        armMessage = nil
        do { try await host.requestTreatmentArm() } catch { armMessage = Self.describe(error) }
        refreshReadout()
    }

    func bypass() {
        host.disarmTreatment()
        refreshReadout()
    }

    // MARK: Readout

    func refreshReadout() {
        let context = host.treatmentContext()
        let treatment = host.treatment
        isArmed = treatment.isArmed
        let readback = host.treatmentReadback()
        armStateLabel = Self.stateLabel(readback: readback, armed: treatment.isArmed)
        gates = [
            GateLine(name: "Audio running", passed: context.engineRunning),
            GateLine(name: "Design staged on the graph", passed: context.stageAttached),
            GateLine(name: "Output hard limit present", passed: context.hardLimitPresent),
            GateLine(name: "Engine lease held", passed: context.engineLeaseHeld),
            GateLine(name: "Not in video latency mode", passed: !context.videoLatencyMode),
            GateLine(name: "Permit valid for this design", passed: treatment.permit != nil && treatment.gateFailure(context) != .fingerprintMismatch),
        ]
        let ratios = readback?.boundRatios
        let peaks = readback?.deltaPeaks
        let live = (readback?.state ?? 0) != 0
        func db(_ value: Float?, _ scale: Double) -> Double? {
            guard live, let value, value > 0 else { return nil }
            return scale * log10(Double(value))
        }
        readout = rows.map { row in
            let slot = designedRoutedSlots[row.lane] ?? treatment.stage?.sourceLanes.firstIndex(of: row.lane)
            return SourceReadout(
                id: row.lane, name: row.name, included: row.included, headroomBudgetDB: designedBudgets[row.lane],
                designedPeakGainDB: designedPeaks[row.lane], designedThermalDB: designedThermal[row.lane],
                liveBoundRatioDB: slot.flatMap { db(ratios?[safe: $0], 10) },
                livePeakDeltaDBFS: slot.flatMap { db(peaks?[safe: $0], 20) })
        }
        if let lastRefusal = treatment.lastRefusal, armMessage == nil, !treatment.isArmed { armMessage = lastRefusal.localizedDescription }
    }

    static func stateLabel(readback: n60_mimo_readback?, armed: Bool) -> String {
        if let readback {
            if readback.faultLatched != 0 { return readback.faultReason == 2 ? "Fault: thermal budget" : "Fault: delta bound" }
            switch readback.state {
            case 1: return "Fading in"
            case 2: return "Armed"
            case 3: return "Fading out"
            default: break
            }
        }
        return armed ? "Armed" : "Off"
    }

    // MARK: Helpers

    static func describe(_ error: Error) -> String {
        if let failure = error as? MIMOGraphHeadroom.Failure { return describe(failure) }
        if let local = error as? LocalizedError, let text = local.errorDescription { return text }
        return String(describing: error)
    }

    static func describe(_ failure: MIMOGraphHeadroom.Failure) -> String {
        switch failure {
        case .chainNotBounded(let source, let stages):
            return "Output \(source + 1) has a stage whose peak gain cannot be bounded (\(stages.joined(separator: ", "))); the treatment cannot be sized for it."
        case .overBudget(let source, let needed):
            return String(format: "Output %d needs %.1f dB of output trim for this design, more than the allowance. Lower the support range or raise the output headroom.", source + 1, needed)
        case .graph(let text): return "The audio graph refused the treatment stage: \(text)"
        }
    }

    /// The decay analyser needs at least 8 kHz; the low rate is 2.7 to 3 kHz for the 44.1/48 families, so the bass
    /// responses are interpolated by the smallest integer that reaches it (the band of interest is far below the low rate).
    nonisolated static func analysisFactor(lowRateHz: Double) -> Int { max(1, Int((8_000 / max(lowRateHz, 1)).rounded(.up))) }

    nonisolated static func upsample(_ input: [Float], by factor: Int) -> [Float] {
        guard factor > 1, input.count > 1 else { return input }
        var out = [Float](repeating: 0, count: (input.count - 1) * factor + 1)
        for i in 0..<(input.count - 1) {
            for k in 0..<factor { out[i * factor + k] = input[i] + (input[i + 1] - input[i]) * Float(k) / Float(factor) }
        }
        out[out.count - 1] = input[input.count - 1]
        return out
    }

    nonisolated static func sum(_ responses: [[Float]]) -> [Float] {
        let length = responses.map(\.count).max() ?? 0
        var out = [Float](repeating: 0, count: length)
        for response in responses { for (i, v) in response.enumerated() { out[i] += v } }
        return out
    }

    nonisolated static func decimate(_ input: [Float], rate: Double) throws -> [Float] {
        let (factor, _) = try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: rate)
        var out = [Float](repeating: 0, count: input.count / factor + 2)
        var written: UInt64 = 0
        let status = input.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer {
                n60_mimo_decimate(rate, source.baseAddress, UInt64(source.count), $0.baseAddress, UInt64($0.count), &written)
            }
        }
        guard status == N60_MIMO_OK else { throw MIMORoomTreatmentCoreDesignError.core(status) }
        return Array(out.prefix(Int(written)))
    }

    private static func median(_ bands: [MIMOTreatmentDecayBand]?) -> Double? {
        let values = (bands ?? []).compactMap(\.seconds).sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
