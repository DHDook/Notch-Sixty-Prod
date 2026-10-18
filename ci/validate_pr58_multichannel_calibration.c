
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "N60MultichannelMeasurementCampaign.h"
#include "N60TargetedRoomMeasurementBridge.h"
#include "N60SpeakerCorrectionDesigner.h"
#include "N60MultiSubOptimizer.h"

static void closef(float actual, float expected, float tolerance) {
    assert(fabsf(actual - expected) <= tolerance);
}

static void set_flat_response(
    N60MultichannelCalibrationMatrix *matrix,
    uint32_t source,
    uint32_t seat,
    uint32_t arrival,
    int8_t polarity,
    float level,
    float magnitudeOffset
) {
    float magnitude[N60_CALIBRATION_MAX_FREQUENCY_BINS] = {0};
    float phase[N60_CALIBRATION_MAX_FREQUENCY_BINS] = {0};
    for (uint32_t f = 0; f < matrix->frequencyCount; ++f) magnitude[f] = magnitudeOffset;
    assert(N60MultichannelCalibrationSetResponse(
        matrix, source, seat, arrival, polarity, level, magnitude, phase));
}

int main(void) {
    // Targeted one-source bridge: exact timeline, exact selected output identity, exact capture.
    const float sweep[3] = {0.1f, 0.2f, 0.3f};
    const float mic[7] = {1, 2, 3, 4, 5, 6, 7};
    float output[7] = {9, 9, 9, 9, 9, 9, 9};
    N60TargetedRoomMeasurementBridge *targeted =
        N60TargetedRoomMeasurementBridgeCreate(sweep, 3u, 2u, 2u, 1u, 7u);
    assert(targeted != NULL);
    assert(N60TargetedRoomMeasurementBridgeProcessPlanar(targeted, mic, output, 4u) == 4u);
    assert(N60TargetedRoomMeasurementBridgeProcessPlanar(targeted, mic + 4u, output + 4u, 3u) == 3u);
    closef(output[0], 0.0f, 1.0e-7f);
    closef(output[1], 0.0f, 1.0e-7f);
    closef(output[2], 0.1f, 1.0e-7f);
    closef(output[3], 0.2f, 1.0e-7f);
    closef(output[4], 0.3f, 1.0e-7f);
    closef(output[5], 0.0f, 1.0e-7f);
    closef(output[6], 0.0f, 1.0e-7f);
    N60TargetedRoomMeasurementBridgeSnapshot targetedSnapshot =
        N60TargetedRoomMeasurementBridgeGetSnapshot(targeted);
    assert(targetedSnapshot.complete);
    assert(targetedSnapshot.outputChannelIndex == 7u);
    assert(targetedSnapshot.capturedFrames == 7u);
    float capture[7] = {0};
    assert(N60TargetedRoomMeasurementBridgeCopyCapture(targeted, capture, 7u) == 7u);
    for (uint32_t i = 0; i < 7u; ++i) closef(capture[i], mic[i], 1.0e-7f);
    N60TargetedRoomMeasurementBridgeDestroy(targeted);

    // Campaign order is speaker/sub source × included seat with explicit physical mapping.
    const float lowFrequencies[4] = {40.0f, 60.0f, 80.0f, 100.0f};
    N60ProgramChannelLayout fiveOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    N60MultichannelCalibrationMatrix campaignMatrix = N60MultichannelCalibrationMatrixMake(
        48000.0, fiveOne, 2u, 2u, lowFrequencies, 4u);
    assert(campaignMatrix.sourceCount == 7u); // Five speakers; native LFE excluded; two physical subs.
    assert(N60MultichannelCalibrationSetSeat(&campaignMatrix, 1u, false, 0.0f));
    const uint32_t physicalMap[7] = {0u, 1u, 2u, 4u, 5u, 6u, 7u};
    N60MultichannelMeasurementCampaign campaign = {0};
    assert(N60MultichannelMeasurementCampaignMake(&campaignMatrix, physicalMap, &campaign));
    assert(campaign.totalMeasurementCount == 7u);
    assert(N60MultichannelMeasurementCampaignStart(&campaign));
    N60MeasurementTarget first = N60MultichannelMeasurementCampaignCurrentTarget(&campaign);
    assert(first.valid && first.seatIndex == 0u && first.physicalOutputChannelIndex == 0u);
    assert(first.source.role == N60ProgramChannelRoleFrontLeft);
    for (uint32_t measurement = 0; measurement < 7u; ++measurement) {
        N60MeasurementTarget current = N60MultichannelMeasurementCampaignCurrentTarget(&campaign);
        assert(current.valid);
        assert(current.seatIndex == 0u);
        assert(N60MultichannelMeasurementCampaignCompleteCurrentTarget(&campaign));
    }
    assert(campaign.complete);
    closef(N60MultichannelMeasurementCampaignProgress(&campaign), 1.0f, 1.0e-7f);
    uint32_t duplicateMap[7] = {0u, 1u, 2u, 4u, 5u, 6u, 6u};
    assert(!N60MultichannelMeasurementCampaignMake(&campaignMatrix, duplicateMap, &campaign));

    // Speaker×seat alignment and deployable PEQ fitting.
    const float speakerFrequencies[8] = {
        125.0f, 250.0f, 500.0f, 1000.0f, 2000.0f, 4000.0f, 8000.0f, 12000.0f
    };
    N60MultichannelCalibrationMatrix speakers = N60MultichannelCalibrationMatrixMake(
        48000.0, fiveOne, 0u, 2u, speakerFrequencies, 8u);
    assert(speakers.sourceCount == 5u);
    assert(N60MultichannelCalibrationSetSeat(&speakers, 0u, true, 2.0f));
    assert(N60MultichannelCalibrationSetSeat(&speakers, 1u, true, 1.0f));

    const float frontLeftSeat0[8] = {0.0f, 0.0f, 1.0f, 6.0f, 2.0f, -2.0f, -5.0f, -1.0f};
    const float frontLeftSeat1[8] = {0.0f, 0.0f, 0.5f, 5.0f, 1.5f, -1.0f, -4.0f, -1.0f};
    float zeroPhase[8] = {0};
    for (uint32_t source = 0; source < speakers.sourceCount; ++source) {
        const uint32_t arrival0 = 100u + source * 5u;
        const uint32_t arrival1 = arrival0 + 2u;
        const int8_t polarity = source == 2u ? -1 : 1;
        const float level = -2.0f - (float)source;
        if (source == 0u) {
            assert(N60MultichannelCalibrationSetResponse(
                &speakers, source, 0u, arrival0, polarity, level,
                frontLeftSeat0, zeroPhase));
            assert(N60MultichannelCalibrationSetResponse(
                &speakers, source, 1u, arrival1, polarity, level - 0.5f,
                frontLeftSeat1, zeroPhase));
        } else {
            set_flat_response(&speakers, source, 0u, arrival0, polarity, level, 0.0f);
            set_flat_response(&speakers, source, 1u, arrival1, polarity, level - 0.5f, 0.0f);
        }
    }
    assert(N60MultichannelCalibrationMatrixIsValid(&speakers, 0u));

    N60SpeakerAlignmentPlan alignment = {0};
    assert(N60MultichannelCalibrationMakeSpeakerAlignmentPlan(&speakers, &alignment));
    assert(alignment.referenceArrivalFrame >= 121u);
    for (uint32_t source = 0; source < speakers.sourceCount; ++source) {
        assert(alignment.sources[source].valid);
        assert(alignment.sources[source].trimDB <= 1.0e-6f);
    }
    assert(alignment.sources[2].polarityInverted);

    float speakerTarget[8] = {0};
    N60SpeakerCorrectionSettings correctionSettings = N60SpeakerCorrectionSettingsMakeDefault();
    correctionSettings.maximumCorrectionHz = 16000.0f;
    N60SpeakerCorrectionPlan correctionPlan = {0};
    assert(N60SpeakerCorrectionDesignPlan(
        &speakers, speakerTarget, correctionSettings, &correctionPlan));
    assert(correctionPlan.sourceCount == 5u);
    const N60SpeakerCorrectionSourceDesign *frontLeft = &correctionPlan.sources[0];
    assert(frontLeft->role == N60ProgramChannelRoleFrontLeft);
    assert(frontLeft->bandCount > 0u);
    assert(frontLeft->postCorrectionRMSErrorDB < frontLeft->preCorrectionRMSErrorDB);
    for (uint32_t band = 0; band < frontLeft->bandCount; ++band) {
        assert(frontLeft->bands[band].gainDB <= correctionSettings.maximumBoostDB + 1.0e-6f);
        assert(frontLeft->bands[band].gainDB >= -correctionSettings.maximumCutDB - 1.0e-6f);
        assert(N60BiquadCoefficientsAreFinite(frontLeft->bands[band].coefficients));
    }

    // Complex-domain multi-sub optimization must resolve a measured polarity cancellation.
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60MultichannelCalibrationMatrix subs = N60MultichannelCalibrationMatrixMake(
        48000.0, stereo, 2u, 2u, lowFrequencies, 4u);
    assert(subs.sourceCount == 4u);
    for (uint32_t seat = 0; seat < subs.seatCount; ++seat) {
        set_flat_response(&subs, 0u, seat, 0u, 1, 0.0f, 0.0f);
        set_flat_response(&subs, 1u, seat, 0u, 1, 0.0f, 0.0f);

        float subMagnitude[4] = {-6.0206f, -6.0206f, -6.0206f, -6.0206f};
        float sub0Phase[4] = {0, 0, 0, 0};
        float sub1Phase[4] = {
            (float)N60_MULTI_SUB_PI, (float)N60_MULTI_SUB_PI,
            (float)N60_MULTI_SUB_PI, (float)N60_MULTI_SUB_PI
        };
        assert(N60MultichannelCalibrationSetResponse(
            &subs, 2u, seat, 0u, 1, -6.0206f, subMagnitude, sub0Phase));
        assert(N60MultichannelCalibrationSetResponse(
            &subs, 3u, seat, 0u, 1, -6.0206f, subMagnitude, sub1Phase));
    }
    assert(N60MultichannelCalibrationMatrixIsValid(&subs, 2u));

    float subTarget[4] = {0, 0, 0, 0};
    N60MultiSubOptimizationSettings subSettings = N60MultiSubOptimizationSettingsMakeDefault();
    subSettings.maximumAdditionalDelayMs = 0.0f;
    subSettings.minimumGainDB = -3.0f;
    subSettings.maximumGainDB = 0.0f;
    subSettings.coordinatePasses = 1u;
    subSettings.eqPasses = 0u;
    uint32_t subIndices[N60_MAX_SUBWOOFER_OUTPUTS] = {0};
    assert(N60MultiSubFindSourceIndices(&subs, 2u, subIndices));
    N60MultiSubOptimizationResult baseline = {0};
    baseline.subwooferCount = 2u;
    baseline.frequencyCount = subs.frequencyCount;
    const float baselineObjective = N60MultiSubEvaluateObjective(
        &subs, subIndices, 2u, subTarget, &subSettings, &baseline, NULL, NULL);
    assert(isfinite(baselineObjective));

    N60MultiSubOptimizationResult optimized = {0};
    assert(N60MultiSubOptimize(&subs, 2u, subTarget, subSettings, &optimized));
    assert(isfinite(optimized.objective));
    assert(optimized.objective < baselineObjective * 0.25f);
    assert(optimized.polarityInverted[0] != optimized.polarityInverted[1]);
    for (uint32_t sub = 0; sub < 2u; ++sub) {
        assert(optimized.gainDB[sub] >= subSettings.minimumGainDB - 1.0e-6f);
        assert(optimized.gainDB[sub] <= subSettings.maximumGainDB + 1.0e-6f);
    }

    return 0;
}
