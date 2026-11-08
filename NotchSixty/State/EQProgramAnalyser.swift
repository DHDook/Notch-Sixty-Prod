import Foundation

/// E27 S2b: the program spectrum behind the Equalizer graph.
///
/// Source of truth (design note 15): the existing render capture (`analysisFrames` in the realtime
/// bridge, drained and transformed by `ProductionAnalysisWorker` off the realtime thread). It holds
/// the stereo program before the render kernel ("Input") and the kernel output ("Output"), so
/// the overlay needs no new engine tap, allocation or lock. "Output" includes every stage after
/// the EQ (see ledger G15), so the Output minus Input difference is the whole chain, not the EQ alone.
/// E27 S2c: which signal the analyser's second curve shows (design note 16, owner decision of 7 Nov 2026).
enum EQAnalyserMode: String, CaseIterable, Identifiable, Sendable {
    /// The program at the EQ stage output (the default): the EQ's own effect, whatever follows it.
    case eqOnly
    /// The program after the compressor and expander. Room correction, gains and crossovers stay out.
    case eqAndDynamics
    /// The S2b curve: the kernel output of the whole chain.
    case fullChain

    var id: String { rawValue }
    static let `default` = EQAnalyserMode.eqOnly

    var displayName: String {
        switch self {
        case .eqOnly: "EQ only"
        case .eqAndDynamics: "EQ + Dynamics"
        case .fullChain: "Output (full chain)"
        }
    }

    /// Tap demand bits: 1 the EQ tap, 2 the after-dynamics tap.
    var tapDemand: UInt8 {
        switch self {
        case .eqOnly: 1
        case .eqAndDynamics: 2
        case .fullChain: 0
        }
    }
}

/// E27 S2c: the newest samples of an analyser tap.
struct EQAnalyserTapWindow: Sendable {
    var left: [Float]
    var right: [Float]
    var sampleRate: Double
}

struct EQProgramSpectrum: Equatable, Sendable {
    var frequenciesHz: [Double] = []
    var inputDB: [Double] = []
    var outputDB: [Double] = []
    /// What the output curve is (legend text).
    var outputLabel = EQAnalyserMode.fullChain.displayName

    static let none = EQProgramSpectrum()

    var isEmpty: Bool { frequenciesHz.isEmpty }

    /// dBFS shown at the bottom and top of the graph's height.
    static let floorDB = Double(ProductionAnalysisMath.spectrumFloorDB)
    static let ceilingDB = Double(ProductionAnalysisMath.spectrumCeilingDB)

    init() {}

    /// Builds the display curves from the worker's snapshot. Empty when the worker has no spectrum
    /// yet (demand just set, transport stopped, or fewer captured frames than one transform).
    init(snapshot: ProductionAnalysisSnapshot) {
        guard snapshot.sampleRate > 0 else { return }
        for band in snapshot.spectrum where band.frequencyHz.isFinite {
            frequenciesHz.append(band.frequencyHz)
            inputDB.append(Double(band.inputDB))
            outputDB.append(Double(band.outputDB))
        }
    }

    /// 0 at the floor, 1 at the ceiling, clamped. Non-finite values read as the floor.
    static func fraction(forDB db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1)
    }
}

/// What the controller reads from the engine; `AudioIOEngine` conforms, tests inject a fake.
@MainActor
protocol EQProgramAnalysisSource: AnyObject {
    var isAnalysisRunning: Bool { get }
    func setAnalysisDemand(_ demandMask: UInt32)
    func productionAnalysisSnapshot() -> ProductionAnalysisSnapshot
    /// E27 S2c. Installs the analyser taps in stereo graphs (the controller does it once, when available).
    func setAnalyserTapsInstalled(_ installed: Bool)
    func setAnalyserTapDemand(_ mask: UInt8)
    var analyserTapsAvailable: Bool { get }
    func analyserTapWindow(afterDynamics: Bool, frames: Int) -> EQAnalyserTapWindow?
}

extension AudioIOEngine: EQProgramAnalysisSource {
    var isAnalysisRunning: Bool { lifecycleState == .running }
}

/// Owns the analyser switch and the polling loop. It sets a capture demand only while the
/// overlay is switched on and the page is showing, so the realtime bridge copies no frame otherwise.
///
/// The loop runs only while the Equalizer page shows the overlay (`.task(id:)` in the view), at
/// 20 Hz, and releases the demand when it ends. The Meters page sets its own demand while visible;
/// the two pages are never on screen together.
@MainActor
final class EQProgramAnalyserController: ObservableObject {
    static let pollIntervalNanoseconds: UInt64 = 50_000_000

