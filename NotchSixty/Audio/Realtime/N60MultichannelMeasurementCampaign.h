#ifndef N60MultichannelMeasurementCampaign_h
#define N60MultichannelMeasurementCampaign_h

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "N60MultichannelCalibration.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_CALIBRATION_OUTPUT_CHANNEL_UNMAPPED UINT32_MAX

typedef struct {
    N60CalibrationSourceDescriptor source;
    uint32_t calibrationSourceIndex;
    uint32_t physicalOutputChannelIndex;
} N60MeasurementSourceRoute;

typedef struct {
    uint32_t seatIndex;
    uint32_t sourceRouteIndex;
    uint32_t calibrationSourceIndex;
    uint32_t physicalOutputChannelIndex;
    N60CalibrationSourceDescriptor source;
    bool valid;
} N60MeasurementTarget;

typedef struct {
    uint32_t seatCount;
    uint32_t sourceRouteCount;
    N60MeasurementSourceRoute routes[N60_CALIBRATION_MAX_SOURCES];
    bool seatIncluded[N60_CALIBRATION_MAX_SEATS];
    uint32_t totalMeasurementCount;
    uint32_t completedMeasurementCount;
    uint32_t cursorSeat;
    uint32_t cursorRoute;
    bool started;
    bool complete;
} N60MultichannelMeasurementCampaign;

/// Creates a campaign from the calibration matrix plus an explicit physical-output
/// map. Mapping remains a control-plane responsibility: semantic program roles are
/// never assumed to equal Core Audio channel indices.
static inline bool N60MultichannelMeasurementCampaignMake(
    const N60MultichannelCalibrationMatrix * _Nonnull matrix,
    const uint32_t * _Nonnull physicalOutputChannelsBySource,
    N60MultichannelMeasurementCampaign * _Nonnull campaignOut
) {
    if (matrix == NULL
        || physicalOutputChannelsBySource == NULL
        || campaignOut == NULL
        || matrix->seatCount == 0u
        || matrix->seatCount > N60_CALIBRATION_MAX_SEATS
        || matrix->sourceCount == 0u
        || matrix->sourceCount > N60_CALIBRATION_MAX_SOURCES) {
        return false;
    }

    N60MultichannelMeasurementCampaign campaign = {0};
    campaign.seatCount = matrix->seatCount;
    campaign.sourceRouteCount = matrix->sourceCount;

    uint32_t includedSeatCount = 0u;
    for (uint32_t seat = 0; seat < matrix->seatCount; ++seat) {
        const bool included = matrix->seats[seat].included && matrix->seats[seat].weight > 0.0f;
        campaign.seatIncluded[seat] = included;
        if (included) includedSeatCount += 1u;
    }
    if (includedSeatCount == 0u) return false;

    for (uint32_t source = 0; source < matrix->sourceCount; ++source) {
        const uint32_t outputChannel = physicalOutputChannelsBySource[source];
        if (outputChannel == N60_CALIBRATION_OUTPUT_CHANNEL_UNMAPPED) return false;
        for (uint32_t previous = 0; previous < source; ++previous) {
            if (physicalOutputChannelsBySource[previous] == outputChannel) {
                // A calibration source must own a distinct physical output lane.
                // Shared hardware routes must be expanded/resolved before campaign creation.
                return false;
            }
        }
        campaign.routes[source] = (N60MeasurementSourceRoute){
            .source = matrix->sources[source],
            .calibrationSourceIndex = source,
            .physicalOutputChannelIndex = outputChannel,
        };
    }

    const uint64_t total64 = (uint64_t)includedSeatCount * (uint64_t)matrix->sourceCount;
    if (total64 == 0u || total64 > UINT32_MAX) return false;
    campaign.totalMeasurementCount = (uint32_t)total64;
    *campaignOut = campaign;
    return true;
}

static inline N60MeasurementTarget N60MultichannelMeasurementCampaignCurrentTarget(
    const N60MultichannelMeasurementCampaign * _Nullable campaign
) {
    N60MeasurementTarget target = {0};
    if (campaign == NULL || campaign->complete || campaign->sourceRouteCount == 0u) return target;

    uint32_t seat = campaign->cursorSeat;
    uint32_t route = campaign->cursorRoute;
    while (seat < campaign->seatCount) {
        if (!campaign->seatIncluded[seat]) {
            seat += 1u;
            route = 0u;
            continue;
        }
        if (route < campaign->sourceRouteCount) {
            const N60MeasurementSourceRoute sourceRoute = campaign->routes[route];
            target.seatIndex = seat;
            target.sourceRouteIndex = route;
            target.calibrationSourceIndex = sourceRoute.calibrationSourceIndex;
            target.physicalOutputChannelIndex = sourceRoute.physicalOutputChannelIndex;
            target.source = sourceRoute.source;
            target.valid = true;
            return target;
        }
        seat += 1u;
        route = 0u;
    }
    return target;
}

static inline bool N60MultichannelMeasurementCampaignStart(
    N60MultichannelMeasurementCampaign * _Nonnull campaign
) {
    if (campaign == NULL || campaign->totalMeasurementCount == 0u) return false;
    campaign->completedMeasurementCount = 0u;
    campaign->cursorSeat = 0u;
    campaign->cursorRoute = 0u;
    campaign->started = true;
    campaign->complete = false;
    while (campaign->cursorSeat < campaign->seatCount
        && !campaign->seatIncluded[campaign->cursorSeat]) {
        campaign->cursorSeat += 1u;
    }
    if (campaign->cursorSeat >= campaign->seatCount) return false;
    return N60MultichannelMeasurementCampaignCurrentTarget(campaign).valid;
}

/// Advances only after the caller has fully materialized/analyzed the current
/// source/seat measurement. This keeps asynchronous analysis ownership explicit.
static inline bool N60MultichannelMeasurementCampaignCompleteCurrentTarget(
    N60MultichannelMeasurementCampaign * _Nonnull campaign
) {
    if (campaign == NULL || !campaign->started || campaign->complete) return false;
    const N60MeasurementTarget current = N60MultichannelMeasurementCampaignCurrentTarget(campaign);
    if (!current.valid) return false;

    campaign->completedMeasurementCount += 1u;
    campaign->cursorRoute += 1u;
    if (campaign->cursorRoute >= campaign->sourceRouteCount) {
        campaign->cursorRoute = 0u;
        campaign->cursorSeat += 1u;
        while (campaign->cursorSeat < campaign->seatCount
            && !campaign->seatIncluded[campaign->cursorSeat]) {
            campaign->cursorSeat += 1u;
        }
    }
    if (campaign->completedMeasurementCount >= campaign->totalMeasurementCount
        || campaign->cursorSeat >= campaign->seatCount) {
        campaign->complete = true;
        campaign->cursorSeat = campaign->seatCount;
        campaign->cursorRoute = 0u;
    }
    return true;
}

static inline float N60MultichannelMeasurementCampaignProgress(
    const N60MultichannelMeasurementCampaign * _Nullable campaign
) {
    if (campaign == NULL || campaign->totalMeasurementCount == 0u) return 0.0f;
    if (campaign->complete) return 1.0f;
    return (float)campaign->completedMeasurementCount / (float)campaign->totalMeasurementCount;
}

#ifdef __cplusplus
}
#endif

#endif
