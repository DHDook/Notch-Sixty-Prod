import CryptoKit
import Foundation

// E19 S9 (design note 10, design side): turns a `SpeakerRoutingConfiguration` plus the raw per-way captures into a
// `MIMOTreatmentRequest` for the existing designer. Each `RoutedSpeaker` is one MIMO source, whatever its way count. The
// program plant of a speaker at a seat is the sum over all its ways of (raw way IR through that way's chain); the injection
// plant is the same sum over the in-band ways only (design note 10, "Plants"). The way chain (ROUTE, XOVER, DRIVER_FIR,
// DELAY, per-way limiter latency) is measured by rendering the compiled routed graph, so it cannot disagree with the engine.
//
// Control plane only: allocates and renders offline (about 0.5 s of audio per speaker, up to 192k floats per lane at 384 kHz), so `plan` must be called off the main actor (S10); `digest(of:)` is cheap enough for the poll tick. Never on an audio callback. Nothing here
// publishes a stage, arms or widens an authorisation; the routed stage itself is E19 S10.

/// One raw way capture: the driver's impulse response at a seat with the way played alone and every correction bypassed.
struct MIMORoutedWayCapture: Equatable, Sendable {
    var speakerID: UUID
    var wayID: UUID
    var seatID: UUID
    var sampleRate: Double
    var impulseResponse: [Float]
}

/// A refusal that names the speaker, way or seat so a screen can say what to fix.
enum MIMORoutedTreatmentRefusal: Error, Equatable, LocalizedError {
    case noSpeakers
    case sourceShared(first: String, second: String)
    case noInBandWay(speaker: String)
    case tooManyInBandWays(speaker: String, count: Int)
    case missingWayCapture(speaker: String, way: String, seat: String)
    case supportRangeInvalid(speaker: String, lowHz: Double, highHz: Double)
    case headroom(speaker: String, way: String, budgetDB: Double)
    case sampleRateMismatch(way: String, captured: Double, engine: Double)
    case chainUnavailable(speaker: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noSpeakers: return "The routing has no speakers to treat."
        case .sourceShared(let first, let second):
            return "\(first) and \(second) share one source. Treat them as ways of one speaker, or give each its own source."
        case .noInBandWay(let speaker):
            return "\(speaker) has no way that plays in the treatment range. Exclude it or change its crossover."
        case .tooManyInBandWays(let speaker, let count):
            return "\(speaker) has \(count) ways in the treatment range; at most \(MIMORoutedTreatmentPlanner.maxInBandWays) are supported."
        case .missingWayCapture(let speaker, let way, let seat):
            return "\(speaker), way \(way): no raw capture at \(seat). Measure this way at every included seat."
        case .supportRangeInvalid(let speaker, let low, let high):
            return "\(speaker): the treatment range \(Int(low))-\(Int(high)) Hz is too narrow."
        case .headroom(let speaker, let way, let budget):
            return "\(speaker), way \(way): no headroom for treatment (budget \(String(format: "%.1f", budget)) dB). Lower the way trim or raise its limiter."
        case .sampleRateMismatch(let way, let captured, let engine):
            return "Way \(way) was captured at \(Int(captured)) Hz but the engine runs at \(Int(engine)) Hz. Measure again."
        case .chainUnavailable(let speaker, let reason): return "\(speaker): the way chain could not be modelled (\(reason))."
        }
    }
}

/// What the screen shows for one routed speaker.
struct MIMORoutedSpeakerPlan: Equatable, Sendable {
    var speakerID: UUID
    var name: String
    /// Graph lane of the speaker's source (program lanes first, then sub lanes).
    var lane: Int
    var included: Bool
    var inBandWayIDs: [UUID]
    var inBandWayNames: [String]
    var supportLowHz: Double
    var supportHighHz: Double
    /// Effort falls 12 dB/octave below this corner (the highest, over in-band ways, of the high-pass and the measured -10 dB point).
    var excursionCornerHz: Double
    /// The most the delta's row gain may reach: the lowest per-way budget (ceiling less 3 dB trim allowance less the way's gain).
    var gainLimitDB: Double
    /// Per in-band way: its budget in dB.
    var wayBudgetsDB: [Double]
}

