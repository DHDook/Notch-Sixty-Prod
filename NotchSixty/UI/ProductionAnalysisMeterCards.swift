import AppKit
import SwiftUI

/// Text for the E33 S8 cards; plain functions so the tests can check them.
enum AnalysisMeterText {
    static func decibels(_ value: Double?, suffix: String = "dB") -> String {
        guard let value, value.isFinite else { return "—" }
        return DesignFormat.level(value, unit: suffix)
    }

    static func balance(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        if abs(value) < 0.05 { return "Centred" }
        let side = value > 0 ? "L" : "R"
        let suffix = abs(value) >= BalanceMeter.clampDB - 0.05 ? " or more" : ""
        return String(format: "%@ %.1f dB%@ louder", side, abs(value), suffix)
    }

    static func correlation(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%+.2f", value)
    }

    static let bandTitles = ["Below 200 Hz", "200 Hz – 2 kHz", "Above 2 kHz"]

    static func lastEvent(_ date: Date?, now: Date) -> String {
        guard let date else { return "none" }
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        return seconds < 60 ? "\(seconds) s ago" : "\(seconds / 60) min ago"
    }

    static let plrNote = "PLR is the true-peak maximum minus integrated loudness; PSR uses the last 3 s of true peak and "
        + "short-term loudness; crest is sample peak minus RMS over 300 ms. Measured on the output."
    static let correlationNote = "Correlation of left and right in three bands (4th-order Linkwitz–Riley splits, 300 ms): "
        + "+1 identical, 0 unrelated, −1 opposite."
    static let dropoutNote = "An event is one reading in which the transport's underrun or overrun frame count rose. "
        + "Counted since this page was opened."
    static let rtaNote = "31 third-octave bands, 20 Hz–20 kHz, on the output. Bands below 1 kHz come from a longer, "
        + "decimated analysis, so they respond more slowly."
}

private func meterTile(_ title: String, _ value: String, id: String) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
        Text(title).font(DesignType.caption.font).foregroundStyle(.secondary)
        Text(value)
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .monospacedDigit()
            .accessibilityIdentifier(id)
    }
    .padding(DesignSpacing.m.pt)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .designSurface(.medium)
    .accessibilityElement(children: .combine)
}

/// PLR, PSR and crest (D1), balance (D5) and per-band correlation (D6) on Meters > Levels.
struct ProductionAnalysisMetersCard: View {
    let readout: AnalysisMeterReadout?
    let isRunning: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dynamics and Balance").font(DesignType.sectionTitle.font)
                Spacer()
                Button("Reset", action: onReset)
                    .accessibilityIdentifier("meters.analysis.reset")
            }
            if !isRunning {
                Text("Start processing to measure.").font(DesignType.caption.font).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                    meterTile("PLR", AnalysisMeterText.decibels(readout?.plr), id: "meters.analysis.plr")
                    meterTile("PSR", AnalysisMeterText.decibels(readout?.psr), id: "meters.analysis.psr")
                    meterTile("Crest (300 ms)", AnalysisMeterText.decibels(readout?.crestDB), id: "meters.analysis.crest")
                    meterTile("True peak max", AnalysisMeterText.decibels(readout?.truePeakMaxDBTP, suffix: "dBTP"),
                              id: "meters.analysis.truePeak")
                    meterTile("Balance", AnalysisMeterText.balance(readout?.balanceDB), id: "meters.analysis.balance")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                    ForEach(0..<3, id: \.self) { band in
                        meterTile(
                            "Correlation, \(AnalysisMeterText.bandTitles[band])",
                            AnalysisMeterText.correlation(readout?.correlation[band]),
                            id: "meters.analysis.correlation.\(band)")
                    }
                }
                Text(AnalysisMeterText.plrNote).font(DesignType.caption.font).foregroundStyle(.secondary)
                Text(AnalysisMeterText.correlationNote).font(DesignType.caption.font).foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.large)
    }
}

/// Peak hold at input, post-EQ and output in one strip (D7).
struct ProductionHeadroomStripCard: View {
    let strip: HeadroomStripModel
    let isAvailable: Bool
    let isRunning: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack(alignment: .firstTextBaseline) {
                Text("Headroom").font(DesignType.sectionTitle.font)
                Spacer()
                Button("Reset Hold", action: onReset).accessibilityIdentifier("meters.headroom.reset")
            }
            if !isAvailable {
                Text("The headroom strip is shown for stereo sessions.").font(DesignType.caption.font).foregroundStyle(.secondary)
            } else if !isRunning {
                Text("Start processing to measure.").font(DesignType.caption.font).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                    ForEach(strip.points, id: \.id) { point in
                        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                            Text(point.title).font(DesignType.caption.font).foregroundStyle(.secondary)
                            ProgressView(value: min(max((point.holdDBFS + 60) / 60, 0), 1))
                                .tint(point.holdDBFS > -3 ? StatusLevel.problem.color : (point.holdDBFS > -6 ? StatusLevel.attention.color : .blue))
                            Text(point.holdDBFS <= HeadroomStripModel.floorDB
                                 ? "—" : String(format: "%.1f dBFS", point.holdDBFS))
                                .font(.system(.body, design: .monospaced)).monospacedDigit()
                            Text(point.holdDBFS <= HeadroomStripModel.floorDB
                                 ? "" : String(format: "%.1f dB headroom", point.headroomDB))
                                .font(DesignType.caption.font).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("meters.headroom.\(point.id)")
                    }
                }
                Text("Peak hold of the stereo meter points since the last reset. The post-dynamics point is not measured yet.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.large)
    }
}

