import Foundation

struct SpeakerMeasurementLabQuasiAnechoicWindow: Codable, Equatable, Sendable {
    var preArrivalMilliseconds: Double = 0.75
    var reflectionFreePostArrivalMilliseconds: Double = 6.0
    var fadeOutMilliseconds: Double = 1.5
    var minimumCyclesForReliableMagnitude: Double = 2.0
    func validate() -> Bool {
        preArrivalMilliseconds.isFinite && (0...2).contains(preArrivalMilliseconds)
        && reflectionFreePostArrivalMilliseconds.isFinite && (2...20).contains(reflectionFreePostArrivalMilliseconds)
        && fadeOutMilliseconds.isFinite && fadeOutMilliseconds >= 0.25
        && fadeOutMilliseconds <= reflectionFreePostArrivalMilliseconds * 0.5
        && minimumCyclesForReliableMagnitude.isFinite && (1...4).contains(minimumCyclesForReliableMagnitude)
    }
}

struct SpeakerMeasurementLabQuasiAnechoicRepeat: Codable, Equatable, Sendable {
    var captureID: UUID
    var directArrivalSeconds: Double
    var assumedReflectionBoundarySeconds: Double
    var frequenciesHz: [Double]
    var magnitudeDB: [Double]
}

struct SpeakerMeasurementLabQuasiAnechoicReport: Codable, Equatable, Sendable {
    var sessionID: UUID
    var playbackSystemID: UUID
    var protocolID: UUID
    var protocolName: String
    var source: MultichannelCalibrationSource
    var geometry: SpeakerMeasurementLabGeometry
    var window: SpeakerMeasurementLabQuasiAnechoicWindow
    var meanDirectArrivalSeconds: Double
    var meanAssumedReflectionBoundarySeconds: Double
    var minimumReliableFrequencyHz: Double
    var maximumReliableFrequencyHz: Double
    var frequenciesHz: [Double]
    var meanMagnitudeDB: [Double]
    var repeats: [SpeakerMeasurementLabQuasiAnechoicRepeat]
    var evidenceConfidence: Double
    var microphoneCalibrationApplied: Bool
    var microphoneCalibrationFingerprint: String?
    var warnings: [String]
    var isQuasiAnechoicEstimate: Bool { true }
    var isAnechoic: Bool { false }
    var magnitudeOnly: Bool { true }
    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
}

enum SpeakerMeasurementLabQuasiAnechoicError: Error, Equatable, LocalizedError {
    case invalidWindow, invalidSession, wholeSpeakerProtocolRequired
    case unqualifiedProtocol(UUID), missingDirectArrival(UUID), invalidDirectArrival(UUID), insufficientImpulse(UUID)
    case incompatibleFrequencyGrid, noReliableFrequencyBand
    case microphoneCalibrationUnavailable, microphoneCalibrationIdentityMismatch, invalidMicrophoneCalibration
    var errorDescription: String? { "Advanced Speaker Measurement Lab quasi-anechoic analysis failed." }
}

