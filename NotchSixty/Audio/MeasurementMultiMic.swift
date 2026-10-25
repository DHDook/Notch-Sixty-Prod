import Foundation

/// E11 S9: one sweep, one record per seat (design notes 4 and 6).
///
/// Offline only: the capture transport hands over K equal-length channel captures of the same
/// pass; this type deconvolves each, finds its direct arrival and, for separate USB microphones,
/// ties every seat to the reference speaker's chirp so the clocks of the devices drop out.

/// How the microphones are clocked.
enum MultiMicMode: Equatable, Sendable {
    /// K channels of one interface: one clock, inter-seat delays are exact.
    case sharedClock
    /// Several USB microphones in one private aggregate: per-mic acoustic timing, less precise.
    case separateDevices

    var isLessPrecise: Bool { self == .separateDevices }

    var label: String {
        switch self {
        case .sharedClock: "Shared clock (one interface)"
        case .separateDevices: "Separate microphones (less precise)"
        }
    }
}

struct MultiMicSeat: Equatable, Sendable, Identifiable {
    var id: Int
    var label: String
}

/// Layout of one pass inside every capture, in frames from the start of the pass.
struct MultiMicPass: Equatable, Sendable {
    var sweep: [Float]
    var sweepStartFrame: Int
    /// Acoustic timing reference (a `makeReferenceChirp` template); required for `.separateDevices`.
    var referenceChirp: [Float]?
    var chirpStartFrame: Int
    var regularizationRatio: Double = 1e-6
}

enum MultiMicError: Error, Equatable {
    case invalidArguments
    /// A seat's capture is absent, the wrong length, or digital silence.
    case missingMic(seat: Int)
    /// A seat could not hear the timing reference clearly enough.
    case weakReference(seat: Int)
    case analysisFailed(seat: Int)
}

struct MultiMicSeatRecord: Equatable, Sendable {
    var seat: MultiMicSeat
    /// Full circular deconvolved response (negative time at the end, for H2-H5).
    var impulseResponse: [Float]
    /// Frame of the direct arrival in `impulseResponse`, sub-sample.
    var directArrivalFrames: Double
    /// Shared clock: seconds after seat 0's direct arrival. Separate: seconds after the reference
    /// speaker's own arrival (flight-time difference), independent of every device clock.
    var delaySeconds: Double
    var timingTier: MeasurementCore.TimingTier
    var referencePeakDB: Double?
}

extension MeasurementCore {
    /// One record per seat from K simultaneous captures. A nil capture is a missing mic and fails
    /// the whole pass: a partial set would silently drop a seat from the average.
    static func processMultiMic(
        captures: [[Float]?], seats: [MultiMicSeat], mode: MultiMicMode, pass: MultiMicPass, sampleRate: Double
    ) throws -> [MultiMicSeatRecord] {
        guard !captures.isEmpty, captures.count == seats.count, sampleRate > 0,
              !pass.sweep.isEmpty, pass.sweepStartFrame >= 0, pass.chirpStartFrame >= 0
        else { throw MultiMicError.invalidArguments }
        if mode == .separateDevices, pass.referenceChirp?.isEmpty ?? true { throw MultiMicError.invalidArguments }

        let length = captures.compactMap { $0?.count }.max() ?? 0
        var partial: [(IR: [Float], direct: Double, arrival: Arrival?)] = []
        for (index, seat) in seats.enumerated() {
            guard let capture = captures[index], capture.count == length, capture.contains(where: { $0 != 0 })
            else { throw MultiMicError.missingMic(seat: seat.id) }
            guard pass.sweepStartFrame < capture.count else { throw MultiMicError.invalidArguments }
            var arrival: Arrival?
            if mode == .separateDevices, let chirp = pass.referenceChirp {
                do {
                    // Search only the slot before the sweep: the sweep itself correlates with the chirp.
                    guard pass.chirpStartFrame < pass.sweepStartFrame else { throw MultiMicError.invalidArguments }
                    let window = Array(capture[pass.chirpStartFrame..<pass.sweepStartFrame])
                    var found = try findArrival(template: chirp, in: window, sampleRate: sampleRate)
                    found.frames += Double(pass.chirpStartFrame)
                    arrival = found
                } catch MultiMicError.invalidArguments {
                    throw MultiMicError.invalidArguments
                } catch {
                    throw MultiMicError.weakReference(seat: seat.id)
                }
            }
            let slice = Array(capture[pass.sweepStartFrame...])
            do {
                let response = try deconvolve(
                    excitation: pass.sweep, observed: slice, regularizationRatio: pass.regularizationRatio
                )
                let direct = try peakPosition(in: response, range: 0..<max(1, response.count / 2))
                partial.append((response, direct, arrival))
            } catch {
                throw MultiMicError.analysisFailed(seat: seat.id)
            }
        }

        return seats.enumerated().map { index, seat in
            let item = partial[index]
            let delayFrames: Double
            if let arrival = item.arrival {
                // direct = clock offset + flight time; arrival - chirpStart = clock offset + reference flight.
                delayFrames = item.direct - (arrival.frames - Double(pass.chirpStartFrame))
            } else {
                delayFrames = item.direct - partial[0].direct
            }
            return MultiMicSeatRecord(
                seat: seat,
                impulseResponse: item.IR,
                directArrivalFrames: item.direct,
                delaySeconds: delayFrames / sampleRate,
                timingTier: mode == .separateDevices ? .acousticChirp : .none,
                referencePeakDB: item.arrival?.peakToNeighbourhoodDB
            )
        }
    }
}
