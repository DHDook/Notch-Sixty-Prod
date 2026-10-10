import Foundation

/// Bridges *already timestamped* HAL reference frames to a native,
/// allocation-free, metadata-only deadline FIFO. Caller must provide verified
/// cross-calibrated acoustic and output clock seconds for each input frame.
/// This is intentionally called off the HAL callback; no DAC send API exists.
final class QuietZoneNativeShadowTimingTransport {
    private var bridge: OpaquePointer?
    private var lastInputCallbackHostTicks: UInt64?
    private var halted = false

    init(
        plan: QuietZoneFeedForwardSchedulingPlan,
        candidate: QuietZoneCausalFIRCandidate,
        routeLeaseToken: UInt64,
        synchronizedClockToken: UInt64,
        capacity: UInt32 = 512
    ) throws {
        guard routeLeaseToken != 0, synchronizedClockToken != 0,
              candidate.sampleRate.isFinite,
              abs(candidate.sampleRate - plan.rig.sampleRate) < 0.5,
              !candidate.leftTaps.isEmpty,
              candidate.leftTaps.count == candidate.rightTaps.count,
              candidate.leftTaps.count <= QuietZoneCausalFIRCompiler.maximumTaps
        else { throw QuietZoneFeedForwardSchedulingError.invalidPlan }

        var native = N60FFDeadlinePlan()
        native.routeLeaseToken = routeLeaseToken
        native.synchronizedClockToken = synchronizedClockToken
        native.sampleRate = plan.rig.sampleRate
        native.conservativeNoiseLeadSeconds = plan.conservativeNoiseLeadSeconds
        native.referenceAcquisitionSeconds = plan.acquisitionLatencySeconds
        native.processingSeconds = plan.processingLatencySeconds
        native.commandToSeatSeconds = plan.commandToSeatLatencySeconds
        native.totalSafetyGuardSeconds = plan.deadlineGuardSeconds

        let created = candidate.leftTaps.withUnsafeBufferPointer { left in
            candidate.rightTaps.withUnsafeBufferPointer { right in
                N60FFDeadlineBridgeCreate(
                    capacity, &native, left.baseAddress!, right.baseAddress!,
                    UInt32(left.count)
                )
            }
        }
        guard let created else {
            throw QuietZoneFeedForwardSchedulingError.invalidPlan
        }
        bridge = created
    }

    deinit { close() }

    /// Stop and release only when no producer or consumer invocation is active.
    /// Like its native C substrate, this object is NOT thread-safe for multiple
    /// producers and is not exposed to any Core Audio IOProc.
    func close() {
        if let bridge {
            N60FFDeadlineBridgeStop(bridge)
            N60FFDeadlineBridgeDestroy(bridge)
            self.bridge = nil
        }
        halted = true
    }

    private func invalidate() {
        halted = true
        if let bridge { N60FFDeadlineBridgeStop(bridge) }
    }

    /// The event's acoustic/availability/evaluation times MUST be on a
    /// calibrated common host-seconds timebase. A bare macOS host tick or
    /// Swift Date is never enough; this wrapper only validates shape.
    @discardableResult
    func ingest(
        referenceFrame: N60FeedForwardReferenceFrame,
        witnessed: QuietZoneFeedForwardReferenceDeadlineEvent,
        output: N60FFDeadlineOutputWitness
    ) throws -> Bool {
        guard !halted, let bridge else {
            throw QuietZoneFeedForwardSchedulingError.disabled
        }
        let inputFrame = referenceFrame.firstFrameSampleTime
            + Double(referenceFrame.frameOffset)
        guard referenceFrame.firstFrameHostTime != 0,
              referenceFrame.firstFrameSampleTime.isFinite,
              inputFrame.isFinite,
              inputFrame >= 0,
              abs(witnessed.referenceSampleFrame - inputFrame) < 0.05,
              referenceFrame.sample.isFinite,
              witnessed.microphoneSample.isFinite,
              abs(referenceFrame.sample - witnessed.microphoneSample) < 0.000001,
              lastInputCallbackHostTicks.map({
                  referenceFrame.firstFrameHostTime >= $0
              }) ?? true else {
            invalidate()
            throw QuietZoneFeedForwardSchedulingError.invalidReference
        }

        var input = N60FFDeadlineReference()
        input.referenceFrame = inputFrame
        input.acousticAtHostSeconds = witnessed.referenceAcousticHostSeconds
        input.availableAtHostSeconds = witnessed.referenceAvailableHostSeconds
        input.evaluatedAtHostSeconds = witnessed.evaluatedAtHostSeconds
        input.referenceSample = referenceFrame.sample

        var actualOutput = output
        guard N60FFDeadlineBridgeProcess(bridge, &input, &actualOutput) else {
            halted = true
            throw QuietZoneFeedForwardSchedulingError.disabled
        }
        lastInputCallbackHostTicks = referenceFrame.firstFrameHostTime
        return true
    }

    func readDiagnostics(maximum: Int = 256) -> [N60FFDeadlineRecord] {
        guard !halted, let bridge, maximum > 0 else { return [] }
        let count = min(maximum, 256)
        var rows = [N60FFDeadlineRecord](
            repeating: N60FFDeadlineRecord(), count: count
        )
        let taken = rows.withUnsafeMutableBufferPointer { ptr in
            N60FFDeadlineBridgeRead(bridge, ptr.baseAddress!, UInt32(ptr.count))
        }
        rows.removeLast(rows.count - Int(taken))
        return rows
    }

    func snapshot() -> N60FFDeadlineSnapshot {
        guard let bridge else { return N60FFDeadlineSnapshot() }
        return N60FFDeadlineBridgeGetSnapshot(bridge)
    }

    /// Control-plane dry-run ONLY. Advances a counter representing how a
    /// hypothetical wet ANC component would fade to zero after a fault.
    /// No audio samples or commands exist; this cannot fade real speakers.
    func advanceSimulatedFaultBypass(frames: UInt32) -> Bool {
        guard let bridge else { return false }
        return N60FFDeadlineBridgeAdvanceFaultFade(bridge, frames)
    }

    /// Clock faults must revoke pending diagnostic records atomically.
    func stopForClockFault() { invalidate() }

    var outputConnected: Bool { false }
    var liveANCQualified: Bool { false }
}
