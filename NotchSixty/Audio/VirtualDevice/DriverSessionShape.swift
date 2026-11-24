import Foundation

// E36 S6b: which ring layout a stereo session reads on the driver path. Pure, so the refusals and the two new shapes are
// tested without an output device (the session constructor calls it). Control plane only; no realtime code here.

enum DriverStereoSessionShape {
    /// - Parameters:
    ///   - programSourceUID: the fold's programme source, nil for a plain stereo session. The driver's own UID means "the ring
    ///     carries the wider programme"; any other device is a tap on that device, which the ring cannot replace.
    ///   - foldLayout: the wider programme's layout when a fold plan is set.
    ///   - hasAggregatePlan: a multi-device output (an aggregate is the clock domain, the ring is read in the DAC's callback).
    /// A same-device output plan is fine and needs no case here: the ring is stereo whatever the DAC's channel count, so a
    /// multichannel DAC drives active stereo speakers with no Audio MIDI Setup change (the tap would need one).
    static func resolve(programSourceUID: String?, foldLayout: OutputProgramLayout?, hasAggregatePlan: Bool) throws -> VirtualDeviceLayout {
        if hasAggregatePlan { throw DriverCaptureError.unsupportedSession("a multi-device output") }
        guard let uid = programSourceUID else { return .stereo }
        guard uid == ProgramFoldDown.driverSourceUID else {
            throw DriverCaptureError.unsupportedSession("a programme taken from another device")
        }
        // By layout, not channel count: 5.1.2 also has eight channels but not the 7.1 order.
        guard let programme = foldLayout, programme != .stereo, let layout = programme.driverLayout else {
            throw DriverCaptureError.unsupportedChannelCount(foldLayout?.roles.count ?? 0)
        }
        return layout
    }
}

extension OutputProgramLayout {
    /// The driver layout that carries this programme, nil for the layouts the protocol has no code for (3.1, 5.1.2, 9.1.6).
    var driverLayout: VirtualDeviceLayout? {
        switch self {
        case .stereo: return .stereo
        case .fiveOne: return .surround51
        case .sevenOne: return .surround71
        case .fiveOneFour: return .surround514
        case .sevenOneFour: return .surround714
        case .threeOne, .fiveOneTwo, .nineOneSix: return nil
        }
    }
}
