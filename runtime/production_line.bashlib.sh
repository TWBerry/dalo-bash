#!/usr/bin/env bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="production_line"
DALO_LIBRARY_VERSION="0.1.2"
DALO_LIBRARY_REQUIRES="python"
DALO_LIBRARY_INIT="production_line_init"
DALO_LIBRARY_FINI="production_line_shutdown"
DALO_LIBRARY_ARTIFACTS="production_line_worker.py"
[ "${DALO_PRODUCTION_LINE_INCLUDE:-0}" -eq 0 ] || return 0
DALO_PRODUCTION_LINE_INCLUDE=1

declare -g DALO_PRODUCTION_LINE_ROOT=''
declare -g DALO_PRODUCTION_LINE_NEXT_ID=0
declare -gA DALO_PRODUCTION_LINE_STATE=()
declare -gA DALO_PRODUCTION_LINE_TX_HANDLE=()
declare -gA DALO_PRODUCTION_LINE_RX_HANDLE=()
declare -gA DALO_PRODUCTION_LINE_TX_JOB=()
declare -gA DALO_PRODUCTION_LINE_RX_JOB=()
declare -gA DALO_PRODUCTION_LINE_INGRESS_FD=()
declare -gA DALO_PRODUCTION_LINE_EGRESS_FD=()
declare -gA DALO_PRODUCTION_LINE_CONTROL_FD=()
declare -gA DALO_PRODUCTION_LINE_DIR=()

# Initialize the production-line runtime directory.
# Parameters: none; DALO_PRODUCTION_LINE_ROOT optionally selects the runtime root.
production_line_init() {
    DALO_PRODUCTION_LINE_ROOT="${DALO_PRODUCTION_LINE_ROOT:-${TMPDIR:-/tmp}/dalo-production-line-${BASHPID}}"
    mkdir -p -- "$DALO_PRODUCTION_LINE_ROOT" || return
    chmod 700 "$DALO_PRODUCTION_LINE_ROOT" || return
}

