from pathlib import Path


def replace_exact(path: str, old: str, new: str, expected: int = 1) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{path}: expected {expected} occurrence(s), found {count}: {old[:80]!r}")
    file.write_text(text.replace(old, new))


# User-visible mains-hum tracking follows its own control instead of running
# unconditionally in every graph.
replace_exact(
    "NotchSixty/Audio/DynamicsConfiguration.swift",
    """        guard N60DynamicsSnapshotSetMainsHumDetector(\n            &snapshot,\n            sampleRate,\n            true,\n            mainsNotch.region.fundamentalHz\n        ) else { throw DynamicsConfigurationError.invalidMainsHumDetector }""",
    """        guard N60DynamicsSnapshotSetMainsHumDetector(\n            &snapshot,\n            sampleRate,\n            mainsNotch.continuousTracking,\n            mainsNotch.region.fundamentalHz\n        ) else { throw DynamicsConfigurationError.invalidMainsHumDetector }""",
)

# Dynamic EQ keeps configuration while computationally parked when its master
# enable is off. An active -> off change still receives the existing smoothing tail.
replace_exact(
    "NotchSixty/Audio/Realtime/N60DynamicEQ.h",
    """    N60DynamicEQDomain currentDomain;\n    bool domainInitialized;\n} N60DynamicEQRuntime;""",
    """    N60DynamicEQDomain currentDomain;\n    bool domainInitialized;\n    bool parked;\n} N60DynamicEQRuntime;""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60DynamicEQ.c",
    "#define N60_DYNAMIC_EQ_TRANSITION_MS 5.0f",
    "#define N60_DYNAMIC_EQ_TRANSITION_MS 5.0f\n#define N60_DYNAMIC_EQ_PARK_EPSILON 1.0e-5f",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60DynamicEQ.c",
    """    memset(runtime, 0, sizeof(*runtime));\n    for (uint32_t index = 0; index < N60_DYNAMIC_EQ_MAX_BANDS; ++index) {""",
    """    memset(runtime, 0, sizeof(*runtime));\n    runtime->parked = true;\n    for (uint32_t index = 0; index < N60_DYNAMIC_EQ_MAX_BANDS; ++index) {""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60DynamicEQ.c",
    """static void process_linked_stereo(\n    N60DynamicEQRuntime *runtime,""",
    """static bool runtime_can_park(\n    const N60DynamicEQRuntime *runtime,\n    const N60DynamicEQSnapshot *snapshot\n) {\n    for (uint32_t index = 0; index < snapshot->bandCount; ++index) {\n        if (fabsf(runtime->dynamicGainDB[index]) > N60_DYNAMIC_EQ_PARK_EPSILON\n            || fabsf(runtime->staticGainDB[index]) > N60_DYNAMIC_EQ_PARK_EPSILON\n            || fabsf(runtime->wetMix[index]) > N60_DYNAMIC_EQ_PARK_EPSILON) return false;\n    }\n    for (uint32_t index = 0; index < snapshot->secondaryBandCount; ++index) {\n        if (fabsf(runtime->secondaryDynamicGainDB[index]) > N60_DYNAMIC_EQ_PARK_EPSILON\n            || fabsf(runtime->secondaryStaticGainDB[index]) > N60_DYNAMIC_EQ_PARK_EPSILON\n            || fabsf(runtime->secondaryWetMix[index]) > N60_DYNAMIC_EQ_PARK_EPSILON) return false;\n    }\n    return true;\n}\n\nstatic void process_linked_stereo(\n    N60DynamicEQRuntime *runtime,""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60DynamicEQ.c",
    """    if (runtime == NULL || left == NULL || right == NULL) return;\n    if (!runtime->domainInitialized || runtime->currentDomain != snapshot->domain) {\n        N60DynamicEQRuntimeReset(runtime);\n        runtime->currentDomain = snapshot->domain;\n        runtime->domainInitialized = true;\n    }\n    runtime->activeBandCount = 0;\n    runtime->maxAbsDynamicGainDB = 0.0f;""",
    """    if (runtime == NULL || snapshot == NULL || left == NULL || right == NULL) return;\n    if (!runtime->domainInitialized || runtime->currentDomain != snapshot->domain) {\n        N60DynamicEQRuntimeReset(runtime);\n        runtime->currentDomain = snapshot->domain;\n        runtime->domainInitialized = true;\n    }\n    runtime->activeBandCount = 0;\n    runtime->maxAbsDynamicGainDB = 0.0f;\n    if (!snapshot->enabled && runtime->parked) return;\n    if (snapshot->enabled) runtime->parked = false;""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60DynamicEQ.c",
    """    case N60DynamicEQDomainLinkedStereo:\n    default:\n        process_linked_stereo(runtime, snapshot, left, right);\n        break;\n    }\n}""",
    """    case N60DynamicEQDomainLinkedStereo:\n    default:\n        process_linked_stereo(runtime, snapshot, left, right);\n        break;\n    }\n\n    if (!snapshot->enabled && runtime_can_park(runtime, snapshot)) {\n        N60DynamicEQDomain domain = snapshot->domain;\n        N60DynamicEQRuntimeReset(runtime);\n        runtime->currentDomain = domain;\n        runtime->domainInitialized = true;\n        runtime->parked = true;\n    }\n}""",
)

# A fully neutral protection configuration is no longer used as an implicit
# true-peak analyzer. Explicit 2x/4x oversampling still runs because that setting
# itself means processing was requested.
replace_exact(
    "NotchSixty/Audio/Realtime/N60Protection.c",
    """    if (runtime == NULL || snapshot == NULL || left == NULL || right == NULL) return;\n\n    update_gain_rider(runtime, snapshot);""",
    """    if (runtime == NULL || snapshot == NULL || left == NULL || right == NULL) return;\n\n    if (snapshot->effectiveFactor == N60OversamplingFactor1x\n        && !snapshot->softClipperEnabled\n        && !snapshot->limiterEnabled) {\n        runtime->gainRiderAttenuationDB = 0.0f;\n        runtime->sustainedLimiterGainReductionDB = 0.0f;\n        runtime->telemetry.gainRiderAttenuationDB = 0.0f;\n        runtime->telemetry.sustainedLimiterGainReductionDB = 0.0f;\n        runtime->telemetry.truePeakGuardActive = false;\n        return;\n    }\n\n    update_gain_rider(runtime, snapshot);""",
)

# Snapshot-level meter gate. It is OFF in the unity/default graph and can be
# explicitly enabled later by the production meter UI.
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.h",
    """    N60CrosstalkCancellationSnapshot crosstalkCancellation;\n    bool bypassed;""",
    """    N60CrosstalkCancellationSnapshot crosstalkCancellation;\n    bool meteringEnabled;\n    bool bypassed;""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.h",
    """    uint32_t channelCount;\n    bool bypassed;""",
    """    uint32_t channelCount;\n    bool meteringEnabled;\n    bool bypassed;""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.h",
    """N60DSPGraphSnapshot N60DSPGraphSnapshotMakeUnity(double sampleRate);\nvoid N60DSPGraphSnapshotClearEQ""",
    """N60DSPGraphSnapshot N60DSPGraphSnapshotMakeUnity(double sampleRate);\nbool N60DSPGraphSnapshotSetMeteringEnabled(\n    N60DSPGraphSnapshot * _Nonnull snapshot,\n    bool enabled\n);\nvoid N60DSPGraphSnapshotClearEQ""",
)

replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """static void promote_pending_filter(N60EQBandRuntime *runtime) {""",
    """static bool smoothed_gain_is_settled_at(const N60SmoothedGain *gain, float value) {\n    return gain->transitionFramesRemaining == 0\n        && gain->current == value\n        && gain->target == value;\n}\n\nstatic void promote_pending_filter(N60EQBandRuntime *runtime) {""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """        reset_smoothed_gain(&kernel->crosstalkCancellationAmount, snapshot->crosstalkCancellation.enabled ? snapshot->crosstalkCancellation.amount : 0.0f);\n        reset_smoothed_gain(&kernel->crosstalkHeadShadowAlpha, snapshot->crosstalkCancellation.headShadowAlpha);""",
    """        reset_smoothed_gain(&kernel->crosstalkCancellationAmount, snapshot->crosstalkCancellation.enabled ? snapshot->crosstalkCancellation.amount : 0.0f);\n        reset_smoothed_gain(&kernel->crosstalkHeadShadowAlpha, snapshot->crosstalkCancellation.enabled ? snapshot->crosstalkCancellation.headShadowAlpha : 0.0f);""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """        schedule_gain_transition(&kernel->crosstalkCancellationAmount, snapshot->crosstalkCancellation.enabled ? snapshot->crosstalkCancellation.amount : 0.0f, gainFrames);\n        schedule_gain_transition(&kernel->crosstalkHeadShadowAlpha, snapshot->crosstalkCancellation.headShadowAlpha, gainFrames);""",
    """        schedule_gain_transition(&kernel->crosstalkCancellationAmount, snapshot->crosstalkCancellation.enabled ? snapshot->crosstalkCancellation.amount : 0.0f, gainFrames);\n        schedule_gain_transition(&kernel->crosstalkHeadShadowAlpha, snapshot->crosstalkCancellation.enabled ? snapshot->crosstalkCancellation.headShadowAlpha : 0.0f, gainFrames);""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """    snapshot.bypassed = false;\n    snapshot.auditionMode = N60AuditionModeProcessed;""",
    """    snapshot.meteringEnabled = false;\n    snapshot.bypassed = false;\n    snapshot.auditionMode = N60AuditionModeProcessed;""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """void N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot *snapshot) {""",
    """bool N60DSPGraphSnapshotSetMeteringEnabled(\n    N60DSPGraphSnapshot *snapshot,\n    bool enabled\n) {\n    if (snapshot == NULL) return false;\n    snapshot->meteringEnabled = enabled;\n    return true;\n}\n\nvoid N60DSPGraphSnapshotClearEQ(N60DSPGraphSnapshot *snapshot) {""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """    uint32_t referenceDelayFrames = context->acquired && context->snapshot != NULL ? context->snapshot->latencyFrames : 0;\n    process_reference_delay(kernel, referenceDelayFrames, left, right, &referenceLeft, &referenceRight);\n    meter_sample(left, right, &context->inputPeakLeft, &context->inputPeakRight, &context->inputSquareSumLeft, &context->inputSquareSumRight, &context->inputOverRangeSamples);""",
    """    uint32_t referenceDelayFrames = context->acquired && context->snapshot != NULL ? context->snapshot->latencyFrames : 0;\n    process_reference_delay(kernel, referenceDelayFrames, left, right, &referenceLeft, &referenceRight);\n    bool meteringEnabled = context->acquired && context->snapshot != NULL && context->snapshot->meteringEnabled;\n    if (meteringEnabled) {\n        meter_sample(left, right, &context->inputPeakLeft, &context->inputPeakRight, &context->inputSquareSumLeft, &context->inputSquareSumRight, &context->inputOverRangeSamples);\n    }""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """        meter_sample(left, right, &context->postEQPeakLeft, &context->postEQPeakRight, &context->postEQSquareSumLeft, &context->postEQSquareSumRight, &context->postEQOverRangeSamples);""",
    """        if (meteringEnabled) {\n            meter_sample(left, right, &context->postEQPeakLeft, &context->postEQPeakRight, &context->postEQSquareSumLeft, &context->postEQSquareSumRight, &context->postEQOverRangeSamples);\n        }""",
    expected=2,
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """        left *= next_gain_value(&kernel->symmetryBalanceGainLeft);\n        right *= next_gain_value(&kernel->symmetryBalanceGainRight);""",
    """        if (!smoothed_gain_is_settled_at(&kernel->symmetryBalanceGainLeft, 1.0f)\n            || !smoothed_gain_is_settled_at(&kernel->symmetryBalanceGainRight, 1.0f)) {\n            left *= next_gain_value(&kernel->symmetryBalanceGainLeft);\n            right *= next_gain_value(&kernel->symmetryBalanceGainRight);\n        }""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """        // Speaker crossfeed / Panning Gain Matrix. The audited effective range\n        // is 0...0.5: zero is identity and 0.5 is exact mono.\n        const float crossfeed = next_gain_value(&kernel->speakerCrossfeedAmount);\n        const float direct = 1.0f - crossfeed;\n        const float spatialLeft = left;\n        const float spatialRight = right;\n        left = direct * spatialLeft + crossfeed * spatialRight;\n        right = direct * spatialRight + crossfeed * spatialLeft;""",
    """        // Speaker crossfeed / Panning Gain Matrix. Once its disable ramp has\n        // reached zero the processor is computationally parked.\n        if (!smoothed_gain_is_settled_at(&kernel->speakerCrossfeedAmount, 0.0f)) {\n            const float crossfeed = next_gain_value(&kernel->speakerCrossfeedAmount);\n            const float direct = 1.0f - crossfeed;\n            const float spatialLeft = left;\n            const float spatialRight = right;\n            left = direct * spatialLeft + crossfeed * spatialRight;\n            right = direct * spatialRight + crossfeed * spatialLeft;\n        }""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """        // Gentle feed-forward speaker crosstalk cancellation. The opposite-channel\n        // cancellation signal is frequency-shaped by a first-order far-ear/head-\n        // shadow model; there is no recursive feedback loop in the realtime path.\n        const float shadowAlpha = next_gain_value(&kernel->crosstalkHeadShadowAlpha);\n        kernel->crosstalkShadowLeft += shadowAlpha * (left - kernel->crosstalkShadowLeft);\n        kernel->crosstalkShadowRight += shadowAlpha * (right - kernel->crosstalkShadowRight);\n        const float cancellationAmount = next_gain_value(&kernel->crosstalkCancellationAmount);\n        const float cancellationLeft = left;\n        const float cancellationRight = right;\n        left = cancellationLeft - cancellationAmount * kernel->crosstalkShadowRight;\n        right = cancellationRight - cancellationAmount * kernel->crosstalkShadowLeft;""",
    """        // Gentle feed-forward speaker crosstalk cancellation. The shadow filter\n        // and cancellation matrix park completely after the disable ramp reaches 0.\n        if (!smoothed_gain_is_settled_at(&kernel->crosstalkCancellationAmount, 0.0f)\n            || !smoothed_gain_is_settled_at(&kernel->crosstalkHeadShadowAlpha, 0.0f)) {\n            const float shadowAlpha = next_gain_value(&kernel->crosstalkHeadShadowAlpha);\n            kernel->crosstalkShadowLeft += shadowAlpha * (left - kernel->crosstalkShadowLeft);\n            kernel->crosstalkShadowRight += shadowAlpha * (right - kernel->crosstalkShadowRight);\n            const float cancellationAmount = next_gain_value(&kernel->crosstalkCancellationAmount);\n            const float cancellationLeft = left;\n            const float cancellationRight = right;\n            left = cancellationLeft - cancellationAmount * kernel->crosstalkShadowRight;\n            right = cancellationRight - cancellationAmount * kernel->crosstalkShadowLeft;\n            if (smoothed_gain_is_settled_at(&kernel->crosstalkCancellationAmount, 0.0f)\n                && smoothed_gain_is_settled_at(&kernel->crosstalkHeadShadowAlpha, 0.0f)) {\n                kernel->crosstalkShadowLeft = 0.0f;\n                kernel->crosstalkShadowRight = 0.0f;\n            }\n        }""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """    meter_sample(left, right, &context->outputPeakLeft, &context->outputPeakRight, &context->outputSquareSumLeft, &context->outputSquareSumRight, &context->outputOverRangeSamples);\n    context->meteredFrames += 1;""",
    """    if (meteringEnabled) {\n        meter_sample(left, right, &context->outputPeakLeft, &context->outputPeakRight, &context->outputSquareSumLeft, &context->outputSquareSumRight, &context->outputOverRangeSamples);\n        context->meteredFrames += 1;\n    }""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """    publish_meter(&kernel->inputPeakLeftBits, &kernel->inputPeakRightBits, &kernel->inputRMSLeftBits, &kernel->inputRMSRightBits, &kernel->inputOverRangeSamples, context->inputPeakLeft, context->inputPeakRight, context->inputSquareSumLeft, context->inputSquareSumRight, context->inputOverRangeSamples, context->meteredFrames);\n    publish_meter(&kernel->postEQPeakLeftBits, &kernel->postEQPeakRightBits, &kernel->postEQRMSLeftBits, &kernel->postEQRMSRightBits, &kernel->postEQOverRangeSamples, context->postEQPeakLeft, context->postEQPeakRight, context->postEQSquareSumLeft, context->postEQSquareSumRight, context->postEQOverRangeSamples, context->meteredFrames);\n    publish_meter(&kernel->outputPeakLeftBits, &kernel->outputPeakRightBits, &kernel->outputRMSLeftBits, &kernel->outputRMSRightBits, &kernel->outputOverRangeSamples, context->outputPeakLeft, context->outputPeakRight, context->outputSquareSumLeft, context->outputSquareSumRight, context->outputOverRangeSamples, context->meteredFrames);""",
    """    if (context->acquired && context->snapshot != NULL && context->snapshot->meteringEnabled) {\n        publish_meter(&kernel->inputPeakLeftBits, &kernel->inputPeakRightBits, &kernel->inputRMSLeftBits, &kernel->inputRMSRightBits, &kernel->inputOverRangeSamples, context->inputPeakLeft, context->inputPeakRight, context->inputSquareSumLeft, context->inputSquareSumRight, context->inputOverRangeSamples, context->meteredFrames);\n        publish_meter(&kernel->postEQPeakLeftBits, &kernel->postEQPeakRightBits, &kernel->postEQRMSLeftBits, &kernel->postEQRMSRightBits, &kernel->postEQOverRangeSamples, context->postEQPeakLeft, context->postEQPeakRight, context->postEQSquareSumLeft, context->postEQSquareSumRight, context->postEQOverRangeSamples, context->meteredFrames);\n        publish_meter(&kernel->outputPeakLeftBits, &kernel->outputPeakRightBits, &kernel->outputRMSLeftBits, &kernel->outputRMSRightBits, &kernel->outputOverRangeSamples, context->outputPeakLeft, context->outputPeakRight, context->outputSquareSumLeft, context->outputSquareSumRight, context->outputOverRangeSamples, context->meteredFrames);\n    }""",
)
replace_exact(
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    """        diagnostics.channelCount = context.snapshot->channelCount;\n        diagnostics.bypassed = context.snapshot->bypassed;""",
    """        diagnostics.channelCount = context.snapshot->channelCount;\n        diagnostics.meteringEnabled = context.snapshot->meteringEnabled;\n        diagnostics.bypassed = context.snapshot->bypassed;""",
)

print("PR35 disabled-stage contract patch applied")
