#!/usr/bin/env python3
from pathlib import Path

ROOT = Path("NotchSixty/UI/ProductionRootView.swift")
PBX = Path("NotchSixty.xcodeproj/project.pbxproj")
MACOS = Path(".github/workflows/macos.yml")
EQ_VIEW = Path("NotchSixty/UI/ProductionEqualizerView.swift")
VALIDATOR = Path("ci/validate_pr37_equalizer_ui.py")
DOC = Path("docs/PR37_PRODUCTION_EQUALIZER.md")
SELF = Path("ci/pr37_apply_equalizer_workspace.py")
WORKFLOW = Path(".github/workflows/pr37-equalizer-integration.yml")

EQ_SOURCE = r'''import Foundation
import SwiftUI

struct ProductionEqualizerView: View {
    @ObservedObject var engine: AudioIOEngine
    @State private var selectedBandID: UUID?
    @State private var dragPreview: EQBand?
    @State private var pendingPublishTask: Task<Void, Never>?

    private var configuration: StereoEQConfiguration { engine.stereoEQConfiguration }
    private var bands: [EQBand] { configuration.editableBands }
    private var sampleRate: Double { engine.selectedOutputDevice?.nominalSampleRate ?? 48_000 }
    private var maximumFrequency: Double { max(20, sampleRate * 0.49) }

    private var selectedBand: EQBand? {
        if let dragPreview, dragPreview.id == selectedBandID { return dragPreview }
        guard let selectedBandID else { return nil }
        return bands.first(where: { $0.id == selectedBandID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            modeBar

            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    responseGraph
                    bandStrip
                }
                .frame(minWidth: 560)

                inspector
                    .frame(minWidth: 330, idealWidth: 360, maxWidth: 430)
            }
        }
        .padding(24)
        .navigationTitle("Equalizer")
        .onAppear { ensureSelection() }
        .onChange(of: configuration.channelMode) { _, _ in resetSelectionForBank() }
        .onChange(of: configuration.editChannel) { _, _ in resetSelectionForBank() }
        .onChange(of: bands.map(\.id)) { _, _ in ensureSelection() }
        .onDisappear {
            pendingPublishTask?.cancel()
            pendingPublishTask = nil
            dragPreview = nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Equalizer").font(.largeTitle.bold())
                Text("Static and Dynamic EQ share one band model. Drag a band on the response graph or use the precision inspector.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(configuration.enabledBandCount) ACTIVE")
                .font(.caption.bold())
                .tracking(1.1)
                .foregroundStyle(.secondary)
        }
    }

    private var modeBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                Picker("Channels", selection: Binding(
                    get: { configuration.channelMode },
                    set: { try? engine.setEQChannelMode($0) }
                )) {
                    ForEach(EQChannelMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                if configuration.channelMode != .linked {
                    Picker("Edit", selection: Binding(
                        get: { configuration.editChannel },
                        set: { engine.setEQEditChannel($0) }
                    )) {
                        ForEach(editChannels) { channel in Text(channel.displayName).tag(channel) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                Picker("Phase", selection: Binding(
                    get: { configuration.phaseMode },
                    set: { try? engine.setEQPhaseMode($0) }
                )) {
                    ForEach(EQPhaseMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)

                Spacer(minLength: 8)

                Toggle("Bypass", isOn: Binding(
                    get: { configuration.bypassed },
                    set: { try? engine.setEQBypassed($0) }
                ))
                .toggleStyle(.switch)

                Button {
                    addBand()
                } label: {
                    Label("Add Band", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .disabled(bands.count >= EQConfiguration.maximumBandCount)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    private var responseGraph: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RESPONSE").font(.caption.bold()).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Text("\(configuration.phaseMode.displayName) · \(activeLaneLabel) · \(sampleRate / 1_000, specifier: "%.1f") kHz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProductionEQResponseGraph(
                bands: bands,
                selectedBandID: selectedBandID,
                previewBand: dragPreview,
                sampleRate: sampleRate,
                bypassed: configuration.bypassed,
                onSelect: { selectedBandID = $0 },
                onPreview: { band in
                    selectedBandID = band.id
                    dragPreview = band
                    scheduleCoalescedPublish(band)
                },
                onCommit: { band in
                    pendingPublishTask?.cancel()
                    pendingPublishTask = nil
                    let sanitized = sanitize(band)
                    dragPreview = nil
                    try? engine.updateEQBand(sanitized)
                }
            )
            .frame(minHeight: 330)

            if bands.contains(where: { $0.enabled && $0.type == .fir }) {
                Label(
                    "Per-band FIR processing remains active, but imported FIR magnitude is intentionally omitted from this first live curve rather than approximated inaccurately.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.24), in: .rect(cornerRadius: 20))
    }

    private var bandStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BANDS").font(.caption.bold()).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Text("\(bands.count) / \(EQConfiguration.maximumBandCount)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }

            if bands.isEmpty {
                ContentUnavailableView(
                    "No EQ Bands",
                    systemImage: "slider.horizontal.3",
                    description: Text("Add a band to begin shaping the response.")
                )
                .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                            Button {
                                selectedBandID = band.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text("\(index + 1)").font(.caption2.bold())
                                        Text(band.type.displayName).font(.caption.bold())
                                        if band.dynamic.enabled {
                                            Text("DYN").font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 2)
                                                .background(.secondary.opacity(0.18), in: .capsule)
                                        }
                                    }
                                    Text("\(formatFrequency(band.frequencyHz)) · \(band.gainDB, specifier: "%+.1f") dB")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 126, alignment: .leading)
                                .padding(9)
                                .background(
                                    selectedBandID == band.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                    in: .rect(cornerRadius: 10)
                                )
                            }
                            .buttonStyle(.plain)
                            .opacity(band.enabled ? 1 : 0.48)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.18), in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var inspector: some View {
        if let band = selectedBand, let binding = selectedBandBinding(for: band.id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inspectorHeader(band: band, binding: binding)
                    staticControls(band: band, binding: binding)
                    if band.type.supportsDynamicEQ {
                        Divider()
                        dynamicControls(band: band, binding: binding)
                    } else {
                        Divider()
                        Label("Dynamic EQ is unavailable for this filter type.", systemImage: "bolt.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
            }
            .background(.quaternary.opacity(0.20), in: .rect(cornerRadius: 20))
        } else {
            ContentUnavailableView(
                "Select a Band",
                systemImage: "cursorarrow.click",
                description: Text("Choose a band below the graph or add a new one.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.16), in: .rect(cornerRadius: 20))
        }
    }

    private func inspectorHeader(band: EQBand, binding: Binding<EQBand>) -> some View {
        HStack {
            Toggle("Enabled", isOn: binding.enabled).toggleStyle(.switch)
            Spacer()
            Button(role: .destructive) {
                removeBand(band.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private func staticControls(band: EQBand, binding: Binding<EQBand>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Band").font(.headline)

            LabeledContent("Filter") {
                Picker("Filter", selection: binding.type) {
                    ForEach(EQFilterType.allCases) { type in Text(type.displayName).tag(type) }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            LabeledContent("Frequency") {
                HStack(spacing: 6) {
                    TextField("Hz", value: binding.frequencyHz, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .disabled(band.type == .fir)
                    Text("Hz").foregroundStyle(.secondary)
                }
            }

            LabeledContent("Gain") {
                HStack(spacing: 6) {
                    TextField("dB", value: binding.gainDB, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .disabled(!band.type.productionHasGainControl)
                    Text("dB").foregroundStyle(.secondary)
                }
            }

            LabeledContent("Q") {
                TextField("Q", value: binding.q, format: .number.precision(.fractionLength(2...3)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .disabled(band.type == .tilt || band.type == .fir)
            }

            if band.type.supportsSlope {
                LabeledContent("Slope") {
                    Picker("Slope", selection: binding.slope) {
                        ForEach(EQFilterSlope.allCases) { slope in Text(slope.displayName).tag(slope) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            if band.type == .peaking {
                Toggle("Constant-Q peak", isOn: binding.constantQ).toggleStyle(.switch)
            }

            if band.type == .linkwitzTransform {
                LabeledContent("Target Frequency") {
                    HStack(spacing: 6) {
                        TextField("Hz", value: binding.linkwitzTargetHz, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder).frame(width: 110)
                        Text("Hz").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Target Q") {
                    TextField("Q", value: binding.linkwitzTargetQ, format: .number.precision(.fractionLength(2...3)))
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                }
            }

            if band.type == .fir {
                VStack(alignment: .leading, spacing: 5) {
                    Text(band.firKernel?.name ?? "No FIR kernel loaded")
                        .font(.subheadline.bold())
                    if let taps = band.firKernel?.taps.count {
                        Text("\(taps) taps").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("FIR asset import remains in Engineering Validation until the production import/persistence milestone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func dynamicControls(band: EQBand, binding: Binding<EQBand>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Dynamic EQ").font(.headline)
                Spacer()
                Toggle("Dynamic", isOn: binding.dynamic.enabled).toggleStyle(.switch)
            }

            if band.dynamic.enabled {
                LabeledContent("Direction") {
                    Picker("Direction", selection: binding.dynamic.direction) {
                        ForEach(DynamicEQDirection.allCases) { direction in Text(direction.displayName).tag(direction) }
                    }
                    .labelsHidden().frame(width: 150)
                    .disabled(band.type == .notch)
                }

                metricField("Threshold", value: binding.dynamic.thresholdDB, suffix: "dB")
                metricField("Ratio", value: binding.dynamic.ratio, suffix: ":1")
                metricField("Max Cut", value: binding.dynamic.rangeDB, suffix: "dB")
                metricField("Attack", value: binding.dynamic.attackMs, suffix: "ms")
                metricField("Release", value: binding.dynamic.releaseMs, suffix: "ms")

                LabeledContent("Detector") {
                    Picker("Detector", selection: binding.dynamic.detectorMode) {
                        ForEach(DynamicEQDetectorMode.allCases) { mode in Text(mode.displayName).tag(mode) }
                    }
                    .labelsHidden().frame(width: 120)
                }

                if band.dynamic.detectorMode == .rms {
                    metricField("RMS Window", value: binding.dynamic.rmsWindowMs, suffix: "ms")
                }

                if band.dynamic.direction != .cutOnly {
                    Text("Boost").font(.subheadline.bold()).padding(.top, 3)
                    metricField("Boost Threshold", value: binding.dynamic.boostThresholdDB, suffix: "dB")
                    metricField("Boost Ratio", value: binding.dynamic.boostRatio, suffix: ":1")
                    metricField("Max Boost", value: binding.dynamic.maxBoostDB, suffix: "dB")
                }
            } else {
                Text("Enable Dynamic to add level-dependent correction to this ordinary EQ band. Static gain remains owned by the band itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metricField(_ label: String, value: Binding<Double>, suffix: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, value: value, format: .number.precision(.fractionLength(1...2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                Text(suffix).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            }
        }
    }

    private var editChannels: [EQEditChannel] {
        switch configuration.channelMode {
        case .linked: return [.linked]
        case .independent: return [.left, .right]
        case .midSide: return [.mid, .side]
        }
    }

    private var activeLaneLabel: String {
        configuration.channelMode == .linked ? configuration.channelMode.displayName : configuration.editChannel.displayName
    }

    private func selectedBandBinding(for id: UUID) -> Binding<EQBand>? {
        guard bands.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                if let dragPreview, dragPreview.id == id { return dragPreview }
                return engine.stereoEQConfiguration.editableBands.first(where: { $0.id == id })
                    ?? EQBand(id: id, enabled: false)
            },
            set: { updated in
                pendingPublishTask?.cancel()
                pendingPublishTask = nil
                dragPreview = nil
                try? engine.updateEQBand(sanitize(updated))
            }
        )
    }

    private func addBand() {
        let band = EQBand(frequencyHz: suggestedFrequency(), q: 1.0)
        do {
            try engine.addEQBand(band)
            selectedBandID = band.id
        } catch { }
    }

    private func removeBand(_ id: UUID) {
        do {
            try engine.removeEQBand(id: id)
            if selectedBandID == id { selectedBandID = nil }
            ensureSelection()
        } catch { }
    }

    private func suggestedFrequency() -> Double {
        guard let last = bands.last else { return 1_000 }
        return min(maximumFrequency * 0.95, max(20, last.frequencyHz * 1.6))
    }

    private func ensureSelection() {
        if let selectedBandID, bands.contains(where: { $0.id == selectedBandID }) { return }
        selectedBandID = bands.first?.id
    }

    private func resetSelectionForBank() {
        pendingPublishTask?.cancel()
        pendingPublishTask = nil
        dragPreview = nil
        selectedBandID = bands.first?.id
    }

    private func scheduleCoalescedPublish(_ band: EQBand) {
        pendingPublishTask?.cancel()
        let sanitized = sanitize(band)
        pendingPublishTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            try? engine.updateEQBand(sanitized)
        }
    }

    private func sanitize(_ input: EQBand) -> EQBand {
        var band = input
        if !band.frequencyHz.isFinite { band.frequencyHz = 1_000 }
        band.frequencyHz = min(max(band.frequencyHz, 1.0), maximumFrequency)

        if !band.gainDB.isFinite { band.gainDB = 0 }
        band.gainDB = min(max(band.gainDB, StereoEQConfiguration.bandGainRange.lowerBound), StereoEQConfiguration.bandGainRange.upperBound)

        if !band.q.isFinite || band.q <= 0 { band.q = 0.707 }
        band.q = min(max(band.q, 0.1), 20.0)

        if !band.linkwitzTargetHz.isFinite || band.linkwitzTargetHz <= 0 { band.linkwitzTargetHz = 40 }
        band.linkwitzTargetHz = min(max(band.linkwitzTargetHz, 1), maximumFrequency)
        if !band.linkwitzTargetQ.isFinite || band.linkwitzTargetQ <= 0 { band.linkwitzTargetQ = 0.707 }
        band.linkwitzTargetQ = min(max(band.linkwitzTargetQ, 0.1), 20)

        if band.type != .peaking { band.constantQ = false }
        if !band.type.supportsDynamicEQ { band.dynamic.enabled = false }
        if band.type == .notch { band.dynamic.direction = .cutOnly }

        if band.dynamic.enabled {
            band.frequencyHz = min(max(band.frequencyHz, DynamicEQBandConfiguration.frequencyRange.lowerBound), DynamicEQBandConfiguration.frequencyRange.upperBound)
            band.q = min(max(band.q, DynamicEQBandConfiguration.qRange.lowerBound), DynamicEQBandConfiguration.qRange.upperBound)
            band.dynamic.thresholdDB = band.dynamic.thresholdDB.clamped(to: EQBandDynamicConfiguration.thresholdRange)
            band.dynamic.ratio = band.dynamic.ratio.clamped(to: EQBandDynamicConfiguration.ratioRange)
            band.dynamic.rangeDB = band.dynamic.rangeDB.clamped(to: EQBandDynamicConfiguration.rangeRange)
            band.dynamic.attackMs = band.dynamic.attackMs.clamped(to: EQBandDynamicConfiguration.attackRange)
            band.dynamic.releaseMs = band.dynamic.releaseMs.clamped(to: EQBandDynamicConfiguration.releaseRange)
            band.dynamic.boostThresholdDB = band.dynamic.boostThresholdDB.clamped(to: EQBandDynamicConfiguration.boostThresholdRange)
            band.dynamic.boostRatio = band.dynamic.boostRatio.clamped(to: EQBandDynamicConfiguration.boostRatioRange)
            band.dynamic.maxBoostDB = band.dynamic.maxBoostDB.clamped(to: EQBandDynamicConfiguration.maxBoostRange)
            band.dynamic.rmsWindowMs = band.dynamic.rmsWindowMs.clamped(to: EQBandDynamicConfiguration.rmsWindowRange)
        }
        return band
    }

    private func formatFrequency(_ value: Double) -> String {
        value >= 1_000 ? String(format: "%.2g kHz", value / 1_000) : String(format: "%.0f Hz", value)
    }
}

private struct ProductionEQResponseGraph: View {
    let bands: [EQBand]
    let selectedBandID: UUID?
    let previewBand: EQBand?
    let sampleRate: Double
    let bypassed: Bool
    let onSelect: (UUID) -> Void
    let onPreview: (EQBand) -> Void
    let onCommit: (EQBand) -> Void

    private let minimumFrequency = 20.0
    private let minimumDB = -24.0
    private let maximumDB = 24.0

    private var graphMaximumFrequency: Double {
        min(96_000, max(minimumFrequency * 1.01, sampleRate * 0.49))
    }

    private var displayBands: [EQBand] {
        bands.map { band in
            if let previewBand, previewBand.id == band.id { return previewBand }
            return band
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.17))

                Canvas { context, _ in
                    drawGrid(context: &context, size: size)
                    drawResponse(context: &context, size: size)
                }
                .opacity(bypassed ? 0.35 : 1)

                ForEach(displayBands.filter { $0.type != .fir }) { band in
                    let point = point(for: band, size: size)
                    Circle()
                        .fill(selectedBandID == band.id ? Color.accentColor : Color.secondary)
                        .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: selectedBandID == band.id ? 2 : 1))
                        .frame(width: selectedBandID == band.id ? 18 : 14, height: selectedBandID == band.id ? 18 : 14)
                        .position(point)
                        .opacity(band.enabled ? 1 : 0.42)
                        .contentShape(Circle().inset(by: -10))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    onSelect(band.id)
                                    var updated = band
                                    updated.frequencyHz = frequency(atX: value.location.x, width: size.width)
                                    if band.type.productionHasGainControl {
                                        updated.gainDB = gain(atY: value.location.y, height: size.height)
                                    }
                                    onPreview(updated)
                                }
                                .onEnded { value in
                                    var updated = band
                                    updated.frequencyHz = frequency(atX: value.location.x, width: size.width)
                                    if band.type.productionHasGainControl {
                                        updated.gainDB = gain(atY: value.location.y, height: size.height)
                                    }
                                    onCommit(updated)
                                }
                        )
                        .onTapGesture { onSelect(band.id) }
                }

                if bypassed {
                    Text("EQ BYPASSED")
                        .font(.caption.bold()).tracking(1.7)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: .capsule)
                }
            }
        }
        .accessibilityLabel("Equalizer frequency response")
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let frequencies: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 40_000, 80_000]
        for frequency in frequencies where frequency <= graphMaximumFrequency {
            let x = xPosition(frequency, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
            context.draw(
                Text(axisFrequency(frequency)).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary),
                at: CGPoint(x: min(max(x, 24), size.width - 24), y: size.height - 11)
            )
        }

        for db in stride(from: -24.0, through: 24.0, by: 6.0) {
            let y = yPosition(db, height: size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(.secondary.opacity(db == 0 ? 0.34 : 0.14)), lineWidth: db == 0 ? 1.3 : 1)
            if db != 0 {
                context.draw(
                    Text("\(Int(db))").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary),
                    at: CGPoint(x: 16, y: y - 7)
                )
            }
        }
    }

    private func drawResponse(context: inout GraphicsContext, size: CGSize) {
        guard !displayBands.isEmpty else { return }
        let count = max(180, Int(size.width / 3))
        var path = Path()
        for index in 0..<count {
            let t = Double(index) / Double(max(1, count - 1))
            let frequency = exp(log(minimumFrequency) + t * (log(graphMaximumFrequency) - log(minimumFrequency)))
            let db = ProductionEQResponseMath.responseDB(bands: displayBands, sampleRate: sampleRate, frequencyHz: frequency)
            let point = CGPoint(x: CGFloat(t) * size.width, y: yPosition(db, height: size.height))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(.accentColor), lineWidth: 2.4)
    }

    private func point(for band: EQBand, size: CGSize) -> CGPoint {
        CGPoint(
            x: xPosition(min(max(band.frequencyHz, minimumFrequency), graphMaximumFrequency), width: size.width),
            y: yPosition(band.type.productionHasGainControl ? band.gainDB : 0, height: size.height)
        )
    }

    private func xPosition(_ frequency: Double, width: CGFloat) -> CGFloat {
        let clamped = min(max(frequency, minimumFrequency), graphMaximumFrequency)
        let t = (log(clamped) - log(minimumFrequency)) / (log(graphMaximumFrequency) - log(minimumFrequency))
        return CGFloat(t) * width
    }

    private func frequency(atX x: CGFloat, width: CGFloat) -> Double {
        let t = min(max(Double(x / max(width, 1)), 0), 1)
        return exp(log(minimumFrequency) + t * (log(graphMaximumFrequency) - log(minimumFrequency)))
    }

    private func yPosition(_ db: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(db, minimumDB), maximumDB)
        return CGFloat((maximumDB - clamped) / (maximumDB - minimumDB)) * height
    }

    private func gain(atY y: CGFloat, height: CGFloat) -> Double {
        let t = min(max(Double(y / max(height, 1)), 0), 1)
        return maximumDB - t * (maximumDB - minimumDB)
    }

    private func axisFrequency(_ value: Double) -> String {
        value >= 1_000 ? "\(Int(value / 1_000))k" : "\(Int(value))"
    }
}

private enum ProductionEQResponseMath {
    static func responseDB(bands: [EQBand], sampleRate: Double, frequencyHz: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0, frequencyHz > 0, frequencyHz < sampleRate * 0.5 else { return 0 }
        var total = 0.0
        for band in bands where band.enabled && band.type != .fir {
            guard let sections = try? band.compiledSections(sampleRate: sampleRate) else { continue }
            for section in sections {
                total += sectionResponseDB(section.coefficients, sampleRate: sampleRate, frequencyHz: frequencyHz)
            }
        }
        return min(max(total, -48), 48)
    }

    private static func sectionResponseDB(
        _ coefficients: N60BiquadCoefficients,
        sampleRate: Double,
        frequencyHz: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequencyHz / sampleRate
        let cos1 = cos(omega)
        let sin1 = sin(omega)
        let cos2 = cos(2 * omega)
        let sin2 = sin(2 * omega)

        let b0 = Double(coefficients.b0)
        let b1 = Double(coefficients.b1)
        let b2 = Double(coefficients.b2)
        let a1 = Double(coefficients.a1)
        let a2 = Double(coefficients.a2)

        let nr = b0 + b1 * cos1 + b2 * cos2
        let ni = -b1 * sin1 - b2 * sin2
        let dr = 1 + a1 * cos1 + a2 * cos2
        let di = -a1 * sin1 - a2 * sin2
        let numerator = nr * nr + ni * ni
        let denominator = dr * dr + di * di
        guard numerator.isFinite, denominator.isFinite, numerator > 1.0e-20, denominator > 1.0e-20 else { return 0 }
        return 10 * log10(numerator / denominator)
    }
}

private extension EQFilterType {
    var productionHasGainControl: Bool {
        switch self {
        case .peaking, .lowShelf, .highShelf, .tilt: return true
        case .lowPass, .highPass, .bandPass, .linkwitzTransform, .fir, .notch, .allPass: return false
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
'''

