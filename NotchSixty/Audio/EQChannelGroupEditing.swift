import Foundation

// E33 S20 part 2 (G39): how the Equalizer page edits one speaker group's list. The chosen group is page state on the
// configuration (`editGroupKey`); `editableBands` then reads and writes that group's list, so every ordinary edit,
// undo step, A/B slot, import and paste follows it with no second code path.
//
// Realtime: none. Control plane only; nothing here runs on the audio thread, and choosing a group publishes nothing.

/// A group list holds static biquad bands only. Each case names the band type or the group.
enum EQGroupBandError: Error, LocalizedError, Equatable {
    case unsupportedType(group: String, type: String)
    case dynamicBand(group: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let group, let type):
            return "\(group) bands must be ordinary filters: a \(type) band cannot be used on one speaker group."
        case .dynamicBand(let group):
            return "\(group) bands cannot be dynamic: switch Dynamic off for the band, or edit it under All."
        }
    }
}

extension StereoEQConfiguration {
    /// The storage rules for every list, session and group (the engine calls this before any edit lands). Group lists
    /// also refuse bands a plain biquad cannot carry, by name.
    func validateStorage(sampleRate: Double?) throws {
        for bands in [linkedBands, leftBands, rightBands, midBands, sideBands] {
            guard bands.count <= EQConfiguration.maximumBandCount else {
                throw EQConfigurationError.tooManyBands(bands.count)
            }
            for (index, band) in bands.enumerated() where band.enabled {
                _ = try EQBandRules.validate(band, index: index, sampleRate: sampleRate)
            }
        }
        for (key, bands) in groupBandLists.sorted(by: { $0.key < $1.key }) {
            let group = EQChannelGroup(rawValue: String(key.split(separator: "/").last ?? "")) ?? .fronts
            guard bands.count <= EQConfiguration.maximumBandCount else {
                throw EQConfigurationError.tooManyBands(bands.count)
            }
            for (index, band) in bands.enumerated() {
                if band.type == .fir || band.type == .linkwitzTransform {
                    throw EQGroupBandError.unsupportedType(group: group.displayName, type: band.type.displayName)
                }
                if band.dynamic.enabled { throw EQGroupBandError.dynamicBand(group: group.displayName) }
                if band.enabled { _ = try EQBandRules.validate(band, index: index, sampleRate: sampleRate) }
            }
        }
    }

    /// The group being edited, when the key belongs to `roleCodes`' layout; nil means "All".
    func editGroup(roleCodes: [UInt32]) -> EQChannelGroup? {
        guard let key = editGroupKey else { return nil }
        return EQChannelGroup.allCases.first { key == EQChannelGroup.editKey($0, roleCodes: roleCodes) }
    }

    /// "Centre", "Fronts" and so on for the list being edited; nil under All.
    var editGroupName: String? {
        editGroupKey.flatMap { EQChannelGroup(rawValue: String($0.split(separator: "/").last ?? ""))?.displayName }
    }

    mutating func setEditGroup(_ group: EQChannelGroup?, roleCodes: [UInt32]) {
        editGroupKey = group.map { EQChannelGroup.editKey($0, roleCodes: roleCodes) }
    }

    /// The boost, in dB, that the group's list adds at its peak on top of the session curve: the page's per-group
    /// readout. Static bands only (the lists accept nothing else); zero for an empty or cut-only list.
    func groupPeakBoostDB(_ group: EQChannelGroup, roleCodes: [UInt32], sampleRate: Double) -> Double {
        let bands = groupBands(group, roleCodes: roleCodes).filter(\.enabled)
        guard !bands.isEmpty else { return 0 }
        let sections = ProductionEQResponseMath.compile(bands: bands, sampleRate: sampleRate)
        let grid = EQHeadroomPredictor.grid(sampleRate: sampleRate, bandCentres: bands.map(\.frequencyHz))
        let peak = grid.map { EQHeadroomPredictor.response(sections, sampleRate: sampleRate, frequency: $0).magnitude }.max() ?? 1
        return max(0, 20 * log10(peak))
    }
}

extension EQChannelGroup {
    /// The `groupBandLists` key of a group in a layout (the same key `groupBands` reads).
    static func editKey(_ group: EQChannelGroup, roleCodes: [UInt32]) -> String {
        layoutKey(roleCodes: roleCodes) + "/" + group.rawValue
    }
}

extension AudioIOEngine {
    /// The role code of every lane of the running session (empty before one starts or on stereo): what decides the
    /// groups the Equalizer offers.
    var eqGroupRoleCodes: [UInt32] {
        guard let shape = dynamicsSessionDescription?.shape, shape.laneCount > 2 else { return [] }
        return shape.roleCodes
    }

    /// Chooses the group the Equalizer page edits (nil: All). Page state: nothing is republished, and an edit made
    /// afterwards goes through the normal setters on that group's list.
    func setEQEditGroup(_ group: EQChannelGroup?) throws {
        var updated = stereoEQConfiguration
        updated.setEditGroup(group, roleCodes: eqGroupRoleCodes)
        try replaceStereoEQConfiguration(updated)
    }
}
