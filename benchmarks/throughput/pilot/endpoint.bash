#!/usr/bin/env bash
# Accept a uniquely identified request at the ENDPOINT. A repeated request is
# acknowledged by the relay without applying its payload a second time.
# Parameters: $1 worker directory; $2 slot ID; $3 CLIENT|REQUEST_ID|PAYLOAD.
worker() {
    local worker_dir="$1" slot_id="$2" frame="${3:-}" instance client request_id payload key rc
    : "$worker_dir" "$slot_id"
    [[ "$frame" =~ ^([A-Za-z0-9_.-]+)\|([12])\|([1-9][0-9]*)\|([a-z]{16})$ ]] || return 81
    instance="${BASH_REMATCH[1]}" client="${BASH_REMATCH[2]}" request_id="${BASH_REMATCH[3]}" payload="${BASH_REMATCH[4]}"
    ((request_id <= DALO_ACK_BATCHES)) || return 82
    [[ "$payload" == "$DALO_ACK_PAYLOAD" ]] || return 83
    # The adapter owns deduplication; the callback applies the payload once.
    dalo_ack_fifo_deliver "$instance" "$client" "$request_id" "$payload" dalo_benchmark_apply "$payload"
    rc=$?
    if (( rc == 10 )); then ((DALO_ACK_DUPLICATES+=1)); return 0; fi
    return "$rc"
}

# Apply an already validated, previously unseen benchmark payload.
# Parameters: $1 payload.
dalo_benchmark_apply() {
    ((DALO_ACK_RECEIVED+=1))
    ((DALO_ACK_BYTES+=${#1}))
}
