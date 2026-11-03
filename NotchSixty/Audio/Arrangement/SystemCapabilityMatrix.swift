import Foundation

// E25 S1: the single capability table. One row per feature in the single-DAC audit (docs/epics/E25.md), one
// answer per arrangement class. All capability text in the UI comes from here, so a feature never explains itself
// twice, and E24 `MeasurementReadiness` can slot the reasons in. Rate-free; no engine access.

enum SystemFeature: String, CaseIterable, Sendable {
    case stereoPlayback
    case widerProgram
    case monoBassOnPair
    case dspSubFeed
    case perFeedCalibration
    case subAlignment
    case multiSubOptimiser
    case roomCorrection
    case multiSeatAveraging
    case programFIR
    case activeCrossovers
    case perSpeakerTrim
    case upmixer
    case speakerRoutingEditor
    case headphoneCorrection
    case binauralVirtualSpeakers
    case measurementSuite
    case generatorsAndMetering
    case roomGeometryAdvisor
    case quietZone
    case mimoRoomTreatment
    case ambientCompensation
    case exportsAndProfiles

    var displayName: String {
        switch self {
        case .stereoPlayback: return "Stereo playback, EQ, dynamics and protection"
        case .widerProgram: return "5.1 and 7.1 program"
        case .monoBassOnPair: return "Mono bass on the pair"
        case .dspSubFeed: return "DSP feed to a subwoofer"
        case .perFeedCalibration: return "Per-speaker trim, delay and polarity"
        case .subAlignment: return "Subwoofer level, delay and polarity alignment"
        case .multiSubOptimiser: return "Multi-sub optimiser and joint bass"
        case .roomCorrection: return "Room correction"
        case .multiSeatAveraging: return "Multi-seat averaging"
        case .programFIR: return "Program FIR and convolution"
        case .activeCrossovers: return "Active multi-way crossovers"
        case .perSpeakerTrim: return "Centre and surround trim, delay and correction"
        case .upmixer: return "Upmixer"
        case .speakerRoutingEditor: return "Speaker routing editor"
        case .headphoneCorrection: return "Headphone correction and crossfeed"
        case .binauralVirtualSpeakers: return "Binaural virtual speakers"
        case .measurementSuite: return "Measurement suite"
        case .generatorsAndMetering: return "Generators and metering"
        case .roomGeometryAdvisor: return "Room geometry advisor"
        case .quietZone: return "Quiet Zone"
        case .mimoRoomTreatment: return "MIMO room treatment"
        case .ambientCompensation: return "Ambient compensation and adaptive tonal"
        case .exportsAndProfiles: return "Exports and profiles"
        }
    }
}

/// The answer for one feature on one arrangement.
enum CapabilityAvailability: Equatable, Sendable {
    case available(note: String)
    case limited(note: String)
    case unavailable(reason: String, fix: String?)

    var text: String {
        switch self {
        case .available(let note), .limited(let note): return note
        case .unavailable(let reason, _): return reason
        }
    }

    var isUsable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

enum SystemCapabilityMatrix {
    static let receiverSetsBass = "Your receiver sets the subwoofer's level, delay and crossover."
    static let receiverAdvice = "Turn off the receiver's own room EQ to avoid double correction, and note that Pure Direct may bypass its bass management."

