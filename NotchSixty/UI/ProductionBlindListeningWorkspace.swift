import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// "Two audio files" mode (E12 S28): a voluntary listening test of two recordings, for example the same passage
/// recorded at the seat through another product and through Notch Sixty. It never touches the live output graph. A and B
/// are known; which one is X is hidden until the trials are in.
struct ProductionBlindListeningWorkspace: View {
    var engine: AudioIOEngine
    /// E12 S27: with `e12.blind-listening` on the page can also test what the app does (needs the profiles).
    var profiles: ProductProfileController?
    @State private var liveMode = true
    @ObservedObject private var request = BlindListeningRequest.shared
    @ObservedObject private var history = BlindTestHistoryStore.shared
    @State private var importingA = false
    @State private var importingB = false
    @State private var fileA: URL?
    @State private var fileB: URL?
    @State private var nameA = ""
    @State private var nameB = ""
    @State private var metricsA: BlindABXFileMetrics?
    @State private var metricsB: BlindABXFileMetrics?
    @State private var numberOfTrials = 16
    @State private var session: BlindABXSession?
    @State private var filePlayer: BlindFilePlayer?
    @State private var errorMessage: String?
    @State private var exportDocument: BlindTestExportFile?
    @State private var exporting = false
    @State private var finishedRecord: BlindTestRecord?
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var preflightReasons: [String] {
        guard let a = metricsA, let b = metricsB else {
            return ["Choose two recordings first (uncompressed WAV or AIFF, stereo)."]
        }
        return BlindABXPreflight.reasons(a: a, b: b)
    }

    private var canStart: Bool {
        session == nil && preflightReasons.isEmpty && engine.lifecycleState == .idle
    }

    private var match: BlindFileLoudnessMatch? {
        guard let a = metricsA, let b = metricsB, preflightReasons.isEmpty else { return nil }
        return BlindFileLoudnessMatch.make(a: a, b: b)
    }

    private var liveAvailable: Bool { profiles != nil && FeatureFlags().isEnabled(.blindListening) }

    var body: some View {
        if let profiles, liveAvailable {
            ProductionPageContainer {
                VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                    Picker("Compare", selection: $liveMode) {
                        Text("What Notch Sixty does").tag(true)
                        Text("Two audio files").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    if liveMode { ProductionBlindLiveView(profiles: profiles, history: history) } else { fileBody }
                    BlindHistoryView(history: history)
                }
            }
            .onChange(of: request.pending) { _, pending in if pending { liveMode = true } }
        } else {
            ProductionPageContainer { fileBody }
        }
    }

