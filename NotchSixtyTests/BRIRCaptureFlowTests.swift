import XCTest
@testable import NotchSixty

/// E13 S7: the guided BRIR capture flow, its per-pass quality gate and its cancel behaviour.
@MainActor
final class BRIRCaptureFlowTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func device() -> AudioInputDevice {
        AudioInputDevice(
            deviceID: 1, uid: "ear-mics", name: "Ear mics", nominalSampleRate: 48_000,
            availableSampleRateRanges: [], inputChannelCount: 2)
    }

    private var leftSeat: MeasurementSeat { MeasurementSeat(device: device(), channelIndex: 0) }
    private var rightSeat: MeasurementSeat { MeasurementSeat(device: device(), channelIndex: 1) }

    private final class FakeEnvironment: BRIRCaptureEnvironment {
        let store: BinauralProfileAssetStore
        let tapCount: Int
        var opened = 0
        var finished = 0
        var sessionOpen = false
        var speakerPasses = 0
        var headphonePasses = 0
        var hangs = false
        var started = false
        /// Consumed front to back; empty means a clean pass.
        var qualities: [BRIRPassQuality] = []

        init(store: BinauralProfileAssetStore, tapCount: Int) {
            self.store = store
            self.tapCount = tapCount
        }

        func beginSession() throws { opened += 1; sessionOpen = true }
        func finishSession() { guard sessionOpen else { return }; sessionOpen = false; finished += 1 }

        private func outcome() async throws -> BRIRPassOutcome {
            started = true
            if hangs { try await Task.sleep(nanoseconds: 60_000_000_000) }
            var left = [Float](repeating: 0, count: tapCount)
            var right = left
            left[8 + speakerPasses % 16] = 1
            right[12 + speakerPasses % 16] = 0.6
            let quality = qualities.isEmpty ? BRIRPassQuality(snrDB: 60, clippedSamples: 0) : qualities.removeFirst()
            return BRIRPassOutcome(left: left, right: right, quality: quality)
        }

        func speakerPass(plan: BRIRCapturePlan, step: BRIRCaptureStep) async throws -> BRIRPassOutcome {
            let result = try await outcome()
            speakerPasses += 1
            return result
        }

        func headphonePass(plan: BRIRCapturePlan, channel: Int) async throws -> BRIRPassOutcome {
            var result = try await outcome()
            result.left = [Float](repeating: 0, count: tapCount); result.left[0] = 1
            result.right = result.left
            headphonePasses += 1
            return result
        }

        func save(_ asset: BinauralProfileAsset) throws -> BinauralProfileReference { try store.save(asset) }
    }

    private func makeFlow(rate: Double = 48_000, roles: [OutputProgramRole] = [.frontLeft, .frontRight])
        throws -> (BRIRCaptureFlow, FakeEnvironment, BinauralProfileAssetStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brir-flow-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = BinauralProfileAssetStore(rootURL: root)
        let tapCount = max(1, min(Int(N60_BINAURAL_MAX_TAPS), Int(0.25 * rate)))
        let environment = FakeEnvironment(store: store, tapCount: tapCount)
        let flow = BRIRCaptureFlow(environment: environment, sampleRate: rate, availableSpeakers: roles + [.lowFrequencyEffects])
        return (flow, environment, store)
    }

    /// Fills the early steps and stops on `target`.
    private func drive(_ flow: BRIRCaptureFlow, to target: BRIRFlowStep, compensation: Bool = false) {
        flow.leftEar = leftSeat
        flow.rightEar = rightSeat
        flow.includeCompensation = compensation
        flow.headphonesConfirmed = compensation
        while flow.step < target {
            let before = flow.step
            flow.advance()
            if flow.step == before { break }
        }
    }

    private func captureAll(_ flow: BRIRCaptureFlow) async {
        while flow.step == .capture {
            let before = flow.passIndex
            await flow.capture()
            if flow.passIndex == before { break }
        }
    }

    // MARK: Steps and blockers

    func testStepsAreBlockedUntilTheirInputsAreValid() throws {
        let (flow, _, _) = try makeFlow()
        XCTAssertEqual(flow.step, .microphones)
        XCTAssertNotNil(flow.blocker)
        flow.advance()
        XCTAssertEqual(flow.step, .microphones, "no microphones chosen")
        flow.leftEar = leftSeat
        flow.rightEar = leftSeat
        XCTAssertNotNil(flow.blocker, "the same channel for both ears")
        flow.rightEar = rightSeat
        flow.advance()
        XCTAssertEqual(flow.step, .speakers)
        XCTAssertFalse(flow.speakers.contains(.lowFrequencyEffects), "LFE is not capturable")
        flow.speakers = []
        XCTAssertNotNil(flow.blocker)
        flow.speakers = [.frontLeft]
        flow.advance()
        flow.headPositions = .five
        XCTAssertEqual(flow.plan?.steps.count, 5)
        flow.advance()
        flow.includeCompensation = true
        XCTAssertNotNil(flow.blocker, "compensation needs the headphones confirmed")
        flow.headphonesConfirmed = true
        flow.advance()
        XCTAssertEqual(flow.step, .capture)
        XCTAssertEqual(flow.passes.count, 5 + BRIRCapturePlan.compensationReseatCount)
        XCTAssertTrue(flow.prompt.contains("Turn your head 60 degrees to the left"))
    }

    // MARK: Quality gate

    func testClippedOrNoisyPassIsDroppedAndOfferedAgain() async throws {
        let (flow, environment, _) = try makeFlow()
        environment.qualities = [
            BRIRPassQuality(snrDB: 60, clippedSamples: 40),
            BRIRPassQuality(snrDB: 12, clippedSamples: 0),
        ]
        drive(flow, to: .capture)
        await flow.capture()
        XCTAssertEqual(flow.passIndex, 0)
        XCTAssertTrue(flow.results.isEmpty)
        XCTAssertTrue(flow.problem?.contains("clipped") == true)
        await flow.capture()
        XCTAssertEqual(flow.passIndex, 0)
        XCTAssertTrue(flow.problem?.contains("noisy") == true)
        await flow.capture()
        XCTAssertEqual(flow.passIndex, 1, "a clean pass is kept")
        XCTAssertNil(flow.problem)
        XCTAssertEqual(flow.results.count, 1)
    }

    func testQualityAssessorFlagsClippingAndNoise() {
        var clean = [Float](repeating: 0, count: 4_096)
        clean[100] = 1
        for i in 1_700..<2_048 { clean[i] = (i % 2 == 0 ? 1 : -1) * 0.001 }
        let seat = MultiMicSeat(id: 0, label: "L")
        func record(_ response: [Float]) -> MultiMicSeatRecord {
            MultiMicSeatRecord(
                seat: seat, impulseResponse: response, directArrivalFrames: 100, delaySeconds: 0, timingTier: MeasurementCore.TimingTier.none,
                referencePeakDB: nil)
        }
        let good = BRIRPassQualityAssessor.assess(captures: [[0.2, -0.5, 0.9]], records: [record(clean)])
        XCTAssertGreaterThan(good.snrDB, 55)
        XCTAssertTrue(good.isAcceptable)

        var noisy = clean
        for i in 1_700..<2_048 { noisy[i] = (i % 2 == 0 ? 1 : -1) * 0.2 }
        XCTAssertTrue(BRIRPassQualityAssessor.assess(captures: [[0.1]], records: [record(noisy)]).isTooNoisy)

        let clipped = BRIRPassQualityAssessor.assess(captures: [[1, 1, 1, 0.99, 0]], records: [record(clean)])
        XCTAssertTrue(clipped.isClipped)
        let stray = BRIRPassQualityAssessor.assess(captures: [[1, 0, 0]], records: [record(clean)])
        XCTAssertFalse(stray.isClipped, "one stray full-scale sample is tolerated")
        XCTAssertEqual(BRIRPassQualityAssessor.snrDB(of: [Float](repeating: 0, count: 10)), 0)
    }

    // MARK: Cancel

    func testCancelAtEveryStepRestoresTheDeviceAndLeavesNoAsset() async throws {
        // 0 captured passes (the early steps and the capture prompt), one pass in, and every pass in (review).
        let stops: [(BRIRFlowStep, passes: Int)] = [
            (.microphones, 0), (.speakers, 0), (.positions, 0), (.compensation, 0),
            (.capture, 0), (.capture, 1), (.review, .max),
        ]
        for (stop, passes) in stops {
            for compensation in [false, true] {
                let label = "\(stop) after \(passes) passes, compensation \(compensation)"
                let (flow, environment, store) = try makeFlow()
                drive(flow, to: stop, compensation: compensation)
                if passes == .max { await captureAll(flow) }
                else { for _ in 0..<passes { await flow.capture() } }
                XCTAssertEqual(flow.step, stop, label)
                flow.cancel()
                XCTAssertEqual(environment.opened, environment.finished, "session released: \(label)")
                XCTAssertFalse(environment.sessionOpen, label)
                XCTAssertTrue(flow.results.isEmpty, label)
                XCTAssertEqual(flow.step, .microphones, label)
                XCTAssertEqual(try store.existingAssetIDs(), [], "no partial asset: \(label)")
            }
        }
    }

    func testCancelDuringAPassInFlightCancelsAndReleases() async throws {
        let (flow, environment, store) = try makeFlow()
        environment.hangs = true
        drive(flow, to: .capture)
        flow.startCapture()
        for _ in 0..<200 where !environment.started { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(flow.isCapturing)
        flow.cancel()
        for _ in 0..<200 where flow.isCapturing { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(flow.isCapturing)
        XCTAssertEqual(environment.opened, environment.finished)
        XCTAssertEqual(environment.speakerPasses, 0, "the in-flight pass never completed")
        XCTAssertTrue(flow.results.isEmpty)
        XCTAssertEqual(try store.existingAssetIDs(), [])
    }

    func testBackFromCaptureReleasesTheSessionAndDropsResults() async throws {
        let (flow, environment, _) = try makeFlow()
        drive(flow, to: .capture)
        await flow.capture()
        XCTAssertEqual(flow.results.count, 1)
        flow.back()
        XCTAssertEqual(flow.step, .compensation)
        XCTAssertEqual(environment.opened, environment.finished)
        XCTAssertTrue(flow.results.isEmpty)
    }

    // MARK: Full flow

    func testFullFlowWithCompensationSavesOneSchema2AssetAndSelectsIt() async throws {
        let (flow, environment, store) = try makeFlow()
        flow.headPositions = .three
        drive(flow, to: .capture, compensation: true)
        XCTAssertEqual(flow.passes.count, 6 + BRIRCapturePlan.compensationReseatCount)
        await captureAll(flow)
        XCTAssertEqual(flow.step, .review)
        XCTAssertEqual(environment.opened, 1)
        XCTAssertEqual(environment.finished, 1, "the session is released when the last pass is in")
        XCTAssertEqual(environment.speakerPasses, 6)
        XCTAssertEqual(environment.headphonePasses, 2 * BRIRCapturePlan.compensationReseatCount)
        XCTAssertEqual(try store.existingAssetIDs(), [], "nothing is stored before the review is accepted")

        flow.displayName = "  "
        XCTAssertNil(flow.save(), "a name is required")
        flow.displayName = "Living room"
        let reference = try XCTUnwrap(flow.save())
        XCTAssertEqual(flow.step, .saved)
        XCTAssertEqual(reference.displayName, "Living room")
        let asset = try store.load(id: reference.assetID)
        XCTAssertEqual(asset.schemaVersion, 2)
        XCTAssertEqual(asset.kind, .brir)
        XCTAssertEqual(Set(asset.measurements.compactMap(\.headYawDegrees)), [-30, 0, 30])
        XCTAssertEqual(Set(asset.measurements.compactMap(\.channelRole)), [.frontLeft, .frontRight])
    }

    func testSavedAssetActivatesAtEveryRate() async throws {
        for rate in Self.rates {
            let (flow, _, store) = try makeFlow(rate: rate)
            XCTAssertLessThanOrEqual(flow.tapCount, Int(N60_BINAURAL_MAX_TAPS), "taps at \(rate)")
            drive(flow, to: .capture)
            await captureAll(flow)
            let reference = try XCTUnwrap(flow.save(), "save at \(rate)")
            XCTAssertEqual(reference.sampleRate, rate)
            let asset = try store.load(id: reference.assetID)
            let prepared = try asset.prepare(
                for: .stereo, headPose: N60HeadPose(yawDegrees: 0, pitchDegrees: 0, rollDegrees: 0))
            XCTAssertEqual(prepared.leftIRs.count, 2 * flow.tapCount, "two virtual speakers at \(rate)")
        }
    }

    func testFlowWithNoProfileSpeakersCannotLeaveTheSpeakerStep() throws {
        let (flow, _, _) = try makeFlow(roles: [])
        flow.leftEar = leftSeat
        flow.rightEar = rightSeat
        flow.advance()
        XCTAssertEqual(flow.step, .speakers)
        XCTAssertTrue(flow.availableSpeakerRoles.isEmpty)
        flow.advance()
        XCTAssertEqual(flow.step, .speakers)
    }
}
