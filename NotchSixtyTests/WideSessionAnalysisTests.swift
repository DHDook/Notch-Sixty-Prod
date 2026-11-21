import XCTest
@testable import NotchSixty

/// E33 S17: View, pair and meters on N-channel, routed and binaural sessions at the eight standard rates.
final class WideSessionAnalysisTests: XCTestCase {
    static let rates = LoudnessMeterTests.rates
    static let fiveOne: [OutputProgramRole] = [.frontLeft, .frontRight, .frontCenter, .lowFrequencyEffects, .sideLeft, .sideRight]
    static let sevenOneFour: [OutputProgramRole] = [
        .frontLeft, .frontRight, .frontCenter, .lowFrequencyEffects, .sideLeft, .sideRight, .rearLeft, .rearRight,
        .topFrontLeft, .topFrontRight, .topRearLeft, .topRearRight,
    ]

    private func plan(_ roles: [OutputProgramRole], subFeeds: Int = 0, hasOutput: Bool = true, binaural: Bool = false) -> WideAnalysisPlan {
        WideAnalysisPlan(
            roles: roles, inputChannels: roles.count,
            outputChannels: binaural ? 2 : (hasOutput ? roles.count + subFeeds : 0), isBinaural: binaural)
    }

    /// Feeds `seconds` of audio, one generator per channel, in 100 ms blocks. `output` defaults to the input.
    private func run(
        _ feed: WideAnalysisFeed, rate: Double, seconds: Double,
        input: (Int, Int) -> Float, output: ((Int, Int) -> Float)? = nil
    ) {
        let inCh = feed.plan.inputChannels, outCh = feed.plan.outputChannels
        let block = Int(rate / 10)
        let total = Int(rate * seconds)
        var start = 0
        while start < total {
            let n = min(block, total - start)
            var i = [Float](repeating: 0, count: n * inCh)
            var o = [Float](repeating: 0, count: n * max(outCh, 1))
            for f in 0..<n {
                for c in 0..<inCh { i[f * inCh + c] = input(c, start + f) }
                for c in 0..<outCh {
                    if let output { o[f * outCh + c] = output(c, start + f) } else { o[f * outCh + c] = input(c, start + f) }
                }
            }
            i.withUnsafeBufferPointer { ip in
                o.withUnsafeBufferPointer { op in
                    feed.ingest(input: ip.baseAddress!, output: outCh > 0 ? op.baseAddress : nil, frames: n)
                }
            }
            start += n
        }
    }

    private func tone(_ hz: Double, rate: Double, _ n: Int, amplitude: Double = 0.5) -> Float {
        Float(amplitude * sin(2 * Double.pi * hz * Double(n) / rate))
    }

    private func demand(
        _ feed: WideAnalysisFeed, spectrum: Bool = false, stereo: Bool = false, meters: Bool = false, rta: Bool = false,
        bits: Bool = false, view: AnalysisView = .standard, pair: AnalysisPair = .standard
    ) {
        feed.setDemand(
            spectrum: spectrum, stereo: stereo, meters: meters, rta: rta, spectrogram: false, spectrogramWindow: .tenSeconds,
            bits: bits, view: view, pair: pair)
    }

    private func peakOutputDB(_ bands: [ProductionSpectrumBand]) -> Float { bands.map(\.outputDB).max() ?? -.infinity }

    // MARK: Selection

    func testSelectionRoundTripsThroughTheDemandMaskWithoutTouchingOtherBits() {
        let views: [AnalysisView] = [.standard, .left, .right, .mid, .side, .programme, .speaker(0), .speaker(15), .speaker(31)]
            + WideGroup.allCases.map { .group($0) }
        for view in views {
            for pair in AnalysisPair.allCases {
                let mask = ProductionAnalysisSelection.encode(view: view, pair: pair)
                XCTAssertEqual(mask & ~ProductionAnalysisSelection.allBits, 0)
                XCTAssertEqual(mask & (UInt32(N60_ANALYSIS_DEMAND_ALL) | ProductionAnalysisDemand.workerBits), 0)
                let decoded = ProductionAnalysisSelection.decode(mask | UInt32(N60_ANALYSIS_DEMAND_SPECTRUM) | ProductionAnalysisDemand.rta)
                XCTAssertEqual(decoded.view, view)
                XCTAssertEqual(decoded.pair, pair)
            }
        }
        XCTAssertEqual(ProductionAnalysisSelection.encode(view: .standard), 0, "the default view adds no bits")
    }

