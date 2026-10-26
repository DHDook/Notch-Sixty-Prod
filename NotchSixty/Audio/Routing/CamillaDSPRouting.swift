import Foundation

// E8 S9: CamillaDSP import and export for the routing model (design note 10).
//
// Import reads a subset: `filters` of type Biquad, BiquadCombo (Butterworth and Linkwitz-Riley high and low pass),
// Gain and Delay; one `mixers` entry; and the `pipeline`. Filters before the mixer become program PEQ per input
// channel; filters after it become the ways of the output channel they sit on. Every item it cannot represent (Conv,
// Dither, Loudness, Volume, processors, unknown keys, ...) produces one warning and is skipped, never approximated.
// Export writes the same subset, so a supported model survives a round trip. Names are not carried by CamillaDSP:
// imported speakers and ways are named from their source and output channel. Pure and off the realtime thread.

struct CamillaRoutingImport {
    var routing: SpeakerRoutingConfiguration?
    /// Program PEQ by input channel (before the mixer).
    var programEQ: [Int: [RoutingEQSection]]
    var warnings: [String]
}

struct CamillaRoutingExport {
    var yaml: String
    var warnings: [String]
}

enum CamillaDSPRouting {
    // MARK: Import

    static func importRouting(
        _ text: String,
        context: SpeakerRoutingContext,
        deviceUID: String
    ) throws -> CamillaRoutingImport {
        let root = try YAMLSubset.parse(text)
        guard let entries = root.entries else {
            throw YAMLSubsetError(line: root.line, message: "The file must be a mapping with `devices`, `filters`, `mixers` and `pipeline`.")
        }
        var warnings: [String] = []
        let known: Set<String> = ["title", "description", "devices", "filters", "mixers", "pipeline", "processors"]
        for entry in entries where !known.contains(entry.key) {
            warnings.append("Line \(entry.line): unknown key `\(entry.key)` was ignored.")
        }
        if let processors = root["processors"] {
            warnings.append("Line \(processors.line): `processors` (compressors, loudness, ...) are not supported and were skipped.")
        }
        if let rate = root["devices"]?["samplerate"]?.double, abs(rate - context.sampleRate) > 0.5 {
            warnings.append("The file is written for \(Int(rate)) Hz; filters are redesigned at the device rate of \(Int(context.sampleRate)) Hz.")
        }

        // Filters.
        var filters: [String: ImportedFilter] = [:]
        for entry in root["filters"]?.entries ?? [] {
            filters[entry.key] = parseFilter(name: entry.key, node: entry.value, context: context, warnings: &warnings)
        }

        // Mixers: only the first one is used.
        var mixers: [String: Mixer] = [:]
        for entry in root["mixers"]?.entries ?? [] {
            let node = entry.value
            guard let inCount = node["channels"]?["in"]?.int, let outCount = node["channels"]?["out"]?.int,
                  inCount > 0, outCount > 0 else {
                warnings.append("Line \(node.line): mixer `\(entry.key)` needs `channels: {in, out}` and was skipped.")
                continue
            }
            var dests: [Int: [MixerSource]] = [:]
            for map in node["mapping"]?.items ?? [] {
                guard let dest = map["dest"]?.int, (0..<outCount).contains(dest) else {
                    warnings.append("Line \(map.line): mixer `\(entry.key)` has a mapping with a missing or out-of-range `dest`; skipped.")
                    continue
                }
                if map["mute"]?.bool == true { continue }
                for source in map["sources"]?.items ?? [] {
                    guard let channel = source["channel"]?.int, (0..<inCount).contains(channel) else {
                        warnings.append("Line \(source.line): mixer `\(entry.key)` has a source with a missing or out-of-range `channel`; skipped.")
                        continue
                    }
                    if source["mute"]?.bool == true { continue }
                    var gain = source["gain"]?.double ?? 0
                    if let scale = source["scale"]?.string?.lowercased(), scale == "linear" {
                        gain = gain == 0 ? -.infinity : 20 * log10(abs(gain))
                    }
                    guard gain.isFinite else { continue }
                    dests[dest, default: []].append(MixerSource(
                        channel: channel, gainDB: gain, inverted: source["inverted"]?.bool ?? false))
                }
            }
            mixers[entry.key] = Mixer(name: entry.key, inChannels: inCount, outChannels: outCount, dests: dests)
        }

        // Pipeline.
        var programEQ: [Int: [RoutingEQSection]] = [:]
        var outputFilters: [Int: [ImportedFilter]] = [:]
        var mixer: Mixer?
        for step in root["pipeline"]?.items ?? [] {
            switch step["type"]?.string {
            case "Mixer":
                guard let name = step["name"]?.string, let found = mixers[name] else {
                    warnings.append("Line \(step.line): pipeline mixer `\(step["name"]?.string ?? "?")` is not defined; skipped.")
                    continue
                }
                if mixer != nil {
                    warnings.append("Line \(step.line): only one mixer is supported; `\(name)` and later steps were skipped.")
                    return finish(mixer: mixer, outputFilters: outputFilters, programEQ: programEQ, warnings: warnings,
                                  context: context, deviceUID: deviceUID)
                }
                mixer = found
            case "Filter":
                var channels: [Int] = step["channels"]?.items?.compactMap(\.int) ?? []
                if channels.isEmpty, let single = step["channel"]?.int { channels = [single] }
                let names = step["names"]?.items?.compactMap(\.string) ?? []
                for channel in channels {
                    for name in names {
                        guard let filter = filters[name] else {
                            warnings.append("Line \(step.line): pipeline filter `\(name)` is not defined; skipped.")
                            continue
                        }
                        if mixer == nil {
                            switch filter {
                            case .eq(let section): programEQ[channel, default: []].append(section)
                            case .skipped: break
                            default:
                                warnings.append("Line \(step.line): `\(name)` (crossover, gain or delay) before the mixer is not supported; skipped.")
                            }
                        } else {
                            outputFilters[channel, default: []].append(filter)
                        }
                    }
                }
            case let other:
                warnings.append("Line \(step.line): pipeline step `\(other ?? "?")` is not supported and was skipped.")
            }
        }
        return finish(mixer: mixer, outputFilters: outputFilters, programEQ: programEQ, warnings: warnings,
                      context: context, deviceUID: deviceUID)
    }

