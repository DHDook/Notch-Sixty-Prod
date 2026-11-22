import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S12: the Dashboard status page. The view model is pure, so each card, health item and attention item is driven
/// with synthetic inputs; one hosted test checks the page fits at the two reference sizes.
@MainActor
final class DashboardStatusPageTests: XCTestCase {
    private func card(_ id: String, _ i: DashboardInputs) -> DashboardCard {
        DashboardModel.cards(i).first { $0.id == id }!
    }

    // MARK: Cards

    func testCardsForStereoRoutedHeadphoneFiveOneAndFaultedStates() {
        var stereo = DashboardInputs()
        stereo.lifecycle = .running
        stereo.bassManagementEnabled = true
        stereo.crossoverHz = 80
        stereo.crossoverName = "LR4"
        XCTAssertEqual(card("path", stereo).line, "Stereo speakers")
        XCTAssertTrue(card("path", stereo).isOn)
        XCTAssertEqual(card("speakers", stereo).line, "Stereo · 80 Hz LR4")

        var routed = stereo
        routed.routing = DashboardRouting(speakers: 3, ways: 7)
        XCTAssertEqual(card("speakers", routed).line, "3 speakers · 7 ways")
        routed.routing = DashboardRouting(speakers: 1, ways: 1)
        XCTAssertEqual(card("speakers", routed).line, "1 speaker · 1 way")

        var phones = DashboardInputs()
        phones.path = .headphones
        XCTAssertEqual(card("path", phones).line, "Headphones · Stereo")
        phones.path = .virtualHeadphones(layout: "5.1")
        XCTAssertEqual(card("path", phones).line, "Virtual 5.1 → Headphones")

        var five = DashboardInputs()
        five.path = .multichannel(system: "5.1")
        five.systemName = "5.1"
        XCTAssertEqual(card("path", five).line, "5.1")
        XCTAssertEqual(card("speakers", five).line, "5.1 · Bass management off")
        XCTAssertFalse(card("speakers", five).isOn)

        var faulted = DashboardInputs()
        faulted.lifecycle = .failed
        faulted.acoustics = .faulted
        XCTAssertFalse(card("path", faulted).isOn)
        XCTAssertEqual(card("acoustics", faulted).line, "Stopped safely after a problem")
    }

    func testCardTextIsPlainAndNeverMentionsFramesOrHardwareGates() {
        let states: [DashboardAcoustics] = [.faulted, .active(sources: 4), .transitioning(percent: 40), .ready, .staged, .notSetUp]
        for state in states {
            let line = DashboardModel.acousticsLine(state).lowercased()
            XCTAssertFalse(line.contains("frames"), line)
            XCTAssertFalse(line.contains("hardware-gated"), line)
        }
        XCTAssertEqual(DashboardModel.acousticsLine(.active(sources: 4)), "On · 4 sources")
    }

    func testDynamicsShowsThreeNamesThenAndNMore() {
        XCTAssertEqual(DashboardModel.dynamicsLine([]), "Nothing switched on")
        XCTAssertEqual(DashboardModel.dynamicsLine(["A", "B", "C"]), "A · B · C")
        XCTAssertEqual(DashboardModel.dynamicsLine(["A", "B", "C", "D", "E"]), "A · B · C and 2 more")
        var i = DashboardInputs()
        i.dynamicsNames = ["A", "B", "C", "D"]
        XCTAssertTrue(card("dynamics", i).isOn)
    }

    func testCorrectionAndEqualizerLines() {
        var i = DashboardInputs()
        XCTAssertEqual(card("correction", i).line, "No correction measured yet")
        i.correctionFilterName = "Living room"
        XCTAssertEqual(card("correction", i).line, "Living room is loaded but off")
        XCTAssertFalse(card("correction", i).isOn)
        i.correctionEnabled = true
        XCTAssertEqual(card("correction", i).line, "Living room")
        i.eqBandCount = 5
        i.eqPhaseName = "Minimum phase"
        XCTAssertEqual(card("eq", i).line, "5 bands · Minimum phase")
    }

