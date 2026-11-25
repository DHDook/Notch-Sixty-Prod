import Foundation

// E12 S12 (behind `e12.dashboard-remote`): the Dashboard as a status page. `DashboardInputs` is a plain-value copy
// of the engine and profile state the page reads; `DashboardModel.make` turns it into every card, health item,
// attention item and now-playing line. Pure: no engine, no SwiftUI, so tests drive it with synthetic inputs.

/// Where a card or an attention button goes.
struct DashboardDestination: Equatable {
    var section: ProductionSection
    /// Meters page to open when `section` is `.meters` (nil keeps the page as it is).
    var metersPage: ProductionMetersPage?

    init(_ section: ProductionSection, metersPage: ProductionMetersPage? = nil) {
        self.section = section
        self.metersPage = metersPage
    }
}

/// What the program path looks like to the listener.
enum DashboardPath: Equatable {
    case stereoSpeakers
    case headphones
    case virtualHeadphones(layout: String)
    case multichannel(system: String)
}

struct DashboardRouting: Equatable {
    var speakers: Int
    var ways: Int
}

enum DashboardAcoustics: Equatable {
    case faulted
    case active(sources: Int)
    case transitioning(percent: Int)
    case ready
    case staged
    case notSetUp
}

struct DashboardInputs: Equatable {
    var lifecycle: AudioLifecycleState = .idle
    var outputName: String?
    var sampleRate: Double?
    var volumeReadout = ""
    var muted = false
    var presetName = "Custom"
    var presetDirty = false
    /// E15 fills this in for an automatic switch (for example "Switched because AirPods connected").
    var switchReason: String?

    /// E12 S24: why processing was not resumed at launch; nil when nothing needs saying.
    var resumeNote: String?

    var path: DashboardPath = .stereoSpeakers
    /// Speaker count and way count when speaker routing is on; nil otherwise.
    var routing: DashboardRouting?
    var systemName = "Stereo"
    var bassManagementEnabled = false
    var crossoverHz = 80
    var crossoverName = ""

    /// E12 S15 (G20): why the calibration is out of date, in plain words; nil when it is current or none exists.
    var calibrationOutOfDate: String?

    var eqBandCount = 0
    var eqPhaseName = ""
    var dynamicsNames: [String] = []
    var correctionEnabled = false
    var correctionFilterName: String?
    var acoustics: DashboardAcoustics = .notSetUp

    var lastError: String?
    var failsafeMessage: String?
    var eventsInLastDay = 0

    // Health: nil means the engine does not report it right now.
    var clippedSamples: UInt64 = 0
    var peakLimiterReductionDB: Float = 0
    var remainingHeadroomDB: Double?
    var meanLoad: Float?
    var peakLoad: Float?
    var dropoutEvents = 0
    var latencyMilliseconds: Double?
    /// Output device latency and I/O buffer in milliseconds (G71); nil when Core Audio does not report them.
    var deviceLatencyMilliseconds: Double?
    var bufferMilliseconds: Double?
    var integratedLUFS: Double?
    var truePeakDBTP: Double?
}

struct DashboardCard: Identifiable, Equatable {
    var id: String
    var title: String
    var systemImage: String
    var isOn: Bool
    var line: String
    var destination: DashboardDestination
}

enum DashboardHealthState: Equatable { case good, warning, unreported }

struct DashboardHealthItem: Identifiable, Equatable {
    var id: String
    var title: String
    var value: String
    var state: DashboardHealthState
}

enum DashboardAttentionKind: String, Equatable {
    case engineError, waitingForDevice, activeSpeakerFailsafe, calibrationOutOfDate, sessionEvents, resumeSkipped
}

struct DashboardAttentionItem: Identifiable, Equatable {
    var kind: DashboardAttentionKind
    var id: String { kind.rawValue }
    var text: String
    var buttonTitle: String
    var destination: DashboardDestination
    var isWarning: Bool
}

struct DashboardNowPlaying: Equatable {
    var title: String
    var unsavedMark: Bool
    var reason: String?
    var output: String
    var sampleRate: String
    var volume: String
}

struct DashboardState: Equatable {
    var nowPlaying: DashboardNowPlaying
    var attention: [DashboardAttentionItem]
    var health: [DashboardHealthItem]
    var cards: [DashboardCard]
    var needsOutput: Bool
}

enum DashboardModel {
    static let maxDynamicsNames = 3
    static let warnLoad: Float = 0.7
    static let warnHeadroomDB = 1.0

    static func make(_ i: DashboardInputs) -> DashboardState {
        DashboardState(
            nowPlaying: nowPlaying(i), attention: attention(i), health: health(i), cards: cards(i),
            needsOutput: i.outputName == nil)
    }

