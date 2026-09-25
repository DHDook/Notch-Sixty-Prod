from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    text = p.read_text()
    if text.count(old) < count:
        raise SystemExit(f"missing pattern in {path}: {old[:120]!r}")
    p.write_text(text.replace(old, new, count))

# Split core gain-computer processing from the late Pause Gate stage so future
# limiter/clipper ordering has a clean insertion seam.
h = 'NotchSixty/Audio/Realtime/N60Dynamics.h'
replace(h,
'''void N60DynamicsProcessStereoFrame(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float * _Nonnull left,
    float * _Nonnull right
);
''',
'''void N60DynamicsProcessCoreStereoFrame(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float * _Nonnull left,
    float * _Nonnull right
);
void N60DynamicsProcessPauseGateStereoFrame(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float * _Nonnull left,
    float * _Nonnull right
);
void N60DynamicsProcessStereoFrame(
    N60DynamicsRuntime * _Nonnull runtime,
    N60DynamicsSnapshot snapshot,
    float * _Nonnull left,
    float * _Nonnull right
);
''')

c = 'NotchSixty/Audio/Realtime/N60Dynamics.c'
# The visible Hold control should dominate gate-close timing; detector smoothing
# is deliberately much shorter than the minimum product hold of 100 ms.
replace(c, 'snapshot.pauseGate.detectorReleaseCoefficient = coefficient_for_time_ms(sampleRate, 50.0f);',
           'snapshot.pauseGate.detectorReleaseCoefficient = coefficient_for_time_ms(sampleRate, 10.0f);')
replace(c, 'configured.detectorReleaseCoefficient = coefficient_for_time_ms(sampleRate, 50.0f);',
           'configured.detectorReleaseCoefficient = coefficient_for_time_ms(sampleRate, 10.0f);')

p = Path(c)
t = p.read_text()
start = t.find('void N60DynamicsProcessStereoFrame(\n')
end = t.find('N60DynamicsTelemetry N60DynamicsRuntimeTelemetry', start)
if start < 0 or end < 0:
    raise SystemExit('dynamics process function boundaries missing')
replacement = r'''void N60DynamicsProcessCoreStereoFrame(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;

    float detector = fmaxf(fabsf(*left), fabsf(*right));
    float detectorDB = linear_to_db(detector);

    float compressorTargetDB = compressor_target_gain_db(detectorDB, snapshot.compressor);
    float compressorCoefficient;
    if (!snapshot.compressor.enabled) {
        compressorCoefficient = snapshot.bypassTransitionCoefficient;
    } else {
        compressorCoefficient = compressorTargetDB < runtime->compressorGainDB
            ? snapshot.compressor.attackCoefficient
            : snapshot.compressor.releaseCoefficient;
    }
    runtime->compressorGainDB = smooth_toward(
        runtime->compressorGainDB,
        compressorTargetDB,
        compressorCoefficient
    );
    float compressorGain = db_to_linear(runtime->compressorGainDB);
    *left *= compressorGain;
    *right *= compressorGain;

    detector = fmaxf(fabsf(*left), fabsf(*right));
    detectorDB = linear_to_db(detector);
    float expanderTargetDB = expander_target_gain_db(detectorDB, snapshot.expander);
    float expanderCoefficient;
    if (!snapshot.expander.enabled) {
        expanderCoefficient = snapshot.bypassTransitionCoefficient;
    } else {
        expanderCoefficient = expanderTargetDB < runtime->expanderGainDB
            ? snapshot.expander.attackCoefficient
            : snapshot.expander.releaseCoefficient;
    }
    runtime->expanderGainDB = smooth_toward(
        runtime->expanderGainDB,
        expanderTargetDB,
        expanderCoefficient
    );
    float expanderGain = db_to_linear(runtime->expanderGainDB);
    *left *= expanderGain;
    *right *= expanderGain;
}

void N60DynamicsProcessPauseGateStereoFrame(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    if (runtime == NULL || left == NULL || right == NULL) return;

    float gateDetectorInput = fmaxf(fabsf(*left), fabsf(*right));
    float detectorCoefficient = gateDetectorInput > runtime->gateDetectorEnvelope
        ? snapshot.pauseGate.detectorAttackCoefficient
        : snapshot.pauseGate.detectorReleaseCoefficient;
    runtime->gateDetectorEnvelope = smooth_toward(
        runtime->gateDetectorEnvelope,
        gateDetectorInput,
        detectorCoefficient
    );

    float gateTarget = 1.0f;
    float gateCoefficient = snapshot.bypassTransitionCoefficient;
    if (snapshot.pauseGate.enabled) {
        float gateLevelDB = linear_to_db(runtime->gateDetectorEnvelope);
        float openThresholdDB = snapshot.pauseGate.thresholdDBFS + snapshot.pauseGate.hysteresisDB;
        if (!runtime->gateOpen) {
            if (gateLevelDB >= openThresholdDB) {
                runtime->gateOpen = true;
                runtime->gateBelowThresholdFrames = 0;
            }
        } else if (gateLevelDB <= snapshot.pauseGate.thresholdDBFS) {
            if (runtime->gateBelowThresholdFrames < snapshot.pauseGate.holdFrames) {
                runtime->gateBelowThresholdFrames += 1;
            }
            if (runtime->gateBelowThresholdFrames >= snapshot.pauseGate.holdFrames) {
                runtime->gateOpen = false;
            }
        } else {
            runtime->gateBelowThresholdFrames = 0;
        }

        gateTarget = runtime->gateOpen ? 1.0f : 0.0f;
        // Product contract: Attack closes/fades out; Release opens/fades in.
        gateCoefficient = gateTarget < runtime->pauseGateGain
            ? snapshot.pauseGate.fadeOutCoefficient
            : snapshot.pauseGate.fadeInCoefficient;
    } else {
        runtime->gateOpen = true;
        runtime->gateBelowThresholdFrames = 0;
    }

    runtime->pauseGateGain = smooth_toward(runtime->pauseGateGain, gateTarget, gateCoefficient);
    *left *= runtime->pauseGateGain;
    *right *= runtime->pauseGateGain;
}

void N60DynamicsProcessStereoFrame(
    N60DynamicsRuntime *runtime,
    N60DynamicsSnapshot snapshot,
    float *left,
    float *right
) {
    N60DynamicsProcessCoreStereoFrame(runtime, snapshot, left, right);
    N60DynamicsProcessPauseGateStereoFrame(runtime, snapshot, left, right);
}

'''
p.write_text(t[:start] + replacement + t[end:])

