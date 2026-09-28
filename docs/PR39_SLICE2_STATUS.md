# PR39 Slice 2 status

Slice 2 adds the production analysis-capture transport used by the later Spectrum and Stereo surfaces.

- Capture is local to the active realtime bridge, not a process-global analyzer state.
- Demand bits distinguish Spectrum and Stereo consumers.
- The capture ring is fixed/preallocated at 65,536 paired frames.
- The physical-output callback captures the exact raw render Input frame and the exact DSP Output frame returned by `N60RenderKernelProcessStereoFrameInContext`, before the bridge's startup/transition fade.
- The ring is single-producer/single-consumer: the callback never waits and never overwrites unread analysis data. If the control-plane reader falls behind, new analysis frames are dropped and counted.
- Analysis demand is read once per output callback. No capture copy runs when no analysis surface is demanded.
- Consumers drain frames through a bounded off-callback copy API exposed through `CoreAudioTransportSession` and `AudioIOEngine`.
- FFT/windowing/stereo-analysis work remains outside the realtime callback and is implemented in the next slice.

This slice preserves the existing Dashboard output-only VU path and the separate detailed Input/Post-EQ/Output meter-demand path.
