#!/usr/bin/env bash
# Accept a uniquely identified request at the ENDPOINT. A repeated request is
# acknowledged by the relay without applying its payload a second time.
# Parameters: $1 worker directory; $2 slot ID; $3 CLIENT|REQUEST_ID|PAYLOAD.
worker() {
    local worker_dir="$1" slot_id="$2" frame="${3:-}" client request_id payload key
    : "$worker_dir" "$slot_id"
    [[ "$frame" =~ ^([12])\|([1-9][0-9]*)\|([a-z]{16})$ ]] || return 81
    client="${BASH_REMATCH[1]}" request_id="${BASH_REMATCH[2]}" payload="${BASH_REMATCH[3]}"
    ((request_id <= DALO_ACK_BATCHES)) || return 82
    [[ "$payload" == "$DALO_ACK_PAYLOAD" ]] || return 83
    key="$client:$request_id"
    if [[ -n "${DALO_ACK_SEEN[$key]+present}" ]]; then
        ((DALO_ACK_DUPLICATES+=1))
        return 0
    fi
    DALO_ACK_SEEN["$key"]=1
    ((DALO_ACK_RECEIVED+=1))
    ((DALO_ACK_BYTES+=${#payload}))
}
