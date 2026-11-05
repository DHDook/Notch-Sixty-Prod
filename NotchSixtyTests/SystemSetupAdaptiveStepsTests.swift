import XCTest
@testable import NotchSixty

/// E25 S4: the Alignment, Bass and Correction steps adapt to the arrangement class.
@MainActor
final class SystemSetupAdaptiveStepsTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func arrangement(_ bass: BassHandling, layout: OutputProgramLayout = .stereo, channels: Int = 2) -> SystemArrangement {
        SystemSetupArrangementPlanner.arrangement(
            deviceUID: "d", detectedChannelCount: 8, channelsInUse: channels,
            choices: .init(layout: layout, bass: bass, subwooferCount: bass == .dspToSubOutputs ? 1 : (bass.isDownstream ? 1 : 0)))
    }

    // MARK: Pure rules

    func testBassStepModePerClass() {
        XCTAssertEqual(SystemSetupAdaptiveSteps.bassMode(arrangement(.dspToSubOutputs, channels: 3)), .dspSubwoofers)
        XCTAssertEqual(SystemSetupAdaptiveSteps.bassMode(arrangement(.dspMonoToMains)), .monoBass)
        XCTAssertEqual(SystemSetupAdaptiveSteps.bassMode(arrangement(.downstreamSubCrossover)),
                       .skipped(reason: SystemCapabilityMatrix.receiverSetsBass))
        XCTAssertEqual(SystemSetupAdaptiveSteps.bassMode(arrangement(.downstreamReceiver, layout: .fiveOne)),
                       .skipped(reason: SystemCapabilityMatrix.receiverSetsBass))
        if case .skipped(let reason)? = SystemSetupAdaptiveSteps.bassMode(arrangement(.fullRange)) {
            XCTAssertFalse(reason.isEmpty)
        } else { XCTFail("class B skips the bass step") }
        XCTAssertNil(SystemSetupAdaptiveSteps.bassMode(nil))
    }

    func testSubNotesAndAdviceOnlyForDownstreamClasses() {
        for bass in [BassHandling.downstreamReceiver, .downstreamSubCrossover] {
            let a = arrangement(bass, layout: bass == .downstreamReceiver ? .fiveOne : .stereo)
            XCTAssertEqual(SystemSetupAdaptiveSteps.alignmentSubNote(a), SystemCapabilityMatrix.receiverSetsBass)
            XCTAssertEqual(SystemSetupAdaptiveSteps.receiverAdvice(a), SystemCapabilityMatrix.receiverAdvice)
            XCTAssertNotNil(SystemSetupAdaptiveSteps.correctionNote(a))
            XCTAssertTrue(SystemSetupAdaptiveSteps.measuredSourceLabel(.speaker(.frontLeft), arrangement: a).contains("not separable"))
        }
        let c = arrangement(.dspMonoToMains)
        XCTAssertNil(SystemSetupAdaptiveSteps.receiverAdvice(c))
        XCTAssertNil(SystemSetupAdaptiveSteps.correctionNote(c))
        XCTAssertEqual(SystemSetupAdaptiveSteps.measuredSourceLabel(.speaker(.frontLeft), arrangement: c),
                       MultichannelCalibrationSource.speaker(.frontLeft).displayName)
    }

    func testFeedAlignmentKeepsTheMonoBassFilter() {
        var base = arrangement(.dspMonoToMains)
        base.stereoAlignment = StereoBassAlignment(monoBassFilter: MonoBassFilter(family: .linkwitzRiley, slopeDBPerOctave: 48))
        let alignment = SystemSetupAlignment(sampleRate: 48_000, rows: [
            SystemSetupAlignmentRow(source: .speaker(.frontLeft), levelDB: -1.5, delayMilliseconds: 0.58, polarityInverted: false, distanceMetres: 2),
            SystemSetupAlignmentRow(source: .speaker(.frontRight), levelDB: 0, delayMilliseconds: 0, polarityInverted: true, distanceMetres: 2.2),
        ])
        let feeds = SystemSetupAdaptiveSteps.feedCalibration(from: alignment)
        XCTAssertEqual(feeds?.left.delayMs, 0.58)
        XCTAssertEqual(feeds?.right.polarityInverted, true)
        let result = SystemSetupAdaptiveSteps.applying(feeds: feeds!, to: base)
        XCTAssertEqual(result.stereoAlignment?.monoBassFilter?.slopeDBPerOctave, 48)
        XCTAssertEqual(result.stereoAlignment?.left.trimDB, -1.5)
        XCTAssertNil(SystemSetupAdaptiveSteps.compileIssue(result))
    }

    // MARK: Mono-bass design (rates)

    /// A 2nd-order Butterworth high-pass impulse response: the speaker stops at `cornerHz`.
    private func highPassImpulse(cornerHz: Double, rate: Double, seconds: Double = 0.3) -> [Float] {
        let w = 2 * Double.pi * cornerHz / rate
        let alpha = sin(w) / (2 * 0.70710678)
        let b0 = (1 + cos(w)) / 2, b1 = -(1 + cos(w)), b2 = b0
        let a0 = 1 + alpha, a1 = -2 * cos(w), a2 = 1 - alpha
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for n in 0..<out.count {
            let x = n == 0 ? 1.0 : 0.0
            let y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = x; y2 = y1; y1 = y
            out[n] = Float(y)
        }
        return out
    }

    func testMonoBassCrossoverIsWithinAThirdOctaveOfTheReferenceAtEveryRate() {
        // Reference: the 2nd-order Butterworth -6 dB point is 0.761 x the corner; the crossover sits 1.5 x above it.
        for rate in Self.rates {
            for corner in [40.0, 55.0, 70.0] {
                let ir = highPassImpulse(cornerHz: corner, rate: rate)
                let ext = SystemSetupMonoBassDesign.extensionPoint(
                    power: SystemSetupMonoBassDesign.powerSpectrum(ir, arrivalSeconds: 0, sampleRate: rate))
                XCTAssertEqual(log2(ext / (0.761 * corner)), 0, accuracy: 1.0 / 3, "\(rate) \(corner)")
                let design = SystemSetupMonoBassDesign.design(leftExtensionHz: ext, rightExtensionHz: ext, sampleRate: rate)
                let reference = min(max(1.5 * 0.761 * corner, 60), 120)
                XCTAssertEqual(log2(design.crossoverHz / reference), 0, accuracy: 1.0 / 3, "\(rate) \(corner)")
                XCTAssertTrue(design.filter.isValid)
            }
        }
    }

    func testMonoBassUsesTheWeakerFeedAndTheSteeperSlopeForSmallSpeakers() {
        let d = SystemSetupMonoBassDesign.design(leftExtensionHz: 40, rightExtensionHz: 95, sampleRate: 48_000)
        XCTAssertEqual(d.crossoverHz, 120)
        XCTAssertEqual(d.filter.slopeDBPerOctave, 48)
        let wide = SystemSetupMonoBassDesign.design(leftExtensionHz: 25, rightExtensionHz: 30, sampleRate: 48_000)
        XCTAssertEqual(wide.crossoverHz, 60)
        XCTAssertEqual(wide.filter.slopeDBPerOctave, 24)
    }

    // MARK: Wizard through production wiring

    private func runToAlignment(_ rig: OfflineSetupRig, bass: BassHandling, layout: OutputProgramLayout = .stereo,
                                label: String) async throws {
        let model = rig.model
        model.begin()
        model.chooseOutput(uid: OfflineSetupRig.outputUID)
        model.next()
        model.chooseLayout(layout)
        model.chooseBass(bass)
        model.next()
        XCTAssertEqual(model.step, .microphone, "\(label): \(model.message ?? "")")
        model.selectMicrophone(uid: OfflineSetupRig.inputUID)
        model.toggleNoise()
        model.stopNoise()
        model.acceptSweepLevel(measuredSPLdBC: 75)
        model.next()
        model.next()
        XCTAssertEqual(model.step, .measure, "\(label): \(model.message ?? "")")
        model.prepareMeasure()
        model.addSeat()
        await model.measureAll()
        model.next()
        XCTAssertEqual(model.step, .alignment, "\(label): \(model.message ?? "")")
        await model.computeAlignment()
        XCTAssertNotNil(model.alignment, "\(label): \(model.message ?? "")")
    }

    func testClassCAlignmentAndMonoBassReachTheStereoSessionAtEveryRate() async throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate, seats: 2, outputChannels: 2)
            defer { rig.tearDown() }
            let model = rig.model
            let label = "\(rate) Hz"
            try await runToAlignment(rig, bass: .dspMonoToMains, label: label)

            // Feeds only: the table has no subwoofer rows and the reason for sub controls is the feed note.
            XCTAssertEqual(model.alignment?.rows.map(\.source), [.speaker(.frontLeft), .speaker(.frontRight)], label)
            // The synthetic room puts the right feed 0.2 m further away: the feeds differ by 0.583 ms.
            let rows = try XCTUnwrap(model.alignment?.rows, label)
            XCTAssertEqual(abs(rows[0].delayMilliseconds - rows[1].delayMilliseconds), 0.2 / 343 * 1000, accuracy: 0.05, label)

            model.applyAlignment()
            XCTAssertTrue(model.choices.alignmentApplied, "\(label): \(model.message ?? "")")
            let stored = rig.profiles.selectedSystemProfile?.state.systemArrangement?.stereoAlignment
            XCTAssertEqual(stored?.left.delayMs, rows[0].delayMilliseconds, label)
            XCTAssertEqual(stored?.right.delayMs, rows[1].delayMilliseconds, label)
            XCTAssertNil(rig.profiles.selectedSystemOutputDeviceProfile, label)

            model.revertAlignment()
            XCTAssertFalse(model.choices.alignmentApplied, label)
            XCTAssertTrue(rig.profiles.selectedSystemProfile?.state.systemArrangement?.stereoAlignment?.left.isIdentity ?? true, label)
            model.applyAlignment()
            model.next()
            XCTAssertEqual(model.step, .bass, "\(label): \(model.message ?? "")")

            XCTAssertEqual(model.bassStepMode, .monoBass, label)
            model.computeBass()
            let design = try XCTUnwrap(model.monoBass, "\(label): \(model.message ?? "")")
            XCTAssertTrue(SystemSetupMonoBassDesign.crossoverRangeHz.contains(design.crossoverHz), label)
            let before = rig.profiles.selectedSystemProfile?.state.bassManagement.frequencyHz
            await model.applyBass()
            XCTAssertTrue(model.choices.bassApplied, "\(label): \(model.message ?? "")")
            XCTAssertEqual(rig.profiles.selectedSystemProfile?.state.bassManagement.frequencyHz, design.crossoverHz, label)
            XCTAssertEqual(rig.profiles.selectedSystemProfile?.state.systemArrangement?.stereoAlignment?.monoBassFilter, design.filter, label)
            XCTAssertEqual(rig.engine.bassManagementConfiguration.frequencyHz, design.crossoverHz, label)
            model.revertBass()
            XCTAssertFalse(model.choices.bassApplied, label)
            XCTAssertEqual(rig.profiles.selectedSystemProfile?.state.bassManagement.frequencyHz, before, label)
            XCTAssertNil(rig.profiles.selectedSystemProfile?.state.systemArrangement?.stereoAlignment?.monoBassFilter, label)
        }
    }

    func testReceiverClassSkipsBassWithTheReasonAndCorrectsTheFeeds() async throws {
        let rate = 48_000.0
        let rig = try OfflineSetupRig(rate: rate, seats: 2, outputChannels: 2)
        defer { rig.tearDown() }
        let model = rig.model
        try await runToAlignment(rig, bass: .downstreamReceiver, layout: .fiveOne, label: "E")
        XCTAssertEqual(model.alignmentSubNote, SystemCapabilityMatrix.receiverSetsBass)
        XCTAssertEqual(model.alignment?.rows.count, 2)
        model.applyAlignment()
        XCTAssertTrue(model.choices.alignmentApplied, model.message ?? "")
        model.next()
        XCTAssertEqual(model.step, .bass)
        XCTAssertEqual(model.bassStepMode, .skipped(reason: SystemCapabilityMatrix.receiverSetsBass))
        XCTAssertNotNil(model.receiverAdvice)
        XCTAssertNotNil(model.correctionNote)
        model.next()
        XCTAssertEqual(model.step, .correction, model.message ?? "")
        XCTAssertNil(rig.profiles.selectedSystemOutputDeviceProfile)
        model.prepareCorrection()
        XCTAssertTrue(model.correctionIsPrepared, model.message ?? "")
        await model.applyCorrection()
        XCTAssertTrue(model.choices.correctionApplied, model.message ?? "")
    }

}
