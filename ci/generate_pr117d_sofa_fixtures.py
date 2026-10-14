#!/usr/bin/env python3
"""Deterministic, license-clean REAL NetCDF4/HDF5 SOFA files for PR117D.

Generated only inside CI runner.temp, never committed or redistributed.
Requires netCDF4 and numpy, installed on CI macOS (off render thread).
"""
import argparse
from pathlib import Path

import netCDF4
import numpy as np


def make(path, sample_rate, delays, corrupt=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with netCDF4.Dataset(path, "w", format="NETCDF4") as root:
        for name, length in {
            "I": 1, "C": 3, "R": 2, "E": 1, "N": 8, "M": 2,
        }.items():
            root.createDimension(name, length)
        root.Conventions = "SOFA"
        root.Version = "2.1"
        root.SOFAConventions = "SimpleFreeFieldHRIR"
        root.SOFAConventionsVersion = "1.2"
        root.DataType = "FIR"
        root.RoomType = "free field"
        root.License = "CC0-1.0"
        root.Title = "PR117D generated 384 kHz acceptance reference"

        def coordinates(name, dims, values, kind, units):
            v = root.createVariable(name, "f8", dims)
            v.Type = kind
            v.Units = units
            v[:] = np.asarray(values, dtype=np.float64)

        coordinates("ListenerPosition", ("I", "C"), [[0., 0., 0.]], "cartesian", "metre")
        coordinates("ListenerView", ("I", "C"), [[1., 0., 0.]], "cartesian", "metre")
        coordinates("ListenerUp", ("I", "C"), [[0., 0., 1.]], "cartesian", "metre")
        coordinates("ReceiverPosition", ("R", "C", "I"),
                    [[[0.], [0.09], [0.]], [[0.], [-0.09], [0.]]],
                    "cartesian", "metre")
        coordinates("SourcePosition", ("M", "C"),
                    [[30., 0., 1.], [-30., 0., 1.]],
                    "spherical", "degree, degree, metre")
        coordinates("EmitterPosition", ("E", "C", "I"),
                    [[[0.], [0.], [0.]]], "cartesian", "metre")
        ir = root.createVariable("Data.IR", "f8", ("M", "R", "N"))
        responses = np.zeros((2, 2, 8), dtype=np.float64)
        responses[0, 0, 0] = 1.0
        responses[0, 1, 0] = 0.5
        responses[1, 0, 0] = 0.25
        responses[1, 1, 0] = 0.75
        if corrupt:
            responses[1, 1, 0] = np.nan
        ir[:] = responses
        rate = root.createVariable("Data.SamplingRate", "f8", ("I",))
        rate.Units = "hertz"
        rate[:] = np.array([sample_rate], dtype=np.float64)
        delay = root.createVariable("Data.Delay", "f8", ("I", "R"))
        delay.Units = "sample"
        delay[:] = np.asarray([delays], dtype=np.float64)
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    fixtures = {
        "integer384": (384000., (2., 5.), False),
        "fractional48": (48000., (0.5, 1.), False),
        "negative441": (44100., (-1., 0.), False),
        "nonfinite384": (384000., (2., 5.), True),
    }
    for name, (rate, delay, corrupt) in fixtures.items():
        path = make(args.directory / (name + ".sofa"), rate, delay, corrupt)
        print(f"{name}: {path} (rate={rate:g}, delay={delay}, invalid={corrupt})")


if __name__ == "__main__":
    main()