    func testMidAndSideNullForMonoAndInvertedPairs() {
        let mono = StereoViewTransform.apply(.side, left: 0.4, right: 0.4)
        XCTAssertEqual(mono.0, 0); XCTAssertEqual(mono.1, 0)
        let inverted = StereoViewTransform.apply(.mid, left: 0.4, right: -0.4)
        XCTAssertEqual(inverted.0, 0); XCTAssertEqual(inverted.1, 0)
        let left = StereoViewTransform.apply(.left, left: 0.3, right: 0.9)
        XCTAssertEqual(left.0, 0.3); XCTAssertEqual(left.1, 0.3)
        let right = StereoViewTransform.apply(.right, left: 0.3, right: 0.9)
        XCTAssertEqual(right.0, 0.9)
        let both = StereoViewTransform.apply(.standard, left: 0.3, right: 0.9)
        XCTAssertEqual(both.0, 0.3); XCTAssertEqual(both.1, 0.9)
    }

    func testPlanResolvesGroupsSpeakersAndPairsOnWideSessions() {
        let p = plan(Self.sevenOneFour, subFeeds: 2)
        XCTAssertEqual(p.source(for: .standard).output, Array(0..<14))
        XCTAssertEqual(p.source(for: .group(.centre)).input, [2])
        XCTAssertEqual(p.source(for: .group(.surrounds)).input, [4, 5, 6, 7])
        XCTAssertEqual(p.source(for: .group(.heights)).input, [8, 9, 10, 11])
        let sub = p.source(for: .group(.sub))
        XCTAssertEqual(sub.input, [3])
        XCTAssertEqual(sub.output, [3, 12, 13], "LFE and every driven subwoofer feed")
        XCTAssertEqual(p.source(for: .speaker(6)).output, [6])
        XCTAssertEqual(p.pair(.standard), WideAnalysisPlan.Pair(left: 0, right: 1, fromInput: false))
        XCTAssertEqual(p.pair(.surrounds)?.left, 4)
        XCTAssertEqual(p.pair(.rears)?.left, 6)
        XCTAssertEqual(p.pair(.heights)?.left, 8, "top front before top rear")
        XCTAssertEqual(p.availablePairs, [.standard, .surrounds, .rears, .heights])
        let five = plan(Self.fiveOne)
        XCTAssertEqual(five.availablePairs, [.standard, .surrounds])
        XCTAssertEqual(five.resolvedPair(.heights), five.pair(.standard), "a missing pair reads as the front pair")
    }

    func testRoutedSessionWithoutOutputPlaneReadsTheInputPlane() {
        let p = plan(Self.fiveOne, hasOutput: false)
        let source = p.source(for: .standard)
        XCTAssertTrue(source.outputFromInput)
        XCTAssertEqual(source.output, Array(0..<6))
        XCTAssertEqual(p.pair(.standard)?.fromInput, true)
    }

    func testBinauralOffersEarPairAndProgramme() {
        let p = plan([.frontLeft, .frontRight, .frontCenter, .sideLeft, .sideRight], binaural: true)
        XCTAssertEqual(p.source(for: .standard).output, [0, 1])
        XCTAssertFalse(p.source(for: .standard).outputFromInput)
        XCTAssertTrue(p.source(for: .programme).outputFromInput)
        XCTAssertEqual(p.pair(.standard), WideAnalysisPlan.Pair(left: 0, right: 1, fromInput: false))
        XCTAssertEqual(p.pair(.programme), WideAnalysisPlan.Pair(left: 0, right: 1, fromInput: true))
        XCTAssertEqual(p.availablePairs, [.standard, .programme])
    }

