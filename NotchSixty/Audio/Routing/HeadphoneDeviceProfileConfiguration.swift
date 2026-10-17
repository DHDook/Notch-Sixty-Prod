import Foundation

enum HeadphoneTargetCurve: String, CaseIterable, Identifiable, Codable, Sendable {
    case neutral
    case diffuseField
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neutral: return "Neutral"
        case .diffuseField: return "Diffuse Field"
        case .custom: return "Custom"
        }
    }

    var realtimeCType: N60HeadphoneTargetCurveKind {
        switch self {
        case .neutral: return N60HeadphoneTargetCurveNeutral
        case .diffuseField: return N60HeadphoneTargetCurveDiffuseField
        case .custom: return N60HeadphoneTargetCurveCustom
        }
    }
}

enum HeadphoneCorrectionFilterType: String, CaseIterable, Identifiable, Codable, Sendable {
    case peaking
    case lowShelf
    case highShelf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peaking: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }

    var realtimeCType: N60BiquadFilterType {
        switch self {
        case .peaking: return N60BiquadFilterTypePeaking
        case .lowShelf: return N60BiquadFilterTypeLowShelf
        case .highShelf: return N60BiquadFilterTypeHighShelf
        }
    }
}

struct HeadphoneCorrectionEQBand: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var enabled = true
    var type: HeadphoneCorrectionFilterType = .peaking
    var frequencyHz = 1_000.0
    var gainDB = 0.0
    var q = 0.707

    func validate(sampleRate: Double) throws {
        guard frequencyHz.isFinite,
              frequencyHz >= 10,
              frequencyHz < sampleRate * 0.5,
              gainDB.isFinite,
              (-18.0...18.0).contains(gainDB),
              q.isFinite,
              (0.20...12.0).contains(q) else {
            throw HeadphoneDeviceProfileError.invalidEQBand
        }
    }
}

struct HeadphoneChannelCorrection: Codable, Equatable, Sendable {
    /// Fine channel matching trim. Positive trim is allowed only when the
    /// profile's explicit headroom attenuation covers it conservatively.
    var gainDB = 0.0
    var polarityInverted = false
    var delayMilliseconds = 0.0
    var eqBands: [HeadphoneCorrectionEQBand] = []

    func validate(sampleRate: Double) throws {
        guard gainDB.isFinite,
              (-12.0...6.0).contains(gainDB),
              delayMilliseconds.isFinite,
              (0.0...20.0).contains(delayMilliseconds),
              eqBands.count <= Int(N60_HEADPHONE_MAX_EQ_SECTIONS) else {
            throw HeadphoneDeviceProfileError.invalidChannelCorrection
        }
        let delayFrames = delayMilliseconds * sampleRate / 1_000.0
        guard delayFrames.isFinite,
              delayFrames <= Double(N60_HEADPHONE_MAX_DELAY_FRAMES) else {
            throw HeadphoneDeviceProfileError.invalidChannelCorrection
        }
        for band in eqBands { try band.validate(sampleRate: sampleRate) }
    }

    var conservativePositiveGainDB: Double {
        max(0, gainDB) + eqBands.lazy.filter(\.enabled).reduce(0) { partial, band in
            partial + max(0, band.gainDB)
        }
    }
}

enum HeadphoneCrossfeedPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case gentle
    case standard
    case wide
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .gentle: return "Gentle"
        case .standard: return "Standard"
        case .wide: return "Wide Speakers"
        case .custom: return "Custom"
        }
    }
}

struct HeadphoneCrossfeedConfiguration: Codable, Equatable, Sendable {
    var preset: HeadphoneCrossfeedPreset = .off
    var amount = 0.0
    var virtualSpeakerAngleDegrees = 30.0
    var headRadiusMeters = 0.0875
    var headShadowFrequencyHz = 700.0

    mutating func applyPreset(_ preset: HeadphoneCrossfeedPreset) {
        self.preset = preset
        switch preset {
        case .off:
            amount = 0
            virtualSpeakerAngleDegrees = 30
            headRadiusMeters = 0.0875
            headShadowFrequencyHz = 700
        case .gentle:
            amount = 0.25
            virtualSpeakerAngleDegrees = 30
            headRadiusMeters = 0.0875
            headShadowFrequencyHz = 700
        case .standard:
            amount = 0.45
            virtualSpeakerAngleDegrees = 30
            headRadiusMeters = 0.0875
            headShadowFrequencyHz = 700
        case .wide:
            amount = 0.40
            virtualSpeakerAngleDegrees = 45
            headRadiusMeters = 0.0875
            headShadowFrequencyHz = 650
        case .custom:
            break
        }
    }

