import Foundation

// E24 S5b2: acoustic timing for microphones on different devices (design note 10).
//
// Control plane only; it prepares the playback layout before the transport starts and aligns the finished captures.
//
// Each device in a private aggregate has its own start offset, so seats on different devices cannot share a frame
// clock. A short reference chirp plays on the front-left speaker just before the sweep. Every seat records it; the
// difference between a seat's chirp arrival and the primary seat's is that seat's clock offset (plus the reference
// speaker's flight-time difference, which is lost). Shifting each capture by that difference puts every seat on the
// primary seat's clock. Within a seat all sources keep their exact relative timing, which is what alignment, bass and
// grid design use.
//
// The chirp slot sits between the lead-in and the sweep: `[leadIn, leadIn + extraFrames)` of the extended capture. After
// the arrivals are read, the slot is cut out so the analyser sees the program's normal layout and its lead-in noise
// floor stays clean.

struct SeparateDeviceTiming: Equatable, Sendable {
    /// Quiet frames before the chirp, so a device that starts late still hears it inside the slot.
    let preFrames: Int
    let chirp: [Float]
    /// Quiet frames after the chirp, so its room tail has died away before the sweep.
    let guardFrames: Int
    let leadInFrames: Int
    let sampleRate: Double

    static let preSeconds = 0.05
    static let guardSeconds = 0.15

    init(program: RoomCorrectionSweepProgram) throws {
        let rate = program.sampleRate
        guard rate.isFinite, rate > 0 else { throw MultiMicError.invalidArguments }
        sampleRate = rate
        chirp = try MeasurementCore.makeReferenceChirp(sampleRate: rate)
        preFrames = Int((Self.preSeconds * rate).rounded())
        guardFrames = Int((Self.guardSeconds * rate).rounded())
        leadInFrames = program.leadInFrames
    }

    /// Frames the slot adds to the capture.
    var extraFrames: Int { preFrames + chirp.count + guardFrames }

    /// Where the chirp starts in the extended timeline.
    var chirpStartFrame: Int { leadInFrames + preFrames }

    func extendedFrameCount(of program: RoomCorrectionSweepProgram) -> Int { program.captureFrameCount + extraFrames }

    /// Another speaker is measured: the chirp plays on the reference channel and the sweep starts after the slot.
    func extendedProgram(_ program: RoomCorrectionSweepProgram) -> RoomCorrectionSweepProgram {
        var extended = program
        extended.leadInFrames += extraFrames
        return extended
    }

    func referenceProgram(outputChannel: UInt32) -> MultichannelReferenceProgram {
        MultichannelReferenceProgram(samples: chirp, startFrame: chirpStartFrame, outputChannelIndex: outputChannel)
    }

    /// The reference speaker itself is measured: its own output carries the chirp, then silence, then the sweep.
    func outputSweep(_ program: RoomCorrectionSweepProgram) -> [Float] {
        [Float](repeating: 0, count: preFrames) + chirp + [Float](repeating: 0, count: guardFrames) + program.sweepSamples
    }

    /// Cuts the slot out of one extended capture, giving the program's normal layout.
    func removeSlot(from capture: [Float]) -> [Float] {
        guard capture.count >= leadInFrames + extraFrames else { return capture }
        return Array(capture[..<leadInFrames]) + Array(capture[(leadInFrames + extraFrames)...])
    }

    /// Chirp arrival (frames from the start of the slot) at each seat.
    func chirpArrivals(in captures: [[Float]]) throws -> [Double] {
        try captures.enumerated().map { index, capture in
            guard capture.count >= leadInFrames + extraFrames else { throw MultiMicError.missingMic(seat: index) }
            let window = Array(capture[leadInFrames..<(leadInFrames + extraFrames)])
            do {
                return try MeasurementCore.findArrival(template: chirp, in: window, sampleRate: sampleRate).frames
            } catch {
                throw MultiMicError.weakReference(seat: index)
            }
        }
    }

    /// Every seat's capture in the program's normal layout, shifted onto the first seat's clock.
    /// Returns the shifts too (frames, positive means that seat's clock runs later).
    func align(_ captures: [[Float]]) throws -> (captures: [[Float]], shifts: [Double]) {
        guard !captures.isEmpty else { throw MultiMicError.invalidArguments }
        let arrivals = try chirpArrivals(in: captures)
        let shifts = arrivals.map { $0 - arrivals[0] }
        let aligned = zip(captures, shifts).map { capture, shift in
            Self.shifted(removeSlot(from: capture), advancedBy: Int(shift.rounded()))
        }
        return (aligned, shifts)
    }

    /// `out[i] = capture[i + frames]`, zero outside; the length is unchanged.
    static func shifted(_ capture: [Float], advancedBy frames: Int) -> [Float] {
        guard frames != 0 else { return capture }
        var out = [Float](repeating: 0, count: capture.count)
        for i in out.indices {
            let source = i + frames
            if source >= 0, source < capture.count { out[i] = capture[source] }
        }
        return out
    }
}