# Capture one command's stdout without executing the command in a subshell.
# Parameters: $1 output variable name; remaining arguments are the command and its arguments.
__production_line_capture() {
    local out_name="${1:-}" capture_file value rc; shift || return 2
    [ -n "$out_name" ] && (($# > 0)) || return 2
    capture_file="$DALO_PRODUCTION_LINE_ROOT/capture-${BASHPID}-${RANDOM}-${RANDOM}"
    "$@" >"$capture_file" || { rc=$?; rm -f -- "$capture_file"; return "$rc"; }
    IFS= read -r value <"$capture_file" || value=''
    rm -f -- "$capture_file"
    printf -v "$out_name" '%s' "$value"
}

# Build the small Python command used to start one persistent worker artifact.
# Parameters: $1 role; $2 first data path; $3 second data path; $4 control path; $5 output variable name.
__production_line_worker_code() {
    local role="$1" path_a="$2" path_b="$3" control="$4" out_name="$5" worker_artifact code
    dalo_library_artifact_path production_line production_line_worker.py worker_artifact || return
    printf -v code 'import runpy,sys; sys.argv=[%q,%q,%q,%q,%q]; runpy.run_path(%q,run_name="__main__")' \
        "$worker_artifact" "$role" "$path_a" "$path_b" "$control" "$worker_artifact"
    # Bash %q is not Python string quoting. Rebuild the command with Python repr
    # outside the data hot path so arbitrary runtime paths remain safe.
    code="$(python3 - "$worker_artifact" "$role" "$path_a" "$path_b" "$control" <<'PY'
import sys
artifact, role, path_a, path_b, control = sys.argv[1:]
print("import runpy,sys; sys.argv=[%r,%r,%r,%r,%r]; runpy.run_path(%r,run_name='__main__')" % (artifact, role, path_a, path_b, control, artifact))
PY
)" || return
    printf -v "$out_name" '%s' "$code"
}

# Wait for both persistent workers to announce readiness.
# Parameters: $1 control FD; $2 line identifier.
__production_line_wait_ready() {
    local fd="$1" line_id="$2" first second
    IFS= read -r -t 30 -u "$fd" first || { printf 'production_line_create: READY timeout line=%s\n' "$line_id" >&2; return 1; }
    IFS= read -r -t 30 -u "$fd" second || { printf 'production_line_create: READY timeout line=%s\n' "$line_id" >&2; return 1; }
    [[ "$first|$second" == *'READY|TX'* && "$first|$second" == *'READY|RX'* ]] || {
        printf 'production_line_create: invalid READY records line=%s first=%q second=%q\n' "$line_id" "$first" "$second" >&2
        return 1
    }
}

# Create one persistent Python TX -> RX production line.
# Parameters: $1 output variable receiving the line identifier.
# Roll back resources allocated during an incomplete create operation.
# Parameters: $1 identifies the partially initialized instance.
production_line_create_rollback() {
    local instance_id="${1:-}"
    [ -n "$instance_id" ] || return 2
    production_line_destroy "$instance_id" || return 1
}

production_line_create() {
    local out_name="${1:-}" line_id line_dir ingress transport egress control ingress_fd egress_fd control_fd
    local tx_handle rx_handle tx_code rx_code tx_job rx_job
    [ "$#" -eq 1 ] && [[ "$out_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    line_id="pl-$((++DALO_PRODUCTION_LINE_NEXT_ID))"
    line_dir="$DALO_PRODUCTION_LINE_ROOT/$line_id"
    DALO_PRODUCTION_LINE_STATE["$line_id"]='CREATING'
    DALO_PRODUCTION_LINE_DIR["$line_id"]="$line_dir"
    ingress="$line_dir/ingress.fifo"; transport="$line_dir/transport.fifo"; egress="$line_dir/egress.fifo"; control="$line_dir/control.fifo"
    mkdir -m 700 -- "$line_dir" || { production_line_create_rollback "$line_id"; return 1; }
    mkfifo -m 600 "$ingress" "$transport" "$egress" "$control" || { production_line_create_rollback "$line_id"; return 1; }
    exec {ingress_fd}<>"$ingress" || { production_line_create_rollback "$line_id"; return 1; }
    [[ "$ingress_fd" =~ ^[0-9]+$ ]] && DALO_PRODUCTION_LINE_INGRESS_FD["$line_id"]="$ingress_fd"
    exec {egress_fd}<>"$egress" || { production_line_create_rollback "$line_id"; return 1; }
    [[ "$egress_fd" =~ ^[0-9]+$ ]] && DALO_PRODUCTION_LINE_EGRESS_FD["$line_id"]="$egress_fd"
    exec {control_fd}<>"$control" || { production_line_create_rollback "$line_id"; return 1; }
    [[ "$control_fd" =~ ^[0-9]+$ ]] && DALO_PRODUCTION_LINE_CONTROL_FD["$line_id"]="$control_fd"
    __production_line_capture tx_handle init_python_thread || { production_line_create_rollback "$line_id"; return 1; }
    [[ "$tx_handle" == OK\|* ]] && DALO_PRODUCTION_LINE_TX_HANDLE["$line_id"]="$tx_handle"
    __production_line_capture rx_handle init_python_thread || { production_line_create_rollback "$line_id"; return 1; }
    [[ "$rx_handle" == OK\|* ]] && DALO_PRODUCTION_LINE_RX_HANDLE["$line_id"]="$rx_handle"
    [[ "$tx_handle" == OK\|* && "$rx_handle" == OK\|* ]] || { production_line_create_rollback "$line_id"; return 1; }
    __production_line_worker_code tx "$ingress" "$transport" "$control" tx_code || { production_line_create_rollback "$line_id"; return 1; }
    __production_line_worker_code rx "$transport" "$egress" "$control" rx_code || { production_line_create_rollback "$line_id"; return 1; }
    __production_line_capture rx_job inline_python -t "$rx_handle" -xa "$rx_code" || { production_line_create_rollback "$line_id"; return 1; }
    __production_line_capture tx_job inline_python -t "$tx_handle" -xa "$tx_code" || { production_line_create_rollback "$line_id"; return 1; }
    __production_line_wait_ready "$control_fd" "$line_id" || { production_line_create_rollback "$line_id"; return 1; }
    DALO_PRODUCTION_LINE_STATE["$line_id"]='READY'
    DALO_PRODUCTION_LINE_TX_HANDLE["$line_id"]="$tx_handle"
    DALO_PRODUCTION_LINE_RX_HANDLE["$line_id"]="$rx_handle"
    DALO_PRODUCTION_LINE_TX_JOB["$line_id"]="$tx_job"
    DALO_PRODUCTION_LINE_RX_JOB["$line_id"]="$rx_job"
    DALO_PRODUCTION_LINE_INGRESS_FD["$line_id"]="$ingress_fd"
    DALO_PRODUCTION_LINE_EGRESS_FD["$line_id"]="$egress_fd"
    DALO_PRODUCTION_LINE_CONTROL_FD["$line_id"]="$control_fd"
    DALO_PRODUCTION_LINE_DIR["$line_id"]="$line_dir"
    printf -v "$out_name" '%s' "$line_id"
}

# Send one Bash-compatible text record into a ready production line.
# Parameters: $1 line identifier; $2 logical key; $3 payload text.
# The data-plane ingress ABI uses NUL-delimited fields because Bash variables
# cannot contain NUL bytes. This keeps byte counting, escaping, and Frame ABI
# construction out of the Bash hot path.
production_line_send() {
    local line_id="${1:-}" key="${2-}" payload="${3-}" fd
    [ "$#" -eq 3 ] || return 2
    [ "${DALO_PRODUCTION_LINE_STATE[$line_id]:-}" = READY ] || return 1
    fd="${DALO_PRODUCTION_LINE_INGRESS_FD[$line_id]}"
    printf '%s\0%s\0' "$key" "$payload" >&"$fd"
}

# Receive one decoded Bash-compatible text record from a production line.
# Parameters: $1 line identifier; $2 output key variable; $3 output payload variable; $4 optional timeout seconds.
# Python RX emits the same NUL-delimited boundary used by ingress. The parent
# Bash process therefore receives the original text fields and retains all
# semantic processing and commit authority without needing byte lengths.
production_line_receive() {
    local line_id="${1:-}" key_out="${2:-}" payload_out="${3:-}" timeout="${4:-30}" fd
    local __dalo_pl_received_key __dalo_pl_received_payload
    (($# == 3 || $# == 4)) || return 2
    [[ "$key_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$payload_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [ "${DALO_PRODUCTION_LINE_STATE[$line_id]:-}" = READY ] || return 1
    fd="${DALO_PRODUCTION_LINE_EGRESS_FD[$line_id]}"
    __dalo_pl_received_key=''; __dalo_pl_received_payload=''
    IFS= read -r -d '' -t "$timeout" -u "$fd" __dalo_pl_received_key || return 1
    IFS= read -r -d '' -t "$timeout" -u "$fd" __dalo_pl_received_payload || return 1
    printf -v "$key_out" '%s' "$__dalo_pl_received_key"
    printf -v "$payload_out" '%s' "$__dalo_pl_received_payload"
}

# Destroy one production line and release its persistent worker leases.
# Parameters: $1 line identifier.
production_line_destroy() {
    local line_id="${1:-}" fd handle dir rc=0
    [ "$#" -eq 1 ] || return 2
    [[ -n "${DALO_PRODUCTION_LINE_STATE[$line_id]:-}" ]] || return 0
    local was_ready="${DALO_PRODUCTION_LINE_STATE[$line_id]}"
    DALO_PRODUCTION_LINE_STATE["$line_id"]='STOPPING'
    fd="${DALO_PRODUCTION_LINE_INGRESS_FD[$line_id]:-}"
    if [[ "$was_ready" == READY && "$fd" =~ ^[0-9]+$ ]]; then printf '%s\0\0' '__DALO_PRODUCTION_LINE_STOP__' >&"$fd" 2>/dev/null || true; fi
    handle="${DALO_PRODUCTION_LINE_TX_HANDLE[$line_id]:-}"; [[ -z "$handle" ]] || release_python_thread "$handle" >/dev/null 2>&1 || rc=1
    handle="${DALO_PRODUCTION_LINE_RX_HANDLE[$line_id]:-}"; [[ -z "$handle" ]] || release_python_thread "$handle" >/dev/null 2>&1 || rc=1
    for fd in "${DALO_PRODUCTION_LINE_INGRESS_FD[$line_id]:-}" "${DALO_PRODUCTION_LINE_EGRESS_FD[$line_id]:-}" "${DALO_PRODUCTION_LINE_CONTROL_FD[$line_id]:-}"; do
        [[ "$fd" =~ ^[0-9]+$ ]] && eval "exec ${fd}>&-" 2>/dev/null || true
    done
    dir="${DALO_PRODUCTION_LINE_DIR[$line_id]:-}"; [[ -z "$dir" ]] || rm -rf -- "$dir"
    unset 'DALO_PRODUCTION_LINE_STATE[$line_id]' 'DALO_PRODUCTION_LINE_TX_HANDLE[$line_id]' 'DALO_PRODUCTION_LINE_RX_HANDLE[$line_id]' \
        'DALO_PRODUCTION_LINE_TX_JOB[$line_id]' 'DALO_PRODUCTION_LINE_RX_JOB[$line_id]' 'DALO_PRODUCTION_LINE_INGRESS_FD[$line_id]' \
        'DALO_PRODUCTION_LINE_EGRESS_FD[$line_id]' 'DALO_PRODUCTION_LINE_CONTROL_FD[$line_id]' 'DALO_PRODUCTION_LINE_DIR[$line_id]'
    if ((rc != 0)); then
        printf 'production_line_create: supervisor lease release not confirmed; manual reconciliation required\n' >&2
    fi
    return "$rc"
}

# Destroy every production line before the dependent Python runtime shuts down.
# Parameters: none.
production_line_shutdown() {
    local line_id rc=0 one_rc
    for line_id in "${!DALO_PRODUCTION_LINE_STATE[@]}"; do
        one_rc=0; production_line_destroy "$line_id" || one_rc=$?
        ((one_rc == 0)) || rc=$one_rc
    done
    [[ -z "${DALO_PRODUCTION_LINE_ROOT:-}" ]] || rm -rf -- "$DALO_PRODUCTION_LINE_ROOT" 2>/dev/null || true
    return "$rc"
}

# Return the ingress FIFO path for direct Python data-plane injection.
# Parameters: $1 line identifier; $2 output variable receiving the path.
production_line_ingress_path() {
    local line_id="${1:-}" out_name="${2:-}" dir
    [ "$#" -eq 2 ] && [[ "$out_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [ "${DALO_PRODUCTION_LINE_STATE[$line_id]:-}" = READY ] || return 1
    dir="${DALO_PRODUCTION_LINE_DIR[$line_id]:-}"
    [ -n "$dir" ] || return 1
    printf -v "$out_name" '%s' "$dir/ingress.fifo"
}

# Build Python code for a handle-sink RX worker using the Payload Store ingest plane.
# Parameters: $1 transport path; $2 metadata path; $3 control path; $4 ingest request path; $5 ingest response path; $6 output variable name.
__production_line_handle_sink_code() {
    local transport="$1" metadata="$2" control="$3" ingest_request="$4" ingest_response="$5" out_name="$6" worker_artifact code
    dalo_library_artifact_path production_line production_line_worker.py worker_artifact || return
    code="$(python3 - "$worker_artifact" "$transport" "$metadata" "$control" "$ingest_request" "$ingest_response" <<'PY2'
import sys
artifact, transport, metadata, control, ingest_request, ingest_response = sys.argv[1:]
print("import runpy,sys; sys.argv=[%r,'rx_handle_sink',%r,%r,%r,%r,%r]; runpy.run_path(%r,run_name='__main__')" %
      (artifact, transport, metadata, control, ingest_request, ingest_response, artifact))
PY2
)" || return
    printf -v "$out_name" '%s' "$code"
}

# Create a Production Line whose RX stores payload directly into a Payload Store.
# Parameters: $1 output line identifier; $2 destination Payload Store identifier.
production_line_create_handle_sink() {
    local out_name="${1:-}" store_id="${2:-}" line_id line_dir ingress transport egress control
    local ingress_fd egress_fd control_fd tx_handle rx_handle tx_code rx_code tx_job rx_job store_ingest_request store_ingest_response
    [ "$#" -eq 2 ] && [[ "$out_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    payload_handle_ingest_paths "$store_id" store_ingest_request store_ingest_response || return
    line_id="pl-$((++DALO_PRODUCTION_LINE_NEXT_ID))"
    line_dir="$DALO_PRODUCTION_LINE_ROOT/$line_id"
    ingress="$line_dir/ingress.fifo"; transport="$line_dir/transport.fifo"; egress="$line_dir/egress.fifo"; control="$line_dir/control.fifo"
    mkdir -m 700 -- "$line_dir" || return
    mkfifo -m 600 "$ingress" "$transport" "$egress" "$control" || { rm -rf -- "$line_dir"; return 1; }
    exec {ingress_fd}<>"$ingress" || return
    exec {egress_fd}<>"$egress" || { eval "exec ${ingress_fd}>&-"; return 1; }
    exec {control_fd}<>"$control" || { eval "exec ${ingress_fd}>&-"; eval "exec ${egress_fd}>&-"; return 1; }
    __production_line_capture tx_handle init_python_thread || return
    __production_line_capture rx_handle init_python_thread || { release_python_thread "$tx_handle" >/dev/null 2>&1 || true; return 1; }
    [[ "$tx_handle" == OK\|* && "$rx_handle" == OK\|* ]] || return 1
    __production_line_worker_code tx "$ingress" "$transport" "$control" tx_code || return
    __production_line_handle_sink_code "$transport" "$egress" "$control" "$store_ingest_request" "$store_ingest_response" rx_code || return
    __production_line_capture rx_job inline_python -t "$rx_handle" -xa "$rx_code" || return
    __production_line_capture tx_job inline_python -t "$tx_handle" -xa "$tx_code" || return
    __production_line_wait_ready "$control_fd" "$line_id" || return
    DALO_PRODUCTION_LINE_STATE["$line_id"]='READY'
    DALO_PRODUCTION_LINE_TX_HANDLE["$line_id"]="$tx_handle"; DALO_PRODUCTION_LINE_RX_HANDLE["$line_id"]="$rx_handle"
    DALO_PRODUCTION_LINE_TX_JOB["$line_id"]="$tx_job"; DALO_PRODUCTION_LINE_RX_JOB["$line_id"]="$rx_job"
    DALO_PRODUCTION_LINE_INGRESS_FD["$line_id"]="$ingress_fd"; DALO_PRODUCTION_LINE_EGRESS_FD["$line_id"]="$egress_fd"
    DALO_PRODUCTION_LINE_CONTROL_FD["$line_id"]="$control_fd"; DALO_PRODUCTION_LINE_DIR["$line_id"]="$line_dir"
    printf -v "$out_name" '%s' "$line_id"
}

# Receive small metadata plus the destination Payload Handle after an RX handle-sink transfer.
# Parameters: $1 line id; $2 destination store id; $3 output key variable; $4 output handle variable; $5 optional timeout.
production_line_receive_handle() {
    local line_id="${1:-}" store_id="${2:-}" key_out="${3:-}" handle_out="${4:-}" timeout="${5:-30}" fd
    local __dalo_pl_key __dalo_pl_handle
    (($# == 4 || $# == 5)) || return 2
    [[ "$key_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$handle_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [ "${DALO_PRODUCTION_LINE_STATE[$line_id]:-}" = READY ] || return 1
    fd="${DALO_PRODUCTION_LINE_EGRESS_FD[$line_id]}"
    IFS= read -r -d '' -t "$timeout" -u "$fd" __dalo_pl_key || return 1
    IFS= read -r -d '' -t "$timeout" -u "$fd" __dalo_pl_handle || return 1
    printf -v "$key_out" '%s' "$__dalo_pl_key"
    printf -v "$handle_out" '%s' "$__dalo_pl_handle"
}