VALIDATOR_SOURCE = r'''#!/usr/bin/env python3
from pathlib import Path

root = Path("NotchSixty/UI/ProductionRootView.swift").read_text()
eq = Path("NotchSixty/UI/ProductionEqualizerView.swift").read_text()
pbx = Path("NotchSixty.xcodeproj/project.pbxproj").read_text()
workflow = Path(".github/workflows/macos.yml").read_text()

required_root = [
    "ProductionEqualizerView(engine: engine)",
]
required_eq = [
    "struct ProductionEqualizerView: View",
    "ProductionEQResponseGraph",
    "EQChannelMode.allCases",
    "EQPhaseMode.allCases",
    "engine.addEQBand",
    "engine.updateEQBand",
    "engine.removeEQBand",
    "Dynamic EQ",
    "DragGesture(minimumDistance: 0)",
    "scheduleCoalescedPublish",
    "33_000_000",
    "StereoEQConfiguration.bandGainRange",
    "DynamicEQBandConfiguration.qRange",
    "band.compiledSections(sampleRate: sampleRate)",
    "Per-band FIR processing remains active",
]

missing = [token for token in required_root if token not in root]
missing += [token for token in required_eq if token not in eq]
if missing:
    raise SystemExit("PR37 production EQ guard failed; missing: " + ", ".join(missing))

if "The production graphical EQ editor follows on this UI foundation." in root:
    raise SystemExit("PR37 production EQ guard failed: Equalizer still routes to the placeholder")

if "ProductionEqualizerView.swift" not in pbx:
    raise SystemExit("PR37 production EQ guard failed: production EQ source is not in the Xcode project")

if "Validate PR37 Production Equalizer" not in workflow:
    raise SystemExit("PR37 production EQ guard failed: macOS CI does not retain the PR37 validator")

print("PR37 production Equalizer guard passed")
'''

