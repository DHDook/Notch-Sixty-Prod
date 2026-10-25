import XCTest
@testable import NotchSixty

/// E10 S8: post-apply verification through a live graph. The harness renders the real core graph (generator sweep, then the
/// published ROOM_FIR stage) and passes the output through a reference room (a delay and one smooth resonance) to stand in
/// for the mic. Real synthesis, real deconvolution, every standard rate.
struct ReferenceRoom: Equatable, Sendable {
    var delayFrames: Int
    var resonanceHz: Double
    var gainDB: Double
    var q = 1.5

    private func coefficients(rate: Double) -> (b: [Double], a: [Double]) {
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * resonanceHz / rate, alpha = sin(w) / (2 * q)
        let b = [1 + alpha * a, -2 * cos(w), 1 - alpha * a]
        let d = [1 + alpha / a, -2 * cos(w), 1 - alpha / a]
        return (b.map { $0 / d[0] }, d.map { $0 / d[0] })
    }

    func render(_ x: [Float], rate: Double) -> [Float] {
        let (b, a) = coefficients(rate: rate)
        var out = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for n in 0..<x.count {
            let input = n >= delayFrames ? Double(x[n - delayFrames]) : 0
            let y = b[0] * input + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            x2 = x1; x1 = input; y2 = y1; y1 = y
            out[n] = Float(y)
        }
        return out
    }

    func impulse(rate: Double, frames: Int) -> [Float] {
        var x = [Float](repeating: 0, count: frames)
        x[0] = 1
        return render(x, rate: rate)
    }

    func magnitudeDB(at hz: Double, rate: Double) -> Double {
        let (b, a) = coefficients(rate: rate)
        let w = 2 * Double.pi * hz / rate
        func eval(_ c: [Double]) -> (Double, Double) {
            (c[0] + c[1] * cos(w) + c[2] * cos(2 * w), -(c[1] * sin(w) + c[2] * sin(2 * w)))
        }
        let n = eval(b), d = eval(a)
        return 20 * log10(hypot(n.0, n.1) / hypot(d.0, d.1))
    }
}

/// Renders the published design through the real graph and a reference room.
final class OfflineGraphTrialHost: RoomCorrectionTrialHost, @unchecked Sendable {
    let room: ReferenceRoom
    let rate: Double
    private let lock = NSLock()
    private var _applied: String?
    private var _reverts = 0
    var captureDelaySeconds = 0.0

    init(room: ReferenceRoom, rate: Double) { self.room = room; self.rate = rate }

    var applied: String? { lock.lock(); defer { lock.unlock() }; return _applied }
    var reverts: Int { lock.lock(); defer { lock.unlock() }; return _reverts }

    func applyTrial(_ candidate: RoomCorrectionDeployCandidate) async throws {
        lock.lock(); _applied = candidate.designID; lock.unlock()
    }

    func revertTrial() async {
        lock.lock(); _applied = nil; _reverts += 1; lock.unlock()
    }

    func captureSweep(for candidate: RoomCorrectionDeployCandidate) async throws -> [Float] {
        if captureDelaySeconds > 0 { try await Task.sleep(nanoseconds: UInt64(captureDelaySeconds * 1e9)) }
        let output = try Self.renderGraph(candidate, rate: rate)
        return room.render(output, rate: rate)
    }

