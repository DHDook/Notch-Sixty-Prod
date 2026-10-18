import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Independent, voluntary OFFLINE comparative listening experiment. It never
/// intercepts Notch Sixty output, applies DSP presets or grants hardware
/// acceptance. File A/B identities are known; randomized X identity is hidden.
private struct BlindABXExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ProductionBlindListeningWorkspace: View {
    @ObservedObject var engine: AudioIOEngine
    @State private var importingA = false
    @State private var importingB = false
    @State private var fileA: URL?
    @State private var fileB: URL?
    @State private var metricsA: BlindABXFileMetrics?
    @State private var metricsB: BlindABXFileMetrics?
    @State private var numberOfTrials = 16
    @State private var session: BlindABXSession?
    @State private var playing: AVAudioPlayer?
    @State private var errorMessage: String?
    @State private var exportDocument: BlindABXExportFile?
    @State private var exporting = false

    private var preflightReasons: [String] {
        guard let a = metricsA, let b = metricsB else {
            return ["Import two local stereo PCM WAV/AIFF excerpts first."]
        }
        return BlindABXPreflight.reasons(a: a, b: b)
    }

    private var canStart: Bool {
        session == nil && preflightReasons.isEmpty
            && engine.lifecycleState == .idle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                sources
                sessionCard
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .topLeading)
        }
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
            defaultFilename: "notch-sixty-blind-abx"
        ) { _ in }
        .onDisappear {
            playing?.stop()
            clearTempFiles()
            fileA = nil
            fileB = nil
            metricsA = nil
            metricsB = nil
            session = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(
                "Compare two user-supplied audio excerpts with a randomly assigned, undisclosed X source. A and B are known; X is revealed only after all trials. This is an optional listening exercise, not a room measurement or physical hardware approval."
            )
            .foregroundStyle(.secondary)
            Label(
                "For safe listening, stop Notch Sixty processing, start with your system volume low, and use the same output setup throughout. The separate file player uses macOS default audio routing—not the live DSP graph.",
                systemImage: "headphones"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. Prepare matched reference excerpts").font(.headline)
            Text(
                "Use the same music passage with identical mastering, channel order, and duration. Match loudness independently before import. File RMS agreement within 0.10 dB is necessary but not perceptual LUFS verification; sample alignment and listener bias can still invalidate the result."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Choose file A…") { importingA = true }
                    .disabled(session != nil)
                Text(fileA == nil ? "No A imported" : "A ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose file B…") { importingB = true }
                    .disabled(session != nil)
                Text(fileB == nil ? "No B imported" : "B ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let a = metricsA, let b = metricsB {
                Text(
                    String(
                        format: "A: %.0f Hz · %.2f dBFS RMS · %.2f dBFS peak    B: %.0f Hz · %.2f dBFS RMS · %.2f dBFS peak",
                        a.sampleRate, a.rmsDBFS, a.samplePeakDBFS,
                        b.sampleRate, b.rmsDBFS, b.samplePeakDBFS
                    )
                )
                .font(.caption.monospacedDigit())
            }
            ForEach(preflightReasons, id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("2. Run randomized X trials").font(.headline)
            HStack {
                Picker("Trials", selection: $numberOfTrials) {
                    Text("12 trials").tag(12)
                    Text("16 trials").tag(16)
                    Text("24 trials").tag(24)
                }
                .frame(maxWidth: 230)
                .disabled(session != nil)
                Spacer()
                Button("Start blind session") { startSession() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
            }
            if engine.lifecycleState != .idle {
                Text("Stop live processing before this offline ABX exercise.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let session {
                Divider()
                Text(
                    "Trial \(session.currentTrialNumber) / \(session.totalTrials)"
                )
                .font(.subheadline.bold().monospacedDigit())

                HStack {
                    Button("Listen A") { play(whichB: false) }
                    Button("Listen B") { play(whichB: true) }
                    Button("Listen X") {
                        play(whichB: session.currentHiddenXWasB, isX: true)
                    }
                    Button("Stop") { playing?.stop() }
                }
                .buttonStyle(.bordered)
                .disabled(session.isComplete || engine.lifecycleState != .idle)
                if !session.isComplete {
                    Text("Which known reference is X? You must play X before choosing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("X is A") { choose(whichB: false) }
                        Button("X is B") { choose(whichB: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.maySubmitChoice || engine.lifecycleState != .idle)
                } else if let evidence = try? session.exportEvidence() {
                    Divider()
                    Text(
                        "\(evidence.correctCount)/\(evidence.trialCount) correct · exact one-sided p = \(evidence.oneSidedExactPValue, specifier: "%.5f")"
                    )
                    .font(.headline.monospacedDigit())
                    Text(
                        evidence.oneSidedExactPValue < 0.05
                            ? "The observed success rate exceeds fair guessing at this exploratory threshold. It does not establish universal audibility, actual DSP quality, or device safety."
                            : "This trial did not reject the fair-guess hypothesis at p < 0.05. It does not prove A and B sound identical."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Export completed trial evidence") {
                            exportCompletedSession()
                        }
                        .buttonStyle(.bordered)
                        Button("New session") {
                            playing?.stop()
                            self.session = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Text(
                "Each trial uses an independent unpredictable 50/50 X assignment; there is no balanced-without-replacement sequence to deduce. Results stay local until you explicitly export them. Playback is capped to 20% software volume; start hardware volume low."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }

    private func startSession() {
        errorMessage = nil
        guard canStart else { return }
        do {
            session = try BlindABXSession(trialCount: numberOfTrials)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func choose(whichB: Bool) {
        guard var current = session else { return }
        playing?.stop()
        do {
            try current.submit(whichB)
            session = current
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func play(whichB: Bool, isX: Bool = false) {
        guard engine.lifecycleState == .idle,
              let file = whichB ? fileB : fileA,
              session?.isComplete == false else { return }
        do {
            playing?.stop()
            let player = try AVAudioPlayer(contentsOf: file)
            player.volume = 0.2
            player.prepareToPlay()
            guard player.play() else {
                throw NSError(domain: "BlindABX", code: 3,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Audio playback could not start."])
            }
            playing = player
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
                                "Import uncompressed WAV/AIFF PCM excerpts, not lossy/encoded files."])
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
            playing?.stop()
            if sideB {
                if let fileB { try? FileManager.default.removeItem(at: fileB) }
                fileB = destination
                metricsB = metrics
            } else {
                if let fileA { try? FileManager.default.removeItem(at: fileA) }
                fileA = destination
                metricsA = metrics
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

    private func exportCompletedSession() {
        guard let session, let evidence = try? session.exportEvidence(),
              let data = try? JSONEncoder().encode(evidence) else { return }
        exportDocument = BlindABXExportFile(data: data)
        exporting = true
    }

    private func clearTempFiles() {
        for file in [fileA, fileB].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