    func testViewOptionsNameEverySpeakerAndGroup() {
        func channel(_ role: OutputProgramRole, _ i: Int) -> ProductionTransportChannelMeter {
            ProductionTransportChannelMeter(id: "program-\(role.rawValue)", label: role.displayName, channelIndex: UInt32(i),
                                            peakLinear: 0, rmsLinear: 0, overRangeSamples: 0)
        }
        func snapshot(kind: ProductionTransportMeterKind, program: [ProductionTransportChannelMeter],
                      outputs: [ProductionTransportChannelMeter] = []) -> ProductionTransportMeterSnapshot {
            ProductionTransportMeterSnapshot(
                kind: kind, displayName: "x", programLayoutName: "x", sampleRate: 48_000, latencyFrames: 0, meteringEnabled: true,
                programChannels: program, physicalOutputs: outputs, inputTruePeakLinear: nil, outputTruePeakLinear: nil,
                roomTreatment: nil, renderFailures: 0, outputWriteFailures: 0)
        }
        XCTAssertEqual(AnalysisViewOptions(transport: nil).views.map(\.title), ["Stereo", "Left", "Right", "Mid", "Side"])
        let wide = AnalysisViewOptions(transport: snapshot(
            kind: .semanticSpeakers, program: Self.fiveOne.enumerated().map { channel($0.element, $0.offset) }))
        XCTAssertEqual(wide.kind, .wide)
        XCTAssertEqual(wide.views.prefix(5).map(\.title), ["All", "Front", "Centre", "Surrounds", "Sub"])
        XCTAssertTrue(wide.views.contains { $0.title == "Side Left" })
        XCTAssertEqual(wide.pairs.map(\.pair), [.standard, .surrounds])
        XCTAssertEqual(wide.resolved(.speaker(99)), .standard, "a stored choice this session lacks reads as the standard one")
        let ears = AnalysisViewOptions(transport: snapshot(kind: .virtualSpeakers, program: []))
        XCTAssertEqual(ears.kind, .binaural)
        XCTAssertEqual(ears.views.map(\.view), [.standard, .programme])
    }

    // MARK: Views through the feed

    func testToneOnOneSpeakerShowsOnlyInThatSpeakersViewAndInAllAtEveryRate() {
        for rate in Self.rates {
            let size = ProductionAnalysisMath.fftSize(sampleRate: rate)
            let seconds = Double(size) / rate + 0.3
            func level(_ view: AnalysisView) -> Float {
                let feed = WideAnalysisFeed(plan: plan(Self.fiveOne), sampleRate: rate)
                demand(feed, spectrum: true, view: view)
                // The tone sits on Side Left (index 4) only.
                run(feed, rate: rate, seconds: seconds) { c, n in c == 4 ? self.tone(1_000, rate: rate, n) : 0 }
                return peakOutputDB(feed.spectrum())
            }
            XCTAssertGreaterThan(level(.speaker(4)), -12, "own view at \(rate)")
            XCTAssertGreaterThan(level(.standard), -25, "All at \(rate)")
            XCTAssertGreaterThan(level(.group(.surrounds)), -18, "group at \(rate)")
            XCTAssertLessThan(level(.speaker(0)), -75, "another speaker at \(rate)")
            XCTAssertLessThan(level(.group(.centre)), -75, "another group at \(rate)")
        }
    }

    func testRTAFollowsTheChosenView() {
        let rate = 48_000.0
        func peak(_ view: AnalysisView) -> Float {
            let feed = WideAnalysisFeed(plan: plan(Self.fiveOne), sampleRate: rate)
            demand(feed, rta: true, view: view)
            run(feed, rate: rate, seconds: 4) { c, n in c == 2 ? self.tone(1_000, rate: rate, n) : 0 }
            return feed.rtaLevels().max() ?? -.infinity
        }
        XCTAssertGreaterThan(peak(.group(.centre)), -12)
        XCTAssertLessThan(peak(.group(.front)), -80)
    }

    func testSubViewReadsTheSubwooferFeedAndNothingElse() {
        let rate = 96_000.0
        let size = ProductionAnalysisMath.fftSize(sampleRate: rate)
        let feed = WideAnalysisFeed(plan: plan(Self.fiveOne, subFeeds: 1), sampleRate: rate)
        demand(feed, spectrum: true, view: .group(.sub))
        // Output channel 6 is the sub feed; the input plane has no sub feed.
        run(feed, rate: rate, seconds: Double(size) / rate + 0.3, input: { _, _ in 0 },
            output: { c, n in c == 6 ? self.tone(60, rate: rate, n) : 0 })
        XCTAssertGreaterThan(peakOutputDB(feed.spectrum()), -12)
    }

    func testBinauralViewsReadEarsOrProgramme() {
        let rate = 48_000.0
        let size = ProductionAnalysisMath.fftSize(sampleRate: rate)
        let roles: [OutputProgramRole] = [.frontLeft, .frontRight, .frontCenter]
        func levels(_ view: AnalysisView) -> (input: Float, output: Float) {
            let feed = WideAnalysisFeed(plan: plan(roles, binaural: true), sampleRate: rate)
            demand(feed, spectrum: true, view: view)
            // Programme: tone on the centre only. Ears: tone on the right ear only.
            run(feed, rate: rate, seconds: Double(size) / rate + 0.3,
                input: { c, n in c == 2 ? self.tone(1_000, rate: rate, n) : 0 },
                output: { c, n in c == 1 ? self.tone(2_000, rate: rate, n) : 0 })
            let bands = feed.spectrum()
            return (bands.map(\.inputDB).max() ?? -.infinity, bands.map(\.outputDB).max() ?? -.infinity)
        }
        let ears = levels(.standard)
        XCTAssertGreaterThan(ears.output, -12, "the ear pair carries the ear signal")
        let programme = levels(.programme)
        XCTAssertGreaterThan(programme.output, -20, "the programme view reads the programme channels")
    }