    static func program(_ plan: RoomCorrectionLanePlan) throws -> UnifiedGraphProgramDSP {
        var base = UnifiedGraphConfiguration(sampleRate: plan.sampleRate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        base.stereoStages = UnifiedGraphStereoStages()
        var program = UnifiedGraphProgramDSP(
            stereo: base, shape: UnifiedGraphLayoutShape(roles: OutputProgramLayout.fiveOne.roles)!, eqMode: .linked)
        program.roomLanes = plan
        return program
    }

    static func generatorParams(_ candidate: RoomCorrectionDeployCandidate) throws -> [Float] {
        var settings = SignalGeneratorSettings()
        settings.kind = .sweep
        settings.lowHz = candidate.sweepStartHz
        settings.highHz = candidate.sweepEndHz
        settings.periodFrames = candidate.sweepFrames
        return try XCTUnwrap(settings.stageParams(active: true, sampleRate: candidate.sampleRate))
    }

    /// Lane `measuredLane` of the graph with the generator playing one sweep.
    static func renderGraph(_ candidate: RoomCorrectionDeployCandidate, rate: Double) throws -> [Float] {
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(sampleRate: rate, programChannels: 6, subwoofers: [])
        configuration.orderPolicy = .canonical
        configuration.programDSP = try program(candidate.lanePlan)
        configuration.generatorParams = try generatorParams(candidate)
        let spec: UnifiedGraphSpec
        do { spec = try configuration.makeSpec() } catch { throw NSError(domain: "makeSpec \(error)", code: 1) }
        let host: UnifiedGraphHost
        do { host = try UnifiedGraphHost(spec: spec) } catch { throw NSError(domain: "build \(error)", code: 1) }
        defer { host.release() }
        let total = candidate.sweepFrames + Int(candidate.lanePlan.declaredLatencyFrames) + Int(0.6 * rate)
        let block = 4_096
        let silence = [[Float]](repeating: [Float](repeating: 0, count: block), count: 6)
        var out: [Float] = []
        out.reserveCapacity(total + block)
        while out.count < total {
            do { out += try host.processOffline(input: silence, frames: block)[candidate.measuredLane] } catch {
                throw NSError(domain: "process \(error) in=\(spec.inputChannels) max=\(spec.maxBlockFrames)", code: 1)
            }
        }
        return Array(out.prefix(total))
    }
}

@MainActor
final class RoomCorrectionDeployControllerTests: XCTestCase {
    static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    let assumed = ReferenceRoom(delayFrames: 120, resonanceHz: 100, gainDB: 6)

    /// A design that undoes `assumed`'s resonance, published at `rate`, with the prediction for the assumed room.
    func candidate(rate: Double, mode: RoomCorrectionLatencyMode = .music20ms, kind: RoomCorrectionDeployCandidate.Kind = .mixedPhase,
                   id: String = "design-A") throws -> RoomCorrectionDeployCandidate {
        let frequencies = try RoomCorrectionCore.gridFrequencies()
        let grid = RoomCorrectionGridDesign(
            correctionDB: frequencies.map { -assumed.magnitudeDB(at: $0, rate: 48_000) },
            correctionPhaseRadians: [Double](repeating: 0, count: frequencies.count),
            coherence: [Double](repeating: 0, count: frequencies.count), seatContribution: [])
        let design = RoomCorrectionMultiLaneDesign(
            latencyMode: mode, laneCount: 6, lanes: [RoomCorrectionLaneDesign(lane: 0, grid: grid)])
        let plan = try RoomCorrectionRateCache().plan(for: design, sampleRate: rate)
        let stage = try XCTUnwrap(plan.stages.first)
        let criteria = RoomCorrectionPostApplyCriteria()
        let check = try RoomCorrectionPredictionCheck.check(
            stage: stage, grid: grid, sampleRate: rate, declaredLatencyFrames: plan.declaredLatencyFrames,
            latencyMode: mode, criteria: criteria)
        let predicted = try RoomCorrectionPostApplyVerifier.prediction(
            roomImpulse: assumed.impulse(rate: rate, frames: Int(0.5 * rate)), roomArrivalFrames: Double(assumed.delayFrames),
            stage: stage, declaredLatencyFrames: plan.declaredLatencyFrames, sampleRate: rate, criteria: criteria)
        return RoomCorrectionDeployCandidate(
            designID: id, kind: kind, sampleRate: rate, lanePlan: plan, latencyMode: mode, measuredLane: 0,
            predictionCheck: check, predicted: predicted, sweepFrames: Int(2 * rate))
    }

    func testCorrectDesignPassesAtEveryRate() async throws {
        for rate in Self.rates {
            let controller = RoomCorrectionDeployController()
            let design = try candidate(rate: rate)
            XCTAssertTrue(design.predictionCheck.passed, "\(design.predictionCheck.reasons) at \(rate)")
            XCTAssertFalse(controller.canDeploy(design), "before verification at \(rate)")
            let host = OfflineGraphTrialHost(room: assumed, rate: rate)
            let report = await controller.verify(design, host: host, timeoutSeconds: 120)
            XCTAssertEqual(report.outcome, .passed, "\(report.detail) at \(rate)")
            XCTAssertLessThanOrEqual(report.maxMagnitudeErrorDB, 1.5)
            XCTAssertEqual(host.applied, "design-A")
            XCTAssertEqual(host.reverts, 0)
            XCTAssertEqual(controller.storedReport, report)
            XCTAssertTrue(controller.canDeploy(design))
        }
    }

