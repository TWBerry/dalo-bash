#!/usr/bin/env bash
# Experimental compiled ORIGIN -> PIPE -> ENDPOINT FIFO and ACK integration.
# This test is not yet validated end-to-end; run with a bounded timeout.
# Parameters: $1 repository root; $2 scenario: normal or retry.
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
SCENARIO="${2:-normal}"
[[ "$SCENARIO" == normal || "$SCENARIO" == retry ]] || { echo 'usage: test.sh ROOT [normal|retry]' >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
# Emit monotonic-style elapsed phase stamps using Bash EPOCHREALTIME.
# Parameters: $1 phase label.
phase() { printf "PHASE %s wall=%s\n" "$1" "${EPOCHREALTIME:-unknown}"; }
phase compile_start
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cp "$HERE"/{probe.dalo,relay.bash,endpoint.bash,origin.bash,pipe.bash} "$TMP/"
cp "$ROOT/benchmarks/parent-dispatch/noop.bash" "$TMP/noop.bash"
bash "$ROOT/compiler/daloc.bash" "$TMP/probe.dalo" >/dev/null
phase compile_done
source "$TMP/compiled_ack_topology.dalo.bash"
export DALO_LIBRARY_PATH="$ROOT/runtime"
source "$ROOT/runtime/library.sh"
include ack-fifo
DALO_BENCH_INSTANCE="run${BASHPID}"
DALO_ACK_PIPE_NS='' DALO_ACK_ENDPOINT_NS='' DALO_ACK_ORIGIN_NS=''
for name_var in $(compgen -A variable); do
    [[ "$name_var" == *_OBJECT_NAME ]] || continue
    case "${!name_var:-}" in
        origin) DALO_ACK_ORIGIN_NS="${name_var%_OBJECT_NAME}" ;;
        pipe) DALO_ACK_PIPE_NS="${name_var%_OBJECT_NAME}" ;;
        endpoint) DALO_ACK_ENDPOINT_NS="${name_var%_OBJECT_NAME}" ;;
    esac
