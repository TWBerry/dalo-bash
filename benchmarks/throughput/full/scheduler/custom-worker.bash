#!/usr/bin/env bash
# Custom benchmark scheduler worker. This is a bounded, cooperative dispatch
# component; the actual transport callback is supplied by the benchmark runner.
# It does not emulate delivery, acknowledgements, or parallel Bash processes.

# Initialize the scheduler's reusable state.
# Parameters: $1 number of dispatch lanes (1..4); $2 callback function name.
dalo_bench_scheduler_init() {
    local lanes="${1:-}" callback="${2:-}" i
    [[ "$lanes" =~ ^[1-4]$ ]] || return 64
    [[ "$callback" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]] || return 64
    declare -F "$callback" >/dev/null || return 66
    DALO_BENCH_SCHED_LANES="$lanes"
    DALO_BENCH_SCHED_CALLBACK="$callback"
    DALO_BENCH_SCHED_CURSOR=0
    DALO_BENCH_SCHED_SUBMITTED=0
    DALO_BENCH_SCHED_COMPLETED=0
    DALO_BENCH_SCHED_PENDING=0
    DALO_BENCH_SCHED_ACTIVE=1
    DALO_BENCH_SCHED_QUEUE=()
    DALO_BENCH_SCHED_LANE_COUNTS=()
    for ((i=0; i<lanes; i++)); do DALO_BENCH_SCHED_LANE_COUNTS[i]=0; done
}

# Queue one opaque benchmark frame without spawning any subprocess.
# Parameters: $1 opaque frame; empty frames are permitted.
dalo_bench_scheduler_submit() {
    [[ "${DALO_BENCH_SCHED_ACTIVE:-0}" == 1 && $# == 1 ]] || return 64
    DALO_BENCH_SCHED_QUEUE+=("$1")
    ((DALO_BENCH_SCHED_PENDING+=1))
    ((DALO_BENCH_SCHED_SUBMITTED+=1))
}

# Dispatch at most the requested number of queued frames, in round-robin order.
# Parameters: $1 maximum dispatches (positive integer); callback receives lane and frame.
# A failed callback leaves the frame queued for a bounded retry by the caller.
dalo_bench_scheduler_poll() {
    local budget="${1:-}" lane frame
    [[ "${DALO_BENCH_SCHED_ACTIVE:-0}" == 1 && "$budget" =~ ^[1-9][0-9]*$ ]] || return 64
    while ((budget > 0 && DALO_BENCH_SCHED_PENDING > 0)); do
        lane="$DALO_BENCH_SCHED_CURSOR"
        frame="${DALO_BENCH_SCHED_QUEUE[0]}"
        "$DALO_BENCH_SCHED_CALLBACK" "$lane" "$frame" || return
        DALO_BENCH_SCHED_QUEUE=("${DALO_BENCH_SCHED_QUEUE[@]:1}")
        DALO_BENCH_SCHED_PENDING=$((DALO_BENCH_SCHED_PENDING-1))
        ((DALO_BENCH_SCHED_COMPLETED+=1))
        ((DALO_BENCH_SCHED_LANE_COUNTS[lane]+=1))
        DALO_BENCH_SCHED_CURSOR=$(((lane+1)%DALO_BENCH_SCHED_LANES))
        budget=$((budget-1))
    done
}

# Verify all queued work has been dispatched and deactivate the scheduler.
# Parameters: none; return 75 if the runner has not drained the queue.
dalo_bench_scheduler_stop() {
    ((DALO_BENCH_SCHED_PENDING == 0)) || return 75
    DALO_BENCH_SCHED_ACTIVE=0
}
