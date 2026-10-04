#!/usr/bin/env bash
# Run bounded preliminary measurements over compiled recovery FIFO topology.
# Parameters: $1 repository root; $2 normal or retry; $3 output CSV path.
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
SCENARIO="${2:-normal}"
OUT="${3:-$ROOT/benchmarks/throughput/pilot-results.csv}"
[[ "$SCENARIO" == normal || "$SCENARIO" == retry ]] || exit 2
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
printf 'mode,scenario,workers_per_object,payload_bytes,messages,transfer_seconds,mib_per_second,messages_per_second,status\n' >"$OUT"
for size in 1 16 256; do
    python3 "$HERE/build.py" "$HERE" "$TMP/case" "$size"
    bash -n "$TMP/case/test.sh"
    echo "PILOT: mode=fifo size=$size scenario=$SCENARIO"
    if timeout 90 bash "$TMP/case/test.sh" "$ROOT" "$SCENARIO" >"$TMP/run.log" 2>&1; then
        grep -E '^(PHASE|METRIC|PASS):?' "$TMP/run.log" || true
        metric="$(grep '^METRIC:' "$TMP/run.log" | tail -1)"
        if [[ "$metric" =~ seconds=([0-9.]+).*MiBps=([0-9.]+).*msgps=([0-9.]+) ]]; then
            printf 'fifo,%s,1,%s,16,%s,%s,%s,PASS\n' "$SCENARIO" "$size" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >>"$OUT"
        else
            cat "$TMP/run.log" >&2; exit 1
        fi
    else
        cat "$TMP/run.log" >&2
        printf 'fifo,%s,1,%s,16,,,,FAIL\n' "$SCENARIO" "$size" >>"$OUT"
        exit 1
    fi
done
printf 'PILOT_DONE csv=%s\n' "$OUT"
