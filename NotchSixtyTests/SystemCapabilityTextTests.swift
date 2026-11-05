import XCTest
@testable import NotchSixty

/// E25 S5: every surface's capability text comes from the matrix, per arrangement class A to E.
final class SystemCapabilityTextTests: XCTestCase {
    private func profile(_ bass: BassHandling, layout: OutputProgramLayout = .stereo, channels: Int = 2) -> PlaybackSystemProfile {
        var state = PlaybackSystemState()
        state.systemArrangement = SystemSetupArrangementPlanner.arrangement(
            deviceUID: "d", detectedChannelCount: 8, channelsInUse: channels,
            choices: .init(layout: layout, bass: bass, subwooferCount: bass == .dspToSubOutputs || bass.isDownstream ? 1 : 0))
        return PlaybackSystemProfile(name: "T", state: state)
    }

    private var classes: [(String, PlaybackSystemProfile)] {
        [("A", profile(.dspToSubOutputs, layout: .fiveOne, channels: 6)),
         ("B", profile(.fullRange)),
         ("C", profile(.dspMonoToMains)),
         ("D", profile(.downstreamSubCrossover)),
         ("E", profile(.downstreamReceiver, layout: .fiveOne))]
    }

    private let surfaces: [(String, [SystemFeature])] = [
        ("speakers", SystemCapabilityText.speakersTabFeatures), ("routing", SystemCapabilityText.routingEditorFeatures),
        ("headphones", SystemCapabilityText.headphoneFeatures), ("advisor", SystemCapabilityText.advisorFeatures),
        ("profile", SystemCapabilityText.profileFeatures),
    ]

    func testEverySurfaceReadsTheMatrixForEveryClass() {
        for (name, p) in classes {
            let a = SystemCapabilityText.arrangement(for: p)!
            for (surface, features) in surfaces {
                let rows = SystemCapabilityText.rows(features, profile: p, deviceChannelCount: 8)
                XCTAssertEqual(rows.map(\.feature), features, "\(surface) class \(name)")
                for row in rows {
                    XCTAssertEqual(row.availability,
                                   SystemCapabilityMatrix.evaluate(row.feature, arrangement: a, deviceChannelCount: 8))
                    XCTAssertFalse(row.availability.text.isEmpty)
                }
            }
        }
    }

    func testNoArrangementShowsNothing() {
        XCTAssertTrue(SystemCapabilityText.rows(SystemCapabilityText.speakersTabFeatures, profile: nil).isEmpty)
    }

    func testReceiverReasonsAndRoutingRefusalOnTwoChannels() {
        let d = SystemCapabilityText.rows([.subAlignment, .speakerRoutingEditor], profile: profile(.downstreamSubCrossover))
        XCTAssertEqual(d[0].availability.text, SystemCapabilityMatrix.receiverSetsBass)
        XCTAssertFalse(d[1].availability.isUsable)
        let a = SystemCapabilityText.rows([.speakerRoutingEditor], profile: classes[0].1)
        XCTAssertTrue(a[0].availability.isUsable)
    }

    func testArrangementSentenceRecordsDownstreamBass() {
        let e = SystemCapabilityText.arrangement(for: profile(.downstreamReceiver, layout: .fiveOne))!
        let text = SystemCapabilityText.arrangementSentence(e)
        XCTAssertTrue(text.contains("5.1") && text.contains("two output channels") && text.contains("receiver"), text)
    }

    func testProfileRequiredReasonPerClass() {
        let old = "Enable and configure an output device profile"
        var seen = Set<String>()
        for (name, p) in classes {
            let r = SystemCapabilityText.profileRequiredReason(profile: p, deviceChannelCount: 8)
            XCTAssertFalse(r.contains(old), name)
            seen.insert(r)
        }
        XCTAssertEqual(seen.count, 3, "describe-first, two-channel, receiver")
        XCTAssertFalse(SystemCapabilityText.profileRequiredReason(profile: nil).isEmpty)
    }

    func testReadinessUsesTheArrangementReason() {
        var i = MeasurementReadiness.Inputs(permission: .authorized, hasInputDevice: true, hasOutputDevice: true)
        i.requiresProfile = true; i.hasProfile = false
        i.profileReason = SystemCapabilityText.profileRequiredReason(profile: profile(.downstreamReceiver, layout: .fiveOne))
        let r = MeasurementReadiness.evaluate(i)
        XCTAssertEqual(r.reason, i.profileReason)
        XCTAssertEqual(r.fix, .describeSpeakers)
    }
}
