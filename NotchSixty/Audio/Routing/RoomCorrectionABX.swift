import Foundation

// E10 S9: blind ABX of two room-correction designs (design note 10).
//
// Offline and control-plane only: this prepares matched FIRs and records trials. It never runs
// on an audio thread. Trial logic reuses `BlindABXSession`; this file adds level and latency
// matching of the two candidates and the on-disk trial log. E24 S9 plays the candidates: each A/B/X press
// republishes the live graph with the candidate's lane install, and the core's silent warm-up plus 20 ms
// equal-power crossfade is the switch (the lane path has no FIR crossfade of its own). The match below gives
// the override its gain and extra delay.

/// One candidate design for a single channel, as a FIR plus its declared latency.
struct RoomCorrectionABXCandidate: Equatable, Sendable {
    var name: String
    var taps: [Float]
    /// Latency the design declares, in frames at `sampleRate`.
    var latencyFrames: Int
}

/// Level and latency matching result. Applying it makes both candidates equally loud over
/// 500 Hz to 2 kHz and equally delayed.
struct RoomCorrectionABXMatch: Equatable, Sendable {
    static let bandLowHz = 500.0
    static let bandHighHz = 2_000.0
    /// Matching tolerance required by the epic (design note 10).
    static let toleranceDB = 0.1

    var sampleRate: Double
    var levelADB: Double
    var levelBDB: Double
    /// Linear trim for each candidate. The louder one is trimmed down, so nothing clips.
    var gainA: Double
    var gainB: Double
    /// Frames of leading delay added to each candidate. The one with less latency is delayed.
    var delayA: Int
    var delayB: Int
    /// E24 S9: the largest per-lane level difference after the global trim (0 for a single-FIR match).
    var maxLaneResidualDB: Double = 0

    /// Mean magnitude in dB over the 500 Hz to 2 kHz band, evaluated on a 1/12-octave grid
    /// by direct DFT in double precision.
    static func bandLevelDB(taps: [Float], sampleRate: Double) -> Double {
        var power = 0.0
        var count = 0
        var f = bandLowHz
        let step = pow(2.0, 1.0 / 12.0)
        while f <= bandHighHz * 1.0000001 {
            let w = 2.0 * Double.pi * f / sampleRate
            var re = 0.0, im = 0.0
            for (n, t) in taps.enumerated() {
                let a = w * Double(n)
                re += Double(t) * cos(a)
                im -= Double(t) * sin(a)
            }
            power += re * re + im * im
            count += 1
            f *= step
        }
        guard count > 0, power > 0 else { return -.infinity }
        return 10.0 * log10(power / Double(count))
    }

    static func make(
        a: RoomCorrectionABXCandidate,
        b: RoomCorrectionABXCandidate,
        sampleRate: Double
    ) throws -> RoomCorrectionABXMatch {
        guard (8_000...384_000).contains(sampleRate),
              !a.taps.isEmpty, !b.taps.isEmpty,
              a.latencyFrames >= 0, b.latencyFrames >= 0,
              a.taps.allSatisfy(\.isFinite), b.taps.allSatisfy(\.isFinite)
        else { throw BlindABXError.invalidTrial }
        let la = bandLevelDB(taps: a.taps, sampleRate: sampleRate)
        let lb = bandLevelDB(taps: b.taps, sampleRate: sampleRate)
        guard la.isFinite, lb.isFinite else { throw BlindABXError.invalidTrial }
        let target = min(la, lb)
        let latency = max(a.latencyFrames, b.latencyFrames)
        return RoomCorrectionABXMatch(
            sampleRate: sampleRate, levelADB: la, levelBDB: lb,
            gainA: pow(10.0, (target - la) / 20.0),
            gainB: pow(10.0, (target - lb) / 20.0),
            delayA: latency - a.latencyFrames,
            delayB: latency - b.latencyFrames)
    }

    /// The matched FIR for a candidate: leading zeros for the delay, then the trimmed taps.
    func matchedTaps(_ candidate: RoomCorrectionABXCandidate, isA: Bool) -> [Float] {
        let gain = isA ? gainA : gainB
        let delay = isA ? delayA : delayB
        return [Float](repeating: 0, count: delay) + candidate.taps.map { Float(Double($0) * gain) }
    }
}

