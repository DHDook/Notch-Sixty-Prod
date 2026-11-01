#!/usr/bin/env python3
"""E4 S31: deterministic reviewer noise files for reproducing the ANC reduction numbers.

Writes three mono 16-bit PCM WAV files at 48 kHz and 96 kHz, plus SHA256SUMS.txt:

  fan_tone_<rate>.wav            a fan blade-pass tone (47 Hz) with harmonics 2-6, slow level wobble
  drifting_compressor_<rate>.wav a compressor (60 Hz) with harmonics 2-4 whose pitch drifts +/-3 Hz
  broadband_lf_<rate>.wav        broadband low-frequency noise (white noise through a 2-pole low-pass, about 120 Hz)

Everything is generated from fixed constants and an integer xorshift generator, so no recording is
used and the same arguments always give byte-identical files (same Python float maths: IEEE 754
doubles, `math.sin`). Usage:

  python3 ci/generate_reviewer_noise.py OUTPUT_DIR [--seconds 60]
"""
import argparse
import hashlib
import math
import os
import struct
import sys

RATES = (48000, 96000)
FULL_SCALE_LEVEL = 0.5  # peak target, linear


def xorshift32(state):
    state ^= (state << 13) & 0xFFFFFFFF
    state ^= state >> 17
    state ^= (state << 5) & 0xFFFFFFFF
    return state


def fan_tone(rate, count):
    f0 = 47.0
    amps = [1.0, 0.5, 0.33, 0.25, 0.2, 0.16]
    norm = FULL_SCALE_LEVEL / sum(amps) / 1.12
    out = []
    for n in range(count):
        t = n / rate
        wobble = 1.0 + 0.12 * math.sin(2.0 * math.pi * 0.3 * t)
        s = 0.0
        for h, a in enumerate(amps, start=1):
            s += a * math.sin(2.0 * math.pi * f0 * h * t + 0.7 * h)
        out.append(s * wobble * norm)
    return out


def drifting_compressor(rate, count):
    amps = [1.0, 0.6, 0.35, 0.2]
    norm = FULL_SCALE_LEVEL / sum(amps)
    phase = 0.0
    out = []
    for n in range(count):
        t = n / rate
        freq = 60.0 + 3.0 * math.sin(2.0 * math.pi * t / 40.0)
        phase += 2.0 * math.pi * freq / rate
        if phase > 2.0 * math.pi * 1000.0:
            phase -= 2.0 * math.pi * 1000.0
        s = 0.0
        for h, a in enumerate(amps, start=1):
            s += a * math.sin(h * phase)
        out.append(s * norm)
    return out


def broadband_lf(rate, count):
    state = 0x2545F491
    a = 1.0 - math.exp(-2.0 * math.pi * 120.0 / rate)
    y1 = 0.0
    y2 = 0.0
    out = []
    # Fixed gain: two one-pole stages at 120 Hz leave about this fraction of white-noise RMS.
    gain = 0.45 * math.sqrt(rate / 48000.0) * 7.0
    for _ in range(count):
        state = xorshift32(state)
        white = (state / 2147483648.0) - 1.0
        y1 += a * (white - y1)
        y2 += a * (y1 - y2)
        v = y2 * gain
        out.append(max(-0.95, min(0.95, v)))
    return out


def wav_bytes(samples, rate):
    pcm = b"".join(struct.pack("<h", int(round(max(-1.0, min(1.0, s)) * 32767.0))) for s in samples)
    header = b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(pcm))
    return header + pcm


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output_dir")
    parser.add_argument("--seconds", type=float, default=60.0)
    args = parser.parse_args(argv)
    os.makedirs(args.output_dir, exist_ok=True)
    sums = []
    for rate in RATES:
        count = int(round(args.seconds * rate))
        for name, fn in (("fan_tone", fan_tone), ("drifting_compressor", drifting_compressor), ("broadband_lf", broadband_lf)):
            data = wav_bytes(fn(rate, count), rate)
            filename = "%s_%d.wav" % (name, rate)
            with open(os.path.join(args.output_dir, filename), "wb") as handle:
                handle.write(data)
            sums.append("%s  %s" % (hashlib.sha256(data).hexdigest(), filename))
    with open(os.path.join(args.output_dir, "SHA256SUMS.txt"), "w") as handle:
        handle.write("\n".join(sums) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
