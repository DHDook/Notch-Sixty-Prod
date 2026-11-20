import Foundation

/// E33 S26 (G51): how a band's biquad sections are designed. `cookbook` is the bilinear (RBJ) design every saved EQ has
/// always used; `matched` keeps the analogue shape of a peak, shelf, low pass, high pass or band pass near the top of the
/// band (docs/MATCHED_EQ_FILTERS.md). A band stores `nil` for the cookbook, so old profiles decode and encode unchanged.
enum EQFilterMethod: String, Codable, Sendable {
    case cookbook
    case matched
}

extension EQBand {
    /// A copy with a new identity that keeps every setting, including the filter method (a copy or paste must not change
    /// how the band sounds).
    func withID(_ id: UUID) -> EQBand {
        var copy = EQBand(
            id: id, enabled: enabled, type: type, frequencyHz: frequencyHz, gainDB: gainDB, q: q, slope: slope,
            constantQ: constantQ, linkwitzTargetHz: linkwitzTargetHz, linkwitzTargetQ: linkwitzTargetQ,
            firKernel: firKernel, dynamic: dynamic)
        copy.filterMethod = filterMethod
        return copy
    }

    /// True when this band asks for the matched design and the design applies to it. Dynamic bands, notch, all-pass,
    /// Linkwitz, FIR, first-order shelves and low or high passes above 12 dB/oct keep the cookbook.
    var usesMatchedFilters: Bool { filterMethod == .matched && matchedFilterApplies }

    /// Whether the matched design exists for this band's shape (independent of the stored method), for the page's offer.
    var matchedFilterApplies: Bool {
        if dynamic.enabled { return false }
        switch type {
        case .peaking, .bandPass, .tilt: return true
        case .lowShelf, .highShelf: return slope.order.isMultiple(of: 2)
        case .lowPass, .highPass: return slope.order == 2
        case .linkwitzTransform, .fir, .notch, .allPass: return false
        }
    }

    /// The matched section type for one second-order section of `type` (graph.h N60_PEQ_SECTION_MATCHED_BASE + base).
    static func matchedSectionType(_ type: EQFilterType, constantQ: Bool) -> N60BiquadFilterType? {
        switch type {
        case .peaking: return constantQ ? N60BiquadFilterTypeMatchedPeakingConstantQ : N60BiquadFilterTypeMatchedPeaking
        case .lowShelf: return N60BiquadFilterTypeMatchedLowShelf
        case .highShelf: return N60BiquadFilterTypeMatchedHighShelf
        case .lowPass: return N60BiquadFilterTypeMatchedLowPass
        case .highPass: return N60BiquadFilterTypeMatchedHighPass
        case .bandPass: return N60BiquadFilterTypeMatchedBandPass
        default: return nil
        }
    }

    /// The band's sections with matched coefficients, or nil when the band uses the cookbook (the caller then designs it
    /// as before). The coefficients come from the core entry point every other consumer uses, so the drawn curve, the
    /// linear-phase design and the engine agree.
    func matchedSections(sampleRate: Double) throws -> [N60BiquadBandSnapshot]? {
        guard usesMatchedFilters else { return nil }
        func section(_ baseType: EQFilterType, gainDB: Double, q: Double) throws -> N60BiquadBandSnapshot {
            guard let sectionType = Self.matchedSectionType(baseType, constantQ: constantQ && baseType == .peaking) else {
                throw EQConfigurationError.invalidBand(index: 0)
            }
            var c = [Double](repeating: 0, count: 5)
            guard n60_eq_design_section(UInt32(sectionType.rawValue), sampleRate, frequencyHz, gainDB, q, &c) == 1 else {
                throw EQConfigurationError.invalidBand(index: 0)
            }
            var result = N60BiquadBandSnapshot()
            result.enabled = true
            result.type = sectionType
            result.frequencyHz = frequencyHz
            result.gainDB = gainDB
            result.q = q
            result.coefficients = N60BiquadCoefficients(b0: Float(c[0]), b1: Float(c[1]), b2: Float(c[2]), a1: Float(c[3]), a2: Float(c[4]))
            return result
        }
        switch type {
        case .tilt:
            // Same convention as the cookbook tilt: gainDB is the low-to-high differential, split into two shelves.
            return [try section(.lowShelf, gainDB: -gainDB * 0.5, q: 0.707), try section(.highShelf, gainDB: gainDB * 0.5, q: 0.707)]
        case .lowShelf, .highShelf:
            let pairs = slope.order / 2
            guard pairs <= Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND) else { throw EQConfigurationError.invalidBand(index: 0) }
            let each = gainDB * 2.0 / Double(slope.order)
            return try (0..<pairs).map { _ in try section(type, gainDB: each, q: q) }
        default:
            return [try section(type, gainDB: type == .peaking ? gainDB : 0, q: q)]
        }
    }
}
