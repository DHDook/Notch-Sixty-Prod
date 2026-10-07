#!/usr/bin/env python3
import sys
from pathlib import Path

import netCDF4
import numpy as np

path = Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)

with netCDF4.Dataset(path, "w", format="NETCDF4") as root:
    for name, size in {
        "I": 1,
        "C": 3,
        "R": 2,
        "E": 1,
        "N": 8,
        "M": 2,
    }.items():
        root.createDimension(name, size)

    root.Conventions = "SOFA"
    root.Version = "2.1"
    root.SOFAConventions = "SimpleFreeFieldHRIR"
    root.SOFAConventionsVersion = "1.2"
    root.DataType = "FIR"
    root.RoomType = "free field"
    root.License = "CC0-1.0"
    root.Title = "PR85 generated fixture"

    def coordinate(name, dims, values, coordinate_type, units):
        variable = root.createVariable(name, "f8", dims)
        variable.Type = coordinate_type
        variable.Units = units
        variable[:] = np.asarray(values, dtype=np.float64)
        return variable

    coordinate(
        "ListenerPosition",
        ("I", "C"),
        [[0.0, 0.0, 0.0]],
        "cartesian",
        "metre",
    )
    coordinate(
        "ListenerView",
        ("I", "C"),
        [[1.0, 0.0, 0.0]],
        "cartesian",
        "metre",
    )
    coordinate(
        "ListenerUp",
        ("I", "C"),
        [[0.0, 0.0, 1.0]],
        "cartesian",
        "metre",
    )
    coordinate(
        "ReceiverPosition",
        ("R", "C", "I"),
        [
            [[0.0], [0.09], [0.0]],
            [[0.0], [-0.09], [0.0]],
        ],
        "cartesian",
        "metre",
    )
    coordinate(
        "SourcePosition",
        ("M", "C"),
        [
            [30.0, 0.0, 1.0],
            [-30.0, 0.0, 1.0],
        ],
        "spherical",
        "degree, degree, metre",
    )
    coordinate(
        "EmitterPosition",
        ("E", "C", "I"),
        [[[0.0], [0.0], [0.0]]],
        "cartesian",
        "metre",
    )

    ir = root.createVariable("Data.IR", "f8", ("M", "R", "N"))
    values = np.zeros((2, 2, 8), dtype=np.float64)
    values[0, 0, 0] = 1.0
    values[0, 1, 1] = 0.8
    values[1, 0, 1] = 0.8
    values[1, 1, 0] = 1.0
    ir[:] = values

    sample_rate = root.createVariable("Data.SamplingRate", "f8", ("I",))
    sample_rate.Units = "hertz"
    sample_rate[:] = [48000.0]

    delay = root.createVariable("Data.Delay", "f8", ("I", "R"))
    delay[:] = [[0.5, 1.0]]

print(path)