/// One finished ABX run with the context the bench needs, stored in the app container.
/// Schema 2 (E24 S9) adds the per-lane residual, the listening seat and the stated preference; a schema 1 file
/// still decodes, with those three nil.
struct RoomCorrectionABXLog: Codable, Equatable, Sendable {
    static let minimumPhaseName = "Minimum phase"
    static let mixedPhaseName = "Mixed phase"

    var schemaVersion = 2
    var date: Date
    var designAName: String
    var designBName: String
    var seatCount: Int
    var sampleRate: Double
    var levelMatchResidualDB: Double
    var latencyFramesMatched: Int
    var trialCount: Int
    var correctCount: Int
    var oneSidedExactPValue: Double
    var trials: [BlindABXTrial]
    var maxLaneResidualDB: Double?
    /// The listening seat (1-based) this run was heard at.
    var listeningSeat: Int?
    /// The design the listener said they prefer, or nil for "no preference" (or a schema 1 file).
    var preferredDesignName: String?

    init(
        session: BlindABXSession, match: RoomCorrectionABXMatch,
        a: RoomCorrectionABXCandidate, b: RoomCorrectionABXCandidate,
        seatCount: Int, date: Date = Date()
    ) throws {
        let evidence = try session.exportEvidence()
        self.date = date
        designAName = a.name
        designBName = b.name
        self.seatCount = seatCount
        sampleRate = match.sampleRate
        let ma = RoomCorrectionABXMatch.bandLevelDB(
            taps: match.matchedTaps(a, isA: true), sampleRate: match.sampleRate)
        let mb = RoomCorrectionABXMatch.bandLevelDB(
            taps: match.matchedTaps(b, isA: false), sampleRate: match.sampleRate)
        levelMatchResidualDB = abs(ma - mb)
        latencyFramesMatched = max(a.latencyFrames, b.latencyFrames)
        trialCount = evidence.trialCount
        correctCount = evidence.correctCount
        oneSidedExactPValue = evidence.oneSidedExactPValue
        trials = evidence.trials
    }

    /// The log of a run played through lane plans (E24 S9): the match carries the levels and the residual.
    init(
        session: BlindABXSession, match: RoomCorrectionABXMatch, designAName: String, designBName: String,
        seatCount: Int, listeningSeat: Int, preferredDesignName: String?, date: Date = Date()
    ) throws {
        let evidence = try session.exportEvidence()
        self.date = date
        self.designAName = designAName
        self.designBName = designBName
        self.seatCount = seatCount
        sampleRate = match.sampleRate
        levelMatchResidualDB = abs((match.levelADB + 20 * log10(match.gainA)) - (match.levelBDB + 20 * log10(match.gainB)))
        latencyFramesMatched = max(match.delayA, match.delayB)
        trialCount = evidence.trialCount
        correctCount = evidence.correctCount
        oneSidedExactPValue = evidence.oneSidedExactPValue
        trials = evidence.trials
        maxLaneResidualDB = match.maxLaneResidualDB
        self.listeningSeat = listeningSeat
        self.preferredDesignName = preferredDesignName
    }

    /// Gate G3 (Q18, decided 2 Nov 2026): three or more distinct listening seats, each with a log at p < 0.05
    /// that states mixed phase as the preference. Logs without a seat or a preference never count.
    static func gateG3(_ logs: [RoomCorrectionABXLog]) -> Bool {
        var seats = Set<Int>()
        for log in logs where log.oneSidedExactPValue < 0.05 && log.preferredDesignName == mixedPhaseName {
            if let seat = log.listeningSeat { seats.insert(seat) }
        }
        return seats.count >= 3
    }

    static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NotchSixty/ABX", isDirectory: true)
    }

    /// Every readable log in `directory`, oldest first. Unreadable files are skipped.
    static func readAll(in directory: URL) -> [RoomCorrectionABXLog] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("abx-") }
            .compactMap { try? read(from: $0) }
            .sorted { $0.date < $1.date }
    }

    @discardableResult
    func write(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let stamp = Int(date.timeIntervalSince1970)
        let tag = listeningSeat.map { "seat\($0)" } ?? "\(seatCount)seat"
        let url = directory.appendingPathComponent("abx-\(stamp)-\(tag).json")
        try encoder.encode(self).write(to: url, options: .atomic)
        return url
    }

    static func read(from url: URL) throws -> RoomCorrectionABXLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RoomCorrectionABXLog.self, from: Data(contentsOf: url))
    }
}
