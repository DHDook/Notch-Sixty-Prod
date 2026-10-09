import SwiftUI

/// PR96 uses the familiar Quiet Zone workspace but deliberately does not
/// expose an Arm switch until the reference-to-speaker path is proven causal.
struct ProductionFeedForwardReadinessCard: View {
    @ObservedObject var quietZone: ActiveQuietZoneController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Virtual-Position Feed-Forward ANC")
                        .font(.headline)
                    Text(
                        "One microphone, two locations: virtual listening-seat error point and upstream doorway reference."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("PR97 · HARDWARE SETUP")
                    .font(.caption.bold())
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    do {
                        try quietZone.prepareFeedForwardPlan()
                    } catch {
                        // Controller publishes the same prerequisites in refresh.
                        quietZone.refreshFeedForwardCalibration()
                    }
                } label: {
                    Label(
                        "Prepare One-Mic Plan",
                        systemImage: "mic"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(
                    quietZone.feedForwardCalibration != nil
                )

                Button {
                    quietZone.refreshFeedForwardCalibration()
                } label: {
                    Label(
                        "Refresh",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                Spacer()
                Text(
                    quietZone.feedForwardCalibration == nil
                        ? "NO CALIBRATION"
                        : "CALIBRATION PLANNED"
                )
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                stage(
                    1,
                    "Listener: establish speaker → virtual-seat path and synchronized controlled-source arrival."
                )
                stage(
                    2,
                    "Doorway: move the same mic upstream; repeat the controlled source with the same trigger/clock reference."
                )
                stage(
                    3,
                    "Listener: return to check source/timebase drift. Independently measure reference acquisition, processing and anti-noise speaker latency."
                )
                stage(
                    4,
                    "Leave mic upstream only after confidence, causality, model accuracy and hardware verification gates pass."
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instrumented calibration stages").font(.caption.bold())
                Text("1. Qualify concurrent input and output HAL clocks")
                Text("2. Repeat at least three wired electrical loopbacks")
                Text("3. Capture listener → upstream doorway → listener return")
                Text("4. Measure physical speaker-to-seat latency before considering ANC")
                Text("The automated hardware capture driver is not connected; no live anti-noise output is permitted.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let calibration = quietZone.feedForwardCalibration {
                HStack {
                    Text("Upstream reference")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(calibration.upstreamLabel)
                }
                .font(.caption)

                HStack {
                    Text("Timed captures")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(
                        "\(calibration.arrivals.count) / 3"
                    )
                    .monospacedDigit()
                }
                .font(.caption)
            }

            if let trace = quietZone.feedForwardCalibration?.halClockTrace {
                if let clock = try? QuietZoneHALClockAnalyzer().analyze(trace) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "HAL clock stability: qualified for loopback bench only",
                            systemImage: "clock"
                        )
                        .font(.caption.bold())
                        Text(
                            String(
                                format:
                                    "Input %.2f Hz · Output %.2f Hz · relative drift %.1f ppm · worst timestamp residual %.3f ms",
                                clock.measuredInputRateHz,
                                clock.measuredOutputRateHz,
                                clock.relativeDriftPPM,
                                1000 * max(
                                    clock.worstInputResidualSeconds,
                                    clock.worstOutputResidualSeconds
                                )
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(
                            "Clock stability is not ADC/DAC latency or proof of live cancellation."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Label(
                        "HAL clock observations failed qualification. Re-capture timing evidence.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if quietZone.feedForwardBudget.acousticPreviewSeconds != nil {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ],
                    spacing: 10
                ) {
                    valueCard(
                        "Measured preview",
                        milliseconds(
                            quietZone.feedForwardBudget.acousticPreviewSeconds
                        ),
                        "Source→listener minus source→upstream; before uncertainty."
                    )
                    valueCard(
                        "Conservative preview",
                        milliseconds(
                            quietZone.feedForwardBudget.conservativePreviewSeconds
                        ),
                        "Lower confidence bound, including repeat drift."
                    )
                    valueCard(
                        "Anti-noise path",
                        milliseconds(
                            quietZone.feedForwardBudget.antiNoisePathSeconds
                        ),
                        "Actual reference ADC + DSP + output-to-seat travel."
                    )
                    valueCard(
                        "Causality reserve",
                        milliseconds(
                            quietZone.feedForwardBudget.conservativeReserveSeconds
                        ),
                        "Conservative preview minus measured path and jitter."
                    )
                }
            }

            if let timing = quietZone.feedForwardCalibration?.timingPath {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Timing path breakdown · diagnostic only")
                        .font(.caption.bold())
                    HStack {
                        Text("Reference ADC / acquisition")
                        Spacer()
                        Text(milliseconds(timing.referenceAcquisitionSeconds))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Reference processing / scheduling")
                        Spacer()
                        Text(milliseconds(timing.referenceProcessingSeconds))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("DAC + speaker-to-seat (combined)")
                        Spacer()
                        Text(milliseconds(timing.commandToSeatSeconds))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Worst-case jitter + 3σ clock allowance")
                        Spacer()
                        Text(milliseconds(
                            timing.totalWorstCaseJitterSeconds
                                + 3 * timing.timingUncertaintySeconds
                        )).monospacedDigit()
                    }
                    Text("Component bounds require separately instrumented hardware evidence. Cable loopback cannot determine acoustic propagation. Positive timing reserve does not establish any frequency-specific attenuation or permit live ANC.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Label(
                readinessTitle,
                systemImage: "waveform.path.ecg.rectangle"
            )
            .font(.callout.bold())
            .foregroundStyle(.secondary)

            Text(quietZone.feedForwardMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "Feed-forward remains unarmed: the PR90 250 ms polling/window analysis is not causal for unpredictable noise. A trigger-synchronized physical calibration, low-latency reference-to-speaker transport and re-measurement at the virtual seat are required. No estimated cancellation dB or broadband frequency range is claimed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
    }

    private var readinessTitle: String {
        switch quietZone.feedForwardBudget.readiness {
        case .missingMeasurements:
            return "Capture required · not eligible"
        case .invalidTimebase:
            return "Clock not trustworthy · not eligible"
        case .unreliableMeasurements:
            return "Measurement confidence insufficient"
        case .nonCausal:
            return "Negative causality reserve · feed-forward cannot work"
        case .limitedMargin:
            return "Marginal positive reserve · control held"
        case .physicallyPlausible:
            return "Timing physically plausible · runtime not yet verified"
        }
    }

    private func stage(
        _ number: Int,
        _ explanation: String
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(
                    Color.accentColor.opacity(0.10),
                    in: Circle()
                )
            Text(explanation)
                .font(.caption)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )
        }
    }

    private func milliseconds(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else {
            return "—"
        }
        return String(
            format: "%+.2f ms",
            seconds * 1000
        )
    }

    private func valueCard(
        _ title: String,
        _ value: String,
        _ detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
            Text(value)
                .font(.title3.monospacedDigit().bold())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}