    @Published private(set) var isOn: Bool
    @Published private(set) var mode: EQAnalyserMode
    @Published private(set) var spectrum = EQProgramSpectrum.none

    private let source: EQProgramAnalysisSource
    private let defaults: UserDefaults
    private let tapAnalyzer = ProductionSpectrumAnalyzer()

    init(source: EQProgramAnalysisSource, defaults: UserDefaults = .standard) {
        self.source = source
        self.defaults = defaults
        self.isOn = defaults.bool(forKey: PreferenceKeys.Equalizer.programAnalyser)
        self.mode = defaults.string(forKey: PreferenceKeys.Equalizer.programAnalyserMode)
            .flatMap(EQAnalyserMode.init(rawValue:)) ?? .default
        // Design note 16: stereo graphs carry the (idle) taps from the start, so switching the
        // analyser or its mode never rebuilds the graph.
        source.setAnalyserTapsInstalled(true)
    }

    /// True when the overlay should be capturing: switched on, transport running.
    var isCapturing: Bool { isOn && source.isAnalysisRunning }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: PreferenceKeys.Equalizer.programAnalyser)
        if !on { spectrum = .none }
    }

    func setMode(_ newMode: EQAnalyserMode) {
        guard newMode != mode else { return }
        mode = newMode
        defaults.set(newMode.rawValue, forKey: PreferenceKeys.Equalizer.programAnalyserMode)
    }

    /// Polls until cancelled or switched off. Sets the spectrum demand once, releases it on exit.
    func run() async {
        guard isOn else {
            spectrum = .none
            return
        }
        var holdsDemand = false
        var tapMask: UInt8 = 0
        func setTapMask(_ mask: UInt8) {
            guard mask != tapMask else { return }
            source.setAnalyserTapDemand(mask)
            tapMask = mask
        }
        defer {
            if holdsDemand { source.setAnalysisDemand(UInt32(N60_ANALYSIS_DEMAND_NONE)) }
            setTapMask(0)
            spectrum = .none
        }
        while !Task.isCancelled, isOn {
            if source.isAnalysisRunning {
                if !holdsDemand {
                    source.setAnalysisDemand(UInt32(N60_ANALYSIS_DEMAND_SPECTRUM))
                    holdsDemand = true
                }
                setTapMask(mode.tapDemand)
                poll()
            } else {
                if holdsDemand {
                    source.setAnalysisDemand(UInt32(N60_ANALYSIS_DEMAND_NONE))
                    holdsDemand = false
                }
                setTapMask(0)
                spectrum = .none
            }
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
    }

    /// One read (also called by tests). The input curve always comes from the render capture. The output curve is the
    /// chosen tap; with "Output (full chain)" chosen, or when the core graph is not rendering (so no tap exists), it is
    /// the render capture's kernel output and the legend says so.
    func poll() {
        let snapshot = source.productionAnalysisSnapshot()
        var next = EQProgramSpectrum(snapshot: snapshot)
        if mode != .fullChain, source.analyserTapsAvailable, snapshot.sampleRate > 0,
           let tap = tapSpectrum(snapshot: snapshot, input: next) {
            next = tap
        }
        if next != spectrum { spectrum = next }
    }

    private func tapSpectrum(snapshot: ProductionAnalysisSnapshot, input: EQProgramSpectrum) -> EQProgramSpectrum? {
        let size = ProductionAnalysisMath.fftSize(sampleRate: snapshot.sampleRate)
        guard let window = source.analyserTapWindow(afterDynamics: mode == .eqAndDynamics, frames: size),
              window.left.count >= size, window.right.count >= size,
              window.sampleRate == snapshot.sampleRate else { return nil }
        let bands = tapAnalyzer.analyze(
            inputLeft: window.left, inputRight: window.right, outputLeft: window.left, outputRight: window.right,
            count: size, sampleRate: window.sampleRate)
        guard !bands.isEmpty else { return nil }
        var spectrum = EQProgramSpectrum()
        for band in bands where band.frequencyHz.isFinite {
            spectrum.frequenciesHz.append(band.frequencyHz)
            spectrum.outputDB.append(Double(band.outputDB))
        }
        spectrum.inputDB = input.inputDB.count == spectrum.outputDB.count
            ? input.inputDB : [Double](repeating: EQProgramSpectrum.floorDB, count: spectrum.outputDB.count)
        spectrum.outputLabel = mode.displayName
        return spectrum
    }
}
