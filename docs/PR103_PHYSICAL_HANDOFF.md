# PR103 — Physical Measurement Handoff

Use this checklist when a real Mac, playback system and measurement microphone
are available.

## Baseline whole-speaker / subwoofer campaign

For each intended microphone position:

1. stop ordinary DSP playback;
2. select the real measurement microphone and correct input channel;
3. load the microphone calibration file when one is available;
4. confirm the expected Playback System and output routing;
5. run all three repeated sweeps for each planned whole speaker/subwoofer source
   without moving the microphone between repeats;
6. move the same microphone to the next named position only after completing
   the current position's planned repeats; and
7. inspect SNR, repeatability, arrival spread, phase consistency and blocker
   details before treating the set as optimizer-ready.

Retain the exact app commit/version, output-device identity, microphone identity,
sample rate, routing signature and measurement-set JSON used for the campaign.

## Physical sanity checks

Confirm at conservative listening level:

- only the intended whole speaker/sub source is energized for each targeted
  measurement;
- non-target output lanes remain silent;
- no clipping, unexpected full-range driver excitation, or routing mistake is
  audible;
- repeated captures are stable with the microphone fixed; and
- moving the microphone between positions is reflected by the intended position
  label rather than silently mixed into one repeat group.

## Protected active-crossover drivers

PR103 does **not** authorize individual Low/Mid/High driver-bus measurement
through the existing targeted calibration transport.

That transport writes the sweep directly to a physical output lane and could
therefore bypass mandatory crossover or limiter protection.

Until a dedicated crossover-preserving protected-driver measurement path is
implemented and physically qualified:

- protected driver-bus measurement remains blocked;
- do not manually route a full-band sweep directly to a woofer, midrange or
  tweeter output to work around the block; and
- do not treat whole-speaker evidence as individual-driver evidence.

## Acceptance result

Physical PR103 acceptance should record:

- which whole speaker/sub sources were actually measured;
- which positions were measured;
- repeat count per source/position;
- final evidence confidence and blocker/warning state;
- microphone/calibration identity;
- any failed/retried captures; and
- confirmation that protected driver paths remained unexposed.

This physical campaign may establish real measurement quality. It still does
not, by itself, establish PR104 optimizer effectiveness.
