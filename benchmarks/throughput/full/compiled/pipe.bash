#!/usr/bin/env bash
# Route the compiled PIPE worker through a persistent PIPE process when enabled.
# Parameters: $1 worker directory; $2 worker slot; $3 sequence|payload frame.
worker() {
    local worker_dir="$1" slot="$2" frame="$3"
    : "$worker_dir" "$slot"
    if [[ "${DALO_BENCH_PIPE_CHILD:-0}" == 1 ]]; then
        # The child executes the actual compiled OBJECT.WORKER implementation.
        # Its endpoint adapter emits the resulting frame over the response channel.
        # Optional regression marker proves execution occurs in child PIDs.
        if [[ -n "${DALO_BENCH_PIPE_CHILD_MARKER:-}" ]]; then
            printf "%s\n" "$BASHPID" >>"$DALO_BENCH_PIPE_CHILD_MARKER"
        fi
        "${DALO_BENCH_ENDPOINT_NS}_summon_worker" in "$frame"
    elif [[ "${DALO_BENCH_PIPE_POOL_ACTIVE:-0}" == 1 ]]; then
        dalo_bench_pipe_submit "$frame"
    else
        "${DALO_BENCH_ENDPOINT_NS}_summon_worker" in "$frame"
    fi
}
