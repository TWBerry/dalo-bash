#!/usr/bin/env bash
# Exercise bounded timeout and rejection of a stale ACK using generic runtime.
# Parameters: $1 repository root.
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
export DALO_LIBRARY_PATH="$ROOT/runtime"
source "$ROOT/runtime/library.sh"
include ack-fifo
TMP="$(mktemp -d)"
trap 'exec {fd}>&-; rm -rf -- "$TMP"' EXIT
mkfifo "$TMP/acks"
exec {fd}<>"$TMP/acks"
# A missing ACK must exhaust exactly one retry round and return 90.
retry_count=0
retry_probe() { ((retry_count+=1)); }
dalo_ack_fifo_send run client req1 true unused
declare -A pending=([req1]=1)
rc=0
dalo_ack_fifo_wait_pending run client "$fd" 0.05 1 pending retry_probe || rc=$?
[[ "$rc" == 90 && "$retry_count" == 1 ]]
printf 'PASS: bounded timeout, retry_rounds=%s\n' "$retry_count"
# An ACK with an unrelated request ID must be rejected, not credited.
dalo_ack_init
dalo_ack_fifo_send run client req1 true unused
pending=([req1]=1)
printf 'ACK|run|client|stale\n' >&"$fd"
rc=0
dalo_ack_fifo_wait_pending run client "$fd" 0.05 0 pending retry_probe || rc=$?
[[ "$rc" == 92 && "${pending[req1]}" == 1 ]]
printf 'PASS: stale ACK rejected, original request still pending\n'
dalo_library_fini_all
