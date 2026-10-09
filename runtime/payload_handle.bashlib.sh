#!/usr/bin/env bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="payload_handle"
DALO_LIBRARY_VERSION="0.1.0"
DALO_LIBRARY_REQUIRES="python"
DALO_LIBRARY_INIT="payload_handle_init"
DALO_LIBRARY_FINI="payload_handle_shutdown"
DALO_LIBRARY_ARTIFACTS="payload_handle_worker.py"
[ "${DALO_PAYLOAD_HANDLE_INCLUDE:-0}" -eq 0 ] || return 0
DALO_PAYLOAD_HANDLE_INCLUDE=1

declare -g DALO_PAYLOAD_HANDLE_ROOT=''
declare -g DALO_PAYLOAD_HANDLE_NEXT_STORE_ID=0
declare -gA DALO_PAYLOAD_HANDLE_STATE=()
declare -gA DALO_PAYLOAD_HANDLE_WORKER_HANDLE=()
declare -gA DALO_PAYLOAD_HANDLE_WORKER_JOB=()
declare -gA DALO_PAYLOAD_HANDLE_REQUEST_FD=()
declare -gA DALO_PAYLOAD_HANDLE_RESPONSE_FD=()
declare -gA DALO_PAYLOAD_HANDLE_CONTROL_FD=()
declare -gA DALO_PAYLOAD_HANDLE_INGEST_REQUEST_FD=()
declare -gA DALO_PAYLOAD_HANDLE_INGEST_RESPONSE_FD=()
declare -gA DALO_PAYLOAD_HANDLE_DIR=()

# Initialize the Payload Handle runtime directory.
# Parameters: none; DALO_PAYLOAD_HANDLE_ROOT optionally selects the runtime root.
payload_handle_init() {
    DALO_PAYLOAD_HANDLE_ROOT="${DALO_PAYLOAD_HANDLE_ROOT:-${TMPDIR:-/tmp}/dalo-payload-handle-${BASHPID}}"
    mkdir -p -- "$DALO_PAYLOAD_HANDLE_ROOT" || return
    chmod 700 "$DALO_PAYLOAD_HANDLE_ROOT" || return
}

