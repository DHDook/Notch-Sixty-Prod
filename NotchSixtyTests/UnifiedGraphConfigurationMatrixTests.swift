import XCTest
@testable import NotchSixty

/// E6 S8 closing test: every supported engine configuration (stereo, every program layout,
/// 1 to 8 subs, binaural) and every stored factory profile is published through the Swift
/// translator and host, and the libn60core graph renders it at all eight standard rates.
/// Anything the translator declines is proven to render through the kernel instead.
@MainActor
final class UnifiedGraphConfigurationMatrixTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func tone(_ hz: Double, rate: Double, frames: Int, amplitude: Float = 0.2) -> [Float] {
        (0..<frames).map { Float(Double(amplitude) * sin(2.0 * .pi * hz * Double($0) / rate)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    /// Renders 0.3 s in 512-frame blocks; returns each lane's final-quarter RMS and checks
    /// every sample is finite.
    private func render(
        _ host: UnifiedGraphHost, rate: Double, label: String, hz: Double = 300
    ) throws -> [Double] {
        let block = 512
        let total = Int(rate * 0.3) / block * block
        let input = [[Float]](
            repeating: tone(hz, rate: rate, frames: total), count: Int(host.inputChannels)
        )
        var out = [[Float]](repeating: [], count: Int(host.outputChannels))
        var position = 0
        while position < total {
            let chunk = input.map { Array($0[position..<position + block]) }
            let rendered = try host.processOffline(input: chunk, frames: block)
            for lane in 0..<rendered.count { out[lane] += rendered[lane] }
            position += block
        }
        for (lane, samples) in out.enumerated() {
            XCTAssertTrue(samples.allSatisfy { $0.isFinite }, "\(label) lane \(lane) rate \(rate) non-finite")
        }
        return out.map { rms($0[(out[0].count * 3 / 4)...]) }
    }

    // MARK: Configurations

    func testOneToEightSubsRenderAtEveryRate() throws {
        for rate in Self.rates {
            for subCount in 1...8 {
                let configuration = UnifiedGraphTranslator.multichannelConfiguration(
                    sampleRate: rate, programChannels: 2,
                    subwoofers: (0..<subCount).map { _ in UnifiedGraphSubwoofer() }
                )
                let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
                XCTAssertEqual(host.outputChannels, UInt32(2 + subCount))
                let levels = try render(host, rate: rate, label: "\(subCount) subs", hz: 40)
                XCTAssertGreaterThan(levels[2], 0.001, "subs \(subCount) rate \(rate)")
                XCTAssertGreaterThan(levels[0], 0.0, "program silent, subs \(subCount) rate \(rate)")
            }
        }
    }

    func testStereoWithEveryTranslatedStageRendersAtEveryRate() throws {
        for rate in Self.rates {
            var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
            snapshot.outputGainLinear = 0.7
            let configuration = try XCTUnwrap(
                UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate)
            )
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            let levels = try render(host, rate: rate, label: "stereo")
            XCTAssertEqual(levels.count, 2)
            XCTAssertGreaterThan(levels[0], 0.01)
        }
    }

    func testEveryProgramLayoutWithAndWithoutSubsRendersAtEveryRate() throws {
        for rate in Self.rates {
            for layout in OutputProgramLayout.allCases {
                let roles = layout.roles.count
                for subs in [0, 1, 2, 8] {
                    // Subs need bass management; the LFE role then has no physical lane, but the
                    // plan keeps one physical lane per role, which the translator accepts.
                    let bass = subs > 0
                    let plan = LiveNChannelOutputRoutePlan(
                        programLayout: layout,
                        orderedDeviceUIDs: ["interface"],
                        referenceDeviceUID: "interface",
                        physicalChannelCount: UInt32(roles + subs),
                        programPhysicalChannels: (0..<roles).map { UInt32($0) },
                        subwooferPhysicalChannels: (0..<subs).map { UInt32(roles + $0) },
                        subwooferCount: UInt32(subs),
                        bassManagementEnabled: bass,
                        speakerCalibrations: [:],
                        subwooferCalibrations: [PhysicalSubwooferCalibration?](repeating: nil, count: subs)
                    )
                    var bassConfiguration = BassManagementConfiguration()
                    bassConfiguration.enabled = bass
                    let label = "\(layout.displayName) subs \(subs)"
                    let configuration = try UnifiedGraphTranslator.nChannelEligibility(
                        routePlan: plan, sampleRate: rate, gainConfiguration: DSPGainConfiguration(),
                        bassManagementConfiguration: bassConfiguration
                    ).get()
                    let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
                    let levels = try render(host, rate: rate, label: label)
                    XCTAssertGreaterThan(levels.max() ?? 0, 0.001, "\(label) rate \(rate)")
                }
            }
        }
    }

    func testBinauralLayoutsRenderAtEveryRate() throws {
        for rate in Self.rates {
            for (identifier, channels) in [(UInt32(N60_LAYOUT_5_1.rawValue), 6), (UInt32(N60_LAYOUT_7_1.rawValue), 8)] {
                let taps: UInt32 = 4
                var responses = [Float](repeating: 0, count: channels * 2 * Int(taps))
                for lane in 0..<channels { for ear in 0..<2 { responses[(lane * 2 + ear) * Int(taps)] = 0.4 } }
                let spec = try UnifiedGraphTranslator.layoutSpec(
                    layoutIdentifier: identifier, sampleRate: rate,
                    binaural: UnifiedGraphTranslator.BinauralProfile(
                        taps: taps, equalEarChannel: 3, responses: responses
                    )
                )
                let host = try UnifiedGraphHost(spec: spec)
                XCTAssertGreaterThanOrEqual(host.outputChannels, 2)
                let levels = try render(host, rate: rate, label: "binaural \(channels)")
                XCTAssertGreaterThan(levels[0], 0.001, "binaural \(channels) rate \(rate)")
                XCTAssertGreaterThan(levels[1], 0.001, "binaural \(channels) rate \(rate)")
            }
        }
    }

    // MARK: Stored profiles

    /// Every stored factory content preset on every stored system profile: it either loads and
    /// renders through the graph, or the translator declines and the kernel renders it.
    func testEveryStoredProfileRendersThroughTheGraphOrFallsBackToTheKernel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = ProductProfileController(
            engine: AudioIOEngine(), storageURL: root.appendingPathComponent("profiles.json")
        )
        let presets = profiles.contentPresets
        let systems = profiles.systemProfiles
        XCTAssertFalse(presets.isEmpty)
        XCTAssertFalse(systems.isEmpty)

        var graphRendered = 0
        var kernelRendered = 0
        for preset in presets {
            for system in systems {
                for rate in Self.rates {
                    let label = "\(preset.name) / \(system.name) @ \(rate)"
                    var snapshot = try preset.state.stereoEQ.makeGraphSnapshot(
                        sampleRate: rate,
                        gainConfiguration: system.state.composingGain(over: preset.state.composingGain(over: DSPGainConfiguration())),
                        bassManagementConfiguration: system.state.bassManagement,
                        dynamicsConfiguration: preset.state.dynamics,
                        playbackConfiguration: system.state.playback.applying(to: PlaybackControlConfiguration())
                    )
                    if let configuration = UnifiedGraphTranslator.stereoConfiguration(
                        snapshot: &snapshot, sampleRate: rate
                    ) {
                        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
                        let levels = try render(host, rate: rate, label: label, hz: 1_000)
                        XCTAssertGreaterThan(levels[0], 1e-4, label)
                        XCTAssertGreaterThan(levels[1], 1e-4, label)
                        graphRendered += 1
                    } else {
                        let kernel = try XCTUnwrap(N60RenderKernelCreate(), label)
                        defer { N60RenderKernelDestroy(kernel) }
                        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, snapshot), label)
                        var left: Float = 0, right: Float = 0
                        let input = tone(1_000, rate: rate, frames: Int(rate * 0.1))
                        for sample in input {
                            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
                            XCTAssertTrue(left.isFinite && right.isFinite, label)
                        }
                        kernelRendered += 1
                    }
                }
            }
        }
        XCTAssertEqual(graphRendered + kernelRendered, presets.count * systems.count * Self.rates.count)
    }
}
