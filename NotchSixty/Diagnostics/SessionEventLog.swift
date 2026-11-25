import Foundation

// E33 S16 (behind `e33.page-enhancements`): timestamped session events built from counters the meter hub already
// polls. Pure Swift on the main actor's poll; nothing here runs on, or reads from, the audio thread, and no audio
// is stored.

enum SessionEventKind: String, Codable, CaseIterable, Sendable {
    case clip, truePeakOver, limiter, protection, dropout, deviceLoss, deviceRecovered, rateChange, inputOver
    /// E12 S20: an Active Acoustics arm, disarm, guard trip or bypass. `place` holds the sentence in plain words.
    case treatment

    var title: String {
        switch self {
        case .clip: return "Clip"
        case .truePeakOver: return "True-peak over"
        case .limiter: return "Limiter"
        case .protection: return "Output protection"
        case .dropout: return "Dropout"
        case .deviceLoss: return "Output lost"
        case .deviceRecovered: return "Output recovered"
        case .rateChange: return "Rate change"
        case .inputOver: return "Input overs"
        case .treatment: return "Active acoustics"
        }
    }
}

struct SessionEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var time: Date
    var lastTime: Date
    var kind: SessionEventKind
    /// Where: a channel, stage or lane name ("" when it applies to the whole session).
    var place: String
    /// How much: peak depth in dB for the limiter and protection, dBTP for a true-peak over, frames for a dropout,
    /// samples for a clip, Hz for a rate change.
    var amount: Double
    var count: Int
    var episodeOpen: Bool = false

    var detail: String {
        switch kind {
        case .clip: return "\(Int(amount)) samples"
        case .truePeakOver: return String(format: "%+.1f dBTP", amount)
        case .limiter:
            let duration = lastTime.timeIntervalSince(time)
            return String(format: "%.1f dB peak, %.1f s", amount, duration)
        case .protection: return String(format: "%.1f dB peak", amount)
        case .dropout: return "\(Int(amount)) frames"
        case .deviceLoss, .deviceRecovered: return ""
        case .rateChange: return String(format: "%.1f kHz", amount / 1_000)
        case .inputOver: return "\(Int(amount)) overs"
        case .treatment: return ""
        }
    }

    /// One line for the History card, VoiceOver and the text export (time added by the caller).
    func summary(timeText: String) -> String {
        if kind == .treatment { return "\(timeText) · \(place)" }
        var parts = [timeText, kind.title]
        if !place.isEmpty { parts.append(place) }
        let d = detail
        if !d.isEmpty { parts.append(d) }
        var text = parts.joined(separator: " · ")
        if count > 1 { text += " (x\(count))" }
        return text
    }
}

/// What one hub poll provides. Per-poll values (clip samples, true peak, limiter reduction) are read-and-reset
/// maxima since the previous poll; the transport and recovery counts are cumulative.
struct SessionEventSample: Sendable {
    var now: Date
    /// Sample-clip counts since the last poll, by channel label. Zero entries are ignored.
    var clipSamples: [String: UInt64] = [:]
    /// True-peak maxima since the last poll (linear), by label. Above 1.0 is an over.
    var truePeakLinear: [String: Float] = [:]
    var limiterReductionDB: Float = 0
    /// E9 hard-limit reduction per output lane (dB, 0 or more).
    var protectionReductionDB: [String: Float] = [:]
    var underrunFrames: UInt64 = 0
    var overrunFrames: UInt64 = 0
    var recoveryAttempts: UInt64 = 0
    var recoverySuccesses: UInt64 = 0
    var sampleRate: Double?
    /// E12 S12: largest output sample or true-peak magnitude (linear) since the last poll; 0 when not read.
    var outputPeakLinear: Float = 0
}

struct SessionEventLog: Equatable, Sendable {
    static let capacity = 300
    static let mergeWindow: TimeInterval = 2
    static let limiterThresholdDB: Float = 3
    static let protectionThresholdDB: Float = 0.1

    var limiterThresholdDB = SessionEventLog.limiterThresholdDB
    private(set) var events: [SessionEvent] = []
    private var lastUnderrun: UInt64?
    private var lastOverrun: UInt64?
    private var lastAttempts: UInt64?
    private var lastSuccesses: UInt64?
    private var lastRate: Double?
    private var lastInputOvers: [UInt64]?
    private var openEpisodes: [String: UUID] = [:]