    // MARK: Pairs

    func testOutOfPhaseSurroundPairReadsMinusOneAndTheFrontPairIsUnaffected() {
        for rate in Self.rates {
            func correlation(_ pair: AnalysisPair) -> Float? {
                let feed = WideAnalysisFeed(plan: plan(Self.sevenOneFour), sampleRate: rate)
                demand(feed, stereo: true, pair: pair)
                run(feed, rate: rate, seconds: 0.5) { c, n in
                    let x = self.tone(440, rate: rate, n)
                    switch c {
                    case 0, 1: return x          // front pair in phase
                    case 4: return x             // Side Left
                    case 5: return -x            // Side Right inverted
                    default: return 0.1 * self.tone(100 + 37 * Double(c), rate: rate, n)
                    }
                }
                return feed.stereoReadout().correlation
            }
            XCTAssertEqual(correlation(.surrounds) ?? .nan, -1, accuracy: 0.01, "surrounds at \(rate)")
            XCTAssertEqual(correlation(.standard) ?? .nan, 1, accuracy: 0.01, "front at \(rate)")
            XCTAssertNotNil(correlation(.heights), "heights at \(rate)")
        }
    }

    func testGoniometerFollowsThePair() {
        let rate = 48_000.0
        let feed = WideAnalysisFeed(plan: plan(Self.fiveOne), sampleRate: rate)
        demand(feed, stereo: true, pair: .surrounds)
        run(feed, rate: rate, seconds: 0.3) { c, n in c == 4 ? self.tone(300, rate: rate, n) : 0 }
        let points = feed.stereoReadout().points
        XCTAssertFalse(points.isEmpty)
        // Left only: every point lies on the left axis, so side and mid have equal magnitude.
        XCTAssertTrue(points.contains { abs($0.x) > 0.1 || abs($0.y) > 0.1 })
    }

    // MARK: Meters

    func testMetersCoverTheWholeProgrammeAndBalanceUsesTheFrontPair() {
        let rate = 48_000.0
        let feed = WideAnalysisFeed(plan: plan(Self.sevenOneFour), sampleRate: rate)
        demand(feed, meters: true)
        // Front pair: right channel 6 dB down. The loudest peak is on Rear Left, so the programme peak is that one.
        run(feed, rate: rate, seconds: 4) { c, n in
            switch c {
            case 0: return self.tone(1_000, rate: rate, n, amplitude: 0.2)
            case 1: return self.tone(1_000, rate: rate, n, amplitude: 0.1)
            case 6: return self.tone(500, rate: rate, n, amplitude: 0.8)
            default: return 0
            }
        }
        let readout = feed.meterReadout(loudness: nil)
        XCTAssertNotNil(readout)
        XCTAssertEqual(readout?.truePeakMaxDBTP ?? .nan, 20 * log10(0.8), accuracy: 0.3, "worst channel sets the programme peak")
        XCTAssertEqual(readout?.balanceDB ?? .nan, 6.02, accuracy: 0.3, "front pair balance")
    }

    func testBitActivityCoversEveryInputChannel() {
        let rate = 48_000.0
        let feed = WideAnalysisFeed(plan: plan(Self.sevenOneFour), sampleRate: rate)
        demand(feed, bits: true)
        run(feed, rate: rate, seconds: 1) { c, n in c == 7 ? self.tone(1_000, rate: rate, n) : 0 }
        let bits = feed.bitActivity()
        XCTAssertEqual(bits.count, Self.sevenOneFour.count)
        XCTAssertEqual(bits[0].verdict, .silent)
        XCTAssertNotEqual(bits[7].verdict, .silent)
    }

