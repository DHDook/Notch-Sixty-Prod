import Foundation

/// E4 S30b: a 4 s history of the ambient residual's 100 Hz amplitude envelope, for the syllable-rate speech
/// detector (which needs 2 s; the analyser window is at most 1.4 s at 48 kHz). It keeps envelope numbers only:
/// the residual samples are reduced block by block and never stored (a partial block is kept as a sum of
/// squares and a count), so nothing speech-like can be played back from it.
///
/// Each poll the controller passes the whole analysis window and the frame count at its end. Windows overlap,
/// so only the frames after the last one consumed are used and every sample counts once. A gap (frames
/// missed), or a change of microphone, rate or epoch, clears the history.
struct SpeechEnvelopeHistory: Sendable {
    static let envelopeRateHz = 100.0
    static let historySeconds = 4.0

    private(set) var envelope: [Double] = []
    private var lastEndFrame: UInt64?
    private var sampleRate = 0.0
    private var epoch: UUID?
    private var microphoneID: String?
    private var partialSumSquares = 0.0
    private var partialCount = 0

    var seconds: Double { Double(envelope.count) / Self.envelopeRateHz }

    /// Speech likelihood 0...1 from the stored envelope; 0 until 2 s have accumulated.
    var confidence: Double { SpeechModulationDetector.confidence(envelope: envelope) }

    mutating func reset() {
        envelope.removeAll(keepingCapacity: true)
        lastEndFrame = nil
        partialSumSquares = 0
        partialCount = 0
    }

    mutating func append(
        window: [Float], endFrame: UInt64, sampleRate: Double, epoch: UUID, microphoneID: String?
    ) {
        guard sampleRate.isFinite, sampleRate >= Self.envelopeRateHz, !window.isEmpty else { reset(); return }
        if sampleRate != self.sampleRate || epoch != self.epoch || microphoneID != self.microphoneID {
            reset()
            self.sampleRate = sampleRate
            self.epoch = epoch
            self.microphoneID = microphoneID
        }
        let count = UInt64(window.count)
        guard endFrame >= count else { reset(); return }
        let start = endFrame - count
        var firstNew = 0
        if let last = lastEndFrame {
            if endFrame <= last { return } // nothing new (or time ran backwards: leave the history alone)
            if start > last { reset() } // frames were missed
            else { firstNew = Int(last - start) }
        }
        let block = max(Int((sampleRate / Self.envelopeRateHz).rounded()), 1)
        for index in firstNew..<window.count {
            let v = Double(window[index])
            partialSumSquares += v * v
            partialCount += 1
            if partialCount == block {
                envelope.append((partialSumSquares / Double(block)).squareRoot())
                partialSumSquares = 0
                partialCount = 0
            }
        }
        let cap = Int(Self.historySeconds * Self.envelopeRateHz)
        if envelope.count > cap { envelope.removeFirst(envelope.count - cap) }
        lastEndFrame = endFrame
    }
}
