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
    case speakerProfileConflict
    case legacyPhysicalRoutingConflict
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
        case .speakerProfileConflict:
            return "Disable the semantic speaker Output Device Profile before enabling the Headphone Device Profile."
        case .legacyPhysicalRoutingConflict:
            return "Disable legacy physical speaker routing before enabling the Headphone Device Profile."
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
    var binauralProfile: BinauralProfileReference?

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
            guard abs(binauralProfile.sampleRate - sampleRate) < 0.5 else {
                throw HeadphoneDeviceProfileError.binauralProfileSampleRateMismatch(
                    profile: binauralProfile.sampleRate,
                    output: sampleRate
                )
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
        guard output.outputChannelCount >= 2 else {
            throw HeadphoneDeviceProfileError.outputMustBeStereoCapable(output.outputChannelCount)
        }
        guard output.supports(sampleRate: sampleRate) else {
            throw HeadphoneDeviceProfileError.sampleRateUnsupported(sampleRate)
        }
        return output
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
                crossfeed.preset != .off && crossfeed.amount > 0
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