struct SpeakerMeasurementLabQuasiAnechoicAnalyzer: Sendable {
    func analyze(session: SpeakerMeasurementLabSession, protocolID: UUID,
                 window: SpeakerMeasurementLabQuasiAnechoicWindow = .init())
    throws -> SpeakerMeasurementLabQuasiAnechoicReport {
        guard window.validate() else { throw SpeakerMeasurementLabQuasiAnechoicError.invalidWindow }
        do { try session.validateStructure() } catch { throw SpeakerMeasurementLabQuasiAnechoicError.invalidSession }
        guard let p = session.protocols.first(where: {$0.id == protocolID}),
              p.request.mode == .wholeSpeakerOnAxis || p.request.mode == .wholeSpeakerOffAxis,
              let source = p.acousticSource, case .speaker(let role) = source,
              role != .lowFrequencyEffects else {
            throw SpeakerMeasurementLabQuasiAnechoicError.wholeSpeakerProtocolRequired
        }
        let evidence = try qualifiedEvidence(session, p)
        guard evidence.optimizerReady else { throw SpeakerMeasurementLabQuasiAnechoicError.unqualifiedProtocol(protocolID) }
        let calibration = try validatedCalibration(session)
        let captures = session.captures.filter {$0.protocolID == protocolID}.sorted {$0.repeatIndex < $1.repeatIndex}
        guard let grid = captures.first?.transferFunction.frequenciesHz,
              validGrid(grid), captures.allSatisfy({ gridsMatch(grid,$0.transferFunction.frequenciesHz) }) else {
            throw SpeakerMeasurementLabQuasiAnechoicError.incompatibleFrequencyGrid
        }
        let postSeconds = window.reflectionFreePostArrivalMilliseconds / 1000
        let gateLow = window.minimumCyclesForReliableMagnitude / postSeconds
        guard let qLow = captures.compactMap({$0.quality.usableLowHz}).max(),
              let qHigh = captures.compactMap({$0.quality.usableHighHz}).min() else {
            throw SpeakerMeasurementLabQuasiAnechoicError.noReliableFrequencyBand
        }
        let low=max(qLow,gateLow), high=min(qHigh,session.sampleRate*0.49)
        let idx=grid.indices.filter {grid[$0]>=low && grid[$0]<=high}
        guard idx.count >= SpeakerOptimizerMeasurementEvidenceEvaluator.minimumCommonResponsePointCount,
              let first=idx.first, let last=idx.last else { throw SpeakerMeasurementLabQuasiAnechoicError.noReliableFrequencyBand }
        let freqs=idx.map{grid[$0]}
        var repeatOut:[SpeakerMeasurementLabQuasiAnechoicRepeat]=[], arrays:[[Double]]=[]
        for c in captures {
            guard let arrival=c.quality.directArrivalSeconds else { throw SpeakerMeasurementLabQuasiAnechoicError.missingDirectArrival(c.id) }
            let afDouble=arrival*session.sampleRate
            guard arrival.isFinite, arrival>=0, afDouble.isFinite else { throw SpeakerMeasurementLabQuasiAnechoicError.invalidDirectArrival(c.id) }
            let af=Int(afDouble.rounded())
            guard c.impulseResponse.indices.contains(af) else { throw SpeakerMeasurementLabQuasiAnechoicError.invalidDirectArrival(c.id) }
            let pre=Int((window.preArrivalMilliseconds*session.sampleRate/1000).rounded())
            let post=Int((window.reflectionFreePostArrivalMilliseconds*session.sampleRate/1000).rounded())
            let fade=max(1,Int((window.fadeOutMilliseconds*session.sampleRate/1000).rounded()))
            let start=max(0,af-pre), end=af+post+1
            guard post>=2,end<=c.impulseResponse.count else { throw SpeakerMeasurementLabQuasiAnechoicError.insufficientImpulse(c.id) }
            let taper=max(af,end-1-fade)
            var mags:[Double]=[]
            for f in freqs {
                var re=0.0, im=0.0
                for n in start..<end {
                    let w:Double
                    if n<af && af>start {
                        let x=Double(n-start)/Double(af-start); w=0.5-0.5*cos(.pi*x)
                    } else if n>taper && end-1>taper {
                        let x=Double(n-taper)/Double(end-1-taper); w=0.5+0.5*cos(.pi*x)
                    } else { w=1 }
                    let v=Double(c.impulseResponse[n])*w, phase = -2*Double.pi*f*Double(n)/session.sampleRate
                    re += v*cos(phase); im += v*sin(phase)
                }
                var db=20*log10(max(hypot(re,im),1e-12))
                if let calibration { do { db += try calibration.gainDB(at:f) } catch { throw SpeakerMeasurementLabQuasiAnechoicError.invalidMicrophoneCalibration } }
                guard db.isFinite else { throw SpeakerMeasurementLabQuasiAnechoicError.incompatibleFrequencyGrid }
                mags.append(db)
            }
            arrays.append(mags)
            repeatOut.append(.init(captureID:c.id,directArrivalSeconds:arrival,
                assumedReflectionBoundarySeconds:arrival+postSeconds,frequenciesHz:freqs,magnitudeDB:mags))
        }
        let mean=freqs.indices.map{i in arrays.reduce(0){$0+$1[i]}/Double(arrays.count)}
        let meanArrival=repeatOut.map(\.directArrivalSeconds).reduce(0,+)/Double(repeatOut.count)
        let meanBoundary=repeatOut.map(\.assumedReflectionBoundarySeconds).reduce(0,+)/Double(repeatOut.count)
        return .init(sessionID:session.id,playbackSystemID:session.playbackSystemID,protocolID:p.id,protocolName:p.name,
            source:source,geometry:p.request.geometry,window:window,meanDirectArrivalSeconds:meanArrival,
            meanAssumedReflectionBoundarySeconds:meanBoundary,minimumReliableFrequencyHz:grid[first],
            maximumReliableFrequencyHz:grid[last],frequenciesHz:freqs,meanMagnitudeDB:mean,repeats:repeatOut,
            evidenceConfidence:evidence.confidence,microphoneCalibrationApplied:calibration != nil,
            microphoneCalibrationFingerprint:session.microphone.calibrationFingerprint,
            warnings:["Reflection-free post-arrival duration is an explicit assumption; the Lab does not claim to detect the first room reflection.",
                      "Windowed response is magnitude-only and is not authenticated crossover/timing phase evidence.",
                      "Quasi-anechoic is a reflection-limited installed-room estimate, not an anechoic/free-field certification."])
    }

