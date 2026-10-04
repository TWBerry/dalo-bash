#!/usr/bin/env bash
# Consume one benchmark frame and publish a parent-visible acknowledgment.
# Parameters: $1 worker directory; $2 slot ID; $3 benchmark frame.
worker() {
    local worker_dir="$1" slot_id="$2" frame="${3:-}" sequence payload expected
    : "$worker_dir" "$slot_id"
    [[ "$frame" == *'|'* ]] || return 81
    sequence="${frame%%|*}"
    payload="${frame#*|}"
    [[ "$sequence" =~ ^[0-9]+$ ]] || return 82
    expected=$((DALO_BENCH_ACK_COUNT + 1))
    ((10#$sequence == expected)) || return 83
    [[ "$payload" == "${DALO_BENCH_PAYLOAD:0:${#payload}}" ]] || return 84
    DALO_BENCH_ACK_COUNT="$expected"
    DALO_BENCH_ACK_BYTES=$((DALO_BENCH_ACK_BYTES + ${#payload}))
    DALO_BENCH_ACK_LAST="$sequence"
}