DOC_SOURCE = r'''# PR37 — Production Equalizer workspace

## Scope

PR37 replaces the production Equalizer placeholder with the shipping-oriented EQ editor while retaining the accepted PR34/PR35 DSP and realtime architecture.

The production UI uses the existing `StereoEQConfiguration` / `EQBand` control plane directly. It does not introduce a second EQ state model and it does not recreate Dynamic EQ as a separate user-facing bank.

## First implementation slice

- Linked / Independent L/R / Mid-Side domain selection.
- Per-domain editable lane selection.
- Minimum / Mixed / Linear phase selection.
- Whole-EQ bypass.
- Add, select, enable, edit, and remove ordinary EQ bands.
- Precision controls for filter type, frequency, gain, Q, slope, Constant-Q, and Linkwitz target metadata.
- Dynamic EQ exposed contextually on an ordinary supported EQ band.
- Log-frequency interactive response graph.
- Direct graph manipulation of frequency and gain-bearing filters.
- Drag preview remains UI-local and realtime publication is coalesced to roughly 30 Hz; gesture completion publishes the final exact value.
- Static graph magnitude is derived from the same compiled biquad sections used by the control plane rather than from a separate hand-written filter-shape approximation.

## FIR display rule

Per-band FIR remains fully active in DSP. The first live production response graph deliberately omits imported FIR magnitude rather than drawing an inaccurate approximation. The UI states this explicitly. Production FIR asset import/visualization will be completed with the persistence/import layer.

## Realtime boundary

No response-graph drawing or coefficient design occurs in the realtime callback. UI response evaluation runs on the product/UI side using already defined control-plane band compilation. Drag publication uses the existing graph publisher and is coalesced so pointer-rate events do not flood graph publication.

## Validation

`ci/validate_pr37_equalizer_ui.py` retains the production route, domain/phase controls, ordinary-band Dynamic EQ model, direct manipulation/coalescing contract, Xcode source membership, and CI integration.
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Unable to patch {label}: expected anchor not found")
    return text.replace(old, new, 1)


# 1) Route production Equalizer to the real workspace.
root = ROOT.read_text()
placeholder = '''        case .equalizer:\n            ProductionPlaceholderPage(\n                title: "Equalizer",\n                subtitle: "Static and dynamic EQ, channel domains, and phase strategy.",\n                systemImage: "slider.horizontal.3",\n                detail: "The production graphical EQ editor follows on this UI foundation."\n            )'''
root = replace_once(root, placeholder, '''        case .equalizer:\n            ProductionEqualizerView(engine: engine)''', "ProductionRootView Equalizer route")
ROOT.write_text(root)

# 2) Create production EQ implementation, validator, and design note.
EQ_VIEW.write_text(EQ_SOURCE)
VALIDATOR.write_text(VALIDATOR_SOURCE)
VALIDATOR.chmod(0o755)
DOC.write_text(DOC_SOURCE)

# 3) Add the source file to the explicit Xcode project.
pbx = PBX.read_text()
pbx = replace_once(
    pbx,
    '\t\tA40000000000000000000010 /* ProductionRootView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A40000000000000000000020 /* ProductionRootView.swift */; };',
    '\t\tA40000000000000000000010 /* ProductionRootView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A40000000000000000000020 /* ProductionRootView.swift */; };\n\t\tA40000000000000000000011 /* ProductionEqualizerView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A40000000000000000000021 /* ProductionEqualizerView.swift */; };',
    "PBX build file"
)
pbx = replace_once(
    pbx,
    '\t\tA40000000000000000000020 /* ProductionRootView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionRootView.swift; sourceTree = "<group>"; };',
    '\t\tA40000000000000000000020 /* ProductionRootView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionRootView.swift; sourceTree = "<group>"; };\n\t\tA40000000000000000000021 /* ProductionEqualizerView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionEqualizerView.swift; sourceTree = "<group>"; };',
    "PBX file reference"
)
pbx = replace_once(
    pbx,
    '\t\tA40000000000000000000050 /* UI */ = {isa = PBXGroup; children = (A40000000000000000000020 /* ProductionRootView.swift */,); path = UI; sourceTree = "<group>"; };',
    '\t\tA40000000000000000000050 /* UI */ = {isa = PBXGroup; children = (A40000000000000000000020 /* ProductionRootView.swift */, A40000000000000000000021 /* ProductionEqualizerView.swift */,); path = UI; sourceTree = "<group>"; };',
    "PBX UI group"
)
pbx = replace_once(
    pbx,
    '\t\t\t\tA40000000000000000000010 /* ProductionRootView.swift in Sources */,',
    '\t\t\t\tA40000000000000000000010 /* ProductionRootView.swift in Sources */,\n\t\t\t\tA40000000000000000000011 /* ProductionEqualizerView.swift in Sources */,',
    "PBX Sources phase"
)
PBX.write_text(pbx)

# 4) Retain a dedicated PR37 source guard in normal macOS CI.
workflow = MACOS.read_text()
anchor = '''      - name: Validate PR36 Production UI Foundation\n        run: python3 ci/validate_pr36_ui_foundation.py\n'''
insert = anchor + '''\n      - name: Validate PR37 Production Equalizer\n        run: python3 ci/validate_pr37_equalizer_ui.py\n'''
workflow = replace_once(workflow, anchor, insert, "macOS PR37 validator step")
MACOS.write_text(workflow)

# 5) Keep branch diff clean: integration helper/workflow are temporary only.
if WORKFLOW.exists():
    WORKFLOW.unlink()
if SELF.exists():
    SELF.unlink()

print("Applied PR37 production Equalizer workspace")
