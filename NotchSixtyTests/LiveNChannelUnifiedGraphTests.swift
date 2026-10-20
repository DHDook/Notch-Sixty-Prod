import CoreAudio
import XCTest
@testable import NotchSixty

/// E6 S8b2b: the live N-channel bridge rendered through libn60core must match the legacy
/// per-frame render core (lanes, bass management, 1 to 8 subs) at every standard rate, and
/// anything the core cannot reproduce must stay on the legacy path.
final class LiveNChannelUnifiedGraphTests: XCTestCase {
    private static let standardSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000
    ]
    private static let block = 480
    private static let blocks = 24
    // Canonical 5.1 order: FL FR C LFE SL SR, delivered by the tap in the same order.
    private static let streamLabels: [AudioChannelLabel] = [
        kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
        kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
    ]

    private func plan(
        subs: Int,
        bass: Bool,
        speakers: [OutputProgramRole: SemanticSpeakerCalibration] = [:],
        subCalibrations: [PhysicalSubwooferCalibration?] = []
    ) -> LiveNChannelOutputRoutePlan {
        LiveNChannelOutputRoutePlan(
            programLayout: .fiveOne,
            orderedDeviceUIDs: ["interface"],
            referenceDeviceUID: "interface",
            physicalChannelCount: UInt32(6 + subs),
            programPhysicalChannels: [5, 4, 3, 2, 1, 0],
            subwooferPhysicalChannels: (0..<subs).map { UInt32(6 + $0) },
            subwooferCount: UInt32(subs),
            bassManagementEnabled: bass,
            speakerCalibrations: speakers,
            subwooferCalibrations: subCalibrations.isEmpty
                ? [PhysicalSubwooferCalibration?](repeating: nil, count: subs) : subCalibrations
        )
    }

    private func bridge(
        plan: LiveNChannelOutputRoutePlan,
        sampleRate: Double,
        bassConfiguration: BassManagementConfiguration,
        useGraph: Bool,
        host: inout UnifiedGraphHost?
    ) throws -> UnsafeMutablePointer<N60LiveNChannelBridge> {
        let graph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: plan, sampleRate: sampleRate, gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: bassConfiguration
        )
        let descriptions = Self.streamLabels.map {
            AudioChannelDescription(mChannelLabel: $0, mChannelFlags: [], mCoordinates: (0, 0, 0))
        }
        var inputMap = N60ProgramInputMap()
        XCTAssertTrue(descriptions.withUnsafeBufferPointer {
            N60ProgramInputMapCompile($0.baseAddress!, UInt32($0.count), graph.programLayout, &inputMap)
        })
        let created = try XCTUnwrap(N60LiveNChannelBridgeCreate(16_384, inputMap, graph, 0, 1))
        if useGraph {
            var configuration = try XCTUnwrap(UnifiedGraphTranslator.nChannelConfiguration(
                routePlan: plan, sampleRate: sampleRate, gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: bassConfiguration
            ))
            configuration.maxBlockFrames = 4_096
            let newHost = try UnifiedGraphHost(spec: try configuration.makeSpec())
            let raw = try XCTUnwrap(newHost.rawGraph)
            XCTAssertTrue(N60LiveNChannelBridgeAttachGraph(
                created, raw,
                UInt32(configuration.channelCount), configuration.maxBlockFrames
            ))
            host = newHost
        }
        return created
    }

    private func sample(_ channel: Int, _ index: Int, _ sampleRate: Double) -> Float {
        // A different mix of a bass tone (inside the crossover) and a mid tone per channel.
        let t = Double(index) / sampleRate
        let bass = sin(2 * .pi * (45 + 7 * Double(channel)) * t)
        let mid = sin(2 * .pi * (700 + 130 * Double(channel)) * t)
        return Float(0.08 * bass + 0.06 * mid)
    }

    private func run(
        _ bridge: UnsafeMutablePointer<N60LiveNChannelBridge>, sampleRate: Double, physical: Int
    ) -> [[Float]] {
        var output = [[Float]](repeating: [], count: physical)
        var position = 0
        for _ in 0..<Self.blocks {
            var input = [Float](repeating: 0, count: Self.block * 6)
            for frame in 0..<Self.block {
                for channel in 0..<6 { input[frame * 6 + channel] = sample(channel, position + frame, sampleRate) }
            }
            position += Self.block
            var timestamp = AudioTimeStamp()
            input.withUnsafeMutableBufferPointer { buffer in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 6,
                        mDataByteSize: UInt32(buffer.count * 4),
                        mData: UnsafeMutableRawPointer(buffer.baseAddress)
                    )
                )
                var unused = AudioBufferList()
                _ = N60LiveNChannelCaptureIOProc(
                    0, &timestamp, &list, &timestamp, &unused, &timestamp, UnsafeMutableRawPointer(bridge))
            }
            var rendered = [Float](repeating: 0, count: Self.block * physical)
            rendered.withUnsafeMutableBufferPointer { buffer in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(physical),
                        mDataByteSize: UInt32(buffer.count * 4),
                        mData: UnsafeMutableRawPointer(buffer.baseAddress)
                    )
                )
                var unused = AudioBufferList()
                _ = N60LiveNChannelOutputIOProc(
                    0, &timestamp, &unused, &timestamp, &list, &timestamp, UnsafeMutableRawPointer(bridge))
            }
            for frame in 0..<Self.block {
                for channel in 0..<physical { output[channel].append(rendered[frame * physical + channel]) }
            }
        }
        return output
    }

    /// Asserts the graph render matches the legacy render to better than -70 dB of each
    /// channel's level (the 1-frame startup fade excluded), and that the channel is not silent.
    private func assertParity(
        plan: LiveNChannelOutputRoutePlan, bass: BassManagementConfiguration, label: String
    ) throws {
        for sampleRate in Self.standardSampleRates {
            var legacyHost: UnifiedGraphHost?
            var graphHost: UnifiedGraphHost?
            let legacy = try bridge(plan: plan, sampleRate: sampleRate, bassConfiguration: bass,
                                    useGraph: false, host: &legacyHost)
            let graph = try bridge(plan: plan, sampleRate: sampleRate, bassConfiguration: bass,
                                   useGraph: true, host: &graphHost)
            defer {
                N60LiveNChannelBridgeDestroy(legacy)
                N60LiveNChannelBridgeDestroy(graph)
                withExtendedLifetime(graphHost) {}
            }
            let physical = Int(plan.physicalChannelCount)
            let expected = run(legacy, sampleRate: sampleRate, physical: physical)
            let actual = run(graph, sampleRate: sampleRate, physical: physical)
            for channel in 0..<physical {
                var error = 0.0, energy = 0.0
                for index in 8..<expected[channel].count {
                    let e = Double(expected[channel][index]), a = Double(actual[channel][index])
                    error += (a - e) * (a - e)
                    energy += e * e
                }
                XCTAssertGreaterThan(energy, 0, "\(label) \(sampleRate) Hz channel \(channel) is silent")
                XCTAssertLessThan(
                    error, energy * 1.0e-7,
                    "\(label) \(sampleRate) Hz channel \(channel): error \(error) vs energy \(energy)")
            }
            let snapshot = N60LiveNChannelBridgeGetSnapshot(graph)
            XCTAssertEqual(snapshot.renderFailures, 0, "\(label) \(sampleRate) Hz")
            XCTAssertEqual(snapshot.outputWriteFailures, 0, "\(label) \(sampleRate) Hz")
        }
    }

    func testLanesWithoutBassManagementMatchLegacyAtEveryRate() throws {
        let speakers: [OutputProgramRole: SemanticSpeakerCalibration] = [
            .frontLeft: SemanticSpeakerCalibration(
                trimDB: -3, eqBands: [OutputCalibrationEQBand(frequencyHz: 700, gainDB: -4, q: 2)]),
            .frontRight: SemanticSpeakerCalibration(trimDB: -1.5, delayMilliseconds: 2),
            .frontCenter: SemanticSpeakerCalibration(trimDB: -6),
        ]
        try assertParity(
            plan: plan(subs: 0, bass: false, speakers: speakers),
            bass: BassManagementConfiguration(enabled: false), label: "no bass")
    }

    func testBassManagementWithOneAndTwoSubsMatchesLegacyAtEveryRate() throws {
        let speakers: [OutputProgramRole: SemanticSpeakerCalibration] = [
            .frontLeft: SemanticSpeakerCalibration(trimDB: -2),
            .sideLeft: SemanticSpeakerCalibration(
                trimDB: -1, eqBands: [OutputCalibrationEQBand(frequencyHz: 1_200, gainDB: -3, q: 1.5)]),
        ]
        let subOne = PhysicalSubwooferCalibration(gainDB: -2)
        let subTwo = PhysicalSubwooferCalibration(
            gainDB: -1, polarityInverted: true,
            eqBands: [OutputCalibrationEQBand(frequencyHz: 60, gainDB: -3, q: 1.2)])
        var bass = BassManagementConfiguration(enabled: true)
        bass.frequencyHz = 80
        try assertParity(
            plan: plan(subs: 1, bass: true, speakers: speakers, subCalibrations: [subOne]),
            bass: bass, label: "1 sub")
        try assertParity(
            plan: plan(subs: 2, bass: true, speakers: speakers, subCalibrations: [subOne, subTwo]),
            bass: bass, label: "2 subs")
    }

    func testIneligibleSetupsStayOnTheLegacyRenderCore() {
        let gain = DSPGainConfiguration()
        let off = BassManagementConfiguration(enabled: false)
        var bass = BassManagementConfiguration(enabled: true)
        func configuration(_ plan: LiveNChannelOutputRoutePlan, _ bass: BassManagementConfiguration)
            -> UnifiedGraphConfiguration? {
            UnifiedGraphTranslator.nChannelConfiguration(
                routePlan: plan, sampleRate: 48_000, gainConfiguration: gain, bassManagementConfiguration: bass)
        }
        XCTAssertNotNil(configuration(plan(subs: 0, bass: false), off))
        XCTAssertNotNil(configuration(plan(subs: 2, bass: true), bass))

        // Polarity-inverted lane: the core's lane gain is positive only.
        XCTAssertNil(configuration(
            plan(subs: 0, bass: false, speakers: [.frontLeft: SemanticSpeakerCalibration(polarityInverted: true)]),
            off))
        // Lane delay under bass management: the legacy order is delay before the crossover.
        XCTAssertNil(configuration(
            plan(subs: 1, bass: true, speakers: [.frontLeft: SemanticSpeakerCalibration(delayMilliseconds: 3)]),
            bass))
        // Bass management without a sub, and a 48 dB crossover, are legacy-only.
        XCTAssertNil(configuration(plan(subs: 0, bass: true), bass))
        bass.topology = .linkwitzRiley48
        XCTAssertNil(configuration(plan(subs: 1, bass: true), bass))
    }

    func testBridgeReportsGraphLatencyAndProgramMeters() throws {
        let sampleRate = 48_000.0
        let subTwo = PhysicalSubwooferCalibration(delayMilliseconds: 5)
        var bass = BassManagementConfiguration(enabled: true)
        bass.frequencyHz = 80
        let p = plan(subs: 2, bass: true, subCalibrations: [nil, subTwo])
        var host: UnifiedGraphHost?
        let live = try bridge(plan: p, sampleRate: sampleRate, bassConfiguration: bass, useGraph: true, host: &host)
        defer { N60LiveNChannelBridgeDestroy(live) }
        N60LiveNChannelBridgeSetMeteringDemand(live, true)
        _ = run(live, sampleRate: sampleRate, physical: 8)
        let snapshot = N60LiveNChannelBridgeGetSnapshot(live)
        XCTAssertEqual(snapshot.algorithmicLatencyFrames, UInt64(host?.latencyFrames ?? 0))
        XCTAssertGreaterThanOrEqual(snapshot.algorithmicLatencyFrames, 240, "5 ms sub delay at 48 kHz")
        var meter = snapshot.meter
        XCTAssertTrue(meter.enabled)
        XCTAssertGreaterThan(N60LiveNChannelMeterProgramPeak(&meter, 0), 0)
        XCTAssertGreaterThan(N60LiveNChannelMeterProgramRMS(&meter, 0), 0)
        XCTAssertGreaterThan(N60LiveNChannelMeterPhysicalPeak(&meter, 6), 0)
        let diagnostics = UnifiedGraphDiagnostics(host: host, programChannelCount: 6)
        XCTAssertEqual(diagnostics?.channelCount, 8)
        XCTAssertEqual(diagnostics?.finalMeters.count, 8)
    }
}
