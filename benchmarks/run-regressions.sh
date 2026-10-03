#!/usr/bin/env bash
# Purpose: compile and execute the parent FIFO integration regression, then validate the throughput plan.
# Parameters: none; execute from any directory inside the repository.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
bash compiler/daloc.bash benchmarks/parent-dispatch/parent-dispatch.dalo
bash benchmarks/parent-dispatch/child-fifo-probe.sh
python3 benchmarks/throughput/matrix.py