/// Dropout events and frames from the transport counters.
struct ProductionDropoutCard: View {
    let counter: DropoutCounter
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dropouts").font(DesignType.sectionTitle.font)
                Spacer()
                Button("Reset", action: onReset).accessibilityIdentifier("meters.dropouts.reset")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                meterTile("Events", "\(counter.events)", id: "meters.dropouts.events")
                meterTile("Frames", "\(counter.frames)", id: "meters.dropouts.frames")
                meterTile("Last", AnalysisMeterText.lastEvent(counter.lastEvent, now: Date()), id: "meters.dropouts.last")
            }
            Text(AnalysisMeterText.dropoutNote).font(DesignType.caption.font).foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.large)
    }
}

/// Input overs (E33 S10): frames above 0 dBTP at the chain input, per lane, since the page was shown or reset.
struct ProductionInputOversCard: View {
    let reading: InputOversReading
    let isRunning: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack(alignment: .firstTextBaseline) {
                Text(reading.title).font(DesignType.sectionTitle.font)
                Spacer()
                Button("Reset", action: onReset).accessibilityIdentifier("meters.inputOvers.reset")
            }
            if isRunning, !reading.counts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: DesignSpacing.m.pt)], spacing: DesignSpacing.m.pt) {
                    meterTile("Total", "\(reading.total)", id: "meters.inputOvers.total")
                    ForEach(Array(reading.perLane.prefix(8).enumerated()), id: \.offset) { lane, count in
                        meterTile("Lane \(lane + 1)", "\(count)", id: "meters.inputOvers.lane\(lane + 1)")
                    }
                }
            } else {
                Text("Start processing to count input overs.").font(.callout).foregroundStyle(.secondary)
            }
            Text(reading.note).font(DesignType.caption.font).foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.large)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meters.inputOvers")
    }
}

/// Third-octave bars (D8): 31 bars, −90…0 dBFS.
struct ProductionRTABarsView: View {
    let levelsDB: [Float]
    let isRunning: Bool
    private static let floorDB: Float = -90
    private let marks = [20, 100, 1_000, 10_000]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Third-octave RTA").font(DesignType.sectionTitle.font)
            if !isRunning {
                Text("Start processing to view the RTA.").foregroundStyle(.secondary)
            } else if levelsDB.count != RTABandMap.bandCount {
                Text("The RTA is filling its analysis window…").foregroundStyle(.secondary)
            }
            Canvas { context, size in
                let count = RTABandMap.bandCount
                let slot = size.width / CGFloat(count)
                for i in 0..<count {
                    let level = i < levelsDB.count ? levelsDB[i] : Self.floorDB
                    let fraction = CGFloat(min(max((level - Self.floorDB) / -Self.floorDB, 0), 1))
                    let rect = CGRect(x: CGFloat(i) * slot + 1, y: size.height * (1 - fraction),
                                      width: max(slot - 2, 1), height: size.height * fraction)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.accentColor))
                }
            }
            .frame(minHeight: 280)
            .padding(DesignSpacing.l.pt)
            .designSurface(.large)
            .accessibilityElement()
            .accessibilityLabel("Third-octave analyser")
            .accessibilityValue(accessibilitySummary)
            .accessibilityIdentifier("meters.rta.bars")
            HStack {
                ForEach(marks, id: \.self) { Text($0 >= 1_000 ? "\($0 / 1_000) kHz" : "\($0) Hz") ; Spacer() }
            }
            .font(DesignType.caption.font).foregroundStyle(.secondary)
            Text(AnalysisMeterText.rtaNote).font(DesignType.caption.font).foregroundStyle(.secondary)
        }
    }

    private var accessibilitySummary: String {
        guard levelsDB.count == RTABandMap.bandCount, let top = levelsDB.indices.max(by: { levelsDB[$0] < levelsDB[$1] }) else {
            return "No data"
        }
        let name = RTABandMap.nominal[top]
        let hz = name >= 1_000 ? String(format: "%g kHz", name / 1_000) : String(format: "%g Hz", name)
        return String(format: "Loudest band %@ at %.0f dBFS", hz, levelsDB[top])
    }
}

/// E33 S16: the session event list, newest first (time, what, where, how much), for this session and the previous one.
struct ProductionEventHistoryCard: View {
    @ObservedObject var history: SessionEventHistory
    @State private var showPrevious = false

    private var shown: [SessionEvent] {
        showPrevious ? history.previous.reversed() : history.log.newestFirst
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack(alignment: .firstTextBaseline) {
                Text("History").font(DesignType.sectionTitle.font)
                Spacer()
                Picker("Session", selection: $showPrevious) {
                    Text("This session").tag(false)
                    Text("Previous session").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                .accessibilityIdentifier("meters.history.session")
                Button("Copy as text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(history.exportText(), forType: .string)
                }.accessibilityIdentifier("meters.history.copy")
                Button("Clear") { history.clear() }.accessibilityIdentifier("meters.history.clear")
            }
            if shown.isEmpty {
                Text(showPrevious ? "No events were kept from the previous session." : "No events this session.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    ForEach(shown) { event in
                        let text = event.summary(timeText: SessionEventText.time(event.time))
                        Text(text).font(.callout.monospacedDigit())
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(text)
                    }
                }
                .accessibilityIdentifier("meters.history.list")
            }
            Text("Events are noted while the meters are polling, kept for this session and the previous one, and never store audio.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.l.pt)
        .designSurface(.large)
    }
}
