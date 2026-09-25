from pathlib import Path

p = Path('NotchSixtyTests/StereoPlaybackControlTests.swift')
t = p.read_text()
start_marker = '    func testRawBypassDefersFIRPreparationPolicyAcrossRepeatedEdits() {'
end_marker = '    func testProcessedModePreparesFIRStages() {'
start = t.find(start_marker)
end = t.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit('bypass-policy test function boundaries missing')
replacement = '''    func testRawBypassDefersFIRPreparationPolicyAcrossRepeatedEdits() {
        let linearEQ = StereoEQConfiguration(phaseMode: .linearPhase)
        let room = RoomCorrectionConfiguration(enabled: true, filter: .validation)
        let globalBypassStates = [
            PlaybackControlConfiguration(balance: 0, globalBypassed: true, auditionMode: .processed),
            PlaybackControlConfiguration(balance: 0, globalBypassed: true, auditionMode: .reference),
            PlaybackControlConfiguration(balance: 0, globalBypassed: true, auditionMode: .delta),
        ]

        for playback in globalBypassStates {
            for _ in 0..<32 {
                XCTAssertTrue(FIRUpdatePolicy.isRawBypassed(playback))
                XCTAssertFalse(FIRUpdatePolicy.shouldPrepareLinearPhase(stereoEQ: linearEQ, playback: playback))
                XCTAssertFalse(FIRUpdatePolicy.shouldPrepareRoomCorrection(roomCorrection: room, playback: playback))
            }
        }
    }

    func testReferenceAndDeltaKeepFIRStagesPrepared() {
        let linearEQ = StereoEQConfiguration(phaseMode: .linearPhase)
        let room = RoomCorrectionConfiguration(enabled: true, filter: .validation)
        for mode in [AuditionMode.reference, .delta] {
            let playback = PlaybackControlConfiguration(auditionMode: mode)
            XCTAssertFalse(FIRUpdatePolicy.isRawBypassed(playback))
            XCTAssertTrue(FIRUpdatePolicy.shouldPrepareLinearPhase(stereoEQ: linearEQ, playback: playback))
            XCTAssertTrue(FIRUpdatePolicy.shouldPrepareRoomCorrection(roomCorrection: room, playback: playback))
        }
    }

'''
p.write_text(t[:start] + replacement + t[end:])