done
[[ -n "$DALO_ACK_ORIGIN_NS" && -n "$DALO_ACK_PIPE_NS" && -n "$DALO_ACK_ENDPOINT_NS" ]]
# Exercise the generated ORIGIN async pool, its parent-side reap hook and
# actual scheduler slot reuse before sending requests through the topology.
# Parameters: $1 worker directory; $2 slot; $3+ ignored test arguments.
blocked_origin_worker() { exec sleep 30; }
# Complete a replacement in the same generated ORIGIN pool slot.
# Parameters: $1 worker directory; $2 slot; $3+ ignored test arguments.
replacement_origin_worker() { printf 'replaced:%s\n' "$2" >"$TMP/replacement.done"; }
phase kill_start
"${DALO_ACK_ORIGIN_NS}_job_pool_submit_port" in blocked_origin_worker '' blocked
origin_pids="${DALO_ACK_ORIGIN_NS}_WORKER_PIDS"
origin_pending="${DALO_ACK_ORIGIN_NS}_PENDING_JOBS"
origin_status="${DALO_ACK_ORIGIN_NS}_JOB_STATUS_VECTOR"
local_pid=''
# Read the PID from the actual generated pool, never from a test-created child.
# Indexed array access through a Bash nameref preserves generated namespace.
declare -n recovery_pids="$origin_pids" recovery_pending="$origin_pending" recovery_status="$origin_status"
local_pid="${recovery_pids[1]:-}"
[[ -n "$local_pid" ]] || { echo 'FAIL: generated pool did not start child' >&2; exit 1; }
dalo_ack_register recovery recoveryclient request1
dalo_ack_register recovery recoveryclient request2
dalo_ack_endpoint_accept recovery recoveryclient request1 payload
dalo_ack_fifo_bind_child_pid "$local_pid" recovery recoveryclient
kill -KILL "$local_pid"
# ORIGIN generates a no-op job_pool_wait; reap its actual pool child explicitly.
# Parameters: none; the generated reap_one owns the active ORIGIN slot.
"${DALO_ACK_ORIGIN_NS}_reap_one"
# Diagnose independent ACK and scheduler invariants after the real child reap.
# Parameters: none; reads the generated pool namespace and parent-owned ACK state.
recovery_diagnostics() {
    local key
    printf 'DIAG: pool_pending=%s ack_pending=%s slot_pid=%s slot_status=%s reaped_pid=%s\n' \
        "${!origin_pending}" "${#DALO_ACK_PENDING[@]}" \
        "${recovery_pids[1]:-<empty>}" "${recovery_status[1]:-<empty>}" \
        "${DALO_ACK_ORIGIN_NS}_REAPED_PIDS"
    local reaped_name="${DALO_ACK_ORIGIN_NS}_REAPED_PIDS"
    declare -n reaped_array="$reaped_name"
    printf 'DIAG: reaped_pid_value=%s hook_notified=%s hook_registered=%s\n' \
        "${reaped_array[1]:-<empty>}" \
        "${DALO_CHILD_REAP_NOTIFIED[$local_pid]:-<empty>}" \
        "${DALO_CHILD_REAP_CALLBACK[$local_pid]:-<empty>}"
    for key in "${!DALO_ACK_PENDING[@]}"; do
        printf 'DIAG: pending_key=%s state=%s\n' "$key" "${DALO_ACK_PENDING[$key]}"
    done
}
recovery_diagnostics
[[ "${!origin_pending}" == 0 ]] || { echo 'FAIL: scheduler slot not released' >&2; exit 1; }
[[ ${#DALO_ACK_PENDING[@]} == 0 ]] || { echo 'FAIL: ACK cancellation not completed' >&2; exit 1; }
[[ "${recovery_status[1]}" == ABNORMAL_TERMINATION && -z "${recovery_pids[1]:-}" ]] || { echo 'FAIL: abnormal status or slot not released' >&2; exit 1; }
[[ -v DALO_ACK_APPLIED[recovery:recoveryclient:request1] ]] || { echo 'FAIL: dedup lost' >&2; exit 1; }
late_rc=0
dalo_ack_confirm recovery recoveryclient request1 || late_rc=$?
[[ "$late_rc" == 4 ]] || { echo 'FAIL: late ACK accepted' >&2; exit 1; }
phase killed_and_reaped
"${DALO_ACK_ORIGIN_NS}_job_pool_submit_port" in replacement_origin_worker '' replacement
"${DALO_ACK_ORIGIN_NS}_reap_one"
[[ "${recovery_status[1]}" == SUCCESS && "$(cat "$TMP/replacement.done")" == replaced:1 ]] || { echo 'FAIL: replacement' >&2; exit 1; }
phase replacement_done

DALO_ACK_BATCHES=8 DALO_ACK_PAYLOAD=abcdefghijklmnop
DALO_ACK_RECEIVED=0 DALO_ACK_BYTES=0 DALO_ACK_DUPLICATES=0
DALO_ACK_SCENARIO="$SCENARIO"
declare -A DALO_ACK_SEEN=() DALO_ACK_DROPPED=()
mkfifo "$TMP/ack1" "$TMP/ack2"
exec {DALO_ACK_FD_1}<>"$TMP/ack1"
exec {DALO_ACK_FD_2}<>"$TMP/ack2"
# Each child sends all requests, then retransmits only unacknowledged IDs.
# Parameters: $1 client identity; $2 inherited ACK FD; $3 scenario.
ack_sender() {
    local client="$1" fd="$2" scenario="$3" i line ack_client ack_id attempts=0
    dalo_ack_init
    local -A pending=()
    for ((i=1;i<=DALO_ACK_BATCHES;i++)); do
        pending["$i"]=1
        dalo_ack_fifo_send "$DALO_BENCH_INSTANCE" "$client" "$i" "${DALO_ACK_ORIGIN_NS}_summon_worker" out "$DALO_BENCH_INSTANCE|$client|$i|$DALO_ACK_PAYLOAD" || return
    done
    # Generic library owns timeout, ACK validation and bounded retries.
    dalo_ack_fifo_wait_pending "$DALO_BENCH_INSTANCE" "$client" "$fd" 0.5 2 pending ack_resend "$client" || return
    attempts="$DALO_ACK_FIFO_RETRY_ROUNDS"
    printf 'CHILD_ACK_PASS client=%s count=%s retries=%s\n' "$client" "$DALO_ACK_BATCHES" "$attempts"
}
# Retransmit one request with its original identity and payload.
# Parameters: $1 request ID; $2 client identity.
ack_resend() {
    local request_id="$1" client="$2"
    dalo_ack_fifo_retry "$DALO_BENCH_INSTANCE" "$client" "$request_id" "${DALO_ACK_ORIGIN_NS}_summon_worker" out "$DALO_BENCH_INSTANCE|$client|$request_id|$DALO_ACK_PAYLOAD"
}
phase transfer_start
ack_sender 1 "$DALO_ACK_FD_1" "$SCENARIO" >"$TMP/child1.log" 2>"$TMP/child1.err" & pid1=$!
ack_sender 2 "$DALO_ACK_FD_2" "$SCENARIO" >"$TMP/child2.log" 2>"$TMP/child2.err" & pid2=$!
# Drain the real PIPE FIFO while children wait on their own ACK descriptors.
# Parameters: none.
for ((attempt=0;attempt<1200;attempt++)); do
    "${DALO_ACK_PIPE_NS}_drain_fifo" || { echo 'FAIL: parent relay' >&2; exit 1; }
    if ((DALO_ACK_RECEIVED == 16)); then
        if [[ "$SCENARIO" == normal || "$DALO_ACK_DUPLICATES" -ge 1 ]]; then break; fi
    fi
    sleep 0.005
done
rc1=0 rc2=0
phase drain_done
wait "$pid1" || rc1=$?
wait "$pid2" || rc2=$?
[[ "$rc1" == 0 && "$rc2" == 0 && "$DALO_ACK_RECEIVED" == 16 && "$DALO_ACK_BYTES" == 256 ]] || {
    cat "$TMP"/child*.err >&2
    printf 'FAIL: rc1=%s rc2=%s received=%s duplicates=%s\n' "$rc1" "$rc2" "$DALO_ACK_RECEIVED" "$DALO_ACK_DUPLICATES" >&2
    exit 1
}
if [[ "$SCENARIO" == retry ]]; then
    [[ "${DALO_ACK_DROPPED[2:4]+present}" && "$DALO_ACK_DUPLICATES" -ge 1 ]] || { echo 'FAIL: retry not observed' >&2; exit 1; }
else
    ((DALO_ACK_DUPLICATES == 0)) || { echo 'FAIL: unexpected duplicates' >&2; exit 1; }
fi
phase transfer_done
cat "$TMP"/child*.log
dalo_library_fini_all
printf 'PASS: compiled recovery + scenario=%s unique=%s bytes=%s duplicates=%s\n' "$SCENARIO" "$DALO_ACK_RECEIVED" "$DALO_ACK_BYTES" "$DALO_ACK_DUPLICATES"