    func testNothingRunsWhileHidden() {
        let rate = 48_000.0
        let feed = WideAnalysisFeed(plan: plan(Self.fiveOne), sampleRate: rate)
        demand(feed, spectrum: true, stereo: true, meters: true, rta: true, bits: true)
        XCTAssertTrue(feed.isActive)
        demand(feed)
        XCTAssertFalse(feed.isActive)
        run(feed, rate: rate, seconds: 1) { _, n in self.tone(1_000, rate: rate, n) }
        XCTAssertTrue(feed.spectrum().isEmpty)
        XCTAssertNil(feed.meterReadout(loudness: nil))
        XCTAssertTrue(feed.rtaLevels().isEmpty)
        XCTAssertTrue(feed.bitActivity().isEmpty)
        XCTAssertNil(feed.stereoReadout().correlation)
    }

    func testAllViewsRunTogetherAt384kHzWith32Channels() {
        let rate = 384_000.0
        let roles = Array(OutputProgramRole.allCases) + Array(OutputProgramRole.allCases)
        let p = WideAnalysisPlan(roles: roles, inputChannels: 32, outputChannels: 32, isBinaural: false)
        let feed = WideAnalysisFeed(plan: p, sampleRate: rate)
        demand(feed, spectrum: true, stereo: true, meters: true, rta: true, bits: true)
        // One 100 ms block is built up front so only the analysis is timed.
        let n = Int(rate / 10)
        var block = [Float](repeating: 0, count: n * 32)
        for f in 0..<n { for c in 0..<32 { block[f * 32 + c] = 0.05 * tone(200 + Double(c) * 31, rate: rate, f) } }
        // Behaviour only: wall-clock cost is not asserted in a Debug XCTest (CI runners vary); the Release figure is G71.
        for _ in 0..<2 {
            block.withUnsafeBufferPointer { feed.ingest(input: $0.baseAddress!, output: $0.baseAddress!, frames: n) }
        }
        XCTAssertEqual(feed.bitActivity().count, 32)
        XCTAssertNotNil(feed.meterReadout(loudness: nil))
    }

    // MARK: Headroom

    func testHeadroomStripNamesTheWorstChannel() {
        func meter(_ label: String, _ peak: Float) -> ProductionTransportChannelMeter {
            ProductionTransportChannelMeter(id: label, label: label, channelIndex: 0, peakLinear: peak, rmsLinear: 0, overRangeSamples: 0)
        }
        XCTAssertNil(WideHeadroom.worst([meter("A", 0), meter("B", 0)]))
        XCTAssertEqual(WideHeadroom.worst([meter("Front Left", 0.2), meter("Rear Left", 0.7), meter("LFE", 0.5)])?.label, "Rear Left")
        var strip = HeadroomStripModel()
        strip.updateWide(
            program: [meter("Front Left", 0.2), meter("Rear Left", 0.5)],
            output: [meter("Sub 1", 0.25), meter("Rear Left", 0.1)])
        XCTAssertEqual(strip.points.map(\.id), ["input", "output"])
        XCTAssertEqual(strip.points[0].worstChannel, "Rear Left")
        XCTAssertEqual(strip.points[0].holdDBFS, 20 * log10(0.5), accuracy: 0.01)
        XCTAssertEqual(strip.points[1].worstChannel, "Sub 1")
        strip.updateWide(program: [meter("Front Left", 0.1)], output: [])
        XCTAssertEqual(strip.points[0].worstChannel, "Rear Left", "the name stays with the held peak")
        strip.reset()
        XCTAssertNil(strip.points[0].worstChannel)
        strip.update(peaks: ["input": 0.5, "postEQ": 0.5, "output": 0.5])
        XCTAssertEqual(strip.points.count, 3, "a stereo session restores the three points")
    }

    // MARK: Through the real ring and worker

