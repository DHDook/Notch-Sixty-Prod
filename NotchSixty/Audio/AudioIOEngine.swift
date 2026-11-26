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

    private let deviceCatalog: any OutputDeviceCataloging
    let eventMonitor: any AudioHardwareEvents
    let masterVolumeController: any MasterVolumeDeviceControlling
    let binauralProfileAssetStore: BinauralProfileAssetStore
    /// E6 S9c: converted HRTF assets per (asset, rate), shared by session start and live asset swaps.
    let binauralAssetCache = BinauralResampledAssetCache()
    /// Newest live HRTF asset swap request; an older prepare that finishes later is dropped.
    private(set) var headphoneAssetGeneration: UInt64 = 0
    let masterVolumeStore: (any MasterVolumePersisting)?
    var lifecycle: AudioLifecycleStateMachine
    /// E25 S2: applied to each new stereo session.
    private(set) var stereoAlignment: StereoBassAlignment?
    /// E25 S8a: the wider-source fold the user configured (nil: none), and the matrix of the session that is running or
    /// being built with it. The protection merge keys on the second, so a fold that resolves to the standard path
    /// (no source tapped) adds no limiter.
    private(set) var programFoldPlan: ProgramFoldDownPlan?
    /// E25 S8c: read-only views of the applied arrangement state, so profile load and the wizard are comparable.
    var appliedStereoAlignment: StereoBassAlignment? { stereoAlignment }
    var appliedProgramFoldPlan: ProgramFoldDownPlan? { programFoldPlan }
    var nChannelTransportSession: CoreAudioNChannelTransportSession?
    private var prepared = false
    /// E27 S3c: designed taps of the recent EQ configurations, so an A/B toggle redesigns nothing.
    var eqFIRCache = EQFIRProgramCache()
    var eqOffMain = EQOffMainState()
    /// Linear-phase designs run so far (a cache hit runs none). Tests read it.
    var eqFIRDesignCount: Int { eqFIRCache.designCount }
    private(set) var stagedRoomTreatment: LiveMIMORoomTreatmentPreparation?
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
    private(set) var stagedAudioUnitRack: AudioUnitLiveRackSwitchboard?
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


    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var routeConfiguration: AudioRouteConfiguration
    private(set) var eqConfiguration = EQConfiguration()
    private(set) var stereoEQConfiguration = StereoEQConfiguration()
    /// E27 S3b: the band-pass "Listen" audition, if one is held. Never stored in
    /// `stereoEQConfiguration`, the profile or undo; it only changes what is rendered.
    private(set) var eqAudition: EQAuditionOverride?
    /// The EQ as rendered: the stored EQ, or the audition band-pass while one is held.
    var renderStereoEQConfiguration: StereoEQConfiguration {
        eqAudition.map { stereoEQConfiguration.auditioned($0) } ?? stereoEQConfiguration
    }
    private(set) var playbackControlConfiguration = PlaybackControlConfiguration()
    /// E16 S2: told when media keys may act (software volume on a selected output). `VolumeKeyController` owns the monitor.
    @ObservationIgnored var onVolumeKeyRouteChange: ((Bool) -> Void)?
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
    private(set) var dynamicsListener: DynamicsListener?
    private(set) var dynamicsSoloBands: Set<Int> = []
    private(set) var roomCorrectionConfiguration = RoomCorrectionConfiguration()
    /// E24 S3b: why an enabled lane-plan correction is not shaping playback right now, for Room Correction to show.
    /// E24 S3b: the engine's per-rate cache of lane-plan synthesis (design note 8).
    let roomCorrectionRateCache = RoomCorrectionRateCache()
    private(set) var speakerIRConfiguration = SpeakerIRConfiguration()
    private(set) var ambientCompensationRuntimeTarget =
        AmbientCompensationTarget.unity
    private(set) var activeQuietZoneRuntimeTarget =
        ActiveQuietZoneRuntimeTarget.bypassed
    private(set) var lastErrorDescription: String?
    private(set) var lifecycleState: AudioLifecycleState
    let lowLatencyBufferProfile: LowLatencyOutputBufferProfile
    /// G20: output-recovery and low-latency state; see `OutputRecoveryState`.
    let recovery = OutputRecoveryState()
    /// G20: session handles, counters, head tracking and routing; see `TransportSessionState`.
    let transport = TransportSessionState()
    /// G20: prepared convolution programs and their slot cursors; see `PreparedProgramSlots`.
    let programs = PreparedProgramSlots()
    /// G20: speaker-drive demand, anchor fan-out and analyser taps; see `SpeakerDriveState`.
    let speakerDrive = SpeakerDriveState()
    /// G20: level, mute, device capabilities and key step; see `MasterVolumeState` and `AudioIOEngine+MasterVolume.swift`.
    let masterVolume = MasterVolumeState()
    // E8 S4: `speakerRoutingConfiguration` is the routing a session renders; see `replaceSpeakerRoutingConfiguration`.
    // `liveTreatmentGeneration` is the arm token: it advances on every teardown and disarm, and
    // `replaceActiveQuietZoneRuntimeTarget` rejects an active target stamped with any other value.

    // G20: single-value state is `private(set)` here and changes through these one-line mutators, so no extension can store
    // a value without going through the engine. Setters publish to the render path first, then commit.
    func commitEQConfiguration(_ v: EQConfiguration) { eqConfiguration = v }
    func commitStereoEQConfiguration(_ v: StereoEQConfiguration) { stereoEQConfiguration = v }
    func commitEQAudition(_ v: EQAuditionOverride?) { eqAudition = v }
    func commitPlaybackControlConfiguration(_ v: PlaybackControlConfiguration) { playbackControlConfiguration = v }
    func commitGainConfiguration(_ v: DSPGainConfiguration) { gainConfiguration = v }
    func commitBassManagementConfiguration(_ v: BassManagementConfiguration) { bassManagementConfiguration = v }
    func commitMultiOutputRoutingConfiguration(_ v: MultiOutputRoutingConfiguration?) { multiOutputRoutingConfiguration = v }
    func commitOutputDeviceProfileConfiguration(_ v: OutputDeviceProfileConfiguration?) { outputDeviceProfileConfiguration = v }
    func commitHeadphoneDeviceProfileConfiguration(_ v: HeadphoneDeviceProfileConfiguration?) { headphoneDeviceProfileConfiguration = v }
    func commitSpeakerDriverProcessingConfiguration(_ v: SpeakerDriverProcessingConfiguration) { speakerDriverProcessingConfiguration = v }
    func commitDynamicsConfiguration(_ v: DynamicsConfiguration) { dynamicsConfiguration = v }
    func commitDynamicsListener(_ v: DynamicsListener?) { dynamicsListener = v }
    func commitDynamicsSoloBands(_ v: Set<Int>) { dynamicsSoloBands = v }
    func commitRoomCorrectionConfiguration(_ v: RoomCorrectionConfiguration) { roomCorrectionConfiguration = v }
    func commitSpeakerIRConfiguration(_ v: SpeakerIRConfiguration) { speakerIRConfiguration = v }
    func commitAmbientCompensationRuntimeTarget(_ v: AmbientCompensationTarget) { ambientCompensationRuntimeTarget = v }
    func commitActiveQuietZoneRuntimeTarget(_ v: ActiveQuietZoneRuntimeTarget) { activeQuietZoneRuntimeTarget = v }
    func commitStereoAlignment(_ v: StereoBassAlignment?) { stereoAlignment = v }
    func commitProgramFoldPlan(_ v: ProgramFoldDownPlan?) { programFoldPlan = v }
    func advanceHeadphoneAssetGeneration() { headphoneAssetGeneration &+= 1 }
    func setLastError(_ description: String?) { lastErrorDescription = description }
    func mirrorLifecycleState() { lifecycleState = lifecycle.state }

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
    var quietZoneHost: (any QuietZoneRuntimeHost)? {
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

    /// Called by the arm owner on disarm: targets built under the old arm can no longer play.
    func revokeLiveTreatmentArm() {
        transport.advanceLiveTreatmentGeneration()
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
    var immutableSemanticTransportActive: Bool {
        nChannelTransportSession != nil || binauralHeadphoneTransportSession != nil
    }

    func renderBassManagementConfiguration(
        _ source: BassManagementConfiguration? = nil
    ) -> BassManagementConfiguration {
        var render = auditionedBassManagement(source ?? bassManagementConfiguration)
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
            masterVolume.setSynchronizedOutputUID(nil)
            masterVolumeController.stopMonitoring()
            masterVolume.setCapabilities(.softwareOnly)
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

    func start() throws {
        try start(resetProcessingSessionCounters: true)
    }

    func stop(cause: TransportTeardownCause) {
        guard lifecycle.state != .idle else { return }
        recovery.cancelAllPending()
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        if lifecycle.state != .stopping { try? setLifecycle(.stopping) }
        tearDownTransport(fadeOut: true, cause: cause)
        try? setLifecycle(.idle)
        clearStagedAudioUnitRack()
        audioUnitRackRebuildPending = false
        if lowLatencyRestorePending { restoreLowLatencyBuffers() }
    }

    func shutdownForTermination() {
        recovery.cancelAllPending()
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

    /// E27 S2c (design note 16). Whether stereo graphs carry the Equalizer analyser taps. The analyser controller sets it;
    /// the engine and the core read no flag.

    /// E4 S22b1: records what is written to the speakers for the feed-forward echo model.
    /// Set from `e4.feedforward-live`; while false nothing ever sets the demand.
    /// E4 S25 follow-up: runs the live reference pump; idle unless the shadow asks and the flag is on.
    @ObservationIgnored private(set) lazy var feedForwardLiveDriver = FeedForwardLiveDriver(host: self)

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

    /// E24 S9, E12 S28b1: what the blind comparison plays instead of the stored system settings. Never persisted; Stop,
    /// an output change and a session teardown clear it. Setter and refusals: `AudioIOEngine+AuditionOverride.swift`.
    var auditionOverride: AuditionOverride?

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
    func requireLiveGraphEdits() throws {
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

}