    private func validatedCalibration(_ s:SpeakerMeasurementLabSession) throws -> RoomCorrectionMicrophoneCalibration? {
        let fingerprint=s.microphone.calibrationFingerprint
        guard let c=s.microphoneCalibration else {
            if fingerprint != nil { throw SpeakerMeasurementLabQuasiAnechoicError.microphoneCalibrationUnavailable }
            return nil
        }
        guard fingerprint == c.sourceName else { throw SpeakerMeasurementLabQuasiAnechoicError.microphoneCalibrationIdentityMismatch }
        guard c.schemaVersion == RoomCorrectionMicrophoneCalibration.currentSchemaVersion, c.points.count>=2 else {
            throw SpeakerMeasurementLabQuasiAnechoicError.invalidMicrophoneCalibration
        }
        var prev=0.0
        for p in c.points { guard p.frequencyHz.isFinite,p.frequencyHz>prev,p.gainDB.isFinite else { throw SpeakerMeasurementLabQuasiAnechoicError.invalidMicrophoneCalibration }; prev=p.frequencyHz }
        return c
    }
    private func qualifiedEvidence(_ s:SpeakerMeasurementLabSession,_ p:SpeakerMeasurementLabProtocol) throws -> SpeakerOptimizerMeasurementGroupReport {
        guard let src=p.acousticSource else { throw SpeakerMeasurementLabQuasiAnechoicError.wholeSpeakerProtocolRequired }
        let position=SpeakerOptimizerMeasurementPosition(id:p.id,name:p.name)
        let caps=s.captures.filter{$0.protocolID==p.id}.map{c in SpeakerOptimizerMeasurementCapture(id:c.id,capturedAt:c.capturedAt,playbackSystemID:c.playbackSystemID,routingSignature:c.routingSignature,microphone:c.microphone,positionID:p.id,source:c.source,sampleRate:c.sampleRate,response:c.transferFunction,quality:c.quality)}
        let synthetic=SpeakerOptimizerMeasurementSet(role:.baseline,playbackSystemID:s.playbackSystemID,routingSignature:s.routingSignature,microphone:s.microphone,sampleRate:s.sampleRate,positions:[position],plannedSources:[src],captures:caps,createdAt:s.createdAt,modifiedAt:s.modifiedAt)
        let report=try SpeakerOptimizerMeasurementEvidenceEvaluator().evaluate(synthetic)
        guard let g=report.groupReports.first else { throw SpeakerMeasurementLabQuasiAnechoicError.unqualifiedProtocol(p.id) }
        return g
    }
    private func validGrid(_ g:[Double])->Bool { g.count>=SpeakerOptimizerMeasurementEvidenceEvaluator.minimumCommonResponsePointCount && g.allSatisfy{$0.isFinite&&$0>0} && zip(g,g.dropFirst()).allSatisfy{$0.0<$0.1} }
    private func gridsMatch(_ a:[Double],_ b:[Double])->Bool { a.count==b.count && zip(a,b).allSatisfy{abs($0.0-$0.1)<=max(1e-6,abs($0.0)*1e-9)} }
}
