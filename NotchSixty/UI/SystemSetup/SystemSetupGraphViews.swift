import SwiftUI

// E12 S30: the graph, the placement diagrams and the term notes the guided setup steps share.

/// One frequency-response graph: log frequency across, level up, a legend that wraps. It fills the width it is given.
struct SystemSetupGraphView: View {
    let graph: SystemSetupGraph

    static let seatColours: [Color] = [.accentColor, .orange, .purple, .teal, .pink, .yellow, .indigo, .mint]

    static func colour(for curve: SystemSetupGraphCurve) -> Color {
        switch curve.role {
        case .measured(let seat): return seatColours[seat % seatColours.count]
        case .target: return .secondary
        case .predicted: return .green
        case .before: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text(graph.title).font(DesignType.label.font.bold())
            Canvas { context, size in draw(context: &context, size: size) }
                .frame(maxWidth: .infinity, minHeight: 150, idealHeight: 180, maxHeight: 200)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignRadius.small.pt))
                .accessibilityLabel(graph.title)
                .accessibilityValue(graph.curves.map(\.label).joined(separator: ", "))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: DesignSpacing.xs.pt) {
                ForEach(graph.curves) { curve in
                    HStack(spacing: DesignSpacing.xs.pt) {
                        Capsule().fill(Self.colour(for: curve)).frame(width: 16, height: 3)
                        Text(curve.label).font(DesignType.caption.font).lineLimit(2)
                    }
                }
            }
            Text(graph.caption).font(DesignType.caption.font).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let plot = CGRect(x: 36, y: 6, width: max(1, size.width - 44), height: max(1, size.height - 22))
        let range = graph.levelRangeDB
        func x(_ hz: Double) -> CGFloat {
            plot.minX + CGFloat(log(hz / graph.lowHz) / log(graph.highHz / graph.lowHz)) * plot.width
        }
        func y(_ db: Double) -> CGFloat {
            plot.maxY - CGFloat((db - range.lowerBound) / (range.upperBound - range.lowerBound)) * plot.height
        }
        var level = (range.lowerBound / 5).rounded(.up) * 5
        let step = (range.upperBound - range.lowerBound) > 40 ? 10.0 : 5.0
        while level <= range.upperBound {
            if level.truncatingRemainder(dividingBy: step) == 0 {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(level)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(level)))
                context.stroke(line, with: .color(.secondary.opacity(level == 0 ? 0.5 : 0.18)), lineWidth: level == 0 ? 1 : 0.5)
                context.draw(Text("\(Int(level))").font(.system(size: DesignType.minimumSize)).foregroundColor(.secondary),
                             at: CGPoint(x: plot.minX - 4, y: y(level)), anchor: .trailing)
            }
            level += 5
        }
        for hz in [20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] where hz >= graph.lowHz && hz <= graph.highHz {
            var line = Path()
            line.move(to: CGPoint(x: x(hz), y: plot.minY))
            line.addLine(to: CGPoint(x: x(hz), y: plot.maxY))
            context.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
            let label = hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))"
            context.draw(Text(label).font(.system(size: DesignType.minimumSize)).foregroundColor(.secondary),
                         at: CGPoint(x: x(hz), y: plot.maxY + 3), anchor: .top)
        }
        for curve in graph.curves {
            var path = Path()
            for (index, hz) in curve.frequenciesHz.enumerated() {
                let point = CGPoint(x: x(hz), y: y(min(max(curve.levelsDB[index], range.lowerBound), range.upperBound)))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let dashed = curve.role == .target || curve.role == .before
            context.stroke(path, with: .color(Self.colour(for: curve)),
                           style: StrokeStyle(lineWidth: dashed ? 1.2 : 1.8, lineJoin: .round, dash: dashed ? [4, 3] : []))
        }
    }
}

