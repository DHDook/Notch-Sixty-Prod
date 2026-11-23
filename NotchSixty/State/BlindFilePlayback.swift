import AVFoundation
import Foundation

// E12 S28 (behind `e12.blind-listening`): "Two audio files" mode. Control plane, main actor. The files play through
// AVAudioPlayer on the selected output device (not the macOS default), never through the live graph, so the page asks
// for processing to be stopped first. Allocation: allocates (offline). Synchronisation: none. Sample rate: each file
// plays at its own rate (any rate to 384 kHz). Reset: `stop()` stops both voices; closing the page stops playback.

/// Loudness match of two files (decision 29 family, G49): the louder file is turned down, the quieter is never raised,
/// and both are cut to the shorter length. The level is each file's RMS, the same measure the page reports.
struct BlindFileLoudnessMatch: Equatable, Sendable {
    var gainA: Double
    var gainB: Double
    /// The common length in seconds (the shorter file).
    var durationSeconds: Double

    var gainADB: Double { 20 * log10(gainA) }
    var gainBDB: Double { 20 * log10(gainB) }

    static func make(a: BlindABXFileMetrics, b: BlindABXFileMetrics) -> BlindFileLoudnessMatch {
        let target = min(a.rmsDBFS, b.rmsDBFS)
        return BlindFileLoudnessMatch(
            gainA: pow(10, (target - a.rmsDBFS) / 20), gainB: pow(10, (target - b.rmsDBFS) / 20),
            durationSeconds: min(Double(a.frameCount) / a.sampleRate, Double(b.frameCount) / b.sampleRate))
    }

    /// "File B was turned down by 3.2 dB to match. Both files are cut to 12.0 seconds."
    var summary: String {
        let turned: String
        if gainA < 1 { turned = String(format: "File A is turned down by %.1f dB to match.", -gainADB) }
        else if gainB < 1 { turned = String(format: "File B is turned down by %.1f dB to match.", -gainBDB) }
        else { turned = "The two files already have the same loudness." }
        return turned + String(format: " Both play for %.1f seconds, the length of the shorter file.", durationSeconds)
    }
}

/// One playing file. Production wraps `AVAudioPlayer`; tests use a fake.
@MainActor
protocol BlindFileVoice: AnyObject {
    var currentTime: TimeInterval { get set }
    var volume: Float { get set }
    var isPlaying: Bool { get }
    func play() -> Bool
    func stop()
}

@MainActor
final class AVBlindFileVoice: BlindFileVoice {
    private let player: AVAudioPlayer

    /// `deviceUID` is the selected output; nil would mean the macOS default, which the page never allows.
    init(url: URL, deviceUID: String) throws {
        player = try AVAudioPlayer(contentsOf: url)
        player.currentDevice = deviceUID
        player.prepareToPlay()
    }

    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    var isPlaying: Bool { player.isPlaying }
    func play() -> Bool { player.play() }
    func stop() { player.stop() }
}

/// The remembered listening level of the file player (decision 29): starts low.
struct BlindFileLevelStore {
    static let key = "blindListening.fileLevel"
    static let defaultLevel = 0.1
    var defaults: UserDefaults = .standard

    var level: Double {
        get {
            guard defaults.object(forKey: Self.key) != nil else { return Self.defaultLevel }
            return min(1, max(0, defaults.double(forKey: Self.key)))
        }
        nonmutating set { defaults.set(min(1, max(0, newValue)), forKey: Self.key) }
    }
}

@MainActor
final class BlindFilePlayer: ObservableObject {
    enum Side { case a, b }

    private let voiceA: BlindFileVoice
    private let voiceB: BlindFileVoice
    private let levelStore: BlindFileLevelStore
    let match: BlindFileLoudnessMatch
    @Published private(set) var playing: Side?
    @Published var loopEnabled = false
    /// The chosen passage, in seconds from the start; clamped to the common length.
    @Published private(set) var loopStart: Double = 0
    @Published private(set) var loopEnd: Double
    @Published var level: Double {
        didSet {
            levelStore.level = level
            if let playing { voice(playing).volume = volume(for: playing) }
        }
    }

    init(voiceA: BlindFileVoice, voiceB: BlindFileVoice, match: BlindFileLoudnessMatch, levelStore: BlindFileLevelStore = .init()) {
        self.voiceA = voiceA
        self.voiceB = voiceB
        self.match = match
        self.levelStore = levelStore
        level = levelStore.level
        loopEnd = match.durationSeconds
    }

    /// Builds the player for two files on the selected output device (`deviceUID`), never the macOS default.
    static func make(
        urlA: URL, urlB: URL, deviceUID: String, match: BlindFileLoudnessMatch,
        voiceFactory: @MainActor (URL, String) throws -> BlindFileVoice = { try AVBlindFileVoice(url: $0, deviceUID: $1) }
    ) throws -> BlindFilePlayer {
        BlindFilePlayer(voiceA: try voiceFactory(urlA, deviceUID), voiceB: try voiceFactory(urlB, deviceUID), match: match)
    }

    private func voice(_ side: Side) -> BlindFileVoice { side == .a ? voiceA : voiceB }
    private func volume(for side: Side) -> Float { Float(level * (side == .a ? match.gainA : match.gainB)) }

    var position: Double { playing.map { voice($0).currentTime } ?? loopStartOrZero }
    private var loopStartOrZero: Double { loopEnabled ? loopStart : 0 }

    func setPassage(start: Double, end: Double) {
        let limit = match.durationSeconds
        let s = min(max(0, start), limit)
        let e = min(max(0, end), limit)
        // A passage is at least a quarter of a second.
        loopStart = min(s, max(0, limit - 0.25))
        loopEnd = max(e, min(limit, loopStart + 0.25))
    }

    /// Plays `side` from where the other one was, so switching keeps the position (G48).
    func play(_ side: Side) -> Bool {
        let at = position
        if let current = playing, current != side { voice(current).stop() }
        let next = voice(side)
        next.currentTime = at >= match.durationSeconds ? loopStartOrZero : at
        next.volume = volume(for: side)
        guard next.play() else { playing = nil; return false }
        playing = side
        return true
    }

    func stop() {
        voiceA.stop()
        voiceB.stop()
        playing = nil
    }

    /// Polled by the page (every 0.1 s): loops the passage, or stops at the common end.
    func tick() {
        guard let side = playing else { return }
        let v = voice(side)
        let end = loopEnabled ? loopEnd : match.durationSeconds
        guard v.currentTime >= end || !v.isPlaying else { return }
        if loopEnabled {
            v.currentTime = loopStart
            if !v.isPlaying { _ = v.play() }
        } else {
            stop()
        }
    }
}