    func validate(sampleRate: Double) throws {
        guard amount.isFinite,
              (0.0...1.0).contains(amount),
              virtualSpeakerAngleDegrees.isFinite,
              (15.0...90.0).contains(virtualSpeakerAngleDegrees),
              headRadiusMeters.isFinite,
              (0.06...0.12).contains(headRadiusMeters),
              headShadowFrequencyHz.isFinite,
              headShadowFrequencyHz >= 200,
              headShadowFrequencyHz < sampleRate * 0.5 else {
            throw HeadphoneDeviceProfileError.invalidCrossfeed
        }
    }
}

enum HeadphoneSpatialMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case stereo
    case virtualSpeakers

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stereo: return "Stereo"
        case .virtualSpeakers: return "Virtual Speakers"
        }
    }
}

struct BinauralProfileReference: Codable, Equatable, Sendable {
    var assetID: UUID
    var displayName: String
    var originalSourceName: String?
    var sampleRate: Double
    var tapCount: Int

    func validate() throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sampleRate.isFinite,
              sampleRate > 0,
              tapCount > 0,
              tapCount <= Int(N60_BINAURAL_MAX_TAPS) else {
            throw HeadphoneDeviceProfileError.invalidBinauralProfileReference
        }
    }
}

enum HeadphoneDeviceProfileError: Error, Equatable, LocalizedError {
    case profileDisabled
    case emptyName
    case outputDeviceRequired
    case outputDeviceUnavailable(String)
    case outputMustBeStereoCapable(UInt32)
    case sampleRateUnsupported(Double)
    case invalidHeadroom
    case insufficientHeadroom(requiredDB: Double, configuredDB: Double)
    case invalidEQBand
    case invalidChannelCorrection
    case invalidCrossfeed
    case invalidBinauralProfileReference
    case binauralProfileRequired
    case binauralProfileSampleRateMismatch(profile: Double, output: Double)
    case programSourceUnavailable(String)
    case programSourceChannelCountMismatch(expected: UInt32, actual: UInt32)
    case headTrackingRequiresVirtualSpeakers
    case speakerProfileConflict
    case legacyPhysicalRoutingConflict
    case speakerProcessingConflict(String)
    case binauralRuntimeUnavailable
    case configurationChangeRequiresRestart
    case realtimeSnapshotCompilationFailed

    var errorDescription: String? {
        switch self {
        case .profileDisabled:
            return "Enable the Headphone Device Profile before starting headphone playback."
        case .emptyName:
            return "Headphone Device Profile name cannot be empty."
        case .outputDeviceRequired:
            return "Associate the Headphone Device Profile with an output device."
        case .outputDeviceUnavailable(let uid):
            return "Headphone output device is unavailable: \(uid)."
        case .outputMustBeStereoCapable(let channels):
            return "Headphone playback requires at least two physical output channels; the selected device exposes \(channels)."
        case .sampleRateUnsupported(let rate):
            return "The headphone output does not support \(rate) Hz natively."
        case .invalidHeadroom:
            return "Headphone headroom attenuation must be between 0 and 30 dB."
        case .insufficientHeadroom(let required, let configured):
            return String(format: "Headphone correction can add up to %.1f dB conservatively; configure at least %.1f dB of headroom (currently %.1f dB).", required, required, configured)
        case .invalidEQBand:
            return "Headphone correction contains an invalid EQ band."
        case .invalidChannelCorrection:
            return "Headphone channel gain, polarity, delay, or EQ is outside the supported range."
        case .invalidCrossfeed:
            return "Headphone crossfeed settings are invalid for the current sample rate."
        case .invalidBinauralProfileReference:
            return "The selected virtual-speaker profile reference is invalid."
        case .binauralProfileRequired:
            return "Virtual Speakers mode requires an imported normalized HRTF/BRIR profile."
        case .binauralProfileSampleRateMismatch(let profile, let output):
            return "The virtual-speaker profile is \(profile) Hz but the headphone output is \(output) Hz. Spatial SRC is not implicit."
        case .programSourceUnavailable(let uid):
            return "The Virtual Speakers program source is unavailable: \(uid)."
        case .programSourceChannelCountMismatch(let expected, let actual):
            return "Virtual Speakers expects \(expected) program channels, but the selected source exposes \(actual)."
        case .headTrackingRequiresVirtualSpeakers:
            return "Head tracking is available only in Virtual Speakers mode."
        case .speakerProfileConflict:
            return "Disable the semantic speaker Output Device Profile before enabling the Headphone Device Profile."
        case .legacyPhysicalRoutingConflict:
            return "Disable legacy physical speaker routing before enabling the Headphone Device Profile."
        case .speakerProcessingConflict(let stage):
            return "Disable \(stage) before enabling the Headphone Device Profile."
        case .binauralRuntimeUnavailable:
            return "Virtual Speakers is not available until a prepared binaural profile is activated by the spatial runtime."
        case .configurationChangeRequiresRestart:
            return "Stop processing before changing the active Headphone Device Profile."
        case .realtimeSnapshotCompilationFailed:
            return "Unable to compile the Headphone Device Profile into the realtime headphone DSP snapshot."
        }
    }
}

