import SwiftUI

/// E4 S27: choose the quiet zone: one seat, one zone that follows your head, or two zones (both sides of a bed).
/// Shown when flag `e4.zones` is on, under the ear survey. Changing the zone while Quiet Zone is on turns it off, and
/// the next Turn On starts at the starting level again. It never arms anything.
struct ProductionZoneChooserCard: View {
    @ObservedObject var zones: QuietZoneZoneController
    @ObservedObject var first: QuietZoneVirtualMicSurveyController
    @ObservedObject var second: QuietZoneVirtualMicSurveyController
    var quietZoneRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quiet Zone Area")
                .font(.headline)
            Text("Choose what Quiet Zone quiets. Two zones quiets both sides of a bed at once; the speakers have just enough freedom for two spots, so each tone is solved for both together and the microphone at the monitor position must not get louder.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Zone", selection: Binding(
                get: { zones.mode },
                set: { zones.setMode($0) }
            )) {
                Text("One seat").tag(QuietZoneZoneMode.fixedSeat)
                Text("Follow my head").tag(QuietZoneZoneMode.follow)
                Text("Two zones").tag(QuietZoneZoneMode.twoZones)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            Text(zones.message)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let plan = zones.plan {
                Text("\(plan.zonePointIDs.count) zone\(plan.zonePointIDs.count == 1 ? "" : "s"), \(plan.otherSeatPointIDs.count) other surveyed position\(plan.otherSeatPointIDs.count == 1 ? "" : "s") kept from getting louder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if zones.mode == .twoZones || zones.unavailableReason(.twoZones) != nil {
                Divider()
                Text("Second zone")
                    .font(.subheadline.bold())
                HStack(spacing: 12) {
                    Text("Position")
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                    Picker("Second zone position", selection: Binding(
                        get: { second.ear?.id },
                        set: { second.selectEar($0) }
                    )) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(second.earPositionCandidates, id: \.id) { entry in
                            Text(entry.name).tag(UUID?.some(entry.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .disabled(second.isCapturing)
                }
                HStack(spacing: 12) {
                    Button("Capture at monitor") { second.beginVisit(.monitor) }
                        .disabled(second.ear == nil || second.isCapturing || !quietZoneRunning)
                    Button("Capture at second zone") { second.beginVisit(.ear) }
                        .disabled(!second.monitorCaptured || second.isCapturing || !quietZoneRunning)
                    if second.isCapturing {
                        ProgressView(value: Double(second.progress), total: Double(QuietZoneVirtualMicSurveyController.windowsPerVisit))
                            .frame(width: 120)
                        Button("Cancel") { second.cancelVisit() }
                    }
                    Spacer()
                    if !second.tones.isEmpty {
                        Button("Discard survey") { second.discardSurvey() }
                    }
                }
                Text(second.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !second.tones.isEmpty {
                    Toggle("Quiet the second zone", isOn: $second.useAtEar)
                        .disabled(second.isCapturing)
                }
                Text("Tones not surveyed at both zones keep the one-zone design. Two zones need the speakers' bass path to be free (no sub-aware conditioning).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onChange(of: first.useAtEar) { _, _ in zones.revalidate() }
        .onChange(of: first.tones.count) { _, _ in zones.revalidate() }
        .onChange(of: second.useAtEar) { _, _ in zones.revalidate() }
        .onChange(of: second.tones.count) { _, _ in zones.revalidate() }
    }
}
