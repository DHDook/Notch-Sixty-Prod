import Foundation

// E12 S15 (G14, G15, G20): what the Overview checklist needs to know about a calibration. A record holds the passing
// verification (design ID and date), the moment the user said "I moved something", and a stamp of the things whose
// change makes a calibration out of date. Pure value types: no engine, no SwiftUI.

/// A stable fingerprint of one part of the system. FNV-1a over sorted-key JSON, so the same value always gives the
/// same number across launches.
enum SystemCalibrationFingerprint {
    static func of<T: Encodable>(_ value: T?) -> UInt64 {
        guard let value else { return 0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}

/// The parts of a system whose change makes a calibration out of date (G20). The sample rate is deliberately not
/// here: designs are built and cached per output rate, so a rate change does not invalidate the calibration.
struct SystemCalibrationStamp: Codable, Equatable, Sendable {
    var outputUID: String?
    var arrangement: UInt64
    /// Output routes and the speaker routing structure (endpoints, matrix, filters), with trims removed.
    var routing: UInt64
    /// The bass crossover (frequency, topology, mode), with the sub trim and polarity removed.
    var crossover: UInt64
    /// Manual trim, delay and polarity: per-way trim, delay and polarity, sub gain and sub polarity.
    var trims: UInt64

    init(
        outputUID: String?, arrangement: SystemArrangement?, outputRouting: MultiOutputRoutingConfiguration?,
        speakerRouting: SpeakerRoutingConfiguration?, bass: BassManagementConfiguration
    ) {
        self.outputUID = outputUID
        self.arrangement = SystemCalibrationFingerprint.of(arrangement)

        var neutralRouting = speakerRouting
        var trimValues: [Double] = []
        if var routing = neutralRouting {
            for s in routing.speakers.indices {
                for w in routing.speakers[s].ways.indices {
                    let way = routing.speakers[s].ways[w]
                    trimValues += [way.trimDB, way.polarityInverted ? 1 : 0, way.delayMilliseconds]
                    routing.speakers[s].ways[w].trimDB = 0
                    routing.speakers[s].ways[w].polarityInverted = false
                    routing.speakers[s].ways[w].delayMilliseconds = 0
                }
            }
            neutralRouting = routing
        }
        self.routing = SystemCalibrationFingerprint.of([
            SystemCalibrationFingerprint.of(outputRouting), SystemCalibrationFingerprint.of(neutralRouting)])

        var neutralBass = bass
        neutralBass.subGainDB = 0
        neutralBass.subPolarityInverted = false
        self.crossover = SystemCalibrationFingerprint.of(neutralBass)
        trimValues += [bass.subGainDB, bass.subPolarityInverted ? 1 : 0]
        self.trims = SystemCalibrationFingerprint.of(trimValues)
    }

    /// The reasons this stamp differs from `other`, in a fixed order.
    func changes(from recorded: SystemCalibrationStamp) -> [SystemCalibrationChange] {
        var result: [SystemCalibrationChange] = []
        if outputUID != recorded.outputUID { result.append(.output) }
        if arrangement != recorded.arrangement { result.append(.arrangement) }
        if routing != recorded.routing { result.append(.routing) }
        if crossover != recorded.crossover { result.append(.crossover) }
        if trims != recorded.trims { result.append(.trims) }
        return result
    }
}

enum SystemCalibrationChange: String, Equatable, Sendable {
    case output, arrangement, routing, crossover, trims, moved

    /// The reason in plain words, as shown on the row and on the Dashboard.
    var reason: String {
        switch self {
        case .output: return "the output device changed"
        case .arrangement: return "the speaker arrangement changed"
        case .routing: return "the output routing changed"
        case .crossover: return "the crossover changed"
        case .trims: return "a trim, delay or polarity changed"
        case .moved: return "you said something moved"
        }
    }
}

/// Stored with a system profile. `stamp` is nil until a correction is deployed or verified.
struct SystemCalibrationRecord: Codable, Equatable, Sendable {
    var verifiedDesignID: UUID?
    var verifiedDate: Date?
    var stamp: SystemCalibrationStamp?
    var stampDate: Date?
    /// "I moved something": set by the user, cleared when a new calibration is stamped.
    var movedDate: Date?

    /// Out-of-date reasons for the live system. Age alone is never a reason.
    func outOfDateReasons(current: SystemCalibrationStamp) -> [SystemCalibrationChange] {
        var reasons = stamp.map { current.changes(from: $0) } ?? []
        if movedDate != nil { reasons.append(.moved) }
        return reasons
    }
}

// MARK: Overview checklist (G15)

enum SystemChecklistState: Equatable {
    case done, notDone, outOfDate
}

enum SystemChecklistRowID: String, CaseIterable, Equatable {
    case arrangement, alignment, bass, correction, verification

    var title: String {
        switch self {
        case .arrangement: return "Arrangement"
        case .alignment: return "Levels and alignment"
        case .bass: return "Bass"
        case .correction: return "Correction"
        case .verification: return "Verification"
        }
    }

    /// Where the row's button goes.
    var tab: ProductionSystemTab {
        switch self {
        case .arrangement: return .speakers
        case .alignment, .bass, .correction: return .calibrate
        case .verification: return .calibrate
        }
    }

    var calibrateSection: ProductionCalibrateSection? {
        switch self {
        case .alignment: return .alignment
        case .bass, .correction, .verification: return .correction
        case .arrangement: return nil
        }
    }

    var buttonTitle: String {
        switch self {
        case .arrangement: return "Open Speakers"
        case .alignment: return "Open Alignment"
        case .bass, .correction: return "Open Bass and correction"
        case .verification: return "Open Bass and correction"
        }
    }
}

struct SystemChecklistRow: Identifiable, Equatable {
    var rowID: SystemChecklistRowID
    var state: SystemChecklistState
    var date: Date?
    var summary: String
    var reason: String?
    var isNextStep = false
    var id: String { rowID.rawValue }
}

/// What the checklist reads from the system, as plain values.
struct SystemChecklistInputs: Equatable {
    var arrangementSummary: String?
    var alignmentConfigured = false
    var alignmentSummary = ""
    var bassEnabled = false
    var bassSummary = ""
    var calibration: RoomCorrectionCalibrationSummary?
    var record: SystemCalibrationRecord?
    var current: SystemCalibrationStamp?
}

enum SystemChecklistModel {
    /// The live reasons the calibration is out of date; empty when nothing was calibrated.
    static func outOfDateReasons(_ i: SystemChecklistInputs) -> [SystemCalibrationChange] {
        guard i.calibration != nil || i.alignmentConfigured || i.bassEnabled, let record = i.record, let current = i.current
        else { return [] }
        return record.outOfDateReasons(current: current)
    }

    static func reasonText(_ reasons: [SystemCalibrationChange]) -> String? {
        guard !reasons.isEmpty else { return nil }
        let text = reasons.map(\.reason).joined(separator: ", ")
        return "Out of date: " + text + "."
    }

    static func rows(_ i: SystemChecklistInputs) -> [SystemChecklistRow] {
        let reasons = outOfDateReasons(i)
        let stale = reasonText(reasons)
        let status = SystemCalibrationStatus.resolve(summary: i.calibration, verifiedDesignID: i.record?.verifiedDesignID)

        func measured(_ done: Bool, summary: String, empty: String, date: Date?) -> SystemChecklistRow.Fields {
            if !done { return .init(state: .notDone, date: nil, summary: empty, reason: nil) }
            if let stale { return .init(state: .outOfDate, date: date, summary: summary, reason: stale) }
            return .init(state: .done, date: date, summary: summary, reason: nil)
        }

        var list: [SystemChecklistRow] = []
        // The arrangement is a choice, so only an arrangement change (or a move) makes it stale.
        list.append(.make(.arrangement, .init(
            state: i.arrangementSummary == nil ? .notDone : .done, date: nil,
            summary: i.arrangementSummary ?? "No arrangement chosen yet.", reason: nil)))
        list.append(.make(.alignment, measured(
            i.alignmentConfigured, summary: i.alignmentSummary, empty: "No levels, delays or polarity set.",
            date: i.record?.stampDate)))
        list.append(.make(.bass, measured(
            i.bassEnabled, summary: i.bassSummary, empty: "Bass management is off.", date: i.record?.stampDate)))
        list.append(.make(.correction, measured(
            i.calibration != nil,
            summary: i.calibration.map { "\"\($0.targetName)\" from \($0.positionCount) position(s)." } ?? "",
            empty: "No room correction.", date: i.calibration?.designDate)))

        let verification: SystemChecklistRow.Fields
        switch status {
        case .notCalibrated:
            verification = .init(state: .notDone, date: nil, summary: "Nothing to verify yet.", reason: nil)
        case .unverified:
            verification = .init(state: .notDone, date: nil, summary: "The correction has no passing verification.", reason: nil)
        case .verified:
            let date = i.record?.verifiedDate
            verification = stale.map { .init(state: .outOfDate, date: date, summary: "Passed verification.", reason: $0) }
                ?? .init(state: .done, date: date, summary: "Passed verification.", reason: nil)
        }
        list.append(.make(.verification, verification))

        if let next = list.firstIndex(where: { $0.state != .done }) { list[next].isNextStep = true }
        return list
    }
}

extension SystemChecklistRow {
    struct Fields: Equatable {
        var state: SystemChecklistState
        var date: Date?
        var summary: String
        var reason: String?
    }

    static func make(_ id: SystemChecklistRowID, _ f: Fields) -> SystemChecklistRow {
        SystemChecklistRow(rowID: id, state: f.state, date: f.date, summary: f.summary, reason: f.reason)
    }
}
