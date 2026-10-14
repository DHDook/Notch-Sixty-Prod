"""PR117 Slice 2: deterministic acoustic transfer and robust-decision fixtures.

Offline-only independent scalar oracle for physical-acoustic reasoning.
No production DSP imports, no hardware, no credentials, no data downloads.
"""

from __future__ import annotations

import cmath
import math
import random
from dataclasses import dataclass

REFERENCE_FREQUENCIES_HZ = (40.0, 63.0, 80.0, 100.0, 125.0, 160.0)
SEAT_WEIGHTS = (0.50, 0.30, 0.20)
MAX_SINGLE_SEAT_REGRESSION_DB = 0.75
MAX_CORRECTION_BOOST_DB = 6.0
MIN_OBJECTIVE_IMPROVEMENT_DB2 = 0.25


@dataclass(frozen=True)
class AcousticPath:
    amplitude: float
    delay_frames: int


def ensure(condition: bool, why: str) -> None:
    if not condition:
        raise AssertionError("PR117 acoustic transfer oracle: " + why)


def close(actual: float, expected: float, tolerance: float, why: str) -> float:
    ensure(math.isfinite(actual) and math.isfinite(expected), why + " nonfinite")
    deviation = abs(actual - expected)
    ensure(deviation <= tolerance, (
        f"{why}: got {actual:.9g} expected {expected:.9g} +/- {tolerance:.3g}"
    ))
    return deviation


def analytic_transfer(paths: tuple[AcousticPath, ...],
                      hz: float, rate: int) -> complex:
    """Known sum of acoustic path phase rotations; no FFT."""
    ensure(rate > 0 and 0 <= hz < rate / 2, "invalid frequency or rate")
    ensure(paths and all(
        math.isfinite(p.amplitude) and 0 <= p.delay_frames <= rate for p in paths
    ), "invalid synthetic path")
    return sum(
        p.amplitude * cmath.exp(-2j * math.pi * hz * p.delay_frames / rate)
        for p in paths
    )


def impulse_dft(paths: tuple[AcousticPath, ...],
                hz: float, rate: int) -> complex:
    """Separate time-domain impulse assembly and scalar Fourier integral.

    Deliberately not a call to analytic_transfer; bin-independent DFT using
    explicit cosine and sine of each *summed impulse time sample*.
    """
    length = max(p.delay_frames for p in paths) + 1
    impulse = [0.0] * length
    for path in paths:
        impulse[path.delay_frames] += path.amplitude
    real = sum(v * math.cos(2 * math.pi * hz * i / rate)
               for i, v in enumerate(impulse) if v)
    imaginary = -sum(v * math.sin(2 * math.pi * hz * i / rate)
                     for i, v in enumerate(impulse) if v)
    return complex(real, imaginary)


def power_db(transfer: complex) -> float:
    magnitude = abs(transfer)
    return 20 * math.log10(max(magnitude, 1e-12))


def weighted_loss_db2(levels_db: tuple[float, ...],
                      target_db: float = 0.0) -> float:
    ensure(len(levels_db) == len(SEAT_WEIGHTS), "incorrect seat count")
    ensure(all(math.isfinite(x) for x in levels_db), "nonfinite seat response")
    return sum(w * (x - target_db) ** 2
               for w, x in zip(SEAT_WEIGHTS, levels_db))


def review_candidate(before_db: tuple[float, ...],
                     after_db: tuple[float, ...],
                     boost_db: float,
                     cap_db: float = MAX_SINGLE_SEAT_REGRESSION_DB) -> dict:
    """Conservative example policy; NOT the production optimizer/deployment gate.

    A mean improvement cannot override a worse individual seat; a positive EQ
    target cannot override an explicit headroom/boost limit.
    """
    ensure(len(before_db) == len(after_db) == len(SEAT_WEIGHTS), "seat mapping")
    ensure(math.isfinite(boost_db) and math.isfinite(cap_db), "invalid policy")
    gain = weighted_loss_db2(before_db) - weighted_loss_db2(after_db)
    # Regression here measures new absolute target error at one seat,
    # not merely a negative pressure change (a cut may be beneficial).
    worst = max(abs(a) - abs(b) for a, b in zip(after_db, before_db))
    reasons = []
    if gain < MIN_OBJECTIVE_IMPROVEMENT_DB2:
        reasons.append("insufficient_weighted_improvement")
    if worst > cap_db:
        reasons.append("held_out_seat_regression")
    if boost_db > MAX_CORRECTION_BOOST_DB:
        reasons.append("boost_over_headroom_budget")
    if boost_db < -24:
        reasons.append("excessive_attenuation")
    return {
        "accepted": len(reasons) == 0,
        "rejectionReasons": reasons,
        "weightedLossImprovementDB2": gain,
        "worstSeatTargetErrorRegressionDB": worst,
    }