struct MIMORoutedTreatmentPlan: Sendable {
    var speakers: [MIMORoutedSpeakerPlan]
    var request: MIMOTreatmentRequest
    /// Graph lanes of the sources, in request order.
    var sourceLanes: [Int]
    /// Outputs fed only by raw matrix entries: not sources, delta exactly zero ("add as a speaker to include").
    var matrixOnlyOutputs: [PhysicalOutputEndpoint]
    /// The largest in-band way count of any included speaker (the D3 class field).
    var inBandWaysPerSpeaker: Int
    /// The routed part of the permit fingerprint.
    var digest: String
}

struct MIMORoutedTreatmentSettings: Sendable {
    /// User edits by speaker; speakers without an entry use the defaults from their ways.
    var excluded: Set<UUID> = []
    var supportOverrides: [UUID: ClosedRange<Double>] = [:]
    var tauSeconds = MIMOTreatmentRealisationLimits.recommendedTauSeconds
    var decaySeconds = 0.3
    var taps = MIMOTreatmentRequest.defaultTaps
}

enum MIMORoutedTreatmentPlanner {
    static let maxInBandWays = 4
    /// A way whose high-pass is at least this and which is at least `predictedRejectionDB` down below 200 Hz needs no capture.
    static let predictedChainMinHighPassHz = 400.0
    static let predictedRejectionDB = 40.0
    static let defaultSupportHz = 15.0...150.0
    static let impulseAmplitude: Float = 0.05
    /// Chain impulse response length rendered per speaker, before delays.
    static let chainSeconds = 0.5

    // MARK: In-band selection (note 10, Q7)

    /// The ways whose passband overlaps `lowHz...highHz`: high-pass corner (0 when none) below `highHz` and low-pass corner
    /// (unbounded when none) above `lowHz`. Order of `speaker.ways` is kept.
    static func inBandWays(of speaker: RoutedSpeaker, lowHz: Double, highHz: Double) -> [RoutedWay] {
        speaker.ways.filter { way in
            let passLow = way.highPass?.cornerHz ?? 0
            let passHigh = way.lowPass?.cornerHz ?? .infinity
            return passLow < highHz && passHigh > lowHz
        }
    }

    /// The largest in-band way count over the routing's speakers for the default window, for the permit's configuration class.
    static func inBandWayCount(of routing: SpeakerRoutingConfiguration) -> Int {
        routing.speakers.map { inBandWays(of: $0, lowHz: defaultSupportHz.lowerBound, highHz: defaultSupportHz.upperBound).count }.max() ?? 1
    }

    // MARK: Digest

