import SwiftUI

/// E15 S6: the one-line notes under the output picker for a wireless output (design note 15): the Bluetooth headset-mode
/// rate note and the "adds N ms on top of the <Bluetooth/AirPlay> delay" note. Nothing shows for a wired output or with
/// `e15.follow-output` off. Wraps text instead of widening the row (`AGENTS.md` section 13).
struct WirelessOutputNotes: View {
    var engine: AudioIOEngine

    var body: some View {
        let flagOn = FeatureFlags().isEnabled(.followOutput)
        let device = engine.selectedOutputDevice
        let notes = Self.notes(
            transport: device?.transport, nominalRateHz: device?.nominalSampleRate,
            latencyFrames: flagOn && device?.transport.isWireless == true
                ? engine.diagnosticsSnapshot().renderKernelDiagnostics?.latencyFrames : nil,
            flagOn: flagOn)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "wave.3.right")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The notes to show, in order. Pure, so the layout test and the unit tests share it.
    static func notes(
        transport: OutputTransportKind?, nominalRateHz: Double?, latencyFrames: UInt32?, flagOn: Bool
    ) -> [String] {
        [WirelessOutputPolicy.rateNote(transport: transport, nominalRateHz: nominalRateHz, flagOn: flagOn),
         WirelessOutputPolicy.overBudgetNote(
            latencyFrames: latencyFrames, sampleRate: nominalRateHz, transport: transport, flagOn: flagOn)]
            .compactMap { $0 }
    }
}
