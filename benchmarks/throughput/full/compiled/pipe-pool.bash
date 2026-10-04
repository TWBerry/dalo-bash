#!/usr/bin/env bash
# Independent persistent PIPE worker pool; its ACKs precede compiled ENDPOINT dispatch.
# The line protocol is deliberately restricted to nonempty printable ASCII tokens.
# It is a control-plane prototype, not the DIRECT or FIFO benchmark transport.

# Start one to four real persistent Bash workers and open reusable request/response FDs.
# Parameters: $1 worker count (1..4); $2 optional worker script path.
dalo_bench_pipe_pool_start() {
    local count="${1:-}" script="${2:-${BASH_SOURCE[0]%/*}/process-worker.bash}" i dir req resp ready
    [[ "$count" =~ ^[1-4]$ && -f "$script" ]] || return 64
    [[ "${DALO_BENCH_PIPE_POOL_ACTIVE:-0}" != 1 ]] || return 75
    dir="$(mktemp -d "${TMPDIR:-/tmp}/dalo-bench-workers.XXXXXXXX")" || return
    DALO_BENCH_PIPE_POOL_DIR="$dir" DALO_BENCH_PIPE_POOL_COUNT="$count"
    DALO_BENCH_PIPE_POOL_PIDS=() DALO_BENCH_PIPE_POOL_REQ=() DALO_BENCH_PIPE_POOL_RESP=()
    DALO_BENCH_PIPE_POOL_SENT=() DALO_BENCH_PIPE_POOL_RECEIVED=()
    for ((i=0;i<count;i++)); do
        mkfifo "$dir/request.$i" "$dir/response.$i" || { dalo_bench_pipe_pool_stop; return 74; }
        bash "$script" "$i" "$DALO_BENCH_PIPE_IMAGE" <"$dir/request.$i" >"$dir/response.$i" 2>"$dir/worker.$i.stderr" &
        DALO_BENCH_PIPE_POOL_PIDS[i]=$!
        exec {req}>"$dir/request.$i" || { dalo_bench_pipe_pool_stop; return 74; }
        exec {resp}<"$dir/response.$i" || { dalo_bench_pipe_pool_stop; return 74; }
        DALO_BENCH_PIPE_POOL_REQ[i]=$req DALO_BENCH_PIPE_POOL_RESP[i]=$resp
        DALO_BENCH_PIPE_POOL_SENT[i]=0 DALO_BENCH_PIPE_POOL_RECEIVED[i]=0
        # Do not dispatch work until the compiled MACHINE is fully loaded.
        # Parameter: response FD for the newly spawned worker.
        if ! IFS= read -r -t "${DALO_BENCH_PIPE_STARTUP_TIMEOUT:-30}" ready <&"$resp"; then
            printf 'PIPE worker %d startup failed (PID %s). Diagnostic output:\n' "$i" "${DALO_BENCH_PIPE_POOL_PIDS[i]}" >&2
            cat "$dir/worker.$i.stderr" >&2 || :
            dalo_bench_pipe_pool_stop
            return 75
        fi
        if [[ "$ready" != "READY" ]]; then
            printf 'PIPE worker %d sent invalid startup response: %q\n' "$i" "$ready" >&2
            cat "$dir/worker.$i.stderr" >&2 || :
            dalo_bench_pipe_pool_stop
            return 76
        fi
    done
    DALO_BENCH_PIPE_POOL_ACTIVE=1
}

# Queue one numbered frame for a persistent worker without waiting for its result.
# Parameters: $1 zero-based lane; $2 positive sequence number; $3 printable ASCII payload.
dalo_bench_pipe_pool_send() {
    local lane="${1:-}" seq="${2:-}" payload="${3-}" fd
    [[ "${DALO_BENCH_PIPE_POOL_ACTIVE:-0}" == 1 && "$lane" =~ ^[0-3]$ && "$seq" =~ ^[1-9][0-9]*$ ]] || return 64
    ((lane < DALO_BENCH_PIPE_POOL_COUNT)) || return 64
    [[ "$payload" =~ ^[a-zA-Z0-9_.-]*$ ]] || return 64
    fd="${DALO_BENCH_PIPE_POOL_REQ[lane]}"
    printf '%s\t%s\n' "$seq" "$payload" >&"$fd" || return 74
    ((DALO_BENCH_PIPE_POOL_SENT[lane]+=1))
}