/// Hardware correction owned by a Playback System. Content EQ/dynamics remain in
/// the Content Preset. The profile is deliberately independent from the PR62
/// semantic speaker Output Device Profile.
struct HeadphoneDeviceProfileConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var name = "Headphones"
    var outputDeviceUID: String?
    var targetCurve: HeadphoneTargetCurve = .neutral
    var headroomAttenuationDB = 6.0
    var left = HeadphoneChannelCorrection()
    var right = HeadphoneChannelCorrection()
    var crossfeed = HeadphoneCrossfeedConfiguration()
    var spatialMode: HeadphoneSpatialMode = .stereo
    /// Optional decoded-program endpoint used only by Virtual Speakers. Nil means
    /// use the physical headphone output endpoint as the program source.
    var programSourceDeviceUID: String?
    var programLayout: OutputProgramLayout = .stereo
    var binauralProfile: BinauralProfileReference?
    var headTracking: HeadTrackingConfiguration?

    var conservativeRequiredHeadroomDB: Double {
        max(left.conservativePositiveGainDB, right.conservativePositiveGainDB)
    }

    func validateStructure(sampleRate: Double) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HeadphoneDeviceProfileError.emptyName
        }
        guard headroomAttenuationDB.isFinite,
              (0.0...30.0).contains(headroomAttenuationDB) else {
            throw HeadphoneDeviceProfileError.invalidHeadroom
        }
        try left.validate(sampleRate: sampleRate)
        try right.validate(sampleRate: sampleRate)
        try crossfeed.validate(sampleRate: sampleRate)
        let required = conservativeRequiredHeadroomDB
        guard headroomAttenuationDB + 1.0e-6 >= required else {
            throw HeadphoneDeviceProfileError.insufficientHeadroom(
                requiredDB: required,
                configuredDB: headroomAttenuationDB
            )
        }
        if spatialMode == .virtualSpeakers {
            guard let binauralProfile else {
                throw HeadphoneDeviceProfileError.binauralProfileRequired
            }
            try binauralProfile.validate()
            // A profile at another rate is converted at activation (control
            // plane, explicit in the UI); it only fails when the converted
            // response would exceed the renderer's tap budget.
            guard BinauralProfileAsset.resampledTapCount(
                binauralProfile.tapCount,
                from: binauralProfile.sampleRate,
                to: sampleRate
            ) <= Int(N60_BINAURAL_MAX_TAPS) else {
                throw HeadphoneDeviceProfileError.binauralProfileSampleRateMismatch(
                    profile: binauralProfile.sampleRate,
                    output: sampleRate
                )
            }
        }
        if let headTracking {
            try headTracking.validate()
            if headTracking.enabled && spatialMode != .virtualSpeakers {
                throw HeadphoneDeviceProfileError.headTrackingRequiresVirtualSpeakers
            }
        }
    }

    func validateForActivation(
        availableDevices: [AudioOutputDevice],
        selectedOutputUID: String,
        sampleRate: Double
    ) throws -> AudioOutputDevice {
        guard enabled else { throw HeadphoneDeviceProfileError.profileDisabled }
        try validateStructure(sampleRate: sampleRate)
        guard let outputDeviceUID, outputDeviceUID == selectedOutputUID else {
            throw HeadphoneDeviceProfileError.outputDeviceRequired
        }
        guard let output = availableDevices.first(where: { $0.uid == outputDeviceUID }) else {
            throw HeadphoneDeviceProfileError.outputDeviceUnavailable(outputDeviceUID)
        }
        guard output.outputChannelCount == 2 else {
            throw HeadphoneDeviceProfileError.outputMustBeStereoCapable(output.outputChannelCount)
        }
        guard output.supports(sampleRate: sampleRate) else {
            throw HeadphoneDeviceProfileError.sampleRateUnsupported(sampleRate)
        }
        return output
    }

    func resolveProgramSource(
        availableDevices: [AudioOutputDevice],
        selectedOutput: AudioOutputDevice
    ) throws -> AudioOutputDevice {
        guard spatialMode == .virtualSpeakers else { return selectedOutput }
        let uid = programSourceDeviceUID ?? selectedOutput.uid
        guard let source = availableDevices.first(where: { $0.uid == uid }) else {
            throw HeadphoneDeviceProfileError.programSourceUnavailable(uid)
        }
        let expected = UInt32(programLayout.roles.count)
        guard source.outputChannelCount == expected else {
            throw HeadphoneDeviceProfileError.programSourceChannelCountMismatch(
                expected: expected, actual: source.outputChannelCount
            )
        }
        return source
    }

    func makeRealtimeSnapshot(sampleRate: Double) throws -> N60HeadphoneDSPSnapshot {
        try validateStructure(sampleRate: sampleRate)
        var snapshot = N60HeadphoneDSPSnapshotMakeUnity(sampleRate)
        guard snapshot.sampleRate > 0,
              N60HeadphoneDSPSetTargetCurveKind(&snapshot, targetCurve.realtimeCType),
              N60HeadphoneDSPSetHeadroomAttenuationDB(&snapshot, headroomAttenuationDB),
              applyChannel(left, index: 0, sampleRate: sampleRate, snapshot: &snapshot),
              applyChannel(right, index: 1, sampleRate: sampleRate, snapshot: &snapshot),
              N60HeadphoneDSPSetCrossfeed(
                &snapshot,
                Float(crossfeed.amount),
                crossfeed.virtualSpeakerAngleDegrees,
                crossfeed.headRadiusMeters,
                crossfeed.headShadowFrequencyHz,
                spatialMode == .stereo && crossfeed.preset != .off && crossfeed.amount > 0
              ),
              N60HeadphoneDSPSnapshotIsValid(&snapshot) else {
            throw HeadphoneDeviceProfileError.realtimeSnapshotCompilationFailed
        }
        return snapshot
    }

    private func applyChannel(
        _ correction: HeadphoneChannelCorrection,
        index: UInt32,
        sampleRate: Double,
        snapshot: inout N60HeadphoneDSPSnapshot
    ) -> Bool {
        let gain = Float(pow(10.0, correction.gainDB / 20.0))
        guard N60HeadphoneDSPSetChannelGain(&snapshot, index, gain),
              N60HeadphoneDSPSetChannelPolarityInverted(
                &snapshot,
                index,
                correction.polarityInverted
              ),
              N60HeadphoneDSPSetChannelDelayMs(
                &snapshot,
                index,
                correction.delayMilliseconds
              ) else { return false }
        for (bandIndex, band) in correction.eqBands.enumerated() {
            guard N60HeadphoneDSPSetChannelEQBand(
                &snapshot,
                index,
                UInt32(bandIndex),
                band.type.realtimeCType,
                band.frequencyHz,
                band.gainDB,
                band.q,
                band.enabled
            ) else { return false }
        }
        return true
    }
}