    init(events: [SessionEvent] = []) {
        self.events = events.map { var e = $0; e.episodeOpen = false; return e }
    }

    var newestFirst: [SessionEvent] { events.reversed() }

    mutating func clear() {
        events = []
        openEpisodes = [:]
    }

    /// A new session: counters rebaseline without an event.
    mutating func rebaseline() {
        lastUnderrun = nil; lastOverrun = nil; lastAttempts = nil; lastSuccesses = nil; lastRate = nil; lastInputOvers = nil
        for i in events.indices { events[i].episodeOpen = false }
        openEpisodes = [:]
    }

    /// Events from `date` on, for the Dashboard attention line.
    func events(since date: Date) -> [SessionEvent] { events.filter { $0.lastTime >= date } }

    mutating func observe(_ s: SessionEventSample) {
        for (place, samples) in s.clipSamples.sorted(by: { $0.key < $1.key }) where samples > 0 {
            record(.clip, place: place, amount: Double(samples), at: s.now)
        }
        for (place, linear) in s.truePeakLinear.sorted(by: { $0.key < $1.key }) where linear.isFinite && linear > 1 {
            let dbtp = 20 * log10(Double(linear))
            record(.truePeakOver, place: place, amount: dbtp, at: s.now, takeMax: true)
        }
        episode(.limiter, place: "", depthDB: s.limiterReductionDB, threshold: limiterThresholdDB, at: s.now)
        let lanes = Set(s.protectionReductionDB.keys).union(openEpisodes.keys.compactMap { key -> String? in
            key.hasPrefix("protection|") ? String(key.dropFirst("protection|".count)) : nil
        })
        for lane in lanes.sorted() {
            episode(.protection, place: lane, depthDB: s.protectionReductionDB[lane] ?? 0,
                    threshold: Self.protectionThresholdDB, at: s.now)
        }
        if let lastUnderrun, let lastOverrun,
           s.underrunFrames >= lastUnderrun, s.overrunFrames >= lastOverrun {
            let delta = (s.underrunFrames - lastUnderrun) + (s.overrunFrames - lastOverrun)
            if delta > 0 { record(.dropout, place: "", amount: Double(delta), at: s.now, sum: true) }
        }
        lastUnderrun = s.underrunFrames
        lastOverrun = s.overrunFrames
        if let lastAttempts, s.recoveryAttempts > lastAttempts {
            record(.deviceLoss, place: "", amount: 0, at: s.now, countBy: Int(s.recoveryAttempts - lastAttempts))
        }
        if let lastSuccesses, s.recoverySuccesses > lastSuccesses {
            record(.deviceRecovered, place: "", amount: 0, at: s.now, countBy: Int(s.recoverySuccesses - lastSuccesses))
        }
        lastAttempts = s.recoveryAttempts
        lastSuccesses = s.recoverySuccesses
        if let rate = s.sampleRate, rate > 0 {
            if let lastRate, abs(lastRate - rate) > 0.5 {
                record(.rateChange, place: "", amount: rate, at: s.now, replace: true)
            }
            lastRate = rate
        }
    }

    /// E33 S10 (closes G54): the core's monotonic input-over counts per lane, read while the Levels page shows them. The first
    /// reading (and any reading after a reset, when a count falls) is the baseline; a rise is an event for that lane.
    mutating func observeInputOvers(counts: [UInt64], at now: Date) {
        defer { lastInputOvers = counts }
        guard let last = lastInputOvers, last.count == counts.count else { return }
        for (lane, count) in counts.enumerated() where count > last[lane] {
            record(.inputOver, place: "Input \(lane + 1)", amount: Double(count - last[lane]), at: now, sum: true)
        }
    }

    /// E12 S20: one plain-words sentence (an arm, a disarm, a guard trip or a bypass). Never merged: each is its own event.
    mutating func note(_ sentence: String, at now: Date) {
        append(SessionEvent(id: UUID(), time: now, lastTime: now, kind: .treatment, place: sentence, amount: 0, count: 1))
    }

    // MARK: Recording

    private mutating func record(
        _ kind: SessionEventKind, place: String, amount: Double, at now: Date,
        takeMax: Bool = false, sum: Bool = false, replace: Bool = false, countBy: Int = 1
    ) {
        if let index = events.lastIndex(where: { $0.kind == kind && $0.place == place }),
           now.timeIntervalSince(events[index].lastTime) <= Self.mergeWindow, !replace {
            events[index].count += countBy
            events[index].lastTime = now
            if takeMax { events[index].amount = max(events[index].amount, amount) }
            if sum { events[index].amount += amount }
            if !takeMax && !sum { events[index].amount = max(events[index].amount, amount) }
            return
        }
        append(SessionEvent(id: UUID(), time: now, lastTime: now, kind: kind, place: place, amount: amount, count: countBy))
    }