# Receive the processed frame and validate the worker PID and sequence.
# Parameters: $1 zero-based lane; $2 expected positive sequence number.
dalo_bench_pipe_pool_receive() {
    local lane="${1:-}" expected="${2:-}" fd line seq pid result rest
    [[ "${DALO_BENCH_PIPE_POOL_ACTIVE:-0}" == 1 && "$lane" =~ ^[0-3]$ && "$expected" =~ ^[1-9][0-9]*$ ]] || return 64
    ((lane < DALO_BENCH_PIPE_POOL_COUNT)) || return 64
    fd="${DALO_BENCH_PIPE_POOL_RESP[lane]}"
    # Parameters: the response FD and configurable per-request timeout.
    if ! IFS= read -r -t "${DALO_BENCH_PIPE_RESPONSE_TIMEOUT:-30}" line <&"$fd"; then
        printf 'PIPE worker %d response timeout/EOF: expected seq=%s pid=%s\n' "$lane" "$expected" "${DALO_BENCH_PIPE_POOL_PIDS[lane]}" >&2
        if ! kill -0 "${DALO_BENCH_PIPE_POOL_PIDS[lane]}" 2>/dev/null; then
            printf 'PIPE worker %d is no longer alive\n' "$lane" >&2
        fi
        cat "$DALO_BENCH_PIPE_POOL_DIR/worker.$lane.stderr" >&2 || :
        return 75
    fi
    IFS=$'\t' read -r seq pid result rest <<<"$line"
    [[ "$seq" == "$expected" && "$pid" == "${DALO_BENCH_PIPE_POOL_PIDS[lane]}" && "$result" == "$expected|"* && -z "$rest" ]] || return 76
    DALO_BENCH_PIPE_RESULT="$result"
    ((DALO_BENCH_PIPE_POOL_RECEIVED[lane]+=1))
}

# Terminate all pool workers, close persistent FDs, and remove private FIFOs.
# Parameters: none. Safe to call after partial initialization.
dalo_bench_pipe_pool_stop() {
    local pid fd
    for pid in "${DALO_BENCH_PIPE_POOL_PIDS[@]}"; do kill "$pid" 2>/dev/null || :; done
    for fd in "${DALO_BENCH_PIPE_POOL_REQ[@]}"; do eval "exec ${fd}>&-"; done
    for fd in "${DALO_BENCH_PIPE_POOL_RESP[@]}"; do eval "exec ${fd}<&-"; done
    for pid in "${DALO_BENCH_PIPE_POOL_PIDS[@]}"; do wait "$pid" 2>/dev/null || :; done
    # Preserve diagnostic files after failure if explicitly requested.
    if [[ -n "${DALO_BENCH_PIPE_POOL_DIR:-}" ]]; then
        if [[ "${DALO_BENCH_PIPE_KEEP_LOGS:-0}" == 1 ]]; then
            printf 'PIPE worker logs: %s\n' "$DALO_BENCH_PIPE_POOL_DIR" >&2
        else
            rm -rf -- "$DALO_BENCH_PIPE_POOL_DIR"
        fi
    fi
    DALO_BENCH_PIPE_POOL_ACTIVE=0
    DALO_BENCH_PIPE_POOL_DIR=""
}

# Start a separate pool of PIPE workers, leaving ENDPOINT pool state independent.
# Parameters: $1 number of PIPE processes; $2 executable worker script path.
dalo_bench_pipe_start() {
    local count="$1" script="$2" i
    dalo_bench_pipe_pool_start "$count" "$script" || return
    DALO_BENCH_PIPE_NEXT=0 DALO_BENCH_PIPE_PENDING=0
    DALO_BENCH_PIPE_SEQ=()
    for ((i=0;i<count;i++)); do DALO_BENCH_PIPE_SEQ[i]=0; done
}

# Receive the frame actually processed by a PIPE process and forward that result.
# Parameters: $1 zero-based PIPE worker lane with an outstanding request.
dalo_bench_pipe_receive() {
    local lane="$1" seq="${DALO_BENCH_PIPE_SEQ[$1]}" frame
    ((seq>0)) || return 76
    dalo_bench_pipe_pool_receive "$lane" "$seq" || return
    frame="$DALO_BENCH_PIPE_RESULT"
    DALO_BENCH_PIPE_SEQ[lane]=0
    ((DALO_BENCH_PIPE_PENDING-=1))
    "${DALO_BENCH_ENDPOINT_NS}_summon_worker" in "$frame"
}

# Submit a complete PIPE frame for execution inside its persistent worker process.
# Parameters: $1 complete sequence|payload frame from the compiled PIPE object.
dalo_bench_pipe_submit() {
    local frame="$1" seq lane="$DALO_BENCH_PIPE_NEXT"
    [[ "$frame" == *'|'* ]] || return 81
    seq="${frame%%|*}"
    [[ "$seq" =~ ^[1-9][0-9]*$ ]] || return 82
    if ((DALO_BENCH_PIPE_SEQ[lane]>0)); then
        dalo_bench_pipe_receive "$lane" || return
    fi
    dalo_bench_pipe_pool_send "$lane" "$seq" "${frame/|/_}" || return
    DALO_BENCH_PIPE_SEQ[lane]="$seq"
    ((DALO_BENCH_PIPE_PENDING+=1))
    DALO_BENCH_PIPE_NEXT=$(((lane+1)%DALO_BENCH_PIPE_POOL_COUNT))
}

# Drain processed PIPE results and forward the remaining frames to ENDPOINT.
# Parameters: none; propagates ACK and dispatch failures.
dalo_bench_pipe_flush() {
    local i
    for ((i=0;i<DALO_BENCH_PIPE_POOL_COUNT;i++)); do
        if ((DALO_BENCH_PIPE_SEQ[i]>0)); then
            dalo_bench_pipe_receive "$i" || return
        fi
    done
}