// MARK: - Batch 3: provenance-gated optional local EQ proposals

/// A user's OWN local correction proposal, not a bundled headphone database.
/// Attribution and license strings are provenance only; they are not a grant
/// of redistribution rights or evidence that any measurement was performed.
struct HeadphoneCorrectionProposal: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var headphoneModel: String
    var sourceName: String
    var sourceAttribution: String
    var sourceLicense: String
    var referenceSampleRate: Double?
    var leftBands: [HeadphoneCorrectionEQBand]
    var rightBands: [HeadphoneCorrectionEQBand]

    func validate(sampleRate: Double) throws {
        guard schemaVersion == 1,
              sampleRate.isFinite, (8_000...384_000).contains(sampleRate),
              !headphoneModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceAttribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceLicense.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              referenceSampleRate.map({
                  $0.isFinite && abs($0 - sampleRate) < 0.5
              }) ?? true,
              leftBands.count <= Int(N60_HEADPHONE_MAX_EQ_SECTIONS),
              rightBands.count <= Int(N60_HEADPHONE_MAX_EQ_SECTIONS),
              Set(leftBands.map(\.id)).count == leftBands.count,
              Set(rightBands.map(\.id)).count == rightBands.count else {
            throw HeadphoneCorrectionProposalError.invalidSourceOrRate
        }
        for band in leftBands + rightBands {
            try band.validate(sampleRate: sampleRate)
        }
    }

    static func load(from file: URL, sampleRate: Double) throws -> Self {
        let data = try Data(contentsOf: file)
        guard data.count <= 64 * 1024 else {
            throw HeadphoneCorrectionProposalError.fileTooLarge
        }
        let proposal = try JSONDecoder().decode(Self.self, from: data)
        try proposal.validate(sampleRate: sampleRate)
        return proposal
    }
}