# Capture one command's stdout without executing the command in a subshell.
# Parameters: $1 output variable name; remaining arguments are the command and its arguments.
__payload_handle_capture() {
    local out_name="${1:-}" capture_file value rc; shift || return 2
    [ -n "$out_name" ] && (($# > 0)) || return 2
    capture_file="$DALO_PAYLOAD_HANDLE_ROOT/capture-${BASHPID}-${RANDOM}-${RANDOM}"
    "$@" >"$capture_file" || { rc=$?; rm -f -- "$capture_file"; return "$rc"; }
    IFS= read -r value <"$capture_file" || value=''
    rm -f -- "$capture_file"
    printf -v "$out_name" '%s' "$value"
}

# Build Python code that starts one persistent dual-plane payload-store worker artifact.
# Parameters: $1 control request path; $2 control response path; $3 ingest request path; $4 ingest response path; $5 lifecycle path; $6 store id; $7 output variable name.
__payload_handle_worker_code() {
    local control_request_path="$1" control_response_path="$2" ingest_request_path="$3" ingest_response_path="$4"
    local lifecycle_path="$5" store_id="$6" out_name="$7" worker_artifact code
    dalo_library_artifact_path payload_handle payload_handle_worker.py worker_artifact || return
    code="$(python3 - "$worker_artifact" "$control_request_path" "$control_response_path" "$ingest_request_path" "$ingest_response_path" "$lifecycle_path" "$store_id" <<'PY2'
import sys
artifact, control_request, control_response, ingest_request, ingest_response, lifecycle, store_id = sys.argv[1:]
print("import runpy,sys; sys.argv=[%r,%r,%r,%r,%r,%r,%r]; runpy.run_path(%r,run_name='__main__')" %
      (artifact, control_request, control_response, ingest_request, ingest_response, lifecycle, store_id, artifact))
PY2
)" || return
    printf -v "$out_name" '%s' "$code"
}

# Read one status/value response from a payload-store worker.
# Parameters: $1 store id; $2 output value variable; $3 optional timeout seconds.
__payload_handle_response() {
    local store_id="$1" out_name="$2" timeout="${3:-30}" fd status value
    fd="${DALO_PAYLOAD_HANDLE_RESPONSE_FD[$store_id]:-}"
    [[ "$fd" =~ ^[0-9]+$ ]] || return 1
    status=''; value=''
    IFS= read -r -d '' -t "$timeout" -u "$fd" status || return 1
    IFS= read -r -d '' -t "$timeout" -u "$fd" value || return 1
    if [ "$status" != OK ]; then
        printf 'payload_handle: store=%s error=%s\n' "$store_id" "$value" >&2
        return 1
    fi
    printf -v "$out_name" '%s' "$value"
}

# Create one persistent Python payload store with isolated control and ingest planes.
# Parameters: $1 output variable receiving the store identifier.
# Roll back resources allocated during an incomplete create operation.
# Parameters: $1 identifies the partially initialized instance.
payload_handle_store_create_rollback() {
    local instance_id="${1:-}"
    [ -n "$instance_id" ] || return 2
    payload_handle_store_destroy "$instance_id" || return 1
}

payload_handle_store_create() {
    local out_name="${1:-}" store_id store_dir request response ingest_request ingest_response control
    local request_fd response_fd ingest_request_fd ingest_response_fd control_fd worker_handle worker_code worker_job ready
    [ "$#" -eq 1 ] && [[ "$out_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    store_id="phs-$((++DALO_PAYLOAD_HANDLE_NEXT_STORE_ID))"
    store_dir="$DALO_PAYLOAD_HANDLE_ROOT/$store_id"
    DALO_PAYLOAD_HANDLE_STATE["$store_id"]='CREATING'
    DALO_PAYLOAD_HANDLE_DIR["$store_id"]="$store_dir"
    request="$store_dir/request.fifo"; response="$store_dir/response.fifo"
    ingest_request="$store_dir/ingest-request.fifo"; ingest_response="$store_dir/ingest-response.fifo"
    control="$store_dir/control.fifo"
    mkdir -m 700 -- "$store_dir" || { payload_handle_store_create_rollback "$store_id"; return 1; }
    mkfifo -m 600 "$request" "$response" "$ingest_request" "$ingest_response" "$control" || { payload_handle_store_create_rollback "$store_id"; return 1; }
    exec {request_fd}<>"$request" || { payload_handle_store_create_rollback "$store_id"; return 1; }
    [[ "$request_fd" =~ ^[0-9]+$ ]] && DALO_PAYLOAD_HANDLE_REQUEST_FD["$store_id"]="$request_fd"
    exec {response_fd}<>"$response" || { payload_handle_store_create_rollback "$store_id"; return 1; }
    [[ "$response_fd" =~ ^[0-9]+$ ]] && DALO_PAYLOAD_HANDLE_RESPONSE_FD["$store_id"]="$response_fd"
    exec {ingest_request_fd}<>"$ingest_request" || { payload_handle_store_create_rollback "$store_id"; return 1; }
    [[ "$ingest_request_fd" =~ ^[0-9]+$ ]] && DALO_PAYLOAD_HANDLE_INGEST_REQUEST_FD["$store_id"]="$ingest_request_fd"
    exec {ingest_response_fd}<>"$ingest_response" || { payload_handle_store_create_rollback "$store_id"; return 1; }
    [[ "$ingest_response_fd" =~ ^[0-9]+$ ]] && DALO_PAYLOAD_HANDLE_INGEST_RESPONSE_FD["$store_id"]="$ingest_response_fd"
    exec {control_fd}<>"$control" || { payload_handle_store_create_rollback "$store_id"; return 1; }
    [[ "$control_fd" =~ ^[0-9]+$ ]] && DALO_PAYLOAD_HANDLE_CONTROL_FD["$store_id"]="$control_fd"
    __payload_handle_capture worker_handle init_python_thread || { payload_handle_store_create_rollback "$store_id"; return 1; }
    [[ "$worker_handle" == OK\|* ]] && DALO_PAYLOAD_HANDLE_WORKER_HANDLE["$store_id"]="$worker_handle"
    [[ "$worker_handle" == OK\|* ]] || { payload_handle_store_create_rollback "$store_id"; return 1; }
    __payload_handle_worker_code "$request" "$response" "$ingest_request" "$ingest_response" "$control" "$store_id" worker_code || { payload_handle_store_create_rollback "$store_id"; return 1; }
    __payload_handle_capture worker_job inline_python -t "$worker_handle" -xa "$worker_code" || { payload_handle_store_create_rollback "$store_id"; return 1; }
    IFS= read -r -t 30 -u "$control_fd" ready || { payload_handle_store_create_rollback "$store_id"; return 1; }
    [ "$ready" = 'READY|PAYLOAD_STORE' ] || { payload_handle_store_create_rollback "$store_id"; return 1; }
    DALO_PAYLOAD_HANDLE_STATE["$store_id"]='READY'
    DALO_PAYLOAD_HANDLE_WORKER_HANDLE["$store_id"]="$worker_handle"
    DALO_PAYLOAD_HANDLE_WORKER_JOB["$store_id"]="$worker_job"
    DALO_PAYLOAD_HANDLE_REQUEST_FD["$store_id"]="$request_fd"
    DALO_PAYLOAD_HANDLE_RESPONSE_FD["$store_id"]="$response_fd"
    DALO_PAYLOAD_HANDLE_INGEST_REQUEST_FD["$store_id"]="$ingest_request_fd"
    DALO_PAYLOAD_HANDLE_INGEST_RESPONSE_FD["$store_id"]="$ingest_response_fd"
    DALO_PAYLOAD_HANDLE_CONTROL_FD["$store_id"]="$control_fd"
    DALO_PAYLOAD_HANDLE_DIR["$store_id"]="$store_dir"
    printf -v "$out_name" '%s' "$store_id"
}

# Store one Bash-compatible payload in Python and return an OWNED PH1 descriptor.
# Parameters: $1 store id; $2 payload text; $3 output descriptor variable.
payload_handle_store() {
    local store_id="${1:-}" payload="${2-}" out_name="${3:-}" fd __dalo_ph_value
    [ "$#" -eq 3 ] && [[ "$out_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [ "${DALO_PAYLOAD_HANDLE_STATE[$store_id]:-}" = READY ] || return 1
    fd="${DALO_PAYLOAD_HANDLE_REQUEST_FD[$store_id]}"
    printf 'STORE\0%s\0' "$payload" >&"$fd" || return
    __payload_handle_response "$store_id" __dalo_ph_value || return
    printf -v "$out_name" '%s' "$__dalo_ph_value"
}

# Transfer payload ownership without materializing payload bytes into Bash.
# Parameters: $1 store id; $2 current OWNED descriptor; $3 output replacement descriptor variable.
payload_handle_forward() {
    local store_id="${1:-}" descriptor="${2:-}" out_name="${3:-}" fd __dalo_ph_value
    [ "$#" -eq 3 ] && [[ "$out_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [ "${DALO_PAYLOAD_HANDLE_STATE[$store_id]:-}" = READY ] || return 1
    fd="${DALO_PAYLOAD_HANDLE_REQUEST_FD[$store_id]}"
    printf 'FORWARD\0%s\0' "$descriptor" >&"$fd" || return
    __payload_handle_response "$store_id" __dalo_ph_value || return
    printf -v "$out_name" '%s' "$__dalo_ph_value"
}

# Explicitly copy resident payload bytes back into the Bash semantic plane.
# Parameters: $1 store id; $2 current OWNED descriptor; $3 output payload variable.
payload_handle_materialize() {
    local store_id="${1:-}" descriptor="${2:-}" out_name="${3:-}" fd __dalo_ph_value
    [ "$#" -eq 3 ] && [[ "$out_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [ "${DALO_PAYLOAD_HANDLE_STATE[$store_id]:-}" = READY ] || return 1
    fd="${DALO_PAYLOAD_HANDLE_REQUEST_FD[$store_id]}"
    printf 'MATERIALIZE\0%s\0' "$descriptor" >&"$fd" || return
    __payload_handle_response "$store_id" __dalo_ph_value || return
    printf -v "$out_name" '%s' "$__dalo_ph_value"
}

# Release one current OWNED handle and invalidate its resident payload.
# Parameters: $1 store id; $2 current OWNED descriptor.
payload_handle_release() {
    local store_id="${1:-}" descriptor="${2:-}" fd __dalo_ph_value
    [ "$#" -eq 2 ] || return 2
    [ "${DALO_PAYLOAD_HANDLE_STATE[$store_id]:-}" = READY ] || return 1
    fd="${DALO_PAYLOAD_HANDLE_REQUEST_FD[$store_id]}"
    printf 'RELEASE\0%s\0' "$descriptor" >&"$fd" || return
    __payload_handle_response "$store_id" __dalo_ph_value || return
    [ "$__dalo_ph_value" = RELEASED ]
}

# Destroy one payload store and release its persistent Python worker lease.
# Parameters: $1 store identifier.
payload_handle_store_destroy() {
    local store_id="${1:-}" fd handle dir __dalo_ph_value rc=0
    [ "$#" -eq 1 ] || return 2
    [[ -n "${DALO_PAYLOAD_HANDLE_STATE[$store_id]:-}" ]] || return 0
    local was_ready="${DALO_PAYLOAD_HANDLE_STATE[$store_id]}"
    DALO_PAYLOAD_HANDLE_STATE["$store_id"]='STOPPING'
    fd="${DALO_PAYLOAD_HANDLE_REQUEST_FD[$store_id]:-}"
    if [[ "$was_ready" == READY && "$fd" =~ ^[0-9]+$ ]]; then
        printf 'STOP\0' >&"$fd" 2>/dev/null || true
        __payload_handle_response "$store_id" __dalo_ph_value 5 >/dev/null 2>&1 || true
    fi
    handle="${DALO_PAYLOAD_HANDLE_WORKER_HANDLE[$store_id]:-}"
    [[ -z "$handle" ]] || release_python_thread "$handle" >/dev/null 2>&1 || rc=1
    for fd in "${DALO_PAYLOAD_HANDLE_REQUEST_FD[$store_id]:-}" "${DALO_PAYLOAD_HANDLE_RESPONSE_FD[$store_id]:-}" "${DALO_PAYLOAD_HANDLE_INGEST_REQUEST_FD[$store_id]:-}" "${DALO_PAYLOAD_HANDLE_INGEST_RESPONSE_FD[$store_id]:-}" "${DALO_PAYLOAD_HANDLE_CONTROL_FD[$store_id]:-}"; do
        [[ "$fd" =~ ^[0-9]+$ ]] && eval "exec ${fd}>&-" 2>/dev/null || true
    done
    dir="${DALO_PAYLOAD_HANDLE_DIR[$store_id]:-}"; [[ -z "$dir" ]] || rm -rf -- "$dir"
    unset 'DALO_PAYLOAD_HANDLE_STATE[$store_id]' 'DALO_PAYLOAD_HANDLE_WORKER_HANDLE[$store_id]' \
        'DALO_PAYLOAD_HANDLE_WORKER_JOB[$store_id]' 'DALO_PAYLOAD_HANDLE_REQUEST_FD[$store_id]' \
        'DALO_PAYLOAD_HANDLE_RESPONSE_FD[$store_id]' 'DALO_PAYLOAD_HANDLE_INGEST_REQUEST_FD[$store_id]' \
        'DALO_PAYLOAD_HANDLE_INGEST_RESPONSE_FD[$store_id]' 'DALO_PAYLOAD_HANDLE_CONTROL_FD[$store_id]' \
        'DALO_PAYLOAD_HANDLE_DIR[$store_id]'
    if ((rc != 0)); then
        printf 'payload_handle_store_create: supervisor lease release not confirmed; manual reconciliation required\n' >&2
    fi
    return "$rc"
}

# Destroy every payload store before the dependent Python runtime shuts down.
# Parameters: none.
payload_handle_shutdown() {
    local store_id rc=0 one_rc
    for store_id in "${!DALO_PAYLOAD_HANDLE_STATE[@]}"; do
        one_rc=0; payload_handle_store_destroy "$store_id" || one_rc=$?
        ((one_rc == 0)) || rc=$one_rc
    done
    [[ -z "${DALO_PAYLOAD_HANDLE_ROOT:-}" ]] || rm -rf -- "$DALO_PAYLOAD_HANDLE_ROOT" 2>/dev/null || true
    return "$rc"
}

# Send resident payload directly into a Production Line ingress FIFO without materializing it in Bash.
# Parameters: $1 store id; $2 current OWNED descriptor; $3 Production Line ingress path; $4 logical key.
payload_handle_send_to_line() {
    local store_id="${1:-}" descriptor="${2:-}" ingress_path="${3:-}" key="${4-}" fd __dalo_ph_value
    [ "$#" -eq 4 ] || return 2
    [ "${DALO_PAYLOAD_HANDLE_STATE[$store_id]:-}" = READY ] || return 1
    fd="${DALO_PAYLOAD_HANDLE_REQUEST_FD[$store_id]}"
    printf 'SEND_TO_LINE\0%s\0%s\0%s\0' "$descriptor" "$ingress_path" "$key" >&"$fd" || return
    __payload_handle_response "$store_id" __dalo_ph_value || return
    [ "$__dalo_ph_value" = SENT ]
}

# Return isolated ingest request/response FIFO paths for Python data-plane workers.
# Parameters: $1 store id; $2 request-path output variable; $3 response-path output variable.
payload_handle_ingest_paths() {
    local store_id="${1:-}" request_out="${2:-}" response_out="${3:-}" dir
    [ "$#" -eq 3 ] || return 2
    [[ "$request_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$response_out" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    [ "${DALO_PAYLOAD_HANDLE_STATE[$store_id]:-}" = READY ] || return 1
    dir="${DALO_PAYLOAD_HANDLE_DIR[$store_id]:-}"
    [ -n "$dir" ] || return 1
    printf -v "$request_out" '%s' "$dir/ingest-request.fifo"
    printf -v "$response_out" '%s' "$dir/ingest-response.fifo"
}
