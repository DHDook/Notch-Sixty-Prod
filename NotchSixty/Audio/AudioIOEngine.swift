import Observation
import CoreAudio
import Foundation


struct PreparedEQFIRProgram {
    let slot: UInt32
    let programInfo: N60ConvolutionProgramInfo
    let designInfo: EQLinearPhaseDesignInfo?
}

struct PreparedRoomCorrectionProgram {
    let slot: UInt32
    let programInfo: N60ConvolutionProgramInfo
}

struct PreparedSpeakerIRProgram {
    let slot: UInt32
    let programInfo: N60ConvolutionProgramInfo
}

@MainActor
@Observable
final class AudioIOEngine {
    /// E6 S8: set by the app shell (on unless `e6.legacy-kernel` is on). The engine never reads
    /// the flag itself; with this false the kernel path runs exactly as before.
    var unifiedGraphEnabled = false

    /// E4 S14 (`e4.engine-lease`): when true, a live anti-noise target is guarded by the render
    /// path's dead-man lease. Set once at launch by the app; off enforces no lease.
    var activeQuietZoneLeaseEnabled = false
    private var activeQuietZoneLeaseKeeper: ActiveQuietZoneLeaseKeeper?

    /// E4 S18b: true when the lease is required and its renewal is running (the adaptive gate
    /// closes otherwise). With the lease flag off nothing is required, so this is true.
    var activeQuietZoneLeaseHealthy: Bool {
        !activeQuietZoneLeaseEnabled || activeQuietZoneLeaseKeeper?.isRunning == true
    }

    /// Starts or stops lease renewal to match whether anti-noise is live on the current session.
    func syncActiveQuietZoneLease(active: Bool) {
        guard activeQuietZoneLeaseEnabled, active, let session = quietZoneHost else {
            activeQuietZoneLeaseKeeper?.stop()
            activeQuietZoneLeaseKeeper = nil
            return
        }
        if activeQuietZoneLeaseKeeper == nil {
            activeQuietZoneLeaseKeeper = ActiveQuietZoneLeaseKeeper(
                poll: { [weak session] in session?.pollQuietZoneGuards() },
                renew: { [weak session] seconds in session?.renewActiveQuietZoneLease(seconds: seconds) },
                release: { [weak session] in session?.releaseActiveQuietZoneLease() }
            )
        }
        activeQuietZoneLeaseKeeper?.start()
    }

    /// E8 S4: the speaker routing a session renders, or nil. See `replaceSpeakerRoutingConfiguration`.
    var speakerRoutingConfiguration: SpeakerRoutingConfiguration?

    private let deviceCatalog: any OutputDeviceCataloging
    let eventMonitor: any AudioHardwareEvents
    let masterVolumeController: any MasterVolumeDeviceControlling
    let binauralProfileAssetStore: BinauralProfileAssetStore
    /// E6 S9c: converted HRTF assets per (asset, rate), shared by session start and live asset swaps.
    let binauralAssetCache = BinauralResampledAssetCache()
    /// Newest live HRTF asset swap request; an older prepare that finishes later is dropped.
    private var headphoneAssetGeneration: UInt64 = 0
    /// The HRTF asset the running binaural graph renders (a requested swap is pending while it differs from the
    /// configuration's).
    var renderedBinauralProfile: BinauralProfileReference?
    private let masterVolumeStore: (any MasterVolumePersisting)?
    /// Output whose stored software volume has already been restored. A sync
    /// for the same output (external change, device-list refresh) never
    /// overwrites the user's current level.
    private var masterVolumeSynchronizedOutputUID: String?
    var lifecycle: AudioLifecycleStateMachine
    var transportSession: CoreAudioTransportSession?
    /// E25 S2: applied to each new stereo session.
    var stereoAlignment: StereoBassAlignment?
    /// E25 S8a: the wider-source fold the user configured (nil: none), and the matrix of the session that is running or
    /// being built with it. The protection merge keys on the second, so a fold that resolves to the standard path
    /// (no source tapped) adds no limiter.
    var programFoldPlan: ProgramFoldDownPlan?
    var foldMatrixInUse: FoldDownMatrix?
    /// E25 S8c: read-only views of the applied arrangement state, so profile load and the wizard are comparable.
    var appliedStereoAlignment: StereoBassAlignment? { stereoAlignment }
    var appliedProgramFoldPlan: ProgramFoldDownPlan? { programFoldPlan }
    var nChannelTransportSession: CoreAudioNChannelTransportSession?
    var binauralHeadphoneTransportSession: CoreAudioBinauralHeadphoneTransportSession?
    var headTrackingController: SpatialHeadTrackingController?
    var lifetimeArchivedCounters = AudioTransportCounters()
    var processingSessionArchivedCounters = AudioTransportCounters()
    var reconfigurationWorkItem: DispatchWorkItem?
    var recoveryWorkItem: DispatchWorkItem?
    var recoveryGeneration: UInt64 = 0
    var recoveryConsecutiveBuildFailures = 0
    var resumeAfterWake = false
    private var prepared = false
    var activeEQFIRProgram: PreparedEQFIRProgram?
    var nextEQFIRProgramSlot: UInt32 = 0
    /// E27 S3c: designed taps of the recent EQ configurations, so an A/B toggle redesigns nothing.
    var eqFIRCache = EQFIRProgramCache()
    var eqOffMain = EQOffMainState()
    /// Linear-phase designs run so far (a cache hit runs none). Tests read it.
    var eqFIRDesignCount: Int { eqFIRCache.designCount }
    var activeRoomCorrectionProgram: PreparedRoomCorrectionProgram?
    var nextRoomCorrectionProgramSlot: UInt32 = 0
    var activeSpeakerIRProgram: PreparedSpeakerIRProgram?
    var nextSpeakerIRProgramSlot: UInt32 = 0
    var stagedRoomTreatment: LiveMIMORoomTreatmentPreparation?
    /// E19 S6: the graph MIMO treatment controller (stage, permit, arm switch); see `AudioIOEngine+MIMOTreatment.swift`.
    @ObservationIgnored lazy var mimoGraphTreatment: MIMOGraphTreatment = makeMIMOGraphTreatment()
    var mimoPollTask: Task<Void, Never>?
    /// E19 S6/S7/S8: the room-correction latency mode as the treatment sees it, refreshed from the installed correction
    /// (`refreshMIMOVideoLatencyInput`); while unknown no permit is issued (G30). Known and video: no arm and no permit.
    var mimoVideoLatencyInput: MIMOVideoLatencyInput = .unknown
    var mimoVideoLatencyMode: Bool {
        if case .known(let video) = mimoVideoLatencyInput { return video }
        return false
    }
    var stagedAudioUnitRack: AudioUnitLiveRackSwitchboard?
    /// Set when a rate change or output recovery dropped a rack built for the
    /// previous format; cleared once the rebuild request has been issued.
    private var audioUnitRackRebuildPending = false
    /// Asked, on the main actor, to re-instantiate the plug-in rack at the
    /// current output format after the transport came back without it.
    var onAudioUnitRackRequiresRebuild: (@MainActor () -> Void)?
    /// Supplies the deployed room-correction filter re-synthesized for another
    /// output rate (the product layer owns the design source). The published
    /// configuration keeps the deployed filter; only the realtime program uses
    /// the adapted one.
    var roomCorrectionFilterAdapter: (@MainActor (RoomCorrectionFilter, Double) -> RoomCorrectionFilter?)?
    private var adaptedRoomCorrectionFilter:
        (source: RoomCorrectionFilter, sampleRate: Double, filter: RoomCorrectionFilter)?

    var sampleRateChangesHandled: UInt64 = 0
    var recoveryAttempts: UInt64 = 0
    var recoverySuccesses: UInt64 = 0
    var recoveryFailures: UInt64 = 0

    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var routeConfiguration: AudioRouteConfiguration
    private(set) var eqConfiguration = EQConfiguration()
    private(set) var stereoEQConfiguration = StereoEQConfiguration()
    /// E27 S3b: the band-pass "Listen" audition, if one is held. Never stored in
    /// `stereoEQConfiguration`, the profile or undo; it only changes what is rendered.
    var eqAudition: EQAuditionOverride?
    /// The EQ as rendered: the stored EQ, or the audition band-pass while one is held.
    var renderStereoEQConfiguration: StereoEQConfiguration {
        eqAudition.map { stereoEQConfiguration.auditioned($0) } ?? stereoEQConfiguration
    }
    private(set) var playbackControlConfiguration = PlaybackControlConfiguration()
    private(set) var masterVolumeConfiguration = MasterVolumeConfiguration()
    var masterVolumeCapabilities = MasterVolumeDeviceCapabilities.softwareOnly
    /// E16 S2: told when media keys may act (software volume on a selected output). `VolumeKeyController` owns the monitor.
    @ObservationIgnored var onVolumeKeyRouteChange: ((Bool) -> Void)?
    private(set) var softwareVolumeKeyStep = MasterVolumeKeyStep.fraction(denominator: 16)
    private(set) var gainConfiguration = DSPGainConfiguration()
    private(set) var bassManagementConfiguration = BassManagementConfiguration()
    private(set) var multiOutputRoutingConfiguration: MultiOutputRoutingConfiguration?
    private(set) var outputDeviceProfileConfiguration: OutputDeviceProfileConfiguration?
    private(set) var headphoneDeviceProfileConfiguration: HeadphoneDeviceProfileConfiguration?
    private(set) var speakerDriverProcessingConfiguration = SpeakerDriverProcessingConfiguration()
    private(set) var dynamicsConfiguration = DynamicsConfiguration() {
        // E9 S5b: keeps the output-protection policy in step with restored and replaced settings.
        didSet { UnifiedGraphOutputProtection.apply(settings: dynamicsConfiguration.outputProtection ?? OutputProtectionSettings()) }
    }
    /// E28 S7d: session state of dynamics listening and multiband solo (never encoded, never persisted). The graph host holds
    /// the same state; these mirror it for the Dynamics page and the banner. Cleared on a profile switch, Stop, an output
    /// change and Quit.
    var dynamicsListener: DynamicsListener?
    var dynamicsSoloBands: Set<Int> = []
    private(set) var roomCorrectionConfiguration = RoomCorrectionConfiguration()
    /// E24 S3b: why an enabled lane-plan correction is not shaping playback right now, for Room Correction to show.
    var roomCorrectionInactiveReason: RoomCorrectionInactiveReason?
    /// E24 S3b: the engine's per-rate cache of lane-plan synthesis (design note 8).
    let roomCorrectionRateCache = RoomCorrectionRateCache()
    private(set) var speakerIRConfiguration = SpeakerIRConfiguration()
    var ambientCompensationRuntimeTarget =
        AmbientCompensationTarget.unity
    private(set) var activeQuietZoneRuntimeTarget =
        ActiveQuietZoneRuntimeTarget.bypassed
    var linearPhaseDesignInfo: EQLinearPhaseDesignInfo?
    var headTrackingRuntimeStatus = HeadTrackingRuntimeStatus.disabled
    var lastErrorDescription: String?
    var lifecycleState: AudioLifecycleState
    /// E4 S7: the low-latency output profile Quiet Zone requests, and the
    /// buffer size it set on the current output (nil when off or not applied).
    var lowLatencyOutputProfileActive = false
    var lowLatencyOutputBufferFrames: UInt32?
    let lowLatencyBufferProfile: LowLatencyOutputBufferProfile
    /// Restore deferred to the rebuild, so the physical output never changes
    /// size under a live tap aggregate.
    var lowLatencyRestorePending = false

    init(
        deviceCatalog: any OutputDeviceCataloging = CoreAudioOutputDeviceCatalog(),
        initialRouteConfiguration: AudioRouteConfiguration = AudioRouteConfiguration(),
        eventMonitor: any AudioHardwareEvents = AudioHardwareEventMonitor(),
        masterVolumeController: any MasterVolumeDeviceControlling = CoreAudioMasterVolumeController(),
        binauralProfileAssetStore: BinauralProfileAssetStore = BinauralProfileAssetStore(),
        masterVolumeStore: (any MasterVolumePersisting)? = nil,
        outputBufferSizeController: any OutputBufferSizeControlling = CoreAudioOutputBufferSizeController()
    ) {
        self.lowLatencyBufferProfile = LowLatencyOutputBufferProfile(
            controller: outputBufferSizeController
        )
        self.deviceCatalog = deviceCatalog
        self.masterVolumeStore = masterVolumeStore
        self.routeConfiguration = initialRouteConfiguration
        self.eventMonitor = eventMonitor
        self.masterVolumeController = masterVolumeController
        self.binauralProfileAssetStore = binauralProfileAssetStore
        let lifecycle = AudioLifecycleStateMachine()
        self.lifecycle = lifecycle
        self.lifecycleState = lifecycle.state

        eventMonitor.onDeviceListChanged = { [weak self] in self?.handleDeviceListChanged() }
        eventMonitor.onSelectedOutputSampleRateChanged = { [weak self] in
            self?.scheduleSampleRateReconfiguration()
        }
        eventMonitor.onWillSleep = { [weak self] in self?.handleWillSleep() }
        eventMonitor.onDidWake = { [weak self] in self?.handleDidWake() }
        masterVolumeController.onExternalChange = { [weak self] in self?.handleMasterVolumeDeviceChange() }
    }

    var ambientCompensationAvailableHeadroomDB: Double {
        max(-gainConfiguration.headroomAttenuationDB, 0)
    }

    var ambientCompensationStereoSpeakerRuntimeAvailable: Bool {
        (transportSession != nil
            && nChannelTransportSession == nil
            && binauralHeadphoneTransportSession == nil
            && headphoneDeviceProfileConfiguration?.enabled != true)
            || ambientCompensationGraphRuntimeAvailable
    }

    /// E6 S9b: a graph-rendered N-channel speaker session runs ambient compensation in the graph (after the
    /// compressor and expander, before protection). Binaural headphones stay without it.
    var ambientCompensationGraphRuntimeAvailable: Bool {
        nChannelTransportSession != nil && liveGraphEditsAvailable
    }

    /// E4 S30c: whether the live graph can realise conversation-unmasking cuts now: a graph-rendered N-channel session,
    /// or a stereo speaker session whose unified graph is active (not `e6.legacy-kernel`, no fallback to the kernel).
    /// The legacy kernel never receives cuts, so the controller falls back to the broad cut when this is false.
    var ambientUnmaskingRuntimeAvailable: Bool {
        if ambientCompensationGraphRuntimeAvailable { return true }
        guard let session = transportSession, ambientCompensationStereoSpeakerRuntimeAvailable else { return false }
        return session.unifiedGraphRendersLocked
    }

    /// E4 S30c: the engine's own check of a conversation target's cuts (the controller's planner already limits them):
    /// 17 finite values, each 0...6 dB of cut, only in Conversation Focus, and only where the graph can realise them.
    private func validateUnmaskingCuts(_ target: AmbientCompensationTarget) throws {
        guard let cuts = target.unmaskingCutsDB else { return }
        guard target.mode == .conversationFocus,
              AmbientUnmaskOverlay.isValid(plannedCutsDB: cuts),
              ambientUnmaskingRuntimeAvailable else {
            throw AmbientCompensationError.invalidConfiguration
        }
    }

    func replaceAmbientCompensationRuntimeTarget(
        _ target: AmbientCompensationTarget
    ) throws {
        try validateUnmaskingCuts(target)
        let values = [
            target.levelDB,
            target.lowSupportDB,
            target.presenceSupportDB,
            target.detailSupportDB,
            target.confidence,
            target.ambientDeltaDB,
        ]
        guard values.allSatisfy(\.isFinite),
              target.levelDB >= -6.0,
              target.levelDB <=
                AmbientCompensationConfiguration
                    .hardMaximumLevelCompensationDB,
              target.lowSupportDB >= -2.0,
              target.lowSupportDB <=
                AmbientCompensationPlanner.maximumLowSupportDB,
              target.presenceSupportDB >= -3.0,
              target.presenceSupportDB <=
                AmbientCompensationPlanner.maximumPresenceSupportDB,
              target.detailSupportDB >= -1.5,
              target.detailSupportDB <=
                AmbientCompensationPlanner.maximumDetailSupportDB,
              target.conversationEvidence.isFinite,
              target.estimatedClearanceDB.isFinite else {
            throw AmbientCompensationError.invalidConfiguration
        }

        if target.mode == .conversationFocus {
            guard target.levelDB <= 0.000_1,
                  target.lowSupportDB >= -0.000_1,
                  target.presenceSupportDB <= 0.000_1,
                  target.detailSupportDB >= -0.000_1 else {
                throw AmbientCompensationError.invalidConfiguration
            }
        }

        let available = ambientCompensationAvailableHeadroomDB
        let positiveRecovery = max(target.levelDB, 0)
        guard positiveRecovery <= available + 0.000_1 else {
            throw AmbientCompensationError
                .insufficientDigitalHeadroom(
                    requested: positiveRecovery,
                    available: available
                )
        }

        let requestsDSP = abs(target.levelDB) > 0.000_1
            || (target.unmaskingCutsDB?.contains { $0 > 0.000_1 } ?? false)
            || abs(target.lowSupportDB) > 0.000_1
            || abs(target.presenceSupportDB) > 0.000_1
            || abs(target.detailSupportDB) > 0.000_1
        if requestsDSP,
           !ambientCompensationStereoSpeakerRuntimeAvailable {
            throw AmbientCompensationError.runtimeUnsupported
        }

        if ambientCompensationGraphRuntimeAvailable {
            var inputs = currentLiveGraphInputs
            inputs.ambient = target
            try republishLiveGraph(inputs)
            ambientCompensationRuntimeTarget = target
            lastErrorDescription = nil
            return
        }

        guard let session = transportSession else {
            ambientCompensationRuntimeTarget = target
            lastErrorDescription = nil
            return
        }

        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: gainConfiguration,
                ambientTarget: target
            )

