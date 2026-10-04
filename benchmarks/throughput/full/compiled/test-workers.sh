#!/usr/bin/env bash
# Verify compiled transport delivery and process-backed ENDPOINT scaling.
# Parameters: none; run from any working directory inside an installed DALO tree.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$here/../../../.." && pwd)"
bash "$root/compiler/daloc.bash" "$here/benchmark.dalo"
for workers in 1 2 3 4; do
    bash "$here/run-workers.sh" direct 64 16 "$workers"
    bash "$here/run-workers.sh" fifo 64 16 "$workers" 2
done
