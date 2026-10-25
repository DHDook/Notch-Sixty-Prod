import XCTest
@testable import NotchSixty

final class SpeakerMeasurementLabQuasiAnechoicTests: XCTestCase {
    let system=UUID(uuidString:"D4000000-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!
    let source:MultichannelCalibrationSource = .speaker(.frontLeft)
    var mic:SpeakerOptimizerMicrophoneIdentity { .init(deviceUID:"pr106-gated",inputChannelIndex:0,calibrationFingerprint:nil) }

    func testExplicitReflectionWindowRejectsLateReflectionAndIsMagnitudeOnly() throws {
        let p=proto(); var s=session([p]); s.captures=captures(p,late:0.8)
        let r=try SpeakerMeasurementLabQuasiAnechoicAnalyzer().analyze(session:s,protocolID:p.id)
        XCTAssertTrue(r.isQuasiAnechoicEstimate); XCTAssertFalse(r.isAnechoic); XCTAssertTrue(r.magnitudeOnly); XCTAssertFalse(r.canDeploy)
        XCTAssertGreaterThan(r.minimumReliableFrequencyHz,300); XCTAssertLessThan(r.minimumReliableFrequencyHz,500)
        r.meanMagnitudeDB.forEach{XCTAssertEqual($0,0,accuracy:0.08)}
    }
    func testShorterWindowRaisesTrustBoundary() throws {
        let p=proto(); var s=session([p]); s.captures=captures(p,late:0)
        let a=SpeakerMeasurementLabQuasiAnechoicAnalyzer()
        let long=try a.analyze(session:s,protocolID:p.id,window:.init(preArrivalMilliseconds:0.75,reflectionFreePostArrivalMilliseconds:10,fadeOutMilliseconds:2,minimumCyclesForReliableMagnitude:2))
        let short=try a.analyze(session:s,protocolID:p.id,window:.init(preArrivalMilliseconds:0.75,reflectionFreePostArrivalMilliseconds:4,fadeOutMilliseconds:1,minimumCyclesForReliableMagnitude:2))
        XCTAssertGreaterThan(short.minimumReliableFrequencyHz,long.minimumReliableFrequencyHz)
    }
    func testStoredMicrophoneCalibrationIsReappliedToGatedMagnitude() throws {
        let cal=RoomCorrectionMicrophoneCalibration(sourceName:"plus3",points:[.init(frequencyHz:20,gainDB:3),.init(frequencyHz:1000,gainDB:3),.init(frequencyHz:20000,gainDB:3)])
        let cm=SpeakerOptimizerMicrophoneIdentity(deviceUID:"pr106-gated",inputChannelIndex:0,calibrationFingerprint:"plus3")
        let p=proto(); var s=session([p],microphone:cm,calibration:cal); s.captures=captures(p,late:0,microphone:cm)
        let r=try SpeakerMeasurementLabQuasiAnechoicAnalyzer().analyze(session:s,protocolID:p.id)
        XCTAssertTrue(r.microphoneCalibrationApplied); r.meanMagnitudeDB.forEach{XCTAssertEqual($0,3,accuracy:0.08)}
    }
    func testLegacyCalibratedSessionWithoutCurveFailsClosed() throws {
        let cm=SpeakerOptimizerMicrophoneIdentity(deviceUID:"pr106-gated",inputChannelIndex:0,calibrationFingerprint:"legacy")
        let p=proto(); var s=session([p],microphone:cm); s.captures=captures(p,late:0,microphone:cm)
        XCTAssertThrowsError(try SpeakerMeasurementLabQuasiAnechoicAnalyzer().analyze(session:s,protocolID:p.id)) {
            XCTAssertEqual($0 as? SpeakerMeasurementLabQuasiAnechoicError,.microphoneCalibrationUnavailable)
        }
    }
    func testLowSNRAndMissingArrivalFailClosed() throws {
        let p=proto(); var s=session([p]); s.captures=captures(p,late:0,snr:20)
        XCTAssertThrowsError(try SpeakerMeasurementLabQuasiAnechoicAnalyzer().analyze(session:s,protocolID:p.id))
        s.captures=captures(p,late:0); s.captures[0].quality.directArrivalSeconds=nil
        XCTAssertThrowsError(try SpeakerMeasurementLabQuasiAnechoicAnalyzer().analyze(session:s,protocolID:p.id))
    }
    func testSubwooferNearFieldIsNotMisrepresentedAsQuasiAnechoicSpeaker() throws {
        var p=proto(); p.request = .init(mode:.subwooferNearField,target:.acousticSource(.subwoofer(0)),geometry:.init(distanceMeters:0.03))
        var s=session([p]); s.captures=captures(p,late:0,sourceOverride:.subwoofer(0))
        XCTAssertThrowsError(try SpeakerMeasurementLabQuasiAnechoicAnalyzer().analyze(session:s,protocolID:p.id)) {
            XCTAssertEqual($0 as? SpeakerMeasurementLabQuasiAnechoicError,.wholeSpeakerProtocolRequired)
        }
    }
    func testWindowTooLongForStoredImpulseFailsClosed() throws {
        let p=proto(); var s=session([p]); s.captures=captures(p,late:0)
        for i in s.captures.indices { s.captures[i].impulseResponse=Array(s.captures[i].impulseResponse.prefix(280)) }
        XCTAssertThrowsError(try SpeakerMeasurementLabQuasiAnechoicAnalyzer().analyze(session:s,protocolID:p.id,window:.init(preArrivalMilliseconds:0.75,reflectionFreePostArrivalMilliseconds:10,fadeOutMilliseconds:2,minimumCyclesForReliableMagnitude:2)))
    }

    func proto()->SpeakerMeasurementLabProtocol { .init(name:"Front Left",request:.init(mode:.wholeSpeakerOnAxis,target:.acousticSource(source),geometry:.init(distanceMeters:1))) }
    func session(_ ps:[SpeakerMeasurementLabProtocol],microphone:SpeakerOptimizerMicrophoneIdentity?=nil,calibration:RoomCorrectionMicrophoneCalibration?=nil)->SpeakerMeasurementLabSession {
        .init(playbackSystemID:system,routingSignature:"gated-route",microphone:microphone ?? mic,microphoneCalibration:calibration,sampleRate:48000,protocols:ps,captures:[],createdAt:Date(timeIntervalSince1970:1704300000),modifiedAt:Date(timeIntervalSince1970:1704300000))
    }
    func captures(_ p:SpeakerMeasurementLabProtocol,late:Float,snr:Double=55,microphone:SpeakerOptimizerMicrophoneIdentity?=nil,sourceOverride:MultichannelCalibrationSource?=nil)->[SpeakerMeasurementLabCapture] {
        let sr=48000.0, arrival=100
        let grid=(0..<96).map{i in 80*pow(18000.0/80.0,Double(i)/95)}
        return (0..<3).map{r in
            var impulse=[Float](repeating:0,count:2048); impulse[arrival]=1
            let li=arrival+Int((sr*0.012).rounded()); if li<impulse.count { impulse[li]=late }
            return .init(id:UUID(),protocolID:p.id,repeatIndex:r,capturedAt:Date(timeIntervalSince1970:1704300100+Double(r)),playbackSystemID:system,routingSignature:"gated-route",microphone:microphone ?? mic,sampleRate:sr,source:sourceOverride ?? source,impulseResponse:impulse,transferFunction:.init(frequenciesHz:grid,magnitudeDB:Array(repeating:0,count:grid.count),phaseRadians:grid.map{_ in Double(r-1)*0.002}),quality:.init(clipped:false,playbackPeakDBFS:-20,capturePeakDBFS:-12,estimatedNoiseFloorDBFS:-70,estimatedSNRDB:snr,sweepComplete:true,directArrivalSeconds:Double(arrival)/sr + Double(r)*0.00001,usableLowHz:80,usableHighHz:18000,warnings:[]))
        }
    }

    // E11 S4: the gated view's lowest valid frequency is the analyser's floor.
    func testGatedPlotLimitMatchesAnalyser() throws {
        let p=proto(); var s=session([p]); s.captures=captures(p,late:0)
        let capture=s.captures[0]
        for post in [4.0,6.0,10.0] {
            let w=SpeakerMeasurementLabQuasiAnechoicWindow(preArrivalMilliseconds:0.75,reflectionFreePostArrivalMilliseconds:post,fadeOutMilliseconds:1,minimumCyclesForReliableMagnitude:2)
            let plot=try XCTUnwrap(MeasurementGatedPlot(impulseResponse:capture.impulseResponse,sampleRate:capture.sampleRate,directArrivalSeconds:try XCTUnwrap(capture.quality.directArrivalSeconds),window:w))
            let report=try SpeakerMeasurementLabQuasiAnechoicAnalyzer().analyze(session:s,protocolID:p.id,window:w)
            XCTAssertGreaterThanOrEqual(report.minimumReliableFrequencyHz,plot.lowestValidFrequencyHz-1e-9)
            XCTAssertLessThan(report.minimumReliableFrequencyHz/plot.lowestValidFrequencyHz,1.1)
            XCTAssertEqual(plot.oneOverGateHz,1000/post,accuracy:1e-9)
            XCTAssertEqual(plot.gateEndSeconds-plot.arrivalSeconds,post/1000,accuracy:1e-12)
        }
    }
}
