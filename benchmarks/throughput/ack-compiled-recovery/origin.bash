#!/usr/bin/env bash
# Emit a request through the compiled ORIGIN's connected PIPE input.
# Parameters: $1 worker directory; $2 slot; $3 request frame.
worker() {
    local worker_dir="$1" slot="$2" frame="$3"
    : "$worker_dir" "$slot"
    "${DALO_ACK_PIPE_NS}_summon_worker" in "$frame"
}