/// A graph with the simple / per seat switch above it. Shows `empty` text in place of the graph when there is no data.
struct SystemSetupGraphPanel: View {
    @ObservedObject var model: SystemSetupFlowModel
    let graph: SystemSetupGraph?
    let emptyNote: String
    /// E12 S8 (G88): the mode decides the detail; with `e12.simple-expert-modes` off the switch stays as it was.
    @Environment(\.interfaceMode) private var interfaceMode
    private var modesEnabled: Bool { FeatureFlags().isEnabled(.simpleExpertModes) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            if let graph {
                if !(modesEnabled && interfaceMode == .simple), graph.hasSeatDetail || model.graphDetail == .expert {
                    Picker("Detail", selection: $model.graphDetail) {
                        ForEach(SystemSetupGraphDetail.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                SystemSetupGraphView(graph: graph)
            } else {
                Text(emptyNote).font(DesignType.caption.font).foregroundStyle(.secondary)
            }
        }
        .onAppear { model.applyInterfaceMode(interfaceMode, modesEnabled: modesEnabled) }
        .onChange(of: interfaceMode) { _, mode in model.applyInterfaceMode(mode, modesEnabled: modesEnabled) }
    }
}

/// Plain explanations for the technical terms a step uses (G66).
struct SystemSetupTermNotes: View {
    let step: SystemSetupStep

    var body: some View {
        let terms = SystemSetupTerm.terms(on: step)
        if !terms.isEmpty {
            GroupBox("In plain words") {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    ForEach(terms) { term in
                        Text("\(Text(term.labelWithName).bold()): \(term.explanation)")
                            .font(DesignType.caption.font).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Side view of the microphone at ear height, or a top view of the seats (G61).
struct SystemSetupPlacementDiagram: View {
    enum Kind { case microphone, seats(count: Int) }
    let kind: Kind

    var body: some View {
        Canvas { context, size in
            switch kind {
            case .microphone: drawMicrophone(&context, size)
            case .seats(let count): drawSeats(&context, size, count: count)
            }
        }
        .frame(width: 200, height: 130)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignRadius.small.pt))
        .accessibilityHidden(true)
    }

    private func drawMicrophone(_ context: inout GraphicsContext, _ size: CGSize) {
        let ink = GraphicsContext.Shading.color(.secondary)
        let floorY = size.height - 14
        var floor = Path()
        floor.move(to: CGPoint(x: 8, y: floorY)); floor.addLine(to: CGPoint(x: size.width - 8, y: floorY))
        context.stroke(floor, with: ink, lineWidth: 1)
        // A seated listener: seat, back, head.
        var chair = Path()
        chair.move(to: CGPoint(x: 40, y: floorY - 34)); chair.addLine(to: CGPoint(x: 80, y: floorY - 34))
        chair.move(to: CGPoint(x: 40, y: floorY - 34)); chair.addLine(to: CGPoint(x: 40, y: floorY - 70))
        context.stroke(chair, with: ink, lineWidth: 1.5)
        context.stroke(Path(ellipseIn: CGRect(x: 50, y: floorY - 84, width: 20, height: 22)), with: ink, lineWidth: 1.5)
        // The microphone stand, its head at ear height, and an arrow up.
        var stand = Path()
        stand.move(to: CGPoint(x: 130, y: floorY)); stand.addLine(to: CGPoint(x: 130, y: floorY - 70))
        context.stroke(stand, with: ink, lineWidth: 1.5)
        context.fill(Path(ellipseIn: CGRect(x: 126, y: floorY - 78, width: 8, height: 8)), with: .color(.accentColor))
        var arrow = Path()
        arrow.move(to: CGPoint(x: 130, y: floorY - 82)); arrow.addLine(to: CGPoint(x: 130, y: floorY - 106))
        arrow.move(to: CGPoint(x: 125, y: floorY - 100)); arrow.addLine(to: CGPoint(x: 130, y: floorY - 106))
        arrow.addLine(to: CGPoint(x: 135, y: floorY - 100))
        context.stroke(arrow, with: .color(.accentColor), lineWidth: 1.5)
        var level = Path()
        level.move(to: CGPoint(x: 62, y: floorY - 73)); level.addLine(to: CGPoint(x: 126, y: floorY - 74))
        context.stroke(level, with: .color(.accentColor.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        context.draw(Text("ear height").font(.system(size: DesignType.minimumSize)).foregroundColor(.secondary), at: CGPoint(x: 150, y: floorY - 60), anchor: .leading)
        context.draw(Text("points up").font(.system(size: DesignType.minimumSize)).foregroundColor(.secondary), at: CGPoint(x: 142, y: floorY - 100), anchor: .leading)
    }

    private func drawSeats(_ context: inout GraphicsContext, _ size: CGSize, count: Int) {
        let marks = SystemSetupPlacementGuidance.seatMarks(count: count)
        var screen = Path()
        screen.move(to: CGPoint(x: size.width * 0.25, y: 10)); screen.addLine(to: CGPoint(x: size.width * 0.75, y: 10))
        context.stroke(screen, with: .color(.secondary), lineWidth: 3)
        context.draw(Text("speakers / screen").font(.system(size: DesignType.minimumSize)).foregroundColor(.secondary), at: CGPoint(x: size.width / 2, y: 20), anchor: .top)
        for (index, mark) in marks.enumerated() {
            let centre = CGPoint(x: mark.x * size.width, y: mark.y * size.height)
            let radius: CGFloat = index == 0 ? 9 : 6
            let shape = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            context.fill(shape, with: .color(index == 0 ? .accentColor : .secondary))
            if index == 0 {
                context.draw(Text("main").font(.system(size: DesignType.minimumSize)).foregroundColor(.secondary), at: CGPoint(x: centre.x, y: centre.y + 12), anchor: .top)
            }
        }
    }
}

/// The two diagrams with their guidance, in a disclosure so a returning user can fold it away.
struct SystemSetupPlacementGuide: View {
    let seatCount: Int
    @State private var expanded = true

    var body: some View {
        DisclosureGroup("Where to put the microphone and the seats", isExpanded: $expanded) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DesignSpacing.l.pt) { column(.microphone, SystemSetupPlacementGuidance.microphoneLines); column(.seats(count: seatCount), SystemSetupPlacementGuidance.seatLines) }
                VStack(alignment: .leading, spacing: DesignSpacing.m.pt) { column(.microphone, SystemSetupPlacementGuidance.microphoneLines); column(.seats(count: seatCount), SystemSetupPlacementGuidance.seatLines) }
            }
            .padding(.top, DesignSpacing.s.pt)
        }
    }

    private func column(_ kind: SystemSetupPlacementDiagram.Kind, _ lines: [String]) -> some View {
        HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
            SystemSetupPlacementDiagram(kind: kind)
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                ForEach(lines, id: \.self) { Text("• \($0)").font(DesignType.caption.font).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(minWidth: 220, maxWidth: 360, alignment: .leading)
        }
    }
}
