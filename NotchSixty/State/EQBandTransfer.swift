import Foundation

/// E33 S2 (designs 4 and 5): the pure edits behind the Equalizer page's Import, Export, copy, paste and
/// "Copy lane to..." commands. Each function returns the new `StereoEQConfiguration` so the page can apply it
/// with one `replaceStereoEQConfiguration` and record exactly one undo step. No UI, no engine.
enum EQLane: String, CaseIterable, Identifiable, Sendable {
    case linked, left, right, mid, side

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .linked: "Linked"
        case .left: "Left"
        case .right: "Right"
        case .mid: "Mid"
        case .side: "Side"
        }
    }
}

extension StereoEQConfiguration {
    func bands(in lane: EQLane) -> [EQBand] {
        switch lane {
        case .linked: linkedBands
        case .left: leftBands
        case .right: rightBands
        case .mid: midBands
        case .side: sideBands
        }
    }

    mutating func setBands(_ bands: [EQBand], in lane: EQLane) {
        switch lane {
        case .linked: linkedBands = bands
        case .left: leftBands = bands
        case .right: rightBands = bands
        case .mid: midBands = bands
        case .side: sideBands = bands
        }
    }

    /// The lane the page is editing now.
    var editLane: EQLane {
        switch channelMode {
        case .linked: .linked
        case .independent: editChannel == .right ? .right : .left
        case .midSide: editChannel == .side ? .side : .mid
        }
    }
}

enum EQBandTransfer {
    enum ImportMode: Sendable { case replace, append }

    enum TransferError: Error, Equatable, LocalizedError {
        case nothingToImport
        case tooManyBands(total: Int)
        case nothingToPaste

        var errorDescription: String? {
            switch self {
            case .nothingToImport: "The text has no usable filters."
            case .tooManyBands(let total):
                "That would make \(total) bands; the EQ holds \(EQConfiguration.maximumBandCount). Nothing was changed."
            case .nothingToPaste: "There are no EQ bands on the clipboard."
            }
        }
    }

    struct Outcome: Equatable {
        var configuration: StereoEQConfiguration
        /// Skipped lines and clamped values, in plain words.
        var notes: [String]
        var addedIDs: [UUID]
    }

    /// Bands imported from APO text into the lane being edited. Values are clamped by the import rule and
    /// each clamp is reported. Fresh band IDs; the lane's other settings are untouched.
    static func importing(_ parsed: EqualizerAPOCodec.Parsed, into configuration: StereoEQConfiguration,
                          mode: ImportMode) throws -> Outcome {
        guard !parsed.bands.isEmpty else { throw TransferError.nothingToImport }
        var notes = parsed.issues
        let bands = parsed.bands.enumerated().map { offset, band -> EQBand in
            let clamped = EQBandRules.sanitizedForImport(band)
            if clamped != band { notes.append("Filter \(offset + 1): values were limited to the supported range.") }
            return clamped
        }
        return try adding(bands, to: configuration, replacing: mode == .replace, notes: notes)
    }

    /// Bands pasted into the lane being edited (appended, fresh IDs).
    static func pasting(_ bands: [EQBand], into configuration: StereoEQConfiguration) throws -> Outcome {
        guard !bands.isEmpty else { throw TransferError.nothingToPaste }
        return try adding(bands.map(EQBandSanitisedCopy.fitted), to: configuration, replacing: false, notes: [])
    }

    private static func adding(_ incoming: [EQBand], to configuration: StereoEQConfiguration,
                               replacing: Bool, notes: [String]) throws -> Outcome {
        let fresh = incoming.map { band -> EQBand in
            band.withID(UUID())
        }
        let existing = replacing ? [] : configuration.editableBands
        let total = existing.count + fresh.count
        guard total <= EQConfiguration.maximumBandCount else { throw TransferError.tooManyBands(total: total) }
        var result = configuration
        result.replaceEditableBands(existing + fresh)
        return Outcome(configuration: result, notes: notes, addedIDs: fresh.map(\.id))
    }

    /// The lanes "Copy lane to..." offers from the lane being edited: the partner lane, then the linked bank
    /// (or, from the linked bank, every other bank).
    static func copyTargets(for configuration: StereoEQConfiguration) -> [EQLane] {
        // E33 S20 part 2: a speaker group's list is not a stereo lane, so there is nothing to copy it to.
        guard configuration.editGroupKey == nil else { return [] }
        let lane = configuration.editLane
        switch configuration.channelMode {
        case .linked: return [EQLane.left, EQLane.right, EQLane.mid, EQLane.side]
        case .independent: return [lane == EQLane.left ? EQLane.right : EQLane.left, EQLane.linked]
        case .midSide: return [lane == EQLane.mid ? EQLane.side : EQLane.mid, EQLane.linked]
        }
    }

    /// Replaces `target` with a copy of `source` (fresh IDs). A bank that has not been seeded is marked
    /// seeded so switching channel mode later does not overwrite the copy.
    static func copyLane(_ source: EQLane, to target: EQLane, in configuration: StereoEQConfiguration) -> StereoEQConfiguration {
        guard source != target else { return configuration }
        var result = configuration
        let copied = configuration.bands(in: source).map { band in
            band.withID(UUID())
        }
        result.setBands(copied, in: target)
        switch target {
        case .left, .right: result.independentSeeded = true
        case .mid, .side: result.midSideSeeded = true
        case .linked: break
        }
        return result
    }
}

/// Pasted bands pass the same range clamp as an import so a stray value never reaches the engine.
private enum EQBandSanitisedCopy {
    static func fitted(_ band: EQBand) -> EQBand { band.type == .fir ? band : EQBandRules.sanitizedForImport(band) }
}

/// The two forms a copy leaves on the clipboard: private JSON of the bands (exact), and APO text (for other
/// apps, and for pasting APO text in).
enum EQBandClipboard {
    static let privateTypeIdentifier = "com.notchsixty.eq-bands"

    struct Payload: Codable, Equatable { var version = 1; var bands: [EQBand] }

    static func encode(_ bands: [EQBand]) -> (data: Data, text: String)? {
        guard !bands.isEmpty, let data = try? JSONEncoder().encode(Payload(bands: bands)) else { return nil }
        return (data, EqualizerAPOCodec.write(bands: bands).text)
    }

    /// Bands from the private JSON when present, else from APO text.
    static func decode(data: Data?, text: String?) -> [EQBand] {
        if let data, let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1 {
            return payload.bands
        }
        if let text { return EqualizerAPOCodec.parse(text).bands }
        return []
    }
}
