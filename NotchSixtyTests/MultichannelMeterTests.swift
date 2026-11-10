import XCTest
@testable import NotchSixty

/// E28 S6: per-output meters for every session shape. A -6 dBFS tone on one output shows on that output's card only,
/// and a sub over-range latches only the sub's card. The bank ingestion is the production one; the channel dictionaries
/// are built by the same encoders the hub uses.
@MainActor
final class MultichannelMeterTests: XCTestCase {
    private static let layouts: [(name: String, outputs: Int)] = [
        ("2.0", 2), ("2.1", 3), ("5.1", 6), ("7.1", 8), ("7.1.4", 12), ("one-DAC 2.1", 3),
    ]

    private func tone(_ dBFS: Double) -> Float { Float(pow(10.0, dBFS / 20.0)) }

    private func ingestTwice(_ bank: MeterBankDisplay, _ readings: [String: MeterChannelReading]) {
        bank.ingest(readings, mode: .peak, now: 0)
        bank.ingest(readings, mode: .peak, now: 0.016)
    }

    func testToneOnOneOutputShowsOnThatCardOnly() {
        for layout in Self.layouts {
            for target in 0..<layout.outputs {
                let bank = MeterBankDisplay()
                var readings: [String: MeterChannelReading] = [:]
                for index in 0..<layout.outputs {
                    _ = bank.channel(id: "out.\(index)", label: "Ch\(index)")
                    let level: Float = index == target ? tone(-6) : 0
                    readings["out.\(index)"] = MeterChannelReading(
                        peakLinear: level, rmsLinear: level * 0.7, overRangeSamples: 0, truePeakLinear: nil)
                }
                ingestTwice(bank, readings)
                for index in 0..<layout.outputs {
                    let shown = bank.channel(id: "out.\(index)", label: "").displayedDB
                    if index == target {
                        XCTAssertEqual(shown, -6, accuracy: 0.05, "\(layout.name) output \(index)")
                    } else {
                        XCTAssertLessThanOrEqual(shown, MeterBallisticsState.floorDB + 0.01, "\(layout.name) output \(index) must stay silent for a tone on \(target)")
                    }
                }
            }
        }
    }

    func testSubOverRangeLatchesOnlyTheSubCard() {
        let bank = MeterBankDisplay()
        let ids = ["out.0", "out.1", "out.2"]
        for id in ids { _ = bank.channel(id: id, label: id) }
        // Over-range counters are cumulative: the latch trips when a counter rises between polls.
        func readings(subCount: UInt64) -> [String: MeterChannelReading] {
            var result: [String: MeterChannelReading] = [:]
            for id in ids {
                result[id] = MeterChannelReading(
                    peakLinear: tone(-12), rmsLinear: tone(-15),
                    overRangeSamples: id == "out.2" ? subCount : 0, truePeakLinear: nil)
            }
            return result
        }
        bank.ingest(readings(subCount: 0), mode: .peak, now: 0)
        bank.ingest(readings(subCount: 7), mode: .peak, now: 0.016)
        XCTAssertFalse(bank.channel(id: "out.0", label: "").isClipped)
        XCTAssertFalse(bank.channel(id: "out.1", label: "").isClipped)
        XCTAssertTrue(bank.channel(id: "out.2", label: "").isClipped)
    }

    func testRouteChannelsCarryEachRoutesOwnReading() {
        let routes = [
            ProductionRouteMeter(id: SpeakerRouteMeterNaming.channelID(busRawValue: 0, physicalChannel: 0), label: "Left",
                                 physicalChannel: 0, peakLinear: 0.5, rmsLinear: 0.3, overRangeSamples: 0),
            ProductionRouteMeter(id: SpeakerRouteMeterNaming.channelID(busRawValue: 8, physicalChannel: 2), label: "Sub",
                                 physicalChannel: 2, peakLinear: 1.2, rmsLinear: 0.9, overRangeSamples: 4),
        ]
        let channels = MultichannelMeterChannels.channels(routes: routes, protection: [])
        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels["route-0-ch0"]?.peakLinear, 0.5)
        XCTAssertEqual(channels["route-0-ch0"]?.overRangeSamples, 0)
        XCTAssertEqual(channels["route-8-ch2"]?.overRangeSamples, 4)
        XCTAssertEqual(SpeakerRouteMeterNaming.label(busRawValue: 8), "Sub")
        XCTAssertEqual(SpeakerRouteMeterNaming.label(busRawValue: 3), "Right Low")
    }

    func testProtectionEncodingRoundTripsThroughTheHub() {
        let readings = [
            UnifiedGraphOutputProtectionReading(
                lane: 0, userGainReductionDB: 2.5, userTruePeakLinear: 0.8,
                hardLimitGainReductionDB: 0.5, outputTruePeakLinear: 0.9),
            UnifiedGraphOutputProtectionReading(
                lane: 2, userGainReductionDB: nil, userTruePeakLinear: nil,
                hardLimitGainReductionDB: 0, outputTruePeakLinear: 0.1),
        ]
        let channels = MultichannelMeterChannels.channels(routes: [], protection: readings)
        XCTAssertNil(channels["protect.2.user"], "no user stage, no user channel")
        let back = MultichannelMeterChannels.protectionReadings(from: channels, lanes: [0, 1, 2])
        XCTAssertEqual(back[0], readings[0])
        XCTAssertEqual(back[2], readings[1])
        XCTAssertNil(back[1], "a lane without a reading is absent")
    }

    func testHubTakeKeepsMaximumAcrossPollsForProtection() {
        var calls = 0
        let visible = AlwaysVisible()
        let hub = MeterReadbackHub<Int>(
            visibility: visible,
            isProcessing: { true },
            source: {
                calls += 1
                let gr: Float = calls == 1 ? 6 : 1
                return MeterFrame(
                    channels: MultichannelMeterChannels.channels(routes: [], protection: [
                        UnifiedGraphOutputProtectionReading(
                            lane: 0, userGainReductionDB: nil, userTruePeakLinear: nil,
                            hardLimitGainReductionDB: gr, outputTruePeakLinear: 0.5)]),
                    context: calls)
            })
        let token = hub.subscribe(hertz: 1000)
        _ = hub.pollOnce()
        _ = hub.pollOnce()
        let taken = hub.take(token)
        XCTAssertEqual(taken["protect.0.hard"]?.peakLinear, 6, "the larger reduction survives the quieter poll")
        hub.unsubscribe(token)
        withExtendedLifetime(visible) {}
    }

    func testRouteLabelsCoverEveryBus() {
        for bus in 0...8 {
            XCTAssertFalse(SpeakerRouteMeterNaming.label(busRawValue: UInt32(bus)).hasPrefix("Bus"))
        }
        XCTAssertNotEqual(
            SpeakerRouteMeterNaming.channelID(busRawValue: 0, physicalChannel: 0),
            SpeakerRouteMeterNaming.channelID(busRawValue: 0, physicalChannel: 1))
    }
}

private final class AlwaysVisible: MeterVisibilityProviding {
    var metersAreVisible: Bool { true }
}
