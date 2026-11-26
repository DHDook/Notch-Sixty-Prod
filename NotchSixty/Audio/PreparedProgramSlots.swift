import Foundation

/// E23 S4 part 4 (G20): the prepared convolution programs the stereo session has installed (EQ FIR, room correction,
/// speaker IR), their slot cursors and the design details the UI shows. Fields are `private(set)`; a slot cursor moves
/// only forward through `advance...Slot`, and `clearAll` / `resetForNewSession` are the only ways to drop a program
/// together with its design info.
///
/// Main actor only. The slot numbers index the render path's program slots; they wrap at `N60_CONVOLUTION_PROGRAM_SLOTS`.
@MainActor
@Observable
final class PreparedProgramSlots {
    private(set) var activeEQFIRProgram: PreparedEQFIRProgram?
    private(set) var activeRoomCorrectionProgram: PreparedRoomCorrectionProgram?
    private(set) var activeSpeakerIRProgram: PreparedSpeakerIRProgram?
    @ObservationIgnored private(set) var nextEQFIRProgramSlot: UInt32 = 0
    @ObservationIgnored private(set) var nextRoomCorrectionProgramSlot: UInt32 = 0
    @ObservationIgnored private(set) var nextSpeakerIRProgramSlot: UInt32 = 0
    @ObservationIgnored private(set) var adaptedRoomCorrectionFilter:
        (source: RoomCorrectionFilter, sampleRate: Double, filter: RoomCorrectionFilter)?
    private(set) var linearPhaseDesignInfo: EQLinearPhaseDesignInfo?
    /// E24 S3b: why an enabled lane-plan correction is not shaping playback right now, for Room Correction to show.
    private(set) var roomCorrectionInactiveReason: RoomCorrectionInactiveReason?

    private static var slotCount: UInt32 { UInt32(N60_CONVOLUTION_PROGRAM_SLOTS) }

    /// The slot the next EQ FIR program is prepared into.
    var eqFIRSlotToUse: UInt32 { nextEQFIRProgramSlot % Self.slotCount }
    var roomCorrectionSlotToUse: UInt32 { nextRoomCorrectionProgramSlot % Self.slotCount }
    var speakerIRSlotToUse: UInt32 { nextSpeakerIRProgramSlot % Self.slotCount }

    func advanceEQFIRSlot(after slot: UInt32) { nextEQFIRProgramSlot = (slot + 1) % Self.slotCount }
    func advanceRoomCorrectionSlot(after slot: UInt32) { nextRoomCorrectionProgramSlot = (slot + 1) % Self.slotCount }
    func advanceSpeakerIRSlot(after slot: UInt32) { nextSpeakerIRProgramSlot = (slot + 1) % Self.slotCount }

    func setActiveEQFIRProgram(_ program: PreparedEQFIRProgram?) { activeEQFIRProgram = program }
    func setActiveRoomCorrectionProgram(_ program: PreparedRoomCorrectionProgram?) { activeRoomCorrectionProgram = program }
    func setActiveSpeakerIRProgram(_ program: PreparedSpeakerIRProgram?) { activeSpeakerIRProgram = program }
    func setLinearPhaseDesignInfo(_ info: EQLinearPhaseDesignInfo?) { linearPhaseDesignInfo = info }
    func setRoomCorrectionInactiveReason(_ reason: RoomCorrectionInactiveReason?) { roomCorrectionInactiveReason = reason }
    func setAdaptedRoomCorrectionFilter(source: RoomCorrectionFilter, sampleRate: Double, filter: RoomCorrectionFilter) {
        adaptedRoomCorrectionFilter = (source, sampleRate, filter)
    }

    /// Drops the three active programs (their session is gone) but leaves the design info.
    func clearActivePrograms() {
        activeEQFIRProgram = nil
        activeRoomCorrectionProgram = nil
        activeSpeakerIRProgram = nil
    }

    /// Drops every active program and the design info.
    func clearAll() {
        clearActivePrograms()
        linearPhaseDesignInfo = nil
    }

    /// A new stereo session starts with no programs and every slot cursor at zero.
    func resetForNewSession() {
        clearActivePrograms()
        nextEQFIRProgramSlot = 0
        nextRoomCorrectionProgramSlot = 0
        nextSpeakerIRProgramSlot = 0
    }
}

extension AudioIOEngine {
    /// Read-forwarders so callers and the UI keep the old names.
    var activeEQFIRProgram: PreparedEQFIRProgram? { programs.activeEQFIRProgram }
    var activeRoomCorrectionProgram: PreparedRoomCorrectionProgram? { programs.activeRoomCorrectionProgram }
    var activeSpeakerIRProgram: PreparedSpeakerIRProgram? { programs.activeSpeakerIRProgram }
    var nextEQFIRProgramSlot: UInt32 { programs.nextEQFIRProgramSlot }
    var nextRoomCorrectionProgramSlot: UInt32 { programs.nextRoomCorrectionProgramSlot }
    var nextSpeakerIRProgramSlot: UInt32 { programs.nextSpeakerIRProgramSlot }
    var adaptedRoomCorrectionFilter: (source: RoomCorrectionFilter, sampleRate: Double, filter: RoomCorrectionFilter)? {
        programs.adaptedRoomCorrectionFilter
    }
    var linearPhaseDesignInfo: EQLinearPhaseDesignInfo? { programs.linearPhaseDesignInfo }
    var roomCorrectionInactiveReason: RoomCorrectionInactiveReason? { programs.roomCorrectionInactiveReason }
}