    private struct MixerSource { var channel: Int; var gainDB: Double; var inverted: Bool }
    private struct Mixer { var name: String; var inChannels: Int; var outChannels: Int; var dests: [Int: [MixerSource]] }

    private enum ImportedFilter {
        case eq(RoutingEQSection)
        case xover(highPass: Bool, CrossoverCore.FilterSpec)
        case gain(db: Double, inverted: Bool)
        case delay(milliseconds: Double)
        case skipped
    }

    private static func parseFilter(
        name: String, node: YAMLNode, context: SpeakerRoutingContext, warnings: inout [String]
    ) -> ImportedFilter {
        let type = node["type"]?.string ?? "?"
        let p = node["parameters"]
        func skip(_ why: String) -> ImportedFilter {
            warnings.append("Line \(node.line): filter `\(name)` (\(type)) \(why) and was skipped.")
            return .skipped
        }
        switch type {
        case "Biquad":
            let sub = p?["type"]?.string ?? "?"
            guard let freq = p?["freq"]?.double else { return skip("has no `freq`") }
            if sub == "HighpassFO" || sub == "LowpassFO" {
                return .xover(highPass: sub == "HighpassFO",
                              CrossoverCore.FilterSpec(family: .butterworth, order: 1, cornerHz: freq))
            }
            let map: [String: (Int, Bool)] = [
                "Peaking": (0, true), "Lowshelf": (1, true), "Highshelf": (2, true), "Lowpass": (3, false),
                "Highpass": (4, false), "Notch": (5, false), "Allpass": (6, false), "Bandpass": (7, false),
            ]
            guard let (code, hasGain) = map[sub] else { return skip("uses the biquad type `\(sub)`, which has no equivalent") }
            guard let q = p?["q"]?.double else {
                return skip("sets the width by bandwidth or slope instead of Q")
            }
            let gain = hasGain ? (p?["gain"]?.double ?? 0) : 0
            guard (-24.0...24.0).contains(gain), q > 0, freq > 0 else { return skip("has a value outside the supported range") }
            return .eq(RoutingEQSection(type: code, frequencyHz: freq, gainDB: gain, q: q))
        case "BiquadCombo":
            let sub = p?["type"]?.string ?? "?"
            guard let freq = p?["freq"]?.double, let order = p?["order"]?.int else { return skip("has no `freq` or `order`") }
            let table: [String: (CrossoverCore.Family, Bool)] = [
                "ButterworthHighpass": (.butterworth, true), "ButterworthLowpass": (.butterworth, false),
                "LinkwitzRileyHighpass": (.linkwitzRiley, true), "LinkwitzRileyLowpass": (.linkwitzRiley, false),
            ]
            guard let (family, high) = table[sub] else { return skip("uses the combo `\(sub)`, which is not supported") }
            guard family.orders.contains(order) else { return skip("has an order the filter library does not offer") }
            return .xover(highPass: high, CrossoverCore.FilterSpec(family: family, order: order, cornerHz: freq))
        case "Gain":
            if p?["mute"]?.bool == true { return skip("is muted") }
            var gain = p?["gain"]?.double ?? 0
            var inverted = p?["inverted"]?.bool ?? false
            if p?["scale"]?.string?.lowercased() == "linear" {
                guard gain != 0 else { return skip("has zero linear gain") }
                if gain < 0 { inverted.toggle() }
                gain = 20 * log10(abs(gain))
            }
            return .gain(db: gain, inverted: inverted)
        case "Delay":
            guard let delay = p?["delay"]?.double, delay >= 0 else { return skip("has no valid `delay`") }
            switch (p?["unit"]?.string ?? "ms").lowercased() {
            case "ms": return .delay(milliseconds: delay)
            case "samples": return .delay(milliseconds: delay / context.sampleRate * 1000)
            case "mm": return .delay(milliseconds: delay / 343.0)
            default: return skip("uses an unknown delay unit")
            }
        default:
            return skip("is not supported")
        }
    }

