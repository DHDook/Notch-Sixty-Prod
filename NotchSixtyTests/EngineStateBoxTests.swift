import XCTest
@testable import NotchSixty

/// E23 S4 part 4 (G20): the engine state boxes keep their invariants.
@MainActor
final class EngineStateBoxTests: XCTestCase {
    func testRecoveryGenerationOnlyAdvancesAndResetsFailureCount() {
        let box = OutputRecoveryState()
        let first = box.beginRecoveryGeneration()
        XCTAssertEqual(box.recordRecoveryBuildFailure(), 1)
        XCTAssertEqual(box.recordRecoveryBuildFailure(), 2)
        XCTAssertEqual(box.recoveryFailures, 2)
        let second = box.beginRecoveryGeneration()
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(box.recoveryConsecutiveBuildFailures, 0)
        XCTAssertEqual(box.recoveryFailures, 2)
        box.recordRecoverySuccess()
        XCTAssertEqual(box.recoverySuccesses, 1)
    }

    func testCancelAllPendingInvalidatesGenerationAndClearsItems() {
        let box = OutputRecoveryState()
        let generation = box.beginRecoveryGeneration()
        box.scheduleRecovery(DispatchWorkItem {})
        box.scheduleReconfiguration(DispatchWorkItem {})
        box.cancelAllPending()
        XCTAssertNotEqual(box.recoveryGeneration, generation)
        XCTAssertNil(box.recoveryWorkItem)
        XCTAssertNil(box.reconfigurationWorkItem)
    }

    func testProgramSlotsWrapAndOnlyAdvanceFromUse() {
        let box = PreparedProgramSlots()
        let count = UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        XCTAssertEqual(box.eqFIRSlotToUse, 0)
        box.advanceEQFIRSlot(after: count - 1)
        XCTAssertEqual(box.eqFIRSlotToUse, 0)
        box.advanceEQFIRSlot(after: 0)
        XCTAssertEqual(box.eqFIRSlotToUse, 1 % count)
        XCTAssertEqual(box.roomCorrectionSlotToUse, 0)
        box.resetForNewSession()
        XCTAssertEqual(box.nextEQFIRProgramSlot, 0)
        XCTAssertNil(box.activeEQFIRProgram)
        XCTAssertNil(box.linearPhaseDesignInfo)
    }

    func testMasterVolumeBoxRejectsInvalidKeyStep() {
        let box = MasterVolumeState()
        let before = box.softwareVolumeKeyStep
        box.setSoftwareVolumeKeyStep(.fraction(denominator: 0))
        XCTAssertEqual(box.softwareVolumeKeyStep, before)
        box.setSoftwareVolumeKeyStep(.decibels(2))
        XCTAssertEqual(box.softwareVolumeKeyStep, .decibels(2))
    }

    func testTransportBoxResetKeepsLifetimeCounters() {
        let box = TransportSessionState()
        var counters = AudioTransportCounters()
        counters.underrunFrames = 7
        counters.bufferedFrames = 9
        box.archive(counters)
        XCTAssertEqual(box.lifetimeArchivedCounters.underrunFrames, 7)
        XCTAssertEqual(box.lifetimeArchivedCounters.bufferedFrames, 0)
        box.resetProcessingSessionCounters()
        XCTAssertEqual(box.processingSessionArchivedCounters.underrunFrames, 0)
        XCTAssertEqual(box.lifetimeArchivedCounters.underrunFrames, 7)
    }
}