    /// `deviceChannelCount` is what the output device exposes now (0 when unknown); it only sharpens the fix text.
    static func evaluate(
        _ feature: SystemFeature,
        arrangement: SystemArrangement,
        deviceChannelCount: Int = 0
    ) -> CapabilityAvailability {
        let c = arrangement.arrangementClass
        let twoChannels = c != .a
        let downstream = c == .d || c == .e
        let moreOutputs = deviceChannelCount > 2 ? "" : " Choose an output device with more channels."
        switch feature {
        case .stereoPlayback, .programFIR, .ambientCompensation:
            return .available(note: "Works on every arrangement.")
        case .widerProgram:
            if c == .a { return .available(note: "Each speaker has its own output.") }
            return .limited(note: downstream
                ? "The player or macOS folds 5.1 and 7.1 to two channels before the app; your receiver may upmix them again."
                : "The player or macOS folds 5.1 and 7.1 to two channels before the app.")
        case .monoBassOnPair:
            switch c {
            case .c: return .available(note: "Low frequencies of the pair are shared by both speakers.")
            case .b: return .available(note: "Choose mono bass to share the low band between both speakers.")
            case .a: return .unavailable(reason: "Mono bass runs on a two-channel system; with a separate output per speaker, feed a subwoofer.", fix: "Choose a subwoofer feed instead.")
            case .d, .e: return .unavailable(reason: receiverSetsBass, fix: "Set the crossover in the receiver or the powered subwoofer.")
            }
        case .dspSubFeed:
            if c == .a { return .available(note: "Bass is crossed over to the subwoofer outputs you assign.") }
            if downstream { return .unavailable(reason: "The receiver feeds the subwoofer, so the app has no subwoofer output.", fix: nil) }
            return .unavailable(reason: "A subwoofer feed needs a third output.", fix: "Use mono bass on the pair, or a downstream subwoofer." + moreOutputs)
        case .perFeedCalibration:
            return .available(note: twoChannels ? "Trim, delay and polarity apply to the left and right feeds." : "Trim, delay and polarity apply to every output.")
        case .subAlignment:
            switch c {
            case .a: return .available(note: "Level, delay and polarity are aligned against the mains.")
            case .c: return .limited(note: "Only the crossover's phase all-pass can align the bass; there is no separate subwoofer.")
            case .b: return .unavailable(reason: "There is no subwoofer output to align.", fix: "Choose mono bass or a downstream subwoofer.")
            case .d, .e: return .unavailable(reason: receiverSetsBass, fix: receiverAdvice)
            }
        case .multiSubOptimiser:
            if c == .a, arrangement.bass == .dspToSubOutputs, arrangement.subwooferCount >= 2 {
                return .available(note: "Each subwoofer has an independent output.")
            }
            if c == .a { return .unavailable(reason: "The optimiser needs two or more subwoofer outputs.", fix: "Assign a second subwoofer output.") }
            return .unavailable(reason: "The optimiser needs independent subwoofer outputs.", fix: downstream ? receiverAdvice : "A third and further outputs are needed." + moreOutputs)
        case .roomCorrection:
            switch c {
            case .d, .e: return .limited(note: "Each feed is corrected as the full system through the receiver, subwoofer included. " + receiverAdvice)
            case .c: return .available(note: "Each speaker is corrected full band, after the mono-bass crossover.")
            case .a, .b: return .available(note: "Each speaker is corrected full band.")
            }
        case .multiSeatAveraging:
            return .available(note: twoChannels ? "Measurements are taken per feed and per seat." : "Measurements are taken per speaker and per seat.")
        case .activeCrossovers:
            return c == .a
                ? .available(note: "Assign one output per driver in the routing editor.")
                : .unavailable(reason: "An active crossover needs one output per driver.", fix: "Use a device with more outputs." )
        case .perSpeakerTrim:
            switch c {
            case .a: return .available(note: "Every speaker has its own trim, delay and correction.")
            case .e: return .unavailable(reason: "Centre and surround levels are set in the receiver.", fix: nil)
            case .b, .c, .d: return .limited(note: "Only the left and right feeds exist, so centre and surround are not used.")
            }
        case .upmixer:
            if c == .a { return arrangement.layout == .stereo
                ? .unavailable(reason: "A stereo layout has no other speakers to upmix to.", fix: "Choose a wider speaker layout.")
                : .available(note: "Stereo is upmixed to the speakers you have.") }
            return .unavailable(reason: "The upmixer needs one output per speaker.", fix: downstream ? "Use the receiver's own upmixer." : "Use a device with more outputs." )
        case .speakerRoutingEditor:
            return c == .a
                ? .available(note: "Route each speaker and driver to an output.")
                : .unavailable(reason: "Routing needs three or more outputs, and would end the two-channel session that keeps Quiet Zone available.", fix: "Use a device with more outputs.")
        case .headphoneCorrection:
            return .available(note: "Works with headphones on every arrangement.")
        case .binauralVirtualSpeakers:
            return .available(note: c == .a ? "Renders the program for headphones." : "Renders for headphones; 5.x program arrives through a program-source device.")
        case .measurementSuite:
            return downstream
                ? .limited(note: "Sweeps, RTA, distortion and decay are measured per feed; the subwoofer cannot be separated from the mains.")
                : .available(note: twoChannels ? "Measured per feed." : "Measured per speaker.")
        case .generatorsAndMetering:
            return .available(note: twoChannels ? "Two output lanes." : "One lane per output.")
        case .roomGeometryAdvisor:
            return downstream
                ? .limited(note: "Your speaker arrangement is recorded for advice, though the app cannot control the receiver.")
                : .available(note: "Advice uses your speaker arrangement.")
        case .quietZone:
            switch c {
            case .a: return .unavailable(reason: "Quiet Zone runs on the two-channel session; a separate output per speaker ends it.", fix: "Use a two-channel arrangement.")
            case .b, .c: return .available(note: "Quiet Zone runs on the stereo session.")
            case .d, .e: return .limited(note: "The receiver's latency counts against the budget, and its processing must stay static.")
            }
        case .mimoRoomTreatment:
            switch c {
            case .a: return .available(note: "Sources are the speaker and subwoofer outputs.")
            case .b, .c: return .limited(note: "Only the left and right speakers act as sources.")
            case .d, .e: return .limited(note: "Only the left and right feeds act as sources; the downstream subwoofer is not independent.")
            }
        case .exportsAndProfiles:
            return .available(note: twoChannels ? "Exports carry two channels; the arrangement is saved in the profile." : "The arrangement is saved in the profile.")
        }
    }

    /// Every feature's answer for an arrangement, in display order.
    static func rows(
        for arrangement: SystemArrangement, deviceChannelCount: Int = 0
    ) -> [(feature: SystemFeature, availability: CapabilityAvailability)] {
        SystemFeature.allCases.map { ($0, evaluate($0, arrangement: arrangement, deviceChannelCount: deviceChannelCount)) }
    }
}
