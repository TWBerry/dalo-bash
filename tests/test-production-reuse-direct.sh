#!/usr/bin/env bash
# Benchmark repeated DIRECT measurements against one compiled, initialized MACHINE.
# Parameters: DALO_REUSE_WORKERS, DALO_REUSE_MESSAGES, DALO_REUSE_SIZES,
# DALO_REUSE_REPEATS, and DALO_REUSE_OUTPUT configure the experiment.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dalo-reuse.XXXXXXXX")"
# Remove only this test's temporary generated project.
# Parameters: none.
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
workers="${DALO_REUSE_WORKERS:-2}"
messages="${DALO_REUSE_MESSAGES:-32}"
repeats="${DALO_REUSE_REPEATS:-2}"
sizes="${DALO_REUSE_SIZES:-8 128}"
output="${DALO_REUSE_OUTPUT:-production-reuse-direct.csv}"
[[ "$workers" =~ ^[1-4]$ && "$messages" =~ ^[1-9][0-9]*$ && "$repeats" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid benchmark parameters' >&2; exit 2; }
for size in $sizes; do [[ "$size" =~ ^[1-9][0-9]*$ ]] || exit 2; done
cat > "$tmp/project.dalo" <<'DALO_PROJECT_END'
PROJECT
	NAME reuse_direct
	VERSION 1.1
OBJECT origin
	TYPE ORIGIN
	WORKER
		TYPE inline
		CODE origin.bash
OBJECT pipe
	MAX_JOBS __WORKERS__
	TYPE PIPE
	WORKER
		TYPE inline
		CODE pipe.bash
		EXECUTION PERSISTENT
OBJECT endpoint
	TYPE ENDPOINT
	WORKER
		TYPE inline
		CODE endpoint.bash
CONNECT origin.out pipe.in
CONNECT pipe.out endpoint.in
DALO_PROJECT_END
sed -i "s/__WORKERS__/$workers/" "$tmp/project.dalo"
cat > "$tmp/origin.bash" <<'ORIGIN'
# Emit one input frame into the compiled DIRECT route.
# Parameters: $1 worker directory; $2 slot; $3 payload.
worker() { "${ASYNC_WORKER_NS}_fifo_output_port" "$2" out "${3:-}"; }
ORIGIN
cat > "$tmp/pipe.bash" <<'PIPE'
# Validate the child-local input vector and return a PID-tagged output.
# Parameters: $1 worker directory; $2 slot; $3 payload.
worker() {
    local slot="$2" payload="$3"
    [[ "${m_0001_pipe_INPUT_DATA_VECTOR["$slot|in"]-}" == "$payload" ]] || return 81
    "${ASYNC_WORKER_NS}_fifo_output_port" "$slot" out "processed:$payload:pid:$BASHPID"
}
PIPE
cat > "$tmp/endpoint.bash" <<'ENDPOINT'
# Record a routed output in the owning parent shell.
# Parameters: $1 worker directory; $2 slot; $3 payload.
worker() { DALO_REUSE_RECEIVED+=("$3"); }
ENDPOINT
compile_start="${EPOCHREALTIME:?Bash 5 required}"
bash "$root/compiler/daloc.bash" "$tmp/project.dalo" >/dev/null
compile_end="$EPOCHREALTIME"
export MAIN_TMP_DIR="$tmp"
export DALO_REUSE_WORKERS="$workers" DALO_REUSE_MESSAGES="$messages" DALO_REUSE_REPEATS="$repeats" DALO_REUSE_SIZES="$sizes" DALO_REUSE_OUTPUT="$output" DALO_REUSE_COMPILE_START="$compile_start" DALO_REUSE_COMPILE_END="$compile_end"
# Run every measured configuration inside one shell and one initialized MACHINE.
# Parameters: $1 path of compiled MACHINE.
bash -c '
set -euo pipefail
init_start="$EPOCHREALTIME"
source "$1"
init_end="$EPOCHREALTIME"
# Persist each verified row immediately; failed measurements never produce PASS rows.
# Parameters: $1 size; $2 repetition; $3 elapsed seconds; $4 distinct PID count.
record_pass() {
    python3 - "$DALO_REUSE_OUTPUT" "$DALO_REUSE_WORKERS" "$DALO_REUSE_MESSAGES" "$1" "$2" "$3" "$4" <<"PY"
import csv, os, sys
path, workers, messages, size, repeat, seconds, pids = sys.argv[1:]
header = ["mode", "workers", "messages", "payload_bytes", "repeat", "seconds", "msgps", "distinct_child_pids", "duplicates", "status"]
with open(path, "a", newline="") as stream:
    writer = csv.writer(stream)
    if stream.tell() == 0:
        writer.writerow(header)
    writer.writerow(["direct", workers, messages, size, repeat, seconds, f"{int(messages)/float(seconds):.3f}", pids, 0, "PASS"])
    stream.flush()
    os.fsync(stream.fileno())
PY
}
for size in $DALO_REUSE_SIZES; do
    printf -v padding "%*s" "$size" ""
    padding="${padding// /x}"
    for ((rep=0; rep<DALO_REUSE_REPEATS; rep++)); do
        DALO_REUSE_RECEIVED=()
        start="$EPOCHREALTIME"
        for ((i=1; i<=DALO_REUSE_MESSAGES; i++)); do
            m_0000_origin_summon_worker out "frame-$i:$padding"
        done
        async_machine_wait_all
        end="$EPOCHREALTIME"
        [[ ${#DALO_REUSE_RECEIVED[@]} -eq DALO_REUSE_MESSAGES ]] || { echo "FAIL delivered=${#DALO_REUSE_RECEIVED[@]}" >&2; exit 1; }
        declare -A seen=() pids=()
        for frame in "${DALO_REUSE_RECEIVED[@]}"; do
            if [[ "$frame" =~ ^processed:frame-([1-9][0-9]*):([x]+):pid:([1-9][0-9]*)$ ]]; then
                number="${BASH_REMATCH[1]}"; data="${BASH_REMATCH[2]}"; pid="${BASH_REMATCH[3]}"
                [[ ${#data} -eq size && "$data" == "$padding" ]] || exit 1
            else
                printf "FAIL malformed=%q\n" "$frame" >&2; exit 1
            fi
            ((number >= 1 && number <= DALO_REUSE_MESSAGES)) || exit 1
            [[ ! -v seen[$number] ]] || { echo "FAIL duplicate=$number" >&2; exit 1; }
            seen[$number]=1; pids[$pid]=1
        done
        [[ ${#seen[@]} -eq DALO_REUSE_MESSAGES ]] || exit 1
        [[ ${#pids[@]} -eq DALO_REUSE_WORKERS ]] || { echo "FAIL pid_count=${#pids[@]}" >&2; exit 1; }
        seconds="$(python3 - "$start" "$end" <<"PY"
import sys
print(f"{float(sys.argv[2])-float(sys.argv[1]):.6f}")
PY
)"
        record_pass "$size" "$rep" "$seconds" "${#pids[@]}"
        printf "PASS mode=direct workers=%s messages=%s size=%s repeat=%s seconds=%s pids=%s\n" "$DALO_REUSE_WORKERS" "$DALO_REUSE_MESSAGES" "$size" "$rep" "$seconds" "${#pids[@]}"
        unset seen pids
    done
done
m_0001_pipe_persistent_stop
printf "SETUP compile_seconds=%s init_seconds=%s\n" "$(python3 - "$DALO_REUSE_COMPILE_START" "$DALO_REUSE_COMPILE_END" <<"PY"
import sys
print(f"{float(sys.argv[2])-float(sys.argv[1]):.6f}")
PY
)" "$(python3 - "$init_start" "$init_end" <<"PY"
import sys
print(f"{float(sys.argv[2])-float(sys.argv[1]):.6f}")
PY
)"
' _ "$tmp/reuse_direct.dalo.bash"
