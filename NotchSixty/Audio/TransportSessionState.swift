import Foundation

/// E23 S4 part 4 (G20): the stereo and binaural session handles, head-tracking status, archived counters and the
/// applied speaker routing of `AudioIOEngine`. Fields are `private(set)`; the transport and setter extensions change
/// them only through these methods, and the counters can only grow by archiving a session's counters.
///
/// Main actor only. Never touched from an audio callback.
@MainActor
@Observable
final class TransportSessionState {
    private(set) var session: CoreAudioTransportSession?
    private(set) var binauralHeadphoneSession: CoreAudioBinauralHeadphoneTransportSession?
    private(set) var headTrackingController: SpatialHeadTrackingController?
    private(set) var headTrackingRuntimeStatus = HeadTrackingRuntimeStatus.disabled
    /// The matrix of the session that is running or being built; the protection merge keys on it.
    private(set) var foldMatrixInUse: FoldDownMatrix?
    private(set) var lifetimeArchivedCounters = AudioTransportCounters()
    private(set) var processingSessionArchivedCounters = AudioTransportCounters()
    private(set) var speakerRoutingConfiguration: SpeakerRoutingConfiguration?
    /// The HRTF asset the running binaural graph renders.
    private(set) var renderedBinauralProfile: BinauralProfileReference?
    /// Arm token for live treatment targets; advances on every teardown and every disarm.
    @ObservationIgnored private(set) var liveTreatmentGeneration: UInt64 = 0

    func setSession(_ value: CoreAudioTransportSession?) { session = value }
    func setBinauralHeadphoneSession(_ value: CoreAudioBinauralHeadphoneTransportSession?) { binauralHeadphoneSession = value }
    func setHeadTrackingController(_ value: SpatialHeadTrackingController?) { headTrackingController = value }
    func setHeadTrackingRuntimeStatus(_ value: HeadTrackingRuntimeStatus) { headTrackingRuntimeStatus = value }
    func setFoldMatrixInUse(_ value: FoldDownMatrix?) { foldMatrixInUse = value }
    func setSpeakerRoutingConfiguration(_ value: SpeakerRoutingConfiguration?) { speakerRoutingConfiguration = value }
    func setRenderedBinauralProfile(_ value: BinauralProfileReference?) { renderedBinauralProfile = value }
    func advanceLiveTreatmentGeneration() { liveTreatmentGeneration &+= 1 }

    /// Adds a finished session's counters to both archives; the buffered-frame gauge does not carry over.
    func archive(_ counters: AudioTransportCounters) {
        lifetimeArchivedCounters = lifetimeArchivedCounters + counters
        lifetimeArchivedCounters.bufferedFrames = 0
        processingSessionArchivedCounters = processingSessionArchivedCounters + counters
        processingSessionArchivedCounters.bufferedFrames = 0
    }

    /// A new processing session starts counting from zero; the lifetime archive keeps its total.
    func resetProcessingSessionCounters() { processingSessionArchivedCounters = AudioTransportCounters() }
}

extension AudioIOEngine {
    /// Read-forwarders so callers and the UI keep the old names.
    var transportSession: CoreAudioTransportSession? { transport.session }
    var binauralHeadphoneTransportSession: CoreAudioBinauralHeadphoneTransportSession? { transport.binauralHeadphoneSession }
    var headTrackingController: SpatialHeadTrackingController? { transport.headTrackingController }
    var headTrackingRuntimeStatus: HeadTrackingRuntimeStatus { transport.headTrackingRuntimeStatus }
    var foldMatrixInUse: FoldDownMatrix? { transport.foldMatrixInUse }
    var lifetimeArchivedCounters: AudioTransportCounters { transport.lifetimeArchivedCounters }
    var processingSessionArchivedCounters: AudioTransportCounters { transport.processingSessionArchivedCounters }
    var speakerRoutingConfiguration: SpeakerRoutingConfiguration? { transport.speakerRoutingConfiguration }
    var renderedBinauralProfile: BinauralProfileReference? { transport.renderedBinauralProfile }
    var liveTreatmentGeneration: UInt64 { transport.liveTreatmentGeneration }
}
