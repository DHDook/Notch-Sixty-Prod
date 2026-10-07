import Foundation

enum AudioUnitRackGenerationExchangeError: Error, Equatable, LocalizedError {
    case exchangeAllocationFailed
    case formatMismatch
    case latencyChangeRequiresRestart(current: Int, candidate: Int)
    case transitionBusy
    case publicationFailed
    case transitionFailed
    case transitionTimedOut

    var errorDescription: String? {
        switch self {
        case .exchangeAllocationFailed:
            return "Unable to allocate the fixed live Audio Unit rack exchange."
        case .formatMismatch:
            return "Candidate Audio Unit rack format does not match the active live session."
        case .latencyChangeRequiresRestart(let current, let candidate):
            return "Audio Unit rack latency changed from \(current) to \(candidate) frames; a controlled transport restart is required."
        case .transitionBusy:
            return "A previous Audio Unit rack generation is still transitioning."
        case .publicationFailed:
            return "The prepared Audio Unit rack generation could not be published."
        case .transitionFailed:
            return "The candidate Audio Unit rack generation failed during live crossfade; the prior generation remained active."
        case .transitionTimedOut:
            return "The live Audio Unit rack did not acknowledge the new generation before the bounded timeout."
        }
    }
}

/// Stable session-owned live processor.
///
/// The Core Audio callback enters only the C exchange. Swift owns the AU
/// runtimes strongly by exchange slot and retires them only after the C reader
/// count says that slot is no longer visible to realtime.
final class AudioUnitLiveRackSwitchboard: @unchecked Sendable {
    static let defaultCrossfadeFrames = 2_048
    static let acknowledgementPollNanoseconds: UInt64 = 5_000_000
    static let acknowledgementTimeoutNanoseconds: UInt64 = 2_000_000_000

    let format: AudioUnitRackProcessingFormat
    let latencyFrames: Int

    private let exchange: OpaquePointer
    private var runtimesBySlot: [Int: AudioUnitLiveRackRuntime] = [:]
    private var nextGeneration: UInt64 = 2

    init(
        format: AudioUnitRackProcessingFormat,
        initialRuntime: AudioUnitLiveRackRuntime?
    ) throws {
        try format.validate()
        if let initialRuntime {
            guard initialRuntime.format == format else {
                throw AudioUnitRackGenerationExchangeError.formatMismatch
            }
        }

        self.format = format
        self.latencyFrames = initialRuntime?.totalLatencyFrames ?? 0

        let created: OpaquePointer?
        if var initialProcessor = initialRuntime?.processor {
            created = withUnsafePointer(to: &initialProcessor) {
                N60AudioUnitRackExchangeCreate(
                    UInt32(format.channelCount),
                    UInt32(format.maximumFramesPerSlice),
                    UInt64(max(latencyFrames, 0)),
                    $0,
                    1
                )
            }
        } else {
            created = N60AudioUnitRackExchangeCreate(
                UInt32(format.channelCount),
                UInt32(format.maximumFramesPerSlice),
                0,
                nil,
                1
            )
        }
        guard let created else {
            throw AudioUnitRackGenerationExchangeError
                .exchangeAllocationFailed
        }
        exchange = created
        if let initialRuntime {
            runtimesBySlot[0] = initialRuntime
        }
    }

    deinit {
        for runtime in runtimesBySlot.values {
            runtime.stopFaultMonitoring()
        }
        runtimesBySlot.removeAll()
        N60AudioUnitRackExchangeDestroy(exchange)
    }

    var processor: N60AudioUnitLiveRackProcessor {
        N60AudioUnitRackExchangeGetProcessor(exchange)
    }

    var status: N60AudioUnitRackExchangeStatus {
        N60AudioUnitRackExchangeGetStatus(exchange)
    }

    /// Same-latency mutation path. The candidate is fully built before this is
    /// called. A nil runtime is an exact zero-latency passthrough generation.
    @MainActor
    func transition(
        to candidate: AudioUnitLiveRackRuntime?,
        crossfadeFrames: Int = defaultCrossfadeFrames
    ) async throws {
        if let candidate {
            guard candidate.format == format else {
                throw AudioUnitRackGenerationExchangeError.formatMismatch
            }
            guard candidate.totalLatencyFrames == latencyFrames else {
                throw AudioUnitRackGenerationExchangeError
                    .latencyChangeRequiresRestart(
                        current: latencyFrames,
                        candidate: candidate.totalLatencyFrames
                    )
            }
        } else if latencyFrames != 0 {
            throw AudioUnitRackGenerationExchangeError
                .latencyChangeRequiresRestart(
                    current: latencyFrames,
                    candidate: 0
                )
        }

        let before = status
        guard before.requestedSlot
                == N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT else {
            throw AudioUnitRackGenerationExchangeError.transitionBusy
        }

        let writable = Int(
            N60AudioUnitRackExchangeFindWritableSlot(exchange)
        )
        guard writable >= 0 else {
            throw AudioUnitRackGenerationExchangeError.transitionBusy
        }

        let generation = nextGeneration
        nextGeneration &+= 1
        if nextGeneration == 0 {
            nextGeneration = 1
        }

        let previousRuntime = runtimesBySlot[writable]
        if let candidate {
            runtimesBySlot[writable] = candidate
        } else {
            runtimesBySlot.removeValue(forKey: writable)
        }

        let frameCount = UInt32(
            min(max(crossfadeFrames, 0), Int(UInt32.max))
        )
        let published: Bool
        if var processor = candidate?.processor {
            published = withUnsafePointer(to: &processor) {
                N60AudioUnitRackExchangePublish(
                    exchange,
                    UInt32(writable),
                    $0,
                    generation,
                    frameCount
                )
            }
        } else {
            published = N60AudioUnitRackExchangePublish(
                exchange,
                UInt32(writable),
                nil,
                generation,
                frameCount
            )
        }

        guard published else {
            if let previousRuntime {
                runtimesBySlot[writable] = previousRuntime
            } else {
                runtimesBySlot.removeValue(forKey: writable)
            }
            throw AudioUnitRackGenerationExchangeError
                .publicationFailed
        }

        let failureBaseline = before.transitionFailureCount
        var waited: UInt64 = 0
        while waited < Self.acknowledgementTimeoutNanoseconds {
            let current = status
            if current.transitionFailureCount > failureBaseline {
                reclaimInactiveRuntimes()
                throw AudioUnitRackGenerationExchangeError
                    .transitionFailed
            }
            if current.renderedGeneration == generation,
               current.requestedSlot
                == N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT {
                reclaimInactiveRuntimes()
                return
            }
            try await Task.sleep(
                nanoseconds: Self.acknowledgementPollNanoseconds
            )
            waited &+= Self.acknowledgementPollNanoseconds
        }

        throw AudioUnitRackGenerationExchangeError
            .transitionTimedOut
    }

    @MainActor
    private func reclaimInactiveRuntimes() {
        for slot in 0..<Int(N60_AUDIO_UNIT_RACK_EXCHANGE_SLOT_COUNT) {
            guard N60AudioUnitRackExchangeSlotIsReclaimable(
                exchange,
                UInt32(slot)
            ) else {
                continue
            }
            if let runtime = runtimesBySlot.removeValue(forKey: slot) {
                runtime.stopFaultMonitoring()
            }
        }
    }
}