# Kernel: core dynamics live before balance/output gain; Pause Gate is a late
# processed-path stage immediately after output gain and before audition mode.
k = 'NotchSixty/Audio/Realtime/N60RenderKernel.c'
replace(k,
'''        N60DynamicsProcessStereoFrame(&kernel->dynamicsRuntime, context->snapshot.dynamics, &left, &right);

        left *= next_gain_value(&kernel->balanceGainLeft);
''',
'''        N60DynamicsProcessCoreStereoFrame(&kernel->dynamicsRuntime, context->snapshot.dynamics, &left, &right);

        left *= next_gain_value(&kernel->balanceGainLeft);
''')
replace(k,
'''        float outputGain = next_gain_value(&kernel->outputGain);
        left *= outputGain;
        right *= outputGain;

        switch (context->snapshot.auditionMode) {
''',
'''        float outputGain = next_gain_value(&kernel->outputGain);
        left *= outputGain;
        right *= outputGain;

        N60DynamicsProcessPauseGateStereoFrame(
            &kernel->dynamicsRuntime,
            context->snapshot.dynamics,
            &left,
            &right
        );

        switch (context->snapshot.auditionMode) {
''')

# Product state schema now includes dynamics; update the prior schema assertion.
test = 'NotchSixtyTests/LiveLinearPhaseTests.swift'
replace(test,
'''    func testProductConfigurationSchemaIsVersionThreeForMasterPlaybackState() {
        XCTAssertEqual(ProductConfiguration.currentSchemaVersion, 3)
        XCTAssertEqual(ProductConfiguration().schemaVersion, 3)
    }
''',
'''    func testProductConfigurationSchemaIsVersionFourForDynamicsState() {
        XCTAssertEqual(ProductConfiguration.currentSchemaVersion, 4)
        XCTAssertEqual(ProductConfiguration().schemaVersion, 4)
    }
''')

# Ensure the product snapshot test explicitly sees the new dynamics domain.
replace(test,
'''        XCTAssertEqual(product.configuration.dsp.gain.outputGainDB, -3.0)
''',
'''        XCTAssertEqual(product.configuration.dsp.gain.outputGainDB, -3.0)
        XCTAssertEqual(product.configuration.dsp.dynamics, engine.dynamicsConfiguration)
''')
