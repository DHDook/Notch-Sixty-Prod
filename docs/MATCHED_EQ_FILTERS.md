# Matched EQ filters (E33 S26, graph ABI v47)

The bilinear (RBJ cookbook) design squashes a filter near Nyquist: a +6 dB, Q 1 bell at 15 kHz gives about +0.5 dB at 20 kHz at
44.1 kHz where the analogue filter gives +4.4 dB (gap G51). Matched designs fit the digital biquad to the analogue magnitude instead.

## Method

Source: `core/src/eqmatched.cpp` (C++, double, deterministic, no allocation, safe to run on the render thread's edit path).

- Poles by the matched-z map: the analogue poles s = -a +- jb of the denominator map to z = exp(sT). Vicanek, "Matched Second Order
  Digital Filters" (2016), gives closed forms for low pass, high pass and band pass; those are used directly.
- Numerator for peak and shelves: B0, B1, B2 are solved from three magnitude targets, at DC, at the corner and at Nyquist, in the
  basis phi0 = 1 - sin^2(w/2), phi1 = sin^2(w/2), phi2 = 4 phi0 phi1 (Vicanek's formulation; Orfanidis, "Digital Parametric
  Equalizer Design with Prescribed Nyquist-Frequency Gain", 1997, is the precedent for prescribing the Nyquist gain). b0 is the
  larger root of the factorisation, b2 = S - b0.
- Cuts are the inverse of the matched boost (A to 1/A), which avoids a spurious notch. The high shelf is A^2 divided by the matched low
  shelf (the identity LS x HS = A^2), because poles at sqrt(A) w0 can lie above Nyquist.
- Tilt is two matched shelves at Q 0.707. Constant-Q peak uses Q/A as the cookbook does.
- Fallback: when the matched design is undefined (corner too near Nyquist, no real factorisation, unstable or non-finite), the section
  is the cookbook section, so the result always exists. A 0 dB section is the cookbook flat section.
- Notch, all-pass, Linkwitz transform, first-order shelves and low or high passes above 12 dB/oct keep the cookbook (gap G93).

## Types

Section types 16..24 are the matched variants of 0..8 (`N60_PEQ_SECTION_MATCHED_BASE` + base): 16 peak, 17 low shelf, 18 high
shelf, 19 low pass, 20 high pass, 23 band pass, 24 constant-Q peak. 21 and 22 are unused. Types 0..10 are bit-identical to before.
One core entry point, `n60_eq_design_section` (and `n60_eq_section_magnitude`), is used by the PEQ stage, the headroom model, the
linear-phase design and `EQFilterAnalysis` (through the sections Swift compiles), so the curve, the FIR and the engine agree.

## Tolerance to the analogue curve (20 Hz to the lower of 20 kHz and 0.499 fs, where the analogue is above -40 dB)

Checked by `core/tests/test_eq_matched.cpp` at the eight standard rates, Q 0.3..5 (shelves 0.3..1.5, pass types 0.5..2), gains
+-6, 12, 18 dB, corners 30 Hz to 20 kHz. Corner at or below 0.30 fs / corner up to 0.42 fs:

| type | near | far |
|---|---|---|
| peak | 1.1 dB | 3.1 dB |
| low and high shelf | 1.2 dB | 1.6 dB |
| low pass | 1.7 dB | 1.7 dB |
| high pass | 0.9 dB | 2.7 dB |
| band pass | 1.5 dB | 2.3 dB |

The cookbook is far outside these near Nyquist (G51 case: more than 2.5 dB off). Corners above 0.42 fs are not claimed.

## Per band, and who gets it (owner decision 32)

The method is stored per band (`filterMethod`, absent means cookbook, so old profiles are byte-identical and sound the same).
New bands from Add Band and double-click are matched. APO and AutoEQ imports, EQ-fit bands and saved EQs stay cookbook; the
Equalizer page offers "Use matched filters" as one undoable edit. Dynamic bands keep the cookbook design (their filter is
recalculated in the dynamics path, which this slice does not change); the page says so.
