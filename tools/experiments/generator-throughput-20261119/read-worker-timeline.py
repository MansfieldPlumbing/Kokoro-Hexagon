"""Extract the final sampled stage records from a section-worker-timeline capture."""
import csv
import mmap
from pathlib import Path
import struct
import sys

LABELS = (
    "FillStart", "ActivationReady", "LockAcquired",
    "FirstHmxIssue", "LastResultVisible", "CombineComplete",
)
MAGIC = b"HMX1"
STRIDE = 64
BANK_SIZE = 24
SECTIONS = ("Main128", "Source256", "Source128")
path = Path(sys.argv[1])
with path.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
    # The fixture uses one final record per stage/worker and window width.
    # Each live bank has 24 consecutive records with the marker at +56.
    bases = []
    after = 0
    while (marker := data.find(MAGIC, after)) >= 0:
        after = marker + len(MAGIC)
        base = marker - 56
        if base % 128 not in (0, 64):
            continue
        if all(data[marker + i * STRIDE:marker + i * STRIDE + 4] == MAGIC for i in range(BANK_SIZE)):
            if not bases or base - bases[-1] >= BANK_SIZE * STRIDE:
                bases.append(base)
    if len(bases) != len(SECTIONS):
        raise SystemExit(f"Expected three lighthouse timeline banks, found {bases}")
    start, end = struct.unpack_from("<QQ", data)
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(("Section", "Worker", "Stage", *LABELS))
    for section, base in zip(SECTIONS, bases):
        for i in range(BANK_SIZE):
            values = struct.unpack_from("<6Q", data, base + i * STRIDE)
            if not (start <= values[0] <= values[-1] <= end and tuple(sorted(values)) == values):
                raise SystemExit(f"Invalid timestamp order in {section} slot {i}: {values}")
            writer.writerow((section, i // 6, i % 6, *(t - start for t in values)))
