#!/usr/bin/env bash
# Dispatch an identified FIFO request and return its ACK after ENDPOINT accepts it.
# Parameters: $1 source OBJECT; $2 destination OBJECT; $3 CLIENT|REQUEST_ID|PAYLOAD.
[[ "$1" == pipe && "$2" == endpoint ]] || return 76
frame="$3"
[[ "$frame" =~ ^([A-Za-z0-9_.-]+)\|([12])\|([1-9][0-9]*)\| ]] || return 77
instance="${BASH_REMATCH[1]}" client="${BASH_REMATCH[2]}" request_id="${BASH_REMATCH[3]}"
"${DALO_ACK_ENDPOINT_NS}_summon_worker" in "$frame" || return
# Suppress the first ACK only, so a retry must reach the ENDPOINT deduplication path.
key="$client:$request_id"
if [[ "${DALO_ACK_SCENARIO:-normal}" == retry && "$key" == 2:4 && -z "${DALO_ACK_DROPPED[$key]+present}" ]]; then
    DALO_ACK_DROPPED["$key"]=1
    return 0
fi
if [[ "$client" == 1 ]]; then
    printf 'ACK|%s|%s|%s\n' "$instance" "$client" "$request_id" >&${DALO_ACK_FD_1}
else
    printf 'ACK|%s|%s|%s\n' "$instance" "$client" "$request_id" >&${DALO_ACK_FD_2}
fi
