#!/usr/bin/env bash
# Verify bounded dispatch, FIFO ordering, round-robin lanes, failure retention,
# and exact counters without starting a benchmark transport.
set -euo pipefail
source "$(dirname "$0")/custom-worker.bash"
observed=()
fail_once=0
receive() {
    local lane="$1" frame="$2"
    if ((fail_once)); then fail_once=0; return 73; fi
    observed+=("$lane:$frame")
}
for lanes in 1 2 3 4; do
    observed=()
    dalo_bench_scheduler_init "$lanes" receive
    for ((i=0;i<17;i++)); do dalo_bench_scheduler_submit "msg-$i"; done
    dalo_bench_scheduler_poll 4
    [[ "$DALO_BENCH_SCHED_PENDING" == 13 && "$DALO_BENCH_SCHED_COMPLETED" == 4 ]]
    if dalo_bench_scheduler_stop; then echo 'FAIL: stopped with pending work'; exit 1; fi
    fail_once=1
    if dalo_bench_scheduler_poll 1; then echo 'FAIL: callback failure lost'; exit 1; fi
    [[ "$DALO_BENCH_SCHED_PENDING" == 13 ]]
    dalo_bench_scheduler_poll 20
    [[ "$DALO_BENCH_SCHED_PENDING" == 0 && "$DALO_BENCH_SCHED_COMPLETED" == 17 ]]
    for ((i=0;i<17;i++)); do
        [[ "${observed[i]}" == "$((i%lanes)):msg-$i" ]]
    done
    dalo_bench_scheduler_stop
    echo "PASS: lanes=$lanes dispatched=17 ordered round-robin failure-retained"
done
