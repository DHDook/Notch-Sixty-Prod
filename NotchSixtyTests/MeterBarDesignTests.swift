import XCTest
@testable import NotchSixty

/// E33 S6 (design 16): zones, colours, readouts, hold, scale, named resets, the stopped state, the spoken-value
/// rate limit and the gain-reduction bars of multiband bands 4 and 5.
@MainActor
final class MeterBarDesignTests: XCTestCase {
    // MARK: Zones

    func testZoneOfEachLevelBoundary() {
        XCTAssertEqual(MeterZone.zone(forDB: -60), .quiet)
        XCTAssertEqual(MeterZone.zone(forDB: -18.01), .quiet)
        XCTAssertEqual(MeterZone.zone(forDB: -18), .signal)
        XCTAssertEqual(MeterZone.zone(forDB: -6.01), .signal)
        XCTAssertEqual(MeterZone.zone(forDB: -6), .hot)
        XCTAssertEqual(MeterZone.zone(forDB: -3.01), .hot)
        XCTAssertEqual(MeterZone.zone(forDB: -3), .over)
        XCTAssertEqual(MeterZone.zone(forDB: 0), .over)
        XCTAssertEqual(MeterZone.allCases.map(\.lowerBoundDB), [nil, -18, -6, -3])
        XCTAssertEqual(MeterZone.allCases.map(\.hatchDirections), [0, 0, 1, 2], "hot is hatched, over is cross-hatched")
    }

    func testAdjacentZoneColoursKeepLuminanceContrastUnderColourBlindness() {
        for deficiency in MeterPalette.Deficiency.allCases {
            let zones = MeterZone.allCases
            for (a, b) in zip(zones, zones.dropFirst()) {
                let ratio = MeterPalette.contrastRatio(
                    MeterPalette.simulated(MeterPalette.color(a), deficiency),
                    MeterPalette.simulated(MeterPalette.color(b), deficiency))
                XCTAssertGreaterThanOrEqual(ratio, MeterPalette.minimumAdjacentContrast, "\(a) vs \(b) under \(deficiency)")
            }
        }
    }

    func testContrastRatioEndpoints() {
        XCTAssertEqual(MeterPalette.contrastRatio((0, 0, 0), (1, 1, 1)), 21, accuracy: 0.001)
        XCTAssertEqual(MeterPalette.contrastRatio((0.5, 0.5, 0.5), (0.5, 0.5, 0.5)), 1, accuracy: 1e-9)
    }

    // MARK: Readout, scale

    func testNumericPeakReadout() {
        XCTAssertEqual(MeterReadout.peakText(-7.26, floorDB: -60), "-7.3")
        XCTAssertEqual(MeterReadout.peakText(-60, floorDB: -60), "\u{2014}")
        XCTAssertEqual(MeterReadout.peakText(-80, floorDB: -96), "-80.0")
        XCTAssertEqual(MeterReadout.peakText(-96, floorDB: -96), "\u{2014}")
    }

    func testScaleChoicesAndDefault() {
        XCTAssertEqual(MeterScaleChoice.allCases.map(\.floorDB), [-60, -96, -120])
        XCTAssertEqual(MeterScaleChoice.default, .minus60)
        let defaults = UserDefaults(suiteName: "MeterBarDesignTests.\(UUID().uuidString)")!
        XCTAssertEqual(MeterScaleChoice.stored(defaults), .minus60)
        MeterScaleChoice.minus120.store(defaults)
        XCTAssertEqual(MeterScaleChoice.stored(defaults), .minus120)
        XCTAssertEqual(MeterHoldChoice.stored(defaults), .twoSeconds)
        MeterHoldChoice.untilReset.store(defaults)
        XCTAssertEqual(MeterHoldChoice.stored(defaults), .untilReset)
    }