    // MARK: Now playing

    static func nowPlaying(_ i: DashboardInputs) -> DashboardNowPlaying {
        DashboardNowPlaying(
            title: i.presetName, unsavedMark: i.presetDirty, reason: i.switchReason,
            output: i.outputName ?? "No output chosen", sampleRate: sampleRateText(i.sampleRate),
            volume: i.muted ? "Muted" : i.volumeReadout)
    }

    static func sampleRateText(_ rate: Double?) -> String {
        guard let rate, rate > 0 else { return "—" }
        let khz = rate / 1_000
        return khz.rounded() == khz ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
    }

    // MARK: Attention (one fixed place, most urgent first)

    static func attention(_ i: DashboardInputs) -> [DashboardAttentionItem] {
        var items: [DashboardAttentionItem] = []
        if let message = i.failsafeMessage {
            items.append(.init(
                kind: .activeSpeakerFailsafe, text: message, buttonTitle: "Open Speakers",
                destination: .init(.speakers), isWarning: true))
        }
        if i.lifecycle == .recoveringOutput {
            let name = i.outputName ?? "the output device"
            items.append(.init(
                kind: .waitingForDevice, text: "Waiting for \(name) to come back.",
                buttonTitle: "Open Speakers", destination: .init(.speakers), isWarning: true))
        }
        if let note = i.resumeNote, i.lifecycle != .running {
            items.append(.init(
                kind: .resumeSkipped, text: note, buttonTitle: "Open Speakers",
                destination: .init(.speakers), isWarning: false))
        }
        if let error = i.lastError, !error.isEmpty {
            items.append(.init(
                kind: .engineError, text: error, buttonTitle: "See Transport",
                destination: .init(.meters, metersPage: .transport), isWarning: true))
        }
        if let reason = i.calibrationOutOfDate {
            items.append(.init(
                kind: .calibrationOutOfDate, text: "The calibration may be out of date: \(reason).",
                buttonTitle: "Open System", destination: .init(.system), isWarning: false))
        }
        if i.eventsInLastDay > 0 {
            let n = i.eventsInLastDay
            items.append(.init(
                kind: .sessionEvents, text: "\(n) \(n == 1 ? "event" : "events") in the last day.",
                buttonTitle: "See History", destination: .init(.meters, metersPage: .transport), isWarning: false))
        }
        return items
    }

    // MARK: Health strip

    static func health(_ i: DashboardInputs) -> [DashboardHealthItem] {
        var items: [DashboardHealthItem] = []
        items.append(.init(
            id: "clipping", title: "Clipping",
            value: i.clippedSamples == 0 ? "None" : "\(i.clippedSamples) samples",
            state: i.clippedSamples == 0 ? .good : .warning))
        items.append(.init(
            id: "limiter", title: "Limiter",
            value: i.peakLimiterReductionDB > 0.05 ? String(format: "Up to %.1f dB", Double(i.peakLimiterReductionDB)) : "Not needed",
            state: i.peakLimiterReductionDB > 3 ? .warning : .good))
        if let headroom = i.remainingHeadroomDB {
            items.append(.init(
                id: "headroom", title: "Headroom", value: String(format: "%.1f dB", headroom),
                state: headroom < warnHeadroomDB ? .warning : .good))
        } else {
            items.append(.init(id: "headroom", title: "Headroom", value: "—", state: .unreported))
        }
        if let mean = i.meanLoad, let peak = i.peakLoad {
            items.append(.init(
                id: "load", title: "Processing load",
                value: String(format: "%.0f%% (peak %.0f%%)", Double(mean) * 100, Double(peak) * 100),
                state: peak > warnLoad ? .warning : .good))
        } else {
            items.append(.init(id: "load", title: "Processing load", value: "Not reported", state: .unreported))
        }
        items.append(.init(
            id: "dropouts", title: "Dropouts", value: i.dropoutEvents == 0 ? "None" : "\(i.dropoutEvents)",
            state: i.dropoutEvents == 0 ? .good : .warning))
        if let ms = i.latencyMilliseconds {
            if let device = i.deviceLatencyMilliseconds, let buffer = i.bufferMilliseconds {
                // G71: processing plus the output device's own latency and its I/O buffer.
                items.append(.init(
                    id: "latency", title: "Total latency", value: String(format: "%.1f ms", ms + device + buffer), state: .good))
            } else {
                items.append(.init(id: "latency", title: "Processing latency", value: String(format: "%.1f ms", ms), state: .good))
            }
        } else {
            items.append(.init(id: "latency", title: "Total latency", value: "—", state: .unreported))
        }
        return items
    }

