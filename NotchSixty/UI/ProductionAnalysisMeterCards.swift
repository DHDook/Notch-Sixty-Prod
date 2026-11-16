import SwiftUI

/// Text for the E33 S8 cards; plain functions so the tests can check them.
enum AnalysisMeterText {
    static func decibels(_ value: Double?, suffix: String = "dB") -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f %@", value, suffix)
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
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(value)
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .monospacedDigit()
            .accessibilityIdentifier(id)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 14))
    .accessibilityElement(children: .combine)
}

/// PLR, PSR and crest (D1), balance (D5) and per-band correlation (D6) on Meters > Levels.
struct ProductionAnalysisMetersCard: View {
    let readout: AnalysisMeterReadout?
    let isRunning: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dynamics and Balance").font(.title3.bold())
                Spacer()
                Button("Reset", action: onReset)
                    .accessibilityIdentifier("meters.analysis.reset")
            }
            if !isRunning {
                Text("Start processing to measure.").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    meterTile("PLR", AnalysisMeterText.decibels(readout?.plr), id: "meters.analysis.plr")
                    meterTile("PSR", AnalysisMeterText.decibels(readout?.psr), id: "meters.analysis.psr")
                    meterTile("Crest (300 ms)", AnalysisMeterText.decibels(readout?.crestDB), id: "meters.analysis.crest")
                    meterTile("True peak max", AnalysisMeterText.decibels(readout?.truePeakMaxDBTP, suffix: "dBTP"),
                              id: "meters.analysis.truePeak")
                    meterTile("Balance", AnalysisMeterText.balance(readout?.balanceDB), id: "meters.analysis.balance")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(0..<3, id: \.self) { band in
                        meterTile(
                            "Correlation, \(AnalysisMeterText.bandTitles[band])",
                            AnalysisMeterText.correlation(readout?.correlation[band]),
                            id: "meters.analysis.correlation.\(band)")
                    }
                }
                Text(AnalysisMeterText.plrNote).font(.caption).foregroundStyle(.secondary)
                Text(AnalysisMeterText.correlationNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.14), in: .rect(cornerRadius: 18))
    }
}

/// Peak hold at input, post-EQ and output in one strip (D7).
struct ProductionHeadroomStripCard: View {
    let strip: HeadroomStripModel
    let isAvailable: Bool
    let isRunning: Bool
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Headroom").font(.title3.bold())
                Spacer()
                Button("Reset Hold", action: onReset).accessibilityIdentifier("meters.headroom.reset")
            }
            if !isAvailable {
                Text("The headroom strip is shown for stereo sessions.").font(.caption).foregroundStyle(.secondary)
            } else if !isRunning {
                Text("Start processing to measure.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(strip.points, id: \.id) { point in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(point.title).font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: min(max((point.holdDBFS + 60) / 60, 0), 1))
                                .tint(point.holdDBFS > -3 ? .red : (point.holdDBFS > -6 ? .orange : .blue))
                            Text(point.holdDBFS <= HeadroomStripModel.floorDB
                                 ? "—" : String(format: "%.1f dBFS", point.holdDBFS))
                                .font(.system(.body, design: .monospaced)).monospacedDigit()
                            Text(point.holdDBFS <= HeadroomStripModel.floorDB
                                 ? "" : String(format: "%.1f dB headroom", point.headroomDB))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("meters.headroom.\(point.id)")
                    }
                }
                Text("Peak hold of the stereo meter points since the last reset. The post-dynamics point is not measured yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.14), in: .rect(cornerRadius: 18))
    }
}

/// Dropout events and frames from the transport counters.
struct ProductionDropoutCard: View {
    let counter: DropoutCounter
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dropouts").font(.title3.bold())
                Spacer()
                Button("Reset", action: onReset).accessibilityIdentifier("meters.dropouts.reset")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                meterTile("Events", "\(counter.events)", id: "meters.dropouts.events")
                meterTile("Frames", "\(counter.frames)", id: "meters.dropouts.frames")
                meterTile("Last", AnalysisMeterText.lastEvent(counter.lastEvent, now: Date()), id: "meters.dropouts.last")
            }
            Text(AnalysisMeterText.dropoutNote).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.14), in: .rect(cornerRadius: 18))
    }
}

/// Third-octave bars (D8): 31 bars, −90…0 dBFS.
struct ProductionRTABarsView: View {
    let levelsDB: [Float]
    let isRunning: Bool
    private static let floorDB: Float = -90
    private let marks = [20, 100, 1_000, 10_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Third-octave RTA").font(.title2.bold())
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
            .padding(14)
            .background(.quaternary.opacity(0.20), in: .rect(cornerRadius: 20))
            .accessibilityElement()
            .accessibilityLabel("Third-octave analyser")
            .accessibilityValue(accessibilitySummary)
            .accessibilityIdentifier("meters.rta.bars")
            HStack {
                ForEach(marks, id: \.self) { Text($0 >= 1_000 ? "\($0 / 1_000) kHz" : "\($0) Hz") ; Spacer() }
            }
            .font(.caption2).foregroundStyle(.secondary)
            Text(AnalysisMeterText.rtaNote).font(.caption).foregroundStyle(.secondary)
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