def run_slice2(rate_hz: tuple[int, ...]) -> list[dict]:
    results = []
    ensure(len(rate_hz) == len(set(rate_hz)), "duplicate rates")
    ensure(rate_hz and max(rate_hz) == 384000, "384-kHz ceiling missing")
    for rate in rate_hz:
        # Three distinct listening positions: one direct, one reflected, one
        # mild delay asymmetry. Path delays expressed in *sample frames*.
        reflector = round(rate * 0.006)
        room = {
            "center": (
                AcousticPath(1.0, 0),
                AcousticPath(0.30, reflector),
            ),
            "near_wall": (
                AcousticPath(1.0, 0),
                AcousticPath(-0.55, round(rate * 0.003)),
            ),
            "off_axis": (
                AcousticPath(0.85, round(rate * 0.001)),
                AcousticPath(0.20, round(rate * 0.009)),
            ),
        }
        worst = 0.0
        for seat, paths in room.items():
            for hz in REFERENCE_FREQUENCIES_HZ:
                a = analytic_transfer(paths, hz, rate)
                b = impulse_dft(paths, hz, rate)
                worst = max(
                    worst,
                    close(a.real, b.real, 1e-12, "complex room real"),
                    close(a.imag, b.imag, 1e-12, "complex room imaginary"),
                )
                ensure(math.isfinite(power_db(a)), "room dB nonfinite")
        results.append({
            "name": f"three_seat_transfer_oracle_{rate}",
            "type": "synthetic_analytical_ground_truth",
            "seatCount": 3,
            "frequencyCount": len(REFERENCE_FREQUENCIES_HZ),
            "worstComplexComponentDifference": worst,
        })
        # Sample-frame quantization must approach requested timing with
        # <= 0.5 frame uncertainty; the bound scales correctly to 384 kHz.
        nominal_ms = 2.375
        samples = round(rate * nominal_ms / 1000)
        quantization_ms = abs(samples / rate * 1000 - nominal_ms)
        ensure(quantization_ms <= 500.0001 / rate, "sub-frame timing error")
        results.append({
            "name": f"clock_quantization_{rate}",
            "type": "synthetic_analytical_ground_truth",
            "delayFrames": samples,
            "quantizationErrorMS": quantization_ms,
            "worstPossibleErrorMS": 500 / rate,
        })

    before = (-6.0, -3.0, -2.0)
    fair = (-3.0, -2.0, -1.0)
    misleading = (0.0, -2.0, -4.0)
    approved = review_candidate(before, fair, 4.0)
    ensure(approved["accepted"], "monotonic three-seat improvement rejected")
    results.append({
        "name": "multi_seat_real_improvement",
        "type": "synthetic_policy_guard",
        **approved,
    })
    rejected = review_candidate(before, misleading, 4.0)
    ensure(not rejected["accepted"], "deceptive mean seat win accepted")
    ensure("held_out_seat_regression" in rejected["rejectionReasons"],
           "seat-protection mechanism absent")
    ensure(rejected["weightedLossImprovementDB2"] > 0,
           "fixture not actually misleading")
    results.append({
        "name": "weighted_mean_looks_good_but_one_seat_worsens",
        "type": "synthetic_policy_guard",
        **rejected,
    })
    too_much = review_candidate(before, fair, 8.0)
    ensure(not too_much["accepted"] and
           "boost_over_headroom_budget" in too_much["rejectionReasons"],
           "uncapped boost accepted")
    results.append({
        "name": "gain_budget_not_overridden_by_seat_improvement",
        "type": "synthetic_policy_guard",
        **too_much,
    })
    # A nominal improvement that vanishes under modest repeat noise is not
    # a robust claim. This is deterministic perturbation testing, not an
    # empirical confidence percentage derived from a real microphone.
    rng = random.Random(117)
    nominal_before = (-3.0, -2.0, -1.0)
    nominal_after = (-2.8, -1.9, -0.9)
    trials = []
    for _ in range(32):
        noise = tuple(rng.uniform(-0.35, 0.35) for _ in SEAT_WEIGHTS)
        measurement_before = tuple(x + n for x, n in zip(nominal_before, noise))
        # Separate repeat capture suffers independent measurement jitter.
        second_noise = tuple(rng.uniform(-0.35, 0.35) for _ in SEAT_WEIGHTS)
        measurement_after = tuple(x + n for x, n in zip(nominal_after, second_noise))
        trials.append(review_candidate(measurement_before, measurement_after, 1.0))
    rejected_count = sum(not trial["accepted"] for trial in trials)
    ensure(rejected_count > 0, "fragile correction incorrectly always accepted")
    results.append({
        "name": "repeat_measurement_perturbation",
        "type": "synthetic_uncertainty_rejection",
        "trialCount": 32,
        "rejectedTrials": rejected_count,
        "empiricalConfidenceClaim": False,
    })
    # A known half-cycle delay at 100 Hz gives complete cancellation with
    # a matched second source. Moving the second source by 1 ms changes its
    # phase by 36 degrees, so reported summation cannot be approximated as
    # magnitude-only addition.
    frequency = 100.0
    rate = 48000
    first = (AcousticPath(1.0, 0), AcousticPath(1.0, 240))
    null = analytic_transfer(first, frequency, rate)
    close(abs(null), 0.0, 1e-12, "5-ms 100-Hz coherent cancellation")
    shifted = (AcousticPath(1.0, 0), AcousticPath(1.0, 288))
    close(abs(analytic_transfer(shifted, frequency, rate)),
          2 * math.sin(math.pi / 10), 1e-12,
          "phase-aware one-millisecond shift")
    results.append({
        "name": "relative_sub_delay_changes_coherent_sum",
        "type": "synthetic_analytical_ground_truth",
        "nullMagnitude": abs(null),
        "shiftedMagnitude": abs(analytic_transfer(shifted, frequency, rate)),
    })
    return results
