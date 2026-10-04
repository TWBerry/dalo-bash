#!/usr/bin/env bash
# Run repeated FIFO transfer-only measurements with one compilation per payload size.
# Parameters: $1 repository root; $2 output CSV; $3 repetitions (default 3).
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
OUT="${2:-$ROOT/pilot-v2.csv}"
REPS="${3:-3}"
[[ "$REPS" =~ ^[1-9][0-9]*$ ]] || { echo 'FAIL: repetitions must be positive' >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
PILOT="$ROOT/benchmarks/throughput/pilot"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
printf 'mode,scenario,payload_bytes,repetition,clients,messages,transfer_seconds,mib_per_second,messages_per_second,status\n' > "$OUT"
for size in 1 16 256; do
    case_dir="$TMP/size-$size"
    python3 "$PILOT/build.py" "$PILOT" "$case_dir" "$size"
    # This case must be generated from the already validated pilot-v1 test.
    # It is then adapted to skip both compilation and destructive recovery.
    python3 "$HERE/prepare.py" "$case_dir/test.sh"
    bash -n "$case_dir/test.sh"
    printf 'PILOT_V2_COMPILE size=%s\n' "$size"
    timeout 90 bash "$ROOT/compiler/daloc.bash" "$case_dir/probe.dalo" >"$TMP/compile-$size.log" 2>&1 || {
        cat "$TMP/compile-$size.log" >&2; exit 1;
    }
    [[ -s "$case_dir/compiled_ack_topology.dalo.bash" ]] || {
        echo 'FAIL: compiled MACHINE missing' >&2; exit 1;
    }
    for scenario in normal retry; do
        for ((rep=1; rep<=REPS; rep++)); do
            printf 'PILOT_V2_RUN size=%s scenario=%s repetition=%s\n' "$size" "$scenario" "$rep"
            if DALO_PILOT_V2_COMPILED="$case_dir/compiled_ack_topology.dalo.bash" \
                timeout 90 bash "$case_dir/test.sh" "$ROOT" "$scenario" >"$TMP/run.log" 2>&1; then
                grep -E '^(PHASE|METRIC|PASS|CHILD_ACK_PASS)' "$TMP/run.log" || true
                metric="$(grep '^METRIC:' "$TMP/run.log" | tail -1)"
                if [[ "$metric" =~ seconds=([0-9.]+).*MiBps=([0-9.]+).*msgps=([0-9.]+) ]] && \
                    grep -q "^PASS: fifo pilot + scenario=$scenario unique=16 bytes=$((size * 16)) duplicates=" "$TMP/run.log"; then
                    printf 'fifo,%s,%s,%s,2,16,%s,%s,%s,PASS\n' \
                        "$scenario" "$size" "$rep" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >> "$OUT"
                else
                    cat "$TMP/run.log" >&2; echo 'FAIL: missing metrics or PASS' >&2; exit 1
                fi
            else
                cat "$TMP/run.log" >&2
                printf 'fifo,%s,%s,%s,2,16,,,,FAIL\n' "$scenario" "$size" "$rep" >> "$OUT"
                exit 1
            fi
        done
    done
done
printf 'PILOT_V2_DONE csv=%s\n' "$OUT"