enum HeadphoneCorrectionProposalError: Error, LocalizedError {
    case fileTooLarge
    case invalidSourceOrRate

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "The local headphone proposal exceeds the 64-KB limit."
        case .invalidSourceOrRate:
            return "The proposal has invalid or uncredited source metadata, an incompatible declared sample rate, duplicated band IDs, or more than 16 bands per ear."
        }
    }
}

extension HeadphoneDeviceProfileConfiguration {
    /// Stage the proposal in an editable draft. This never saves a Playback
    /// System, changes audio or downloads a profile. Do not auto-apply.
    mutating func stageLocalProposal(
        _ proposal: HeadphoneCorrectionProposal, sampleRate: Double
    ) throws {
        try proposal.validate(sampleRate: sampleRate)
        var updated = self
        updated.left.eqBands = proposal.leftBands
        updated.right.eqBands = proposal.rightBands
        let need = updated.conservativeRequiredHeadroomDB
        guard need.isFinite, need <= 30 else {
            throw HeadphoneDeviceProfileError.insufficientHeadroom(
                requiredDB: need, configuredDB: headroomAttenuationDB
            )
        }
        updated.headroomAttenuationDB = max(updated.headroomAttenuationDB, need)
        try updated.validateStructure(sampleRate: sampleRate)
        self = updated
    }
}

/// Control/UI-only response visualization from the SAME production float
/// coefficient design. This is electrical DSP transfer, not measured SPL,
/// headphone compensation target or physical frequency-response prediction.
enum HeadphoneEQResponsePreview {
    static func magnitudeDB(
        _ correction: HeadphoneChannelCorrection,
        frequencyHz: Double,
        sampleRate: Double,
        headroomAttenuationDB: Double
    ) -> Double? {
        guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate),
              frequencyHz.isFinite, frequencyHz > 0,
              frequencyHz < sampleRate / 2,
              headroomAttenuationDB.isFinite else { return nil }
        var db = correction.gainDB - headroomAttenuationDB
        let w = 2 * Double.pi * frequencyHz / sampleRate
        let c1 = cos(w), c2 = cos(2 * w)
        let s1 = sin(w), s2 = sin(2 * w)
        for band in correction.eqBands where band.enabled {
            var c = N60BiquadCoefficientsMakeIdentity()
            guard N60BiquadDesign(
                band.type.realtimeCType, sampleRate, band.frequencyHz,
                band.gainDB, band.q, &c
            ) else { return nil }
            let nr = Double(c.b0) + Double(c.b1) * c1
                + Double(c.b2) * c2
            let ni = -(Double(c.b1) * s1 + Double(c.b2) * s2)
            let dr = 1 + Double(c.a1) * c1 + Double(c.a2) * c2
            let di = -(Double(c.a1) * s1 + Double(c.a2) * s2)
            let numerator = nr * nr + ni * ni
            let denominator = dr * dr + di * di
            guard numerator.isFinite, numerator > 1e-24,
                  denominator.isFinite, denominator > 1e-24 else {
                return nil
            }
            db += 10 * log10(numerator / denominator)
        }
        return db.isFinite ? db : nil
    }

    static func curve(
        _ correction: HeadphoneChannelCorrection,
        sampleRate: Double,
        headroomAttenuationDB: Double,
        pointCount: Int = 96
    ) -> [(hz: Double, db: Double)] {
        guard (2...512).contains(pointCount), sampleRate.isFinite,
              sampleRate >= 8_000, sampleRate <= 384_000 else { return [] }
        let low = 20.0
        let high = min(20_000.0, 0.45 * sampleRate)
        return (0..<pointCount).compactMap { i in
            let t = Double(i) / Double(pointCount - 1)
            let hz = low * pow(high / low, t)
            guard let db = magnitudeDB(
                correction, frequencyHz: hz, sampleRate: sampleRate,
                headroomAttenuationDB: headroomAttenuationDB
            ) else { return nil }
            return (hz: hz, db: db)
        }
    }
}