    func testScaleLowersTheFloorOfTheDisplayedLevelAndTheReadout() {
        let channel = MeterChannelDisplay(id: "x", label: "L")
        channel.configure(floorDB: -96, holdSeconds: 2, zones: true)
        // -80 dBFS = 1e-4 linear: below the default floor, above the -96 floor.
        let reading = MeterChannelReading(peakLinear: 1e-4, rmsLinear: 1e-4, overRangeSamples: nil, truePeakLinear: nil)
        channel.ingest(reading, mode: .peak, elapsed: 0.016, now: 0)
        XCTAssertEqual(channel.displayedDB, -80, accuracy: 0.01)
        let plain = MeterChannelDisplay(id: "y", label: "L")
        plain.ingest(reading, mode: .peak, elapsed: 0.016, now: 0)
        XCTAssertEqual(plain.displayedDB, -60, accuracy: 0.001, "flag off: the -60 floor")
    }

    // MARK: Hold

    func testOneHoldTimeDrivesBothHoldsAndInfiniteHoldsUntilReset() {
        XCTAssertEqual(MeterHoldChoice.allCases.map(\.seconds), [1, 2, 5, .infinity])
        for choice in [MeterHoldChoice.oneSecond, .fiveSeconds, .untilReset] {
            var level = MeterPeakHold()
            level.holdSeconds = choice.seconds
            level.advance(displayedDB: -6, elapsed: 0.1)
            level.advance(displayedDB: -40, elapsed: choice.seconds.isFinite ? choice.seconds - 0.5 : 1_000)
            XCTAssertEqual(level.heldDB, -6, "\(choice): still held")
            level.advance(displayedDB: -40, elapsed: 1)
            let levelExpired = level.heldDB == -40

            let monitor = GainReductionMonitor(hub: { nil }, clock: { 0 })
            monitor.setHold(seconds: choice.seconds)
            func reading(_ db: Float) -> [String: MeterChannelReading] {
                [GainReductionSource.compressor.channelID: MeterChannelReading(peakLinear: db, rmsLinear: 0, overRangeSamples: nil, truePeakLinear: nil)]
            }
            monitor.ingest(reading(12), now: 10)
            monitor.ingest(reading(0), now: 10 + (choice.seconds.isFinite ? choice.seconds - 0.5 : 1_000))
            XCTAssertEqual(monitor.history(.compressor).held(at: 10 + (choice.seconds.isFinite ? choice.seconds - 0.5 : 1_000)), 12, "\(choice): GR still held")
            monitor.ingest(reading(0), now: 10 + (choice.seconds.isFinite ? choice.seconds + 0.5 : 2_000))
            let grExpired = monitor.history(.compressor).held(at: 10 + (choice.seconds.isFinite ? choice.seconds + 0.5 : 2_000)) == 0
            XCTAssertEqual(levelExpired, choice.seconds.isFinite, "\(choice) level hold")
            XCTAssertEqual(grExpired, choice.seconds.isFinite, "\(choice) GR hold")
        }
    }

    // MARK: Named resets

    private func hot(_ bank: MeterBankDisplay) -> MeterChannelDisplay {
        let channel = bank.channel(id: "c", label: "L")
        channel.ingest(MeterChannelReading(peakLinear: 1, rmsLinear: 1, overRangeSamples: 5, truePeakLinear: nil), mode: .peak, elapsed: 0, now: 0)
        channel.ingest(MeterChannelReading(peakLinear: 1, rmsLinear: 1, overRangeSamples: 9, truePeakLinear: nil), mode: .peak, elapsed: 0.1, now: 0.1)
        return channel
    }

    func testEachNamedResetClearsOnlyItsTarget() {
        let bank = MeterBankDisplay()
        let channel = hot(bank)
        XCTAssertTrue(channel.isClipped)
        XCTAssertEqual(channel.heldDB, 0, accuracy: 0.01)

        bank.reset(.clipLatches)
        XCTAssertFalse(channel.isClipped)
        XCTAssertEqual(channel.heldDB, 0, accuracy: 0.01, "clip reset leaves the hold")

        let bank2 = MeterBankDisplay()
        let channel2 = hot(bank2)
        bank2.reset(.peakHold)
        XCTAssertTrue(channel2.isClipped, "hold reset leaves the latch")
        XCTAssertEqual(channel2.heldDB, MeterBallisticsState.floorDB)

        // Loudness and true-peak max are not level-bank state.
        let bank3 = MeterBankDisplay()
        let channel3 = hot(bank3)
        bank3.reset(.loudness)
        bank3.reset(.truePeakMax)
        XCTAssertTrue(channel3.isClipped)
        XCTAssertEqual(channel3.heldDB, 0, accuracy: 0.01)

        var truePeak = TruePeakMaxHold()
        truePeak.update(dbtp: -1)
        XCTAssertEqual(truePeak.maxDBTP, -1)
        truePeak.reset()
        XCTAssertNil(truePeak.maxDBTP)
    }

