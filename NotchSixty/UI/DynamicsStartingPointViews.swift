import SwiftUI

/// E33 S15 (G25): the Dynamics page's "Start from" menu. Choosing a starting point is one ordinary, undoable edit of the live
/// Dynamics; it leaves the selected content preset dirty and never saves. When the page already differs from the selected
/// preset (unsaved Dynamics edits) the menu asks first.
struct DynamicsStartFromMenu: View {
    /// True when the live Dynamics differ from the selected preset's.
    let hasUnsavedDynamicsEdits: () -> Bool
    let apply: (DynamicsStartingPoint) -> Void
    @State private var pending: DynamicsStartingPoint?

    var body: some View {
        Menu("Start from") {
            ForEach(DynamicsStartingPoint.allCases) { point in
                Button(point.title) { choose(point) }
                    .help(point.intent)
                    .accessibilityIdentifier("dynamics.startFrom.\(point.rawValue)")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Fill in the level controls for a goal. It is an ordinary edit: the EQ and plug-ins are not touched, and nothing is saved until you save the preset.")
        .accessibilityIdentifier("dynamics.startFrom")
        .confirmationDialog(
            pending.map { "Replace your Dynamics edits with \($0.title)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace") { if let point = pending { apply(point) }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("The unsaved changes you made to Dynamics are overwritten. Edit > Undo brings them back.")
        }
    }

    private func choose(_ point: DynamicsStartingPoint) {
        if hasUnsavedDynamicsEdits() { pending = point } else { apply(point) }
    }
}

/// E33 S15 (G27): one line on the Limiter card saying output protection follows the limiter, and which of the two is acting now.
struct LimiterProtectionLineView: View {
    var engine: AudioIOEngine
    let limiterOn: Bool
    @ObservedObject var monitor: GainReductionMonitor
    @State private var protectionDB: Float = 0

    var body: some View {
        let running = engine.lifecycleState == .running
        let acting = LimiterProtectionLine.acting(limiterDB: monitor.latest(.limiter), protectionDB: protectionDB)
        Text(LimiterProtectionLine.text(limiterOn: limiterOn, running: running, acting: acting))
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("dynamics.limiter.protectionLine")
            .task { await poll() }
    }

    @MainActor
    private func poll() async {
        let hub = ProductionMeterHub.shared(for: engine)
        let token = hub.subscribe(hertz: 8)
        defer { hub.unsubscribe(token) }
        while !Task.isCancelled {
            let taken = hub.take(token)
            if engine.lifecycleState == .running {
                let readings = MultichannelMeterChannels.protectionReadings(from: taken, lanes: engine.outputProtectionLanes.map(\.index))
                protectionDB = readings.values.map { max($0.hardLimitGainReductionDB, $0.userGainReductionDB ?? 0) }.max() ?? 0
            } else {
                protectionDB = 0
            }
            try? await Task.sleep(nanoseconds: 125_000_000)
        }
    }
}