    func testEveryCardOpensItsPageAndCarriesNoSwitch() {
        let cards = DashboardModel.cards(DashboardInputs())
        XCTAssertEqual(cards.map(\.id), ["path", "eq", "dynamics", "speakers", "correction", "acoustics"])
        let sections = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.destination.section) })
        XCTAssertEqual(sections["eq"], .equalizer)
        XCTAssertEqual(sections["dynamics"], .dynamics)
        XCTAssertEqual(sections["speakers"], .speakers)
        XCTAssertEqual(sections["correction"], .roomCorrection)
        XCTAssertEqual(sections["acoustics"], .activeAcoustics)
        XCTAssertEqual(sections["path"], .system)
    }

    func testNavigationFromACardLandsOnItsSectionAndMetersRequestIsTakenOnce() {
        let navigation = ProductionNavigation()
        let destination = DashboardModel.attention({ var i = DashboardInputs(); i.lastError = "boom"; return i }())[0].destination
        navigation.requestedMetersPage = destination.metersPage
        navigation.navigate(to: destination.section)
        XCTAssertEqual(navigation.selection, .meters)
        XCTAssertEqual(navigation.requestedMetersPage, .transport)
        navigation.requestedMetersPage = nil
        XCTAssertNil(navigation.requestedMetersPage)
    }

    // MARK: Attention

    func testEachAttentionItemAppearsAndClears() {
        var i = DashboardInputs()
        XCTAssertTrue(DashboardModel.attention(i).isEmpty)

        i.failsafeMessage = "Default output feeds drivers."
        XCTAssertEqual(DashboardModel.attention(i).map(\.kind), [.activeSpeakerFailsafe])
        XCTAssertEqual(DashboardModel.attention(i)[0].destination.section, .speakers)
        i.failsafeMessage = nil
        XCTAssertTrue(DashboardModel.attention(i).isEmpty)

        i.lifecycle = .recoveringOutput
        i.outputName = "Studio DAC"
        let waiting = DashboardModel.attention(i)
        XCTAssertEqual(waiting.map(\.kind), [.waitingForDevice])
        XCTAssertEqual(waiting[0].text, "Waiting for Studio DAC to come back.")
        i.lifecycle = .running
        XCTAssertTrue(DashboardModel.attention(i).isEmpty)

        i.lastError = "Output failed"
        XCTAssertEqual(DashboardModel.attention(i).map(\.kind), [.engineError])
        i.lastError = ""
        XCTAssertTrue(DashboardModel.attention(i).isEmpty)

        i.eventsInLastDay = 3
        let events = DashboardModel.attention(i)
        XCTAssertEqual(events.map(\.kind), [.sessionEvents])
        XCTAssertEqual(events[0].text, "3 events in the last day.")
        XCTAssertEqual(events[0].destination, DashboardDestination(.meters, metersPage: .transport))
        XCTAssertFalse(events[0].isWarning)
        i.eventsInLastDay = 1
        XCTAssertEqual(DashboardModel.attention(i)[0].text, "1 event in the last day.")
    }

    func testAttentionOrderPutsWarningsBeforeTheEventLine() {
        var i = DashboardInputs()
        i.eventsInLastDay = 2
        i.lastError = "x"
        i.failsafeMessage = "y"
        i.lifecycle = .recoveringOutput
        XCTAssertEqual(DashboardModel.attention(i).map(\.kind),
                       [.activeSpeakerFailsafe, .waitingForDevice, .engineError, .sessionEvents])
    }

    // MARK: Now playing and health

    func testNowPlayingShowsValuesOnly() {
        var i = DashboardInputs()
        i.presetName = "Film"
        i.presetDirty = true
        i.outputName = "Studio DAC"
        i.sampleRate = 96_000
        i.volumeReadout = "-24.0 dB"
        i.switchReason = "Switched because the headphones connected."
        let n = DashboardModel.nowPlaying(i)
        XCTAssertEqual(n.title, "Film")
        XCTAssertTrue(n.unsavedMark)
        XCTAssertEqual(n.reason, "Switched because the headphones connected.")
        XCTAssertEqual(n.output, "Studio DAC")
        XCTAssertEqual(n.sampleRate, "96 kHz")
        XCTAssertEqual(n.volume, "-24.0 dB")
        i.muted = true
        XCTAssertEqual(DashboardModel.nowPlaying(i).volume, "Muted")
        XCTAssertEqual(DashboardModel.sampleRateText(44_100), "44.1 kHz")
        XCTAssertEqual(DashboardModel.sampleRateText(352_800), "352.8 kHz")
        XCTAssertEqual(DashboardModel.sampleRateText(nil), "—")
        XCTAssertTrue(DashboardModel.make(DashboardInputs()).needsOutput)
    }

    func testHealthStripReportsWhatTheEngineKnowsAndMarksTheRest() {
        var i = DashboardInputs()
        var h = DashboardModel.health(i)
        XCTAssertEqual(h.map(\.id), ["clipping", "limiter", "headroom", "load", "dropouts", "latency"])
        XCTAssertEqual(h.first { $0.id == "load" }?.state, .unreported)
        XCTAssertEqual(h.first { $0.id == "headroom" }?.state, .unreported)
        XCTAssertEqual(h.first { $0.id == "clipping" }?.value, "None")

        i.clippedSamples = 12
        i.peakLimiterReductionDB = 4.5
        i.remainingHeadroomDB = 0.4
        i.meanLoad = 0.2
        i.peakLoad = 0.85
        i.dropoutEvents = 2
        i.latencyMilliseconds = 12.34
        h = DashboardModel.health(i)
        func item(_ id: String) -> DashboardHealthItem { h.first { $0.id == id }! }
        XCTAssertEqual(item("clipping").value, "12 samples")
        XCTAssertEqual(item("clipping").state, .warning)
        XCTAssertEqual(item("limiter").value, "Up to 4.5 dB")
        XCTAssertEqual(item("limiter").state, .warning)
        XCTAssertEqual(item("headroom").state, .warning)
        XCTAssertEqual(item("load").value, "20% (peak 85%)")
        XCTAssertEqual(item("load").state, .warning)
        XCTAssertEqual(item("dropouts").value, "2")
        XCTAssertEqual(item("latency").value, "12.3 ms")
    }

    func testSessionHealthTotalsAccumulateAndReset() {
        var totals = SessionHealthTotals()
        XCTAssertNil(totals.remainingHeadroomDB)
        var a = SessionEventSample(now: Date(timeIntervalSince1970: 0))
        a.clipSamples = ["Output L": 3, "Output R": 2]
        a.limiterReductionDB = 2
        a.outputPeakLinear = 0.5
        var b = SessionEventSample(now: Date(timeIntervalSince1970: 1))
        b.limiterReductionDB = 1
        b.outputPeakLinear = 0.25
        totals.observe(a)
        totals.observe(b)
        XCTAssertEqual(totals.clippedSamples, 5)
        XCTAssertEqual(totals.peakLimiterReductionDB, 2)
        XCTAssertEqual(totals.limiterActivePolls, 2)
        XCTAssertEqual(try XCTUnwrap(totals.remainingHeadroomDB), 20 * log10(2.0), accuracy: 1e-9)
        totals.reset()
        XCTAssertEqual(totals, SessionHealthTotals())
    }

    func testHistoryFeedsTotalsAndStoppingClearsThem() {
        let history = SessionEventHistory(store: nil)
        var s = SessionEventSample(now: Date(timeIntervalSince1970: 100))
        s.clipSamples = ["Output L": 4]
        s.outputPeakLinear = 1
        history.observe(s)
        XCTAssertEqual(history.health.clippedSamples, 4)
        XCTAssertEqual(try XCTUnwrap(history.health.remainingHeadroomDB), 0, accuracy: 1e-9)
        history.noteStopped()
        XCTAssertEqual(history.health, SessionHealthTotals())
    }

    func testSampleBuilderReadsOutputPeakFromOutputChannelsOnly() {
        let channels: [String: MeterChannelReading] = [
            "output.L": MeterChannelReading(peakLinear: 0.4, rmsLinear: 0.1, overRangeSamples: 0, truePeakLinear: nil),
            "output.truePeak": MeterChannelReading(peakLinear: 0.7, rmsLinear: 0, overRangeSamples: nil, truePeakLinear: 0.7),
            "input.L": MeterChannelReading(peakLinear: 0.99, rmsLinear: 0.1, overRangeSamples: 0, truePeakLinear: nil),
        ]
        let diagnostics = AudioIOEngine().diagnosticsSnapshot()
        let sample = SessionEventSample.make(channels: channels, diagnostics: diagnostics, protection: [], now: Date())
        XCTAssertEqual(sample.outputPeakLinear, 0.7, accuracy: 1e-6)
    }

    // MARK: Volume text

    func testVolumeReadoutIsAValueInBothModes() {
        XCTAssertEqual(DashboardModel.volumeReadout(level: 0.5, softwareControl: false, usesDecibels: false), "50.0%")
        let software = DashboardModel.volumeReadout(level: 0.5, softwareControl: true, usesDecibels: false)
        XCTAssertTrue(software.hasPrefix("50.0% · "), software)
        let db = DashboardModel.volumeReadout(level: 0.5, softwareControl: true, usesDecibels: true)
        XCTAssertTrue(db.contains("dB"), db)
    }

    // MARK: Flag and hosting

    func testFlagIsRegisteredDarkAndReleaseIgnoresStoredOverrides() {
        XCTAssertTrue(FeatureFlag.all.contains(.dashboardRemote))
        XCTAssertEqual(FeatureFlag.dashboardRemote.id, "e12.dashboard-remote")
        XCTAssertFalse(FeatureFlag.dashboardRemote.resolvedDefault)
        let defaults = UserDefaults(suiteName: "e12.dashboard.\(UUID().uuidString)")!
        let release = FeatureFlags(known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly, arguments: [], environment: [:])
        XCTAssertFalse(release.isEnabled(.dashboardRemote))
        let on = FeatureFlags(known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly, arguments: ["-NotchSixtyFeatures", "e12.dashboard-remote"], environment: [:])
        XCTAssertTrue(on.isEnabled(.dashboardRemote))
    }

    func testStatusPageFitsAtBothReferenceSizes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            let page = HostedPage(
                ProductionStatusDashboardView(
                    engine: engine, profiles: profiles, navigation: ProductionNavigation(), failsafeMessage: "Check the default output."),
                size: size)
            XCTAssertLessThanOrEqual(page.hosting.fittingSize.width, size.width, "page wider than \(size.width)")
            for control in page.controls {
                let frame = control.view.convert(control.view.bounds, to: page.hosting)
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(control.label) extends past the page at \(size.width)")
            }
            // The everyday controls left the Dashboard (they live in the menu bar panel).
            XCTAssertNil(page.controls(of: .slider).first, "no slider on the status page")
            XCTAssertNil(page.controls(of: .popup).first, "no output picker on the status page")
        }
    }
}