    func testMismatchedRoomFailsAndReverts() async throws {
        let rate = 48_000.0
        let controller = RoomCorrectionDeployController()
        let design = try candidate(rate: rate)
        let host = OfflineGraphTrialHost(room: ReferenceRoom(delayFrames: 120, resonanceHz: 160, gainDB: 6), rate: rate)
        let report = await controller.verify(design, host: host, timeoutSeconds: 120)
        XCTAssertEqual(report.outcome, .magnitudeMismatch, report.detail)
        XCTAssertGreaterThan(report.maxMagnitudeErrorDB, 1.5)
        XCTAssertNil(host.applied)
        XCTAssertEqual(host.reverts, 1)
        XCTAssertNil(controller.storedReport)
        XCTAssertFalse(controller.canDeploy(design))
    }

    func testTimeoutRevertsAndBlocksDeploy() async throws {
        let rate = 48_000.0
        let controller = RoomCorrectionDeployController()
        let design = try candidate(rate: rate)
        let host = OfflineGraphTrialHost(room: assumed, rate: rate)
        host.captureDelaySeconds = 30
        let report = await controller.verify(design, host: host, timeoutSeconds: 0.2)
        XCTAssertEqual(report.outcome, .timedOut)
        XCTAssertNil(host.applied)
        XCTAssertEqual(host.reverts, 1)
        XCTAssertFalse(controller.canDeploy(design))
    }

    func testCancelRevertsAndBlocksDeploy() async throws {
        let rate = 48_000.0
        let controller = RoomCorrectionDeployController()
        let design = try candidate(rate: rate)
        let host = OfflineGraphTrialHost(room: assumed, rate: rate)
        host.captureDelaySeconds = 30
        let canceller = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            controller.cancel()
        }
        let report = await controller.verify(design, host: host, timeoutSeconds: 60)
        await canceller.value
        XCTAssertEqual(report.outcome, .cancelled)
        XCTAssertNil(host.applied)
        XCTAssertEqual(host.reverts, 1)
        XCTAssertFalse(controller.canDeploy(design))
    }

    func testCanDeployNeedsAStoredPassingReportForTheSameDesign() async throws {
        let rate = 48_000.0
        let controller = RoomCorrectionDeployController()
        let design = try candidate(rate: rate)
        let other = try candidate(rate: rate, id: "design-B")
        XCTAssertFalse(controller.canDeploy(design))
        let host = OfflineGraphTrialHost(room: assumed, rate: rate)
        _ = await controller.verify(design, host: host, timeoutSeconds: 120)
        XCTAssertTrue(controller.canDeploy(design))
        XCTAssertFalse(controller.canDeploy(other))
        controller.invalidate()
        XCTAssertFalse(controller.canDeploy(design))
        // Minimum phase keeps the prediction-only path.
        var minimum = try candidate(rate: rate, mode: .video, kind: .minimumPhase)
        XCTAssertTrue(controller.canDeploy(minimum))
        minimum.predictionCheck.passed = false
        XCTAssertFalse(controller.canDeploy(minimum))
    }

    func testPassingReportIsStoredAndReloaded() async throws {
        let rate = 48_000.0
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("postapply-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let design = try candidate(rate: rate)
        let controller = RoomCorrectionDeployController(storeURL: url)
        _ = await controller.verify(design, host: OfflineGraphTrialHost(room: assumed, rate: rate), timeoutSeconds: 120)
        let reloaded = RoomCorrectionDeployController(storeURL: url)
        XCTAssertTrue(reloaded.canDeploy(design))
        XCTAssertEqual(reloaded.storedReport?.designID, "design-A")
        XCTAssertFalse(reloaded.storedReport?.centres.isEmpty ?? true)
    }

    func testFailedPredictionCheckNeverReachesTheHost() async throws {
        let rate = 48_000.0
        var design = try candidate(rate: rate)
        design.predictionCheck = RoomCorrectionPredictionCheck(passed: false, rmsErrorDB: 9, reasons: ["bad"])
        let host = OfflineGraphTrialHost(room: assumed, rate: rate)
        let report = await RoomCorrectionDeployController().verify(design, host: host, timeoutSeconds: 5)
        XCTAssertEqual(report.outcome, .analysisFailed)
        XCTAssertNil(host.applied)
    }
}
