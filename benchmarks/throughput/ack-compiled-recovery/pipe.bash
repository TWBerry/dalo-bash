#!/usr/bin/env bash
# Forward a request through the existing child-to-parent FIFO adapter.
# Parameters: $1 worker directory; $2 slot; $3 request frame.
worker() {
    local worker_dir="$1" slot="$2" frame="$3"
    : "$worker_dir" "$slot"
    "${DALO_ACK_PIPE_NS}_fifo_send" P pipe endpoint "$frame"
}