        var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
            sampleRate: session.outputFormat.sampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration:
                renderBassManagementConfiguration(),
            dynamicsConfiguration: renderDynamicsConfiguration(),
            playbackConfiguration: playbackControlConfiguration,
            masterGainLinear: currentMasterSoftwareGain
        )
        try attachActiveEQFIRProgramIfNeeded(
            to: &graph,
            stereoConfiguration: renderStereoEQConfiguration,
            playbackConfiguration: playbackControlConfiguration
        )
        try attachActiveRoomCorrectionProgramIfNeeded(
            to: &graph,
            playbackConfiguration: playbackControlConfiguration
        )
        try attachActiveSpeakerIRProgramIfNeeded(
            to: &graph,
            playbackConfiguration: playbackControlConfiguration
        )
        try applyAudioUnitRackLatency(to: &graph)
        try attachAmbientCompensation(target, to: &graph)
        try attachActiveQuietZone(
            candidateQuietZone,
            to: &graph
        )
        // E4 S30c: the cuts ride on the session's unified graph, not the kernel snapshot.
        // A failed publish restores the previous cuts, so a later republish never renders cuts the engine refused.
        let previousCuts = session.currentAmbientUnmaskCuts
        session.setAmbientUnmaskCuts(target.unmaskingCutsDB)
        do { try session.publishDSPGraph(graph) } catch {
            session.setAmbientUnmaskCuts(previousCuts)
            throw error
        }
        ambientCompensationRuntimeTarget = target
        activeQuietZoneRuntimeTarget = candidateQuietZone
        lastErrorDescription = nil
    }

    func clearAmbientCompensationRuntimeTarget() throws {
        try replaceAmbientCompensationRuntimeTarget(.unity)
    }

    var activeQuietZoneStereoSpeakerRuntimeAvailable: Bool {
        transportSession != nil
            && nChannelTransportSession == nil
            && binauralHeadphoneTransportSession == nil
            && headphoneDeviceProfileConfiguration?.enabled != true
            && outputDeviceProfileConfiguration?.enabled != true
            && multiOutputRoutingConfiguration?.enabled != true
    }

    /// E26 S7b2b: the profile session hosts the Quiet Zone feed (class A: two mains plus one sub output, not routed).
    var activeQuietZoneProfileRuntimeAvailable: Bool {
        guard transportSession == nil, binauralHeadphoneTransportSession == nil,
              let profile = nChannelTransportSession else { return false }
        return profile.hostsQuietZone
    }

    /// Largest anti-noise peak the engine will accept: the planner's headroom-based value, then the
    /// always-on live-treatment cap (`LiveTreatmentSafeguards`), which no setting disables.
    var activeQuietZoneAvailableInjectionPeak: Double {
        LiveTreatmentSafeguards.limitedInjectionPeak(
            (try? ActiveQuietZonePlanner().availableInjectionPeak(
                headroomAttenuationDB:
                    gainConfiguration.headroomAttenuationDB,
                ambientLevelRecoveryDB:
                    max(
                        ambientCompensationRuntimeTarget.levelDB,
                        0
                    ),
                configuration: ActiveQuietZoneConfiguration()
            )) ?? 0
        )
    }

    /// Output sample rate of the running transport, for the live-treatment arm switch: the stereo session, or the
    /// profile session when it hosts the Quiet Zone feed (class A). Without the profile fallback Turn On refused
    /// with `engineNotRunning` on a profile session (E26 S7b2c part 2, G16).
    var liveTreatmentSampleRate: Double? {
        if let transportSession { return transportSession.outputFormat.sampleRate }
        if let profile = nChannelTransportSession, profile.hostsQuietZone { return profile.outputFormat.sampleRate }
        return nil
    }

    /// E26 S7b2: the session that renders Quiet Zone anti-noise: the stereo session, or the profile session when its
    /// graph carries the ANC lane feed (class A). nil otherwise, so every passthrough below answers "no session".
    private var quietZoneHost: (any QuietZoneRuntimeHost)? {
        if let transportSession { return transportSession.quietZoneRuntimeHost }
        if let profile = nChannelTransportSession, profile.hostsQuietZone { return profile }
        return nil
    }

    /// E4 S15: live howl-guard trips on the current transport session (0 without one). The Quiet
    /// Zone arm compares it with the value captured at arming.
    var liveTreatmentHowlTripCount: UInt64 { quietZoneHost?.howlGuardTripCount ?? 0 }

    /// E4 S15: clears a latched howl-guard trip; the arm calls it before arming.
    func rearmHowlGuard() { quietZoneHost?.rearmHowlGuard() }

    /// E4 S18b: when true, an active Quiet Zone target also stamps the render snapshot with its arm
    /// token, which lets the adaptive gain mailbox play. Set by the controller from the
    /// `e4.adaptive-tonal-live` flag; false leaves the snapshot exactly as before (generation 0).
    var adaptiveTonalMailboxEnabled = false

    /// E4 S20 (`e4.earned-cap`): the earned anti-noise cap at arm, linear. 0 (the default, flag
    /// off) keeps the fixed -40 dBFS snapshot cap exactly as before. Above 0 the snapshot cap is
    /// the arm ceiling (-18 dBFS) and the kernel starts its own ceiling here and raises it at most
    /// 3 dB per 5 s. Set by the Quiet Zone controller at arm; the engine never reads the flag.
    var earnedCapInitialLinear: Float = 0
    /// E4 S21 (`e4.earned-cap`): the speaker's excursion curve for this arm. Each tone gets a
    /// kernel cap equal to the curve's lowest value across its tracking range; nil (flag off)
    /// sets no caps and the snapshot is unchanged. Set by the Quiet Zone controller at arm.
    var excursionCapCurve: ExcursionCapCurve?

    /// The token the kernel holds for the current arm: never 0 (0 means no arm in the mailbox).
    var kernelArmGeneration: UInt64 { liveTreatmentGeneration &+ 1 }

    @discardableResult
    func publishActiveQuietZoneGainRecord(_ record: N60ActiveQuietZoneGainRecord) -> UInt64 {
        quietZoneHost?.publishActiveQuietZoneGainRecord(record) ?? 0
    }

    func popActiveQuietZoneTelemetry() -> N60ActiveQuietZoneTelemetryRecord? {
        quietZoneHost?.popActiveQuietZoneTelemetry()
    }

    var activeQuietZoneMailboxStats: N60ActiveQuietZoneMailboxStats {
        quietZoneHost?.activeQuietZoneMailboxStats ?? N60ActiveQuietZoneMailboxStats()
    }

    /// E4 S18b: the worker's link onto the current session, or nil when none is running.
    var adaptiveTonalLink: (any AdaptiveTonalLiveLink)? {
        quietZoneHost.map { CoreAudioAdaptiveTonalLink(session: $0) }
    }

    /// Latches the same fade as a kernel howl-guard trip; the arm then disarms on the trip count.
    func requestHowlTrip() { quietZoneHost?.requestHowlTrip() }

    /// Output gain the user's volume and the headroom attenuation apply, in dB (0 = unity),
    /// for the live-treatment arm switch. Muted reads as -120.
    var liveTreatmentOutputGainDB: Double {
        let level = masterVolumeConfiguration.muted
            ? 0 : MasterVolumeConfiguration.softwareTaperGain(forLevel: masterVolumeConfiguration.level)
        let volumeDB = level > 1.0e-6 ? 20 * log10(level) : -120
        return gainConfiguration.headroomAttenuationDB + volumeDB
    }

    private var transportTeardownObservers: [(id: UUID, handler: (TransportTeardownCause) -> Void)] = []

    /// Registers a handler fired at the end of every transport teardown (control plane, main
    /// actor; never the audio callback). Multicast, so the Quiet Zone and MIMO arm switches
    /// each keep their own. Returns an id for `removeTransportTeardownObserver`.
    @discardableResult
    func addTransportTeardownObserver(_ handler: @escaping (TransportTeardownCause) -> Void) -> UUID {
        let id = UUID()
        transportTeardownObservers.append((id, handler))
        return id
    }

    /// Every transport teardown path (Stop, Quit, sleep, output lost, rate or route reconfiguration) ends in
    /// `tearDownTransport`, which calls this last. Also called directly by tests, which have no Core Audio session.
    func notifyTransportTeardown(_ cause: TransportTeardownCause) {
        for observer in transportTeardownObservers { observer.handler(cause) }
    }

    func removeTransportTeardownObserver(_ id: UUID) {
        transportTeardownObservers.removeAll { $0.id == id }
    }

    /// Arm token for live treatment targets. It advances on every transport teardown and every
    /// disarm; `replaceActiveQuietZoneRuntimeTarget` rejects an active target stamped with any
    /// other value. Control plane only.
    var liveTreatmentGeneration: UInt64 = 0

    /// Called by the arm owner on disarm: targets built under the old arm can no longer play.
    func revokeLiveTreatmentArm() {
        liveTreatmentGeneration &+= 1
        // E6 S12h part 2b: the stereo session's hosted feed fades out at once; the next publish carries the revoke.
        transportSession?.revokeHostedQuietZone()
        // A republish (an EQ change, say) must not re-authorise the revoked target: the hosted feed is armed by the snapshot.
        if transportSession?.hostedQuietZoneFeed != nil, activeQuietZoneRuntimeTarget.active {
            activeQuietZoneRuntimeTarget = ActiveQuietZoneRuntimeTarget(tones: [], transitionMilliseconds: 100)
            syncActiveQuietZoneLease(active: false)
        }
        // E26 S7b2b: the profile session's ANC_INJECT authorisation ends with the arm (the feed fades out in 20 ms).
        if let profile = nChannelTransportSession, profile.hostsQuietZone, profile.quietZoneInjectAuthorised {
            try? profile.setQuietZoneInjectAuthorised(false)
        }
        if activeQuietZoneProfileRuntimeAvailable, activeQuietZoneRuntimeTarget.active {
            activeQuietZoneRuntimeTarget = ActiveQuietZoneRuntimeTarget(tones: [], transitionMilliseconds: 100)
            syncActiveQuietZoneLease(active: false)
        }
    }

    func replaceActiveQuietZoneRuntimeTarget(
        _ rawTarget: ActiveQuietZoneRuntimeTarget
    ) throws {
        let target = try rawTarget.validated()
        if target.active, target.armGeneration != liveTreatmentGeneration {
            throw ActiveQuietZoneError.armRevoked
        }
        if target.active,
           !activeQuietZoneStereoSpeakerRuntimeAvailable,
           !activeQuietZoneProfileRuntimeAvailable {
            throw ActiveQuietZoneError.runtimeUnsupported
        }
        if activeQuietZoneRuntimeTarget.active,
           target.active,
           !activeQuietZoneRuntimeTarget
                .frequencies(withinFraction: 0.02, of: target) {
            throw ActiveQuietZoneError
                .frequencyChangeRequiresDisarm
        }

        let available = LiveTreatmentSafeguards.limitedInjectionPeak(
            try ActiveQuietZonePlanner()
                .availableInjectionPeak(
                    headroomAttenuationDB:
                        gainConfiguration.headroomAttenuationDB,
                    ambientLevelRecoveryDB:
                        max(
                            ambientCompensationRuntimeTarget.levelDB,
                            0
                        ),
                    configuration:
                        ActiveQuietZoneConfiguration()
                )
        )
        if target.active,
           target.maximumSourceMagnitude
                > available + 1.0e-7 {
            throw ActiveQuietZoneError
                .insufficientOutputHeadroom
        }

        if transportSession == nil, let profile = nChannelTransportSession, profile.hostsQuietZone,
           binauralHeadphoneTransportSession == nil {
            try replaceProfileActiveQuietZoneTarget(target, on: profile)
            return
        }
        guard let session = transportSession else {
            guard !target.active else {
                throw ActiveQuietZoneError.runtimeUnsupported
            }
            activeQuietZoneRuntimeTarget = target
            lastErrorDescription = nil
            return
        }

        var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
            sampleRate: session.outputFormat.sampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration:
                renderBassManagementConfiguration(),
            dynamicsConfiguration: renderDynamicsConfiguration(),
            playbackConfiguration:
                playbackControlConfiguration,
            masterGainLinear: currentMasterSoftwareGain
        )
        try attachActiveEQFIRProgramIfNeeded(
            to: &graph,
            stereoConfiguration: renderStereoEQConfiguration,
            playbackConfiguration: playbackControlConfiguration
        )
        try attachActiveRoomCorrectionProgramIfNeeded(
            to: &graph,
            playbackConfiguration: playbackControlConfiguration
        )
        try attachActiveSpeakerIRProgramIfNeeded(
            to: &graph,
            playbackConfiguration: playbackControlConfiguration
        )
        try applyAudioUnitRackLatency(to: &graph)
        try attachActiveQuietZone(target, to: &graph)
        // The lease exists before any anti-noise is published.
        if target.active { syncActiveQuietZoneLease(active: true) }
        do {
            try session.publishDSPGraph(graph)
        } catch {
            if !activeQuietZoneRuntimeTarget.active { syncActiveQuietZoneLease(active: false) }
            throw error
        }
        syncActiveQuietZoneLease(active: target.active)
        activeQuietZoneRuntimeTarget = target
        lastErrorDescription = nil
    }

    /// E26 S7b2b: the profile session's branch. The tonal snapshot goes to the feed; ANC_INJECT is authorised only for
    /// an active target stamped with the current arm token (checked by the caller), and revoked for an inactive one.
    /// The lease exists before the feed is armed, so the output stays zero until the first renewal.
    private func replaceProfileActiveQuietZoneTarget(
        _ target: ActiveQuietZoneRuntimeTarget, on profile: CoreAudioNChannelTransportSession
    ) throws {
        var scratch = N60DSPGraphSnapshotMakeUnity(profile.outputFormat.sampleRate)
        try attachActiveQuietZone(target, to: &scratch)
        if target.active { syncActiveQuietZoneLease(active: true) }
        do {
            try profile.setQuietZoneTonalSnapshot(scratch.activeQuietZone)
            try profile.setQuietZoneInjectAuthorised(target.active)
        } catch {
            if !activeQuietZoneRuntimeTarget.active {
                try? profile.setQuietZoneInjectAuthorised(false)
                syncActiveQuietZoneLease(active: false)
            }
            throw error
        }
        syncActiveQuietZoneLease(active: target.active)
        activeQuietZoneRuntimeTarget = target
        lastErrorDescription = nil
    }

    func clearActiveQuietZoneRuntimeTarget(
        fadeMilliseconds: Double = 100
    ) throws {
        try replaceActiveQuietZoneRuntimeTarget(
            ActiveQuietZoneRuntimeTarget(
                tones: [],
                transitionMilliseconds:
                    fadeMilliseconds
            )
        )
    }

    var physicalSpeakerBusRoutingActive: Bool {
        guard let routing = multiOutputRoutingConfiguration, routing.enabled else { return false }
        return routing.enabledRoutes.contains { !$0.bus.isFullRangeBus }
    }

    var liveNChannelActive: Bool { nChannelTransportSession != nil }

    /// E6 S12h part 3 (G50, G51): the delta audition runs on the program lanes of an unrouted speaker graph. A routed
    /// session (each output has its own crossover, delay and protection) and Virtual Speakers (the ears are rendered
    /// from the lanes) refuse it, so the picker does not offer it there.
    var deltaAuditionAvailable: Bool {
        if nChannelTransportSession?.routePlan.isRouted == true { return false }
        if binauralHeadphoneTransportSession != nil { return false }
        if let headphone = headphoneDeviceProfileConfiguration, headphone.enabled, headphone.spatialMode == .virtualSpeakers {
            return false
        }
        return true
    }

    /// Test seam (E6 S9c2): puts the engine in `.running` with a hardware-free N-channel session, so the live
    /// setters, the planner and the session-kind paths run against a real bridge and graph without Core Audio.
    func installTestingNChannelSession(_ session: CoreAudioNChannelTransportSession) throws {
        precondition(lifecycle.state == .idle && nChannelTransportSession == nil, "test seam needs an idle engine")
        for state: AudioLifecycleState in [.creatingTap, .creatingAggregate, .openingOutput, .starting, .running] {
            try setLifecycle(state)
        }
        nChannelTransportSession = session
        adoptQuietZoneReferenceHost()
    }

    /// Test seam: stops and drops the seam session and returns the engine to idle.
    func removeTestingNChannelSession() {
        nChannelTransportSession?.stop(fadeOut: false)
        nChannelTransportSession = nil
        try? setLifecycle(.stopping)
        try? setLifecycle(.idle)
    }
    var liveBinauralHeadphoneActive: Bool { binauralHeadphoneTransportSession != nil }
    private var immutableSemanticTransportActive: Bool {
        nChannelTransportSession != nil || binauralHeadphoneTransportSession != nil
    }

    func renderBassManagementConfiguration(
        _ source: BassManagementConfiguration? = nil
    ) -> BassManagementConfiguration {
        var render = source ?? bassManagementConfiguration
        if physicalSpeakerBusRoutingActive {
            // The physical splitter runs after shared DSP/audition. Disabling the
            // older early recombined crossover prevents double filtering.
            render.enabled = false
            render.subPhaseAlignmentEnabled = false
        }
        return render
    }

    var roomTreatmentStagedForNextStart: Bool {
        stagedRoomTreatment != nil
    }

    func stageRoomTreatmentForNextStart(
        firProgram: MIMORoomTreatmentFIRProgram,
        permit: MIMORoomTreatmentActivationPermit,
        transitionConfiguration: MIMORoomTreatmentTransitionConfiguration = .conservative
    ) throws {
        guard lifecycle.state == .idle else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        guard let profile = outputDeviceProfileConfiguration,
              profile.enabled,
              let selectedOutputUID = routeConfiguration.selectedOutputUID else {
            throw OutputDeviceProfileError.profileDisabled
        }
        let preparation = LiveMIMORoomTreatmentPreparation(
            firProgram: firProgram,
            permit: permit,
            acceptedProfile: profile,
            acceptedSelectedOutputUID: selectedOutputUID,
            transitionConfiguration: transitionConfiguration
        )
        try preparation.validate(sampleRate: firProgram.sampleRate)
        stagedRoomTreatment = preparation
    }

    func clearStagedRoomTreatment() throws {
        guard lifecycle.state == .idle else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        stagedRoomTreatment = nil
    }

    func requestRoomTreatmentArm() -> Bool {
        nChannelTransportSession?.requestRoomTreatmentArm() ?? false
    }

    func requestRoomTreatmentBypass() {
        nChannelTransportSession?.requestRoomTreatmentBypass()
    }

    func latchRoomTreatmentFault(
        _ fault: N60MIMOTreatmentFault
    ) -> Bool {
        nChannelTransportSession?.latchRoomTreatmentFault(fault) ?? false
    }

    func requestRoomTreatmentFaultClear() {
        nChannelTransportSession?.requestRoomTreatmentFaultClear()
    }

    func revokeRoomTreatmentAuthorization() {
        nChannelTransportSession?.revokeRoomTreatmentAuthorization()
    }

    var selectedOutputDevice: AudioOutputDevice? {
        guard let selectedOutputUID = routeConfiguration.selectedOutputUID else { return nil }
        return outputDevices.first { $0.uid == selectedOutputUID }
    }

    /// PR97 read-only, current-session route binding. This is not a probe
    /// transmitter, a DAC latency measurement, or an ANC arming interface.
    func hardwareClockAcquisitionRoute()
        -> QuietZoneHardwareHALClockAcquisition.Route? {
        guard let session = transportSession,
              nChannelTransportSession == nil,
              binauralHeadphoneTransportSession == nil,
              let selected = selectedOutputDevice,
              selected.uid == session.selectedOutput.uid,
              selected.deviceID == session.selectedOutput.deviceID,
              abs(selected.nominalSampleRate - session.outputFormat.sampleRate) < 0.5,
              session.passiveFeedForwardOutputTimingSnapshot() != nil
        else { return nil }
        return (
            outputID: selected.uid,
            routeID: session.calibrationTimingRouteLeaseID,
            sampleRate: session.outputFormat.sampleRate
        )
    }

    /// Records a controlled EXTERNAL source probe with the live microphone.
    /// The instrumented source emitter supplies an independent, calibrated
    /// acoustic-emission timestamp; this entry point NEVER launches playback.
    func makeInstrumentedSourceProbeAcquisition(
        microphone: AudioInputDevice,
        inputChannelIndex: Int,
        position: QuietZoneFeedForwardPosition,
        sourceFixtureID: String,
        synchronizedClockID: String,
        physicalSourceID: String
    ) throws -> QuietZoneInstrumentedProbeAcquisition {
        guard let session = transportSession,
              let route = hardwareClockAcquisitionRoute()
        else { throw QuietZoneInstrumentedProbeError.staleRoute }
        let collector = try QuietZoneInstrumentedProbeCollector(
            position: position,
            microphoneID: microphone.uid,
            microphoneChannel: inputChannelIndex,
            sourceFixtureID: sourceFixtureID,
            synchronizedClockID: synchronizedClockID,
            physicalSourceID: physicalSourceID,
            routeLeaseID: route.routeID,
            sampleRate: route.sampleRate
        )
        let reference = try FeedForwardReferenceTransport(
            microphone: microphone, inputChannelIndex: inputChannelIndex
        )
        return try QuietZoneInstrumentedProbeAcquisition(
            reference: reference,
            collector: collector,
            currentRoute: { [weak self, weak session] in
                guard let self, let session,
                      self.transportSession === session
                else { return nil }
                return self.hardwareClockAcquisitionRoute()
            }
        )
    }

    /// Creates a microphone-only timing observer bound to the *specific*
    /// active speaker-output session. Changes to the selected device, route,
    /// format or session lifetime invalidate the observer on its next poll.
    func makeHardwareClockAcquisition(
        microphone: AudioInputDevice,
        inputChannelIndex: Int
    ) throws -> QuietZoneHardwareHALClockAcquisition {
        guard let session = transportSession,
              let route = hardwareClockAcquisitionRoute()
        else { throw QuietZoneHardwareClockCaptureError.incompatibleRoute }
        let reference = try FeedForwardReferenceTransport(
            microphone: microphone,
            inputChannelIndex: inputChannelIndex
        )
        return try QuietZoneHardwareHALClockAcquisition(
            reference: reference,
            microphoneID: microphone.uid,
            outputID: route.outputID,
            routeID: route.routeID,
            sampleRate: route.sampleRate,
            currentRoute: { [weak self, weak session] in
                guard let self, let session,
                      self.transportSession === session
                else { return nil }
                return self.hardwareClockAcquisitionRoute()
            },
            outputWitness: { [weak session] in
                session?.passiveFeedForwardOutputTimingSnapshot()
            }
        )
    }

    func audioUnitRackProcessingFormatForNextStart() throws
        -> AudioUnitRackProcessingFormat {
        guard lifecycle.state == .idle else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        try refreshOutputDevices()
        guard let output = selectedOutputDevice else {
            throw AudioRouteSelectionError.outputDeviceUnavailable(
                uid: routeConfiguration.selectedOutputUID
                    ?? "No output selected"
            )
        }

        let format = makeAudioUnitRackFormat(sampleRate: output.nominalSampleRate)
        try format.validate()
        return format
    }

    func audioUnitRackChannelCount() -> Int {
        audioUnitRackRoles()?.count ?? 2
    }

    /// A staged rack is bound to the sample rate and channel count it was
    /// instantiated for. After a nominal-rate change or output recovery the
    /// transport would reject it and fail; instead continue dry and ask the
    /// product layer to rebuild the rack at the new format once running.
    func detachAudioUnitRackIfIncompatible(with output: AudioOutputDevice) {
        guard let rack = stagedAudioUnitRack else { return }
        let compatible = abs(rack.format.sampleRate - output.nominalSampleRate) < 0.5
            && rack.format.channelCount == audioUnitRackChannelCount()
        guard !compatible else { return }
        stagedAudioUnitRack = nil
        audioUnitRackRebuildPending = true
    }

    func requestAudioUnitRackRebuildIfPending() {
        guard audioUnitRackRebuildPending, lifecycle.state == .running else { return }
        audioUnitRackRebuildPending = false
        onAudioUnitRackRequiresRebuild?()
    }

    /// Reinstalls a rack rebuilt for the current output format after
    /// `onAudioUnitRackRequiresRebuild`. Uses the controlled-restart path.
    func restoreAudioUnitRackAfterFormatChange(
        _ runtime: AudioUnitLiveRackRuntime
    ) throws {
        guard lifecycle.state == .running, stagedAudioUnitRack == nil else { return }
        try controlledRestartForAudioUnitRackMutation(runtime)
    }

    func stageAudioUnitRackForNextStart(
        _ runtime: AudioUnitLiveRackRuntime?
    ) throws {
        guard lifecycle.state == .idle else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        if let runtime {
            stagedAudioUnitRack = try AudioUnitLiveRackSwitchboard(
                format: runtime.format,
                initialRuntime: runtime
            )
        } else {
            stagedAudioUnitRack = nil
        }
    }

    func clearStagedAudioUnitRack() {
        guard lifecycle.state == .idle else { return }
        stagedAudioUnitRack = nil
    }

    func audioUnitRackProcessingFormatForMutation() throws
        -> AudioUnitRackProcessingFormat {
        switch lifecycle.state {
        case .idle:
            if let stagedAudioUnitRack {
                return stagedAudioUnitRack.format
            }
            return try audioUnitRackProcessingFormatForNextStart()
        case .running:
            if let stagedAudioUnitRack {
                return stagedAudioUnitRack.format
            }
            guard let output = selectedOutputDevice else {
                throw AudioRouteSelectionError.outputDeviceUnavailable(
                    uid: routeConfiguration.selectedOutputUID
                        ?? "No output selected"
                )
            }
            let format = makeAudioUnitRackFormat(sampleRate: output.nominalSampleRate)
            try format.validate()
            return format
        default:
            throw AudioUnitRackMutationError
                .liveMutationRequiresRunningOrIdle(lifecycle.state)
        }
    }

    func activateAudioUnitRackMutation(
        _ candidate: AudioUnitRackMutationCandidate,
        crossfadeFrames: Int =
            AudioUnitLiveRackSwitchboard.defaultCrossfadeFrames
    ) async throws -> AudioUnitRackMutationActivation {
        switch lifecycle.state {
        case .idle:
            try stageAudioUnitRackForNextStart(candidate.runtime)
            return .stagedForNextStart

        case .running:
            if candidate.runtime == nil,
               stagedAudioUnitRack == nil {
                return .noAudioChange
            }

            if let switchboard = stagedAudioUnitRack,
               switchboard.format == candidate.format,
               switchboard.latencyFrames
                    == candidate.totalLatencyFrames {
                try await switchboard.transition(
                    to: candidate.runtime,
                    crossfadeFrames: crossfadeFrames
                )
                return .seamlessCrossfade(
                    generation:
                        switchboard.status.renderedGeneration
                )
            }

            try controlledRestartForAudioUnitRackMutation(
                candidate.runtime
            )
            return .controlledRestart

        default:
            throw AudioUnitRackMutationError
                .liveMutationRequiresRunningOrIdle(lifecycle.state)
        }
    }

    private func controlledRestartForAudioUnitRackMutation(
        _ runtime: AudioUnitLiveRackRuntime?
    ) throws {
        guard lifecycle.state == .running else {
            throw AudioUnitRackMutationError
                .liveMutationRequiresRunningOrIdle(lifecycle.state)
        }

        let previousSwitchboard = stagedAudioUnitRack
        let replacementSwitchboard: AudioUnitLiveRackSwitchboard?
        if let runtime {
            replacementSwitchboard =
                try AudioUnitLiveRackSwitchboard(
                    format: runtime.format,
                    initialRuntime: runtime
                )
        } else {
            replacementSwitchboard = nil
        }

        stop()
        stagedAudioUnitRack = replacementSwitchboard

        do {
            try start(resetProcessingSessionCounters: false)
        } catch {
            let activationError = error
            if lifecycle.state == .failed {
                if AudioLifecycleStateMachine.canTransition(
                    from: lifecycle.state,
                    to: .stopping
                ) {
                    try? setLifecycle(.stopping)
                }
                tearDownTransport(fadeOut: false)
                if AudioLifecycleStateMachine.canTransition(
                    from: lifecycle.state,
                    to: .idle
                ) {
                    try? setLifecycle(.idle)
                }
            }

            stagedAudioUnitRack = previousSwitchboard
            do {
                try start(resetProcessingSessionCounters: false)
            } catch {
                throw AudioUnitRackMutationError.rollbackFailed(
                    error.localizedDescription
                )
            }
            throw activationError
        }
    }

    func prepareForUse() {
        guard !prepared else { return }
        prepared = true
        do {
            try refreshOutputDevices()
            try eventMonitor.start()
            try syncMasterVolumeMonitorToSelectedOutput()
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    @discardableResult
    func refreshOutputDevices() throws -> [AudioOutputDevice] {
        do {
            let discoveredDevices = try deviceCatalog.outputDevices()
            outputDevices = discoveredDevices
            return discoveredDevices
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func selectOutput(uid: String?) throws {
        guard lifecycle.state == .idle else { return }
        guard let uid else {
            routeConfiguration.selectedOutputUID = nil
            masterVolumeSynchronizedOutputUID = nil
            masterVolumeController.stopMonitoring()
            masterVolumeCapabilities = .softwareOnly
            onVolumeKeyRouteChange?(false)
            return
        }
        guard outputDevices.contains(where: { $0.uid == uid }) else {
            let error = AudioRouteSelectionError.outputDeviceUnavailable(uid: uid)
            lastErrorDescription = error.localizedDescription
            throw error
        }
        routeConfiguration.selectedOutputUID = uid
        try syncMasterVolumeMonitorToSelectedOutput()
        lastErrorDescription = nil
    }

    func addEQBand(_ band: EQBand = EQBand()) throws {
        guard stereoEQConfiguration.editableBands.count < EQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(stereoEQConfiguration.editableBands.count + 1)
        }
        var updated = stereoEQConfiguration
        var bands = updated.editableBands
        bands.append(band)
        updated.replaceEditableBands(bands)
        try applyStereoEQConfiguration(updated)
    }

    func updateEQBand(_ band: EQBand) throws {
        var updated = stereoEQConfiguration
        guard updated.editableBands.contains(where: { $0.id == band.id }) else { return }
        updated.updateEditableBand(band)
        try applyStereoEQConfiguration(updated)
    }

    func removeEQBand(id: UUID) throws {
        var updated = stereoEQConfiguration
        updated.removeEditableBand(id: id)
        try applyStereoEQConfiguration(updated)
    }

    func setEQBypassed(_ bypassed: Bool) throws {
        var updated = stereoEQConfiguration
        updated.bypassed = bypassed
        try applyStereoEQConfiguration(updated)
    }

    func setEQPhaseMode(_ mode: EQPhaseMode) throws {
        guard mode != stereoEQConfiguration.phaseMode else { return }
        var updated = stereoEQConfiguration
        updated.phaseMode = mode
        try applyStereoEQConfiguration(updated)
    }

    func setEQChannelMode(_ mode: EQChannelMode) throws {
        var updated = stereoEQConfiguration
        updated.setChannelMode(mode)
        try applyStereoEQConfiguration(updated)
    }

    func setEQEditChannel(_ channel: EQEditChannel) {
        var updated = stereoEQConfiguration
        updated.setEditChannel(channel)
        stereoEQConfiguration = updated
        eqConfiguration = legacyEQConfiguration(from: updated)
        lastErrorDescription = nil
    }

    func replaceStereoEQConfiguration(_ configuration: StereoEQConfiguration) throws {
        try applyStereoEQConfiguration(configuration)
    }

    /// E27 S3b: starts, moves or ends the Listen audition. The stored EQ is untouched; the
    /// rendered EQ becomes one unity-peak band-pass (minimum phase) and returns on `nil`.
    /// Control thread only; it publishes through the normal EQ snapshot path.
    func setEQAudition(_ override: EQAuditionOverride?) throws {
        guard override != eqAudition else { return }
        let previous = eqAudition
        eqAudition = override
        do {
            try applyStereoEQConfiguration(stereoEQConfiguration, forceRepublish: true)
        } catch {
            eqAudition = previous
            throw error
        }
    }

    func replaceEQConfiguration(_ configuration: EQConfiguration) throws {
        var updated = stereoEQConfiguration
        updated.phaseMode = configuration.phaseMode
        updated.bypassed = configuration.bypassed
        updated.replaceEditableBands(configuration.bands)
        try applyStereoEQConfiguration(updated)
    }

    func replacePlaybackControlConfiguration(_ configuration: PlaybackControlConfiguration) throws {
        try applyPlaybackControlConfiguration(configuration)
    }

    func setCrosstalkCancellationEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.crosstalkCancellationEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setCrosstalkCancellationAmount(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.crosstalkCancellationAmountRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkCancellationAmount(value)
        }
        var updated = playbackControlConfiguration
        updated.crosstalkCancellationAmount = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setCrosstalkHeadShadowFrequency(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.crosstalkHeadShadowFrequencyRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkHeadShadowFrequency(value)
        }
        var updated = playbackControlConfiguration
        updated.crosstalkHeadShadowFrequencyHz = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setSpeakerCrossfeedEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.speakerCrossfeedEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setSpeakerCrossfeedAmount(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.speakerCrossfeedRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidSpeakerCrossfeed(value)
        }
        var updated = playbackControlConfiguration
        updated.speakerCrossfeedAmount = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setSymmetryBalanceEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.symmetryBalanceEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setSymmetryBalancePosition(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.symmetryBalanceRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidSymmetryBalance(value)
        }
        var updated = playbackControlConfiguration
        updated.symmetryBalancePosition = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setChannelBalance(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.balanceRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidBalance(value)
        }
        var updated = playbackControlConfiguration
        updated.balance = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setInterChannelDelayMs(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.interChannelDelayRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidInterChannelDelay(value)
        }
        var updated = playbackControlConfiguration
        updated.interChannelDelayMs = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setGlobalDSPBypassed(_ bypassed: Bool) throws {
        var updated = playbackControlConfiguration
        updated.globalBypassed = bypassed
        try applyPlaybackControlConfiguration(updated)
    }

    func setFlatAuditionEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.auditionMode = enabled ? .reference : .processed
        try applyPlaybackControlConfiguration(updated)
    }

    func setAuditionMode(_ mode: AuditionMode) throws {
        if mode == .delta, !deltaAuditionAvailable {
            throw LiveNChannelTransportError.routingRefused("the delta audition is not available with speaker routing or Virtual Speakers; switch to Processed or Reference.")
        }
        var updated = playbackControlConfiguration
        updated.auditionMode = mode
        try applyPlaybackControlConfiguration(updated)
    }

    func setSoftwareVolumeKeyStep(_ step: MasterVolumeKeyStep) {
        guard step.isValid else { return }
        softwareVolumeKeyStep = step
    }

    func setMasterVolumeLevel(_ level: Double) throws {
        guard level.isFinite, MasterVolumeConfiguration.levelRange.contains(level) else {
            throw MasterVolumeConfigurationError.invalidLevel(level)
        }
        var updated = masterVolumeConfiguration
        updated.level = level
        try applyMasterVolumeConfiguration(updated, writeDevice: true)
    }

    func setMasterMuted(_ muted: Bool) throws {
        var updated = masterVolumeConfiguration
        updated.muted = muted
        try applyMasterVolumeConfiguration(updated, writeDevice: true)
    }

    func replaceGainConfiguration(_ configuration: DSPGainConfiguration) throws {
        try applyGainConfiguration(configuration)
    }

    /// Applies the PR113B A/B-safe content domain as one complete graph
    /// transition. Playback-System state, output routing, room/speaker
    /// correction, master/output gain and Audio Unit topology remain owned by
    /// their existing domains and are only reattached to the candidate graph.
    ///
    /// The extra attenuation is intentionally non-positive and exists only for
    /// measured A/B level matching. It is not written back into the captured
    /// snapshot.
    func transitionContentAuditionState(
        _ state: ContentABAuditionState,
        additionalInputAttenuationDB: Double = 0
    ) throws {
        guard additionalInputAttenuationDB.isFinite,
              (-24.0...0.0).contains(additionalInputAttenuationDB) else {
            throw DSPGainConfigurationError.invalidInputPreamp(
                state.inputPreampDB + additionalInputAttenuationDB
            )
        }

        try validateStereoEQStorage(state.stereoEQ)

        var targetGain = gainConfiguration
        targetGain.inputPreampDB = min(
            max(
                state.inputPreampDB + additionalInputAttenuationDB,
                DSPGainConfiguration.inputPreampRange.lowerBound
            ),
            DSPGainConfiguration.inputPreampRange.upperBound
        )
        targetGain.headroomAttenuationDB = state.headroomAttenuationDB

        guard DSPGainConfiguration.inputPreampRange
                .contains(targetGain.inputPreampDB) else {
            throw DSPGainConfigurationError.invalidInputPreamp(
                targetGain.inputPreampDB
            )
        }
        guard DSPGainConfiguration.headroomAttenuationRange
                .contains(targetGain.headroomAttenuationDB) else {
            throw DSPGainConfigurationError.invalidHeadroomAttenuation(
                targetGain.headroomAttenuationDB
            )
        }

        let clampedAmbientTarget =
            ambientTargetClampedToHeadroom(
                ambientCompensationRuntimeTarget,
                gainConfiguration: targetGain
            )
        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: targetGain,
                ambientTarget: clampedAmbientTarget
            )

        // E9 S5b: the graph builders read the output-protection policy; whatever happens, leave it matching the stored settings.
        UnifiedGraphOutputProtection.apply(settings: state.dynamics.outputProtection ?? OutputProtectionSettings())
        defer { UnifiedGraphOutputProtection.apply(settings: dynamicsConfiguration.outputProtection ?? OutputProtectionSettings()) }
        if immutableSemanticTransportActive {
            if state.stereoEQ != stereoEQConfiguration
                || state.dynamics != dynamicsConfiguration
                || targetGain != gainConfiguration
                || clampedAmbientTarget != ambientCompensationRuntimeTarget {
                try requireLiveGraphEdits()
                var inputs = currentLiveGraphInputs
                inputs.stereoEQ = state.stereoEQ
                inputs.dynamics = state.dynamics
                inputs.gain = targetGain
                inputs.ambient = clampedAmbientTarget
                try republishLiveGraph(inputs)
            }
        } else if let session = transportSession {
            // E28 S8: a profile switch changes the dynamics, so the stereo session's extras follow it (put back if refused).
            let previousExtras = session.dynamicsExtras
            session.setDynamicsExtras(DynamicsGraphExtras.make(
                state.dynamics, sampleRate: session.outputFormat.sampleRate, flagOn: FeatureFlags().isEnabled(.dynamicsExtras)))
            var extrasAdopted = false
            defer { if !extrasAdopted { session.setDynamicsExtras(previousExtras) } }
            var graph = try state.stereoEQ.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: targetGain,
                bassManagementConfiguration:
                    renderBassManagementConfiguration(),
                dynamicsConfiguration: state.dynamics.mergingFoldProtection(foldMatrixInUse),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )

            var preparedEQFIRProgram: PreparedEQFIRProgram?
            if !processingIsBypassed(playbackControlConfiguration),
               state.stereoEQ.requiresEQFIRProgram,
               !state.stereoEQ.bypassed {
                let prepared =
                    try prepareEQFIRProgram(state.stereoEQ, for: session)
                try attachEQFIRProgram(prepared, to: &graph)
                preparedEQFIRProgram = prepared
            }

            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try applyAudioUnitRackLatency(to: &graph)
            try attachAmbientCompensation(
                clampedAmbientTarget,
                to: &graph
            )
            try attachActiveQuietZone(
                candidateQuietZone,
                to: &graph
            )

            // Always use the sample-domain structural transition for A/B.
            // Even when only biquad/gain values differ this avoids an
            // instantaneous coefficient/gain discontinuity at the output.
            try session.transitionDSPGraph(graph)
            extrasAdopted = true
            activeEQFIRProgram = preparedEQFIRProgram
            linearPhaseDesignInfo = preparedEQFIRProgram?.designInfo
        } else {
            // Validate the complete target graph while idle even though there
            // is no transport to publish it to yet.
            let validationRate =
                selectedOutputDevice?.nominalSampleRate ?? 48_000
            _ = try state.stereoEQ.makeGraphSnapshot(
                sampleRate: validationRate,
                gainConfiguration: targetGain,
                bassManagementConfiguration:
                    renderBassManagementConfiguration(),
                dynamicsConfiguration: state.dynamics.mergingFoldProtection(foldMatrixInUse),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            activeEQFIRProgram = nil
            linearPhaseDesignInfo = nil
        }

        stereoEQConfiguration = state.stereoEQ
        eqConfiguration = legacyEQConfiguration(from: state.stereoEQ)
        dynamicsConfiguration = state.dynamics
        clearDynamicsListening()  // E28 S7d (G36): a profile switch ends listening and solo
        gainConfiguration = targetGain
        ambientCompensationRuntimeTarget = clampedAmbientTarget
        activeQuietZoneRuntimeTarget = candidateQuietZone
        lastErrorDescription = nil
    }

    func setInputPreampDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.inputPreampRange.contains(value) else {
            throw DSPGainConfigurationError.invalidInputPreamp(value)
        }
        var updated = gainConfiguration
        updated.inputPreampDB = value
        try applyGainConfiguration(updated)
    }

    /// Applies a Headroom Assistant recommendation through the same
    /// sample-domain silent-boundary transition used for other click-sensitive
    /// structural graph changes. This changes only the existing headroom gain;
    /// it does not save/overwrite the selected Content Preset.
    func transitionHeadroomAttenuationDB(_ value: Double) throws {
        guard value.isFinite,
              DSPGainConfiguration.headroomAttenuationRange
                .contains(value) else {
            throw DSPGainConfigurationError
                .invalidHeadroomAttenuation(value)
        }

        var updated = gainConfiguration
        updated.headroomAttenuationDB = value

        let clampedAmbientTarget =
            ambientTargetClampedToHeadroom(
                ambientCompensationRuntimeTarget,
                gainConfiguration: updated
            )
        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: updated,
                ambientTarget: clampedAmbientTarget
            )

        if immutableSemanticTransportActive {
            if updated != gainConfiguration || clampedAmbientTarget != ambientCompensationRuntimeTarget {
                try requireLiveGraphEdits()
                var inputs = currentLiveGraphInputs
                inputs.gain = updated
                inputs.ambient = clampedAmbientTarget
                try republishLiveGraph(inputs)
            }
        } else if let session = transportSession {
            var graph = try renderStereoEQConfiguration
                .makeGraphSnapshot(
                    sampleRate:
                        session.outputFormat.sampleRate,
                    gainConfiguration: updated,
                    bassManagementConfiguration:
                        renderBassManagementConfiguration(),
                    dynamicsConfiguration:
                        dynamicsConfiguration,
                    playbackConfiguration:
                        playbackControlConfiguration,
                    masterGainLinear:
                        currentMasterSoftwareGain
                )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration:
                    renderStereoEQConfiguration,
                playbackConfiguration:
                    playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration:
                    playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration:
                    playbackControlConfiguration
            )
            try applyAudioUnitRackLatency(to: &graph)
            try attachAmbientCompensation(
                clampedAmbientTarget,
                to: &graph
            )
            try attachActiveQuietZone(
                candidateQuietZone,
                to: &graph
            )
            try session.transitionDSPGraph(graph)
        }

        gainConfiguration = updated
        ambientCompensationRuntimeTarget =
            clampedAmbientTarget
        activeQuietZoneRuntimeTarget =
            candidateQuietZone
        lastErrorDescription = nil
    }

    func setHeadroomAttenuationDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.headroomAttenuationRange.contains(value) else {
            throw DSPGainConfigurationError.invalidHeadroomAttenuation(value)
        }
        var updated = gainConfiguration
        updated.headroomAttenuationDB = value
        try applyGainConfiguration(updated)
    }

    func setOutputGainDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.outputGainRange.contains(value) else {
            throw DSPGainConfigurationError.invalidOutputGain(value)
        }
        var updated = gainConfiguration
        updated.outputGainDB = value
        try applyGainConfiguration(updated)
    }

    func replaceMultiOutputRoutingConfiguration(
        _ configuration: MultiOutputRoutingConfiguration?
    ) throws {
        if let configuration {
            try configuration.validateStructure()
        }
        if configuration?.enabled == true, outputDeviceProfileConfiguration?.enabled == true {
            throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
        }
        if configuration?.enabled == true, headphoneDeviceProfileConfiguration?.enabled == true {
            throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
        }
        guard lifecycle.state == .idle || configuration == multiOutputRoutingConfiguration else {
            throw MultiOutputRoutingError.routingChangeRequiresIdle
        }
        multiOutputRoutingConfiguration = configuration
        lastErrorDescription = nil
    }

    func replaceOutputDeviceProfileConfiguration(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws {
        if configuration?.enabled == true {
            try configuration?.validateStructure(
                bassManagementEnabled: bassManagementConfiguration.enabled
            )
            if multiOutputRoutingConfiguration?.enabled == true {
                throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
            }
            if headphoneDeviceProfileConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.speakerProfileConflict
            }
        }
        guard lifecycle.state == .idle || configuration == outputDeviceProfileConfiguration else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        outputDeviceProfileConfiguration = configuration
        lastErrorDescription = nil
    }

    func replaceHeadphoneDeviceProfileConfiguration(
        _ configuration: HeadphoneDeviceProfileConfiguration?
    ) throws {
        if let configuration, configuration.enabled {
            if outputDeviceProfileConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.speakerProfileConflict
            }
            if multiOutputRoutingConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
            }
            if !speakerDriverProcessingConfiguration.isNeutral {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("per-driver speaker processing")
            }
            if bassManagementConfiguration.enabled {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("speaker bass management")
            }
            if roomCorrectionConfiguration.enabled {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("speaker room correction")
            }
            if speakerIRConfiguration.enabled {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("Speaker IR")
            }
            if let output = selectedOutputDevice {
                try configuration.validateStructure(sampleRate: output.nominalSampleRate)
            }
        }
        if lifecycle.state != .idle {
            let context = HeadphoneLiveEditPlanner.Context(
                unifiedGraphEnabled: unifiedGraphEnabled,
                lifecycleRunning: lifecycle.state == .running,
                binauralSession: binauralHeadphoneTransportSession.map { $0.unifiedGraphActive ? .graph : .legacy } ?? .none,
                nChannelSessionActive: nChannelTransportSession != nil,
                stereoHeadphoneGraphActive: transportSession?.headphoneGraphActive == true)
            switch HeadphoneLiveEditPlanner.plan(from: headphoneDeviceProfileConfiguration, to: configuration, context: context) {
            case .unchanged: break
            case .refuse: throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart
            case .liveEdit(let assetChanged):
                guard let configuration else { throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart }
                if transportSession?.headphoneGraphActive == true {
                    try applyLiveStereoHeadphoneEdit(configuration)
                } else {
                    try applyLiveHeadphoneEdit(configuration, assetChanged: assetChanged)
                }
                return
            case .reconfigure:
                try validateHeadphoneSessionKindChange(configuration)
                headphoneDeviceProfileConfiguration = configuration
                lastErrorDescription = nil
                scheduleSampleRateReconfiguration(countsAsSampleRateChange: false, fadeOut: true, settleDelay: 0.03)
                return
            }
        }
        headphoneDeviceProfileConfiguration = configuration
        if configuration?.enabled == true,
           configuration?.spatialMode == .virtualSpeakers,
           configuration?.headTracking?.enabled == true {
            headTrackingRuntimeStatus = .configuredStopped
        } else {
            headTrackingRuntimeStatus = .disabled
        }
        lastErrorDescription = nil
    }

    /// E6 S9c: everything a session-kind change would need at the rebuild, checked before the change is committed so
    /// a refusal leaves the running session and the stored configuration alone.
    private func validateHeadphoneSessionKindChange(_ configuration: HeadphoneDeviceProfileConfiguration?) throws {
        guard let configuration, configuration.enabled else { return }
        guard let output = selectedOutputDevice else {
            throw HeadphoneDeviceProfileError.outputDeviceRequired
        }
        let selected = try configuration.validateForActivation(
            availableDevices: outputDevices, selectedOutputUID: output.uid, sampleRate: output.nominalSampleRate)
        if configuration.spatialMode == .stereo {
            guard multiOutputRoutingConfiguration?.enabled != true else {
                throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
            }
        }
        if configuration.spatialMode == .virtualSpeakers {
            let source = try configuration.resolveProgramSource(availableDevices: outputDevices, selectedOutput: selected)
            guard source.supports(sampleRate: output.nominalSampleRate) else {
                throw BinauralHeadphoneTransportError.sampleRateMismatch(
                    source: source.nominalSampleRate, output: output.nominalSampleRate)
            }
            try validateBinauralHeadphoneActivation()
        }
    }

    /// E25 S2: sets the stereo session's mono-bass filter and speaker feed calibration (from the compiled
    /// arrangement). Built dark: the arrangement wizard (S3) calls it.
    func applyStereoAlignment(_ alignment: StereoBassAlignment?) throws {
        if let session = transportSession {
            try session.applyStereoAlignment(alignment)
        } else if let alignment {
            if let issue = alignment.issue { throw issue }
            if !unifiedGraphEnabled, let refusal = alignment.legacyKernelRefusal { throw refusal }
        }
        stereoAlignment = alignment
        lastErrorDescription = nil
    }

    /// The stored dynamics with the fold's output limiter merged in while a wider source is folded (stricter of each
    /// setting; see `DynamicsConfiguration.mergingFoldProtection`).
    func renderDynamicsConfiguration() -> DynamicsConfiguration {
        dynamicsConfiguration.mergingFoldProtection(foldMatrixInUse)
    }

    /// E25 S8a: sets the wider program source and fold. The source is tapped and folded onto the two feeds inside the
    /// capture callback, so the change needs a new tap: a running stereo session is rebuilt through the planned-profile
    /// path (one short dropout). Called by the Speakers tab (S8b) behind.
    func applyProgramFoldDown(_ plan: ProgramFoldDownPlan?) throws {
        if plan != nil {
            if let reason = ProgramFoldDownPlan.incompatibility(
                sameDeviceOrAggregateOutput: multiOutputRoutingConfiguration?.enabled == true,
                headphoneProfileEnabled: headphoneDeviceProfileConfiguration?.enabled == true) {
                throw CoreAudioTransportError.programFoldFailed(reason)
            }
        }
        guard plan != programFoldPlan else { return }
        programFoldPlan = plan
        lastErrorDescription = nil
        if transportSession != nil {
            scheduleSampleRateReconfiguration(countsAsSampleRateChange: false, fadeOut: true, cause: .plannedProfileChange)
        }
    }

    /// What `buildStereoTransport` does for this output given the configured fold and the devices present now.
    func programFoldBuildDecision(for output: AudioOutputDevice) -> ProgramFoldDownPlan.BuildDecision {
        ProgramFoldDownPlan.buildDecision(
            plan: programFoldPlan, availableDevices: outputDevices, sampleRate: output.nominalSampleRate, driverPathActive: DriverCaptureSelection.shared.current != nil)
    }

    /// E6 S9d: a headphone profile edit inside one graph-rendered stereo session. The session rebuilds the HEADPHONE
    /// and ear delay stages and republishes; stored state changes only after the graph accepted it.
    private func applyLiveStereoHeadphoneEdit(_ configuration: HeadphoneDeviceProfileConfiguration) throws {
        guard let session = transportSession else {
            throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart
        }
        try configuration.validateStructure(sampleRate: session.outputFormat.sampleRate)
        try session.applyLiveHeadphoneProfile(configuration)
        headphoneDeviceProfileConfiguration = configuration
        lastErrorDescription = nil
    }

    /// E6 S9c: a headphone profile edit inside one graph-rendered binaural session. The channel correction (headroom,
    /// gain, polarity, EQ, delay) is laid onto the retained base spec and republished as a posted parameter or a
    /// faded rebuild; stored state changes only after the graph accepted it. A new HRTF asset is prepared off the main
    /// actor and published when ready, the old one rendering meanwhile.
    private func applyLiveHeadphoneEdit(
        _ configuration: HeadphoneDeviceProfileConfiguration, assetChanged: Bool
    ) throws {
        guard let session = binauralHeadphoneTransportSession, let base = session.unifiedGraphBaseSpec else {
            throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart
        }
        try configuration.validateStructure(sampleRate: session.outputFormat.sampleRate)
        switch UnifiedGraphTranslator.binauralApplyHeadphone(base: base, profile: configuration) {
        case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
        case .success(let newBase): try republishLiveGraph(currentLiveGraphInputs, headphoneBase: newBase)
        }
        headphoneDeviceProfileConfiguration = configuration
        lastErrorDescription = nil
        if assetChanged { beginHeadphoneAssetSwap(session: session, profile: configuration) }
    }

    private func beginHeadphoneAssetSwap(
        session: CoreAudioBinauralHeadphoneTransportSession, profile: HeadphoneDeviceProfileConfiguration
    ) {
        headphoneAssetGeneration &+= 1
        let generation = headphoneAssetGeneration
        guard let reference = profile.binauralProfile else { return }
        let rate = session.outputFormat.sampleRate
        let store = binauralProfileAssetStore
        let cache = binauralAssetCache
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<UnifiedGraphSpec, Error>
            do {
                let asset = try cache.asset(for: reference, sampleRate: rate, store: store)
                switch UnifiedGraphTranslator.binauralBaseSpec(
                    asset: asset, layout: profile.programLayout, profile: profile, outputChannels: 2,
                    sampleRate: rate, headTracking: profile.headTracking?.enabled == true
                ) {
                case .success(let base): result = .success(base)
                case .failure(let reason): result = .failure(LiveNChannelTransportError.unifiedGraphRejected(reason))
                }
            } catch {
                result = .failure(error)
            }
            await self?.finishHeadphoneAssetSwap(
                generation: generation, reference: reference, session: session, result: result)
        }
    }

    private func finishHeadphoneAssetSwap(
        generation: UInt64,
        reference: BinauralProfileReference,
        session: CoreAudioBinauralHeadphoneTransportSession,
        result: Result<UnifiedGraphSpec, Error>
    ) {
        guard generation == headphoneAssetGeneration,
              binauralHeadphoneTransportSession === session,
              lifecycle.state == .running,
              let profile = headphoneDeviceProfileConfiguration,
              profile.binauralProfile == reference else { return }
        do {
            // Edits made while the asset prepared are already in the configuration: lay them onto the new set.
            let prepared = try result.get()
            let newBase: UnifiedGraphSpec
            switch UnifiedGraphTranslator.binauralApplyHeadphone(base: prepared, profile: profile) {
            case .success(let base): newBase = base
            case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
            }
            try republishLiveGraph(currentLiveGraphInputs, headphoneBase: newBase)
            renderedBinauralProfile = reference
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            if var restored = headphoneDeviceProfileConfiguration, let rendered = renderedBinauralProfile {
                restored.binauralProfile = rendered
                headphoneDeviceProfileConfiguration = restored
            }
        }
    }

    func recenterHeadTracking() {
        headTrackingController?.recenter()
    }

    func importNormalizedBinauralProfile(from url: URL) throws -> BinauralProfileReference {
        let reference = try binauralProfileAssetStore.importNormalizedDocument(from: url)
        lastErrorDescription = nil
        return reference
    }

    func replaceSpeakerDriverProcessingConfiguration(
        _ configuration: SpeakerDriverProcessingConfiguration
    ) throws {
        try configuration.validateStructure()
        guard lifecycle.state == .idle || configuration == speakerDriverProcessingConfiguration else {
            throw SpeakerDriverProcessingError.changesRequireIdle
        }
        speakerDriverProcessingConfiguration = configuration
        lastErrorDescription = nil
    }

    func replaceBassManagementConfiguration(_ configuration: BassManagementConfiguration) throws {
        guard configuration.frequencyHz.isFinite,
              configuration.lowerFrequencyRange.contains(configuration.frequencyHz) else {
            throw BassManagementConfigurationError.invalidFrequency(configuration.frequencyHz)
        }
        guard configuration.subGainDB.isFinite,
              BassManagementConfiguration.subGainRange.contains(configuration.subGainDB) else {
            throw BassManagementConfigurationError.invalidSubGain(configuration.subGainDB)
        }
        guard configuration.subPhaseAlignmentFrequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange.contains(configuration.subPhaseAlignmentFrequencyHz) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentFrequency(
                configuration.subPhaseAlignmentFrequencyHz
            )
        }
        guard configuration.subPhaseAlignmentQ.isFinite,
              BassManagementConfiguration.subPhaseAlignmentQRange.contains(configuration.subPhaseAlignmentQ) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentQ(configuration.subPhaseAlignmentQ)
        }
        if configuration.physicalOutputMode == .triAmp {
            let upper = configuration.upperFrequencyHz ?? .nan
            guard upper.isFinite, BassManagementConfiguration.speakerFrequencyRange.contains(upper),
                  upper > configuration.frequencyHz else {
                throw BassManagementConfigurationError.invalidUpperFrequency(upper)
            }
        }
        if let outputDeviceProfile = outputDeviceProfileConfiguration, outputDeviceProfile.enabled {
            try outputDeviceProfile.validateStructure(bassManagementEnabled: configuration.enabled)
        }
        if immutableSemanticTransportActive, configuration != bassManagementConfiguration {
            // The crossover topology is fixed when the session starts, so toggling bass management restarts.
            // Retuning an enabled N-channel crossover republishes the graph. A graph-rendered binaural
            // session has no bass stage in the graph, so with `enabled` unchanged its bass edits are live
            // state commits. A legacy binaural session still needs a restart for any change.
            let binauralGraphLive = binauralHeadphoneTransportSession?.unifiedGraphActive == true
            if (binauralHeadphoneTransportSession != nil && !binauralGraphLive)
                || configuration.enabled != bassManagementConfiguration.enabled {
                throw LiveNChannelTransportError.configurationChangeRequiresRestart
            }
        }
        if physicalSpeakerBusRoutingActive, lifecycle.state != .idle, configuration != bassManagementConfiguration {
            throw BassManagementConfigurationError.physicalCrossoverChangeRequiresIdle
        }
        if immutableSemanticTransportActive, configuration != bassManagementConfiguration,
           binauralHeadphoneTransportSession == nil {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.bass = configuration
            try republishLiveGraph(inputs)
        }
        if let session = transportSession {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(configuration),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: renderStereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
        }
        bassManagementConfiguration = configuration
        lastErrorDescription = nil
    }

    @discardableResult
    func applyDetectedMainsHum(minimumConfidence: Float = 0.55) throws -> Bool {
        guard let diagnostics = diagnosticsSnapshot().renderKernelDiagnostics,
              diagnostics.mainsDetectedFrequencyHz.isFinite,
              diagnostics.mainsDetectionConfidence >= minimumConfidence,
              MainsNotchConfiguration.detectedFrequencyRange.contains(Double(diagnostics.mainsDetectedFrequencyHz)) else {
            return false
        }
        var updated = dynamicsConfiguration
        updated.mainsNotch.detectedFundamentalHz = Double(diagnostics.mainsDetectedFrequencyHz)
        try replaceDynamicsConfiguration(updated)
        return true
    }

    func detectMainsHumOnce(minimumConfidence: Float = 0.55) async throws -> Bool {
        guard lifecycle.state == .running else { return false }
        let trackingWasEnabled = dynamicsConfiguration.mainsNotch.continuousTracking
        if !trackingWasEnabled {
            var detecting = dynamicsConfiguration
            detecting.mainsNotch.continuousTracking = true
            try replaceDynamicsConfiguration(detecting)
        }
        defer {
            if !trackingWasEnabled {
                var restored = dynamicsConfiguration
                restored.mainsNotch.continuousTracking = false
                try? replaceDynamicsConfiguration(restored)
            }
        }
        try await Task.sleep(nanoseconds: 1_150_000_000)
        return try applyDetectedMainsHum(minimumConfidence: minimumConfidence)
    }

    func pollMainsHumTracking(minimumConfidence: Float = 0.70) {
        guard dynamicsConfiguration.mainsNotch.continuousTracking,
              let diagnostics = diagnosticsSnapshot().renderKernelDiagnostics,
              diagnostics.mainsDetectionConfidence >= minimumConfidence else { return }
        let detected = Double(diagnostics.mainsDetectedFrequencyHz)
        guard detected.isFinite,
              MainsNotchConfiguration.detectedFrequencyRange.contains(detected),
              abs(detected - dynamicsConfiguration.mainsNotch.fundamentalHz) >= 0.03 else { return }
        var updated = dynamicsConfiguration
        updated.mainsNotch.detectedFundamentalHz = detected
        try? replaceDynamicsConfiguration(updated)
    }

    func applySpectralDenoiserPreset(_ preset: SpectralDenoiserPreset) throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.applyPreset(preset)
        try replaceDynamicsConfiguration(updated)
    }

    func captureSpectralNoiseProfile() throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.requestProfileCapture()
        try replaceDynamicsConfiguration(updated)
    }

    func resetSpectralNoiseProfile() throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.resetProfile()
        try replaceDynamicsConfiguration(updated)
    }

    /// E9 S5b: one output the Protection card's Outputs list can show.
    struct OutputProtectionLane: Equatable, Identifiable, Sendable {
        let index: Int
        let label: String
        let isSub: Bool
        var id: Int { index }
    }

    /// E9 S5b: the outputs that have user protection of their own under `e9.output-protection`: the program lanes (one linked
    /// group unless "Independent per output" is on) then each subwoofer lane. Empty when the flag is off, or for a routed or
    /// binaural session (those keep their own stages; E9 S5c). A stereo session shows its two lanes.
    var outputProtectionLanes: [OutputProtectionLane] {
        guard UnifiedGraphOutputProtection.current() != nil else { return [] }
        if let session = nChannelTransportSession {
            guard !session.routePlan.isRouted else { return [] }
            var lanes = session.routePlan.programLayout.roles.enumerated().map {
                OutputProtectionLane(index: $0.offset, label: $0.element.displayName, isSub: false)
            }
            for sub in 0..<Int(session.routePlan.subwooferCount) {
                lanes.append(OutputProtectionLane(index: lanes.count, label: "Sub \(sub + 1)", isSub: true))
            }
            return lanes
        }
        if binauralHeadphoneTransportSession != nil { return [] }
        return [OutputProtectionLane(index: 0, label: "Left", isSub: false), OutputProtectionLane(index: 1, label: "Right", isSub: false)]
    }

    /// E9 S5b (G14): gain reduction and true peak per output since the last call (read-and-reset in the core). Empty when no
    /// graph renders or the flag is off. Only the Outputs list calls this, so no other reader loses its values.
    func outputProtectionReadings() -> [UnifiedGraphOutputProtectionReading] {
        let lanes = outputProtectionLanes.count
        guard lanes > 0,
              let host = transportSession?.unifiedGraphReadback ?? nChannelTransportSession?.unifiedGraphReadback else { return [] }
        return host.outputProtectionReadings(lanes: lanes)
    }

    /// E9 S7: the published graph spec of the running render, with the output lane count, for the headroom assistant. nil when
    /// no graph renders. Control plane (the host lock); the model itself runs off the main actor on the copy.
    func headroomSpecSnapshot() -> (spec: UnifiedGraphSpec, lanes: Int)? {
        let lanes = outputProtectionLanes.count
        guard lanes > 0,
              let host = transportSession?.unifiedGraphReadback ?? nChannelTransportSession?.unifiedGraphReadback else { return nil }
        return (host.currentSpec, lanes)
    }

    /// E28 S7d: the graph host of whichever session renders now (stereo, N-channel or binaural), for listen and solo.
    var dynamicsListenHost: UnifiedGraphHost? {
        transportSession?.unifiedGraphReadback
            ?? nChannelTransportSession?.unifiedGraphReadback
            ?? binauralHeadphoneTransportSession?.unifiedGraphReadback
    }

    func setDynamicsListenerMirror(_ listener: DynamicsListener?, solo: Set<Int>) {
        if dynamicsListener != listener { dynamicsListener = listener }
        if dynamicsSoloBands != solo { dynamicsSoloBands = solo }
    }

    var dynamicsHasStereoSession: Bool { transportSession != nil }

    func reportDynamicsListenError(_ message: String) { lastErrorDescription = message }

    /// Where the live graph runs, `true` when the frozen kernel renders instead (so the extras cannot play).
    var dynamicsKernelRenders: Bool {
        if let session = transportSession { return !session.unifiedGraphActive }
        return !unifiedGraphEnabled
    }

    func replaceDynamicsConfiguration(_ configuration: DynamicsConfiguration) throws {
        let validationRate = transportSession?.outputFormat.sampleRate
            ?? nChannelTransportSession?.outputFormat.sampleRate
            ?? binauralHeadphoneTransportSession?.outputFormat.sampleRate
            ?? 48_000
        _ = try configuration.makeSnapshot(sampleRate: validationRate)
        let newProtection = try configuration.mergingFoldProtection(foldMatrixInUse).makeProtectionSnapshot(sampleRate: validationRate)
        // E9 S5b: the graph builders read the output-protection policy from here, so it is set before they run and put back if
        // the edit is refused (the running graph and the stored configuration then stay as they were).
        let previousOutputProtection = UnifiedGraphOutputProtection.apply(settings: configuration.outputProtection ?? OutputProtectionSettings())
        // Main-actor only: the policy static is written from here, the dynamicsConfiguration didSet and state restore.
        var committed = false
        // The stereo session's extras are restored on any throw before the edit is stored, whatever `committed` says.
        var extrasStored = false
        let previousStereoExtras = transportSession?.dynamicsExtras
        defer {
            if !extrasStored { transportSession?.setDynamicsExtras(previousStereoExtras) }
            if !committed { UnifiedGraphOutputProtection.apply(settings: previousOutputProtection) }
        }
        // E28 S7d part 3 (G34): a lookahead-only edit crossfades two copies of one signal, so it uses the linear law.
        let lookaheadOnly = FeatureFlags().isEnabled(.dynamicsExtras) && configuration.differsOnlyInLookahead(from: dynamicsConfiguration)
        let previousStereoFade = transportSession?.linearFadeForEQRepublish ?? false
        let previousNChannelFade = nChannelTransportSession?.linearFadeForEQRepublish ?? false
        if lookaheadOnly {
            transportSession?.linearFadeForEQRepublish = true
            nChannelTransportSession?.linearFadeForEQRepublish = true
        }
        defer {
            if lookaheadOnly {
                transportSession?.linearFadeForEQRepublish = previousStereoFade
                nChannelTransportSession?.linearFadeForEQRepublish = previousNChannelFade
            }
        }
        if immutableSemanticTransportActive, configuration != dynamicsConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.dynamics = configuration
            try republishLiveGraph(inputs)
            // The live graph now carries the new policy; keep it even if a later step throws.
            committed = true
        }
        if let session = transportSession {
            // E28 S8: the stereo graph is built with the new configuration's extras (the stored one is replaced below).
            session.setDynamicsExtras(DynamicsGraphExtras.make(
                configuration, sampleRate: session.outputFormat.sampleRate, flagOn: FeatureFlags().isEnabled(.dynamicsExtras)))
            let oldProtection = try renderDynamicsConfiguration().makeProtectionSnapshot(sampleRate: session.outputFormat.sampleRate)
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: configuration.mergingFoldProtection(foldMatrixInUse),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: renderStereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            let protectionStructureChanged = oldProtection.latencyFrames != newProtection.latencyFrames
                || oldProtection.effectiveFactor != newProtection.effectiveFactor
                || oldProtection.limiterEnabled != newProtection.limiterEnabled
                || dynamicsConfiguration.softClipper.enabled != configuration.softClipper.enabled
                || (dynamicsConfiguration.outputProtection?.independent ?? false) != (configuration.outputProtection?.independent ?? false)
            let denoiserStructureChanged = dynamicsConfiguration.spectralDenoiser.enabled != configuration.spectralDenoiser.enabled
                || (configuration.spectralDenoiser.enabled
                    && dynamicsConfiguration.spectralDenoiser.quality != configuration.spectralDenoiser.quality)
            if protectionStructureChanged || denoiserStructureChanged {
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
            } else {
                try applyAudioUnitRackLatency(to: &graph)
                try session.publishDSPGraph(graph)
            }
        }
        dynamicsConfiguration = configuration
        extrasStored = true
        committed = true
        lastErrorDescription = nil
        surfaceDynamicsListenRepostFailure()  // E28 S7d part 3 (G37): a rebuild that lost the listener is reported, not swallowed
    }

    func loadRoomCorrectionValidationFilter() throws {
        var updated = roomCorrectionConfiguration
        updated.filter = .validation
        try applyRoomCorrectionConfiguration(updated)
    }

    func setRoomCorrectionEnabled(_ enabled: Bool) throws {
        var updated = roomCorrectionConfiguration
        updated.enabled = enabled
        try applyRoomCorrectionConfiguration(updated)
    }

    func replaceRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {
        try applyRoomCorrectionConfiguration(configuration)
    }

    func loadSpeakerIRValidationFilter() throws {
        var updated = speakerIRConfiguration
        updated.filter = .validation
        try applySpeakerIRConfiguration(updated)
    }

    func setSpeakerIREnabled(_ enabled: Bool) throws {
        var updated = speakerIRConfiguration
        updated.enabled = enabled
        try applySpeakerIRConfiguration(updated)
    }

    func clearSpeakerIRFilter() throws {
        var updated = speakerIRConfiguration
        updated.enabled = false
        updated.filter = nil
        try applySpeakerIRConfiguration(updated)
    }

    func replaceSpeakerIRConfiguration(_ configuration: SpeakerIRConfiguration) throws {
        try applySpeakerIRConfiguration(configuration)
    }

    func start() throws {
        try start(resetProcessingSessionCounters: true)
    }

    func stop(cause: TransportTeardownCause) {
        guard lifecycle.state != .idle else { return }
        recoveryGeneration &+= 1
        reconfigurationWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        reconfigurationWorkItem = nil
        recoveryWorkItem = nil
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        if lifecycle.state != .stopping { try? setLifecycle(.stopping) }
        tearDownTransport(fadeOut: true, cause: cause)
        try? setLifecycle(.idle)
        clearStagedAudioUnitRack()
        audioUnitRackRebuildPending = false
        if lowLatencyRestorePending { restoreLowLatencyBuffers() }
    }

    func shutdownForTermination() {
        recoveryGeneration &+= 1
        reconfigurationWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        if lifecycle.state != .idle {
            if lifecycle.state != .stopping { try? setLifecycle(.stopping) }
            tearDownTransport(fadeOut: true, cause: .quit)
            try? setLifecycle(.idle)
        }
        if lifecycle.state == .idle {
            clearStagedAudioUnitRack()
            if lowLatencyOutputProfileActive || lowLatencyRestorePending {
                restoreLowLatencyBuffers()
            }
        }
        masterVolumeController.stopMonitoring()
        onVolumeKeyRouteChange?(false)
        eventMonitor.stop()
    }

    func setDetailedMeteringDemand(_ enabled: Bool) throws {
        if let session = nChannelTransportSession {
            session.setDetailedMeteringDemand(enabled)
            return
        }
        if let session = binauralHeadphoneTransportSession {
            session.setDetailedMeteringDemand(enabled)
            return
        }
        // E28 S6: the per-route meters of a same-device speaker map share the detailed-meter demand.
        N60RealtimeAudioBridgeSetRouteMeterDemand(enabled)
        let previousDemand = N60RealtimeAudioBridgeMeteringDemand()
        guard previousDemand != enabled else { return }

        N60RealtimeAudioBridgeSetMeteringDemand(enabled)
    }

    func setAnalysisDemand(_ demandMask: UInt32) {
        // E28 S6b, E33 S17: wide sessions run the same analysis on the capture ring they own.
        if let session = nChannelTransportSession { session.setAnalysisDemand(demandMask) }
        else if let session = binauralHeadphoneTransportSession { session.setAnalysisDemand(demandMask) }
        else { transportSession?.setAnalysisDemand(demandMask) }
    }

    /// E27 S2c (design note 16). Whether stereo graphs carry the Equalizer analyser taps. The analyser controller sets it;
    /// the engine and the core read no flag.
    private(set) var analyserTapsInstalled = false

    func setAnalyserTapsInstalled(_ installed: Bool) {
        guard installed != analyserTapsInstalled else { return }
        analyserTapsInstalled = installed
        transportSession?.setAnalyserTapsInstalled(installed)
    }

    /// Bit 0 records the EQ tap, bit 1 the after-dynamics tap; 0 releases both.
    func setAnalyserTapDemand(_ mask: UInt8) {
        transportSession?.setAnalyserTapDemand(mask)
    }

    /// True when a tap can be read now: installed, and the core graph (not the kernel) is rendering.
    var analyserTapsAvailable: Bool { transportSession?.analyserTapsAvailable ?? false }

    func analyserTapWindow(afterDynamics: Bool, frames: Int) -> EQAnalyserTapWindow? {
        guard let session = transportSession,
              let window = session.readAnalyserTap(afterDynamics: afterDynamics, frames: frames) else { return nil }
        return EQAnalyserTapWindow(left: window.left, right: window.right, sampleRate: session.outputSampleRate)
    }

    func analysisCaptureSnapshot() -> N60AnalysisCaptureSnapshot? {
        transportSession?.analysisCaptureSnapshot()
    }

    /// E26 S7b2c (G26): true for the stereo session and for a profile session whose graph carries the Quiet Zone feed
    /// (class A); the references come from the live `quietZoneHost` either way.
    var ambientPlaybackReferenceAvailable: Bool {
        (transportSession != nil
            && nChannelTransportSession == nil
            && binauralHeadphoneTransportSession == nil)
            || activeQuietZoneProfileRuntimeAvailable
    }

    var ambientPlaybackReferenceSampleRate: Double? {
        guard ambientPlaybackReferenceAvailable else { return nil }
        return quietZoneHost?.ambientReferenceSampleRate
    }

    func setAmbientPlaybackReferenceDemand(_ enabled: Bool) {
        guard ambientPlaybackReferenceAvailable else {
            quietZoneHost?.setAmbientReferenceDemand(false)
            return
        }
        quietZoneHost?.setAmbientReferenceDemand(enabled)
    }

    func ambientPlaybackReferenceSnapshot()
        -> N60AmbientPlaybackReferenceSnapshot? {
        guard ambientPlaybackReferenceAvailable else { return nil }
        return quietZoneHost?.ambientReferenceSnapshot()
    }

    func discardAmbientPlaybackReferenceFrames() {
        quietZoneHost?.discardAmbientReferenceFrames()
    }

    func readAmbientPlaybackReferenceFrames(
        maximumFrames: Int =
            Int(N60_AMBIENT_REFERENCE_CAPACITY_FRAMES)
    ) -> [N60AmbientPlaybackReferenceFrame] {
        guard ambientPlaybackReferenceAvailable else { return [] }
        return quietZoneHost?.readAmbientReferenceFrames(
            maximumFrames: maximumFrames
        ) ?? []
    }

    /// E4 S22b1: records what is written to the speakers for the feed-forward echo model.
    /// Set from `e4.feedforward-live`; while false nothing ever sets the demand.
    var speakerDriveFeatureEnabled = false
    private var speakerDriveDemandMux = SpeakerDriveDemandMux()
    var speakerDriveAnchorFanout = SpeakerDriveAnchorFanout()
    /// E4 S25 follow-up: runs the live reference pump; idle unless the shadow asks and the flag is on.
    @ObservationIgnored private(set) lazy var feedForwardLiveDriver = FeedForwardLiveDriver(host: self)

    func setSpeakerDriveDemand(_ requested: Bool) {
        speakerDriveDemandMux.shadow = requested
        applySpeakerDriveDemand()
    }

    /// E4 S25 follow-up: the live reference pump needs the output anchors.
    func setPumpDriveDemand(_ requested: Bool) {
        speakerDriveDemandMux.pump = requested
        applySpeakerDriveDemand()
    }

    func applySpeakerDriveDemand() {
        let allowed = SpeakerDriveDemandPolicy.demand(
            requested: speakerDriveDemandMux.requested,
            featureEnabled: speakerDriveFeatureEnabled,
            transportAvailable: ambientPlaybackReferenceAvailable
        )
        quietZoneHost?.setSpeakerDriveDemand(allowed)
    }

    func speakerDriveSnapshot() -> N60SpeakerDriveSnapshot? {
        quietZoneHost?.speakerDriveSnapshot()
    }

    /// E4 S25b: live feed-forward passthroughs. Arm needs the gate's inputs; the app supplies
    /// `liveOutputAuthorized` only from `FeedForwardLiveArmingController` (the user's request).
    func setFeedForwardLiveWeights(left: [Float], right: [Float]) -> Bool {
        speakerDriveFeatureEnabled && (quietZoneHost?.setFeedForwardLiveWeights(left: left, right: right) ?? false)
    }

    func armFeedForwardLive(gate: FeedForwardLiveArmGate.Inputs) -> UInt32? {
        var checked = gate
        checked.featureEnabled = speakerDriveFeatureEnabled
        return quietZoneHost?.armFeedForwardLive(gate: checked)
    }

    /// E4 S22b3: the echo stage's model, with the pump delay as timing. Refused (and cleared) with a
    /// subwoofer or bass management (owner decision of 3 Nov 2026, question 18) and while the pump has
    /// no delay yet. Nil clears.
    func setFeedForwardLiveEcho(_ payload: FeedForwardLiveEchoPayload?) -> Bool {
        guard speakerDriveFeatureEnabled, let transport = quietZoneHost else { return false }
        guard let payload, !bassManagementConfiguration.enabled else {
            _ = transport.setFeedForwardLiveEcho(nil, timingFrames: 0)
            return payload == nil
        }
        guard let rate = ambientPlaybackReferenceSampleRate, let delay = feedForwardLiveDriver.delaySeconds,
              delay > 0, delay < 0.1
        else { return false }
        return transport.setFeedForwardLiveEcho(payload, timingFrames: UInt32((delay * rate).rounded()))
    }

    func disarmFeedForwardLive() { quietZoneHost?.disarmFeedForwardLive() }

    func markFeedForwardLiveReferenceLost() { quietZoneHost?.markFeedForwardLiveReferenceLost() }

    func feedForwardLiveStatus() -> N60RenderKernelFeedForwardLiveStatus? {
        quietZoneHost?.feedForwardLiveStatus()
    }

    func pushFeedForwardLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64? {
        guard speakerDriveFeatureEnabled else { return nil }
        return quietZoneHost?.pushFeedForwardLiveReference(startIndex: startIndex, samples: samples)
    }

    func readSpeakerDriveAnchors() -> [N60SpeakerDriveAnchor] {
        quietZoneHost?.readSpeakerDriveAnchors(maximum: Int(N60_SPEAKER_DRIVE_ANCHOR_CAPACITY)) ?? []
    }

    /// The anchor ring has one consumer; the shadow and the live reference pump each get every anchor
    /// through this fan-out.
    func pullSpeakerDriveAnchors(for consumer: SpeakerDriveAnchorFanout.Consumer) -> [N60SpeakerDriveAnchor] {
        speakerDriveAnchorFanout.ingest(readSpeakerDriveAnchors())
        return speakerDriveAnchorFanout.drain(consumer)
    }

    func readSpeakerDriveFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        quietZoneHost?.readSpeakerDriveFrames(maximumFrames: maximumFrames) ?? []
    }

    var activeQuietZoneReferenceAvailable: Bool {
        activeQuietZoneStereoSpeakerRuntimeAvailable || activeQuietZoneProfileRuntimeAvailable
    }

    /// E26 S7b2c (G26): the tonal controller may run on the stereo route or on a profile session hosting the feed.
    var activeQuietZoneRuntimeAvailable: Bool {
        activeQuietZoneStereoSpeakerRuntimeAvailable || activeQuietZoneProfileRuntimeAvailable
    }

    var activeQuietZoneReferenceSampleRate: Double? {
        guard activeQuietZoneReferenceAvailable else {
            return nil
        }
        return quietZoneHost?
            .activeQuietZoneReferenceSampleRate
    }

    func setActiveQuietZoneReferenceDemand(_ enabled: Bool) {
        guard activeQuietZoneReferenceAvailable else {
            quietZoneHost?
                .setActiveQuietZoneReferenceDemand(false)
            return
        }
        quietZoneHost?
            .setActiveQuietZoneReferenceDemand(enabled)
    }

    func activeQuietZoneReferenceSnapshot()
        -> N60ActiveQuietZoneReferenceSnapshot? {
        guard activeQuietZoneReferenceAvailable else {
            return nil
        }
        return quietZoneHost?
            .activeQuietZoneReferenceSnapshot()
    }

    func discardActiveQuietZoneReferenceFrames() {
        quietZoneHost?
            .discardActiveQuietZoneReferenceFrames()
    }

    func readActiveQuietZoneReferenceFrames(
        maximumFrames: Int =
            Int(
                N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES
            )
    ) -> [N60ActiveQuietZoneReferenceFrame] {
        guard activeQuietZoneReferenceAvailable else {
            return []
        }
        return quietZoneHost?
            .readActiveQuietZoneReferenceFrames(
                maximumFrames: maximumFrames
            )
            ?? []
    }

    func productionAnalysisSnapshot() -> ProductionAnalysisSnapshot {
        if let session = nChannelTransportSession { return session.productionAnalysisSnapshot() }
        if let session = binauralHeadphoneTransportSession { return session.productionAnalysisSnapshot() }
        return transportSession?.productionAnalysisSnapshot() ?? .empty
    }

    func resetSpectrumPeakHold() {
        nChannelTransportSession?.resetSpectrumPeakHold()
        binauralHeadphoneTransportSession?.resetSpectrumPeakHold()
        transportSession?.resetSpectrumPeakHold()
    }

    /// E28 S6: per-route maxima for a stereo session whose output map drives several DAC channels (speakers plus subs on
    /// one device). Empty for every other session. Read-and-reset: the meter hub is the only caller while processing runs.
    func productionRouteMeters() -> [ProductionRouteMeter] {
        transportSession?.routeMeters() ?? []
    }

    func productionTransportMeterSnapshot() -> ProductionTransportMeterSnapshot? {
        if let session = nChannelTransportSession, let raw = session.bridgeSnapshot() {
            var meter = raw.meter
            let roles = session.routePlan.programLayout.roles
            let programChannels: [ProductionTransportChannelMeter] = roles.enumerated().map { index, role in
                let channel = UInt32(index)
                return ProductionTransportChannelMeter(
                    id: "program-\(role.rawValue)",
                    label: role.displayName,
                    channelIndex: channel,
                    peakLinear: N60LiveNChannelMeterProgramPeak(&meter, channel),
                    rmsLinear: N60LiveNChannelMeterProgramRMS(&meter, channel),
                    overRangeSamples: N60LiveNChannelMeterProgramOverRangeSamples(&meter, channel)
                )
            }

            var mapped: [(UInt32, String, String)] = []
            for (index, role) in roles.enumerated() {
                let physical = session.routePlan.programPhysicalChannels[index]
                guard physical != UInt32.max else { continue }
                mapped.append((physical, role.displayName, "physical-\(role.rawValue)"))
            }
            for sub in 0..<Int(session.routePlan.subwooferCount) {
                let physical = session.routePlan.subwooferPhysicalChannels[sub]
                guard physical != UInt32.max else { continue }
                mapped.append((physical, "Sub \(sub + 1)", "physical-sub-\(sub)"))
            }
            mapped.sort { $0.0 < $1.0 }
            let physicalOutputs = mapped.map { physical, label, id in
                ProductionTransportChannelMeter(
                    id: id,
                    label: label,
                    channelIndex: physical,
                    peakLinear: N60LiveNChannelMeterPhysicalPeak(&meter, physical),
                    rmsLinear: N60LiveNChannelMeterPhysicalRMS(&meter, physical),
                    overRangeSamples: N60LiveNChannelMeterPhysicalOverRangeSamples(&meter, physical)
                )
            }
            return ProductionTransportMeterSnapshot(
                kind: .semanticSpeakers,
                displayName: outputDeviceProfileConfiguration?.systemDisplayName
                    ?? session.routePlan.programLayout.displayName,
                programLayoutName: session.routePlan.programLayout.displayName,
                sampleRate: session.outputFormat.sampleRate,
                latencyFrames: raw.algorithmicLatencyFrames
                    + raw.adaptiveTransportLatencyFrames
                    + raw.roomTreatmentLatencyFrames,
                meteringEnabled: raw.meter.enabled,
                programChannels: programChannels,
                physicalOutputs: physicalOutputs,
                inputTruePeakLinear: nil,
                outputTruePeakLinear: nil,
                roomTreatment: raw.roomTreatmentConfigured
                    ? ProductionRoomTreatmentDiagnostics(
                        authorized: raw.roomTreatment.transition.authorized,
                        armRequested: raw.roomTreatment.transition.armRequested,
                        active: raw.roomTreatment.transition.state
                            == N60MIMOTreatmentStateActive,
                        transitioning:
                            raw.roomTreatment.transition.state
                                == N60MIMOTreatmentStateArming
                            || raw.roomTreatment.transition.state
                                == N60MIMOTreatmentStateDisarming
                            || raw.roomTreatment.transition.state
                                == N60MIMOTreatmentStateFaultFading,
                        faulted: raw.roomTreatment.transition.fault
                            != N60MIMOTreatmentFaultNone,
                        treatmentMix: raw.roomTreatment.transition.treatmentMix,
                        treatmentSourceCount: raw.roomTreatment.treatmentChannelCount,
                        latencyFrames: raw.roomTreatment.totalLatencyFrames,
                        processedFrames: raw.roomTreatment.processedFrames,
                        protectionClampSamples:
                            raw.roomTreatment.protectionClampSamples,
                        integrationFailures:
                            raw.roomTreatment.integrationFailures
                    )
                    : nil,
                renderFailures: raw.renderFailures,
                outputWriteFailures: raw.outputWriteFailures
            )
        }

        if let session = binauralHeadphoneTransportSession, let raw = session.bridgeSnapshot() {
            let meter = raw.meter
            let outputs = [
                ProductionTransportChannelMeter(
                    id: "headphone-left", label: "Left", channelIndex: 0,
                    peakLinear: meter.peakLeft, rmsLinear: meter.rmsLeft,
                    overRangeSamples: meter.overRangeLeft
                ),
                ProductionTransportChannelMeter(
                    id: "headphone-right", label: "Right", channelIndex: 1,
                    peakLinear: meter.peakRight, rmsLinear: meter.rmsRight,
                    overRangeSamples: meter.overRangeRight
                ),
            ]
            return ProductionTransportMeterSnapshot(
                kind: .virtualSpeakers,
                displayName: "Virtual \(session.programLayout.displayName) → Headphones",
                programLayoutName: session.programLayout.displayName,
                sampleRate: session.outputFormat.sampleRate,
                latencyFrames: raw.algorithmicLatencyFrames,
                meteringEnabled: meter.enabled,
                programChannels: [],
                physicalOutputs: outputs,
                inputTruePeakLinear: raw.protection.inputTruePeakLinear,
                outputTruePeakLinear: raw.protection.outputTruePeakLinear,
                roomTreatment: nil,
                renderFailures: raw.renderFailures,
                outputWriteFailures: raw.outputWriteFailures
            )
        }
        return nil
    }

    func diagnosticsSnapshot() -> AudioDiagnosticsSnapshot {
        let selectedDevice = selectedOutputDevice
        let currentCounters = transportSession?.counters()
            ?? nChannelTransportSession?.counters()
            ?? binauralHeadphoneTransportSession?.counters()
            ?? AudioTransportCounters()
        let processingSessionCounters = processingSessionArchivedCounters + currentCounters
        let lifetimeCounters = lifetimeArchivedCounters + currentCounters
        let activeTapSampleRate = transportSession?.tapFormat.sampleRate
            ?? nChannelTransportSession?.tapFormat.sampleRate
            ?? binauralHeadphoneTransportSession?.tapFormat.sampleRate
        let activeOutputSampleRate = transportSession?.outputFormat.sampleRate
            ?? nChannelTransportSession?.outputFormat.sampleRate
            ?? binauralHeadphoneTransportSession?.outputFormat.sampleRate
        let startupGateOpened = transportSession?.startupGateOpened
            ?? nChannelTransportSession?.startupGateOpened
            ?? binauralHeadphoneTransportSession?.startupGateOpened
        let startupGateTargetFrames = transportSession?.startupGateTargetFrames
            ?? nChannelTransportSession?.startupGateTargetFrames
            ?? binauralHeadphoneTransportSession?.startupGateTargetFrames
        let startupGateActivationFrames = transportSession?.startupGateActivationFrames
            ?? nChannelTransportSession?.startupGateActivationFrames
            ?? binauralHeadphoneTransportSession?.startupGateActivationFrames
        let stereoRenderDiagnostics = transportSession?.renderDiagnostics()
        // The stereo overlay already read FINAL_METER into outputMeter unless the bridge VU supplied it.
        let stereoFinalReading: StereoMeterReading? =
            (transportSession?.unifiedGraphReadback != nil && !N60RealtimeAudioBridgeOutputVUMeterDemand())
            ? stereoRenderDiagnostics?.outputMeter : nil
        // S8c: the stereo overlay also took this snapshot's gain-reduction and true-peak readings.
        let stereoDynamicsReading: UnifiedGraphDynamicsReading? = stereoRenderDiagnostics.flatMap { diagnostics in
            transportSession?.unifiedGraphReadback == nil ? nil : UnifiedGraphDynamicsReading(
                compressorGainReductionDB: diagnostics.compressorGainReductionDB,
                limiterGainReductionDB: diagnostics.limiterGainReductionDB,
                inputTruePeakLinear: diagnostics.inputTruePeakLinear,
                outputTruePeakLinear: diagnostics.outputTruePeakLinear,
                truePeakGuardActive: diagnostics.truePeakGuardActive)
        }
        return AudioDiagnosticsSnapshot(
            lifecycleState: lifecycle.state,
            selectedOutputUID: routeConfiguration.selectedOutputUID,
            selectedOutputName: selectedDevice?.name,
            selectedOutputPresent: selectedDevice != nil,
            selectedOutputNominalSampleRate: selectedDevice?.nominalSampleRate, selectedOutputTransport: selectedDevice?.transport,
            discoveredOutputCount: outputDevices.count,
            tapSampleRate: activeTapSampleRate,
            outputSampleRate: activeOutputSampleRate,
            sessionTransportCounters: processingSessionCounters,
            lifetimeTransportCounters: lifetimeCounters,
            renderKernelDiagnostics: stereoRenderDiagnostics,
            startupGateOpened: startupGateOpened,
            startupGateTargetFrames: startupGateTargetFrames,
            startupGateActivationFrames: startupGateActivationFrames,
            sampleRateChangesHandled: sampleRateChangesHandled,
            recoveryAttempts: recoveryAttempts,
            recoverySuccesses: recoverySuccesses,
            recoveryFailures: recoveryFailures,
            lastErrorDescription: lastErrorDescription,
            unifiedGraph: UnifiedGraphDiagnostics(
                host: transportSession?.unifiedGraphReadback
                    ?? nChannelTransportSession?.unifiedGraphReadback
                    ?? binauralHeadphoneTransportSession?.unifiedGraphReadback,
                programChannelCount: nChannelTransportSession.map {
                    $0.routePlan.programLayout.roles.count
                } ?? binauralHeadphoneTransportSession.map {
                    $0.programLayout.roles.count
                } ?? 2,
                fallbackReason: unifiedGraphEnabled
                    ? (transportSession?.unifiedGraphFallbackReason
                        ?? nChannelTransportSession?.unifiedGraphFallbackReason
                        ?? binauralHeadphoneTransportSession?.unifiedGraphFallbackReason)
                    : nil,
                stereoFinalReading: stereoFinalReading,
                stereoDynamicsReading: stereoDynamicsReading
            )
        )
    }

    private func legacyEQConfiguration(from configuration: StereoEQConfiguration) -> EQConfiguration {
        EQConfiguration(
            phaseMode: configuration.phaseMode,
            bypassed: configuration.bypassed,
            bands: configuration.sessionEditableBands
        )
    }

    private func processingIsBypassed(_ configuration: PlaybackControlConfiguration) -> Bool {
        FIRUpdatePolicy.isRawBypassed(configuration)
    }

    private func validateStereoEQStorage(_ configuration: StereoEQConfiguration) throws {
        try configuration.validateStorage(sampleRate: transportSession?.outputFormat.sampleRate)
    }

    private func applyStereoEQConfiguration(
        _ configuration: StereoEQConfiguration, forceRepublish: Bool = false
    ) throws {
        try validateStereoEQStorage(configuration)
        transportSession?.linearFadeForEQRepublish = true
        nChannelTransportSession?.linearFadeForEQRepublish = true
        defer {
            transportSession?.linearFadeForEQRepublish = false
            nChannelTransportSession?.linearFadeForEQRepublish = false
        }
        // E27 S3b: an active audition replaces what is rendered, never what is stored.
        let rendered = eqAudition.map { configuration.auditioned($0) } ?? configuration
        if immutableSemanticTransportActive, forceRepublish || rendered != renderStereoEQConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.stereoEQ = rendered
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try rendered.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )

            if processingIsBypassed(playbackControlConfiguration) {
                // The raw path is already active. Update state without rotating FIR
                // programs or fading an audibly identical raw graph.
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                activeEQFIRProgram = nil
                linearPhaseDesignInfo = nil
            } else {
                var preparedEQFIRProgram: PreparedEQFIRProgram?
                if rendered.requiresEQFIRProgram && !rendered.bypassed {
                    let prepared = try prepareEQFIRProgram(rendered, for: session)
                    preparedEQFIRProgram = prepared
                    linearPhaseDesignInfo = prepared.designInfo
                    try attachEQFIRProgram(prepared, to: &graph)
                } else {
                    linearPhaseDesignInfo = nil
                }

                try attachActiveRoomCorrectionProgramIfNeeded(
                    to: &graph,
                    playbackConfiguration: playbackControlConfiguration
                )

                let leavingEQFIR = activeEQFIRProgram != nil
                    && (!rendered.requiresEQFIRProgram || rendered.bypassed)
                let enteringOrReplacingEQFIR = preparedEQFIRProgram != nil
                if leavingEQFIR || enteringOrReplacingEQFIR {
                    try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                } else {
                    try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                }
                activeEQFIRProgram = preparedEQFIRProgram
            }
        } else {
            activeEQFIRProgram = nil
            linearPhaseDesignInfo = nil
        }

        stereoEQConfiguration = configuration
        eqConfiguration = legacyEQConfiguration(from: configuration)
        lastErrorDescription = nil
    }

    private func applyPlaybackControlConfiguration(_ configuration: PlaybackControlConfiguration) throws {
        guard configuration.balance.isFinite,
              PlaybackControlConfiguration.balanceRange.contains(configuration.balance) else {
            throw PlaybackControlConfigurationError.invalidBalance(configuration.balance)
        }
        guard configuration.interChannelDelayMs.isFinite,
              PlaybackControlConfiguration.interChannelDelayRange.contains(configuration.interChannelDelayMs) else {
            throw PlaybackControlConfigurationError.invalidInterChannelDelay(configuration.interChannelDelayMs)
        }
        if immutableSemanticTransportActive, configuration != playbackControlConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.playback = configuration
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: configuration,
                masterGainLinear: currentMasterSoftwareGain
            )

            let wasBypassed = processingIsBypassed(playbackControlConfiguration)
            let willBeBypassed = processingIsBypassed(configuration)

            if !willBeBypassed {
                if FIRUpdatePolicy.shouldPrepareEQFIR(
                    stereoEQ: renderStereoEQConfiguration,
                    playback: configuration
                ) {
                    if activeEQFIRProgram == nil {
                        let prepared = try prepareEQFIRProgram(renderStereoEQConfiguration, for: session)
                        activeEQFIRProgram = prepared
                        linearPhaseDesignInfo = prepared.designInfo
                    }
                    try attachActiveEQFIRProgramIfNeeded(
                        to: &graph,
                        stereoConfiguration: renderStereoEQConfiguration,
                        playbackConfiguration: configuration
                    )
                }

                if roomCorrectionConfiguration.isActiveOnStereoKernel {
                    guard let filter = roomCorrectionConfiguration.filter else {
                        throw RoomCorrectionConfigurationError.filterRequired
                    }
                    if activeRoomCorrectionProgram == nil {
                        activeRoomCorrectionProgram = try prepareRoomCorrectionProgram(filter, for: session)
                    }
                    try attachActiveRoomCorrectionProgramIfNeeded(
                        to: &graph,
                        playbackConfiguration: configuration
                    )
                }

                if speakerIRConfiguration.enabled {
                    guard let filter = speakerIRConfiguration.filter else {
                        throw SpeakerIRConfigurationError.filterRequired
                    }
                    if activeSpeakerIRProgram == nil {
                        activeSpeakerIRProgram = try prepareSpeakerIRProgram(filter, for: session)
                    }
                    try attachActiveSpeakerIRProgramIfNeeded(
                        to: &graph,
                        playbackConfiguration: configuration
                    )
                }
            }

            let auditionModeChanged = playbackControlConfiguration.auditionMode != configuration.auditionMode
            if wasBypassed != willBeBypassed || auditionModeChanged {
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
            } else {
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
            }
        }

        playbackControlConfiguration = configuration
        lastErrorDescription = nil
    }

    var currentMasterSoftwareGain: Float {
        masterVolumeConfiguration.softwareGain(for: masterVolumeCapabilities)
    }

    private func applyMasterVolumeConfiguration(
        _ configuration: MasterVolumeConfiguration,
        writeDevice: Bool
    ) throws {
        guard configuration.level.isFinite,
              MasterVolumeConfiguration.levelRange.contains(configuration.level) else {
            throw MasterVolumeConfigurationError.invalidLevel(configuration.level)
        }

        if writeDevice, let output = selectedOutputDevice {
            if masterVolumeCapabilities.controlMode == .device {
                try masterVolumeController.setVolume(configuration.level, deviceID: output.deviceID)
            }
            if masterVolumeCapabilities.usesDeviceMute {
                try masterVolumeController.setMuted(configuration.muted, deviceID: output.deviceID)
            }
        }

        let oldSoftwareGain = currentMasterSoftwareGain
        let newSoftwareGain = configuration.softwareGain(for: masterVolumeCapabilities)
        if let session = transportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: newSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(to: &graph, stereoConfiguration: renderStereoEQConfiguration, playbackConfiguration: playbackControlConfiguration)
            try attachActiveRoomCorrectionProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try attachActiveSpeakerIRProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
        }
        if let session = nChannelTransportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {
            session.setOutputGain(newSoftwareGain)
        }
        if let session = binauralHeadphoneTransportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {
            session.setOutputGain(newSoftwareGain)
        }

        masterVolumeConfiguration = configuration
        persistSoftwareMasterVolumeIfNeeded()
        lastErrorDescription = nil
    }

    private func persistSoftwareMasterVolumeIfNeeded() {
        guard masterVolumeCapabilities.controlMode == .softwareDSP,
              let uid = selectedOutputDevice?.uid,
              uid == masterVolumeSynchronizedOutputUID else { return }
        masterVolumeStore?.storeSoftwareVolume(masterVolumeConfiguration, forOutputUID: uid)
    }

    func syncMasterVolumeMonitorToSelectedOutput() throws {
        guard let output = selectedOutputDevice else {
            masterVolumeController.stopMonitoring()
            masterVolumeCapabilities = .softwareOnly
            onVolumeKeyRouteChange?(false)
            return
        }
        try masterVolumeController.monitor(deviceID: output.deviceID)
        try synchronizeMasterVolumeFromSelectedDevice()
        onVolumeKeyRouteChange?(masterVolumeCapabilities.controlMode == .softwareDSP)
    }

    private func synchronizeMasterVolumeFromSelectedDevice() throws {
        guard let output = selectedOutputDevice else { return }
        let previousCapabilities = masterVolumeCapabilities
        let snapshot = try masterVolumeController.inspect(deviceID: output.deviceID)
        masterVolumeCapabilities = snapshot.capabilities

        var updated = masterVolumeConfiguration
        let firstSyncForOutput = masterVolumeSynchronizedOutputUID != output.uid
        if snapshot.capabilities.controlMode == .device, let level = snapshot.level {
            updated.level = min(max(level, 0), 1)
        } else if snapshot.capabilities.controlMode == .softwareDSP,
                  firstSyncForOutput,
                  let restored = masterVolumeStore?.restoredSoftwareVolume(forOutputUID: output.uid) {
            updated.level = min(max(restored.level, 0), 1)
            if !snapshot.capabilities.usesDeviceMute {
                updated.muted = restored.muted
            }
        }
        if snapshot.capabilities.usesDeviceMute, let muted = snapshot.muted {
            updated.muted = muted
        }
        masterVolumeSynchronizedOutputUID = output.uid

        let oldGain = masterVolumeConfiguration.softwareGain(for: previousCapabilities)
        let newGain = updated.softwareGain(for: snapshot.capabilities)
        if let session = transportSession, abs(oldGain - newGain) > 0.000_001 {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: newGain
            )
            try attachActiveEQFIRProgramIfNeeded(to: &graph, stereoConfiguration: renderStereoEQConfiguration, playbackConfiguration: playbackControlConfiguration)
            try attachActiveRoomCorrectionProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try attachActiveSpeakerIRProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
        }
        if let session = nChannelTransportSession, abs(oldGain - newGain) > 0.000_001 {
            session.setOutputGain(newGain)
        }
        if let session = binauralHeadphoneTransportSession, abs(oldGain - newGain) > 0.000_001 {
            session.setOutputGain(newGain)
        }
        masterVolumeConfiguration = updated
    }

    private func handleMasterVolumeDeviceChange() {
        do {
            try synchronizeMasterVolumeFromSelectedDevice()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    /// E16 S2: a media-key level change. Software volume only; never writes the device.
    func applySoftwareVolumeKey(level: Double) {
        guard masterVolumeCapabilities.controlMode == .softwareDSP else { return }
        var updated = masterVolumeConfiguration
        updated.level = level
        do {
            try applyMasterVolumeConfiguration(updated, writeDevice: false)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func applyGainConfiguration(_ configuration: DSPGainConfiguration) throws {
        let clampedAmbientTarget =
            ambientTargetClampedToHeadroom(
                ambientCompensationRuntimeTarget,
                gainConfiguration: configuration
            )

        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: configuration,
                ambientTarget: clampedAmbientTarget
            )

        if immutableSemanticTransportActive,
           configuration != gainConfiguration || clampedAmbientTarget != ambientCompensationRuntimeTarget {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.gain = configuration
            inputs.ambient = clampedAmbientTarget
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: configuration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: renderStereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try applyAudioUnitRackLatency(to: &graph)
            try attachAmbientCompensation(
                clampedAmbientTarget,
                to: &graph
            )
            try attachActiveQuietZone(
                candidateQuietZone,
                to: &graph
            )
            try session.publishDSPGraph(graph)
        }

        gainConfiguration = configuration
        ambientCompensationRuntimeTarget =
            clampedAmbientTarget
        activeQuietZoneRuntimeTarget =
            candidateQuietZone
        lastErrorDescription = nil
    }

    private func applyRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {
        if configuration.enabled && configuration.filter == nil && configuration.lanes == nil {
            throw RoomCorrectionConfigurationError.filterRequired
        }
        if configuration.filter != nil && configuration.lanes != nil {
            throw RoomCorrectionConfigurationError.filterAndLanes
        }
        try configuration.lanes?.validate()
        if immutableSemanticTransportActive, configuration != roomCorrectionConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.room = configuration
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: renderStereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )

            if processingIsBypassed(playbackControlConfiguration) {
                if let filter = configuration.filter {
                    try validateRoomCorrectionFilter(
                        filter,
                        outputSampleRate: session.outputFormat.sampleRate
                    )
                }
                // Stay on the untreated path without rotating a stale FIR slot or
                // invoking a fade-through-silence transition.
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                activeRoomCorrectionProgram = nil
            } else if configuration.isActiveOnStereoKernel {
                guard let filter = configuration.filter else {
                    throw RoomCorrectionConfigurationError.filterRequired
                }
                let preparedProgram = try prepareRoomCorrectionProgram(filter, for: session)
                try attachRoomCorrectionProgram(preparedProgram, to: &graph)
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                activeRoomCorrectionProgram = preparedProgram
            } else {
                if activeRoomCorrectionProgram != nil {
                    try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                } else {
                    try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                }
                activeRoomCorrectionProgram = nil
            }
        } else {
            activeRoomCorrectionProgram = nil
        }

        // A lane plan cannot run on the stereo kernel (two-band stages, per-lane delays): the session plays uncorrected
        // and says why (Q9, owner 1 Nov 2026). N-channel sessions set the reason while they build the graph.
        if transportSession != nil {
            roomCorrectionInactiveReason = configuration.enabled && configuration.lanes != nil ? .needsSpeakerProfile : nil
        } else if !immutableSemanticTransportActive {
            roomCorrectionInactiveReason = nil
        }
        roomCorrectionConfiguration = configuration
        lastErrorDescription = nil
    }

    /// E24 S3b: synthesises the lane plan at every rate the selected output exposes, before a deploy commits (Q8), so a
    /// rate change later hits the cache. Any failure throws and the deploy fails.
    func precomputeRoomCorrectionPlans(for lanes: RoomCorrectionLaneInstall) async throws {
        try lanes.validate()
        let rates = selectedOutputDevice?.correctionSampleRates ?? [48_000]
        for rate in rates {
            _ = try await roomCorrectionRateCache.planAsync(
                for: lanes.design, sampleRate: rate, unifiedGraphEnabled: unifiedGraphEnabled)
        }
    }

    /// The plan the graph runs at `sampleRate` for the stored lanes (a cache hit after the precompute), for verification.
    func installedRoomCorrectionPlan(sampleRate: Double) -> RoomCorrectionLanePlan? {
        guard roomCorrectionConfiguration.enabled, roomCorrectionInactiveReason == nil,
              let lanes = roomCorrectionConfiguration.lanes else { return nil }
        return try? roomCorrectionRateCache.plan(
            for: lanes.design, sampleRate: sampleRate, unifiedGraphEnabled: unifiedGraphEnabled)
    }

    private func applySpeakerIRConfiguration(_ configuration: SpeakerIRConfiguration) throws {
        if configuration.enabled && configuration.filter == nil {
            throw SpeakerIRConfigurationError.filterRequired
        }
        if immutableSemanticTransportActive, configuration != speakerIRConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.speakerIR = configuration
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try renderStereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: renderDynamicsConfiguration(),
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: renderStereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )

            if processingIsBypassed(playbackControlConfiguration) {
                if let filter = configuration.filter {
                    try validateSpeakerIRFilter(
                        filter,
                        outputSampleRate: session.outputFormat.sampleRate
                    )
                }
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                activeSpeakerIRProgram = nil
            } else if configuration.enabled {
                guard let filter = configuration.filter else {
                    throw SpeakerIRConfigurationError.filterRequired
                }
                let preparedProgram = try prepareSpeakerIRProgram(filter, for: session)
                try attachSpeakerIRProgram(preparedProgram, to: &graph)
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                activeSpeakerIRProgram = preparedProgram
            } else {
                if activeSpeakerIRProgram != nil {
                    try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                } else {
                    try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                }
                activeSpeakerIRProgram = nil
            }
        } else {
            activeSpeakerIRProgram = nil
        }

        speakerIRConfiguration = configuration
        lastErrorDescription = nil
    }

    /// The EQ FIR taps for the configured channel mode (left and optional second channel padded to one length), their
    /// declared latency and the linear-phase design report. Pure: prepares nothing.
    private func eqFIRTaps(
        _ configuration: StereoEQConfiguration,
        sampleRate: Double
    ) throws -> (left: [Float], right: [Float]?, declaredLatencyFrames: UInt32, designInfo: EQLinearPhaseDesignInfo?) {
        let design = try eqFIRCache.design(for: EQFIRProgramKey(configuration, sampleRate: sampleRate)) {
            let taps = try EQFIRDesigner.design(configuration, sampleRate: sampleRate)
            return EQFIRDesign(
                left: taps.left, right: taps.right,
                declaredLatencyFrames: taps.declaredLatencyFrames, designInfo: taps.designInfo)
        }
        return (design.left, design.right, design.declaredLatencyFrames, design.designInfo)
    }

    func prepareEQFIRProgram(
        _ configuration: StereoEQConfiguration,
        for session: CoreAudioTransportSession
    ) throws -> PreparedEQFIRProgram {
        // The taps come from the design cache (E27 S3c); the program itself is always freshly
        // prepared so its convolver runtime starts clean.
        let primary = try eqFIRTaps(configuration, sampleRate: session.outputFormat.sampleRate)
        let secondaryTaps = primary.right

        let slot = nextEQFIRProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareConvolutionProgram(
                slot: slot,
                leftTaps: primary.left,
                rightTaps: secondaryTaps,
                declaredLatencyFrames: primary.declaredLatencyFrames
            )
        } catch {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        nextEQFIRProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedEQFIRProgram(
            slot: slot,
            programInfo: programInfo,
            designInfo: primary.designInfo
        )
    }

    /// E27 S3c: designs `partner` (the other A/B slot) now and keeps its design cached while the
    /// live EQ is edited, so a toggle to it designs nothing. `nil` ends the protection. Control
    /// thread; publishes nothing. Skipped when the partner needs no FIR.
    func prewarmEQFIRPartner(_ partner: StereoEQConfiguration?) {
        guard let partner, partner.requiresEQFIRProgram else {
            eqFIRCache.protect(nil)
            return
        }
        let rate = transportSession?.outputFormat.sampleRate
            ?? nChannelTransportSession?.outputFormat.sampleRate
            ?? selectedOutputDevice?.nominalSampleRate ?? 48_000
        eqFIRCache.protect(EQFIRProgramKey(partner, sampleRate: rate))
        _ = try? eqFIRTaps(partner, sampleRate: rate)
    }

    private func rateAdaptedRoomCorrectionFilter(
        _ filter: RoomCorrectionFilter,
        sampleRate: Double
    ) -> RoomCorrectionFilter {
        guard let designRate = filter.sampleRate,
              abs(designRate - sampleRate) >= 0.5 else { return filter }
        if let cached = adaptedRoomCorrectionFilter,
           abs(cached.sampleRate - sampleRate) < 0.5,
           cached.source == filter {
            return cached.filter
        }
        guard let adapted = roomCorrectionFilterAdapter?(filter, sampleRate),
              let adaptedRate = adapted.sampleRate,
              abs(adaptedRate - sampleRate) < 0.5 else {
            return filter
        }
        adaptedRoomCorrectionFilter = (filter, sampleRate, adapted)
        return adapted
    }

    func validateRoomCorrectionFilter(
        _ deployedFilter: RoomCorrectionFilter,
        outputSampleRate: Double
    ) throws {
        let filter = rateAdaptedRoomCorrectionFilter(deployedFilter, sampleRate: outputSampleRate)
        let tapCount = filter.leftTaps.count
        guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw RoomCorrectionConfigurationError.invalidTapCount(tapCount)
        }
        if let rightTaps = filter.rightTaps, rightTaps.count != tapCount {
            throw RoomCorrectionConfigurationError.mismatchedStereoTapCount(left: tapCount, right: rightTaps.count)
        }
        guard filter.leftTaps.allSatisfy(\.isFinite),
              filter.rightTaps?.allSatisfy(\.isFinite) ?? true else {
            throw RoomCorrectionConfigurationError.nonFiniteTap
        }
        try filter.validateSampleRate(forOutputSampleRate: outputSampleRate)
        guard filter.declaredLatencyFrames < UInt32(tapCount) else {
            throw RoomCorrectionConfigurationError.invalidDeclaredLatency(filter.declaredLatencyFrames)
        }
    }

    func prepareRoomCorrectionProgram(
        _ deployedFilter: RoomCorrectionFilter,
        for session: CoreAudioTransportSession
    ) throws -> PreparedRoomCorrectionProgram {
        try validateRoomCorrectionFilter(deployedFilter, outputSampleRate: session.outputFormat.sampleRate)
        let filter = rateAdaptedRoomCorrectionFilter(
            deployedFilter,
            sampleRate: session.outputFormat.sampleRate
        )

        let slot = nextRoomCorrectionProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareRoomCorrectionProgram(
                slot: slot,
                leftTaps: filter.leftTaps,
                rightTaps: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames
            )
        } catch {
            throw RoomCorrectionConfigurationError.convolutionProgramUnavailable
        }
        nextRoomCorrectionProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedRoomCorrectionProgram(slot: slot, programInfo: programInfo)
    }

    /// Validates `filter` for `outputSampleRate` and returns what plays: with `e7.rate-adapt` a filter that carries
    /// another rate is resampled (cached, control plane; E7 S2), otherwise a rate mismatch refuses as before.
    @discardableResult
    func validateSpeakerIRFilter(_ filter: SpeakerIRFilter, outputSampleRate: Double) throws -> SpeakerIRFilter {
        try SpeakerIRRateAdapter.shared.validated(
            filter, outputSampleRate: outputSampleRate, enabled: FeatureFlags().isEnabled(.rateAdapt))
    }

    func prepareSpeakerIRProgram(
        _ filter: SpeakerIRFilter,
        for session: CoreAudioTransportSession
    ) throws -> PreparedSpeakerIRProgram {
        let filter = try validateSpeakerIRFilter(filter, outputSampleRate: session.outputFormat.sampleRate)

        let slot = nextSpeakerIRProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareSpeakerIRProgram(
                slot: slot,
                leftTaps: filter.leftTaps,
                rightTaps: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames
            )
        } catch {
            throw SpeakerIRConfigurationError.convolutionProgramUnavailable
        }
        nextSpeakerIRProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedSpeakerIRProgram(slot: slot, programInfo: programInfo)
    }

    /// E6 S9a: the stereo-class DSP (EQ, dynamics, FIR, room, Speaker IR, image, protection) the active configuration
    /// would apply, ready to map onto an N-channel or Virtual Speakers graph. Nil when the flag is off, when global
    /// bypass or reference audition removes the program DSP (the lane calibration, bass management, binaural
    /// rendering and protection stay), or when nothing is active. Throws when the configuration is unusable
    /// (missing filter, rate mismatch) or when the graph cannot reproduce it, so activation never silently drops it.
    func makeUnifiedProgramDSP(
        sampleRate: Double,
        shape: UnifiedGraphLayoutShape,
        virtualSpeakers: Bool,
        subwooferCount: Int? = nil,
        foldStereoCrossover: Bool = false,
        inputs candidate: LiveGraphInputs? = nil
    ) throws -> UnifiedGraphProgramDSP? {
        guard unifiedGraphEnabled else {
            let room = candidate?.room ?? roomCorrectionConfiguration
            roomCorrectionInactiveReason = room.enabled && room.lanes != nil ? .needsUnifiedGraph : nil
            return nil
        }
        let inputs = candidate ?? currentLiveGraphInputs
        let playback = inputs.playback
        if FIRUpdatePolicy.isRawBypassed(playback) || playback.auditionMode == .reference { return nil }
        // E6 S12h part 3 (G50): the delta runs on the program lanes of a speaker graph (mask form, ABI v31). Virtual
        // Speakers renders the ears from the lanes, so a lane delta would not be what the listener hears.
        let deltaAudition = playback.auditionMode == .delta
        if deltaAudition, virtualSpeakers {
            throw LiveNChannelTransportError.unsupportedActiveDSP("delta audition in Virtual Speakers mode")
        }
        // E8 S11b: stereo plus sub lanes folds the user's crossover (monitor mode, phase alignment, filter) into the
        // session's one bass management; every other layout keeps the route plan's own split and a disabled crossover.
        let subLaneTotal = subwooferCount ?? 0
        let fold = foldStereoCrossover && !virtualSpeakers && subLaneTotal > 0 && shape.laneCount == 2
            && shape.lfeLane == nil && renderBassManagementConfiguration(inputs.bass).enabled
        let foldedBassSettings = fold ? renderBassManagementConfiguration(inputs.bass) : BassManagementConfiguration()
        var snapshot = try inputs.stereoEQ.makeGraphSnapshot(
            sampleRate: sampleRate,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: foldedBassSettings,
            dynamicsConfiguration: inputs.dynamics,
            playbackConfiguration: playback,
            masterGainLinear: 1, groupRoleCodes: shape.roleCodes
        )
        // The ambient live target rides in the snapshot like the stereo path (E6 S9b); the stereo engine only
        // runs it on speakers, so Virtual Speakers keeps it off.
        if !virtualSpeakers {
            try attachAmbientCompensation(
                ambientTargetClampedToHeadroom(inputs.ambient, gainConfiguration: inputs.gain), to: &snapshot)
        }
        // The graph never reads the kernel's convolver slots; it takes the taps by generation. Generations here are
        // local to this one translation (1 EQ FIR, 2 room correction, 3 Speaker IR).
        var retained: [UInt64: UnifiedGraphFIRProgram] = [:]
        func info(_ generation: UInt64, _ left: [Float], _ declared: UInt32) -> N60ConvolutionProgramInfo {
            N60ConvolutionProgramInfo(
                prepared: true,
                generation: generation,
                tapCount: UInt32(left.count),
                partitionCount: N60ConvolutionPartitionCountForTapCount(UInt32(left.count)),
                engineLatencyFrames: N60_CONVOLUTION_PARTITION_FRAMES,
                declaredLatencyFrames: declared
            )
        }
        if FIRUpdatePolicy.shouldPrepareEQFIR(stereoEQ: inputs.stereoEQ, playback: playback) {
            let taps = try eqFIRTaps(inputs.stereoEQ, sampleRate: sampleRate)
            retained[1] = UnifiedGraphFIRProgram(
                generation: 1, left: taps.left, right: taps.right, declaredLatencyFrames: taps.declaredLatencyFrames)
            guard N60DSPGraphSnapshotSetConvolutionProgram(
                &snapshot, 0, info(1, taps.left, taps.declaredLatencyFrames), true) else {
                throw EQConfigurationError.convolutionProgramUnavailable
            }
        }
        var installedLanes: (plan: RoomCorrectionLanePlan, delays: [Int: UInt32])?
        var inactive: RoomCorrectionInactiveReason?
        // E24 S9: a blind-ABX override replaces the profile's lanes while its sheet is open. It never changes the
        // stored configuration, and a layout or delay it cannot honour throws instead of silently falling back.
        let abx = roomCorrectionABXOverride
        var abxGain: Float = 1
        if let abx {
            guard abx.install.matches(programLaneCount: shape.laneCount, subwooferCount: subwooferCount) else {
                throw RoomCorrectionLaneInstallError.invalidLayout
            }
            var delays = try abx.install.delayFrames(sampleRate: sampleRate)
            if abx.extraDelayFrames > 0 {
                for lane in 0..<(shape.laneCount + (subwooferCount ?? 0)) {
                    let total = delays[lane, default: 0] + abx.extraDelayFrames
                    guard total <= N60_GRAPH_MAX_DELAY_FRAMES else {
                        throw RoomCorrectionLaneInstallError.delayTooLong(lane: lane)
                    }
                    delays[lane] = total
                }
            }
            installedLanes = (try roomCorrectionRateCache.plan(for: abx.install.design, sampleRate: sampleRate), delays)
            abxGain = abx.gain
        } else if inputs.room.enabled, let lanes = inputs.room.lanes {
            // Lane plans install on the main lanes (design note 8). A layout that no longer matches, or a rate the
            // filters cannot be built for, leaves correction off with its reason; playback is never refused (Q9, Q11).
            if !lanes.matches(programLaneCount: shape.laneCount, subwooferCount: subwooferCount) {
                inactive = .layoutChanged
            } else {
                do {
                    let delays = try lanes.delayFrames(sampleRate: sampleRate)
                    // Cache hit after the deploy-time precompute; a miss (new device rate) synthesises here, on the control thread.
                    let plan = try roomCorrectionRateCache.plan(for: lanes.design, sampleRate: sampleRate)
                    installedLanes = (plan, delays)
                } catch {
                    inactive = .synthesisFailed(rate: sampleRate)
                }
            }
        } else if inputs.room.enabled {
            guard let filter = inputs.room.filter else {
                throw RoomCorrectionConfigurationError.filterRequired
            }
            try validateRoomCorrectionFilter(filter, outputSampleRate: sampleRate)
            let adapted = rateAdaptedRoomCorrectionFilter(filter, sampleRate: sampleRate)
            retained[2] = UnifiedGraphFIRProgram(
                generation: 2, left: adapted.leftTaps, right: adapted.rightTaps,
                declaredLatencyFrames: adapted.declaredLatencyFrames)
            guard N60DSPGraphSnapshotSetRoomCorrectionProgram(
                &snapshot, 1, info(2, adapted.leftTaps, adapted.declaredLatencyFrames), true) else {
                throw RoomCorrectionConfigurationError.graphAttachmentFailed
            }
        }
        if inputs.speakerIR.enabled {
            guard let deployed = inputs.speakerIR.filter else {
                throw SpeakerIRConfigurationError.filterRequired
            }
            let filter = try validateSpeakerIRFilter(deployed, outputSampleRate: sampleRate)
            retained[3] = UnifiedGraphFIRProgram(
                generation: 3, left: filter.leftTaps, right: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames)
            guard N60DSPGraphSnapshotSetSpeakerIRProgram(
                &snapshot, 2, info(3, filter.leftTaps, filter.declaredLatencyFrames), true) else {
                throw SpeakerIRConfigurationError.graphAttachmentFailed
            }
        }
        let programs = retained
        var stereo: UnifiedGraphConfiguration
        // Neutral placeholders: the fold adds the crossover's sub gain, polarity and all-pass; the route plan's
        // calibrations are added by `nChannelEligibility`.
        switch UnifiedGraphTranslator.stereoEligibility(
            snapshot: &snapshot, sampleRate: sampleRate,
            subwoofers: fold ? Array(repeating: UnifiedGraphSubwoofer(), count: subLaneTotal) : [],
            crossoverHz: foldedBassSettings.frequencyHz,
            programs: { _, generation in programs[generation] },
            compressorExtras: FeatureFlags().isEnabled(.dynamicsExtras)
                ? inputs.dynamics.compressor.coreExtras(sampleRate: sampleRate) : nil,
            expanderExtras: FeatureFlags().isEnabled(.dynamicsExtras)
                ? inputs.dynamics.expander.coreExtras(sampleRate: sampleRate, lookahead: FeatureFlags.isEnabledProcessWide(.eqPageEnhancements), swapTiming: FeatureFlags.isEnabledProcessWide(.dynamicsSound)) : nil,
            multibandExtras: FeatureFlags().isEnabled(.dynamicsExtras)
                ? inputs.dynamics.multibandCompressor.translatorBlock(sampleRate: sampleRate, bands: FeatureFlags.isEnabledProcessWide(.eqPageEnhancements)) : nil
        ) {
        case .success(let configuration): stereo = configuration
        case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
        }
        // E4 S30a: planned unmasking cuts ride as the AMBIENT stage's section trailer (graph ABI v32). nil cuts, an
        // invalid plan or Virtual Speakers keep the plain stage. A neutral base is made when the kernel left ambient off.
        if !virtualSpeakers, let cuts = inputs.ambient.unmaskingCutsDB,
           let params = AmbientUnmaskOverlay.stageParameters(
            base: stereo.stereoStages.ambient, plannedCutsDB: cuts, sampleRate: sampleRate) {
            stereo.stereoStages.ambient = params
        }
        // Bypassed EQ covers every lane (the other program stages follow the lane set of the EQ mode).
        let mode: UnifiedGraphProgramDSP.EQMode
        switch inputs.stereoEQ.bypassed ? .linked : inputs.stereoEQ.channelMode {
        case .linked: mode = .linked
        case .independent: mode = .independent
        case .midSide: mode = .midSide
        }
        var program = UnifiedGraphProgramDSP(
            stereo: stereo, shape: shape, eqMode: mode, virtualSpeakers: virtualSpeakers, groupEQ: try inputs.stereoEQ.groupCurves(shape: shape, sampleRate: sampleRate))
        program.deltaAudition = deltaAudition
        if let installedLanes {
            program.inputGain *= abxGain
            program.roomLanes = installedLanes.plan
            program.laneDelayFrames = installedLanes.delays
            program.subLaneCount = subwooferCount ?? 0
        }
        roomCorrectionInactiveReason = inactive
        return program.isNeutral && program.foldedBass == nil ? nil : program
    }

    // MARK: E6 S9b live edits on a graph-rendered N-channel or binaural session

    /// Every engine setting that shapes an N-channel or binaural graph, so a setter can build the graph for the
    /// candidate value and publish it before it commits the value.
    struct LiveGraphInputs {
        var stereoEQ: StereoEQConfiguration
        var dynamics: DynamicsConfiguration
        var playback: PlaybackControlConfiguration
        var gain: DSPGainConfiguration
        var bass: BassManagementConfiguration
        var room: RoomCorrectionConfiguration
        var speakerIR: SpeakerIRConfiguration
        var ambient: AmbientCompensationTarget
        /// E12 S4a: the guided-setup Level step's noise. nil (the default) means no generator stage. Any hand-built
        /// inputs must carry this forward or a later edit drops the noise.
        var generator: LiveGenerator?
    }

    /// E12 S4a: the generator currently published to the live graph, or nil when none is playing. Never persisted:
    /// a session restart, stop or output change clears it.
    var liveGenerator: LiveGenerator?  // set by the E19 S12c probe feed extension

    /// E24 S9: the design the blind ABX is playing in place of the profile's applied lanes, level-trimmed and
    /// latency-matched. Never persisted; Stop, an output change and a session teardown clear it.
    var roomCorrectionABXOverride: RoomCorrectionABXOverride?

    /// Why the ABX cannot play right now, or nil when it can: it needs a running graph session that installs lanes.
    var roomCorrectionABXUnavailableReason: String? {
        if nChannelTransportSession == nil, transportSession != nil {
            return RoomCorrectionInactiveReason.needsSpeakerProfile.message
        }
        guard nChannelTransportSession != nil, liveGraphEditsAvailable else {
            return "Start playback with music to compare by ear."
        }
        guard roomCorrectionConfiguration.enabled, roomCorrectionConfiguration.lanes != nil else {
            return "Apply a room correction to the speaker profile first."
        }
        return nil
    }

    /// True while the core is warming or fading to a republished graph (the switch the ABX presses cause).
    var graphRebuildInProgress: Bool { (nChannelTransportSession?.unifiedGraphReadback?.rebuildState ?? 0) != 0 }

    /// Sets (or, with nil, clears) the ABX override and moves the running graph to it through the normal faded
    /// republish. Throws and leaves the override and the running graph as they were when the graph cannot take it.
    func setRoomCorrectionABXOverride(_ override: RoomCorrectionABXOverride?) throws {
        if override == nil, roomCorrectionABXOverride == nil { return }
        if override == nil, nChannelTransportSession == nil {
            roomCorrectionABXOverride = nil
            return
        }
        if override == nil {
            // Clearing never fails to clear: if the republish cannot run, the next republish or teardown rebuilds
            // the graph without the override.
            roomCorrectionABXOverride = nil
            try republishLiveGraph(currentLiveGraphInputs)
            return
        }
        if let reason = roomCorrectionABXUnavailableReason { throw RoomCorrectionABXError.unavailable(reason) }
        let previous = roomCorrectionABXOverride
        roomCorrectionABXOverride = override
        do { try republishLiveGraph(currentLiveGraphInputs) } catch {
            roomCorrectionABXOverride = previous
            throw error
        }
    }

    /// Plays (or, with nil, stops) the E11 generator on the running graph through the normal republish path:
    /// N-channel graphs through `republishLiveGraph`, the stereo graph through its transport session. Throws and
    /// leaves the playing state as it was when the running session cannot take the edit (kernel render, binaural,
    /// flag off), the selection matches no lane, or the settings cannot form a stage at the output rate.
    func setLiveGenerator(_ settings: SignalGeneratorSettings?, selection: SignalGeneratorLaneSelection = .allProgram(includeLFE: false)) throws {
        if probeStimulusInstalled { throw MIMOProbeFeedError.generatorBusy }  // E19 S12c: the probe owns the stage
        if let session = nChannelTransportSession, liveGraphEditsAvailable {
            var wanted: LiveGenerator?
            if let settings {
                guard let shape = UnifiedGraphLayoutShape(roles: session.routePlan.programLayout.roles),
                      selection.mask(laneCount: shape.laneCount, lfeLane: shape.lfeLane) != nil,
                      settings.stageParams(active: true, sampleRate: session.outputFormat.sampleRate) != nil else {
                    throw LiveNChannelTransportError.unifiedGraphRejected(.specRejected)
                }
                wanted = LiveGenerator(settings: settings, selection: selection)
            }
            var inputs = currentLiveGraphInputs
            inputs.generator = wanted
            try republishLiveGraph(inputs)
            liveGenerator = wanted
        } else if let session = transportSession {
            var mask: UInt64?
            if settings != nil {
                guard let resolved = selection.mask(laneCount: 2, lfeLane: nil) else {
                    throw LiveNChannelTransportError.unifiedGraphRejected(.specRejected)
                }
                mask = resolved
            }
            try session.setLiveGenerator(settings, laneMask: mask)
            liveGenerator = settings.map { LiveGenerator(settings: $0, selection: selection) }
        } else if nChannelTransportSession != nil || binauralHeadphoneTransportSession != nil {
            // A graph that cannot take the edit may still hold a generator, so never report it stopped.
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        } else if settings == nil {
            liveGenerator = nil
        } else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
    }

    /// E12 S4a: the lanes the Level step can play noise on, for the running session (stereo L/R when the stereo
    /// transport runs or nothing runs yet).
    var generatorLaneChoices: [(index: Int, name: String, isLFE: Bool)] {
        if let session = nChannelTransportSession {
            return session.routePlan.programLayout.roles.enumerated().map {
                ($0.offset, $0.element.displayName, $0.element == .lowFrequencyEffects)
            }
        }
        return [(0, OutputProgramRole.frontLeft.displayName, false), (1, OutputProgramRole.frontRight.displayName, false)]
    }

    var currentLiveGraphInputs: LiveGraphInputs {
        LiveGraphInputs(
            stereoEQ: renderStereoEQConfiguration, dynamics: dynamicsConfiguration,
            playback: playbackControlConfiguration, gain: gainConfiguration,
            bass: bassManagementConfiguration, room: roomCorrectionConfiguration,
            speakerIR: speakerIRConfiguration, ambient: ambientCompensationRuntimeTarget,
            generator: liveGenerator)
    }

    /// True when the flag is on and the running N-channel or binaural session is rendered by the graph, so the
    /// setters can republish it instead of asking for a restart. A session that started on the legacy path (or any
    /// session with the flag off) keeps `configurationChangeRequiresRestart`.
    var liveGraphEditsAvailable: Bool {
        guard unifiedGraphEnabled else { return false }
        if let session = nChannelTransportSession { return session.unifiedGraphActive }
        if let session = binauralHeadphoneTransportSession { return session.unifiedGraphActive }
        return false
    }

    /// E6 decision 8: independent (left/right) stereo EQ applies no EQ to a layout's unpaired lanes (centre, centre
    /// surround, ...). Non-nil text for the equaliser view when the running N-channel layout has such lanes.
    var unpairedEQLaneNote: String? {
        guard stereoEQConfiguration.channelMode == .independent,
              let session = nChannelTransportSession,
              let shape = UnifiedGraphLayoutShape(roles: session.routePlan.programLayout.roles) else { return nil }
        var covered = Set(shape.pairs.flatMap { [$0.a, $0.b] })
        if let lfe = shape.lfeLane { covered.insert(lfe) }
        guard covered.count < shape.laneCount else { return nil }
        return "Independent mode applies the left and right curves to channel pairs only. Unpaired channels "
            + "(such as centre) get no stereo EQ; use Linked or Mid/Side to include them."
    }

    /// Call where a setter used to throw for a changed value: it still throws `configurationChangeRequiresRestart`
    /// unless the session's graph can take the edit.
    private func requireLiveGraphEdits() throws {
        guard liveGraphEditsAvailable else { throw LiveNChannelTransportError.configurationChangeRequiresRestart }
    }

    /// Builds the graph for `inputs` and moves the running graph to it. Throws (a named reason) and leaves the
    /// running graph untouched when the graph cannot take the edit; call it as the last step before committing state.
    func republishLiveGraph(
        _ inputs: LiveGraphInputs, headphoneBase: UnifiedGraphSpec? = nil, routing: SpeakerRoutingConfiguration? = nil
    ) throws {
        if let session = nChannelTransportSession {
            let rate = session.outputFormat.sampleRate
            // The delta refusal comes before the program build so a refused edit costs nothing (G51).
            if session.routePlan.isRouted, inputs.playback.auditionMode == .delta {
                throw LiveNChannelTransportError.routingRefused("the delta audition is not available with speaker routing; switch to Processed or Reference.")
            }
            guard let shape = UnifiedGraphLayoutShape(roles: session.routePlan.programLayout.roles) else {
                throw LiveNChannelTransportError.unifiedGraphRejected(.laneCountMismatch)
            }
            let folds = foldsStereoCrossover(
                routePlan: session.routePlan, bass: renderBassManagementConfiguration(inputs.bass), requiresRackFree: true)
            if !folds { try requireNoCrossoverAudition(inputs.bass) }
            let program = try makeUnifiedProgramDSP(
                sampleRate: rate, shape: shape, virtualSpeakers: false,
                subwooferCount: Int(session.routePlan.subwooferCount), foldStereoCrossover: folds, inputs: inputs)
            var configuration: UnifiedGraphConfiguration
            if session.routePlan.isRouted {
                guard let activeRouting = routing ?? speakerRoutingConfiguration, activeRouting.enabled else {
                    throw LiveNChannelTransportError.routingRefused("the session is routed but no routing is set.")
                }
                configuration = try makeRoutedGraphConfiguration(
                    routing: activeRouting, routePlan: session.routePlan, sampleRate: rate, inputs: inputs)
            } else {
                switch UnifiedGraphTranslator.nChannelEligibility(
                    routePlan: session.routePlan, sampleRate: rate, gainConfiguration: inputs.gain,
                    bassManagementConfiguration: renderBassManagementConfiguration(inputs.bass), programDSP: program
                ) {
                case .success(let built): configuration = built
                case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
                }
            }
            if let generator = inputs.generator {
                guard let mask = generator.selection.mask(laneCount: shape.laneCount, lfeLane: shape.lfeLane),
                      let params = generator.stageParams(sampleRate: rate) else {
                    throw LiveNChannelTransportError.unifiedGraphRejected(.specRejected)
                }
                configuration.generatorParams = params
                configuration.generatorLaneMask = mask
            }
            // E19 S6: a new topology rebuilds the graph, so the switch goes off first: the disarm word is stored with the
            // stage and the rebuilt graph carries it disarmed (a rebuild never fades through live treatment).
            if session.mimoStageAttached { mimoGraphTreatment.graphRebuilt() }
            try session.republishGraph(configuration)
        } else if let session = binauralHeadphoneTransportSession {
            guard let base = headphoneBase ?? session.unifiedGraphBaseSpec,
                  let shape = UnifiedGraphLayoutShape(roles: session.programLayout.roles) else {
                throw LiveNChannelTransportError.configurationChangeRequiresRestart
            }
            let program = try makeUnifiedProgramDSP(
                sampleRate: session.outputFormat.sampleRate, shape: shape, virtualSpeakers: true, inputs: inputs)
            let combinedDB = inputs.gain.inputPreampDB + inputs.gain.headroomAttenuationDB + inputs.gain.outputGainDB
            switch UnifiedGraphTranslator.binauralApplyProgram(
                base: base, programDSP: program, programGain: Float(DSPGainConfiguration.linearGain(forDB: combinedDB))
            ) {
            case .success(let spec):
                try session.republishGraph(spec)
                if let headphoneBase { session.commitUnifiedGraphBaseSpec(headphoneBase) }
            case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
            }
        } else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
    }

    func attachEQFIRProgram(
        _ program: PreparedEQFIRProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetConvolutionProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw EQConfigurationError.linearPhaseDesignFailed
        }
    }

    private func attachActiveEQFIRProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        stereoConfiguration: StereoEQConfiguration,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              stereoConfiguration.requiresEQFIRProgram,
              !stereoConfiguration.bypassed else { return }
        guard let activeEQFIRProgram else {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        try attachEQFIRProgram(activeEQFIRProgram, to: &graph)
    }

    func attachRoomCorrectionProgram(
        _ program: PreparedRoomCorrectionProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetRoomCorrectionProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw RoomCorrectionConfigurationError.graphAttachmentFailed
        }
    }

    private func attachActiveRoomCorrectionProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              roomCorrectionConfiguration.isActiveOnStereoKernel else { return }
        guard let activeRoomCorrectionProgram else {
            throw RoomCorrectionConfigurationError.convolutionProgramUnavailable
        }
        try attachRoomCorrectionProgram(activeRoomCorrectionProgram, to: &graph)
    }

    private func attachAmbientCompensation(
        _ target: AmbientCompensationTarget,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        let enabled = abs(target.levelDB) > 0.000_1
            || abs(target.lowSupportDB) > 0.000_1
            || abs(target.presenceSupportDB) > 0.000_1
            || abs(target.detailSupportDB) > 0.000_1
        guard N60DSPGraphSnapshotSetActiveAcousticsAdaptation(
            &graph,
            target.levelDB,
            target.lowSupportDB,
            target.presenceSupportDB,
            target.detailSupportDB,
            enabled
        ) else {
            throw AmbientCompensationError.invalidConfiguration
        }
    }

    private func attachAmbientCompensation(
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        try attachAmbientCompensation(
            ambientCompensationRuntimeTarget,
            to: &graph
        )
    }

    private func ambientTargetClampedToHeadroom(
        _ target: AmbientCompensationTarget,
        gainConfiguration: DSPGainConfiguration
    ) -> AmbientCompensationTarget {
        var clamped = target
        let available = max(
            -gainConfiguration.headroomAttenuationDB,
            0
        )
        if target.levelDB > 0 {
            clamped.levelDB = min(
                target.levelDB,
                available,
                AmbientCompensationConfiguration
                    .hardMaximumLevelCompensationDB
            )
        } else {
            clamped.levelDB = max(target.levelDB, -6.0)
        }
        return clamped
    }

    private func attachActiveQuietZone(
        _ target: ActiveQuietZoneRuntimeTarget,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        let resolved =
            processingIsBypassed(
                playbackControlConfiguration
            )
            ? ActiveQuietZoneRuntimeTarget(
                tones: [],
                transitionMilliseconds:
                    target.transitionMilliseconds
            )
            : target
        let transitionFramesDouble =
            graph.sampleRate
            * resolved.transitionMilliseconds
            / 1_000
        guard transitionFramesDouble.isFinite,
              transitionFramesDouble >= 1,
              transitionFramesDouble
                <= Double(UInt32.max) else {
            throw ActiveQuietZoneError.invalidConfiguration
        }
        let transitionFrames =
            UInt32(transitionFramesDouble.rounded())

        var tones = resolved.tones.map { tone in
            var value =
                N60ActiveQuietZoneToneSnapshot()
            value.frequencyHz = tone.frequencyHz
            value.leftReal =
                Float(tone.leftOutput.real)
            value.leftImaginary =
                Float(tone.leftOutput.imaginary)
            value.rightReal =
                Float(tone.rightOutput.real)
            value.rightImaginary =
                Float(tone.rightOutput.imaginary)
            return value
        }

        let attached: Bool
        if tones.isEmpty {
            attached =
                N60DSPGraphSnapshotSetActiveQuietZone(
                    &graph,
                    nil,
                    0,
                    transitionFrames,
                    false
                )
        } else {
            attached =
                tones.withUnsafeMutableBufferPointer {
                    N60DSPGraphSnapshotSetActiveQuietZone(
                        &graph,
                        $0.baseAddress,
                        UInt32($0.count),
                        transitionFrames,
                        true
                    )
                }
        }
        if attached, adaptiveTonalMailboxEnabled, !tones.isEmpty, let generation = resolved.armGeneration,
           !N60DSPGraphSnapshotSetActiveQuietZoneArmGeneration(&graph, generation &+ 1) {
            throw ActiveQuietZoneError.invalidConfiguration
        }
        let toneCaps: [Float] = excursionCapCurve.map { curve in
            tones.map { curve.trackedCapLinear(atHz: Double($0.frequencyHz)) }
        } ?? []
        let earnedInitial = earnedCapInitialLinear
        let snapshotCapDBFS = earnedInitial > 0
            ? LiveTreatmentSafeguards.hardMaximumPeakCapDBFS
            : LiveTreatmentSafeguards.defaultPeakCapDBFS
        guard attached,
              N60DSPGraphSnapshotSetActiveQuietZonePeakCap(
                &graph,
                Float(LiveTreatmentSafeguards.linearPeak(dbfs: snapshotCapDBFS))
              ),
              N60DSPGraphSnapshotSetActiveQuietZoneInitialCap(&graph, tones.isEmpty ? 0 : earnedInitial),
              toneCaps.withUnsafeBufferPointer({
                  N60DSPGraphSnapshotSetActiveQuietZoneToneCaps(&graph, $0.baseAddress, UInt32($0.count))
              }) else {
            throw ActiveQuietZoneError
                .invalidConfiguration
        }
    }

    private func attachActiveQuietZone(
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        try attachActiveQuietZone(
            activeQuietZoneRuntimeTarget,
            to: &graph
        )
    }

    private func activeQuietZoneTargetAfterHeadroomChange(
        _ target: ActiveQuietZoneRuntimeTarget,
        gainConfiguration: DSPGainConfiguration,
        ambientTarget: AmbientCompensationTarget
    ) -> ActiveQuietZoneRuntimeTarget {
        guard target.active else { return target }
        let available = LiveTreatmentSafeguards.limitedInjectionPeak(
            (
                try? ActiveQuietZonePlanner()
                    .availableInjectionPeak(
                        headroomAttenuationDB:
                            gainConfiguration
                                .headroomAttenuationDB,
                        ambientLevelRecoveryDB:
                            max(ambientTarget.levelDB, 0),
                        configuration:
                            ActiveQuietZoneConfiguration()
                    )
            )
            ?? 0
        )
        guard target.maximumSourceMagnitude
                <= available + 1.0e-7 else {
            // Never rescale solved phasors behind the controller's back.
            return ActiveQuietZoneRuntimeTarget(
                tones: [],
                transitionMilliseconds: 100
            )
        }
        return target
    }

    func applyAudioUnitRackLatency(
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        try attachAmbientCompensation(to: &graph)
        try attachActiveQuietZone(to: &graph)
        guard let stagedAudioUnitRack else { return }
        let combinedLatency =
            UInt64(graph.latencyFrames)
            + UInt64(max(stagedAudioUnitRack.latencyFrames, 0))
        guard combinedLatency <= UInt64(UInt32.max) else {
            throw CoreAudioTransportError.audioUnitRackConfigurationFailed
        }
        if graph.auditionMode != N60AuditionModeProcessed,
           combinedLatency >= UInt64(N60_MAX_AUDITION_DELAY_FRAMES) {
            throw CoreAudioTransportError.audioUnitRackConfigurationFailed
        }
        graph.latencyFrames = UInt32(combinedLatency)
    }

    func attachSpeakerIRProgram(
        _ program: PreparedSpeakerIRProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetSpeakerIRProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw SpeakerIRConfigurationError.graphAttachmentFailed
        }
    }

    private func attachActiveSpeakerIRProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              speakerIRConfiguration.enabled else { return }
        guard let activeSpeakerIRProgram else {
            throw SpeakerIRConfigurationError.convolutionProgramUnavailable
        }
        try attachSpeakerIRProgram(activeSpeakerIRProgram, to: &graph)
    }
}
