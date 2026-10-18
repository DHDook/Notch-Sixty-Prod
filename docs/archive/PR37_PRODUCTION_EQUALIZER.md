# PR37 — Production Equalizer workspace

## Scope

PR37 replaces the production Equalizer placeholder with the shipping-oriented EQ editor while retaining the accepted PR34/PR35 DSP and realtime architecture.

The production UI uses the existing `StereoEQConfiguration` / `EQBand` control plane directly. It does not introduce a second EQ state model and it does not recreate Dynamic EQ as a separate user-facing bank.

## First implementation slice

- Linked / Independent L/R / Mid-Side domain selection.
- Per-domain editable lane selection.
- Minimum / Mixed / Linear phase selection.
- Whole-EQ bypass.
- Add, select, enable, edit, and remove ordinary EQ bands.
- Precision controls for filter type, frequency, gain, Q, slope, Constant-Q, and Linkwitz target metadata.
- Dynamic EQ exposed contextually on an ordinary supported EQ band.
- Log-frequency interactive response graph.
- Direct graph manipulation of frequency and gain-bearing filters.
- Drag preview remains UI-local and realtime publication is coalesced to roughly 30 Hz; gesture completion publishes the final exact value.
- Static graph magnitude is derived from the same compiled biquad sections used by the control plane rather than from a separate hand-written filter-shape approximation.

## FIR display rule

Per-band FIR remains fully active in DSP. The first live production response graph deliberately omits imported FIR magnitude rather than drawing an inaccurate approximation. The UI states this explicitly. Production FIR asset import/visualization will be completed with the persistence/import layer.

## Realtime boundary

No response-graph drawing or coefficient design occurs in the realtime callback. UI response evaluation runs on the product/UI side using already defined control-plane band compilation. Drag publication uses the existing graph publisher and is coalesced so pointer-rate events do not flood graph publication.

## Validation

`ci/validate_pr37_equalizer_ui.py` retains the production route, domain/phase controls, ordinary-band Dynamic EQ model, direct manipulation/coalescing contract, Xcode source membership, and CI integration.


## Interaction / presentation refinement

- Filter choices that the active control plane cannot accept are disabled instead of failing silently: an empty band cannot be switched to FIR until it owns a kernel, and user All-Pass is restricted to Minimum Phase.
- Add Band is available with Shift-Command-N; previous/next band selection uses Command-[ / Command-]; removal uses Command-Delete.
- Removing the selected band keeps selection on the nearest surviving neighbor rather than jumping unexpectedly to the first band.
- The response graph compiles each active band's control-plane sections once per graph draw and reuses that flattened coefficient program across plotted frequency points. It no longer redesigns the same filter sections for every pixel sample.


## Drag publication semantics

The graph uses a latest-value throttle rather than a debounce. The first drag value publishes immediately, pointer-rate updates replace one pending value, and the publisher advances at most once per 33 ms while dragging. Gesture completion cancels the throttle and publishes the final exact band state. This keeps audible interaction live without allowing pointer event rate to become graph-publication rate.
