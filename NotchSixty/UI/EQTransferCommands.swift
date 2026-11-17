import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// E33 S2: the page's Import, Export, copy, paste and "Copy lane to..." commands (designs 4 and 5). The pure
/// edits are in `EQBandTransfer`; this file is the panels, alerts and pasteboard around them. Every change goes
/// through `apply` as one replacement of the whole configuration, so the page records one undo step.
@MainActor
struct EQTransferCommands {
    var current: () -> StereoEQConfiguration
    /// Publishes the new configuration and records one undo step ("Import EQ Filters" and so on).
    var apply: (StereoEQConfiguration) -> Void
    var selectedBandID: () -> UUID?
    var inputPreampDB: () -> Double
    /// E33 S3 (G3): sets an imported `Preamp:` line as the manual preamp term.
    var applyPreampDB: (Double) throws -> Void
    var reportError: (String) -> Void

    static let pasteboardType = NSPasteboard.PasteboardType(EQBandClipboard.privateTypeIdentifier)

    private var lane: EQLane { current().editLane }

    // MARK: Import and export

    func importFilterText() {
        let panel = NSOpenPanel()
        panel.title = "Import Equalizer APO Filters"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text, .data].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else { throw EQBandTransfer.TransferError.nothingToImport }
            importText(String(decoding: data, as: UTF8.self), source: url.lastPathComponent)
        } catch {
            reportError("Import failed: \(error.localizedDescription)")
        }
    }

    /// Parses `text`, asks replace or append when the lane already has bands, applies, reports what was skipped.
    func importText(_ text: String, source: String) {
        let parsed = EqualizerAPOCodec.parse(text)
        guard !parsed.bands.isEmpty else {
            reportError(parsed.issues.isEmpty
                ? "\(source) has no usable filters."
                : "\(source) has no usable filters.\n" + parsed.issues.prefix(8).joined(separator: "\n"))
            return
        }
        var mode = EQBandTransfer.ImportMode.replace
        let existing = current().editableBands.count
        if existing > 0 {
            let alert = NSAlert()
            alert.messageText = "Import \(parsed.bands.count) filters into \(lane.displayName)?"
            alert.informativeText = "The \(lane.displayName) lane has \(existing) bands. Replace them, or add the new filters after them."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: mode = .replace
            case .alertSecondButtonReturn: mode = .append
            default: return
            }
        }
        do {
            let outcome = try EQBandTransfer.importing(parsed, into: current(), mode: mode)
            apply(outcome.configuration)
            var notes = outcome.notes
            if let preamp = parsed.preampDB {
                do {
                    try applyPreampDB(preamp)
                    notes.append("Preamp \(String(format: "%+.1f", preamp)) dB in the file was set as the manual preamp.")
                } catch {
                    notes.append("Preamp \(String(format: "%+.1f", preamp)) dB in the file could not be applied: \(error.localizedDescription)")
                }
            }
            if !notes.isEmpty { showNotes(title: "Imported \(parsed.bands.count) filters", notes: notes) }
        } catch {
            reportError(error.localizedDescription)
        }
    }

    func exportFilterText() {
        let written = EqualizerAPOCodec.write(
            bands: current().editableBands, preampDB: inputPreampDB(),
            header: ["Notch Sixty Equalizer APO filter export", "Lane: \(lane.displayName)"])
        guard current().editableBands.contains(where: { EqualizerAPOCodec.canWrite($0.type) }) else {
            reportError("There are no bands that can be exported as filter text.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Equalizer APO Filters"
        panel.nameFieldStringValue = "Notch-Sixty-\(lane.displayName)-EQ.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try Data(written.text.utf8).write(to: url, options: .atomic)
            if !written.issues.isEmpty { showNotes(title: "Exported with notes", notes: written.issues) }
        } catch {
            reportError("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: Clipboard

    var canCopyBand: Bool { selectedBandID().flatMap { id in current().editableBands.first { $0.id == id } } != nil }

    func copyBand() {
        guard let id = selectedBandID(), let band = current().editableBands.first(where: { $0.id == id }) else { return }
        writeToPasteboard([band])
    }

    func copyAllBands() { writeToPasteboard(current().editableBands) }

    private func writeToPasteboard(_ bands: [EQBand]) {
        guard let encoded = EQBandClipboard.encode(bands) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(encoded.data, forType: Self.pasteboardType)
        pasteboard.setString(encoded.text, forType: .string)
    }

    var canPaste: Bool {
        let pasteboard = NSPasteboard.general
        return pasteboard.data(forType: Self.pasteboardType) != nil || pasteboard.string(forType: .string) != nil
    }

    func paste() {
        let pasteboard = NSPasteboard.general
        let bands = EQBandClipboard.decode(
            data: pasteboard.data(forType: Self.pasteboardType), text: pasteboard.string(forType: .string))
        do {
            let outcome = try EQBandTransfer.pasting(bands, into: current())
            apply(outcome.configuration)
        } catch {
            reportError(error.localizedDescription)
        }
    }

    // MARK: Copy lane

    var laneTargets: [EQLane] { EQBandTransfer.copyTargets(for: current()) }

    func copyLane(to target: EQLane) {
        let source = lane
        let replaced = current().bands(in: target).count
        if replaced > 0 {
            let alert = NSAlert()
            alert.messageText = "Replace the \(target.displayName) lane?"
            alert.informativeText = "The \(target.displayName) lane has \(replaced) bands. They are replaced by a copy of the \(source.displayName) lane. You can undo this."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        apply(EQBandTransfer.copyLane(source, to: target, in: current()))
    }

    private func showNotes(title: String, notes: [String]) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = notes.prefix(12).map { "• \($0)" }.joined(separator: "\n")
            + (notes.count > 12 ? "\n… and \(notes.count - 12) more." : "")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// The Import / Export menu in the Bands panel header.
struct EQTransferMenu: View {
    let commands: EQTransferCommands
    let canAddBands: Bool

    var body: some View {
        Menu {
            Button("Import Filter Text…") { commands.importFilterText() }
                .accessibilityIdentifier("eq.transfer.import")
            Button("Export Filter Text…") { commands.exportFilterText() }
                .accessibilityIdentifier("eq.transfer.export")
            Divider()
            Button("Copy Band") { commands.copyBand() }
                .disabled(!commands.canCopyBand)
            Button("Copy All Bands") { commands.copyAllBands() }
            Button("Paste Bands") { commands.paste() }
                .disabled(!commands.canPaste || !canAddBands)
            Divider()
            Menu("Copy Lane To") {
                ForEach(commands.laneTargets) { target in
                    Button(target.displayName) { commands.copyLane(to: target) }
                }
            }
        } label: {
            Label("Import and Export", systemImage: "square.and.arrow.down.on.square")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Import or export Equalizer APO filter text; copy and paste bands; copy a lane")
        .accessibilityIdentifier("eq.transfer.menu")
    }
}

/// Edit-menu Copy and Paste on the page: Copy puts the selected band on the pasteboard, Paste adds bands from it.
struct EQClipboardCommandsModifier: ViewModifier {
    let enabled: Bool
    let commands: EQTransferCommands

    func body(content: Content) -> some View {
        if enabled {
            content
                .onCopyCommand {
                    guard commands.canCopyBand, let band = commands.current().editableBands.first(where: { $0.id == commands.selectedBandID() }),
                          let encoded = EQBandClipboard.encode([band]) else { return [] }
                    let bandProvider = NSItemProvider()
                    let bandData = encoded.data
                    bandProvider.registerDataRepresentation(
                        forTypeIdentifier: EQBandClipboard.privateTypeIdentifier, visibility: .all
                    ) { completion in
                        completion(bandData, nil)
                        return nil
                    }
                    return [
                        bandProvider,
                        NSItemProvider(object: encoded.text as NSString),
                    ]
                }
                .onPasteCommand(of: [.plainText]) { _ in commands.paste() }
        } else {
            content
        }
    }
}
