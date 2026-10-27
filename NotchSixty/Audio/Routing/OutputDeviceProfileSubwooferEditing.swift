import Foundation

// E8 A5: pure edits of an Output Device Profile's physical subwoofers for the Speakers-tab card. Add, remove and
// reassign keep the Sub indices contiguous from 0 and carry each sub's own calibration with it. Records that depend on
// the sub set or the destinations (coherent alignment, calibration summary, Speaker Optimizer PEQ/FIR) are cleared
// when they no longer validate against the edited profile and are listed so the UI can ask first; records that still
// validate are kept as they are. No engine access.

enum OutputDeviceProfileSubwooferEditError: Error, Equatable, LocalizedError {
    case limit
    case unknownSubwoofer(UInt32)

    var errorDescription: String? {
        switch self {
        case .limit: return "At most \(SubwooferLimit.graph) subwoofers are supported."
        case .unknownSubwoofer(let index): return "Sub \(index + 1) is not in this profile."
        }
    }
}

/// An edited profile and the stored records the edit invalidated (already cleared in `profile`).
struct OutputDeviceProfileSubwooferEdit: Equatable {
    var profile: OutputDeviceProfileConfiguration
    var clearedRecords: [String]
}

extension OutputDeviceProfileConfiguration {
    /// The lowest channel of `deviceUID` below `channelCount` that no speaker or sub of this profile uses.
    func nextFreeDestination(deviceUID: String, channelCount: UInt32) -> PhysicalOutputEndpoint? {
        let used = Set(allDestinations.filter { $0.deviceUID == deviceUID }.map(\.channelIndex))
        return (0..<channelCount).first { !used.contains($0) }
            .map { PhysicalOutputEndpoint(deviceUID: deviceUID, channelIndex: $0) }
    }

    var allDestinations: [PhysicalOutputEndpoint] {
        speakerAssignments.map(\.destination) + subwooferAssignments.map(\.destination)
    }

    func addingSubwoofer(destination: PhysicalOutputEndpoint) throws -> OutputDeviceProfileSubwooferEdit {
        guard subwooferAssignments.count < SubwooferLimit.graph else {
            throw OutputDeviceProfileSubwooferEditError.limit
        }
        var next = self
        next.subwooferAssignments.append(PhysicalSubwooferOutputAssignment(
            index: UInt32(subwooferAssignments.count), destination: destination))
        return next.clearingInvalidRecords()
    }

    /// Removes Sub `index` and renumbers the higher subs down by one; each keeps its own calibration.
    func removingSubwoofer(index: UInt32) throws -> OutputDeviceProfileSubwooferEdit {
        guard subwooferAssignments.contains(where: { $0.index == index }) else {
            throw OutputDeviceProfileSubwooferEditError.unknownSubwoofer(index)
        }
        var next = self
        next.subwooferAssignments = subwooferAssignments
            .filter { $0.index != index }
            .map { assignment in
                var a = assignment
                if a.index > index { a.index -= 1 }
                return a
            }
            .sorted { $0.index < $1.index }
        return next.clearingInvalidRecords()
    }

    func movingSubwoofer(index: UInt32, to destination: PhysicalOutputEndpoint) throws -> OutputDeviceProfileSubwooferEdit {
        guard let position = subwooferAssignments.firstIndex(where: { $0.index == index }) else {
            throw OutputDeviceProfileSubwooferEditError.unknownSubwoofer(index)
        }
        var next = self
        next.subwooferAssignments[position].destination = destination
        return next.clearingInvalidRecords()
    }

    /// Clears each dependent record that fails validation against this (already edited) profile.
    private func clearingInvalidRecords() -> OutputDeviceProfileSubwooferEdit {
        var next = self
        var cleared: [String] = []
        if let summary = calibrationSummary,
           (try? summary.validate()) == nil || summary.subwooferCount != subwooferAssignments.count {
            next.calibrationSummary = nil
            cleared.append("Calibration summary")
        }
        if let record = coherentSubwooferAlignment, !record.validate(profile: self) {
            next.coherentSubwooferAlignment = nil
            cleared.append("Coherent subwoofer alignment")
        }
        if let record = coherentMultiSubwooferAlignment, !record.validate(profile: self) {
            next.coherentMultiSubwooferAlignment = nil
            cleared.append("Coherent multi-subwoofer alignment")
        }
        if let record = speakerOptimizerPEQ, (try? record.validate(profile: self)) == nil {
            next.speakerOptimizerPEQ = nil
            cleared.append("Speaker Optimizer EQ")
        }
        if let record = speakerOptimizerFIR, (try? record.validate(profile: self)) == nil {
            next.speakerOptimizerFIR = nil
            cleared.append("Speaker Optimizer FIR")
        }
        return OutputDeviceProfileSubwooferEdit(profile: next, clearedRecords: cleared)
    }
}