    private static func finish(
        mixer: Mixer?, outputFilters: [Int: [ImportedFilter]], programEQ: [Int: [RoutingEQSection]],
        warnings inWarnings: [String], context: SpeakerRoutingContext, deviceUID: String
    ) -> CamillaRoutingImport {
        var warnings = inWarnings
        guard let mixer else {
            if !outputFilters.isEmpty { warnings.append("The pipeline has no mixer, so no routing was imported.") }
            return CamillaRoutingImport(routing: nil, programEQ: programEQ, warnings: warnings)
        }
        let dests = mixer.dests.mapValues { $0.map { ($0.channel, $0.gainDB, $0.inverted) } }
        func source(_ channel: Int) -> RoutingSource? {
            if channel < context.programLanes { return .program(channel) }
            if channel - context.programLanes < context.subwoofers { return .sub(channel - context.programLanes) }
            return nil
        }
        var speakers: [RoutedSpeaker] = []
        var speakerIndex: [RoutingSource: Int] = [:]
        var matrix: [RoutingMatrixEntry] = []
        for dest in dests.keys.sorted() {
            let endpoint = PhysicalOutputEndpoint(deviceUID: deviceUID, channelIndex: UInt32(dest))
            var feeds = (dests[dest] ?? []).compactMap { raw -> (RoutingSource, Double, Bool)? in
                guard let s = source(raw.0) else {
                    warnings.append("Output \(dest + 1) reads input channel \(raw.0 + 1), which the current layout does not have; skipped.")
                    return nil
                }
                return (s, raw.1, raw.2)
            }
            let filters = outputFilters[dest] ?? []
            func isUnity(_ f: (RoutingSource, Double, Bool)) -> Bool { abs(f.1) < 1e-9 && !f.2 }
            var wayFeed: (RoutingSource, Double, Bool)?
            if filters.isEmpty {
                if feeds.count == 1, isUnity(feeds[0]) { wayFeed = feeds[0]; feeds = [] }
            } else if let unity = feeds.firstIndex(where: isUnity) {
                wayFeed = feeds.remove(at: unity)
            } else if feeds.count == 1 {
                wayFeed = feeds[0]; feeds = []
            } else if !feeds.isEmpty {
                warnings.append("Output \(dest + 1) has filters but no unity-gain feed; its filters were skipped and its sources kept as a plain mix.")
            }
            for f in feeds {
                matrix.append(RoutingMatrixEntry(
                    source: f.0, output: endpoint, gain: (f.2 ? -1 : 1) * pow(10, f.1 / 20)))
            }
            guard let feed = wayFeed else { continue }
            var way = RoutedWay(name: "Output \(dest + 1)", endpoint: endpoint)
            if !isUnity(feed) { way.trimDB += feed.1; way.polarityInverted = feed.2 }
            for filter in filters {
                switch filter {
                case .eq(let section):
                    if way.eq.count < Int(N60_PEQ_MAX_SECTIONS) { way.eq.append(section) } else {
                        warnings.append("Output \(dest + 1) has more than \(N60_PEQ_MAX_SECTIONS) EQ sections; the rest were skipped.")
                    }
                case .xover(let high, let spec):
                    if high {
                        if way.highPass == nil { way.highPass = spec } else { warnings.append("Output \(dest + 1) has a second high-pass; it was skipped.") }
                    } else {
                        if way.lowPass == nil { way.lowPass = spec } else { warnings.append("Output \(dest + 1) has a second low-pass; it was skipped.") }
                    }
                case .gain(let db, let inverted):
                    way.trimDB += db
                    if inverted { way.polarityInverted.toggle() }
                case .delay(let ms): way.delayMilliseconds += ms
                case .skipped: break
                }
            }
            if let index = speakerIndex[feed.0] {
                speakers[index].ways.append(way)
            } else {
                speakerIndex[feed.0] = speakers.count
                speakers.append(RoutedSpeaker(name: "Speaker \(speakers.count + 1)", source: feed.0, ways: [way]))
            }
        }
        for index in speakers.indices where speakers[index].ways.count > RoutedSpeaker.maxWays {
            warnings.append("\(speakers[index].name) has more than \(RoutedSpeaker.maxWays) ways; the rest were skipped.")
            speakers[index].ways.removeLast(speakers[index].ways.count - RoutedSpeaker.maxWays)
        }
        guard !speakers.isEmpty || !matrix.isEmpty else {
            warnings.append("The mixer feeds no outputs, so no routing was imported.")
            return CamillaRoutingImport(routing: nil, programEQ: programEQ, warnings: warnings)
        }
        return CamillaRoutingImport(
            routing: SpeakerRoutingConfiguration(speakers: speakers, matrix: matrix),
            programEQ: programEQ, warnings: warnings)
    }

