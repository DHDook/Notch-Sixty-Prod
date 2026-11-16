import XCTest
@testable import NotchSixty

/// E1 S11 (G6): timed app-level tests with budgets. The E20 bench measures the core; these measure the control plane the
/// user touches: edit-to-publish (an EQ band edit through the engine to the graph the translator publishes), graph
/// publish (stereo start graph through the production translator), profile save and launch services (engine plus profile
/// controller construction). Budgets are the median of several runs and are deliberately loose (about 10x a local M4
/// reading) so a shared runner does not flake while a real regression (an accidental O(n^2) or a blocking call) still fails.
/// Budgets are in `AppPerformanceBudget`. Signposts (`AppSignposts`) mark the same stages for Instruments.
@MainActor
final class AppPerformanceTests: XCTestCase {
    private enum AppPerformanceBudget {
        static let editToPublishSeconds = 0.250
        static let graphPublishSeconds = 0.100
        static let profileSaveSeconds = 0.100
        static let launchServicesSeconds = 1.0
    }

    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func median(runs: Int, _ body: () throws -> Void) rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let clock = ContinuousClock()
            let d = try clock.measure(body)
            samples.append(Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_511, uid: "perf-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "perf-out")
        return engine
    }

    private func publish(_ engine: AudioIOEngine, rate: Double) throws {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        _ = try UnifiedGraphTranslator.stereoEligibility(snapshot: &snapshot, sampleRate: rate).get()
    }

    func testEditToPublishIsWithinBudgetAtEveryRate() throws {
        for rate in rates {
            let engine = try engine(rate: rate)
            var band = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 3, q: 1)
            try engine.addEQBand(band)
            var gain = 0.0
            let t = try median(runs: 5) {
                gain += 0.5
                band.gainDB = 3 + gain
                try engine.updateEQBand(band)
                try publish(engine, rate: rate)
            }
            XCTAssertLessThan(t, AppPerformanceBudget.editToPublishSeconds, "edit-to-publish at \(rate) Hz took \(t) s")
        }
    }

    func testGraphPublishIsWithinBudgetAtEveryRate() throws {
        for rate in rates {
            let engine = try engine(rate: rate)
            let t = try median(runs: 5) { try publish(engine, rate: rate) }
            XCTAssertLessThan(t, AppPerformanceBudget.graphPublishSeconds, "graph publish at \(rate) Hz took \(t) s")
        }
    }

    func testProfileSaveIsWithinBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ProductProfileController(
            engine: AudioIOEngine(), storageURL: root.appendingPathComponent("profiles.json"))
        var n = 0
        let t = median(runs: 5) {
            n += 1
            _ = profiles.saveCurrentSystemProfile(named: "Perf \(n)")
        }
        XCTAssertLessThan(t, AppPerformanceBudget.profileSaveSeconds, "profile save took \(t) s")
    }

    func testLaunchServicesAreWithinBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let t = median(runs: 3) {
            let engine = AudioIOEngine()
            _ = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        }
        XCTAssertLessThan(t, AppPerformanceBudget.launchServicesSeconds, "launch services took \(t) s")
    }
}
