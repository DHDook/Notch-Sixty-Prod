import Foundation

/// E9 S5b: the user's per-output protection settings (`e9.output-protection`). They live in `DynamicsConfiguration`, so they
/// persist with the other Dynamics settings; the graph reads them through `UnifiedGraphOutputProtection`. The always-on hard
/// limit is not part of this: no setting here can lower or remove it.
struct OutputProtectionSettings: Equatable, Codable, Sendable {
    /// One output lane's override of the program protection settings.
    struct Lane: Equatable, Codable, Sendable {
        /// false parks the lane's user protection: its ceiling moves up to the hard ceiling (the stage keeps its look-ahead
        /// and oversampling, so every output still reports the same latency, and the change is a live parameter edit).
        var enabled = true
        /// nil follows the program ceiling. Always held between `ceilingRangeDB` and the hard ceiling.
        var ceilingDB: Double?

        init(enabled: Bool = true, ceilingDB: Double? = nil) {
            self.enabled = enabled
            self.ceilingDB = ceilingDB
        }
    }

    static let ceilingRangeDB: ClosedRange<Double> = -20 ... Double(UnifiedGraphOutputProtection.hardLimitCeilingDB)

    /// The Advanced "Independent per output" switch.
    var independent = false
    /// Overrides by output lane index (program lanes first, then sub lanes). Absent means the defaults.
    var lanes: [Int: Lane] = [:]

    init(independent: Bool = false, lanes: [Int: Lane] = [:]) {
        self.independent = independent
        self.lanes = lanes
    }

    func lane(_ index: Int) -> Lane { lanes[index] ?? Lane() }

    /// Stores `lane` for `index`; a lane equal to the defaults is dropped so equal settings compare equal.
    mutating func set(_ lane: Lane, at index: Int) {
        var value = lane
        if let ceiling = value.ceilingDB {
            value.ceilingDB = ceiling.isFinite ? min(max(ceiling, Self.ceilingRangeDB.lowerBound), Self.ceilingRangeDB.upperBound) : nil
        }
        if value == Lane() { lanes[index] = nil } else { lanes[index] = value }
    }
}
