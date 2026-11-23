/*
 * Realtime ANC domain header (E21 S4). Includes every public header of the realtime ANC domain: the active
 * quiet zone tonal types, the FxLMS primitives, the remote tonal runtime, the live feed-forward filter, the
 * howl guard and the anti-noise lane feed. The domain version below changes only when one of those interfaces
 * changes; it is independent of the graph, measurement and design domains (n60_core_abi reports it).
 * Pure C interface over C++20 sources in core/src/anc; no platform header, no Apple framework.
 */
#ifndef N60_ANC_H
#define N60_ANC_H

#include <stdint.h>

#include "n60/active_quiet_zone.h"
#include "n60/anc_guard.h"
#include "n60/anc_lane_feed.h"
#include "n60/ff_live.h"
#include "n60/fxlms.h"
#include "n60/remote_tonal.h"

#define N60_ANC_ABI_VERSION 1u

#ifdef __cplusplus
extern "C" {
#endif

uint32_t n60_anc_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif
