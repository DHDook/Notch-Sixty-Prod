# PR40 Slice E validation checkpoint

Slice E now builds on the fully green Slice D measurement/project foundation and the validated minimum-phase FIR designer.

Target/preview work already validated:
- Flat, Gentle Downward Tilt, and Bass Shelf + Tilt built-in targets;
- deterministic target text import, normalization, sorting and duplicate-frequency averaging;
- log-frequency target interpolation;
- non-destructive fractional-octave magnitude smoothing;
- correction-range / usable-range intersection;
- maximum boost/cut clamps, deep-null boost protection, and smooth edge tapering;
- explicit correction-preview headroom without changing Content Preset ownership.

FIR work already validated:
- offline real-cepstrum conversion from desired correction magnitude to a causal minimum-phase stereo response;
- power-of-two Accelerate complex transforms sized independently of the realtime callback;
- bounded tap generation through the existing `N60_CONVOLUTION_MAX_TAPS` limit;
- direct output in the existing `RoomCorrectionFilter` model used by the current room-correction convolution runtime;
- zero declared intentional filter latency for the minimum-phase design; existing convolution partition latency remains separate and authoritative;
- post-truncation re-measurement of the actual generated Left / Right filters;
- predicted corrected Left / Right magnitude response derived from the actual truncated filter;
- recommended headroom derived from the actual maximum positive filter gain with a deterministic safety margin;
- finite-data, sample-rate, Nyquist and transform-size validation;
- stable algorithm version `n60-room-minphase-v1`;
- deterministic native-rate coverage at 44.1, 48, 96 and 384 kHz plus the full 32,768-tap budget.

Project integration:
- active target persistence in the room-correction sidecar;
- target edits invalidate candidate selection without deleting historical design assets or touching deployed playback;
- correction preview and final FIR generation share the same included-position quality and usable-range gate;
- clipped, incomplete, missing-range, or sub-20 dB SNR included measurements are rejected for design until re-measured or excluded;
- generated design candidates persist transactionally and become the selected project candidate;
- explicit persisted design selection and deletion;
- deterministic controller tests for preview/design persistence, target-change invalidation, low-confidence rejection, selection and deletion.

Production Target / Design surface in this checkpoint:
- built-in target menu plus sandboxed custom target-file import;
- editable two-column target point editor using the same parser/normalization rules as imports;
- correction low/high controls, smoothing selector, maximum boost/cut controls and FIR tap-count selector;
- safe correction preview showing effective measured range, maximum requested positive correction and advisory headroom;
- explicit FIR generation with user-editable design name;
- persisted generated-design history with selection and deletion controls;
- selected-candidate status makes clear that generation does not deploy or alter daily playback;
- preview state is invalidated when project content changes so stale safety information is not retained in the UI.

After this exact UI tree is green, Slice E is functionally complete. Slice F will deploy the selected candidate transactionally through the existing Room Correction runtime and Playback System profile ownership path, then add the daily-playback calibration summary and deployment/audition regression gates.