    // MARK: Export

    static func exportRouting(
        _ routing: SpeakerRoutingConfiguration,
        programEQ: [Int: [RoutingEQSection]] = [:],
        context: SpeakerRoutingContext,
        playbackDeviceName: String? = nil
    ) -> CamillaRoutingExport {
        var warnings: [String] = []
        let endpoints = routing.outputEndpoints
        guard let reference = endpoints.first?.deviceUID else {
            return CamillaRoutingExport(yaml: "", warnings: ["The routing has no outputs to export."])
        }
        if endpoints.contains(where: { $0.deviceUID != reference }) {
            warnings.append("CamillaDSP drives one playback device; outputs on other devices were left out.")
        }
        func included(_ e: PhysicalOutputEndpoint) -> Bool { e.deviceUID == reference }
        let outCount = Int((endpoints.filter(included).map(\.channelIndex).max() ?? 0)) + 1
        let inCount = max(1, context.programLanes + context.subwoofers)
        func channel(_ s: RoutingSource) -> Int { s.kind == .program ? s.index : context.programLanes + s.index }

        var filterLines: [String] = []
        var preNames: [Int: [String]] = [:]
        var postNames: [Int: [String]] = [:]
        var mapping: [Int: [(channel: Int, gainDB: Double, inverted: Bool)]] = [:]

        func eqLines(_ name: String, _ s: RoutingEQSection) -> Bool {
            let types = ["Peaking", "Lowshelf", "Highshelf", "Lowpass", "Highpass", "Notch", "Allpass", "Bandpass"]
            guard types.indices.contains(s.type) else {
                warnings.append("EQ section type \(s.type) has no CamillaDSP equivalent and was left out.")
                return false
            }
            filterLines += ["  \(name):", "    type: Biquad", "    parameters:", "      type: \(types[s.type])",
                            "      freq: \(num(s.frequencyHz))"]
            if s.type <= 2 { filterLines.append("      gain: \(num(s.gainDB))") }
            filterLines.append("      q: \(num(s.q))")
            return true
        }

        for lane in programEQ.keys.sorted() {
            for (k, section) in programEQ[lane]!.enumerated() {
                let name = "in\(lane)_eq\(k + 1)"
                if eqLines(name, section) { preNames[lane, default: []].append(name) }
            }
        }

        for speaker in routing.speakers {
            for way in speaker.ways where included(way.endpoint) {
                let d = Int(way.endpoint.channelIndex)
                mapping[d, default: []].append((channel(speaker.source), 0, false))
                func xover(_ spec: CrossoverCore.FilterSpec?, high: Bool) {
                    guard let spec else { return }
                    guard spec.family != .bessel else {
                        warnings.append("\(way.name): CamillaDSP has no Bessel crossover; the \(high ? "high" : "low")-pass was left out.")
                        return
                    }
                    let name = "out\(d)_\(high ? "hp" : "lp")"
                    let family = spec.family == .butterworth ? "Butterworth" : "LinkwitzRiley"
                    filterLines += ["  \(name):", "    type: BiquadCombo", "    parameters:",
                                    "      type: \(family)\(high ? "Highpass" : "Lowpass")",
                                    "      freq: \(num(spec.cornerHz))", "      order: \(spec.order)"]
                    postNames[d, default: []].append(name)
                }
                if way.trimDB != 0 || way.polarityInverted {
                    filterLines += ["  out\(d)_gain:", "    type: Gain", "    parameters:", "      gain: \(num(way.trimDB))",
                                    "      scale: dB", "      inverted: \(way.polarityInverted)"]
                    postNames[d, default: []].append("out\(d)_gain")
                }
                xover(way.highPass, high: true)
                xover(way.lowPass, high: false)
                for (k, section) in way.eq.enumerated() {
                    let name = "out\(d)_eq\(k + 1)"
                    if eqLines(name, section) { postNames[d, default: []].append(name) }
                }
                if way.delayMilliseconds > 0 {
                    filterLines += ["  out\(d)_delay:", "    type: Delay", "    parameters:",
                                    "      delay: \(num(way.delayMilliseconds))", "      unit: ms"]
                    postNames[d, default: []].append("out\(d)_delay")
                }
                if way.limiter != nil { warnings.append("\(way.name): CamillaDSP has no equivalent of the per-way limiter; it was left out.") }
                if way.realisation == .fir { warnings.append("\(way.name): linear-phase ways are exported as their minimum-phase equivalent.") }
            }
        }
        for entry in routing.matrix where included(entry.output) {
            guard entry.gain != 0, entry.gain.isFinite else {
                warnings.append("A zero-gain matrix entry was left out.")
                continue
            }
            mapping[Int(entry.output.channelIndex), default: []].append(
                (channel(entry.source), 20 * log10(abs(entry.gain)), entry.gain < 0))
        }
        warnings.append("Unity matrix-only outputs re-import as one-way speakers; names and the capture and playback device are not carried by CamillaDSP.")

        var lines: [String] = [
            "---", "title: \"Notch Sixty routing export\"",
            "description: \"Exported from the Notch Sixty routing matrix. Review device names before use.\"",
            "devices:", "  samplerate: \(Int(context.sampleRate.rounded()))", "  chunksize: 1024",
            "  capture:", "    type: CoreAudio", "    channels: \(inCount)", "    device: \"CHANGE_ME_CAPTURE\"",
            "  playback:", "    type: CoreAudio", "    channels: \(outCount)",
            "    device: \(quoted(playbackDeviceName ?? "CHANGE_ME_PLAYBACK"))",
            "mixers:", "  routing:", "    channels:", "      in: \(inCount)", "      out: \(outCount)", "    mapping:",
        ]
        for d in mapping.keys.sorted() {
            lines += ["      - dest: \(d)", "        sources:"]
            for s in mapping[d]! {
                lines += ["          - channel: \(s.channel)", "            gain: \(num(s.gainDB))",
                          "            inverted: \(s.inverted)"]
            }
        }
        lines.append("filters:")
        lines += filterLines.isEmpty ? ["  {}"] : filterLines
        lines.append("pipeline:")
        for lane in preNames.keys.sorted() {
            lines += ["  - type: Filter", "    channels: [\(lane)]", "    names:"] + preNames[lane]!.map { "      - \($0)" }
        }
        lines += ["  - type: Mixer", "    name: routing"]
        for d in postNames.keys.sorted() {
            lines += ["  - type: Filter", "    channels: [\(d)]", "    names:"] + postNames[d]!.map { "      - \($0)" }
        }
        return CamillaRoutingExport(yaml: lines.joined(separator: "\n") + "\n", warnings: warnings)
    }

    private static func num(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(format: "%.1f", value) : "\(value)"
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
