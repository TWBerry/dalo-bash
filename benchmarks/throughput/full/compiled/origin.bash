#!/usr/bin/env bash
# Forward a benchmark frame from the compiled ORIGIN to the compiled PIPE.
# Parameters: $1 worker directory; $2 worker slot; $3 sequence|payload frame.
worker() {
    local worker_dir="$1" slot="$2" frame="$3"
    : "$worker_dir" "$slot"
    "${DALO_BENCH_PIPE_NS}_summon_worker" in "$frame"
}
