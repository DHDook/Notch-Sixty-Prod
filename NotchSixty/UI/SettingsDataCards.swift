import AppKit
import SwiftUI

/// E12 S25: the two Data cards added to Backup & Restore: automatic backups, and reset and erase.
/// Control rows sit in `ViewThatFits` so they reflow instead of widening the window (AGENTS.md section 13).
struct SettingsAutomaticBackupCard: View {
    @ObservedObject var manager: SettingsDataManager
    @ObservedObject var preferences: ApplicationPreferences
    @State private var message: String?

    var body: some View {
        SettingsDataCardFrame(title: "Automatic Backups", systemImage: "clock.arrow.circlepath") {
            LabeledContent("Last backup") {
                Text(manager.lastBackupDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "None yet")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
            Text("Notch Sixty keeps a backup of your presets, systems and settings in its own folder: at most one a day, on days when something changed, and the last five. Use Save Backup to keep one somewhere else.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            do {
                try manager.backUpNow(preferences: preferences)
                message = "Backup saved."
            } catch {
                message = "Backup failed: \(error.localizedDescription)"
            }
        } label: {
            Label("Back Up Now", systemImage: "arrow.clockwise.circle")
        }
        .buttonStyle(.glass)
        Button {
            try? FileManager.default.createDirectory(at: manager.store.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([manager.store.directory])
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .buttonStyle(.glass)
    }
}

struct SettingsResetEraseCard: View {
    @ObservedObject var manager: SettingsDataManager
    @ObservedObject var preferences: ApplicationPreferences
    let isIdle: Bool
    @State private var message: String?
    @State private var showsEraseSheet = false
    @State private var typed = ""

    var body: some View {
        SettingsDataCardFrame(title: "Reset & Erase", systemImage: "arrow.counterclockwise.circle") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
            Text("Restore Default Settings puts the app settings back to how they first looked. Your presets, systems and measurements are not changed. Erase All Data removes all of those too, after a backup is made first; stop processing before you erase.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .sheet(isPresented: $showsEraseSheet) { eraseSheet }
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            guard DesignDialogs.confirm(
                title: "Restore default settings?",
                message: "Your presets, systems and measurements are not changed.",
                buttons: ["Restore", "Cancel"], warning: false) != nil else { return }
            manager.restoreDefaultSettings(preferences: preferences)
            message = "Settings were put back to their defaults."
        } label: {
            Label("Restore Default Settings", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.glass)
        Button(role: .destructive) {
            typed = ""
            showsEraseSheet = true
        } label: {
            Label("Erase All Data…", systemImage: "trash")
        }
        .buttonStyle(.glass)
        .disabled(!isIdle)
    }

    private var eraseSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Erase all data?").font(.headline)
            Text("This removes your presets, speaker systems, room correction projects, measurement sessions, headphone profiles, listening history and settings. A backup is saved first in the Notch Sixty backup folder, and erasing never deletes it. Type \(SettingsDataManager.eraseConfirmationWord) to continue.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type \(SettingsDataManager.eraseConfirmationWord)", text: $typed)
                .textFieldStyle(.roundedBorder)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { sheetButtons }
                VStack(alignment: .leading, spacing: 10) { sheetButtons }
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 420)
    }

    @ViewBuilder
    private var sheetButtons: some View {
        Button("Cancel", role: .cancel) { showsEraseSheet = false }
        Button("Erase All Data", role: .destructive) {
            do {
                try manager.eraseAllData(typed: typed, preferences: preferences)
                message = "All saved data was erased. The backup made first is in the backup folder."
            } catch {
                message = error.localizedDescription
            }
            showsEraseSheet = false
        }
        .disabled(typed.trimmingCharacters(in: .whitespaces).uppercased() != SettingsDataManager.eraseConfirmationWord)
    }
}

private struct SettingsDataCardFrame<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}
