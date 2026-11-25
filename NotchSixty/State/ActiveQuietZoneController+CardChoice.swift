import Foundation

// E12 S19: the "where to quiet" choice over the existing zone and ear-position controllers. No new engine path:
// each choice sets the same state the old cards' own switches did, and nothing here arms anything.

extension ActiveQuietZoneController {
    /// The current choice, derived from the zone mode and the ear-position survey switch.
    var areaChoice: QuietZoneAreaChoice {
        switch zones?.mode ?? .fixedSeat {
        case .follow: return .followMyHead
        case .twoZones: return .twoZones
        case .fixedSeat: return (virtualMic?.isActive ?? false) ? .earPosition : .oneSeat
        }
    }

    /// Why a choice cannot be picked now, in plain words. Absent when it can.
    var areaUnavailableReasons: [QuietZoneAreaChoice: String] {
        var reasons: [QuietZoneAreaChoice: String] = [:]
        guard let virtualMic else {
            reasons[.earPosition] = "Ear-position quieting is not available in this build."
            reasons[.followMyHead] = "Follow my head needs an ear position, which is not available in this build."
            reasons[.twoZones] = "Two zones need ear positions, which are not available in this build."
            return reasons
        }
        if virtualMic.tones.isEmpty {
            reasons[.earPosition] = "Measure your ear position first (in the section below)."
        }
        for (choice, mode) in [(QuietZoneAreaChoice.followMyHead, QuietZoneZoneMode.follow), (.twoZones, .twoZones)] {
            guard let zones else {
                reasons[choice] = "Not available in this build."
                continue
            }
            if !virtualMic.isActive {
                reasons[choice] = "Choose Ear position first, once it is measured."
            } else if let why = zones.unavailableReason(mode) {
                reasons[choice] = mode == .follow ? "\(why) The camera option is under Advanced." : why
            }
        }
        return reasons
    }

    /// Applies a choice. False (nothing changed) when it is unavailable.
    @discardableResult
    func setAreaChoice(_ choice: QuietZoneAreaChoice) -> Bool {
        if areaUnavailableReasons[choice] != nil { return false }
        switch choice {
        case .oneSeat:
            zones?.setMode(.fixedSeat)
            virtualMic?.useAtEar = false
            zones?.revalidate()
        case .earPosition:
            zones?.setMode(.fixedSeat)
            virtualMic?.useAtEar = true
        case .followMyHead:
            return zones?.setMode(.follow) ?? false
        case .twoZones:
            return zones?.setMode(.twoZones) ?? false
        }
        return true
    }

    /// Everything the one card shows, from the controllers.
    @MainActor
    func cardInputs(
        engineRunning: Bool,
        microphonePermissionGranted: Bool,
        microphoneName: String?,
        measuredModelName: String?
    ) -> QuietZoneCardInputs {
        let subApplies = bassConditioningActive
        return QuietZoneCardInputs(
            microphonePermissionGranted: microphonePermissionGranted,
            microphoneName: microphoneName,
            engineRunning: engineRunning,
            measuredModelName: measuredModelName,
            subMeasurementApplies: subApplies,
            subMeasurementMissing: subApplies ? subAwareReadiness(mode: .tonal).message : nil,
            area: areaChoice,
            areaUnavailable: areaUnavailableReasons,
            armed: arm.isArmed,
            lastAutoDisarmMessage: arm.latchedByEvent ? arm.statusMessage : nil,
            feedForwardAvailable: feedForwardArming != nil,
            feedForwardOn: feedForwardArming?.isRequested ?? false,
            feedForwardFacts: feedForwardLiveFacts())
    }
}
