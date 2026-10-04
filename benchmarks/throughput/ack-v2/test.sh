#!/usr/bin/env bash
# Exercise request identity, ENDPOINT deduplication, and bounded ACK retry.
# Parameters: $1 repository root; $2 scenario: normal or retry.
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
SCENARIO="${2:-normal}"
[[ "$SCENARIO" == normal || "$SCENARIO" == retry ]] || { echo 'usage: test.sh ROOT [normal|retry]' >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cp "$HERE"/{probe.dalo,relay.bash,endpoint.bash} "$TMP/"
cp "$ROOT/benchmarks/parent-dispatch/noop.bash" "$TMP/noop.bash"
bash "$ROOT/compiler/daloc.bash" "$TMP/probe.dalo" >/dev/null
source "$TMP/async_ack_probe.dalo.bash"
DALO_ACK_PIPE_NS='' DALO_ACK_ENDPOINT_NS=''
for name_var in $(compgen -A variable); do
    [[ "$name_var" == *_OBJECT_NAME ]] || continue
    case "${!name_var:-}" in
        pipe) DALO_ACK_PIPE_NS="${name_var%_OBJECT_NAME}" ;;
        endpoint) DALO_ACK_ENDPOINT_NS="${name_var%_OBJECT_NAME}" ;;
    esac
done
[[ -n "$DALO_ACK_PIPE_NS" && -n "$DALO_ACK_ENDPOINT_NS" ]]
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
    local -A pending=()
    for ((i=1;i<=DALO_ACK_BATCHES;i++)); do
        pending["$i"]=1
        "${DALO_ACK_PIPE_NS}_fifo_send" P pipe endpoint "$client|$i|$DALO_ACK_PAYLOAD" || return
    done
    while ((${#pending[@]})); do
        if IFS= read -r -t 0.5 -u "$fd" line; then
            [[ "$line" =~ ^ACK\|([12])\|([1-9][0-9]*)$ ]] || return 91
            ack_client="${BASH_REMATCH[1]}" ack_id="${BASH_REMATCH[2]}"
            [[ "$ack_client" == "$client" && -n "${pending[$ack_id]+present}" ]] || return 92
            unset 'pending[$ack_id]'
            continue
        fi
        ((attempts+=1))
        if ((attempts > 2)); then
            printf 'ACK_TIMEOUT client=%s pending=%s\n' "$client" "${#pending[@]}" >&2
            return 90
        fi
        for i in "${!pending[@]}"; do
            "${DALO_ACK_PIPE_NS}_fifo_send" P pipe endpoint "$client|$i|$DALO_ACK_PAYLOAD" || return
        done
    done
    printf 'CHILD_ACK_PASS client=%s count=%s retries=%s\n' "$client" "$DALO_ACK_BATCHES" "$attempts"
}
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
cat "$TMP"/child*.log
printf 'PASS: scenario=%s unique=%s bytes=%s duplicates=%s\n' "$SCENARIO" "$DALO_ACK_RECEIVED" "$DALO_ACK_BYTES" "$DALO_ACK_DUPLICATES"
