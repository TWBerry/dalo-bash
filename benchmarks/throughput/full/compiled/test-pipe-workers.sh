#!/usr/bin/env bash
# Compile the full .dalo MACHINE and test real PIPE and ENDPOINT process counts.
# Parameters: none; execute from any working directory.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$here/../../../.." && pwd)"
bash "$root/compiler/daloc.bash" "$here/benchmark.dalo"
for mode in direct fifo; do
    producers=1
    [[ "$mode" == fifo ]] && producers=2
    for pipe_workers in 1 2 3 4; do
        for endpoint_workers in 1 2 3 4; do
            bash "$here/run-workers.sh" "$mode" 64 16 "$endpoint_workers" "$producers" "$pipe_workers"
        done
    done
done
