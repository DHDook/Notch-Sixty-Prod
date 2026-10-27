import XCTest
@testable import NotchSixty

/// E8 A2b: live protected capture of one routed way. Control plane only: binding, excitation, provenance, planning.
@MainActor
final class SpeakerMeasurementLabRoutedWayTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Fixtures

    private func routing(_ mode: SpeakerCrossoverMode, rate: Double, limiter: Double? = -6) throws
        -> SpeakerRoutingConfiguration {
        let buses: [SpeakerOutputBus] = mode == .triAmp
            ? [.leftLow, .rightLow, .leftMid, .rightMid, .leftHigh, .rightHigh]
            : [.leftLow, .rightLow, .leftHigh, .rightHigh]
        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.physicalOutputMode = mode
        bass.topology = .linkwitzRiley24
        bass.upperTopology = .linkwitzRiley24
        bass.frequencyHz = 400
        bass.upperFrequencyHz = mode == .triAmp ? 3_000 : nil
        let outputs = MultiOutputRoutingConfiguration(
            enabled: true,
            routes: buses.enumerated().map { index, bus in
                SpeakerOutputRoute(
                    name: bus.displayName, bus: bus,
                    destination: PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: UInt32(index)))
            })
        let drivers = SpeakerDriverProcessingConfiguration(
            buses: buses.map {
                SpeakerDriverBusProcessingConfiguration(
                    bus: $0, enabled: true, limiterEnabled: limiter != nil, limiterThresholdDBFS: limiter ?? -3)
            })
        let migrated = SpeakerRoutingMigration.migrate(routing: outputs, bassManagement: bass, driverProcessing: drivers)
        return try XCTUnwrap(migrated.routing)
    }

    private func device(_ uid: String, channels: UInt32 = 8) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: 77, uid: uid, name: uid, nominalSampleRate: 48_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)],
            outputChannelCount: channels)
    }

    private func environment(rate: Double, devices: [AudioOutputDevice]? = nil) -> SpeakerMeasurementLabRoutedWayEnvironment {
        SpeakerMeasurementLabRoutedWayEnvironment(
            availableOutputs: devices ?? [device("dev")], sampleRate: rate, selectedOutputUID: "dev")
    }

    private func sweep(rate: Double, level: Double = -30) -> RoomCorrectionSweepSettings {
        RoomCorrectionSweepSettings(sampleRate: rate, durationSeconds: 1, levelDBFS: level, leadInSeconds: 0.05, tailSeconds: 0.1)
    }

    private func midWay(_ routing: SpeakerRoutingConfiguration) -> RoutedWay { routing.speakers[0].ways[1] }

    // MARK: Guard band

    func testSweepStaysInsideGuardBandAtEveryRate() throws {
        for rate in Self.rates {
            let routing = try routing(.triAmp, rate: rate)
            let way = midWay(routing)
            let acquisition = try SpeakerMeasurementLabRoutedWayAcquisitionPlanner().prepare(
                wayID: way.id, routing: routing, environment: environment(rate: rate), sweep: sweep(rate: rate))
            let band = acquisition.binding.passband
            XCTAssertGreaterThanOrEqual(band.lowerBound, 400 * 1.5 - 1.0e-9, "\(rate)")
            XCTAssertLessThanOrEqual(band.upperBound, 3_000 / 1.5 + 1.0e-9, "\(rate)")
            XCTAssertGreaterThanOrEqual(acquisition.sweepProgram.settings.startFrequencyHz, band.lowerBound - 1.0e-9)
            XCTAssertLessThanOrEqual(acquisition.sweepProgram.settings.endFrequencyHz, band.upperBound + 1.0e-9)
            XCTAssertLessThanOrEqual(acquisition.provenance.inputPeakDBFS, -24)
            XCTAssertTrue(acquisition.provenance.validates(wayID: way.id))
            XCTAssertTrue(acquisition.provenance.limiterPreserved)
            XCTAssertEqual(acquisition.analysisProgram.sweepSamples, acquisition.sweepProgram.sweepSamples)
            XCTAssertEqual(
                acquisition.analysisProgram.tailFrames - acquisition.sweepProgram.tailFrames,
                acquisition.excitation.renderedSamples.count - acquisition.excitation.sourceFrameCount)
        }
    }

    func testBiAmpWaysCompileAtEveryRate() throws {
        for rate in Self.rates {
            let routing = try routing(.biAmp, rate: rate)
            for way in routing.speakers.flatMap(\.ways) {
                let acquisition = try SpeakerMeasurementLabRoutedWayAcquisitionPlanner().prepare(
                    wayID: way.id, routing: routing, environment: environment(rate: rate), sweep: sweep(rate: rate))
                XCTAssertFalse(acquisition.excitation.canDeploy)
                XCTAssertTrue(acquisition.excitation.measurementOnly)
                XCTAssertTrue(acquisition.excitation.renderedSamples.allSatisfy(\.isFinite))
            }
        }
    }

    // MARK: Refusals

    func testRefusalsNameTheirReason() throws {
        let rate = 48_000.0
        let routing = try routing(.triAmp, rate: rate)
        let way = midWay(routing)
        let planner = SpeakerMeasurementLabRoutedWayAcquisitionPlanner()
        func failure(_ routing: SpeakerRoutingConfiguration?, _ id: UUID, level: Double = -30,
                     env: SpeakerMeasurementLabRoutedWayEnvironment? = nil) -> SpeakerMeasurementLabRoutedWayError? {
            do {
                _ = try planner.prepare(
                    wayID: id, routing: routing, environment: env ?? environment(rate: rate), sweep: sweep(rate: rate, level: level))
                return nil
            } catch { return error as? SpeakerMeasurementLabRoutedWayError }
        }
        XCTAssertEqual(failure(nil, way.id), .routingRequired)
        XCTAssertEqual(failure(routing, UUID()), .wayNotFound)
        XCTAssertEqual(failure(routing, way.id, level: -10), .levelOutOfRange(-10))
        XCTAssertEqual(failure(routing, way.id, level: -60), .levelOutOfRange(-60))

        var unprotected = routing
        unprotected.speakers[0].ways[1].limiter = nil
        XCTAssertEqual(failure(unprotected, way.id), .wayNotProtected)
        var unlimited = routing
        unlimited.speakers[0].ways[1].highPass = nil
        unlimited.speakers[0].ways[1].lowPass = nil
        XCTAssertEqual(failure(unlimited, way.id), .wayNotProtected)

        var narrow = routing
        narrow.speakers[0].ways[1].highPass = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 1_000)
        narrow.speakers[0].ways[1].lowPass = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 2_000)
        XCTAssertEqual(failure(narrow, way.id), .noProtectedPassband)

        let missing = SpeakerMeasurementLabRoutedWayEnvironment(
            availableOutputs: [device("other")], sampleRate: rate, selectedOutputUID: "dev")
        guard case .endpointUnresolvable? = failure(routing, way.id, env: missing) else {
            return XCTFail("an unavailable device must be named")
        }
        let tooSmall = environment(rate: rate, devices: [device("dev", channels: 2)])
        guard case .endpointUnresolvable? = failure(routing, way.id, env: tooSmall) else {
            return XCTFail("a channel beyond the device must be refused")
        }
        for error in [SpeakerMeasurementLabRoutedWayError.wayChanged, .wayNotProtected, .levelOutOfRange(0)] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    // MARK: Binding

    func testBindingMapsEndpointToPhysicalChannel() throws {
        let rate = 96_000.0
        let routing = try routing(.triAmp, rate: rate)
        let planner = SpeakerMeasurementLabRoutedWayRoutePlanner()
        let ways = routing.speakers.flatMap(\.ways)
        XCTAssertEqual(ways.count, 6)
        for way in ways {
            let binding = try planner.plan(wayID: way.id, routing: routing, environment: environment(rate: rate))
            XCTAssertEqual(binding.physicalOutputChannelIndex, way.endpoint.channelIndex)
            XCTAssertEqual(binding.physicalDestination, way.endpoint)
            XCTAssertEqual(binding.carrierRoutePlan.orderedDeviceUIDs, ["dev"])
        }
        // Two devices: the second device's channels follow the first (selected) device's.
        var split = routing
        let moved = PhysicalOutputEndpoint(deviceUID: "usb", channelIndex: 1)
        split.speakers[0].ways[1].endpoint = moved
        let env = environment(rate: rate, devices: [device("dev", channels: 8), device("usb", channels: 4)])
        let binding = try planner.plan(wayID: split.speakers[0].ways[1].id, routing: split, environment: env)
        XCTAssertEqual(binding.physicalOutputChannelIndex, 8 + 1)
        XCTAssertEqual(binding.carrierRoutePlan.orderedDeviceUIDs, ["dev", "usb"])
        XCTAssertEqual(binding.carrierRoutePlan.physicalChannelCount, 12)
    }

    func testEditingTheWayAfterCompileFailsTheStartCheck() throws {
        let rate = 48_000.0
        let routing = try routing(.triAmp, rate: rate)
        let way = midWay(routing)
        let binding = try SpeakerMeasurementLabRoutedWayRoutePlanner().plan(
            wayID: way.id, routing: routing, environment: environment(rate: rate))
        XCTAssertTrue(binding.matchesCurrentState(routing: routing))
        XCTAssertFalse(binding.matchesCurrentState(routing: nil))

        var edited = routing
        edited.speakers[0].ways[1].limiter?.ceilingDB += 3
        XCTAssertFalse(binding.matchesCurrentState(routing: edited))
        var rerouted = routing
        rerouted.speakers[0].ways[1].endpoint = PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: 7)
        XCTAssertFalse(binding.matchesCurrentState(routing: rerouted))
        var off = routing
        off.enabled = false
        XCTAssertFalse(binding.matchesCurrentState(routing: off))
    }

    // MARK: Provenance and determinism

    func testProvenanceValidationRejectsTamperingAndIsDeterministic() throws {
        let rate = 48_000.0
        let routing = try routing(.triAmp, rate: rate)
        let way = midWay(routing)
        let planner = SpeakerMeasurementLabRoutedWayAcquisitionPlanner()
        let first = try planner.prepare(wayID: way.id, routing: routing, environment: environment(rate: rate), sweep: sweep(rate: rate))
        let second = try planner.prepare(wayID: way.id, routing: routing, environment: environment(rate: rate), sweep: sweep(rate: rate))
        XCTAssertEqual(first, second)

        var tampered = first.provenance
        XCTAssertFalse(tampered.validates(wayID: UUID()))
        tampered.way.limiter = nil
        XCTAssertFalse(tampered.validates(wayID: way.id))
        var hot = first.provenance
        hot.inputPeakDBFS = -10
        XCTAssertFalse(hot.validates(wayID: way.id))
        var inverted = first.provenance
        inverted.passbandHighHz = inverted.passbandLowHz
        XCTAssertFalse(inverted.validates(wayID: way.id))

        let data = try JSONEncoder().encode(first.provenance)
        XCTAssertEqual(try JSONDecoder().decode(SpeakerMeasurementLabRoutedWayCaptureProvenance.self, from: data), first.provenance)
    }

    // MARK: Capability

    private func routePlan() -> LiveNChannelOutputRoutePlan {
        var program = Array(repeating: UInt32.max, count: Int(N60_MAX_PROGRAM_CHANNELS))
        program[0] = 0
        program[1] = 1
        return LiveNChannelOutputRoutePlan(
            programLayout: .stereo, orderedDeviceUIDs: ["dev"], referenceDeviceUID: "dev",
            physicalChannelCount: 8, programPhysicalChannels: program,
            subwooferPhysicalChannels: Array(repeating: UInt32.max, count: Int(N60_MAX_SUBWOOFER_OUTPUTS)),
            subwooferCount: 0, bassManagementEnabled: false, speakerCalibrations: [:],
            subwooferCalibrations: Array(repeating: nil, count: Int(N60_MAX_SUBWOOFER_OUTPUTS)))
    }

    private func request(_ mode: SpeakerMeasurementLabMode, _ target: SpeakerMeasurementLabTarget) -> SpeakerMeasurementLabRequest {
        SpeakerMeasurementLabRequest(mode: mode, target: target, geometry: SpeakerMeasurementLabGeometry(distanceMeters: 0.03))
    }

    func testPlanStartsReadyWaysAndBlocksOthers() throws {
        let rate = 48_000.0
        let routing = try routing(.triAmp, rate: rate)
        let id = midWay(routing).id
        let planner = SpeakerMeasurementLabCapabilityPlanner()
        for (mode, target) in [
            (SpeakerMeasurementLabMode.driverNearField, SpeakerMeasurementLabTarget.routedWay(id)),
            (.protectedDriverNearField, .protectedRoutedWay(id)),
        ] {
            let plan = try planner.plan(
                request(mode, target), routePlan: routePlan(), multiOutputRouting: nil, speakerDriverProcessing: nil,
                speakerRouting: routing, routedWayEnvironment: environment(rate: rate))
            XCTAssertEqual(plan.blockReasons, [], "\(mode)")
            XCTAssertEqual(plan.protectedRoutedWayID, id)
            XCTAssertTrue(plan.canStartMeasurement)
        }
        var unprotected = routing
        unprotected.speakers[0].ways[1].limiter = nil
        let blocked = try planner.plan(
            request(.driverNearField, .routedWay(id)), routePlan: routePlan(), multiOutputRouting: nil,
            speakerDriverProcessing: nil, speakerRouting: unprotected, routedWayEnvironment: environment(rate: rate))
        XCTAssertEqual(blocked.blockReasons, [.routedWayAcquisitionUnavailable(id)])
        XCTAssertFalse(blocked.canStartMeasurement)

        let noEnvironment = try planner.plan(
            request(.driverNearField, .routedWay(id)), routePlan: routePlan(), multiOutputRouting: nil,
            speakerDriverProcessing: nil, speakerRouting: routing, routedWayEnvironment: nil)
        XCTAssertFalse(noEnvironment.canStartMeasurement)
        XCTAssertFalse(noEnvironment.blockReasons.isEmpty)
    }
}
