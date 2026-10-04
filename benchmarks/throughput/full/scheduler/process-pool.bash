#!/usr/bin/env bash
# Persistent process-backed scheduler adapter for correctness and lifecycle tests.
# The line protocol is deliberately restricted to nonempty printable ASCII tokens.
# It is a control-plane prototype, not the DIRECT or FIFO benchmark transport.

# Start one to four real persistent Bash workers and open reusable request/response FDs.
# Parameters: $1 worker count (1..4); $2 optional worker script path.
dalo_bench_pool_start() {
    local count="${1:-}" script="${2:-${BASH_SOURCE[0]%/*}/process-worker.bash}" i dir
    [[ "$count" =~ ^[1-4]$ && -f "$script" ]] || return 64
    [[ "${DALO_BENCH_POOL_ACTIVE:-0}" != 1 ]] || return 75
    dir="$(mktemp -d "${TMPDIR:-/tmp}/dalo-bench-workers.XXXXXXXX")" || return
    DALO_BENCH_POOL_DIR="$dir" DALO_BENCH_POOL_COUNT="$count"
    DALO_BENCH_POOL_PIDS=() DALO_BENCH_POOL_REQ=() DALO_BENCH_POOL_RESP=()
    DALO_BENCH_POOL_SENT=() DALO_BENCH_POOL_RECEIVED=()
    for ((i=0;i<count;i++)); do
        mkfifo "$dir/request.$i" "$dir/response.$i" || { dalo_bench_pool_stop; return 74; }
        bash "$script" "$i" <"$dir/request.$i" >"$dir/response.$i" &
        DALO_BENCH_POOL_PIDS[i]=$!
        exec {req}>"$dir/request.$i" || { dalo_bench_pool_stop; return 74; }
        exec {resp}<"$dir/response.$i" || { dalo_bench_pool_stop; return 74; }
        DALO_BENCH_POOL_REQ[i]=$req DALO_BENCH_POOL_RESP[i]=$resp
        DALO_BENCH_POOL_SENT[i]=0 DALO_BENCH_POOL_RECEIVED[i]=0
    done
    DALO_BENCH_POOL_ACTIVE=1
}

# Queue one numbered message for an existing persistent worker without waiting for ACK.
# Parameters: $1 zero-based lane; $2 positive sequence number; $3 printable ASCII payload.
dalo_bench_pool_send() {
    local lane="${1:-}" seq="${2:-}" payload="${3-}" fd
    [[ "${DALO_BENCH_POOL_ACTIVE:-0}" == 1 && "$lane" =~ ^[0-3]$ && "$seq" =~ ^[1-9][0-9]*$ ]] || return 64
    ((lane < DALO_BENCH_POOL_COUNT)) || return 64
    [[ "$payload" =~ ^[a-zA-Z0-9_.-]*$ ]] || return 64
    fd="${DALO_BENCH_POOL_REQ[lane]}"
    printf '%s\t%s\n' "$seq" "$payload" >&"$fd" || return 74
    ((DALO_BENCH_POOL_SENT[lane]+=1))
}

# Receive one ACK from the specified worker and validate its sequence and PID.
# Parameters: $1 zero-based lane; $2 expected positive sequence number.
dalo_bench_pool_receive() {
    local lane="${1:-}" expected="${2:-}" fd line seq pid rest
    [[ "${DALO_BENCH_POOL_ACTIVE:-0}" == 1 && "$lane" =~ ^[0-3]$ && "$expected" =~ ^[1-9][0-9]*$ ]] || return 64
    ((lane < DALO_BENCH_POOL_COUNT)) || return 64
    fd="${DALO_BENCH_POOL_RESP[lane]}"
    IFS= read -r -t 5 line <&"$fd" || return 75
    IFS=$'\t' read -r seq pid rest <<<"$line"
    [[ "$seq" == "$expected" && "$pid" == "${DALO_BENCH_POOL_PIDS[lane]}" && -z "$rest" ]] || return 76
    ((DALO_BENCH_POOL_RECEIVED[lane]+=1))
}

# Terminate all pool workers, close persistent FDs, and remove private FIFOs.
# Parameters: none. Safe to call after partial initialization.
dalo_bench_pool_stop() {
    local pid fd
    for pid in "${DALO_BENCH_POOL_PIDS[@]}"; do kill "$pid" 2>/dev/null || :; done
    for fd in "${DALO_BENCH_POOL_REQ[@]}"; do eval "exec ${fd}>&-"; done
    for fd in "${DALO_BENCH_POOL_RESP[@]}"; do eval "exec ${fd}<&-"; done
    for pid in "${DALO_BENCH_POOL_PIDS[@]}"; do wait "$pid" 2>/dev/null || :; done
    [[ -z "${DALO_BENCH_POOL_DIR:-}" ]] || rm -rf -- "$DALO_BENCH_POOL_DIR"
    DALO_BENCH_POOL_ACTIVE=0
    DALO_BENCH_POOL_DIR=""
}
