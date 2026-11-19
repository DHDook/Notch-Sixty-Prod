import Foundation

/// E33 S18 (G35): the single table that says which lanes the Equalizer reaches on a stereo, N-channel, routed or Virtual
/// Speakers (binaural) session, per channel mode, and which curve each lane gets. `UnifiedGraphProgramDSP.apply` takes
/// its EQ lane set from here and the Equalizer page prints its one-line "Applies to" text from here, so the page, the
/// translator and the tests cannot drift apart.
///
/// Realtime: none. Pure value logic, built off the audio thread. Sample rate and channel count: independent of both.
///
/// The table (L/R pairs are the layout's left/right members; the LFE and any unpaired lane are never part of a pair):
/// - Linked: every lane except the LFE runs the one linked curve (centre and surrounds included).
/// - Independent: left members run the left curve, right members the right curve; centre, LFE and unpaired lanes pass through.
/// - Mid/Side: every lane except the LFE is covered. Each pair is encoded to mid/side, the mid curve runs on the pair's
///   left member and the side curve on its right member, then the pair is decoded. A lane with no pair partner (the centre)
///   runs the mid curve alone, with no encode or decode. The LFE passes through.
enum EQSessionReach {
    struct Reach: Equatable, Sendable {
        /// Lanes that run a curve, ascending.
        var covered: [Int]
        /// Lanes that run the first curve (left, or mid), ascending.
        var firstCurveLanes: [Int]
        /// Lanes that run the second curve (right, or side), ascending.
        var secondCurveLanes: [Int]
        /// Lanes the Equalizer does not touch, ascending.
        var passThrough: [Int]
        /// Lanes that go through a mid/side encode and decode (Mid/Side only).
        var midSideLanes: [Int]
    }

    static func reach(shape: UnifiedGraphLayoutShape, mode: UnifiedGraphProgramDSP.EQMode) -> Reach {
        let all = Array(0..<shape.laneCount)
        let nonLFE = all.filter { $0 != shape.lfeLane }
        let rights = Set(shape.rightMembers)
        let covered: [Int]
        var first: [Int]
        var second: [Int]
        var midSide: [Int] = []
        switch mode {
        case .linked:
            covered = nonLFE
            first = nonLFE
            second = []
        case .independent:
            covered = (shape.leftMembers + shape.rightMembers).sorted()
            first = shape.leftMembers
            second = shape.rightMembers
        case .midSide:
            covered = nonLFE
            first = nonLFE.filter { !rights.contains($0) }
            second = nonLFE.filter { rights.contains($0) }
            midSide = shape.pairs.flatMap { [$0.a, $0.b] }
        }
        let coveredSet = Set(covered)
        return Reach(
            covered: covered, firstCurveLanes: first.sorted(), secondCurveLanes: second.sorted(),
            passThrough: all.filter { !coveredSet.contains($0) }, midSideLanes: midSide.sorted())
    }

    /// The one line the Equalizer page shows. A two-lane shape is a stereo session and reads plainly.
    static func pageText(
        shape: UnifiedGraphLayoutShape, mode: UnifiedGraphProgramDSP.EQMode, virtualSpeakers: Bool
    ) -> String {
        let r = reach(shape: shape, mode: mode)
        let tail = virtualSpeakers ? " (the virtual speakers, before binaural rendering)" : ""
        if shape.laneCount == 2, !virtualSpeakers {
            switch mode {
            case .linked: return "Applies to left and right"
            case .independent: return "Applies to left and right, each with its own bands"
            case .midSide: return "Applies to the mid and side of left and right"
            }
        }
        switch mode {
        case .linked:
            let base = shape.lfeLane != nil ? "Applies to all speakers except the LFE" : "Applies to all speakers"
            return base + tail
        case .independent:
            var passing: [String] = []
            if let centre = shape.centerLane, r.passThrough.contains(centre) { passing.append("centre") }
            if let lfe = shape.lfeLane, r.passThrough.contains(lfe) { passing.append("LFE") }
            let others = r.passThrough.filter { $0 != shape.centerLane && $0 != shape.lfeLane }
            if !others.isEmpty { passing.append("unpaired speakers") }
            let base = "Applies to the left and right pairs"
            return (passing.isEmpty ? base : base + "; " + passing.joined(separator: ", ") + " pass through") + tail
        case .midSide:
            var base = shape.lfeLane != nil ? "Applies to all speakers except the LFE" : "Applies to all speakers"
            base += "; mid/side acts on each left and right pair"
            if let centre = shape.centerLane, r.covered.contains(centre) { base += ", the centre takes the mid bands" }
            return base + tail
        }
    }
}
