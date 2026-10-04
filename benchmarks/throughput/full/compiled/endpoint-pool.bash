#!/usr/bin/env bash
# Connect the compiled ENDPOINT worker to persistent Bash processes via reusable FDs.
# The worker control FIFO is NOT the benchmark's measured ORIGIN transport.

# Initialize the endpoint worker pool and per-lane outstanding request tracking.
# Parameters: $1 number of persistent endpoint processes (1..4); $2 worker script path.
dalo_bench_endpoint_start() {
    local count="$1" script="$2" i
    dalo_bench_pool_start "$count" "$script" || return
    DALO_BENCH_ENDPOINT_NEXT=0
    DALO_BENCH_ENDPOINT_PENDING=0
    DALO_BENCH_ENDPOINT_SEQ=()
    for ((i=0;i<count;i++)); do DALO_BENCH_ENDPOINT_SEQ[i]=0; done
}

# Collect an exact acknowledgment from a lane and update parent-owned delivery counters.
# Parameters: $1 zero-based worker lane with one outstanding request.
dalo_bench_endpoint_receive() {
    local lane="$1" seq="${DALO_BENCH_ENDPOINT_SEQ[$1]}"
    ((seq>0)) || return 76
    dalo_bench_pool_receive "$lane" "$seq" || return
    DALO_BENCH_ENDPOINT_SEQ[lane]=0
    ((DALO_BENCH_ENDPOINT_PENDING-=1))
    ((DALO_BENCH_RECEIVED+=1))
    ((DALO_BENCH_BYTES+=DALO_BENCH_SIZE))
}

# Dispatch one validated frame to a persistent endpoint process in round-robin order.
# Parameters: $1 unique positive sequence number; payload was validated by compiled worker.
dalo_bench_endpoint_submit() {
    local seq="$1" lane="$DALO_BENCH_ENDPOINT_NEXT"
    if ((DALO_BENCH_ENDPOINT_SEQ[lane]>0)); then
        dalo_bench_endpoint_receive "$lane" || return
    fi
    dalo_bench_pool_send "$lane" "$seq" "msg-$seq" || return
    DALO_BENCH_ENDPOINT_SEQ[lane]="$seq"
    ((DALO_BENCH_ENDPOINT_PENDING+=1))
    DALO_BENCH_ENDPOINT_NEXT=$(((lane+1)%DALO_BENCH_POOL_COUNT))
}

# Drain all outstanding endpoint acknowledgments after the current transport burst.
# Parameters: none; returns failure if any worker fails, times out, or mismatches its ACK.
dalo_bench_endpoint_flush() {
    local i
    for ((i=0;i<DALO_BENCH_POOL_COUNT;i++)); do
        if ((DALO_BENCH_ENDPOINT_SEQ[i]>0)); then
            dalo_bench_endpoint_receive "$i" || return
        fi
    done
}
