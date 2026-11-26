import CoreAudio
import Foundation

// E23 S4 part 3: production meters, analysis snapshots and the diagnostics snapshot, moved verbatim from AudioIOEngine.swift (no behaviour change).
extension AudioIOEngine {
    func productionAnalysisSnapshot() -> ProductionAnalysisSnapshot {
        if let session = nChannelTransportSession { return session.productionAnalysisSnapshot() }
        if let session = binauralHeadphoneTransportSession { return session.productionAnalysisSnapshot() }
        return transportSession?.productionAnalysisSnapshot() ?? .empty
    }

    func resetSpectrumPeakHold() {
        nChannelTransportSession?.resetSpectrumPeakHold()
        binauralHeadphoneTransportSession?.resetSpectrumPeakHold()
        transportSession?.resetSpectrumPeakHold()
    }

    /// E28 S6: per-route maxima for a stereo session whose output map drives several DAC channels (speakers plus subs on
    /// one device). Empty for every other session. Read-and-reset: the meter hub is the only caller while processing runs.
    func productionRouteMeters() -> [ProductionRouteMeter] {
        transportSession?.routeMeters() ?? []
    }

    func productionTransportMeterSnapshot() -> ProductionTransportMeterSnapshot? {
        if let session = nChannelTransportSession, let raw = session.bridgeSnapshot() {
            var meter = raw.meter
            let roles = session.routePlan.programLayout.roles
            let programChannels: [ProductionTransportChannelMeter] = roles.enumerated().map { index, role in
                let channel = UInt32(index)
                return ProductionTransportChannelMeter(
                    id: "program-\(role.rawValue)",
                    label: role.displayName,
                    channelIndex: channel,
                    peakLinear: N60LiveNChannelMeterProgramPeak(&meter, channel),
                    rmsLinear: N60LiveNChannelMeterProgramRMS(&meter, channel),
                    overRangeSamples: N60LiveNChannelMeterProgramOverRangeSamples(&meter, channel)
                )
            }

            var mapped: [(UInt32, String, String)] = []
            for (index, role) in roles.enumerated() {
                let physical = session.routePlan.programPhysicalChannels[index]
                guard physical != UInt32.max else { continue }
                mapped.append((physical, role.displayName, "physical-\(role.rawValue)"))
            }
            for sub in 0..<Int(session.routePlan.subwooferCount) {
                let physical = session.routePlan.subwooferPhysicalChannels[sub]
                guard physical != UInt32.max else { continue }
                mapped.append((physical, "Sub \(sub + 1)", "physical-sub-\(sub)"))
            }
            mapped.sort { $0.0 < $1.0 }
            let physicalOutputs = mapped.map { physical, label, id in
                ProductionTransportChannelMeter(
                    id: id,
                    label: label,
                    channelIndex: physical,
                    peakLinear: N60LiveNChannelMeterPhysicalPeak(&meter, physical),
                    rmsLinear: N60LiveNChannelMeterPhysicalRMS(&meter, physical),
                    overRangeSamples: N60LiveNChannelMeterPhysicalOverRangeSamples(&meter, physical)
                )
            }
            return ProductionTransportMeterSnapshot(
                kind: .semanticSpeakers,
                displayName: outputDeviceProfileConfiguration?.systemDisplayName
                    ?? session.routePlan.programLayout.displayName,
                programLayoutName: session.routePlan.programLayout.displayName,
                sampleRate: session.outputFormat.sampleRate,
                latencyFrames: raw.algorithmicLatencyFrames
                    + raw.adaptiveTransportLatencyFrames
                    + raw.roomTreatmentLatencyFrames,
                meteringEnabled: raw.meter.enabled,
                programChannels: programChannels,
                physicalOutputs: physicalOutputs,
                inputTruePeakLinear: nil,
                outputTruePeakLinear: nil,
                roomTreatment: raw.roomTreatmentConfigured
                    ? ProductionRoomTreatmentDiagnostics(
                        authorized: raw.roomTreatment.transition.authorized,
                        armRequested: raw.roomTreatment.transition.armRequested,
                        active: raw.roomTreatment.transition.state
                            == N60MIMOTreatmentStateActive,
                        transitioning:
                            raw.roomTreatment.transition.state
                                == N60MIMOTreatmentStateArming
                            || raw.roomTreatment.transition.state
                                == N60MIMOTreatmentStateDisarming
                            || raw.roomTreatment.transition.state
                                == N60MIMOTreatmentStateFaultFading,
                        faulted: raw.roomTreatment.transition.fault
                            != N60MIMOTreatmentFaultNone,
                        treatmentMix: raw.roomTreatment.transition.treatmentMix,
                        treatmentSourceCount: raw.roomTreatment.treatmentChannelCount,
                        latencyFrames: raw.roomTreatment.totalLatencyFrames,
                        processedFrames: raw.roomTreatment.processedFrames,
                        protectionClampSamples:
                            raw.roomTreatment.protectionClampSamples,
                        integrationFailures:
                            raw.roomTreatment.integrationFailures
                    )
                    : nil,
                renderFailures: raw.renderFailures,
                outputWriteFailures: raw.outputWriteFailures
            )
        }

        if let session = binauralHeadphoneTransportSession, let raw = session.bridgeSnapshot() {
            let meter = raw.meter
            let outputs = [
                ProductionTransportChannelMeter(
                    id: "headphone-left", label: "Left", channelIndex: 0,
                    peakLinear: meter.peakLeft, rmsLinear: meter.rmsLeft,
                    overRangeSamples: meter.overRangeLeft
                ),
                ProductionTransportChannelMeter(
                    id: "headphone-right", label: "Right", channelIndex: 1,
                    peakLinear: meter.peakRight, rmsLinear: meter.rmsRight,
                    overRangeSamples: meter.overRangeRight
                ),
            ]
            return ProductionTransportMeterSnapshot(
                kind: .virtualSpeakers,
                displayName: "Virtual \(session.programLayout.displayName) → Headphones",
                programLayoutName: session.programLayout.displayName,
                sampleRate: session.outputFormat.sampleRate,
                latencyFrames: raw.algorithmicLatencyFrames,
                meteringEnabled: meter.enabled,
                programChannels: [],
                physicalOutputs: outputs,
                inputTruePeakLinear: raw.protection.inputTruePeakLinear,
                outputTruePeakLinear: raw.protection.outputTruePeakLinear,
                roomTreatment: nil,
                renderFailures: raw.renderFailures,
                outputWriteFailures: raw.outputWriteFailures
            )
        }
        return nil
    }