    /// The routed fields of the fingerprint (note 10): speaker-to-way map, every ROUTE entry, every way's crossover parameters,
    /// linearisation capture (the DRIVER_FIR source), delay, trim, polarity, EQ, limiter and endpoint. Names and ids are left out,
    /// so a rename does not disarm; any audible edit does. Master volume is not part of the routing.
    static func digest(of routing: SpeakerRoutingConfiguration) -> String {
        var stripped = routing
        for s in stripped.speakers.indices {
            stripped.speakers[s].id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            stripped.speakers[s].name = ""
            for w in stripped.speakers[s].ways.indices {
                stripped.speakers[s].ways[w].id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
                stripped.speakers[s].ways[w].name = ""
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(stripped)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Planning

    /// Builds the request. `seats` are the included seats (weights as the controller passes them). `captures` hold every raw way
    /// capture; an in-band way needs one at every included seat (Q9). Throws a named refusal; never returns a partial plan.
    static func plan(
        routing: SpeakerRoutingConfiguration, sampleRate: Double, programLanes: Int, subwoofers: Int,
        seats: [MultichannelCalibrationSeat], captures: [MIMORoutedWayCapture], settings: MIMORoutedTreatmentSettings = .init()
    ) async throws -> MIMORoutedTreatmentPlan {
        guard !routing.speakers.isEmpty else { throw MIMORoutedTreatmentRefusal.noSpeakers }
        func label(_ s: RoutedSpeaker) -> String { s.name.isEmpty ? s.id.uuidString : s.name }
        func label(_ w: RoutedWay) -> String { w.name.isEmpty ? w.id.uuidString : w.name }
        func lane(_ source: RoutingSource) -> Int { source.kind == .program ? source.index : programLanes + source.index }
        for (index, speaker) in routing.speakers.enumerated() {
            if let other = routing.speakers[..<index].first(where: { $0.source == speaker.source }) {
                throw MIMORoutedTreatmentRefusal.sourceShared(first: label(other), second: label(speaker))
            }
        }
        let seats = seats.filter { $0.included && $0.weight > 0 }
        var base = UnifiedGraphConfiguration(sampleRate: sampleRate, lanes: [UnifiedGraphLane](repeating: UnifiedGraphLane(), count: programLanes))
        if subwoofers > 0 {
            base.bassManagement = UnifiedGraphBassManagement(
                lfeLane: nil, subwoofers: [UnifiedGraphSubwoofer](repeating: UnifiedGraphSubwoofer(), count: subwoofers))
        }
        let full: UnifiedGraphConfiguration
        do { full = try SpeakerRoutingCompiler.compile(routing, onto: base) } catch {
            throw MIMORoutedTreatmentRefusal.chainUnavailable(speaker: "routing", reason: String(describing: error))
        }
        let fullOutputs = full.routing?.outputs ?? []
        let target = fullOutputs.map { latencyFrames(of: $0, sampleRate: sampleRate) }.max() ?? 0
        let spec: UnifiedGraphSpec
        do { spec = try full.makeSpec() } catch {
            throw MIMORoutedTreatmentRefusal.chainUnavailable(speaker: "routing", reason: String(describing: error))
        }
        let headrooms = await HeadroomRecompute.run(spec: spec, laneCount: Int(spec.outputChannels), strict: false, trimsDB: [:])
        let endpoints = routing.outputEndpoints
        let firstOutputLane = programLanes + subwoofers
        func ceilingDB(of way: RoutedWay) -> Double {
            var ceiling = 0.0
            if let index = endpoints.firstIndex(of: way.endpoint), let result = headrooms.first(where: { $0.lane == firstOutputLane + index }) {
                ceiling = result.ceilingDB
            }
            if let limiter = way.limiter { ceiling = min(ceiling, limiter.ceilingDB) }
            return ceiling
        }

        var speakerPlans: [MIMORoutedSpeakerPlan] = []
        var sources: [MIMOTreatmentSourceSpec] = []
        var plants: [[MIMOTreatmentPlant?]] = []
        for speaker in routing.speakers {
            let name = label(speaker)
            let included = !settings.excluded.contains(speaker.id)
            let window = settings.supportOverrides[speaker.id] ?? defaultSupportHz
            var plan = MIMORoutedSpeakerPlan(
                speakerID: speaker.id, name: name, lane: lane(speaker.source), included: included, inBandWayIDs: [], inBandWayNames: [],
                supportLowHz: window.lowerBound, supportHighHz: window.upperBound, excursionCornerHz: 0, gainLimitDB: 9, wayBudgetsDB: [])
            let inBand = inBandWays(of: speaker, lowHz: window.lowerBound, highHz: window.upperBound)
            plan.inBandWayIDs = inBand.map(\.id)
            plan.inBandWayNames = inBand.map(label)
            guard included else {
                var spec = MIMOTreatmentSourceSpec()
                spec.excluded = true
                sources.append(spec)
                plants.append([MIMOTreatmentPlant?](repeating: nil, count: seats.count))
                speakerPlans.append(plan)
                continue
            }
            guard !inBand.isEmpty else { throw MIMORoutedTreatmentRefusal.noInBandWay(speaker: name) }
            guard inBand.count <= maxInBandWays else {
                throw MIMORoutedTreatmentRefusal.tooManyInBandWays(speaker: name, count: inBand.count)
            }
            let chains = try renderChains(
                of: speaker, name: name, sampleRate: sampleRate, offsetFrames: max(0, target - miniTarget(of: speaker, sampleRate: sampleRate)))
            // Captures per way and seat; an in-band way needs all of them.
            func capture(_ way: RoutedWay, _ seat: MultichannelCalibrationSeat) -> MIMORoutedWayCapture? {
                captures.last { $0.speakerID == speaker.id && $0.wayID == way.id && $0.seatID == seat.id && !$0.impulseResponse.isEmpty }
            }
            for way in inBand {
                for seat in seats where capture(way, seat) == nil {
                    throw MIMORoutedTreatmentRefusal.missingWayCapture(speaker: name, way: label(way), seat: seat.name)
                }
            }
            for way in speaker.ways {
                for found in seats.compactMap({ capture(way, $0) }) where abs(found.sampleRate - sampleRate) > 0.5 {
                    throw MIMORoutedTreatmentRefusal.sampleRateMismatch(way: label(way), captured: found.sampleRate, engine: sampleRate)
                }
            }
            // Out-of-band ways without a capture: allowed only when predicted from the chain (400 Hz rule).
            for way in speaker.ways where !inBand.contains(where: { $0.id == way.id }) {
                let missing = seats.contains { capture(way, $0) == nil }
                guard missing else { continue }
                guard let chain = chains[way.id], (way.highPass?.cornerHz ?? 0) >= predictedChainMinHighPassHz,
                      maximumGainDB(chain, lowHz: 15, highHz: 200, sampleRate: sampleRate) <= -predictedRejectionDB
                else {
                    throw MIMORoutedTreatmentRefusal.missingWayCapture(
                        speaker: name, way: label(way), seat: seats.first { capture(way, $0) == nil }?.name ?? "")
                }
            }
            // Support range from the in-band ways (note 10), unless the user set one.
            var lowestPass = Double.infinity, highestPass = 0.0
            var minus10: [UUID: Double] = [:]
            for way in inBand {
                lowestPass = min(lowestPass, way.highPass?.cornerHz ?? 0)
                highestPass = max(highestPass, way.lowPass?.cornerHz ?? .infinity)
                let points = seats.compactMap { capture(way, $0) }.map { minusTenDBPoint(of: $0.impulseResponse, sampleRate: sampleRate) }
                minus10[way.id] = points.max() ?? 0
            }
            var low = window.lowerBound, high = window.upperBound
            if settings.supportOverrides[speaker.id] == nil {
                low = max(defaultSupportHz.lowerBound, lowestPass, minus10.values.min() ?? 0)
                high = min(defaultSupportHz.upperBound, highestPass)
            }
            guard high > low * 1.1 else { throw MIMORoutedTreatmentRefusal.supportRangeInvalid(speaker: name, lowHz: low, highHz: high) }
            plan.supportLowHz = low
            plan.supportHighHz = high
            plan.excursionCornerHz = inBand.map { max($0.highPass?.cornerHz ?? 0, minus10[$0.id] ?? 0) }.max() ?? 0
            var limit = 9.0
            for way in inBand {
                let chainPeak = maximumGainDB(chains[way.id] ?? [], lowHz: low, highHz: high, sampleRate: sampleRate)
                let budget = n60_headroom_mimo_budget_db(ceilingDB(of: way), N60_HEADROOM_MIMO_TRIM_ALLOWANCE_DB, chainPeak)
                guard budget >= 0 else { throw MIMORoutedTreatmentRefusal.headroom(speaker: name, way: label(way), budgetDB: budget) }
                plan.wayBudgetsDB.append(budget)
                limit = min(limit, budget)
            }
            plan.gainLimitDB = limit
            var spec = MIMOTreatmentSourceSpec()
            spec.supportLowHz = low
            spec.supportHighHz = high
            spec.excursionCornerHz = plan.excursionCornerHz
            spec.gainLimitDB = limit
            sources.append(spec)
            // Plants: program over every way with a capture, injection over the in-band ways.
            var perSeat: [MIMOTreatmentPlant?] = []
            for seat in seats {
                func sum(_ ways: [RoutedWay]) throws -> [Float] {
                    var raws: [[Float]] = [], filters: [[Float]] = []
                    for way in ways {
                        guard let found = capture(way, seat), let chain = chains[way.id] else { continue }
                        raws.append(found.impulseResponse)
                        filters.append(chain)
                    }
                    guard !raws.isEmpty else { return [] }
                    return try MeasurementCore.predictTreatedIR(plants: raws, filters: filters)
                }
                let program = try sum(speaker.ways)
                let injection = try sum(inBand)
                let samePlant = Set(speaker.ways.filter { w in capture(w, seat) != nil }.map(\.id)) == Set(inBand.map(\.id))
                perSeat.append(MIMOTreatmentPlant(program: program, injection: samePlant ? nil : injection, arrivalSeconds: nil))
            }
            plants.append(perSeat)
            speakerPlans.append(plan)
        }
        var request = MIMOTreatmentRequest(
            sampleRate: sampleRate, sources: sources,
            seats: seats.map { MIMOTreatmentSeatSpec(included: true, weight: $0.weight) }, plants: plants)
        request.tauSeconds = settings.tauSeconds
        request.decaySeconds = settings.decaySeconds
        request.taps = settings.taps
        let owned = Set(routing.speakers.flatMap { $0.ways.map(\.endpoint) })
        let matrixOnly = endpoints.filter { !owned.contains($0) }
        return MIMORoutedTreatmentPlan(
            speakers: speakerPlans, request: request, sourceLanes: speakerPlans.map(\.lane), matrixOnlyOutputs: matrixOnly,
            inBandWaysPerSpeaker: speakerPlans.filter(\.included).map { $0.inBandWayIDs.count }.max() ?? 1, digest: digest(of: routing))
    }

    // MARK: Way chains

    static func latencyFrames(of output: UnifiedGraphOutputLane, sampleRate: Double) -> Int {
        Int((output.protection?.latencyFrames(sampleRate: sampleRate) ?? 0) + (output.driverFIR?.latencyFrames ?? 0))
    }

    /// The latency every output of this speaker alone would be aligned to; the full routing aligns to the largest over all
    /// speakers, so the difference is added to each speaker's chains.
    private static func miniTarget(of speaker: RoutedSpeaker, sampleRate: Double) -> Int {
        guard let config = try? SpeakerRoutingCompiler.compile(mini(speaker), onto: miniBase(sampleRate)) else { return 0 }
        return (config.routing?.outputs ?? []).map { latencyFrames(of: $0, sampleRate: sampleRate) }.max() ?? 0
    }

    private static func mini(_ speaker: RoutedSpeaker) -> SpeakerRoutingConfiguration {
        var copy = speaker
        copy.source = RoutingSource(kind: .program, index: 0)
        return SpeakerRoutingConfiguration(speakers: [copy], matrix: [])
    }

    private static func miniBase(_ sampleRate: Double) -> UnifiedGraphConfiguration {
        UnifiedGraphConfiguration(sampleRate: sampleRate, lanes: [UnifiedGraphLane()])
    }

    /// Renders a unit impulse on the speaker's feed through ROUTE, XOVER, DRIVER_FIR, DELAY and the way limiter of the compiled
    /// graph and returns each way's impulse response (the way chain, down to the physical output). Offline.
    static func renderChains(of speaker: RoutedSpeaker, name: String, sampleRate: Double, offsetFrames: Int) throws -> [UUID: [Float]] {
        let routing = mini(speaker)
        let config: UnifiedGraphConfiguration
        let host: UnifiedGraphHost
        do {
            config = try SpeakerRoutingCompiler.compile(routing, onto: miniBase(sampleRate))
            host = try UnifiedGraphHost(spec: try config.makeSpec())
        } catch {
            throw MIMORoutedTreatmentRefusal.chainUnavailable(speaker: name, reason: String(describing: error))
        }
        defer { host.release() }
        let outputs = config.routing?.outputs ?? []
        let longestDelay = outputs.map { Int($0.delayFrames.rounded(.up)) + latencyFrames(of: $0, sampleRate: sampleRate) }.max() ?? 0
        let block = 512
        let frames = (Int(chainSeconds * sampleRate) + longestDelay + block - 1) / block * block
        var out = [[Float]](repeating: [], count: Int(host.outputChannels))
        var position = 0
        do {
            while position < frames {
                var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: Int(host.inputChannels))
                if position == 0 { input[0][0] = impulseAmplitude }
                let rendered = try host.processOffline(input: input, frames: block)
                for lane in 0..<rendered.count { out[lane] += rendered[lane] }
                position += block
            }
        } catch {
            throw MIMORoutedTreatmentRefusal.chainUnavailable(speaker: name, reason: String(describing: error))
        }
        let endpoints = routing.outputEndpoints
        var chains: [UUID: [Float]] = [:]
        for way in speaker.ways {
            guard let index = endpoints.firstIndex(of: way.endpoint), 1 + index < out.count else { continue }
            let response = out[1 + index].map { $0 / impulseAmplitude }
            chains[way.id] = [Float](repeating: 0, count: offsetFrames) + trimmedTail(response)
        }
        return chains
    }

    /// Drops the silent tail so plants stay short; keeps at least one sample.
    private static func trimmedTail(_ response: [Float]) -> [Float] {
        let peak = response.map { abs($0) }.max() ?? 0
        guard peak > 0 else { return [0] }
        let floor = peak * 1e-6
        var end = response.count
        while end > 1, abs(response[end - 1]) < floor { end -= 1 }
        return Array(response[..<end])
    }

    // MARK: Spectral helpers (direct evaluation: a few dozen frequencies, so no FFT)

    static func magnitudeDB(_ response: [Float], hz: Double, sampleRate: Double) -> Double {
        guard !response.isEmpty else { return -200 }
        let w = 2 * Double.pi * hz / sampleRate
        let c = cos(w), s = sin(w)
        var re = 0.0, im = 0.0
        var pr = 1.0, pi = 0.0
        for sample in response {
            let x = Double(sample)
            re += x * pr
            im -= x * pi
            let next = pr * c - pi * s
            pi = pr * s + pi * c
            pr = next
        }
        return 20 * log10(max(1e-10, (re * re + im * im).squareRoot()))
    }

    static func grid(from low: Double, to high: Double, perOctave: Double) -> [Double] {
        guard high > low, low > 0 else { return [low] }
        let count = max(2, Int((log2(high / low) * perOctave).rounded(.up)) + 1)
        return (0..<count).map { low * pow(high / low, Double($0) / Double(count - 1)) }
    }

    /// Highest gain (dB) of a chain between two frequencies.
    static func maximumGainDB(_ response: [Float], lowHz: Double, highHz: Double, sampleRate: Double) -> Double {
        grid(from: lowHz, to: highHz, perOctave: 12).map { magnitudeDB(response, hz: $0, sampleRate: sampleRate) }.max() ?? -200
    }

    /// The frequency (Hz) below which a raw capture falls more than 10 dB under its 80-150 Hz level, scanning down from 80 Hz;
    /// 0 when it does not fall that far above 10 Hz.
    static func minusTenDBPoint(of capture: [Float], sampleRate: Double) -> Double {
        let reference = grid(from: 80, to: 150, perOctave: 6).map { magnitudeDB(capture, hz: $0, sampleRate: sampleRate) }.sorted()
        guard !reference.isEmpty else { return 0 }
        let level = reference[reference.count / 2] - 10
        let scan = grid(from: 10, to: 80, perOctave: 12).reversed()
        var previous: (hz: Double, db: Double)?
        for hz in scan {
            let db = magnitudeDB(capture, hz: hz, sampleRate: sampleRate)
            if db < level {
                guard let previous else { return hz }
                let t = (previous.db - level) / max(1e-9, previous.db - db)
                return previous.hz * pow(hz / previous.hz, min(max(t, 0), 1))
            }
            previous = (hz, db)
        }
        return 0
    }
}
