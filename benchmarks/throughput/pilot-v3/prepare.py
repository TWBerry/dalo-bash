#!/usr/bin/env python3
"""Adapt the existing verified FIFO pilot test for precompiled, recovery-free runs."""
import sys
from pathlib import Path


def main():
    """Patch a generated test in place; argv[1] is its filesystem path."""
    if len(sys.argv) != 2:
        raise SystemExit('usage: prepare.py GENERATED_TEST')
    path = Path(sys.argv[1])
    script = path.read_text()
    compile_start = 'phase compile_start\n'
    compile_end = 'phase compile_done\n'
    assert script.count(compile_start) == 1 and script.count(compile_end) == 1
    start = script.index(compile_start)
    end = script.index(compile_end, start) + len(compile_end)
    script = (script[:start] + '''# Load a MACHINE compiled once by the benchmark controller.
# DALO_PILOT_V2_COMPILED: absolute path to the compiled MACHINE script.
: "${DALO_PILOT_V2_COMPILED:?missing compiled MACHINE}"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
source "$DALO_PILOT_V2_COMPILED"
''' + script[end:])
    # The original script sources the generated MACHINE after compilation.
    script = script.replace('source "$TMP/compiled_ack_topology.dalo.bash"\n', '')
    recovery_start = 'phase kill_start\n'
    recovery_end = 'phase replacement_done\n'
    assert script.count(recovery_start) == 1 and script.count(recovery_end) == 1
    start = script.index(recovery_start)
    end = script.index(recovery_end, start) + len(recovery_end)
    script = script[:start] + '''# The destructive SIGKILL/reap test is validated separately.
# No worker is killed or replaced inside a throughput measurement.
phase recovery_skipped
''' + script[end:]
    script = script.replace('PASS: compiled recovery + scenario=%s', 'PASS: fifo pilot + scenario=%s')
    path.write_text(script)


if __name__ == '__main__':
    main()