    private var fileBody: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xl.pt) {
            header
            sources
            sessionCard
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(StatusLevel.attention.color)
                    .font(DesignType.caption.font)
                    .textSelection(.enabled)
            }
        }
        .onReceive(tick) { _ in filePlayer?.tick() }
        .fileImporter(
            isPresented: $importingA, allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            importSource(result, sideB: false)
        }
        .fileImporter(
            isPresented: $importingB, allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            importSource(result, sideB: true)
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "notch-sixty-blind-test"
        ) { _ in }
        .onDisappear {
            filePlayer?.stop()
            filePlayer = nil
            clearTempFiles()
            fileA = nil
            fileB = nil
            metricsA = nil
            metricsB = nil
            session = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text(
                "Compare two recordings of the same passage, for example one made at your listening seat through another product and one through Notch Sixty. You know which is A and which is B; which one is X stays hidden until all trials are done. This is a listening exercise, not a room measurement."
            )
            .foregroundStyle(.secondary)
            Label(
                "Stop Notch Sixty playback first. The files play on the output device you selected, not through the live processing. Start with your hardware volume low and use the level slider below.",
                systemImage: "headphones"
            )
            .font(DesignType.caption.font)
            .foregroundStyle(StatusLevel.attention.color)
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            Text("1. Choose two recordings").font(DesignType.sectionTitle.font)
            Text(
                "Use the same passage in both. The page matches the loudness itself (the louder one is turned down) and cuts both to the shorter length, so you do not need to prepare them. Recordings made at different places or times can still differ in ways the page cannot remove."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { chooseButtons }
                VStack(alignment: .leading) { chooseButtons }
            }
            if let a = metricsA, let b = metricsB {
                Text(
                    String(
                        format: "A: %.0f Hz · %.2f dBFS RMS    B: %.0f Hz · %.2f dBFS RMS",
                        a.sampleRate, a.rmsDBFS, b.sampleRate, b.rmsDBFS
                    )
                )
                .font(DesignType.caption.font.monospacedDigit())
            }
            if let match {
                Label(match.summary, systemImage: "slider.horizontal.3").font(DesignType.caption.font)
            }
            ForEach(preflightReasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.shield")
                    .font(DesignType.caption.font)
                    .foregroundStyle(StatusLevel.attention.color)
            }
        }
        .padding(DesignSpacing.xl.pt)
        .background(.regularMaterial, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    @ViewBuilder private var chooseButtons: some View {
        Button("Choose file A…") { importingA = true }.disabled(session != nil)
        Text(fileA == nil ? "No A chosen" : "A: \(nameA)").font(DesignType.caption.font).foregroundStyle(.secondary)
        Button("Choose file B…") { importingB = true }.disabled(session != nil)
        Text(fileB == nil ? "No B chosen" : "B: \(nameB)").font(DesignType.caption.font).foregroundStyle(.secondary)
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            Text("2. Run the test").font(DesignType.sectionTitle.font)
            ViewThatFits(in: .horizontal) {
                HStack { startControls }
                VStack(alignment: .leading) { startControls }
            }
            if engine.lifecycleState != .idle {
                Text("Stop playback before using the two-file test.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(StatusLevel.attention.color)
            }
            if let session, let player = filePlayer {
                Divider()
                Text("Trial \(session.currentTrialNumber) of \(session.totalTrials)")
                    .font(DesignType.label.font.bold().monospacedDigit())
                BlindFileListenControls(player: player)
                ViewThatFits(in: .horizontal) {
                    HStack { listenButtons(session) }
                    VStack(alignment: .leading) { listenButtons(session) }
                }
                .buttonStyle(.glass)
                .disabled(session.isComplete || engine.lifecycleState != .idle)
                if !session.isComplete {
                    Text("Which recording is X? Play X at least once before you answer.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("X is A") { choose(whichB: false) }
                        Button("X is B") { choose(whichB: true) }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!session.maySubmitChoice || engine.lifecycleState != .idle)
                } else if let record = finishedRecord {
                    Divider()
                    Text("\(record.correctCount ?? 0) of \(record.trialCount) correct (p = \(record.pValue, specifier: "%.4f"))")
                        .font(DesignType.sectionTitle.font.monospacedDigit())
                    Text(record.outcome).font(DesignType.caption.font).foregroundStyle(.secondary)
                    HStack {
                        Button("Save a copy of the result…") { exportRecord(record) }
                            .buttonStyle(.glass)
                        Button("New test") {
                            filePlayer?.stop()
                            filePlayer = nil
                            self.session = nil
                            finishedRecord = nil
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            Text(
                "Each trial picks X at random, so there is no pattern to work out. The result is kept in the list below on this Mac; saving a copy is optional."
            )
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.xl.pt)
        .background(.regularMaterial, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    @ViewBuilder private var startControls: some View {
        Picker("Trials", selection: $numberOfTrials) {
            Text("12 trials").tag(12)
            Text("16 trials").tag(16)
            Text("24 trials").tag(24)
        }
        .frame(maxWidth: 230)
        .disabled(session != nil)
        Button("Start blind test") { startSession() }
            .buttonStyle(.glassProminent)
            .disabled(!canStart)
    }

    @ViewBuilder private func listenButtons(_ session: BlindABXSession) -> some View {
        Button("Listen A") { play(.a) }
        Button("Listen B") { play(.b) }
        Button("Listen X") { play(session.currentHiddenXWasB ? .b : .a, isX: true) }
        Button("Stop") { filePlayer?.stop() }
    }

    private func startSession() {
        errorMessage = nil
        guard canStart, let match, let fileA, let fileB else { return }
        guard let uid = engine.selectedOutputDevice?.uid else {
            errorMessage = "Choose an output device first. The files play on the device you selected."
            return
        }
        do {
            filePlayer = try BlindFilePlayer.make(urlA: fileA, urlB: fileB, deviceUID: uid, match: match)
            session = try BlindABXSession(trialCount: numberOfTrials)
            finishedRecord = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func choose(whichB: Bool) {
        guard var current = session else { return }
        filePlayer?.stop()
        do {
            try current.submit(whichB)
            session = current
            if let record = BlindTestRecords.abx(sideA: nameA, sideB: nameB, session: current, kind: .twoFiles) {
                finishedRecord = record
                history.append(record)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func play(_ side: BlindFilePlayer.Side, isX: Bool = false) {
        guard engine.lifecycleState == .idle, let filePlayer, session?.isComplete == false else { return }
        guard filePlayer.play(side) else {
            errorMessage = "Playback could not start on the selected output."
            return
        }
        do {
            if isX, var current = session {
                try current.recordXPlayback()
                session = current
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importSource(_ result: Result<[URL], Error>, sideB: Bool) {
        guard session == nil else { return }
        errorMessage = nil
        do {
            guard let original = try result.get().first else { return }
            guard ["wav", "wave", "aif", "aiff"].contains(
                original.pathExtension.lowercased()
            ) else {
                throw NSError(domain: "BlindABX", code: 8,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Choose uncompressed WAV or AIFF recordings, not compressed files."])
            }
            let scope = original.startAccessingSecurityScopedResource()
            defer { if scope { original.stopAccessingSecurityScopedResource() } }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: original.path
            )
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0, bytes <= 128 * 1024 * 1024 else {
                throw NSError(domain: "BlindABX", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Choose a local audio excerpt smaller than 128 MB."])
            }
            let metrics = try Self.readMetrics(original)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "notch-sixty-abx-" + UUID().uuidString
                )
                .appendingPathExtension(original.pathExtension)
            try FileManager.default.copyItem(at: original, to: destination)
            filePlayer?.stop()
            let name = original.deletingPathExtension().lastPathComponent
            if sideB {
                if let fileB { try? FileManager.default.removeItem(at: fileB) }
                fileB = destination
                metricsB = metrics
                nameB = name
            } else {
                if let fileA { try? FileManager.default.removeItem(at: fileA) }
                fileA = destination
                metricsA = metrics
                nameA = name
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// This is bounded offline PCM analysis, not a Core Audio render callback
    /// or a loudness-normalization pass. It never modifies source samples.
    private static func readMetrics(_ url: URL) throws -> BlindABXFileMetrics {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32,
              format.channelCount == 2,
              (8_000...384_000).contains(format.sampleRate),
              file.length > 0,
              Double(file.length) <= format.sampleRate * 90 else {
            throw NSError(domain: "BlindABX", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "ABX input must decode to two-channel Float32 PCM, <=90 seconds, at 8–384 kHz."])
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 4096
        ) else {
            throw NSError(domain: "BlindABX", code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Unable to allocate bounded offline PCM buffer."])
        }
        var squares = 0.0
        var peak = 0.0
        var samples: Int64 = 0
        while true {
            try file.read(into: buffer, frameCount: 4096)
            if buffer.frameLength == 0 { break }
            guard let channels = buffer.floatChannelData else {
                throw NSError(domain: "BlindABX", code: 5,
                              userInfo: [NSLocalizedDescriptionKey:
                                "PCM channel data is unavailable."])
            }
            for ch in 0..<2 {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = Double(channels[ch][frame])
                    guard value.isFinite else {
                        throw NSError(domain: "BlindABX", code: 6,
                                      userInfo: [NSLocalizedDescriptionKey:
                                        "The source contains non-finite PCM."])
                    }
                    squares += value * value
                    peak = max(peak, abs(value))
                    samples += 1
                }
            }
        }
        guard samples == file.length * 2,
              squares > 0, peak > 0,
              squares.isFinite, peak.isFinite else {
            throw NSError(domain: "BlindABX", code: 7,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Missing or invalid PCM energy."])
        }
        return BlindABXFileMetrics(
            sampleRate: format.sampleRate,
            channels: 2, frameCount: file.length,
            rmsDBFS: 20 * log10(sqrt(squares / Double(samples))),
            samplePeakDBFS: 20 * log10(peak)
        )
    }

    private func exportRecord(_ record: BlindTestRecord) {
        guard let data = try? BlindTestRecords.exportData(record) else { return }
        exportDocument = BlindTestExportFile(data: data)
        exporting = true
    }

    private func clearTempFiles() {
        for file in [fileA, fileB].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Level, loop and position controls for the file player (E12 S28).
struct BlindFileListenControls: View {
    @ObservedObject var player: BlindFilePlayer

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            HStack {
                Text("Level").font(DesignType.caption.font)
                Slider(value: $player.level, in: 0...1).frame(maxWidth: 260)
                Text("\(Int((player.level * 100).rounded()))%").font(DesignType.caption.font.monospacedDigit())
            }
            Text("The slider starts low and is remembered. Raise it slowly.").font(DesignType.caption.font).foregroundStyle(.secondary)
            Toggle("Loop a passage", isOn: $player.loopEnabled).font(DesignType.caption.font)
            if player.loopEnabled {
                HStack {
                    Text("From").font(DesignType.caption.font)
                    Slider(value: Binding(get: { player.loopStart }, set: { player.setPassage(start: $0, end: player.loopEnd) }),
                           in: 0...max(0.5, player.match.durationSeconds)).frame(maxWidth: 220)
                    Text("to").font(DesignType.caption.font)
                    Slider(value: Binding(get: { player.loopEnd }, set: { player.setPassage(start: player.loopStart, end: $0) }),
                           in: 0...max(0.5, player.match.durationSeconds)).frame(maxWidth: 220)
                }
                Text(String(format: "%.1f s to %.1f s. Switching between A, B and X keeps the position.", player.loopStart, player.loopEnd))
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
            } else {
                Text("Switching between A, B and X keeps the position in the recording.").font(DesignType.caption.font).foregroundStyle(.secondary)
            }
        }
    }
}

/// The saved list of finished tests (E12 S28, decision 28).
struct BlindHistoryView: View {
    @ObservedObject var history: BlindTestHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            HStack {
                Text("Finished tests").font(DesignType.sectionTitle.font)
                Spacer()
                if !history.records.isEmpty {
                    Button("Clear list") { history.clear() }.buttonStyle(.borderless).font(DesignType.caption.font)
                }
            }
            if history.records.isEmpty {
                Text("Nothing yet. Each finished test is kept here, with the date, what was compared and the result.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            ForEach(history.records.prefix(20)) { record in
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("\(record.date.formatted(date: .abbreviated, time: .shortened)): \(record.title)").font(DesignType.label.font)
                    Text(record.outcome).font(DesignType.caption.font).foregroundStyle(.secondary)
                }
            }
        }
        .padding(DesignSpacing.xl.pt)
        .background(.regularMaterial, in: .rect(cornerRadius: DesignRadius.large.pt))
    }
}