    // MARK: Cards

    static func cards(_ i: DashboardInputs) -> [DashboardCard] {
        let running = i.lifecycle == .running
        return [
            DashboardCard(
                id: "path", title: "Playback Path", systemImage: "point.3.connected.trianglepath.dotted",
                isOn: running, line: pathLine(i.path), destination: .init(.system)),
            DashboardCard(
                id: "eq", title: "Equalizer", systemImage: "slider.horizontal.3", isOn: i.eqBandCount > 0,
                line: i.eqBandCount == 0 ? "No bands in use" : "\(i.eqBandCount) \(i.eqBandCount == 1 ? "band" : "bands") · \(i.eqPhaseName)",
                destination: .init(.equalizer)),
            DashboardCard(
                id: "dynamics", title: "Dynamics", systemImage: "waveform.path.ecg",
                isOn: !i.dynamicsNames.isEmpty, line: dynamicsLine(i.dynamicsNames), destination: .init(.dynamics)),
            DashboardCard(
                id: "speakers", title: "Speakers", systemImage: "hifispeaker.2.fill",
                isOn: i.routing != nil || i.bassManagementEnabled, line: speakersLine(i),
                destination: .init(.speakers)),
            DashboardCard(
                id: "correction", title: "Room Correction", systemImage: "waveform.badge.magnifyingglass",
                isOn: i.correctionEnabled, line: correctionLine(i), destination: .init(.roomCorrection)),
            DashboardCard(
                id: "acoustics", title: "Active Acoustics", systemImage: "waveform.and.mic",
                isOn: { if case .active = i.acoustics { return true } else { return false } }(),
                line: acousticsLine(i.acoustics), destination: .init(.activeAcoustics)),
        ]
    }

    static func pathLine(_ path: DashboardPath) -> String {
        switch path {
        case .stereoSpeakers: return "Stereo speakers"
        case .headphones: return "Headphones · Stereo"
        case .virtualHeadphones(let layout): return "Virtual \(layout) → Headphones"
        case .multichannel(let system): return system
        }
    }

    /// At most three names, then "and N more".
    static func dynamicsLine(_ names: [String]) -> String {
        guard !names.isEmpty else { return "Nothing switched on" }
        let shown = names.prefix(maxDynamicsNames).joined(separator: " · ")
        let more = names.count - maxDynamicsNames
        return more > 0 ? "\(shown) and \(more) more" : shown
    }

    static func speakersLine(_ i: DashboardInputs) -> String {
        if let routing = i.routing {
            let s = routing.speakers, w = routing.ways
            return "\(s) \(s == 1 ? "speaker" : "speakers") · \(w) \(w == 1 ? "way" : "ways")"
        }
        guard i.bassManagementEnabled else { return "\(i.systemName) · Bass management off" }
        return "\(i.systemName) · \(i.crossoverHz) Hz \(i.crossoverName)"
    }

    static func correctionLine(_ i: DashboardInputs) -> String {
        if i.correctionEnabled { return i.correctionFilterName ?? "On" }
        if let name = i.correctionFilterName { return "\(name) is loaded but off" }
        return "No correction measured yet"
    }

    static func acousticsLine(_ a: DashboardAcoustics) -> String {
        switch a {
        case .faulted: return "Stopped safely after a problem"
        case .active(let sources): return "On · \(sources) \(sources == 1 ? "source" : "sources")"
        case .transitioning(let percent): return "Changing · \(percent)%"
        case .ready: return "Ready, not reducing noise yet"
        case .staged: return "Ready for the next start"
        case .notSetUp: return "Not set up"
        }
    }

    // MARK: Volume text (the Dashboard shows the level as a number; the menu bar owns the control)

    static func volumeReadout(level: Double, softwareControl: Bool, usesDecibels: Bool) -> String {
        if softwareControl, usesDecibels {
            return VolumeFeedbackPresentation.decibelReadout(
                MasterVolumeConfiguration.softwareTaperDB(forLevel: level), alwaysTenths: true)
        }
        let percent = String(format: "%.1f%%", level * 100)
        guard softwareControl else { return percent }
        guard let db = MasterVolumeConfiguration.softwareTaperDB(forLevel: level) else { return percent + " · −∞ dB" }
        return percent + String(format: " · %.1f dB", db)
    }

    /// Short readouts for the VU meter's loudness line.
    static func lufsText(_ value: Double?) -> String { value.map { String(format: "%.1f LUFS", $0) } ?? "—" }
    static func truePeakText(_ value: Double?) -> String { value.map { String(format: "%.1f dBTP", $0) } ?? "—" }
}