    func testPeakHoldResetClearsTheGainReductionHoldButNotTheBar() {
        let monitor = GainReductionMonitor(hub: { nil }, clock: { 0 })
        let r = [GainReductionSource.limiter.channelID: MeterChannelReading(peakLinear: 9, rmsLinear: 0, overRangeSamples: nil, truePeakLinear: nil)]
        monitor.ingest(r, now: 1)
        let quiet = [GainReductionSource.limiter.channelID: MeterChannelReading(peakLinear: 3, rmsLinear: 0, overRangeSamples: nil, truePeakLinear: nil)]
        monitor.ingest(quiet, now: 1.05)
        XCTAssertEqual(monitor.history(.limiter).held(at: 1.05), 9)
        monitor.resetHolds()
        XCTAssertEqual(monitor.history(.limiter).held(at: 1.05), 3, "the hold is gone, the latest value stays")
    }

    // MARK: Stopped state

    func testEveryMeterPageShowsTheStoppedStateWhenStopped() {
        for page in ProductionMetersPage.allCases {
            XCTAssertTrue(MeterStoppedPolicy.showsStoppedState(isRunning: false, page: page), "\(page)")
            XCTAssertFalse(MeterStoppedPolicy.showsStoppedState(isRunning: true, page: page), "\(page)")
        }
    }

    // MARK: Spoken values

    func testSpokenValueRateLimit() {
        var throttle = SpokenValueThrottle()
        XCTAssertEqual(throttle.offer("-23.0 LUFS", number: -23.0, now: 0), "-23.0 LUFS")
        XCTAssertEqual(throttle.offer("-22.6 LUFS", number: -22.6, now: 0.5), "-23.0 LUFS", "small move inside 2 s waits")
        XCTAssertEqual(throttle.offer("-21.9 LUFS", number: -21.9, now: 1.0), "-21.9 LUFS", "a 1 LU move speaks at once")
        XCTAssertEqual(throttle.offer("-21.5 LUFS", number: -21.5, now: 2.5), "-21.9 LUFS", "2 s counts from the last spoken value")
        XCTAssertEqual(throttle.offer("-21.5 LUFS", number: -21.5, now: 3.1), "-21.5 LUFS", "2 s later it speaks")
    }

    // MARK: Gain reduction of bands 4 and 5 (G19)

    func testGainReductionSourcesCoverBandsFourAndFive() {
        XCTAssertTrue(GainReductionSource.allCases.contains(.multibandBand4))
        XCTAssertTrue(GainReductionSource.allCases.contains(.multibandBand5))
        var raw = N60RenderKernelDiagnostics()
        raw.multibandBand4GainReductionDB = 4.5
        raw.multibandBand5GainReductionDB = 7.5
        let channels = GainReductionSource.channels(from: RenderKernelDiagnostics(raw))
        XCTAssertEqual(channels[GainReductionSource.multibandBand4.channelID]?.peakLinear, 4.5)
        XCTAssertEqual(channels[GainReductionSource.multibandBand5.channelID]?.peakLinear, 7.5)
        let monitor = GainReductionMonitor(hub: { nil }, clock: { 0 })
        monitor.ingest(channels, now: 1)
        XCTAssertEqual(monitor.latest(.multibandBand5), 7.5)
    }

    func testTransferCurveForBandsFourAndFiveReadsTheExtraBandSettings() {
        var multiband = MultibandCompressorConfiguration()
        multiband.setBandCount(5)
        var extra = MultibandExtraBandConfiguration()
        extra.thresholdDB = -30
        extra.ratio = 6
        multiband[extraBand: 4] = extra
        let curve = DynamicsTransferCurve(multiband, band: 4)
        XCTAssertEqual(curve.thresholdDB, -30)
        XCTAssertEqual(curve.ratio, 6)
    }
}
