#!/usr/bin/env python3
"""Define and validate the deterministic DALO throughput benchmark matrix.

This file does not claim to measure DALO yet: the compiled MACHINE controller,
parent FIFO relay, worker-count controls and timestamp protocol are pending.
"""
from __future__ import annotations

import argparse
import json


def build_matrix() -> list[dict[str, int | str]]:
    """Return both benchmark modes for worker counts 1..4.

    Parameters: none. Sizes are powers of two, including both endpoints.
    """
    return [
        {"mode": mode, "workers_per_object": workers, "bytes": size, "batches": batches}
        for mode, max_size, batches in (("direct", 65536, 256), ("fifo", 2048, 64))
        for workers in range(1, 5)
        for size in (1 << power for power in range(max_size.bit_length()))
    ]


def main() -> None:
    """Print a machine-readable plan or a human-readable summary.

    Parameters: none; --json selects JSON Lines output.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit JSON Lines")
    args = parser.parse_args()
    matrix = build_matrix()
    if args.json:
        for item in matrix:
            print(json.dumps(item, separators=(",", ":")))
        return
    for mode in ("direct", "fifo"):
        entries = [entry for entry in matrix if entry["mode"] == mode]
        print(f"{mode}: {len(entries)} configurations, "
              f"{sum(int(entry['batches']) for entry in entries)} batches")
    print(f"total: {len(matrix)} configurations, "
          f"{sum(int(entry['batches']) for entry in matrix)} batches")


if __name__ == "__main__":
    main()