    /// One event per episode: opens above the threshold, grows its peak and duration, closes when back below it.
    /// An episode starting within the merge window of the previous one of the same kind and place continues it.
    private mutating func episode(_ kind: SessionEventKind, place: String, depthDB: Float, threshold: Float, at now: Date) {
        let key = "\(kind.rawValue)|\(place)"
        let above = depthDB.isFinite && depthDB >= threshold
        if let id = openEpisodes[key], let index = events.firstIndex(where: { $0.id == id }) {
            if above {
                events[index].amount = max(events[index].amount, Double(depthDB))
                events[index].lastTime = now
            } else {
                events[index].episodeOpen = false
                openEpisodes[key] = nil
            }
            return
        }
        guard above else { return }
        if let index = events.lastIndex(where: { $0.kind == kind && $0.place == place }),
           now.timeIntervalSince(events[index].lastTime) <= Self.mergeWindow {
            events[index].count += 1
            events[index].amount = max(events[index].amount, Double(depthDB))
            events[index].lastTime = now
            events[index].episodeOpen = true
            openEpisodes[key] = events[index].id
            return
        }
        var event = SessionEvent(id: UUID(), time: now, lastTime: now, kind: kind, place: place,
                                 amount: Double(depthDB), count: 1)
        event.episodeOpen = true
        openEpisodes[key] = event.id
        append(event)
    }

    private mutating func append(_ event: SessionEvent) {
        events.append(event)
        if events.count > Self.capacity {
            let drop = events.count - Self.capacity
            let removed = Set(events.prefix(drop).map(\.id))
            events.removeFirst(drop)
            openEpisodes = openEpisodes.filter { !removed.contains($0.value) }
        }
    }
}

enum SessionEventText {
    static func time(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// "Copy as text": both sessions, oldest first, one line per event.
    static func export(current: [SessionEvent], previous: [SessionEvent]) -> String {
        func lines(_ title: String, _ events: [SessionEvent]) -> String {
            let body = events.isEmpty ? "No events." : events.map { $0.summary(timeText: time($0.time)) }.joined(separator: "\n")
            return "\(title)\n\(body)"
        }
        return [lines("Previous session", previous), lines("Current session", current)].joined(separator: "\n\n")
    }
}

/// The two kept sessions as stored in the app's own container.
struct SessionEventArchive: Codable, Equatable, Sendable {
    var current: [SessionEvent] = []
    var previous: [SessionEvent] = []
}

struct SessionEventStore: Sendable {
    let url: URL

    static func defaultURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return root.appendingPathComponent("Notch Sixty", isDirectory: true).appendingPathComponent("SessionEvents.json")
    }

    func load() -> SessionEventArchive {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(SessionEventArchive.self, from: data) else { return SessionEventArchive() }
        return archive
    }

    func save(_ archive: SessionEventArchive) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(archive).write(to: url, options: .atomic)
        } catch {
            // History is a convenience: a failed write must never disturb metering.
        }
    }
}

/// The meter hub's owner of the log, the previous session, the session dropout counter and persistence.
@MainActor
final class SessionEventHistory: ObservableObject {
    static let saveInterval: TimeInterval = 5

    @Published private(set) var log: SessionEventLog
    @Published private(set) var previous: [SessionEvent]
    /// Counts from session start (closes E33 G8): it lives here, not in a page's view state.
    @Published private(set) var dropouts = DropoutCounter()
    /// E12 S12: clip, limiter and headroom totals from session start, for the Dashboard health strip.
    @Published private(set) var health = SessionHealthTotals()
    private let store: SessionEventStore?
    private var lastSave: Date?
    private var dirty = false
    private var sessionActive = false

    /// A launch begins a new session: the stored current session becomes the previous one.
    init(store: SessionEventStore?) {
        self.store = store
        let archive = store?.load() ?? SessionEventArchive()
        previous = archive.current.isEmpty ? archive.previous : archive.current
        log = SessionEventLog()
    }

