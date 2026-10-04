#!/usr/bin/env bash
# Compile and exercise explicit child ACK transport with two concurrent senders.
# Parameters: $1 DALO repository root; $2 optional fault scenario (normal/drop).
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
SCENARIO="${2:-normal}"
[[ "$SCENARIO" == normal || "$SCENARIO" == drop ]]
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cp "$HERE"/{probe.dalo,relay.bash,endpoint.bash} "$TMP/"
cp "$ROOT/benchmarks/parent-dispatch/noop.bash" "$TMP/noop.bash"
bash "$ROOT/compiler/daloc.bash" "$TMP/probe.dalo" >/dev/null
source "$TMP/async_ack_probe.dalo.bash"
DALO_ASYNC_PIPE_NS='' DALO_ASYNC_ENDPOINT_NS=''
for name_var in $(compgen -A variable); do
    [[ "$name_var" == *_OBJECT_NAME ]] || continue
    case "${!name_var:-}" in
        pipe) DALO_ASYNC_PIPE_NS="${name_var%_OBJECT_NAME}" ;;
        endpoint) DALO_ASYNC_ENDPOINT_NS="${name_var%_OBJECT_NAME}" ;;
    esac
done
[[ -n "$DALO_ASYNC_PIPE_NS" && -n "$DALO_ASYNC_ENDPOINT_NS" ]]
DALO_ASYNC_BATCHES=8 DALO_ASYNC_PAYLOAD=abcdefghijklmnop
DALO_ASYNC_RECEIVED=0 DALO_ASYNC_BYTES=0
declare -A DALO_ASYNC_SEEN=()
[[ "$SCENARIO" != drop ]] || DALO_ASYNC_DROP_ACK=2:4
mkfifo "$TMP/ack1" "$TMP/ack2"
exec {DALO_ASYNC_ACK_FD_1}<>"$TMP/ack1"
exec {DALO_ASYNC_ACK_FD_2}<>"$TMP/ack2"
# Each child queues all frames before waiting for acknowledgments; parent drains concurrently.
# Parameters: $1 client ID; $2 inherited ACK file descriptor.
async_sender() {
    local client="$1" fd="$2" i line ack_client ack_seq
    local -A acknowledged=()
    for ((i=1;i<=DALO_ASYNC_BATCHES;i++)); do
        "${DALO_ASYNC_PIPE_NS}_fifo_send" P pipe endpoint "$client|$i|$DALO_ASYNC_PAYLOAD" || return
    done
    for ((i=1;i<=DALO_ASYNC_BATCHES;i++)); do
        if ! IFS= read -r -t 4 -u "$fd" line; then
            printf 'ACK_TIMEOUT client=%s received=%s/%s\n' "$client" "${#acknowledged[@]}" "$DALO_ASYNC_BATCHES" >&2
            return 90
        fi
        [[ "$line" =~ ^ACK\|([12])\|([1-9][0-9]*)$ ]] || return 91
        ack_client="${BASH_REMATCH[1]}" ack_seq="${BASH_REMATCH[2]}"
        [[ "$ack_client" == "$client" && "$ack_seq" -le "$DALO_ASYNC_BATCHES" ]] || return 92
        [[ -z "${acknowledged[$ack_seq]+present}" ]] || return 93
        acknowledged["$ack_seq"]=1
    done
    printf 'CHILD_ACK_PASS client=%s count=%s\n' "$client" "${#acknowledged[@]}"
}
async_sender 1 "$DALO_ASYNC_ACK_FD_1" >"$TMP/child1.log" 2>"$TMP/child1.err" & pid1=$!
async_sender 2 "$DALO_ASYNC_ACK_FD_2" >"$TMP/child2.log" 2>"$TMP/child2.err" & pid2=$!
# Bounded parent event loop. Never wait for children before draining their FIFO.
for ((attempt=0;attempt<1000;attempt++)); do
    if ! "${DALO_ASYNC_PIPE_NS}_drain_fifo"; then
        echo 'FAIL: parent relay' >&2; exit 1
    fi
    ((DALO_ASYNC_RECEIVED == 16)) && break
    sleep 0.005
done
rc1=0 rc2=0
wait "$pid1" || rc1=$?
wait "$pid2" || rc2=$?
if [[ "$SCENARIO" == drop ]]; then
    [[ "$rc2" == 90 ]] || { echo "FAIL: expected timeout, got $rc2" >&2; exit 1; }
    grep -q 'ACK_TIMEOUT client=2' "$TMP/child2.err"
    echo 'PASS: dropped ACK detected by child timeout'
else
    [[ "$rc1" == 0 && "$rc2" == 0 && "$DALO_ASYNC_RECEIVED" == 16 && "$DALO_ASYNC_BYTES" == 256 ]] || {
        cat "$TMP"/child*.err >&2; echo "FAIL: rc1=$rc1 rc2=$rc2 received=$DALO_ASYNC_RECEIVED" >&2; exit 1;
    }
    cat "$TMP"/child*.log
    echo 'PASS: 2 concurrent child senders -> FIFO -> ENDPOINT -> 16 explicit ACKs, 256 bytes'
fi
