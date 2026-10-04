#!/usr/bin/env bash
# Regression: prove compiled OBJECT.WORKER executes inside child PIPE processes.
# Parameters: none; runs both benchmark transport modes with two PIPE workers.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
marker="$(mktemp "${TMPDIR:-/tmp}/dalo-compiled-pipe.XXXXXXXX")"
trap 'rm -f -- "$marker"' EXIT
export DALO_BENCH_PIPE_CHILD_MARKER="$marker"
for mode in direct fifo; do
    : >"$marker"
    bash "$here/run-workers.sh" "$mode" 8 16 2 "$([[ "$mode" == fifo ]] && echo 2 || echo 1)" 2
    [[ "$(wc -l <"$marker")" -eq 8 ]] || { echo "FAIL: compiled PIPE did not execute 8 frames" >&2; exit 1; }
    [[ "$(sort -u "$marker" | wc -l)" -eq 2 ]] || { echo "FAIL: expected two distinct child PIDs" >&2; exit 1; }
    echo "PASS compiled-worker-child mode=$mode distinct_child_pids=2 frames=8"
done