    func diagnosticsSnapshot() -> AudioDiagnosticsSnapshot {
        let selectedDevice = selectedOutputDevice
        let currentCounters = transportSession?.counters()
            ?? nChannelTransportSession?.counters()
            ?? binauralHeadphoneTransportSession?.counters()
            ?? AudioTransportCounters()
        let processingSessionCounters = processingSessionArchivedCounters + currentCounters
        let lifetimeCounters = lifetimeArchivedCounters + currentCounters
        let activeTapSampleRate = transportSession?.tapFormat.sampleRate
            ?? nChannelTransportSession?.tapFormat.sampleRate
            ?? binauralHeadphoneTransportSession?.tapFormat.sampleRate
        let activeOutputSampleRate = transportSession?.outputFormat.sampleRate
            ?? nChannelTransportSession?.outputFormat.sampleRate
            ?? binauralHeadphoneTransportSession?.outputFormat.sampleRate
        let startupGateOpened = transportSession?.startupGateOpened
            ?? nChannelTransportSession?.startupGateOpened
            ?? binauralHeadphoneTransportSession?.startupGateOpened
        let startupGateTargetFrames = transportSession?.startupGateTargetFrames
            ?? nChannelTransportSession?.startupGateTargetFrames
            ?? binauralHeadphoneTransportSession?.startupGateTargetFrames
        let startupGateActivationFrames = transportSession?.startupGateActivationFrames
            ?? nChannelTransportSession?.startupGateActivationFrames
            ?? binauralHeadphoneTransportSession?.startupGateActivationFrames
        let stereoRenderDiagnostics = transportSession?.renderDiagnostics()
        // The stereo overlay already read FINAL_METER into outputMeter unless the bridge VU supplied it.
        let stereoFinalReading: StereoMeterReading? =
            (transportSession?.unifiedGraphReadback != nil && !N60RealtimeAudioBridgeOutputVUMeterDemand())
            ? stereoRenderDiagnostics?.outputMeter : nil
        // S8c: the stereo overlay also took this snapshot's gain-reduction and true-peak readings.
        let stereoDynamicsReading: UnifiedGraphDynamicsReading? = stereoRenderDiagnostics.flatMap { diagnostics in
            transportSession?.unifiedGraphReadback == nil ? nil : UnifiedGraphDynamicsReading(
                compressorGainReductionDB: diagnostics.compressorGainReductionDB,
                limiterGainReductionDB: diagnostics.limiterGainReductionDB,
                inputTruePeakLinear: diagnostics.inputTruePeakLinear,
                outputTruePeakLinear: diagnostics.outputTruePeakLinear,
                truePeakGuardActive: diagnostics.truePeakGuardActive)
        }
        return AudioDiagnosticsSnapshot(
            lifecycleState: lifecycle.state,
            selectedOutputUID: routeConfiguration.selectedOutputUID,
            selectedOutputName: selectedDevice?.name,
            selectedOutputPresent: selectedDevice != nil,
            selectedOutputNominalSampleRate: selectedDevice?.nominalSampleRate, selectedOutputTransport: selectedDevice?.transport,
            discoveredOutputCount: outputDevices.count,
            tapSampleRate: activeTapSampleRate,
            outputSampleRate: activeOutputSampleRate,
            sessionTransportCounters: processingSessionCounters,
            lifetimeTransportCounters: lifetimeCounters,
            renderKernelDiagnostics: stereoRenderDiagnostics,
            startupGateOpened: startupGateOpened,
            startupGateTargetFrames: startupGateTargetFrames,
            startupGateActivationFrames: startupGateActivationFrames,
            sampleRateChangesHandled: sampleRateChangesHandled,
            recoveryAttempts: recoveryAttempts,
            recoverySuccesses: recoverySuccesses,
            recoveryFailures: recoveryFailures,
            lastErrorDescription: lastErrorDescription,
            unifiedGraph: UnifiedGraphDiagnostics(
                host: transportSession?.unifiedGraphReadback
                    ?? nChannelTransportSession?.unifiedGraphReadback
                    ?? binauralHeadphoneTransportSession?.unifiedGraphReadback,
                programChannelCount: nChannelTransportSession.map {
                    $0.routePlan.programLayout.roles.count
                } ?? binauralHeadphoneTransportSession.map {
                    $0.programLayout.roles.count
                } ?? 2,
                fallbackReason: transportSession?.unifiedGraphFallbackReason,
                stereoFinalReading: stereoFinalReading,
                stereoDynamicsReading: stereoDynamicsReading
            )
        )
    }
}
