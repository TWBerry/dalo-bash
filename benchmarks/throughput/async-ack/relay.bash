#!/usr/bin/env bash
# Route one child frame through the endpoint, then send an explicit ACK to its child.
# Parameters: $1 source OBJECT; $2 destination OBJECT; $3 CLIENT|SEQUENCE|PAYLOAD.
[[ "$1" == pipe && "$2" == endpoint ]] || return 76
frame="$3"
[[ "$frame" =~ ^([12])\|([1-9][0-9]*)\| ]] || return 77
client="${BASH_REMATCH[1]}" seq="${BASH_REMATCH[2]}"
"${DALO_ASYNC_ENDPOINT_NS}_summon_worker" in "$frame" || return
# The ACK is emitted only after the ENDPOINT has accepted the frame.
if [[ "${DALO_ASYNC_DROP_ACK:-}" == "$client:$seq" ]]; then return 0; fi
if [[ "$client" == 1 ]]; then
    printf 'ACK|%s|%s\n' "$client" "$seq" >&${DALO_ASYNC_ACK_FD_1}
else
    printf 'ACK|%s|%s\n' "$client" "$seq" >&${DALO_ASYNC_ACK_FD_2}
fi
