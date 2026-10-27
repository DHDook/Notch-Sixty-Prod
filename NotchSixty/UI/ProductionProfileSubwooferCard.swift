import SwiftUI

// E8 A5: the small Output Device Profile subwoofer card on the Speakers tab. Sub 1 to Sub 8 with an output picker, add
// and remove, through the selected Playback System's profile. Pure edits live in
// `OutputDeviceProfileSubwooferEditing.swift`; a change that invalidates stored alignment or calibration records asks
// first and then clears them.

struct ProductionProfileSubwooferCard: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var profiles: ProductProfileController
    @State private var pending: OutputDeviceProfileSubwooferEdit?
    @State private var errorText: String?

    var body: some View {
        if let profile = engine.outputDeviceProfileConfiguration, profile.enabled {
            VStack(alignment: .leading, spacing: 10) {
                Text("Profile subwoofers").font(.headline)
                if engine.speakerRoutingConfiguration?.enabled == true {
                    Label("The routing matrix owns the outputs while it is on; these assignments apply when it is off.",
                          systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if profile.subwooferAssignments.count > SubwooferLimit.legacyKernel, !engine.unifiedGraphEnabled {
                    Label("More than \(SubwooferLimit.legacyKernel) subwoofers need the unified graph; the legacy kernel drives at most \(SubwooferLimit.legacyKernel).",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if profile.subwooferAssignments.isEmpty {
                    Text("No subwoofers assigned.").foregroundStyle(.secondary)
                }
                ForEach(profile.subwooferAssignments.sorted { $0.index < $1.index }, id: \.index) { sub in
                    HStack {
                        Text("Sub \(sub.index + 1)").frame(width: 60, alignment: .leading)
                        Picker("Output", selection: Binding(
                            get: { sub.destination },
                            set: { endpoint in attempt { try profile.movingSubwoofer(index: sub.index, to: endpoint) } })) {
                            ForEach(choices(profile: profile, current: sub.destination)) { Text($0.title).tag($0.endpoint) }
                        }
                        .labelsHidden().frame(width: 280)
                        Spacer()
                        Button("Remove", role: .destructive) { attempt { try profile.removingSubwoofer(index: sub.index) } }
                    }
                }
                HStack {
                    Button("Add subwoofer") { addSubwoofer(profile) }
                        .disabled(profile.subwooferAssignments.count >= SubwooferLimit.graph)
                    Text("Changing outputs or subwoofers restarts the output with a short fade.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 22))
            .confirmationDialog(
                "Clear stored records?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                presenting: pending
            ) { edit in
                Button("Clear and apply", role: .destructive) { apply(edit) }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { edit in
                Text("This change makes these records invalid, so they will be cleared: \(edit.clearedRecords.joined(separator: ", ")).")
            }
        }
    }

    /// Every connected channel not used by another assignment, plus the current endpoint.
    private func choices(profile: OutputDeviceProfileConfiguration, current: PhysicalOutputEndpoint) -> [RoutingOutputChoice] {
        let used = Set(profile.allDestinations).subtracting([current])
        return RoutingOutputChoice.choices(devices: engine.outputDevices, current: current)
            .filter { !used.contains($0.endpoint) }
    }

    private func addSubwoofer(_ profile: OutputDeviceProfileConfiguration) {
        guard let device = engine.selectedOutputDevice else { errorText = "Select an output device first."; return }
        guard let endpoint = profile.nextFreeDestination(deviceUID: device.uid, channelCount: device.outputChannelCount) else {
            errorText = "All \(device.outputChannelCount) outputs of \(device.name) are in use."
            return
        }
        attempt { try profile.addingSubwoofer(destination: endpoint) }
    }

    private func attempt(_ edit: () throws -> OutputDeviceProfileSubwooferEdit) {
        do {
            let result = try edit()
            let bassManaged = engine.bassManagementConfiguration.enabled
            try result.profile.validateStructure(bassManagementEnabled: bassManaged)
            if result.clearedRecords.isEmpty { apply(result) } else { pending = result }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func apply(_ edit: OutputDeviceProfileSubwooferEdit) {
        pending = nil
        do {
            try profiles.replaceSelectedSystemOutputDeviceProfile(edit.profile)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
