#!/usr/bin/env bash
# Validate asynchronous benchmark frames and record unique endpoint deliveries.
# Parameters: $1 worker directory; $2 slot ID; $3 frame CLIENT|SEQUENCE|PAYLOAD.
worker() {
    local worker_dir="$1" slot_id="$2" frame="${3:-}" client seq payload key
    : "$worker_dir" "$slot_id"
    [[ "$frame" =~ ^([12])\|([1-9][0-9]*)\|([a-z]{16})$ ]] || return 81
    client="${BASH_REMATCH[1]}" seq="${BASH_REMATCH[2]}" payload="${BASH_REMATCH[3]}"
    ((seq <= DALO_ASYNC_BATCHES)) || return 82
    [[ "$payload" == "${DALO_ASYNC_PAYLOAD:0:16}" ]] || return 83
    key="$client:$seq"
    [[ -z "${DALO_ASYNC_SEEN[$key]+present}" ]] || return 84
    DALO_ASYNC_SEEN["$key"]=1
    ((DALO_ASYNC_RECEIVED+=1))
    ((DALO_ASYNC_BYTES+=${#payload}))
}
