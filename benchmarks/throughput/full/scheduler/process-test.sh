#!/usr/bin/env bash
# Validate persistent real-process pool, PID identity, dispatch and exact ACKs.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$here/custom-worker.bash"
source "$here/process-pool.bash"
trap 'dalo_bench_pool_stop 2>/dev/null || :' EXIT
# Route scheduler dispatch into real persistent worker request descriptors.
# Parameters: $1 selected lane; $2 opaque benchmark frame.
submit_to_pool() {
    local lane="$1" frame="$2" seq="${frame#msg-}"
    dalo_bench_pool_send "$lane" "$((seq+1))" "$frame"
}
for lanes in 1 2 3 4; do
    dalo_bench_pool_start "$lanes" "$here/process-worker.bash"
    dalo_bench_scheduler_init "$lanes" submit_to_pool
    for ((i=0;i<32;i++)); do dalo_bench_scheduler_submit "msg-$i"; done
    dalo_bench_scheduler_poll 32
    [[ "$DALO_BENCH_SCHED_PENDING" == 0 ]]
    for ((i=0;i<32;i++)); do dalo_bench_pool_receive "$((i%lanes))" "$((i+1))"; done
    for ((i=0;i<lanes;i++)); do
        [[ "${DALO_BENCH_POOL_SENT[i]}" == "${DALO_BENCH_POOL_RECEIVED[i]}" ]]
        kill -0 "${DALO_BENCH_POOL_PIDS[i]}"
    done
    dalo_bench_scheduler_stop
    dalo_bench_pool_stop
    echo "PASS: real persistent Bash workers=$lanes messages=32 exact ACKs=32"
done