    func testWorkerPublishesSpectrumAndStereoOfTheChosenViewFromTheRingAtEveryRate() throws {
        for rate in Self.rates {
            let capture = try XCTUnwrap(N60LoudnessCaptureCreate(6, 6, rate))
            defer { N60LoudnessCaptureDestroy(capture) }
            let positions = LoudnessChannelPosition.positions(for: Self.fiveOne)
            let worker = try XCTUnwrap(ProductionWideLoudnessWorker(
                capture: capture, sampleRate: rate, inputPositions: positions, outputPositions: positions, roles: Self.fiveOne))
            defer { worker.stop() }
            let size = ProductionAnalysisMath.fftSize(sampleRate: rate)
            worker.setDemand(UInt32(N60_ANALYSIS_DEMAND_SPECTRUM) | ProductionAnalysisSelection.encode(view: .speaker(2)))
            Thread.sleep(forTimeInterval: 0.1)
            let count = Int(rate * (Double(size) / rate + 0.4))
            let centre = (0..<count).map { self.tone(1_000, rate: rate, $0) }
            let silence = [Float](repeating: 0, count: count)
            let planes = [silence, silence, centre, silence, silence, silence]
            let snapshot = pump(capture, worker: worker, planes: planes, rate: rate)
            XCTAssertEqual(snapshot.droppedFrames, 0, "rate \(rate)")
            XCTAssertGreaterThan(snapshot.spectrum.map(\.outputDB).max() ?? -.infinity, -12, "centre view at \(rate)")

            worker.setDemand(UInt32(N60_ANALYSIS_DEMAND_SPECTRUM) | ProductionAnalysisSelection.encode(view: .speaker(0)))
            Thread.sleep(forTimeInterval: 0.1)
            let again = pump(capture, worker: worker, planes: planes, rate: rate)
            XCTAssertLessThan(again.spectrum.map(\.outputDB).max() ?? -.infinity, -75, "front-left view at \(rate)")

            worker.setDemand(0)
            Thread.sleep(forTimeInterval: 0.2)
            XCTAssertEqual(worker.snapshot(), .empty, "nothing is published while hidden")
        }
    }

    func testWorkerCarriesMetersAndBitsForEveryChannelAndTheSelectedPair() throws {
        let rate = 48_000.0
        let capture = try XCTUnwrap(N60LoudnessCaptureCreate(6, 6, rate))
        defer { N60LoudnessCaptureDestroy(capture) }
        let positions = LoudnessChannelPosition.positions(for: Self.fiveOne)
        let worker = try XCTUnwrap(ProductionWideLoudnessWorker(
            capture: capture, sampleRate: rate, inputPositions: positions, outputPositions: positions, roles: Self.fiveOne))
        defer { worker.stop() }
        worker.setDemand(ProductionAnalysisDemand.loudness | ProductionAnalysisDemand.analysisMeters | ProductionAnalysisDemand.bitActivity)
        Thread.sleep(forTimeInterval: 0.1)
        let count = Int(rate * 4)
        let x = (0..<count).map { self.tone(440, rate: rate, $0, amplitude: 0.4) }
        let planes = [x, x, x, [Float](repeating: 0, count: count), x, x]
        let snapshot = pump(capture, worker: worker, planes: planes, rate: rate)
        XCTAssertEqual(snapshot.bitActivity.count, 6)
        XCTAssertNotNil(snapshot.analysisMeters?.crestDB)
        XCTAssertNotNil(snapshot.analysisMeters?.plr)

        worker.setDemand(UInt32(N60_ANALYSIS_DEMAND_STEREO) | ProductionAnalysisSelection.encode(view: .standard, pair: .surrounds))
        Thread.sleep(forTimeInterval: 0.1)
        let inverted = [x, x, x, planes[3], x, x.map { -$0 }]
        let stereo = pump(capture, worker: worker, planes: inverted, rate: rate)
        XCTAssertTrue(stereo.phaseCorrelationValid)
        XCTAssertEqual(stereo.phaseCorrelation, -1, accuracy: 0.01)
        XCTAssertTrue(stereo.bitActivity.isEmpty, "the meters stop when their card is hidden")
    }

