import Foundation

// E29 S6 (behind `e29.room-model`): the Swift side of `n60_roommodel_interpolate`. Control plane only: nothing here
// runs on an audio callback, arms anything or changes an engine snapshot. A derived response is never persisted and
// always carries per-band confidence (design note 4); consumers that need an authoritative path never read it.

/// Third-octave band levels of one source-to-position response (core band grid, 31.25 Hz to 16 kHz).
struct RoomBandResponse: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case measured
        case derived(neighboursUsed: Int)
    }

    var origin: Origin
    var bandCentresHz: [Double]
    /// dB re 1 per unit of impulse-response sum (the core's reference); only differences matter to consumers.
    var levelsDB: [Double]
    /// 0...1 per band; 1 for a measured path.
    var confidence: [Double]
    /// False for bands above the lower of Nyquist and 20 kHz, or refused (neighbours disagree).
    var available: [Bool]
    var crossoverHz: Double?

    var isDerived: Bool { if case .derived = origin { return true } else { return false } }

    /// Mean confidence over the available bands; 0 when none is available.
    var meanConfidence: Double {
        let used = zip(confidence, available).filter { $0.1 }.map { $0.0 }
        return used.isEmpty ? 0 : used.reduce(0, +) / Double(used.count)
    }

    func bandIndex(nearest centreHz: Double, tolerance: Double = 0.03) -> Int? {
        guard centreHz > 0 else { return nil }
        var best: Int?
        var bestError = tolerance
        for (i, c) in bandCentresHz.enumerated() where c > 0 {
            let e = abs(log(c / centreHz))
            if e < bestError { best = i; bestError = e }
        }
        return best
    }

    /// Two uncorrelated sources (the left and right feed) add in power. A band is available only when both are;
    /// confidence is the lower of the two; the result is derived when either is.
    static func powerSum(_ responses: [RoomBandResponse]) -> RoomBandResponse? {
        guard let first = responses.first,
              responses.allSatisfy({ $0.bandCentresHz == first.bandCentresHz }) else { return nil }
        let n = first.bandCentresHz.count
        var levels = [Double](repeating: 0, count: n)
        var confidence = [Double](repeating: 1, count: n)
        var available = [Bool](repeating: true, count: n)
        for i in 0..<n {
            var power = 0.0
            for r in responses {
                power += pow(10, r.levelsDB[i] / 10)
                confidence[i] = min(confidence[i], r.confidence[i])
                available[i] = available[i] && r.available[i]
            }
            levels[i] = 10 * log10(max(power, 1e-30))
        }
        let used = responses.reduce(0) { total, r in
            if case .derived(let k) = r.origin { return total + k }
            return total
        }
        let derived = responses.contains { $0.isDerived }
        return RoomBandResponse(
            origin: derived ? .derived(neighboursUsed: used) : .measured, bandCentresHz: first.bandCentresHz,
            levelsDB: levels, confidence: confidence, available: available, crossoverHz: first.crossoverHz)
    }
}

enum RoomDerivedRefusal: Error, Equatable, Sendable {
    case outsideTrust
    case noNeighbours
    case invalid

    var message: String {
        switch self {
        case .outsideTrust: return "No measured seat is close enough to estimate this position."
        case .noNeighbours: return "No measured seat to estimate from."
        case .invalid: return "The measurements could not be combined."
        }
    }
}

struct RoomNeighbourPath: Sendable {
    var position: RoomPosition
    var impulseResponse: [Float]
    /// Timing tier loopback or reference; false reads the low band as magnitude-only.
    var phaseTrusted: Bool
    var repeatScatterDB: Double = 0
}

enum RoomModelInterpolator {
    static func fftSize(forFrames frames: Int) -> UInt32? {
        guard frames > 0, frames <= Int(N60_ROOMMODEL_MAX_FFT_SIZE) else { return nil }
        var n = 4096
        while n < frames { n <<= 1 }
        return UInt32(n)
    }