    /// E33 S10: input overs from the Levels page poll (the detector runs only while that page is shown).
    func observeInputOvers(counts: [UInt64], now: Date) {
        sessionActive = true
        let before = log.events.last
        let n = log.events.count
        log.observeInputOvers(counts: counts, at: now)
        if log.events.count != n || log.events.last != before { dirty = true }
    }

    func observe(_ sample: SessionEventSample) {
        sessionActive = true
        let before = log.events.count
        let beforeLast = log.events.last
        log.observe(sample)
        if log.events.count != before || log.events.last != beforeLast { dirty = true }
        dropouts.observe(underrunFrames: sample.underrunFrames, overrunFrames: sample.overrunFrames, now: sample.now)
        health.observe(sample)
        saveIfDue(now: sample.now)
    }

    /// Processing stopped: the next observation starts a new session for the dropout counter and rebaselines the
    /// transport counts; the event list continues (the session is the app run).
    func noteStopped() {
        guard sessionActive else { return }
        sessionActive = false
        log.rebaseline()
        dropouts.reset()
        health.reset()
        saveIfDue(now: Date(), force: true)
    }

    func resetDropouts() { dropouts.reset() }

    /// E12 S20: Active Acoustics arm, disarm, guard trip and bypass, in plain words.
    func noteTreatment(_ sentence: String, now: Date = Date()) {
        log.note(sentence, at: now)
        dirty = true
        saveIfDue(now: now)
    }

    func clear() {
        log.clear()
        dirty = true
        saveIfDue(now: Date(), force: true)
    }

    func eventsSince(_ date: Date) -> [SessionEvent] { log.events(since: date) }

    func exportText() -> String { SessionEventText.export(current: log.events, previous: previous) }

    private func saveIfDue(now: Date, force: Bool = false) {
        guard dirty, let store else { return }
        if !force, let lastSave, now.timeIntervalSince(lastSave) < Self.saveInterval { return }
        lastSave = now
        dirty = false
        store.save(SessionEventArchive(current: log.events, previous: previous))
    }
}

extension SessionEventSample {
    /// The sample the hub builds from one frame: pure, so tests feed synthetic frames through the same encoding.
    static func make(
        channels: [String: MeterChannelReading],
        diagnostics: AudioDiagnosticsSnapshot,
        protection: [UnifiedGraphOutputProtectionReading],
        now: Date
    ) -> SessionEventSample {
        var sample = SessionEventSample(now: now)
        for (id, reading) in channels where !id.hasPrefix("gr.") {
            if let over = reading.overRangeSamples, over > 0 { sample.clipSamples[placeName(id)] = over }
            if let tp = reading.truePeakLinear, tp > 1 {
                let place = placeName(stage(of: id))
                sample.truePeakLinear[place] = max(sample.truePeakLinear[place] ?? 0, tp)
            }
        }
        if let kernel = diagnostics.renderKernelDiagnostics {
            sample.limiterReductionDB = max(0, kernel.limiterGainReductionDB)
        }
        for reading in protection where reading.hardLimitGainReductionDB > 0 {
            sample.protectionReductionDB["Output \(reading.lane + 1)"] = reading.hardLimitGainReductionDB
        }
        let counters = diagnostics.sessionTransportCounters
        sample.underrunFrames = counters.underrunFrames
        sample.overrunFrames = counters.overrunFrames
        sample.recoveryAttempts = diagnostics.recoveryAttempts
        sample.recoverySuccesses = diagnostics.recoverySuccesses
        sample.sampleRate = diagnostics.outputSampleRate
        var outputPeak: Float = 0
        for (id, reading) in channels where id.hasPrefix("output.") {
            outputPeak = max(outputPeak, reading.peakLinear, reading.truePeakLinear ?? 0)
        }
        sample.outputPeakLinear = outputPeak
        return sample
    }

    private static func stage(of id: String) -> String {
        guard let dot = id.firstIndex(of: ".") else { return id }
        return String(id[..<dot])
    }

    /// "input.L" -> "Input L", "postEQ.R" -> "Post-EQ R", "output.truePeak" -> "Output".
    static func placeName(_ id: String) -> String {
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        let head: String
        switch parts.first ?? id {
        case "input": head = "Input"
        case "postEQ": head = "Post-EQ"
        case "output": head = "Output"
        default: head = parts.first ?? id
        }
        guard parts.count == 2, parts[1] != "truePeak" else { return head }
        return "\(head) \(parts[1])"
    }
}