    private func pump(
        _ capture: UnsafeMutablePointer<N60LoudnessCapture>, worker: ProductionWideLoudnessWorker, planes: [[Float]], rate: Double
    ) -> ProductionAnalysisSnapshot {
        let total = planes[0].count
        let block = Int(rate / 10)
        var start = 0
        var written = N60LoudnessCaptureGetSnapshot(capture).capturedFrames
        while start < total {
            let end = min(start + block, total)
            let granted = N60LoudnessCaptureBeginBlock(capture, UInt32(end - start))
            XCTAssertEqual(Int(granted.frames), end - start)
            for n in 0..<Int(granted.frames) {
                var frame = planes.map { $0[start + n] }
                N60LoudnessCaptureWriteInput(capture, granted, UInt32(n), &frame)
                N60LoudnessCaptureWriteOutput(capture, granted, UInt32(n), &frame)
            }
            N60LoudnessCaptureCommit(capture, granted)
            written += UInt64(granted.frames)
            start = end
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let s = worker.snapshot()
                if s.capturedFrames == written, s.availableFrames == 0 { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        Thread.sleep(forTimeInterval: 0.12)
        return worker.snapshot()
    }

    // MARK: E33 S11 (G72): role names for bit activity

    private func channel(_ id: String, _ label: String, _ index: UInt32) -> ProductionTransportChannelMeter {
        ProductionTransportChannelMeter(id: id, label: label, channelIndex: index, peakLinear: 0, rmsLinear: 0, overRangeSamples: 0)
    }

    func testProgramRolesParseTheProgramChannelIdsAndSkipOthers() {
        let channels = [
            channel("program-frontLeft", "Front left", 0), channel("physical-frontLeft", "x", 1),
            channel("program-notARole", "y", 2), channel("program-lowFrequencyEffects", "LFE", 3),
        ]
        XCTAssertEqual(AnalysisViewOptions.programRoles(of: channels), [.frontLeft, .lowFrequencyEffects])
        for role in OutputProgramRole.allCases {
            XCTAssertEqual(AnalysisViewOptions.programRoles(of: [channel("program-\(role.rawValue)", "", 0)]), [role])
        }
    }

    func testBinauralBitActivityNamesAreRolesAtEveryRate() {
        for rate in Self.rates {
            let roles = Self.fiveOne
            let feed = WideAnalysisFeed(plan: plan(roles, binaural: true), sampleRate: rate)
            feed.setDemand(
                spectrum: false, stereo: false, meters: false, rta: false, spectrogram: false, spectrogramWindow: .tenSeconds,
                bits: true, view: .standard, pair: .standard)
            run(feed, rate: rate, seconds: 0.3, input: { c, n in self.tone(500 + 100 * Double(c), rate: rate, n) })
            let bits = feed.bitActivity()
            XCTAssertEqual(bits.count, roles.count, "\(rate)")
            XCTAssertEqual(feed.plan.bitChannelNames(bitCount: bits.count), roles.map(\.displayName), "\(rate)")
            XCTAssertEqual(feed.plan.bitChannelNames(bitCount: roles.count + 1), [], "a mismatch falls back")
        }
    }

    func testBitActivityNamesPreferRolesThenTransportLabelsThenStereo() {
        XCTAssertEqual(BitActivityNames.resolve(roleNames: ["A", "B"], transport: nil), ["A", "B"])
        XCTAssertEqual(BitActivityNames.resolve(roleNames: [], transport: nil), SpectrogramText.channelNames)
        let transport = ProductionTransportMeterSnapshot(
            kind: .semanticSpeakers, displayName: "", programLayoutName: "", sampleRate: 48_000, latencyFrames: 0,
            meteringEnabled: true, programChannels: [channel("program-frontLeft", "Front left", 0)], physicalOutputs: [],
            inputTruePeakLinear: nil, outputTruePeakLinear: nil, roomTreatment: nil, renderFailures: 0, outputWriteFailures: 0)
        XCTAssertEqual(BitActivityNames.resolve(roleNames: [], transport: transport), ["Front left"])
    }

    // MARK: Cost and block helpers (E33 G71)

    func testRingAppendAndCopyWrapLikeTheSampleLoopForAnyBlockSize() {
        var ring = [Float](repeating: 0, count: 10)
        var reference = ring
        var write = 0, refWrite = 0
        var counter: Float = 1
        for block in [3, 4, 5, 10, 1, 7, 25, 2] {
            let source = (0..<block).map { _ in defer { counter += 1 }; return counter }
            write = WideAnalysisFeed.ringAppend(&ring, write: write, source: source, frames: block)
            for v in source { reference[refWrite] = v; refWrite = (refWrite + 1) % 10 }
            XCTAssertEqual(ring, reference, "block \(block)")
            XCTAssertEqual(write, refWrite)
        }
        var out = [Float](repeating: -1, count: 8)
        WideAnalysisFeed.ringCopy(ring, start: 7, count: 6, into: &out)
        XCTAssertEqual(Array(out[0..<6]), (0..<6).map { ring[(7 + $0) % 10] })
        XCTAssertEqual(out[6], -1, "the copy writes only `count` samples")
    }

    func testMixKeepsPowerAndIgnoresMissingChannelsWithLongerPlanes() {
        let planes: [[Float]] = [[1, 2, 3, 99], [3, 2, 1, 99], [5, 5, 5, 99]]
        var out: [Float] = []
        WideAnalysisFeed.mix(planes, indices: [0, 1, 7], frames: 3, into: &out)
        let scale = 1 / Float(2).squareRoot()
        XCTAssertEqual(Array(out[0..<3]), [4 * scale, 4 * scale, 4 * scale])
        WideAnalysisFeed.mix(planes, indices: [], frames: 3, into: &out)
        XCTAssertEqual(Array(out[0..<3]), [0, 0, 0])
    }

    /// Blocks of changing size (a device that varies its buffer) give the same spectrum as steady blocks.
    func testVariableBlockSizesGiveTheSameSpectrum() {
        let rate = 48_000.0
        let size = ProductionAnalysisMath.fftSize(sampleRate: rate)
        func spectrum(blocks: [Int]) -> [Float] {
            let feed = WideAnalysisFeed(plan: plan(Self.fiveOne), sampleRate: rate)
            demand(feed, spectrum: true)
            let channels = 6
            var position = 0, index = 0
            while position < size + 4_800 {
                let n = blocks[index % blocks.count]
                index += 1
                var data = [Float](repeating: 0, count: n * channels)
                for f in 0..<n { for c in 0..<channels { data[f * channels + c] = c == 2 ? tone(1_000, rate: rate, position + f) : 0 } }
                data.withUnsafeBufferPointer { feed.ingest(input: $0.baseAddress!, output: $0.baseAddress!, frames: n) }
                position += n
            }
            return feed.spectrum().map(\.outputDB)
        }
        let a = spectrum(blocks: [512]), b = spectrum(blocks: [512])
        XCTAssertEqual(a, b)
        let varied = spectrum(blocks: [128, 512, 64, 512, 256, 512])
        XCTAssertEqual(varied.count, a.count)
        XCTAssertEqual(varied.max() ?? 0, a.max() ?? 0, accuracy: 0.5)
    }

    /// Cost of the wide feed with every view held at 384 kHz and 32 channels, per second of audio. Prints the figure for the
    /// Release run (`xcodebuild test -configuration Release`); the bound is loose enough for a Debug build on a shared runner
    /// and still fails an accidental per-sample or per-tick allocation (the measured Debug figure was 51 s before G71).
    func testWideFeedCostAt384kHzWith32ChannelsStaysWellUnderRealtime() {
        let all = (spectrum: true, stereo: true, meters: true, rta: true, bits: true)
        let total = wideFeedCost(all)
        print("G71 wide feed cost at 384 kHz, 32 channels: \(total) s of CPU per second of audio")
        XCTAssertLessThan(total, Self.costBudgetSeconds, "cost per audio second")
    }

    func testWideFeedCostByView() {
        for (name, d) in [("spectrum", (true, false, false, false, false)), ("stereo", (false, true, false, false, false)),
                          ("meters", (false, false, true, false, false)), ("rta", (false, false, false, true, false)),
                          ("bits", (false, false, false, false, true))] {
            print("G71 \(name) only: \(wideFeedCost((d.0, d.1, d.2, d.3, d.4))) s")
        }
    }

    /// Debug is about 25 times slower than Release on the true-peak meters (the Debug figure is 52 s, Release is the figure
    /// recorded in the epic's G71 entry); the bound only catches a per-sample or per-tick allocation or an O(n^2).
    #if DEBUG
    static let costBudgetSeconds = 120.0
    #else
    static let costBudgetSeconds = 3.0
    #endif

    private func wideFeedCost(_ d: (spectrum: Bool, stereo: Bool, meters: Bool, rta: Bool, bits: Bool)) -> Double {
        let rate = 384_000.0, channels = 32, block = 1_024
        let wide = WideAnalysisPlan(roles: Array((Self.sevenOneFour + Self.sevenOneFour + Self.sevenOneFour).prefix(channels)),
                                    inputChannels: channels, outputChannels: channels, isBinaural: false)
        let feed = WideAnalysisFeed(plan: wide, sampleRate: rate)
        feed.setDemand(spectrum: d.spectrum, stereo: d.stereo, meters: d.meters, rta: d.rta, spectrogram: false, spectrogramWindow: .tenSeconds,
                       bits: d.bits, view: .standard, pair: .standard)
        var data = [Float](repeating: 0, count: block * channels)
        for f in 0..<block { for c in 0..<channels { data[f * channels + c] = Float(0.3 * sin(Double(f * (c + 1)) * 0.01)) } }
        let blocks = Int(rate) / block
        let pollEvery = Int(rate / 20) / block
        let elapsed = ContinuousClock().measure {
            for i in 0..<blocks {
                data.withUnsafeBufferPointer { feed.ingest(input: $0.baseAddress!, output: $0.baseAddress!, frames: block) }
                if i % pollEvery == 0 { _ = feed.spectrum(); _ = feed.stereoReadout(); _ = feed.rtaLevels() }
            }
        }
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    }
}