    /// The band response at `query` from measured neighbours of one source, all at `sampleRate`.
    static func derive(
        source: RoomPosition, query: RoomPosition, sampleRate: Double, neighbours: [RoomNeighbourPath]
    ) -> Swift.Result<RoomBandResponse, RoomDerivedRefusal> {
        guard !neighbours.isEmpty else { return .failure(.noNeighbours) }
        guard neighbours.count <= Int(N60_ROOMMODEL_MAX_NEIGHBOUR_INPUTS),
              let size = fftSize(forFrames: neighbours.map { $0.impulseResponse.count }.max() ?? 0) else {
            return .failure(.invalid)
        }
        var flat: [Float] = []
        var offsets: [Int] = []
        for n in neighbours { offsets.append(flat.count); flat.append(contentsOf: n.impulseResponse) }
        var q = n60_roommodel_query()
        q.structSize = UInt32(MemoryLayout<n60_roommodel_query>.size)
        q.fftSize = size
        q.sampleRate = sampleRate
        q.source = (source.x, source.y, source.z)
        q.query = (query.x, query.y, query.z)
        q.neighbourCount = UInt32(neighbours.count)
        var r = n60_roommodel_result()
        r.structSize = UInt32(MemoryLayout<n60_roommodel_result>.size)
        let status: Int32 = flat.withUnsafeBufferPointer { buf in
            var list = [n60_roommodel_neighbour]()
            for (i, n) in neighbours.enumerated() {
                list.append(n60_roommodel_neighbour(
                    position: (n.position.x, n.position.y, n.position.z), ir: buf.baseAddress.map { $0 + offsets[i] },
                    irFrames: UInt32(n.impulseResponse.count), phaseTrusted: n.phaseTrusted ? 1 : 0,
                    repeatScatterDb: n.repeatScatterDB))
            }
            return list.withUnsafeBufferPointer { n60_roommodel_interpolate(&q, $0.baseAddress, &r, nil, nil) }
        }
        if status == Int32(N60_ROOMMODEL_NOT_MEASURED) {
            return .failure(r.reason == Int32(N60_ROOMMODEL_REASON_NO_NEIGHBOURS) ? .noNeighbours : .outsideTrust)
        }
        guard status == Int32(N60_ROOMMODEL_OK) else { return .failure(.invalid) }
        return .success(response(from: &r, origin: .derived(neighboursUsed: Int(r.neighboursUsed))))
    }

    /// Band levels of a measured impulse response, on the same grid and with the same reference as `derive`, by
    /// asking the core for the response at the measured point itself (one neighbour, no extrapolation). Confidence is
    /// 1 for a measured path (the core reports a single neighbour as half the limit; that is not scatter).
    static func measured(impulseResponse: [Float], sampleRate: Double) -> RoomBandResponse? {
        let here = RoomPosition(x: 0, y: 0, z: 0, source: .unknown, uncertaintyMetres: nil)
        let n = RoomNeighbourPath(position: here, impulseResponse: impulseResponse, phaseTrusted: false)
        let source = RoomPosition(x: 0, y: 1, z: 0, source: .unknown, uncertaintyMetres: nil)
        guard case .success(var r) = derive(source: source, query: here, sampleRate: sampleRate, neighbours: [n])
        else { return nil }
        r.origin = .measured
        r.confidence = r.available.map { $0 ? 1 : 0 }
        return r
    }

    private static func response(from r: inout n60_roommodel_result, origin: RoomBandResponse.Origin) -> RoomBandResponse {
        let status: [Int32] = withUnsafeBytes(of: &r.bandStatus) { Array($0.bindMemory(to: Int32.self)) }
        let centres: [Double] = withUnsafeBytes(of: &r.bandCentreHz) { Array($0.bindMemory(to: Double.self)) }
        let levels: [Double] = withUnsafeBytes(of: &r.levelDb) { Array($0.bindMemory(to: Double.self)) }
        let confidence: [Double] = withUnsafeBytes(of: &r.confidence) { Array($0.bindMemory(to: Double.self)) }
        return RoomBandResponse(
            origin: origin, bandCentresHz: centres, levelsDB: levels, confidence: confidence,
            available: status.map { $0 == Int32(N60_ROOMMODEL_BAND_OK) }, crossoverHz: r.crossoverHz)
    }
}
