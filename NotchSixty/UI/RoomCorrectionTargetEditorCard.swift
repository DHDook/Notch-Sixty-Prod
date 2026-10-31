import SwiftUI
import UniformTypeIdentifiers

/// E10 S5: target editor card (design note 8).
/// Curtains, the limited-range preset, per-channel level and tilt, and the saved target library.
struct RoomCorrectionTargetEditorCard: View {
    let channelNames: [String]
    @Binding var shaping: ChannelTargetShaping
    @Binding var target: RoomCorrectionTargetCurve?

    @State private var report = TargetLibraryLoadReport(records: TargetLibrary.builtIns, skipped: [])
    @State private var message: String?
    @State private var importing = false
    @State private var importCategory: TargetCategory = .room
    @State private var showAll = false
    @EnvironmentObject private var featureFlags: FeatureFlags
    private let library = TargetLibrary()

    var body: some View {
        GroupBox("Target editor") {
            VStack(alignment: .leading, spacing: 12) {
                libraryRow
                ForEach(Array(channelNames.enumerated()), id: \.offset) { index, name in
                    channelRow(index, name)
                }
                if !report.skipped.isEmpty {
                    ForEach(report.skipped.indices, id: \.self) { i in
                        Text("Skipped \(report.skipped[i].file): \(report.skipped[i].reason)")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onAppear { report = library.loadAll() }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let name = url.deletingPathExtension().lastPathComponent
                let record: TargetRecord
                if featureFlags.isEnabled(.byoImport) {
                    let curve = try FrequencyResponseImporter.parse(Data(contentsOf: url), sourceName: name)
                    record = try FrequencyResponseImporter.targetRecord(
                        from: curve, useOfferedTarget: curve.offeredTarget != nil, category: importCategory)
                    message = curve.issues.isEmpty ? nil : "\(curve.issues.count) lines skipped; first: \(curve.issues[0])"
                } else {
                    record = try TargetLibrary.importREW(Data(contentsOf: url), name: name)
                }
                try library.save(record)
                report = library.loadAll()
                target = record.curve
            } catch { message = error.localizedDescription }
        }
    }

    private static let importTypes: [UTType] =
        [.plainText, .text, .commaSeparatedText] + (UTType(filenameExtension: "frd").map { [$0] } ?? [])

    private var libraryRow: some View {
        HStack {
            Picker("Target", selection: Binding(
                get: { target?.id }, set: { id in
                    if let record = report.records.first(where: { $0.id == id }) {
                        target = record.curve; shaping = record.shaping
                        if featureFlags.isEnabled(.byoImport) {
                            message = TargetLibrary.crossCategoryCaution(record, picker: .room)
                        }
                    }
                })) {
                ForEach(featureFlags.isEnabled(.byoImport)
                    ? pickerRecords : report.records) { Text($0.name).tag(Optional($0.id)) }
            }
            if featureFlags.isEnabled(.byoImport) { Toggle("Show all", isOn: $showAll).toggleStyle(.checkbox) }
            Button("Duplicate") { act { if let t = target { _ = try library.duplicate(TargetRecord(curve: t, shaping: shaping)) } } }
                .disabled(target == nil)
            Button("Save") {
                act { if let t = target, !TargetLibrary.isBuiltIn(t.id) { try library.save(TargetRecord(curve: t, shaping: shaping)) } }
            }.disabled(target == nil || target.map { TargetLibrary.isBuiltIn($0.id) } ?? true)
            if featureFlags.isEnabled(.byoImport) {
                Menu("Import target...") {
                    ForEach(TargetCategory.allCases, id: \.self) { category in
                        Button("As \(category.rawValue) target") { importCategory = category; importing = true }
                    }
                }
            } else {
                Button("Import REW...") { importing = true }
            }
            Button("Copy REW text") {
                if let t = target {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        String(decoding: TargetLibrary.exportREW(TargetRecord(curve: t)), as: UTF8.self), forType: .string)
                    message = "Copied \(t.name) as REW text."
                }
            }.disabled(target == nil)
        }
    }

    /// The current target stays listed even when its category is filtered out.
    private var pickerRecords: [TargetRecord] {
        let shown = TargetLibrary.visible(report.records, for: .room, showAll: showAll)
        guard let id = target?.id, !shown.contains(where: { $0.id == id }),
              let current = report.records.first(where: { $0.id == id }) else { return shown }
        return shown + [current]
    }

    private func channelRow(_ index: Int, _ name: String) -> some View {
        let binding = Binding(get: { shaping[index] }, set: { shaping[index] = $0 })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).bold()
                Spacer()
                Toggle("Limited range", isOn: Binding(
                    get: { binding.wrappedValue.highCurtainHz != nil },
                    set: { binding.wrappedValue.highCurtainHz = $0 ? TargetShaping.limitedRangeHighCurtainHz : nil }))
            }
            HStack {
                curtainField("Low curtain (Hz)", binding.lowCurtainHz)
                curtainField("High curtain (Hz)", binding.highCurtainHz)
                Stepper("Level \(binding.wrappedValue.levelOffsetDB, specifier: "%+.1f") dB",
                        value: binding.levelOffsetDB, in: -12 ... 12, step: 0.5)
                Stepper("Tilt \(binding.wrappedValue.tiltDBPerOctave, specifier: "%+.1f") dB/oct",
                        value: binding.tiltDBPerOctave, in: -3 ... 3, step: 0.1)
            }
            if !binding.wrappedValue.isValid {
                Text("The low curtain must be below the high curtain.").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func curtainField(_ title: String, _ value: Binding<Double?>) -> some View {
        TextField(title, value: value, format: .number).frame(width: 130)
    }

    private func act(_ body: () throws -> Void) {
        do { try body(); report = library.loadAll(); message = nil } catch { message = error.localizedDescription }
    }
}
