#!/usr/bin/env bash
# Validate a benchmark frame and deliver it to the endpoint process pool when enabled.
# Parameters: $1 worker directory; $2 worker slot; $3 sequence|payload frame.
worker() {
    local worker_dir="$1" slot="$2" frame="$3" seq payload
    : "$worker_dir" "$slot"
    [[ "$frame" == *'|'* ]] || return 81
    seq="${frame%%|*}" payload="${frame#*|}"
    [[ "$seq" =~ ^[1-9][0-9]*$ ]] || return 82
    [[ -z "${DALO_BENCH_SEEN[$seq]+set}" ]] || { ((DALO_BENCH_DUPLICATES+=1)); return 83; }
    (( ${#payload} == DALO_BENCH_SIZE )) || return 84
    [[ "$payload" == "$DALO_BENCH_PAYLOAD" ]] || return 85
    DALO_BENCH_SEEN["$seq"]=1
    if [[ "${DALO_BENCH_POOL_ACTIVE:-0}" == 1 ]]; then
        dalo_bench_endpoint_submit "$seq" || return
    else
        ((DALO_BENCH_RECEIVED+=1))
        ((DALO_BENCH_BYTES+=${#payload}))
    fi
}
