import Foundation

/// E19 S6 (G17, G19): applies the headroom budgets of the chain after the MIMO stage to a design request, and re-checks
/// the designed stage against the hard limit. Both run on the headroom worker (`HeadroomRecompute`), never on the main
/// actor or an audio callback.
enum MIMOGraphHeadroom {
    enum Failure: Error, Equatable {
        /// A source lane's headroom could not be bounded (the model named an unbounded stage).
        case chainNotBounded(source: Int, stages: [String])
        /// The designed stage needs more output trim than the allowance: source index and the trim it needs (dB).
        case overBudget(source: Int, neededDB: Double)
        case graph(String)
    }

    /// `configuration` is the graph the stage will join (its own `mimo` is ignored). Returns the request with every
    /// included source's `gainLimitDB` capped by the budget of its output (G17). A source whose chain cannot be bounded
    /// is refused by name; a budget below 0 dB refuses as `.headroom`.
    static func budgetedRequest(
        _ request: MIMOTreatmentRequest, configuration: UnifiedGraphConfiguration, sourceLanes: [Int],
        strict: Bool = false, trimsDB: [Int: Double] = [:]
    ) async throws -> MIMOTreatmentRequest {
        var bare = configuration
        bare.mimo = nil
        let spec: UnifiedGraphSpec
        do { spec = try bare.makeSpec() } catch { throw Failure.graph(String(describing: error)) }
        let results = await HeadroomRecompute.run(
            spec: spec, laneCount: Int(spec.outputChannels), strict: strict, trimsDB: trimsDB)
        var headrooms: [OutputHeadroom?] = []
        for (source, lane) in sourceLanes.enumerated() {
            let result = results.first { $0.lane == lane }
            if let result, !result.isComplete, source < request.sources.count, !request.sources[source].excluded {
                throw Failure.chainNotBounded(source: source, stages: result.incomplete.sorted())
            }
            headrooms.append(result)
        }
        return try request.applyingHeadroomBudgets(headrooms)
    }

    /// Runs the model on the graph with the designed stage and confirms every source's output fits its hard-limit
    /// headroom: the trim the stage needs is at most the allowance (G19).
    static func verifyDesignedStage(
        configuration: UnifiedGraphConfiguration, stage: UnifiedGraphMIMOStage, strict: Bool = false,
        trimAllowanceDB: Double = N60_HEADROOM_MIMO_TRIM_ALLOWANCE_DB
    ) async throws {
        var with = configuration
        with.mimo = stage
        let spec: UnifiedGraphSpec
        do { spec = try with.makeSpec() } catch { throw Failure.graph(String(describing: error)) }
        let results = await HeadroomRecompute.run(
            spec: spec, laneCount: Int(spec.outputChannels), strict: strict, trimsDB: [:])
        for (source, lane) in stage.sourceLanes.enumerated() {
            guard let result = results.first(where: { $0.lane == lane }) else { continue }
            guard result.isComplete else { throw Failure.chainNotBounded(source: source, stages: result.incomplete.sorted()) }
            if result.neededDB > trimAllowanceDB + 0.05 { throw Failure.overBudget(source: source, neededDB: result.neededDB) }
        }
    }
}
