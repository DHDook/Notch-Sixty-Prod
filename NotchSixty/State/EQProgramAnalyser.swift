import Foundation

/// E27 S2b: the program spectrum behind the Equalizer graph.
///
/// Source of truth (design note 15): the existing render capture (`analysisFrames` in the realtime
/// bridge, drained and transformed by `ProductionAnalysisWorker` off the realtime thread). It holds
/// the stereo program before the render kernel ("Input") and the kernel output ("Output"), so
/// the overlay needs no new engine tap, allocation or lock. "Output" includes every stage after
/// the EQ (see ledger G15), so the Output minus Input difference is the whole chain, not the EQ alone.
struct EQProgramSpectrum: Equatable, Sendable {
    var frequenciesHz: [Double] = []
    var inputDB: [Double] = []
    var outputDB: [Double] = []

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
}

extension AudioIOEngine: EQProgramAnalysisSource {
    var isAnalysisRunning: Bool { lifecycleState == .running }
}

/// Owns the analyser switch and the polling loop. Inert unless `isAvailable` (the
/// `e27.eq-safety` flag, decided by Swift at launch): with the flag off it never sets a capture
/// demand, so the realtime bridge never copies a frame for the Equalizer page.
///
/// The loop runs only while the Equalizer page shows the overlay (`.task(id:)` in the view), at
/// 20 Hz, and releases the demand when it ends. The Meters page sets its own demand while visible;
/// the two pages are never on screen together.
@MainActor
final class EQProgramAnalyserController: ObservableObject {
    static let pollIntervalNanoseconds: UInt64 = 50_000_000

    @Published private(set) var isOn: Bool
    @Published private(set) var spectrum = EQProgramSpectrum.none

    let isAvailable: Bool
    private let source: EQProgramAnalysisSource
    private let defaults: UserDefaults

    init(source: EQProgramAnalysisSource, isAvailable: Bool, defaults: UserDefaults = .standard) {
        self.source = source
        self.isAvailable = isAvailable
        self.defaults = defaults
        self.isOn = isAvailable && defaults.bool(forKey: PreferenceKeys.Equalizer.programAnalyser)
    }

    /// True when the overlay should be capturing: available, switched on, transport running.
    var isCapturing: Bool { isAvailable && isOn && source.isAnalysisRunning }

    func setOn(_ on: Bool) {
        guard isAvailable, on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: PreferenceKeys.Equalizer.programAnalyser)
        if !on { spectrum = .none }
    }

    /// Polls until cancelled or switched off. Sets the spectrum demand once, releases it on exit.
    func run() async {
        guard isAvailable, isOn else {
            spectrum = .none
            return
        }
        var holdsDemand = false
        defer {
            if holdsDemand { source.setAnalysisDemand(UInt32(N60_ANALYSIS_DEMAND_NONE)) }
            spectrum = .none
        }
        while !Task.isCancelled, isOn {
            if source.isAnalysisRunning {
                if !holdsDemand {
                    source.setAnalysisDemand(UInt32(N60_ANALYSIS_DEMAND_SPECTRUM))
                    holdsDemand = true
                }
                poll()
            } else {
                if holdsDemand {
                    source.setAnalysisDemand(UInt32(N60_ANALYSIS_DEMAND_NONE))
                    holdsDemand = false
                }
                spectrum = .none
            }
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
    }

    /// One read of the worker's latest snapshot (also called by tests).
    func poll() {
        let next = EQProgramSpectrum(snapshot: source.productionAnalysisSnapshot())
        if next != spectrum { spectrum = next }
    }
}
