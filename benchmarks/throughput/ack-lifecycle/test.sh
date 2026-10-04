#!/usr/bin/env bash
# Validate worker cancellation during ACK wait and rejection of late ACKs.
# Parameters: $1 repository root containing runtime libraries.
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
export DALO_LIBRARY_PATH="$ROOT/runtime"
source "$ROOT/runtime/library.sh"
include ack-fifo
TMP="$(mktemp -d)"
child_pid=''
cleanup() {
    # Stop a still-running child and remove only this test's temporary files.
    # Parameters: none.
    if [[ -n "$child_pid" ]]; then kill "$child_pid" 2>/dev/null || :; wait "$child_pid" 2>/dev/null || :; fi
    rm -rf -- "$TMP"
}
trap cleanup EXIT
mkfifo "$TMP/acks"
# Run a real child with its own ACK bookkeeping and cancellation signal trap.
# Parameters: none; inherited ROOT and FIFO path are read from the parent.
child_main() {
    source "$ROOT/runtime/library.sh"
    include ack-fifo
    exec {ack_fd}<>"$TMP/acks"
    DALO_ACK_FIFO_CANCELLED=0
    trap 'DALO_ACK_FIFO_CANCELLED=1' TERM
    dalo_ack_fifo_send run child req1 true unused
    dalo_ack_fifo_send run child req2 true unused
    local -A pending=([req1]=1 [req2]=1)
    : > "$TMP/ready"
    local rc=0
    dalo_ack_fifo_wait_pending run child "$ack_fd" 0.1 50 pending true || rc=$?
    [[ "$rc" == 93 && "${#pending[@]}" == 0 && "${#DALO_ACK_PENDING[@]}" == 0 ]] || return 1
    printf 'PASS: worker cancelled, no pending requests\n' > "$TMP/child-result"
    # Even an ACK arriving after cancellation must not revive the request.
    local late_rc=0
    dalo_ack_fifo_receive run child 'ACK|run|child|req1' || late_rc=$?
    [[ "$late_rc" == 4 ]] || return 1
    printf 'PASS: late ACK rejected after worker cancellation\n' >> "$TMP/child-result"
    exec {ack_fd}>&-
    dalo_library_fini_all
}
child_main >"$TMP/child.log" 2>"$TMP/child.err" & child_pid=$!
for ((i=0;i<200;i++)); do [[ -f "$TMP/ready" ]] && break; sleep 0.01; done
[[ -f "$TMP/ready" ]] || { echo 'FAIL: child did not become ready' >&2; exit 1; }
kill -TERM "$child_pid"
wait "$child_pid" || { cat "$TMP/child.err" >&2; exit 1; }
child_pid=''
cat "$TMP/child-result"
# The endpoint must retain deduplication state while other retries can exist.
dalo_ack_endpoint_accept run child req1 fingerprint
dalo_ack_cancel_client run child
[[ "${DALO_ACK_APPLIED[run:child:req1]}" == fingerprint ]]
dalo_ack_close_instance run
[[ "${#DALO_ACK_APPLIED[@]}" == 0 ]]
printf 'PASS: endpoint dedup retained until explicit instance close\n'
dalo_library_fini_all
