#!/bin/bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="dalo"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="helpers"
# ==============================================================================
# Async object / project compiler runtime for Bash.
#
# ARCHITECTURAL MODEL
# -------------------
# A PROJECT is the editable source representation. It contains the A x B object
# field, logical object placement, logical edges, worker source, worker-count
# policy, resource declarations, and future compiler/JIT hints.
#
# A MACHINE is the compact executable representation produced from a PROJECT.
# The machine is encoded directly into generated async_script.bash. Runtime does
# not need the project file in order to execute the generated machine.
#
# The ASYNC_SCRIPT object is the runtime owner of a compiled machine. Like every
# first-class async object it owns UUID/obj_id/ns/FIFO identity. Child objects
# are materialized from the project's object field and remain explicitly owned
# by the ASYNC_SCRIPT.
#
# DATA and CONTROL are intentionally separate planes. FIFO is the local control
# and ownership-boundary mechanism. TCP is a transport boundary and therefore
# applies the TCP capability gate before a received control frame reaches FIFO.
#
# FIFO Frame ABI v1:
#   O<TAB>argc<TAB>...  worker output
#   S<TAB>argc<TAB>...  canonical parent variable mutation
#   A<TAB>argc<TAB>...  canonical parent array append
#   C<TAB>argc<TAB>...  parent/object RPC
#   X<TAB>argc<TAB>...  parent-side code mutation
#
# Requirements: Bash >= 4.3. sha256sum or shasum is required for project hashes.
# ==============================================================================

# Loaded DALO modules may use this to select namespaced/code-recorded installation.
if [ "${DALO_INCLUDE:-0}" -eq 0 ]; then
    DALO_INCLUDE=1
else
    return 0
fi

__dalo_library_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return
source "${__dalo_library_dir}/helpers.bashlib.sh" || return
unset __dalo_library_dir
# ============================================================================
# 0. OBJECT VARIABLE / CODE STORAGE BOOTSTRAP
# ============================================================================




define_variable_api() {
    local ns="$1"
    __asyncobj_ensure_variable_storage "$ns"

    local body
    body=$(cat <<EOF
${ns}_set_variable() {
    [ \$# -eq 3 ] || return 2
    local name="\$1" type="\$2" value="\$3"

    if [[ "\$name" == code.* ]]; then
        printf 'Chyba [${ns}]: namespace code.* je vyhrazen canonical code storage: %s\n' "\$name" >&2
        return 3
    fi

    ${ns}_VARIABLE_TYPE["\$name"]="\$type"
    ${ns}_VARIABLE_VALUE["\$name"]="\$value"
}

${ns}_get_variable() {
    [ \$# -eq 1 ] || [ \$# -eq 3 ] || return 2
    local name="\$1"
    [[ -v ${ns}_VARIABLE_TYPE[\$name] ]] || return 1
    local type="\${${ns}_VARIABLE_TYPE[\$name]}"
    local value="\${${ns}_VARIABLE_VALUE[\$name]}"

    if [ \$# -eq 3 ]; then
        printf -v "\$2" '%s' "\$type"
        printf -v "\$3" '%s' "\$value"
    else
        printf '%s %s\n' "\$type" "\$value"
    fi
}

${ns}_variable_exists() {
    [ \$# -eq 1 ] || return 2
    [[ -v ${ns}_VARIABLE_TYPE[\$1] ]]
}

${ns}_variable_type() {
    [ \$# -eq 1 ] || return 2
    ${ns}_variable_exists "\$1" || return 1
    printf '%s\n' "\${${ns}_VARIABLE_TYPE[\$1]}"
}

${ns}_variable_is_code() {
    [ \$# -eq 1 ] || return 2
    [[ "\$1" == code.* ]]
}

${ns}_list_variables() {
    [ \$# -le 1 ] || return 2
    local filter="\${1:-all}" name
    case "\$filter" in
        all|data|code) ;;
        *) return 2 ;;
    esac

    for name in "\${!${ns}_VARIABLE_TYPE[@]}"; do
        case "\$filter" in
            all)  ;;
            data) ${ns}_variable_is_code "\$name" && continue ;;
            code) ${ns}_variable_is_code "\$name" || continue ;;
        esac
        printf '%s\n' "\$name"
    done | LC_ALL=C sort
}

${ns}_unset_variable() {
    [ \$# -eq 1 ] || return 2
    local name="\$1"
    ${ns}_variable_exists "\$name" || return 1

    if ${ns}_variable_is_code "\$name"; then
        printf 'Chyba [${ns}]: protected code variable nelze odstranit přes unset_variable: %s\n' "\$name" >&2
        return 3
    fi

    unset "${ns}_VARIABLE_TYPE[\$name]" "${ns}_VARIABLE_VALUE[\$name]"
}

${ns}_validate_code() {
    [ \$# -eq 1 ] || return 2
    local code="\$1" tmp
    tmp="\$(mktemp "\${TMPDIR:-/tmp}/${ns}-code.XXXXXX")" || return 1
    printf '%s\n' "\$code" > "\$tmp"
    bash -n "\$tmp"
    local rc=\$?
    rm -f -- "\$tmp"
    return "\$rc"
}

${ns}_validate_object() {
    local tmp
    tmp="\$(mktemp "\${TMPDIR:-/tmp}/${ns}-object.XXXXXX")" || return 1
    printf '%s\n' "\${${ns}_variables_code}" > "\$tmp"
    bash -n "\$tmp"
    local rc=\$?
    rm -f -- "\$tmp"
    return "\$rc"
}

${ns}_apply_code() {
    [ \$# -eq 1 ] || return 2
    local code="\$1"
    ${ns}_validate_code "\$code" || {
        printf 'Chyba [${ns}]: X code odmítnut: bash -n selhal\n' >&2
        return 2
    }

    eval "\$code" || return

    local seq=\$(( \${${ns}_CODE_PATCH_SEQ:-0} + 1 ))
    ${ns}_CODE_PATCH_SEQ="\$seq"
    __asyncobj_record_code "${ns}" "x_patch_\$seq" "\$code"

    ${ns}_validate_object || {
        ${ns}_OBJECT_HEALTH="BROKEN"
        printf 'Chyba [${ns}]: object code po X neprošel self-diagnostic bash -n\n' >&2
        return 3
    }
    ${ns}_OBJECT_HEALTH="OK"
}
EOF
)
    __asyncobj_eval_body "$ns" "variable_api" "$body"
}

# ============================================================================
# 1. GENERICKÁ FIFO INFRASTRUKTURA
# ============================================================================

fifo_open() {
    local fifo_path="$1" fd_var="$2"
    mkdir -p -- "$(dirname -- "$fifo_path")"
    [ -p "$fifo_path" ] || mkfifo -m 600 "$fifo_path"
    local fd
    exec {fd}<>"$fifo_path"
    printf -v "$fd_var" '%s' "$fd"
}

fifo_close() {
    local fd="${1:-}"
    [ -n "$fd" ] && eval "exec $fd<&-" 2>/dev/null || true
}

# ============================================================================
# 2. ITERÁTORY A REKURZORY
# ============================================================================
# Přesunuto do samostatné knihovny iterators.bashlib.sh.
# iterators.bashlib.sh závisí na DALO core API (__asyncobj_eval_body a job pool).

# ============================================================================
# 6. DEFINICE METOD INSTANCE
# ============================================================================

define_default_worker_cleanup() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_default_worker_cleanup() {
    local worker_dir="\$1" slot_id="\${2:-}" exit_code="\${3:-0}"
    : "\$worker_dir" "\$slot_id" "\$exit_code"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_fifo_api() {
    local ns="$1"
    local body
    body=$(cat <<'EOF'
__NS___fifo_frame_encode() {
    local tag="$1"; shift
    local frame q arg
    printf -v frame '%s\t%d' "$tag" "$#"
    for arg in "$@"; do
        printf -v q '%q' "$arg"
        frame+=$'\t'"$q"
    done
    printf '%s' "$frame"
}

__NS___fifo_frame_decode() {
    local frame="$1" out_tag_name="$2" out_argv_name="$3"
    local _tag _argc _field i
    local -a fields=() decoded=()
    local -n out_tag_ref="$out_tag_name"
    local -n out_argv_ref="$out_argv_name"

    IFS=$'\t' read -r -a fields <<< "$frame"
    ((${#fields[@]} >= 2)) || return 2
    _tag="${fields[0]}"
    _argc="${fields[1]}"
    [[ "$_argc" =~ ^[0-9]+$ ]] || return 3
    ((${#fields[@]} == _argc + 2)) || return 4

    for ((i=0; i<_argc; i++)); do
        _field="${fields[i+2]}"
        eval "decoded[i]=$_field"
    done
    out_tag_ref="$_tag"
    out_argv_ref=("${decoded[@]}")
}

__NS___fifo_send() {
    local tag="$1"; shift
    local fd="${__NS___FIFO_FD:-}"; [ -n "$fd" ] || return 1
    local frame frame_bytes atomic_max

    frame="$(__NS___fifo_frame_encode "$tag" "$@")" || return

    # Frame v1 invariant:
    #   one physical line + trailing LF must fit into one atomic FIFO write budget.
    # PIPE_BUF is at least 512 by POSIX; Linux FIFOs normally expose 4096.
    # Allow an explicit override, otherwise query the FIFO path, with 512 as
    # the conservative portable fallback.
    atomic_max="${__NS___FIFO_ATOMIC_MAX:-}"
    if [ -z "$atomic_max" ]; then
        atomic_max="$(getconf PIPE_BUF "${__NS___FIFO_PATH}" 2>/dev/null || true)"
        [[ "$atomic_max" =~ ^[0-9]+$ ]] || atomic_max=512
        __NS___FIFO_ATOMIC_MAX="$atomic_max"
    fi

    frame_bytes="$(LC_ALL=C printf '%s\n' "$frame" | wc -c)"
    frame_bytes="${frame_bytes//[[:space:]]/}"

    if (( frame_bytes > atomic_max )); then
        printf 'Chyba [__NS__]: FIFO frame je příliš velký (%d > PIPE_BUF %d bytes), tag=%q\n' \
            "$frame_bytes" "$atomic_max" "$tag" >&2
        return 90
    fi

    # Exactly one shell printf invocation for the complete framed message.
    printf '%s\n' "$frame" >&"$fd"
}

__NS___fifo_output() {
    local slot_id="$1"; shift
    __NS___fifo_send O "$slot_id|out" "$*"
}

# Port-aware DATA output. The worker owns output-vector semantics; runtime only
# records the member under <slot>|<port> and transports it to the parent.
__NS___fifo_output_port() {
    [ $# -ge 3 ] || return 2
    local slot_id="$1" output_port="$2"; shift 2
    [[ "$output_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 2
    __NS___fifo_send O "$slot_id|$output_port" "$*"
}

__NS___fifo_set() {
    local var="$1"; shift
    __NS___fifo_send S "$var" "$*"
}

__NS___fifo_array_push() {
    local arr="$1"; shift
    __NS___fifo_send A "$arr" "$*"
}

__NS___fifo_exec() {
    local code="$1"
    __NS___fifo_send X "$code"
}

__NS___fifo_msg() {
    local tag="$1"; shift
    __NS___fifo_send "$tag" "$@"
}

__NS___fifo_call_parent() {
    local func="$1"; shift
    local code arg quoted
    printf -v code '%q' "$func"
    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        code+=" $quoted"
    done
    __NS___fifo_send C "$code"
}

__NS___drain_fifo() {
    local fd="${__NS___FIFO_FD:-}"; [ -n "$fd" ] || return 0
    local line tag
    local -a argv=()
    while :; do
        read -t 0 -u "$fd" || break
        IFS= read -r -u "$fd" line || break
        if ! __NS___fifo_frame_decode "$line" tag argv; then
            printf 'Chyba [__NS__]: neplatný FIFO frame: %q\n' "$line" >&2
            continue
        fi
        case "$tag" in
            O) ((${#argv[@]} == 2)) || continue
               __NS___OUTPUT_DATA_VECTOR["${argv[0]}"]="${argv[1]}" ;;
            S) ((${#argv[@]} == 2)) || continue
               printf -v "${argv[0]}" '%s' "${argv[1]}" ;;
            A) ((${#argv[@]} == 2)) || continue
               local -n _arr_ref="${argv[0]}"
               _arr_ref+=("${argv[1]}")
               unset -n _arr_ref ;;
            C) ((${#argv[@]} == 1)) || continue
               eval "${argv[0]}" ;;
            X) ((${#argv[@]} == 1)) || continue
               __NS___apply_code "${argv[0]}" ;;
            *)
               if declare -f "__NS___on_fifo_message" >/dev/null 2>&1; then
                   "__NS___on_fifo_message" "$tag" "${argv[@]}"
               fi ;;
        esac
    done
}
EOF
)
    body="${body//__NS__/$ns}"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_worker_cleanup_wrapper() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_worker_cleanup_wrapper() {
    local exit_code=\$?
    local worker_dir="\$1" slot_id="\$2" cleanup_func="\${3:-}"
    local task_id="\${4:-}" attempt="\${5:-}"
    if [ -n "\$cleanup_func" ] && declare -f "\$cleanup_func" >/dev/null 2>&1; then
        "\$cleanup_func" "\$worker_dir" "\$slot_id" "\$exit_code" || true
    fi
    ${ns}_default_worker_cleanup "\$worker_dir" "\$slot_id" "\$exit_code" || true
    ${ns}_fifo_call_parent "${ns}_mark_job_completed" \
        "\$slot_id" "\$BASHPID" "\$exit_code" "\$task_id" "\$attempt"
    exit "\$exit_code"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_job_pool_init() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_job_pool_init() {
    ${ns}_MAX_JOBS="\${1:-\$(nproc 2>/dev/null || echo 4)}"
    ${ns}_JOB_COUNTER=0
    ${ns}_PENDING_JOBS=0

    # Task layer v1 / STEP 1: identity, policy snapshot storage, timestamps.
    # NEXT_TASK_ID is per-object; task IDs are intentionally local to an object.
    ${ns}_NEXT_TASK_ID=1
    ${ns}_DEFAULT_RETRIES=0

    ${ns}_TARGET_WORKER_FUNC="\${2:-}"
    ${ns}_TARGET_CLEANUP_FUNC="\${3:-}"

    declare -gA ${ns}_INPUT_DATA_VECTOR
    declare -gA ${ns}_OUTPUT_DATA_VECTOR
    declare -gA ${ns}_EXIT_CODE_VECTOR
    declare -gA ${ns}_JOB_STATUS_VECTOR
    declare -gA ${ns}_WORKER_TMP_DIR
    declare -gA ${ns}_WORKER_PIDS
    declare -gA ${ns}_COMPLETED_PIDS
    declare -gA ${ns}_COMPLETION_EXIT_CODES
    declare -gA ${ns}_REAPED_PIDS
    declare -gA ${ns}_REAP_EXIT_CODES

    # Persistent task storage. No task API or argv storage yet (STEP 1 only).
    declare -gA ${ns}_TASK_STATUS
    declare -gA ${ns}_TASK_FUNC
    declare -gA ${ns}_TASK_ATTEMPT
    declare -gA ${ns}_TASK_RETRIES
    declare -gA ${ns}_TASK_CREATED
    declare -gA ${ns}_TASK_STARTED
    declare -gA ${ns}_TASK_FINISHED
    declare -gA ${ns}_DIAG
    declare -gA ${ns}_RESOURCE
    declare -gA ${ns}_BACKEND_SCOPE
    declare -gA ${ns}_BACKEND_CAPABILITIES
    declare -gA ${ns}_PEER_BACKEND
    declare -gA ${ns}_PEER_PROTOCOL
    declare -gA ${ns}_PEER_RESOURCE

    # Execution binding: ephemeral slot/attempt -> persistent task identity.
    declare -gA ${ns}_SLOT_TASK_ID
    declare -gA ${ns}_SLOT_ATTEMPT

    local main_tmp="\${MAIN_TMP_DIR:-\${TMPDIR:-/tmp}}"
    mkdir -p -- "\$main_tmp"
    ${ns}_FIFO_PATH="\$main_tmp/${ns}_pool.fifo"
    [ -p "\${${ns}_FIFO_PATH}" ] || mkfifo -m 600 "\${${ns}_FIFO_PATH}"
    local _fd
    exec {_fd}<>"\${${ns}_FIFO_PATH}"
    ${ns}_FIFO_FD="\$_fd"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_task_argv_api() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_task_argv_set() {
    local task_id="\$1"
    shift

    # One real Bash indexed array per task preserves argv boundaries exactly.
    # The variable is internal; callers use set/get helpers only.
    local array_name="${ns}_TASK_ARGV_\${task_id}"

    # Drop any previous argv atomically from the API point of view, then rebuild.
    unset "\$array_name" 2>/dev/null || true
    declare -g -a "\$array_name"
    local -n argv_ref="\$array_name"
    argv_ref=("\$@")
}

${ns}_task_argv_get() {
    local task_id="\$1"
    local out_name="\$2"
    local array_name="${ns}_TASK_ARGV_\${task_id}"

    # Missing argv is distinct from an existing empty argv.
    declare -p "\$array_name" >/dev/null 2>&1 || return 1

    local -n src_ref="\$array_name"
    local -n out_ref="\$out_name"
    out_ref=("\${src_ref[@]}")
}

${ns}_task_argv_forget() {
    local task_id="\$1"
    local array_name="${ns}_TASK_ARGV_\${task_id}"
    unset "\$array_name" 2>/dev/null || true
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_task_mutation_api() {
    local ns="$1"
    local body
    body=$(cat <<EOF
# Parent/owner-side task mutations. These are the canonical state writers.
${ns}_task_do_submit() {
    [ \$# -ge 1 ] || return 2
    local worker_func="\$1"
    shift

    local task_id="\${${ns}_NEXT_TASK_ID}"
    ${ns}_NEXT_TASK_ID=\$((task_id + 1))

    ${ns}_TASK_STATUS[\$task_id]="QUEUED"
    ${ns}_TASK_FUNC[\$task_id]="\$worker_func"
    ${ns}_TASK_ATTEMPT[\$task_id]=0
    ${ns}_TASK_RETRIES[\$task_id]="\${${ns}_DEFAULT_RETRIES}"
    printf -v "${ns}_TASK_CREATED[\$task_id]" '%(%s)T' -1
    unset "${ns}_TASK_STARTED[\$task_id]" "${ns}_TASK_FINISHED[\$task_id]" 2>/dev/null || true

    ${ns}_task_argv_set "\$task_id" "\$@"
    ${ns}_LAST_TASK_ID="\$task_id"
}

${ns}_task_exists() {
    [ \$# -eq 1 ] || return 2
    [[ -v ${ns}_TASK_STATUS[\$1] ]]
}

${ns}_task_do_argv_set() {
    [ \$# -ge 1 ] || return 2
    local task_id="\$1"
    shift
    ${ns}_task_exists "\$task_id" || return 1
    ${ns}_task_argv_set "\$task_id" "\$@"
}

${ns}_task_do_forget() {
    [ \$# -eq 1 ] || return 2
    local task_id="\$1"
    ${ns}_task_exists "\$task_id" || return 1

    local status="\${${ns}_TASK_STATUS[\$task_id]}"

    # Never erase canonical metadata while an attempt may still own a slot/PID.
    [ "\$status" != "RUNNING" ] || {
        printf 'Chyba [${ns}]: nelze zapomenout RUNNING task=%s\n' "\$task_id" >&2
        return 3
    }

    local slot
    for slot in "\${!${ns}_SLOT_TASK_ID[@]}"; do
        if [ "\${${ns}_SLOT_TASK_ID[\$slot]:-}" = "\$task_id" ]; then
            printf 'Chyba [${ns}]: task=%s je stále navázán na slot=%s\n' "\$task_id" "\$slot" >&2
            return 3
        fi
    done

    ${ns}_task_argv_forget "\$task_id"
    unset "${ns}_TASK_STATUS[\$task_id]" \
          "${ns}_TASK_FUNC[\$task_id]" \
          "${ns}_TASK_ATTEMPT[\$task_id]" \
          "${ns}_TASK_RETRIES[\$task_id]" \
          "${ns}_TASK_CREATED[\$task_id]" \
          "${ns}_TASK_STARTED[\$task_id]" \
          "${ns}_TASK_FINISHED[\$task_id]" 2>/dev/null || true

    if [ "\${${ns}_LAST_TASK_ID:-}" = "\$task_id" ]; then
        unset ${ns}_LAST_TASK_ID
    fi
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_task_api() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_task() {
    local op="\${1:-}"
    [ \$# -gt 0 ] && shift

    case "\$op" in
        submit)
            [ \$# -ge 1 ] || {
                echo "Chyba: ${ns}_task submit vyžaduje worker funkci." >&2
                return 2
            }
            ${ns}_task_do_submit "\$@"
            ;;

        start)
            [ \$# -eq 1 ] || return 2
            ${ns}_task_do_start "\$1"
            ;;

        rerun)
            [ \$# -eq 1 ] || return 2
            ${ns}_task_do_rerun "\$1"
            ;;

        forget)
            [ \$# -eq 1 ] || return 2
            ${ns}_task_do_forget "\$1"
            ;;

        retries)
            [ \$# -ge 1 ] || return 2
            local retries_op="\$1"
            shift
            case "\$retries_op" in
                get)
                    [ \$# -eq 1 ] || return 2
                    [[ -v ${ns}_TASK_STATUS[\$1] ]] || return 1
                    printf '%s\n' "\${${ns}_TASK_RETRIES[\$1]}"
                    ;;
                set)
                    [ \$# -eq 2 ] || return 2
                    ${ns}_task_do_retries_set "\$1" "\$2"
                    ;;
                left)
                    [ \$# -eq 1 ] || return 2
                    ${ns}_task_retries_left "\$1"
                    ;;
                *)
                    return 2
                    ;;
            esac
            ;;

        status)
            [ \$# -eq 1 ] || {
                echo "Chyba: ${ns}_task status vyžaduje TASK_ID." >&2
                return 2
            }
            local task_id="\$1"
            [[ -v ${ns}_TASK_STATUS[\$task_id] ]] || return 1
            printf '%s\n' "\${${ns}_TASK_STATUS[\$task_id]}"
            ;;

        time)
            [ \$# -eq 2 ] || {
                echo "Chyba: ${ns}_task time vyžaduje {created|started|finished} TASK_ID." >&2
                return 2
            }
            local time_op="\$1" task_id="\$2"
            case "\$time_op" in
                created)
                    [[ -v ${ns}_TASK_CREATED[\$task_id] ]] || return 1
                    printf '%s\n' "\${${ns}_TASK_CREATED[\$task_id]}"
                    ;;
                started)
                    [[ -v ${ns}_TASK_STARTED[\$task_id] ]] || return 1
                    printf '%s\n' "\${${ns}_TASK_STARTED[\$task_id]}"
                    ;;
                finished)
                    [[ -v ${ns}_TASK_FINISHED[\$task_id] ]] || return 1
                    printf '%s\n' "\${${ns}_TASK_FINISHED[\$task_id]}"
                    ;;
                *)
                    echo "Chyba: neznámá ${ns}_task time operace: \$time_op" >&2
                    return 2
                    ;;
            esac
            ;;

        argv)
            [ \$# -ge 1 ] || {
                echo "Chyba: ${ns}_task argv vyžaduje operaci." >&2
                return 2
            }
            local argv_op="\$1"
            shift
            case "\$argv_op" in
                set)
                    ${ns}_task_do_argv_set "\$@"
                    ;;
                get)
                    [ \$# -eq 2 ] || return 2
                    local task_id="\$1" out_name="\$2"
                    [[ -v ${ns}_TASK_STATUS[\$task_id] ]] || return 1
                    ${ns}_task_argv_get "\$task_id" "\$out_name"
                    ;;
                *)
                    echo "Chyba: neznámá ${ns}_task argv operace: \$argv_op" >&2
                    return 2
                    ;;
            esac
            ;;

        *)
            echo "Chyba: neznámá ${ns}_task operace: \$op" >&2
            return 2
            ;;
    esac
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_task_state_api() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_task_status_is_terminal() {
    case "\$1" in
        SUCCESS|FAILED|POSSIBLE_DATA_LOSS|ABNORMAL_TERMINATION|PROTOCOL_INCONSISTENCY) return 0 ;;
        *) return 1 ;;
    esac
}

${ns}_task_transition() {
    local task_id="\$1" from="\$2" to="\$3"
    [[ -v ${ns}_TASK_STATUS[\$task_id] ]] || return 1
    local current="\${${ns}_TASK_STATUS[\$task_id]}"

    [ "\$current" = "\$from" ] || {
        printf 'Chyba [${ns}]: task transition invariant: task=%s expected=%s current=%s target=%s\n' \
            "\$task_id" "\$from" "\$current" "\$to" >&2
        return 1
    }

    case "\$from:\$to" in
        QUEUED:RUNNING|RUNNING:SUCCESS|RUNNING:FAILED|RUNNING:POSSIBLE_DATA_LOSS|RUNNING:ABNORMAL_TERMINATION|RUNNING:PROTOCOL_INCONSISTENCY|SUCCESS:QUEUED|FAILED:QUEUED|POSSIBLE_DATA_LOSS:QUEUED|ABNORMAL_TERMINATION:QUEUED|PROTOCOL_INCONSISTENCY:QUEUED) ;;
        *)
            printf 'Chyba [${ns}]: nepovolený task transition: task=%s %s -> %s\n' \
                "\$task_id" "\$from" "\$to" >&2
            return 1
            ;;
    esac
    ${ns}_TASK_STATUS["\$task_id"]="\$to"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_task_retry_api() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_task_retries_left() {
    local task_id="\$1"
    [[ -v ${ns}_TASK_STATUS[\$task_id] ]] || return 1
    local retries="\${${ns}_TASK_RETRIES[\$task_id]:-0}"
    local attempts="\${${ns}_TASK_ATTEMPT[\$task_id]:-0}"
    local left=\$(( retries + 1 - attempts ))
    (( left < 0 )) && left=0
    printf '%s\n' "\$left"
}

${ns}_task_do_retries_set() {
    local task_id="\$1" retries="\$2"
    [[ -v ${ns}_TASK_STATUS[\$task_id] ]] || return 1
    [[ "\$retries" =~ ^[0-9]+$ ]] || return 2
    ${ns}_TASK_RETRIES["\$task_id"]="\$retries"
}

${ns}_task_do_rerun() {
    local task_id="\$1"
    [[ -v ${ns}_TASK_STATUS[\$task_id] ]] || return 1
    local status="\${${ns}_TASK_STATUS[\$task_id]}"

    ${ns}_task_status_is_terminal "\$status" || {
        printf 'Chyba [${ns}]: task %s nelze rerun ze stavu %s\n' "\$task_id" "\$status" >&2
        return 1
    }

    local left
    left="\$(${ns}_task_retries_left "\$task_id")" || return \$?
    (( left > 0 )) || {
        printf 'Chyba [${ns}]: task %s vyčerpal retries (attempt=%s retries=%s)\n' \
            "\$task_id" "\${${ns}_TASK_ATTEMPT[\$task_id]:-0}" "\${${ns}_TASK_RETRIES[\$task_id]:-0}" >&2
        return 1
    }

    ${ns}_task_transition "\$task_id" "\$status" QUEUED || return 1
    unset "${ns}_TASK_STARTED[\$task_id]" "${ns}_TASK_FINISHED[\$task_id]" 2>/dev/null || true

    if ${ns}_task_do_start "\$task_id"; then
        return 0
    else
        local rc=\$?
        # task_do_start restores QUEUED if no worker was accepted.
        return "\$rc"
    fi
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_task_execution_api() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_task_do_start() {
    local task_id="\$1"
    [[ -v ${ns}_TASK_STATUS[\$task_id] ]] || return 1
    [ "\${${ns}_TASK_STATUS[\$task_id]}" = "QUEUED" ] || return 1

    local func="\${${ns}_TASK_FUNC[\$task_id]}"
    local -a argv=()
    ${ns}_task_argv_get "\$task_id" argv || return 1
    local attempt=\$(( \${${ns}_TASK_ATTEMPT[\$task_id]:-0} + 1 ))

    # Canonical identity is published before the child can report completion.
    ${ns}_TASK_ATTEMPT["\$task_id"]="\$attempt"
    ${ns}_task_transition "\$task_id" QUEUED RUNNING || return 1
    printf -v "${ns}_TASK_STARTED[\$task_id]" '%(%s)T' -1
    unset "${ns}_TASK_FINISHED[\$task_id]" 2>/dev/null || true

    if ${ns}_job_pool_submit_task "\$task_id" "\$attempt" "\$func" "" "\${argv[@]}"; then
        return 0
    else
        local rc=\$?
        # No worker was accepted: restore the pre-start canonical state.
        ${ns}_TASK_STATUS["\$task_id"]="QUEUED"
        ${ns}_TASK_ATTEMPT["\$task_id"]=\$((attempt - 1))
        unset "${ns}_TASK_STARTED[\$task_id]" "${ns}_TASK_FINISHED[\$task_id]" 2>/dev/null || true
        return "\$rc"
    fi
}

${ns}_task_do_attempt_terminal() {
    local task_id="\$1" attempt="\$2" slot_id="\$3" status="\$4"
    local bound_task="\${${ns}_SLOT_TASK_ID[\$slot_id]:-}"
    local bound_attempt="\${${ns}_SLOT_ATTEMPT[\$slot_id]:-}"

    [ -n "\$bound_task" ] || return 0
    if [ "\$bound_task" != "\$task_id" ] || \
       [ "\$bound_attempt" != "\$attempt" ] || \
       [ "\${${ns}_TASK_ATTEMPT[\$task_id]:-}" != "\$attempt" ]; then
        printf 'Chyba [${ns}]: terminal identity invariant: slot=%s bound=%s/%s got=%s/%s\n' \
            "\$slot_id" "\$bound_task" "\$bound_attempt" "\$task_id" "\$attempt" >&2
        return 1
    fi

    ${ns}_task_status_is_terminal "\$status" || return 1
    ${ns}_task_transition "\$task_id" RUNNING "\$status" || return 1
    printf -v "${ns}_TASK_FINISHED[\$task_id]" '%(%s)T' -1
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_try_release_slot() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_try_release_slot() {
    local slot_id="\$1" pid="\$2"
    local current_pid="\${${ns}_WORKER_PIDS[\$slot_id]:-}"
    local completed_pid="\${${ns}_COMPLETED_PIDS[\$slot_id]:-}"
    local reaped_pid="\${${ns}_REAPED_PIDS[\$slot_id]:-}"

    [ -n "\$current_pid" ] || return 0
    [ "\$current_pid" = "\$pid" ] || return 0
    [ "\$completed_pid" = "\$pid" ] || return 0
    [ "\$reaped_pid" = "\$pid" ] || return 0

    local completion_rc="\${${ns}_COMPLETION_EXIT_CODES[\$slot_id]:-}"
    local reap_rc="\${${ns}_REAP_EXIT_CODES[\$slot_id]:-}"
    if [ "\$completion_rc" != "\$reap_rc" ]; then
        printf 'Chyba [${ns}]: completion/reap RC invariant selhal: slot=%s pid=%s completion_rc=%s reap_rc=%s\n' \
            "\$slot_id" "\$pid" "\${completion_rc:-<none>}" "\${reap_rc:-<none>}" >&2
        ${ns}_EXIT_CODE_VECTOR["\$slot_id"]="\$reap_rc"
        ${ns}_JOB_STATUS_VECTOR["\$slot_id"]="PROTOCOL_INCONSISTENCY"
    else
        ${ns}_EXIT_CODE_VECTOR["\$slot_id"]="\$reap_rc"
        if [ "\$reap_rc" -eq 0 ]; then
            ${ns}_JOB_STATUS_VECTOR["\$slot_id"]="SUCCESS"
        else
            ${ns}_JOB_STATUS_VECTOR["\$slot_id"]="FAILED"
        fi
    fi

    ${ns}_PENDING_JOBS=\$(( ${ns}_PENDING_JOBS - 1 ))

    local task_id="\${${ns}_SLOT_TASK_ID[\$slot_id]:-}"
    local attempt="\${${ns}_SLOT_ATTEMPT[\$slot_id]:-}"
    if [ -n "\$task_id" ]; then
        ${ns}_task_do_attempt_terminal "\$task_id" "\$attempt" "\$slot_id" \
            "\${${ns}_JOB_STATUS_VECTOR[\$slot_id]}"
    fi

    # Only a verified completion may flow into the normal completion hook.
    # An RC disagreement is terminal, but untrusted as a successful task result.
    if [ "\${${ns}_JOB_STATUS_VECTOR[\$slot_id]}" != "PROTOCOL_INCONSISTENCY" ] && \
       declare -f "${ns}_on_job_completed" >/dev/null 2>&1; then
        "${ns}_on_job_completed" "\$slot_id" "\$completion_rc" \
            "\${${ns}_OUTPUT_DATA_VECTOR["\$slot_id|out"]:-}"
    fi

    local worker_dir="\${${ns}_WORKER_TMP_DIR[\$slot_id]:-}"
    [ -n "\$worker_dir" ] && rm -rf -- "\$worker_dir" 2>/dev/null || true

    unset "${ns}_WORKER_PIDS[\$slot_id]"
    unset "${ns}_COMPLETED_PIDS[\$slot_id]"
    unset "${ns}_COMPLETION_EXIT_CODES[\$slot_id]"
    unset "${ns}_REAPED_PIDS[\$slot_id]"
    unset "${ns}_REAP_EXIT_CODES[\$slot_id]"
    unset "${ns}_WORKER_TMP_DIR[\$slot_id]"
    unset "${ns}_SLOT_TASK_ID[\$slot_id]"
    unset "${ns}_SLOT_ATTEMPT[\$slot_id]"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_finalize_missing_completion() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_finalize_missing_completion() {
    local slot_id="\$1" pid="\$2"
    local current_pid="\${${ns}_WORKER_PIDS[\$slot_id]:-}"
    local reaped_pid="\${${ns}_REAPED_PIDS[\$slot_id]:-}"
    local completed_pid="\${${ns}_COMPLETED_PIDS[\$slot_id]:-}"
    local reap_rc="\${${ns}_REAP_EXIT_CODES[\$slot_id]:-}"

    [ "\$current_pid" = "\$pid" ] || return 0
    [ "\$reaped_pid" = "\$pid" ] || return 0
    [ -z "\$completed_pid" ] || return 0

    ${ns}_EXIT_CODE_VECTOR["\$slot_id"]="\$reap_rc"
    if [ "\$reap_rc" -eq 0 ]; then
        ${ns}_JOB_STATUS_VECTOR["\$slot_id"]="POSSIBLE_DATA_LOSS"
    else
        ${ns}_JOB_STATUS_VECTOR["\$slot_id"]="ABNORMAL_TERMINATION"
    fi

    printf 'Chyba [${ns}]: worker reaped bez completion: slot=%s pid=%s rc=%s status=%s\n' \
        "\$slot_id" "\$pid" "\$reap_rc" "\${${ns}_JOB_STATUS_VECTOR[\$slot_id]}" >&2

    ${ns}_PENDING_JOBS=\$(( ${ns}_PENDING_JOBS - 1 ))

    local task_id="\${${ns}_SLOT_TASK_ID[\$slot_id]:-}"
    local attempt="\${${ns}_SLOT_ATTEMPT[\$slot_id]:-}"
    if [ -n "\$task_id" ]; then
        ${ns}_task_do_attempt_terminal "\$task_id" "\$attempt" "\$slot_id" \
            "\${${ns}_JOB_STATUS_VECTOR[\$slot_id]}"
    fi

    local worker_dir="\${${ns}_WORKER_TMP_DIR[\$slot_id]:-}"
    [ -n "\$worker_dir" ] && rm -rf -- "\$worker_dir" 2>/dev/null || true

    unset "${ns}_WORKER_PIDS[\$slot_id]"
    unset "${ns}_COMPLETED_PIDS[\$slot_id]"
    unset "${ns}_COMPLETION_EXIT_CODES[\$slot_id]"
    unset "${ns}_REAPED_PIDS[\$slot_id]"
    unset "${ns}_REAP_EXIT_CODES[\$slot_id]"
    unset "${ns}_WORKER_TMP_DIR[\$slot_id]"
    unset "${ns}_SLOT_TASK_ID[\$slot_id]"
    unset "${ns}_SLOT_ATTEMPT[\$slot_id]"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_mark_reaped() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_mark_reaped() {
    local pid="\$1" reap_rc="\$2" slot_id current_pid
    for (( slot_id=1; slot_id<=\${${ns}_MAX_JOBS}; slot_id++ )); do
        current_pid="\${${ns}_WORKER_PIDS[\$slot_id]:-}"
        if [ "\$current_pid" = "\$pid" ]; then
            ${ns}_REAPED_PIDS["\$slot_id"]="\$pid"
            ${ns}_REAP_EXIT_CODES["\$slot_id"]="\$reap_rc"
            ${ns}_try_release_slot "\$slot_id" "\$pid"
            return
        fi
    done
    printf 'Chyba [${ns}]: reap PID nenalezen v aktivních slotech: pid=%s rc=%s\n' "\$pid" "\$reap_rc" >&2
    return 1
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_reap_one() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_reap_one() {
    local reaped_pid reap_rc slot_id pid
    local -a wait_pids=()

    # Reap only children owned by this pool/object.  A bare `wait -n` could
    # consume an unrelated child belonging to another async object or to the
    # parent shell itself.
    for (( slot_id=1; slot_id<=\${${ns}_MAX_JOBS}; slot_id++ )); do
        pid="\${${ns}_WORKER_PIDS[\$slot_id]:-}"
        [ -n "\$pid" ] && wait_pids+=("\$pid")
    done

    if [ "\${#wait_pids[@]}" -eq 0 ]; then
        ${ns}_drain_fifo
        return 0
    fi

    if wait -n -p reaped_pid "\${wait_pids[@]}" 2>/dev/null; then
        reap_rc=0
    else
        reap_rc=\$?
    fi

    if [ -n "\${reaped_pid:-}" ]; then
        ${ns}_mark_reaped "\$reaped_pid" "\$reap_rc"
    fi

    # Completion is emitted by the child's EXIT trap before process exit.
    # Therefore drain after reap before classifying a missing completion.
    ${ns}_drain_fifo

    if [ -n "\${reaped_pid:-}" ]; then
        for (( slot_id=1; slot_id<=\${${ns}_MAX_JOBS}; slot_id++ )); do
            if [ "\${${ns}_WORKER_PIDS[\$slot_id]:-}" = "\$reaped_pid" ] && \
               [ "\${${ns}_REAPED_PIDS[\$slot_id]:-}" = "\$reaped_pid" ] && \
               [ -z "\${${ns}_COMPLETED_PIDS[\$slot_id]:-}" ]; then
                ${ns}_finalize_missing_completion "\$slot_id" "\$reaped_pid"
                break
            fi
        done
    fi
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_mark_job_completed() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_mark_job_completed() {
    local slot_id="\$1" worker_pid="\$2" exit_code="\${3:-0}"
    local task_id="\${4:-}" attempt="\${5:-}"
    local expected_pid="\${${ns}_WORKER_PIDS[\$slot_id]:-}"
    local expected_task="\${${ns}_SLOT_TASK_ID[\$slot_id]:-}"
    local expected_attempt="\${${ns}_SLOT_ATTEMPT[\$slot_id]:-}"

    if [ -z "\$worker_pid" ] || [ -z "\$expected_pid" ] || [ "\$worker_pid" != "\$expected_pid" ]; then
        printf 'Chyba [${ns}]: completion PID invariant selhal: slot=%s expected_pid=%s worker_pid=%s exit=%s\n' \
            "\$slot_id" "\${expected_pid:-<none>}" "\${worker_pid:-<none>}" "\$exit_code" >&2
        return 1
    fi

    if [ -n "\$expected_task" ]; then
        if [ "\$task_id" != "\$expected_task" ] || [ "\$attempt" != "\$expected_attempt" ]; then
            printf 'Chyba [${ns}]: task/attempt invariant selhal: slot=%s expected=%s/%s got=%s/%s pid=%s\n' \
                "\$slot_id" "\$expected_task" "\$expected_attempt" "\${task_id:-<none>}" "\${attempt:-<none>}" "\$worker_pid" >&2
            return 1
        fi
    fi

    ${ns}_COMPLETED_PIDS["\$slot_id"]="\$worker_pid"
    ${ns}_COMPLETION_EXIT_CODES["\$slot_id"]="\$exit_code"
    ${ns}_try_release_slot "\$slot_id" "\$worker_pid"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_forward_hook() {
    local ns="$1" ns_out="$2"
    local body
    body=$(cat <<EOF
${ns}_on_job_completed() {
    local slot_id="\$1" exit_code="\$2" output="\$3"
    if [ "\$exit_code" -eq 0 ]; then
        ${ns_out}_summon_worker "\$output"
    fi
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_summon_worker() {
    local ns="$1"
    local body
    body=$(cat <<EOF
# Canonical OBJECT -> WORKER boundary.
# ABI: summon_worker INPUT_PORT DATA...
${ns}_summon_worker() {
    [ \$# -ge 1 ] || return 2
    local input_port="\$1"; shift
    [[ "\$input_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$ ]] || return 2
    ${ns}_job_pool_add_work_port "\$input_port" "\$@"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_job_pool_add_work() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_job_pool_add_work() {
    ${ns}_job_pool_add_work_port in "\$@"
}

${ns}_job_pool_add_work_port() {
    [ \$# -ge 1 ] || return 2
    local input_port="\$1"; shift
    local worker_func="\${${ns}_TARGET_WORKER_FUNC}"
    local cleanup_func="\${${ns}_TARGET_CLEANUP_FUNC}"
    ${ns}_job_pool_submit_port "\$input_port" "\$worker_func" "\$cleanup_func" "\$@"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_job_pool_submit() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_job_pool_submit_core() {
    local task_id="\$1" attempt="\$2" cmd_func="\$3" cleanup_func="\${4:-}" input_port="\${5:-in}"
    shift 5 2>/dev/null || shift \$#

    while [ "\${${ns}_PENDING_JOBS}" -ge "\${${ns}_MAX_JOBS}" ]; do
        ${ns}_reap_one
    done

    local slot_id=0 i
    for (( i=1; i<=\${${ns}_MAX_JOBS}; i++ )); do
        if [ -z "\${${ns}_WORKER_PIDS[\$i]:-}" ]; then
            slot_id=\$i; break
        fi
    done
    if [ "\$slot_id" -eq 0 ]; then
        echo "Chyba [${ns}]: žádný volný slot" >&2
        return 1
    fi

    ${ns}_PENDING_JOBS=\$(( ${ns}_PENDING_JOBS + 1 ))
    ${ns}_JOB_COUNTER=\$(( ${ns}_JOB_COUNTER + 1 ))

    local main_tmp="\${MAIN_TMP_DIR:-\${TMPDIR:-/tmp}}"
    local worker_dir="\$main_tmp/${ns}_slot_\$slot_id"
    rm -rf -- "\$worker_dir"; mkdir -p "\$worker_dir"

    ${ns}_INPUT_DATA_VECTOR["\$slot_id|\$input_port"]="\$*"
    local vector_key
    for vector_key in "\${!${ns}_OUTPUT_DATA_VECTOR[@]}"; do
        [[ "\$vector_key" == "\$slot_id|"* ]] && unset '${ns}_OUTPUT_DATA_VECTOR['"\$vector_key"']'
    done
    unset "${ns}_EXIT_CODE_VECTOR[\$slot_id]" \
          "${ns}_JOB_STATUS_VECTOR[\$slot_id]" "${ns}_COMPLETED_PIDS[\$slot_id]" \
          "${ns}_COMPLETION_EXIT_CODES[\$slot_id]" "${ns}_REAPED_PIDS[\$slot_id]" \
          "${ns}_REAP_EXIT_CODES[\$slot_id]" 2>/dev/null || true
    ${ns}_WORKER_TMP_DIR["\$slot_id"]="\$worker_dir"

    if [ -n "\$task_id" ]; then
        ${ns}_SLOT_TASK_ID["\$slot_id"]="\$task_id"
        ${ns}_SLOT_ATTEMPT["\$slot_id"]="\$attempt"
    else
        unset "${ns}_SLOT_TASK_ID[\$slot_id]" "${ns}_SLOT_ATTEMPT[\$slot_id]" 2>/dev/null || true
    fi

    (
        set -eu
        cd "\$worker_dir" 2>/dev/null || true
        trap '${ns}_worker_cleanup_wrapper "\$worker_dir" "\$slot_id" "\$cleanup_func" "\$task_id" "\$attempt"' EXIT INT TERM
        "\$cmd_func" "\$worker_dir" "\$slot_id" "\$@"
    ) &

    ${ns}_WORKER_PIDS["\$slot_id"]=\$!
}

${ns}_job_pool_submit() {
    local cmd_func="\$1" cleanup_func="\${2:-}"
    shift 2 2>/dev/null || shift \$#
    ${ns}_job_pool_submit_core "" "" "\$cmd_func" "\$cleanup_func" in "\$@"
}

${ns}_job_pool_submit_port() {
    local input_port="\$1" cmd_func="\$2" cleanup_func="\${3:-}"
    shift 3 2>/dev/null || shift \$#
    ${ns}_job_pool_submit_core "" "" "\$cmd_func" "\$cleanup_func" "\$input_port" "\$@"
}

${ns}_job_pool_submit_task() {
    local task_id="\$1" attempt="\$2" cmd_func="\$3" cleanup_func="\${4:-}"
    shift 4 2>/dev/null || shift \$#
    ${ns}_job_pool_submit_core "\$task_id" "\$attempt" "\$cmd_func" "\$cleanup_func" in "\$@"
}

${ns}_job_pool_submit_task_port() {
    local task_id="\$1" attempt="\$2" input_port="\$3" cmd_func="\$4" cleanup_func="\${5:-}"
    shift 5 2>/dev/null || shift \$#
    ${ns}_job_pool_submit_core "\$task_id" "\$attempt" "\$cmd_func" "\$cleanup_func" "\$input_port" "\$@"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_job_pool_wait() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_job_pool_wait() {
    while [ "\${${ns}_PENDING_JOBS}" -gt 0 ]; do
        ${ns}_reap_one
    done
    ${ns}_drain_fifo
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_audit_job_pool() {
    local ns="$1"
    local body
    body=$(cat <<EOF
${ns}_audit_job_pool() {
    local validate_func="\$1"
    echo "--- Parallel Job State Audit [Instance: ${ns}] ---"
    local slot
    for (( slot=1; slot<=\${${ns}_MAX_JOBS}; slot++ )); do
        local in_vec="\${${ns}_INPUT_DATA_VECTOR[\$slot]:-}"
        local worker_dir="\${${ns}_WORKER_TMP_DIR[\$slot]:-}"
        local pid="\${${ns}_WORKER_PIDS[\$slot]:-none}"
        [ -z "\$in_vec" ] && continue
        echo "Worker Slot [\$slot] (PID \$pid):"
        if [[ ! -v ${ns}_OUTPUT_DATA_VECTOR["\$slot"] ]]; then
            echo "  └─ [FAIL] Output vector undefined."
            "\$validate_func" "\$slot" "UNFINISHED" "\$in_vec" "" "\$worker_dir"
        else
            local out_vec="\${${ns}_OUTPUT_DATA_VECTOR[\$slot]}"
            local ec="\${${ns}_EXIT_CODE_VECTOR[\$slot]:-?}"
            if "\$validate_func" "\$slot" "COMPLETED" "\$in_vec" "\$out_vec" "\$worker_dir"; then
                echo "  └─ [OK] Verification successful (exit=\$ec)."
            else
                echo "  └─ [FAIL] Integrity validation failed (exit=\$ec)."
            fi
        fi
    done
    echo "--------------------------------------------------"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

# ============================================================================
# 7. ENDPOINT-SPECIFICKÉ METODY
# ============================================================================
#
# Endpoint nemá downstream. Místo forwardu bufferuje a flushuje na FD.
# ============================================================================

define_endpoint_api() {
    local ns="$1"
    local out_fd="$2"
    local buffer_file="$3"
    local flush_threshold="$4"

    local body
    body=$(cat <<EOF
${ns}_ENDPOINT_OUT_FD="$out_fd"
${ns}_ENDPOINT_FLUSH_THRESHOLD="$flush_threshold"
${ns}_ENDPOINT_BUFFER_FILE="$buffer_file"
${ns}_ENDPOINT_BUFFER_SIZE=0
${ns}_ENDPOINT_JOBS_APPENDED=0
${ns}_ENDPOINT_JOBS_FLUSHED=0

# Inicializuj buffer (pokud uživatel nezadal cestu, vytvoř temp).
${ns}_endpoint_init() {
    local bf="\${${ns}_ENDPOINT_BUFFER_FILE}"
    if [ -z "\$bf" ]; then
        local tmp="\${MAIN_TMP_DIR:-\${TMPDIR:-/tmp}}"
        bf="\$tmp/${ns}_endpoint_buffer.\$\$"
    fi
    mkdir -p -- "\$(dirname -- "\$bf")"
    : > "\$bf"
    ${ns}_ENDPOINT_BUFFER_FILE="\$bf"
    ${ns}_ENDPOINT_BUFFER_SIZE=0
    ${ns}_ENDPOINT_JOBS_APPENDED=0
    ${ns}_ENDPOINT_JOBS_FLUSHED=0
}

# Přidej jednu položku do bufferu. Když buffer přesáhne threshold,
# automaticky flushuj.
${ns}_endpoint_append() {
    local data="\$1"
    local bf="\${${ns}_ENDPOINT_BUFFER_FILE}"
    printf '%s\n' "\$data" >> "\$bf"
    ${ns}_ENDPOINT_BUFFER_SIZE=\$(( ${ns}_ENDPOINT_BUFFER_SIZE + \${#data} + 1 ))
    ${ns}_ENDPOINT_JOBS_APPENDED=\$(( ${ns}_ENDPOINT_JOBS_APPENDED + 1 ))
    if [ "\${${ns}_ENDPOINT_BUFFER_SIZE}" -ge "\${${ns}_ENDPOINT_FLUSH_THRESHOLD}" ]; then
        ${ns}_endpoint_flush
    fi
}

# Flush buffer → output fd, buffer se vyprázdní.
${ns}_endpoint_flush() {
    local bf="\${${ns}_ENDPOINT_BUFFER_FILE}"
    local fd="\${${ns}_ENDPOINT_OUT_FD}"
    [ -n "\$bf" ] && [ -s "\$bf" ] || return 0
    cat -- "\$bf" >&"\$fd"
    : > "\$bf"
    ${ns}_ENDPOINT_BUFFER_SIZE=0
    ${ns}_ENDPOINT_JOBS_FLUSHED=\${${ns}_ENDPOINT_JOBS_APPENDED}
}

# Uzavři endpoint: flush + smaž buffer.
${ns}_endpoint_close() {
    ${ns}_endpoint_flush
    local bf="\${${ns}_ENDPOINT_BUFFER_FILE}"
    [ -n "\$bf" ] && rm -f -- "\$bf"
    ${ns}_ENDPOINT_BUFFER_FILE=""
}

# Endpoint: on_job_completed bufferuje místo forwardu.
# (Přepíše defaultní chování – forward hook nebyl definován, protože
#  endpoint nemá ns_out.)
${ns}_on_job_completed() {
    local slot_id="\$1" exit_code="\$2" output="\$3"
    [ "\$exit_code" -eq 0 ] || return 0
    ${ns}_endpoint_append "\$output"
}

# Výchozí endpoint worker: identity – přepíše se uživatelem.
${ns}_default_endpoint_worker() {
    local worker_dir="\$1" slot_id="\$2"
    shift 2
    : "\$worker_dir" "\$slot_id"
    printf '%s\n' "\$*"
}

# Pohodlná zkratka: počkej na dokončení + flush.
${ns}_endpoint_finalize() {
    ${ns}_job_pool_wait
    ${ns}_endpoint_flush
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"

    "${ns}_endpoint_init"
}

# ============================================================================
# 7B. MACHINE-READABLE OBJECT DIAGNOSTICS
# ============================================================================

define_diagnostic_api() {
    local ns="$1" body
    body=$(cat <<EOF
${ns}_diag_set() {
    [ \$# -eq 2 ] || return 2
    ${ns}_DIAG["\$1"]="\$2"
}
${ns}_diag_get() {
    [ \$# -eq 1 ] || return 2
    [[ -v ${ns}_DIAG[\$1] ]] || return 1
    printf '%s\n' "\${${ns}_DIAG[\$1]}"
}
${ns}_diagnose() {
    ${ns}_DIAG=()
    local failed=0 slot pid task_id attempt status name
    local -A seen_task_slots=()
    ${ns}_diag_set schema.version 1

    if ${ns}_validate_object >/dev/null 2>&1; then
        ${ns}_diag_set code.status OK
    else
        ${ns}_diag_set code.status FAIL
        ${ns}_diag_set code.error BASH_N_FAILED
        failed=1
    fi

    ${ns}_diag_set variables.status OK
    for name in "\${!${ns}_VARIABLE_TYPE[@]}"; do
        if [[ ! -v ${ns}_VARIABLE_VALUE[\$name] ]]; then
            ${ns}_diag_set variables.status FAIL; ${ns}_diag_set variables.error VALUE_MISSING
            ${ns}_diag_set variables.name "\$name"; failed=1; break
        fi
        if [[ "\$name" == code.* && "\${${ns}_VARIABLE_TYPE[\$name]}" != bash ]]; then
            ${ns}_diag_set variables.status FAIL; ${ns}_diag_set variables.error CODE_TYPE_INVALID
            ${ns}_diag_set variables.name "\$name"; failed=1; break
        fi
    done
    if [[ "\${${ns}_DIAG[variables.status]}" == OK ]]; then
        for name in "\${!${ns}_VARIABLE_VALUE[@]}"; do
            if [[ ! -v ${ns}_VARIABLE_TYPE[\$name] ]]; then
                ${ns}_diag_set variables.status FAIL; ${ns}_diag_set variables.error TYPE_MISSING
                ${ns}_diag_set variables.name "\$name"; failed=1; break
            fi
        done
    fi

    ${ns}_diag_set slots.status OK
    ${ns}_diag_set pids.status OK
    for slot in "\${!${ns}_WORKER_PIDS[@]}"; do
        pid="\${${ns}_WORKER_PIDS[\$slot]}"
        if [[ -z "\$pid" ]]; then
            ${ns}_diag_set pids.status FAIL; ${ns}_diag_set pids.error EMPTY_WORKER_PID
            ${ns}_diag_set pids.slot "\$slot"; failed=1; break
        fi
        if [[ -v ${ns}_COMPLETED_PIDS[\$slot] && "\${${ns}_COMPLETED_PIDS[\$slot]}" != "\$pid" ]]; then
            ${ns}_diag_set pids.status FAIL; ${ns}_diag_set pids.error COMPLETED_PID_MISMATCH
            ${ns}_diag_set pids.slot "\$slot"; ${ns}_diag_set pids.worker_pid "\$pid"
            ${ns}_diag_set pids.completed_pid "\${${ns}_COMPLETED_PIDS[\$slot]}"; failed=1; break
        fi
        if [[ -v ${ns}_REAPED_PIDS[\$slot] && "\${${ns}_REAPED_PIDS[\$slot]}" != "\$pid" ]]; then
            ${ns}_diag_set pids.status FAIL; ${ns}_diag_set pids.error REAPED_PID_MISMATCH
            ${ns}_diag_set pids.slot "\$slot"; ${ns}_diag_set pids.worker_pid "\$pid"
            ${ns}_diag_set pids.reaped_pid "\${${ns}_REAPED_PIDS[\$slot]}"; failed=1; break
        fi
        if [[ -v ${ns}_SLOT_TASK_ID[\$slot] ]]; then
            task_id="\${${ns}_SLOT_TASK_ID[\$slot]}"
            attempt="\${${ns}_SLOT_ATTEMPT[\$slot]:-}"
            if [[ ! -v ${ns}_TASK_STATUS[\$task_id] ]]; then
                ${ns}_diag_set slots.status FAIL; ${ns}_diag_set slots.error TASK_MISSING
                ${ns}_diag_set slots.slot "\$slot"; ${ns}_diag_set slots.task_id "\$task_id"; failed=1; break
            fi
            if [[ "\${${ns}_TASK_STATUS[\$task_id]}" != RUNNING ]]; then
                ${ns}_diag_set slots.status FAIL; ${ns}_diag_set slots.error TASK_NOT_RUNNING
                ${ns}_diag_set slots.slot "\$slot"; ${ns}_diag_set slots.task_id "\$task_id"; failed=1; break
            fi
            if [[ -z "\$attempt" || "\${${ns}_TASK_ATTEMPT[\$task_id]:-}" != "\$attempt" ]]; then
                ${ns}_diag_set slots.status FAIL; ${ns}_diag_set slots.error ATTEMPT_MISMATCH
                ${ns}_diag_set slots.slot "\$slot"; ${ns}_diag_set slots.task_id "\$task_id"
                ${ns}_diag_set slots.slot_attempt "\$attempt"; ${ns}_diag_set slots.task_attempt "\${${ns}_TASK_ATTEMPT[\$task_id]:-}"
                failed=1; break
            fi
            seen_task_slots["\$task_id"]=1
        fi
    done

    ${ns}_diag_set tasks.status OK
    for task_id in "\${!${ns}_TASK_STATUS[@]}"; do
        status="\${${ns}_TASK_STATUS[\$task_id]}"
        case "\$status" in
            QUEUED|RUNNING|SUCCESS|FAILED|POSSIBLE_DATA_LOSS|ABNORMAL_TERMINATION|PROTOCOL_INCONSISTENCY) ;;
            *) ${ns}_diag_set tasks.status FAIL; ${ns}_diag_set tasks.error INVALID_STATUS
               ${ns}_diag_set tasks.task_id "\$task_id"; ${ns}_diag_set tasks.value "\$status"; failed=1; break ;;
        esac
        if [[ "\$status" == RUNNING && ! -v seen_task_slots[\$task_id] ]]; then
            ${ns}_diag_set tasks.status FAIL; ${ns}_diag_set tasks.error RUNNING_WITHOUT_SLOT
            ${ns}_diag_set tasks.task_id "\$task_id"; ${ns}_diag_set tasks.attempt "\${${ns}_TASK_ATTEMPT[\$task_id]:-}"
            failed=1; break
        fi
    done

    ${ns}_diag_set pool.status OK
    local worker_count=0 _
    for _ in "\${!${ns}_WORKER_PIDS[@]}"; do ((worker_count++)); done
    if (( ${ns}_PENDING_JOBS != worker_count )); then
        ${ns}_diag_set pool.status FAIL; ${ns}_diag_set pool.error PENDING_COUNT_MISMATCH
        ${ns}_diag_set pool.pending "\${${ns}_PENDING_JOBS}"; ${ns}_diag_set pool.worker_slots "\$worker_count"; failed=1
    fi

    ${ns}_diag_set fifo.status OK
    if [[ -z "\${${ns}_FIFO_PATH:-}" || ! -p "\${${ns}_FIFO_PATH:-}" ]]; then
        ${ns}_diag_set fifo.status FAIL; ${ns}_diag_set fifo.error FIFO_PATH_INVALID; failed=1
    elif [[ -z "\${${ns}_FIFO_FD:-}" ]]; then
        ${ns}_diag_set fifo.status FAIL; ${ns}_diag_set fifo.error FIFO_FD_MISSING; failed=1
    fi

    if (( failed )); then
        ${ns}_diag_set object.status FAIL
        ${ns}_OBJECT_HEALTH="BROKEN"
        return 1
    fi
    ${ns}_diag_set object.status OK
    ${ns}_OBJECT_HEALTH="OK"
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

# ============================================================================
# 7C. DISTRIBUTED RUNTIME FOUNDATIONS
# ============================================================================

define_runtime_resource_api() {
    local ns="$1" body
    body=$(cat <<EOF
${ns}_resource_set() {
    [ \$# -eq 2 ] || return 2
    [[ "\$1" =~ ^[a-zA-Z0-9_.-]+$ ]] || return 2
    ${ns}_RESOURCE["\$1"]="\$2"
}
${ns}_resource_get() {
    [ \$# -eq 1 ] || return 2
    [[ -v ${ns}_RESOURCE[\$1] ]] || return 1
    printf '%s\n' "\${${ns}_RESOURCE[\$1]}"
}
${ns}_resource_list() {
    printf '%s\n' "\${!${ns}_RESOURCE[@]}" | LC_ALL=C sort
}
${ns}_resource_refresh_workers() {
    local busy=0 _ total free
    for _ in "\${!${ns}_WORKER_PIDS[@]}"; do ((busy++)); done
    total="\${${ns}_MAX_JOBS:-0}"
    (( total < 0 )) && total=0
    free=\$((total - busy))
    (( free < 0 )) && free=0
    ${ns}_RESOURCE["workers.total"]="\$total"
    ${ns}_RESOURCE["workers.busy"]="\$busy"
    ${ns}_RESOURCE["workers.free"]="\$free"
    ${ns}_RESOURCE["workers.offered"]="\$free"
}
${ns}_resource_snapshot() {
    ${ns}_resource_refresh_workers || return
    local key
    while IFS= read -r key; do
        [[ -n "\$key" ]] || continue
        printf '%s=%s\n' "\$key" "\${${ns}_RESOURCE[\$key]}"
    done < <(${ns}_resource_list)
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_backend_descriptor_api() {
    local ns="$1" body
    body=$(cat <<EOF
${ns}_backend_register() {
    [ \$# -ge 2 ] || return 2
    local name="\$1" scope="\$2"; shift 2
    [[ "\$name" =~ ^[a-zA-Z0-9_.-]+$ ]] || return 2
    case "\$scope" in local|remote|universal) ;; *) return 2 ;; esac
    ${ns}_BACKEND_SCOPE["\$name"]="\$scope"
    ${ns}_BACKEND_CAPABILITIES["\$name"]=""
    local cap
    for cap in "\$@"; do
        [[ "\$cap" =~ ^[a-zA-Z0-9_.-]+$ ]] || return 2
        [[ -z "\${${ns}_BACKEND_CAPABILITIES[\$name]}" ]] || ${ns}_BACKEND_CAPABILITIES["\$name"]+=" "
        ${ns}_BACKEND_CAPABILITIES["\$name"]+="\$cap"
    done
}
${ns}_backend_scope() {
    [ \$# -eq 1 ] || return 2
    [[ -v ${ns}_BACKEND_SCOPE[\$1] ]] || return 1
    printf '%s\n' "\${${ns}_BACKEND_SCOPE[\$1]}"
}
${ns}_backend_has_capability() {
    [ \$# -eq 2 ] || return 2
    local name="\$1" wanted="\$2" cap
    [[ -v ${ns}_BACKEND_SCOPE[\$name] ]] || return 1
    for cap in \${${ns}_BACKEND_CAPABILITIES[\$name]}; do
        [[ "\$cap" == "\$wanted" ]] && return 0
    done
    return 1
}
${ns}_backend_list() {
    printf '%s\n' "\${!${ns}_BACKEND_SCOPE[@]}" | LC_ALL=C sort
}
${ns}_backend_is_network_capable() {
    [ \$# -eq 1 ] || return 2
    local scope
    scope="\$(${ns}_backend_scope "\$1")" || return
    [[ "\$scope" == remote || "\$scope" == universal ]]
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

# ============================================================================
# 7D. EXPERIMENTAL DISTRIBUTED DISCOVERY ABI
#
# Discovery transport is deliberately externalized:
#   udp -> discovery/broadcast
#   tcp -> reliable peer communication (next slice)
#
# The library itself owns the machine-readable HELLO/resource payload and peer
# registry.  A tiny UDP adapter can feed received datagrams into
# <ns>_discovery_accept without teaching the resource/object layer about UDP.
# ============================================================================

define_discovery_api() {
    local ns="$1" body
    body=$(cat <<EOF
${ns}_discovery_payload() {
    ${ns}_resource_refresh_workers || return
    printf 'HELLO\t1\t%s\t%s\t%s\n' \
        "\${${ns}_RESOURCE[workers.total]}" \
        "\${${ns}_RESOURCE[workers.free]}" \
        "\${${ns}_RESOURCE[workers.offered]}"
}

${ns}_discovery_accept() {
    [ \$# -eq 2 ] || return 2
    local handle="\$1" payload="\$2"
    local tag version total free offered extra

    IFS=\$'\t' read -r tag version total free offered extra <<<"\$payload"
    [[ "\$tag" == HELLO && "\$version" == 1 ]] || return 1
    [[ -z "\$extra" ]] || return 1
    [[ "\$total" =~ ^[0-9]+$ && "\$free" =~ ^[0-9]+$ && "\$offered" =~ ^[0-9]+$ ]] || return 1
    (( free <= total && offered <= free )) || return 1

    ${ns}_PEER_BACKEND["\$handle"]="udp"
    ${ns}_PEER_PROTOCOL["\$handle"]="1"
    ${ns}_PEER_RESOURCE["\$handle|workers.total"]="\$total"
    ${ns}_PEER_RESOURCE["\$handle|workers.free"]="\$free"
    ${ns}_PEER_RESOURCE["\$handle|workers.offered"]="\$offered"
}

${ns}_peer_get() {
    [ \$# -eq 2 ] || return 2
    local handle="\$1" key="\$2"
    [[ -v ${ns}_PEER_RESOURCE["\$handle|\$key"] ]] || return 1
    printf '%s\n' "\${${ns}_PEER_RESOURCE["\$handle|\$key"]}"
}

${ns}_peer_list() {
    printf '%s\n' "\${!${ns}_PEER_BACKEND[@]}" | LC_ALL=C sort
}

${ns}_peer_forget() {
    [ \$# -eq 1 ] || return 2
    local handle="\$1" key
    unset '${ns}_PEER_BACKEND['"\$handle"']'
    unset '${ns}_PEER_PROTOCOL['"\$handle"']'
    for key in "\${!${ns}_PEER_RESOURCE[@]}"; do
        [[ "\$key" == "\$handle|"* ]] && unset '${ns}_PEER_RESOURCE['"\$key"']'
    done
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

# ============================================================================
# 8. CONSTRUCTORS
# ============================================================================

asyncobj_constructor() {
    local ns="$1" ns_out="${2:-}"

    define_variable_api            "$ns"
    printf -v "${ns}_CODE_PATCH_SEQ" '%s' 0
    printf -v "${ns}_OBJECT_HEALTH" '%s' "OK"

    define_default_worker_cleanup  "$ns"
    define_worker_cleanup_wrapper  "$ns"
    define_fifo_api                "$ns"
    define_job_pool_init           "$ns"
    define_task_argv_api           "$ns"
    define_task_mutation_api       "$ns"
    define_task_state_api          "$ns"
    define_task_retry_api          "$ns"
    define_task_execution_api      "$ns"
    define_task_api                "$ns"
    define_try_release_slot        "$ns"
    define_finalize_missing_completion "$ns"
    define_mark_reaped             "$ns"
    define_reap_one                "$ns"
    define_mark_job_completed      "$ns"
    define_summon_worker           "$ns"
    define_job_pool_add_work       "$ns"
    define_job_pool_submit         "$ns"
    define_job_pool_wait           "$ns"
    define_audit_job_pool          "$ns"
    define_diagnostic_api           "$ns"
    define_runtime_resource_api     "$ns"
    define_backend_descriptor_api   "$ns"
    define_discovery_api            "$ns"

    if [ -n "$ns_out" ]; then
        define_forward_hook "$ns" "$ns_out"
    fi

    "${ns}_job_pool_init"
    "${ns}_backend_register" fifo local send receive
    "${ns}_backend_register" tcp universal connect send receive listen
    "${ns}_resource_refresh_workers"
}

# Origin: vždy má downstream (nebo je sám o sobě jednorázový stage).
async_pipeline_origin_constructor() {
    local ns="$1" ns_out="${2:-}"
    asyncobj_constructor "$ns" "$ns_out"
}

# Pipe: musí mít downstream – jinak je to endpoint.
async_pipeline_pipe_constructor() {
    local ns="$1" ns_out="${2:-}"
    if [ -z "$ns_out" ]; then
        echo "Chyba: async_pipeline_pipe_constructor '$ns' bez \$2 = endpoint." >&2
        echo "       Použij: async_pipeline_endpoint_constructor $ns <out_fd> [buffer_file] [threshold]" >&2
        return 1
    fi
    asyncobj_constructor "$ns" "$ns_out"
}

# Endpoint: terminální stupeň. Buffer + flush na out_fd.
#   <ns>            jméno instance
#   <out_fd>        FD, kam se flushuje (default: 1 = stdout)
#   [buffer_file]   cesta k bufferu (default: temp v MAIN_TMP_DIR)
#   [threshold]     kolik bajtů spustí auto-flush (default: 65536)
async_pipeline_endpoint_constructor() {
    local ns="$1"
    local out_fd="${2:-1}"
    local buffer_file="${3:-}"
    local threshold="${4:-65536}"

    # Standardní pool bez downstreamu.
    asyncobj_constructor "$ns" ""

    # Endpoint API + override on_job_completed.
    define_endpoint_api "$ns" "$out_fd" "$buffer_file" "$threshold"

    # Default worker pro endpoint, pokud si uživatel nenastaví vlastní.
    if [ -z "${!ns_TARGET_WORKER_FUNC:-}" ]; then
        printf -v "${ns}_TARGET_WORKER_FUNC" '%s' "${ns}_default_endpoint_worker"
    fi
}


# ============================================================================
# 9. OBJECT SNAPSHOT / MIGRATION SAFEPOINT ABI v1
# ============================================================================

define_snapshot_api() {
    local ns="$1" body
    body="$(cat <<'SNAP_EOF'
__NS___migration_request() {
    __NS___MIGRATION_REQUESTED=1
    __NS___MIGRATION_STATE=REQUESTED
}
__NS___migration_requested() {
    [[ "${__NS___MIGRATION_REQUESTED:-0}" == 1 ]]
}
__NS___migration_quiesce() {
    __NS___MIGRATION_STATE=QUIESCING
    __NS___MIGRATION_ADMISSION=0
    __NS___job_pool_wait || return
    __NS___drain_fifo || return
    (( ${__NS___PENDING_JOBS:-0} == 0 )) || { __NS___MIGRATION_STATE=FAILED; return 1; }
    (( ${#__NS___WORKER_PIDS[@]} == 0 )) || { __NS___MIGRATION_STATE=FAILED; return 1; }
    __NS___diagnose || { __NS___MIGRATION_STATE=FAILED; return 1; }
    __NS___MIGRATION_STATE=QUIESCED
}
__NS___migration_resume() {
    __NS___MIGRATION_REQUESTED=0
    __NS___MIGRATION_ADMISSION=1
    __NS___MIGRATION_STATE=ACTIVE
}
__NS___safepoint() {
    __NS___migration_requested || return 0
    __NS___migration_quiesce
}
__NS___snapshot_write() {
    [ $# -eq 1 ] || return 2
    local file="$1" name task_id arg
    local -a argv=()
    [[ "${__NS___MIGRATION_STATE:-ACTIVE}" == QUIESCED ]] || return 3
    (( ${__NS___PENDING_JOBS:-0} == 0 )) || return 3
    (( ${#__NS___WORKER_PIDS[@]} == 0 )) || return 3
    : > "$file" || return
    printf 'ASYNC_OBJECT_SNAPSHOT\t1\t%s\n' '__NS__' >> "$file"

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        printf 'VAR\t' >> "$file"
        printf '%q\t%q\t%q\n' "$name" "${__NS___VARIABLE_TYPE[$name]}" \
            "${__NS___VARIABLE_VALUE[$name]}" >> "$file"
    done < <(__NS___list_variables all)

    for task_id in "${!__NS___TASK_STATUS[@]}"; do
        printf 'TASK\t' >> "$file"
        printf '%q\t%q\t%q\t%q\t%q\t%q\t%q\t%q\n' \
            "$task_id" "${__NS___TASK_STATUS[$task_id]}" \
            "${__NS___TASK_FUNC[$task_id]:-}" "${__NS___TASK_ATTEMPT[$task_id]:-0}" \
            "${__NS___TASK_RETRIES[$task_id]:-0}" "${__NS___TASK_CREATED[$task_id]:-}" \
            "${__NS___TASK_STARTED[$task_id]:-}" "${__NS___TASK_FINISHED[$task_id]:-}" >> "$file"
        argv=()
        if __NS___task_argv_get "$task_id" argv 2>/dev/null; then
            printf 'ARGV\t%q\t%d' "$task_id" "${#argv[@]}" >> "$file"
            for arg in "${argv[@]}"; do printf '\t%q' "$arg" >> "$file"; done
            printf '\n' >> "$file"
        fi
    done

    printf 'META\tNEXT_TASK_ID\t%q\n' "${__NS___NEXT_TASK_ID:-1}" >> "$file"
    printf 'META\tDEFAULT_RETRIES\t%q\n' "${__NS___DEFAULT_RETRIES:-0}" >> "$file"
    printf 'META\tMAX_JOBS\t%q\n' "${__NS___MAX_JOBS:-1}" >> "$file"
    printf 'END\n' >> "$file"
}
SNAP_EOF
)"
    body="${body//__NS__/$ns}"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

create_blank_object() {
    local ns="$1"
    asyncobj_constructor "$ns" "" || return
    define_snapshot_api "$ns" || return
    printf -v "${ns}_OBJECT_TYPE" '%s' BLANK
    printf -v "${ns}_MIGRATION_REQUESTED" '%s' 0
    printf -v "${ns}_MIGRATION_ADMISSION" '%s' 1
    printf -v "${ns}_MIGRATION_STATE" '%s' ACTIVE
}

object_enable_snapshot() {
    local ns="$1"
    define_snapshot_api "$ns" || return
    printf -v "${ns}_MIGRATION_REQUESTED" '%s' 0
    printf -v "${ns}_MIGRATION_ADMISSION" '%s' 1
    printf -v "${ns}_MIGRATION_STATE" '%s' ACTIVE
}

# ============================================================================
# 10. LOCAL OBJECT ADDRESSING + FD REGISTRIES + RESOURCE_CONTAINER v2
# ============================================================================


__asyncobj_ensure_global_registries() {
    declare -p ALL_FIFO >/dev/null 2>&1 || declare -gA ALL_FIFO=()
    declare -p ALL_FD_TYPE >/dev/null 2>&1 || declare -gA ALL_FD_TYPE=()
    declare -p ALL_FD_OBJ_ID >/dev/null 2>&1 || declare -gA ALL_FD_OBJ_ID=()
    declare -p ALL_NS >/dev/null 2>&1 || declare -gA ALL_NS=()
    declare -p OBJ_ID_TO_NS >/dev/null 2>&1 || declare -gA OBJ_ID_TO_NS=()
    declare -p UUID_TO_OBJ_ID >/dev/null 2>&1 || declare -gA UUID_TO_OBJ_ID=()

    if [ -z "${ASYNC_SCRIPT_ID:-}" ]; then
        ASYNC_SCRIPT_ID="as_$(__asyncobj_random_hex 8)" || return
    fi
    : "${ASYNC_SCRIPT_NEXT_OBJECT_ID:=1}"
}

# allocate_object_ns [outvar]
# Parent-side allocator.  With outvar it does not require command substitution,
# therefore registry/counter mutations stay in the owning async_script shell.
allocate_object_ns() {
    [ $# -le 1 ] || return 2
    __asyncobj_ensure_global_registries || return
    local outvar="${1:-}" candidate i
    for (( i=0; i<128; i++ )); do
        candidate="o_$(__asyncobj_random_hex 8)" || return
        [[ "$candidate" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || continue
        [[ ! -v ALL_NS["$candidate"] ]] || continue
        # Also reject an already materialized Bash namespace even if an older
        # caller forgot to register it.
        if compgen -A variable "${candidate}_" | grep -q . 2>/dev/null; then
            continue
        fi
        if compgen -A function "${candidate}_" | grep -q . 2>/dev/null; then
            continue
        fi
        if [ -n "$outvar" ]; then
            printf -v "$outvar" '%s' "$candidate"
        else
            printf '%s\n' "$candidate"
        fi
        return 0
    done
    return 1
}

__asyncobj_allocate_obj_id() {
    [ $# -eq 1 ] || return 2
    local outvar="$1" id
    __asyncobj_ensure_global_registries || return
    id="${ASYNC_SCRIPT_ID}:${ASYNC_SCRIPT_NEXT_OBJECT_ID}"
    ASYNC_SCRIPT_NEXT_OBJECT_ID=$(( ASYNC_SCRIPT_NEXT_OBJECT_ID + 1 ))
    printf -v "$outvar" '%s' "$id"
}

__asyncobj_allocate_uuid() {
    [ $# -eq 1 ] || return 2
    local outvar="$1" candidate
    if [ -r /proc/sys/kernel/random/uuid ]; then
        IFS= read -r candidate < /proc/sys/kernel/random/uuid || return
    else
        candidate="$(__asyncobj_random_hex 16)" || return
    fi
    printf -v "$outvar" '%s' "$candidate"
}

register_object_identity() {
    [ $# -eq 3 ] || return 2
    local ns="$1" obj_id="$2" uuid="$3"
    __asyncobj_ensure_global_registries || return
    [[ -n "$ns" && -n "$obj_id" && -n "$uuid" ]] || return 2
    [[ ! -v ALL_NS["$ns"] ]] || return 3
    [[ ! -v OBJ_ID_TO_NS["$obj_id"] ]] || return 4
    [[ ! -v UUID_TO_OBJ_ID["$uuid"] ]] || return 5
    ALL_NS["$ns"]="$obj_id"
    OBJ_ID_TO_NS["$obj_id"]="$ns"
    UUID_TO_OBJ_ID["$uuid"]="$obj_id"
}

lookup_obj_id_by_ns() {
    [ $# -eq 1 ] || return 2
    __asyncobj_ensure_global_registries
    [[ -v ALL_NS["$1"] ]] || return 1
    printf '%s\n' "${ALL_NS[$1]}"
}

lookup_ns_by_obj_id() {
    [ $# -eq 1 ] || return 2
    __asyncobj_ensure_global_registries
    [[ -v OBJ_ID_TO_NS["$1"] ]] || return 1
    printf '%s\n' "${OBJ_ID_TO_NS[$1]}"
}

resolve_uuid() {
    [ $# -eq 1 ] || return 2
    __asyncobj_ensure_global_registries
    [[ -v UUID_TO_OBJ_ID["$1"] ]] || return 1
    printf '%s\n' "${UUID_TO_OBJ_ID[$1]}"
}

register_fifo() {
    [ $# -eq 2 ] || return 2
    local fifo="$1" obj_id="$2"
    __asyncobj_ensure_global_registries
    [[ -n "$fifo" && -n "$obj_id" ]] || return 2
    ALL_FIFO["$obj_id"]="$fifo"
}

unregister_fifo() {
    [ $# -eq 1 ] || return 2
    __asyncobj_ensure_global_registries
    unset 'ALL_FIFO[$1]'
}

fifo_lookup_byid() {
    [ $# -eq 1 ] || return 2
    __asyncobj_ensure_global_registries
    [[ -v ALL_FIFO["$1"] ]] || return 1
    printf '%s\n' "${ALL_FIFO[$1]}"
}

register_fd() {
    [ $# -eq 3 ] || return 2
    local fd="$1" type="$2" obj_id="$3"
    __asyncobj_ensure_global_registries
    [[ "$fd" =~ ^[0-9]+$ && -n "$type" && -n "$obj_id" ]] || return 2
    ALL_FD_TYPE["$fd"]="$type"
    ALL_FD_OBJ_ID["$fd"]="$obj_id"
}

unregister_fd() {
    [ $# -eq 1 ] || return 2
    __asyncobj_ensure_global_registries
    unset 'ALL_FD_TYPE[$1]' 'ALL_FD_OBJ_ID[$1]'
}

lookup_file_by_fd() {
    [ $# -eq 1 ] || return 2
    local fd="$1"
    __asyncobj_ensure_global_registries
    [[ -v ALL_FD_TYPE["$fd"] && -v ALL_FD_OBJ_ID["$fd"] ]] || return 1
    printf '%s %s\n' "${ALL_FD_TYPE[$fd]}" "${ALL_FD_OBJ_ID[$fd]}"
}

lookup_fd_by_object() {
    [ $# -eq 1 ] || return 2
    local obj_id="$1" fd
    __asyncobj_ensure_global_registries
    for fd in "${!ALL_FD_OBJ_ID[@]}"; do
        [[ "${ALL_FD_OBJ_ID[$fd]}" == "$obj_id" ]] || continue
        printf '%s %s\n' "$fd" "${ALL_FD_TYPE[$fd]}"
    done | sort -n
}

# create_blank_object <ns>
# ns is local/direct Bash addressing. obj_id is the current routable address.
# UUID is stable identity intended to survive later migration.
create_blank_object() {
    [ $# -eq 1 ] || return 2
    local ns="$1" fifo fd fifo_var fd_var obj_id uuid
    __asyncobj_ensure_global_registries || return
    [[ "$ns" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 2
    [[ ! -v ALL_NS["$ns"] ]] || {
        printf 'Chyba: namespace %q je již obsazen\n' "$ns" >&2
        return 3
    }

    __asyncobj_allocate_obj_id obj_id || return
    __asyncobj_allocate_uuid uuid || return

    asyncobj_constructor "$ns" "" || return
    define_snapshot_api "$ns" || return
    printf -v "${ns}_OBJECT_TYPE" '%s' BLANK
    printf -v "${ns}_OBJECT_ID" '%s' "$obj_id"
    printf -v "${ns}_OBJECT_UUID" '%s' "$uuid"
    printf -v "${ns}_MIGRATION_REQUESTED" '%s' 0
    printf -v "${ns}_MIGRATION_ADMISSION" '%s' 1
    printf -v "${ns}_MIGRATION_STATE" '%s' ACTIVE

    register_object_identity "$ns" "$obj_id" "$uuid" || return

    fifo_var="${ns}_FIFO_PATH"
    fd_var="${ns}_FIFO_FD"
    fifo="${!fifo_var}"
    fd="${!fd_var}"
    register_fifo "$fifo" "$obj_id" || return
    register_fd "$fd" fifo "$obj_id" || return
}

# create_random_blank_object [out_ns_var]
# Recommended constructor for runtime/JIT materialization.
create_random_blank_object() {
    [ $# -le 1 ] || return 2
    local outvar="${1:-}" allocated_ns
    allocate_object_ns allocated_ns || return
    create_blank_object "$allocated_ns" || return
    if [ -n "$outvar" ]; then
        printf -v "$outvar" '%s' "$allocated_ns"
    else
        printf '%s\n' "$allocated_ns"
    fi
}

# open_file <ns> <path> [r|w|a|rw]
# BLANK + file FD => RESOURCE_CONTAINER.
open_file() {
    [ $# -ge 2 ] && [ $# -le 3 ] || return 2
    local ns="$1" path="$2" mode="${3:-r}" fd obj_id_var="${1}_OBJECT_ID"
    local type_var="${ns}_OBJECT_TYPE"
    [[ "${!type_var:-}" == BLANK ]] || {
        printf 'Chyba [%s]: open_file vyžaduje BLANK object\n' "$ns" >&2
        return 3
    }

    case "$mode" in
        r)  exec {fd}<"$path" ;;
        w)  exec {fd}>"$path" ;;
        a)  exec {fd}>>"$path" ;;
        rw) exec {fd}<>"$path" ;;
        *)  return 2 ;;
    esac || return

    register_fd "$fd" file "${!obj_id_var}" || { eval "exec ${fd}>&-"; return 1; }
    printf -v "${ns}_RESOURCE_FD" '%s' "$fd"
    printf -v "${ns}_RESOURCE_TYPE" '%s' file
    printf -v "${ns}_RESOURCE_PATH" '%s' "$path"
    printf -v "${ns}_RESOURCE_MODE" '%s' "$mode"
    printf -v "${ns}_OBJECT_TYPE" '%s' RESOURCE_CONTAINER
    printf '%s\n' "$fd"
}

close_resource() {
    [ $# -eq 1 ] || return 2
    local ns="$1" fd_var="${1}_RESOURCE_FD" fd=""
    local type_var="${ns}_OBJECT_TYPE"
    [[ "${!type_var:-}" == RESOURCE_CONTAINER ]] || return 3
    fd="${!fd_var:-}"
    [[ "$fd" =~ ^[0-9]+$ ]] || return 1
    unregister_fd "$fd"
    eval "exec ${fd}>&-"
    unset "${ns}_RESOURCE_FD" "${ns}_RESOURCE_TYPE" "${ns}_RESOURCE_PATH" "${ns}_RESOURCE_MODE"
    printf -v "${ns}_OBJECT_TYPE" '%s' BLANK
}


# ============================================================================
# 11. TWO-ASYNC_SCRIPT MIGRATION VERTICAL SLICE v1
# ============================================================================


migration_export() {
    [ $# -eq 2 ] || return 2
    local ns="$1" bundle="$2" snap
    local uuid_var="${1}_OBJECT_UUID" type_var="${1}_OBJECT_TYPE" id_var="${1}_OBJECT_ID"
    snap="${bundle}.snapshot"

    "${ns}_migration_request" || return
    "${ns}_migration_quiesce" || return
    "${ns}_snapshot_write" "$snap" || return

    {
        printf 'ASYNC_OBJECT_MIGRATION\t1\n'
        printf 'UUID\t%q\n' "${!uuid_var}"
        printf 'SOURCE_OBJ_ID\t%q\n' "${!id_var}"
        printf 'OBJECT_TYPE\t%q\n' "${!type_var}"
        printf 'SNAPSHOT\t%q\n' "$snap"
        printf 'END\n'
    } > "$bundle"
}

__asyncobj_rebind_uuid() {
    [ $# -eq 2 ] || return 2
    local ns="$1" wanted="$2"
    local uuid_var="${1}_OBJECT_UUID" id_var="${1}_OBJECT_ID"
    local generated="${!uuid_var}" obj_id="${!id_var}"
    __asyncobj_ensure_global_registries
    unset 'UUID_TO_OBJ_ID[$generated]'
    [[ ! -v UUID_TO_OBJ_ID["$wanted"] ]] || return 3
    printf -v "$uuid_var" '%s' "$wanted"
    UUID_TO_OBJ_ID["$wanted"]="$obj_id"
}

migration_import() {
    [ $# -ge 2 ] && [ $# -le 3 ] || return 2
    local bundle="$1" out_ns="$2" out_obj_id="${3:-}"
    local tag a b uuid="" source_obj_id="" object_type="" snap=""
    local new_ns obj_id_var line name type value
    local task status func attempt retries created started finished
    local argc i arg meta_value
    local -a fields argv

    while IFS=$'\t' read -r tag a b; do
        case "$tag" in
            ASYNC_OBJECT_MIGRATION) [[ "$a" == 1 ]] || return 10 ;;
            UUID) __asyncobj_decode_q "$a" uuid || return ;;
            SOURCE_OBJ_ID) __asyncobj_decode_q "$a" source_obj_id || return ;;
            OBJECT_TYPE) __asyncobj_decode_q "$a" object_type || return ;;
            SNAPSHOT) __asyncobj_decode_q "$a" snap || return ;;
            END) break ;;
        esac
    done < "$bundle"

    [[ -n "$uuid" && -r "$snap" ]] || return 11
    [[ "$object_type" == BLANK ]] || return 12

    create_random_blank_object new_ns || return
    __asyncobj_rebind_uuid "$new_ns" "$uuid" || return

    while IFS= read -r line; do
        IFS=$'\t' read -r -a fields <<< "$line"
        tag="${fields[0]:-}"
        case "$tag" in
            VAR)
                [[ ${#fields[@]} -eq 4 ]] || return 20
                __asyncobj_decode_q "${fields[1]}" name || return
                __asyncobj_decode_q "${fields[2]}" type || return
                __asyncobj_decode_q "${fields[3]}" value || return
                # Standard generated code is regenerated under the fresh namespace.
                [[ "$name" == code.* ]] && continue
                "${new_ns}_set_variable" "$name" "$type" "$value" || return
                ;;
            TASK)
                [[ ${#fields[@]} -eq 9 ]] || return 21
                __asyncobj_decode_q "${fields[1]}" task || return
                __asyncobj_decode_q "${fields[2]}" status || return
                __asyncobj_decode_q "${fields[3]}" func || return
                __asyncobj_decode_q "${fields[4]}" attempt || return
                __asyncobj_decode_q "${fields[5]}" retries || return
                __asyncobj_decode_q "${fields[6]}" created || return
                __asyncobj_decode_q "${fields[7]}" started || return
                __asyncobj_decode_q "${fields[8]}" finished || return
                [[ "$status" != RUNNING ]] || return 22
                local -n st="${new_ns}_TASK_STATUS" fn="${new_ns}_TASK_FUNC"
                local -n at="${new_ns}_TASK_ATTEMPT" rt="${new_ns}_TASK_RETRIES"
                local -n cr="${new_ns}_TASK_CREATED" ss="${new_ns}_TASK_STARTED" ff="${new_ns}_TASK_FINISHED"
                st["$task"]="$status"; fn["$task"]="$func"; at["$task"]="$attempt"; rt["$task"]="$retries"
                cr["$task"]="$created"; ss["$task"]="$started"; ff["$task"]="$finished"
                unset -n st fn at rt cr ss ff
                ;;
            ARGV)
                [[ ${#fields[@]} -ge 3 ]] || return 23
                __asyncobj_decode_q "${fields[1]}" task || return
                argc="${fields[2]}"
                [[ "$argc" =~ ^[0-9]+$ && ${#fields[@]} -eq $((argc+3)) ]] || return 24
                argv=()
                for ((i=0; i<argc; i++)); do
                    __asyncobj_decode_q "${fields[i+3]}" arg || return
                    argv+=("$arg")
                done
                "${new_ns}_task_argv_set" "$task" "${argv[@]}" || return
                ;;
            META)
                [[ ${#fields[@]} -eq 3 ]] || return 25
                __asyncobj_decode_q "${fields[2]}" meta_value || return
                case "${fields[1]}" in
                    NEXT_TASK_ID) printf -v "${new_ns}_NEXT_TASK_ID" '%s' "$meta_value" ;;
                    DEFAULT_RETRIES) printf -v "${new_ns}_DEFAULT_RETRIES" '%s' "$meta_value" ;;
                    MAX_JOBS) printf -v "${new_ns}_MAX_JOBS" '%s' "$meta_value" ;;
                esac
                ;;
        esac
    done < "$snap"

    printf -v "${new_ns}_OBJECT_TYPE" '%s' BLANK
    printf -v "${new_ns}_MIGRATION_REQUESTED" '%s' 0
    printf -v "${new_ns}_MIGRATION_ADMISSION" '%s' 1
    printf -v "${new_ns}_MIGRATION_STATE" '%s' ACTIVE
    "${new_ns}_diagnose" || return 30

    obj_id_var="${new_ns}_OBJECT_ID"
    printf -v "$out_ns" '%s' "$new_ns"
    [ -z "$out_obj_id" ] || printf -v "$out_obj_id" '%s' "${!obj_id_var}"
}


# ============================================================================
# 12. ASYNC_SCRIPT OBJECT + DECLARATIVE TOPOLOGY COMPILER v2
#     Full port edges: src:port -> dst:port. Y has NO built-in memory/semantics.
# ============================================================================

__asyncscript_safe_name() { [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; }

__create_blank_async_script_topology_legacy() {
    [ $# -eq 4 ] || return 2
    local as="$1" x="$2" y="$3" n="$4" i total ns
    __asyncscript_safe_name "$as" || return 2
    [[ "$x" =~ ^[1-9][0-9]*$ && "$y" =~ ^[1-9][0-9]*$ && "$n" =~ ^[1-9][0-9]*$ ]] || return 2
    total=$((x*y))
    printf -v "${as}_OBJECT_TYPE" '%s' ASYNC_SCRIPT
    printf -v "${as}_GRID_X" '%s' "$x"; printf -v "${as}_GRID_Y" '%s' "$y"
    printf -v "${as}_MAX_WORKERS_PER_OBJECT" '%s' "$n"; printf -v "${as}_COMPILED" '%s' 0
    eval "declare -g -a ${as}_SLOTS=() ${as}_DECL_OBJECTS=() ${as}_EDGES=()"
    eval "declare -g -A ${as}_DECL_TYPE=() ${as}_DECL_SLOT=() ${as}_DECL_WORKER_FILE=()"
    eval "declare -g -A ${as}_WORKER_ARTIFACT=() ${as}_WORKER_SHA256=() ${as}_WORKER_ORIGIN=()"
    eval "declare -g -A ${as}_DECL_RESOURCE_KIND=() ${as}_DECL_RESOURCE_ARG=()"
    eval "declare -g -A ${as}_DECL_WORKERS=()"
    local -n slots="${as}_SLOTS"
    for ((i=0;i<total;i++)); do create_random_blank_object ns || return; slots+=("$ns"); done
}

register_object() {
    [ $# -eq 3 ] || return 2
    local as="$1" name="$2" type="$3" cv="${1}_COMPILED"
    [[ "${!cv:-1}" == 0 ]] || return 3; __asyncscript_safe_name "$name" || return 2
    case "$type" in ORIGIN|PIPE|ENDPOINT|T|Y|BIFURCATOR|SENSOR|SCHEDULER|DRIVER|GOD|RESOURCE_CONTAINER|BRIDGE) ;; *) return 2;; esac
    local -n objs="${as}_DECL_OBJECTS" types="${as}_DECL_TYPE" smap="${as}_DECL_SLOT" slots="${as}_SLOTS"
    [[ ! -v types["$name"] ]] || return 4
    local idx="${#objs[@]}"; ((idx < ${#slots[@]})) || return 5
    objs+=("$name"); types["$name"]="$type"; smap["$name"]="${slots[$idx]}"
}

__asyncscript_port_valid() {
    local type="$1" dir="$2" port="$3"
    case "$type:$dir:$port" in
        T:in:in|T:out:out1|T:out:out2|Y:in:in1|Y:in:in2|Y:out:out) return 0 ;;
        ORIGIN:out:out|SENSOR:out:out|PIPE:in:in|PIPE:out:out|BRIDGE:in:in|BRIDGE:out:out|ENDPOINT:in:in|SCHEDULER:in:in|DRIVER:in:in|RESOURCE_CONTAINER:out:out|BIFURCATOR:in:in|BIFURCATOR:out:out1|BIFURCATOR:out:out2) return 0 ;;
    esac
    return 1
}

connect_objects() {
    [ $# -eq 5 ] || return 2
    local as="$1" src="$2" src_port="$3" dst="$4" dst_port="$5" cv="${1}_COMPILED"
    [[ "${!cv:-1}" == 0 ]] || return 3
    local -n types="${as}_DECL_TYPE" edges="${as}_EDGES"
    [[ -v types["$src"] && -v types["$dst"] ]] || return 4
    __asyncscript_port_valid "${types[$src]}" out "$src_port" || return 5
    __asyncscript_port_valid "${types[$dst]}" in "$dst_port" || return 6
    edges+=("$src"$'\t'"$src_port"$'\t'"$dst"$'\t'"$dst_port")
}

implant_worker_code_to_object() {
    [ $# -eq 3 ] || return 2
    local as="$1" obj="$2" file="$3" cv="${1}_COMPILED"
    [[ "${!cv:-1}" == 0 && -r "$file" ]] || return 3
    local -n types="${as}_DECL_TYPE" wf="${as}_DECL_WORKER_FILE"; [[ -v types["$obj"] ]] || return 4
    wf["$obj"]="$file"
}

__asyncscript_add_resource() {
    [ $# -eq 4 ] || return 2
    local as="$1" obj="$2" kind="$3" arg="$4" cv="${1}_COMPILED"
    [[ "${!cv:-1}" == 0 ]] || return 3
    local -n types="${as}_DECL_TYPE" rk="${as}_DECL_RESOURCE_KIND" ra="${as}_DECL_RESOURCE_ARG"
    [[ -v types["$obj"] ]] || return 4; rk["$obj"]="$kind"; ra["$obj"]="$arg"
}
add_file()   { [ $# -ge 3 ] && [ $# -le 4 ] || return 2; __asyncscript_add_resource "$1" "$2" file "$3"$'\t'"${4:-r}"; }
add_stdin()  { [ $# -eq 2 ] || return 2; __asyncscript_add_resource "$1" "$2" stdin ""; }
add_stdout() { [ $# -eq 2 ] || return 2; __asyncscript_add_resource "$1" "$2" stdout ""; }
add_stderr() { [ $# -eq 2 ] || return 2; __asyncscript_add_resource "$1" "$2" stderr ""; }

# Generic vector routing metafunction.
# Object JSON is consumed by the compiler. Resolved routes are passed here,
# keeping generated MACHINE/runtime independent of jq and descriptor files.
# Vector keys are "<slot>|<port>"; worker owns vector semantics, runtime routing.
define_vector_forward_hook() {
    [ $# -ge 2 ] || return 2
    local ns="$1" obj_type="$2"; shift 2
    (( $# % 3 == 0 )) || return 2
    local body src dst_ns dst_port
    body="${ns}_forward_output_vector() {
    local slot_id=\"\$1\" key port value prefix=\"\$1|\"
    for key in \"\${!${ns}_OUTPUT_DATA_VECTOR[@]}\"; do
        [[ \"\$key\" == \"\$prefix\"* ]] || continue
        port=\"\${key#\"\$prefix\"}\"
        value=\"\${${ns}_OUTPUT_DATA_VECTOR[\$key]}\"
        case \"\$port\" in
"
    while (( $# )); do
        src="$1"; dst_ns="$2"; dst_port="$3"; shift 3
        printf -v body '%s            %q) %s_summon_worker %q "$value" ;;\n' "$body" "$src" "$dst_ns" "$dst_port"
    done
    body+="            *) printf 'Chyba [${ns}/${obj_type}]: output port bez route: %s\\n' \"\$port\" >&2; return 70 ;;
        esac
    done
}
${ns}_on_job_completed() {
    local slot_id=\"\$1\" exit_code=\"\$2\"
    (( exit_code == 0 )) || return 0
    ${ns}_forward_output_vector \"\$slot_id\"
}
"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

define_t_forward_hook() {
    [ $# -eq 3 ] || return 2
    local ns="$1" ns_out="$2" ns_out2="$3" body
    body=$(cat <<EOF
${ns}_on_job_completed() {
    local slot_id="\$1" exit_code="\$2" output="\$3" output2="\${4:-\$3}"
    if [ "\$exit_code" -eq 0 ]; then
        ${ns_out2}_summon_worker "\$output2"
        ${ns_out}_summon_worker "\$output"
    fi
}
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

# Structural Y only: input ports are explicit entry points. No buffering,
# pairing, fading memory, DSP policy, or other semantics are imposed here.
define_y_structural_hooks() {
    [ $# -eq 2 ] || return 2
    local ns="$1" ns_out="$2" body
    body=$(cat <<EOF
${ns}_receive_in1() { ${ns}_summon_worker "\$@"; }
${ns}_receive_in2() { ${ns}_summon_worker "\$@"; }
EOF
)
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
    define_forward_hook "$ns" "$ns_out"
}

__asyncscript_find_edge() {
    [ $# -eq 5 ] || return 2
    local as="$1" src="$2" sport="$3" out_ns="$4" out_port="$5" e s sp d dp
    local -n edges="${as}_EDGES" smap="${as}_DECL_SLOT"
    for e in "${edges[@]}"; do
        IFS=$'\t' read -r s sp d dp <<<"$e"
        [[ "$s" == "$src" && "$sp" == "$sport" ]] || continue
        printf -v "$out_ns" '%s' "${smap[$d]}"; printf -v "$out_port" '%s' "$dp"; return 0
    done
    return 1
}

# Generate a forwarding function appropriate to the destination input port.
__asyncscript_target_call() {
    local dst_ns="$1" dst_port="$2"
    case "$dst_port" in
        in)  printf '%s_summon_worker' "$dst_ns" ;;
        in1) printf '%s_receive_in1' "$dst_ns" ;;
        in2) printf '%s_receive_in2' "$dst_ns" ;;
        *) return 2 ;;
    esac
}


__asyncscript_implant_worker() {
    [ $# -eq 2 ] || return 2
    local ns="$1" file="$2" def renamed
    [[ -r "$file" ]] || return 3
    bash -n "$file" || return 4
    if declare -F worker >/dev/null; then return 6; fi
    source "$file" || return 5
    if ! declare -F "${ns}_worker" >/dev/null; then
        declare -F worker >/dev/null || return 9
        def="$(declare -f worker)" || return 7
        renamed="${def/#worker ()/${ns}_worker ()}"
        eval "$renamed" || return 8
        unset -f worker
    fi
    def="$(declare -f "${ns}_worker")" || return 10
    local code_key="code.implanted_worker"
    __asyncobj_record_code "$ns" "$code_key" "$def" || return 11
}

compile_topology() {
    [ $# -eq 2 ] || return 2
    local as="$1" outdir="$2" cv="${1}_COMPILED"; [[ "${!cv:-1}" == 0 ]] || return 3
    mkdir -p "$outdir" || return
    local -n objs="${as}_DECL_OBJECTS" types="${as}_DECL_TYPE" smap="${as}_DECL_SLOT"
    local -n wf="${as}_DECL_WORKER_FILE" rk="${as}_DECL_RESOURCE_KIND" ra="${as}_DECL_RESOURCE_ARG" edges="${as}_EDGES"
    local gxv="${as}_GRID_X" gyv="${as}_GRID_Y" mwv="${as}_MAX_WORKERS_PER_OBJECT"
    local obj ns type dst1 port1 dst2 port2 call1 call2 e s sp d dp worker_file path mode

    : >"$outdir/topology.graph"
    printf 'ASYNC_SCRIPT\t%s\tGRID\t%s\t%s\tMAX_WORKERS\t%s\n' "$as" "${!gxv}" "${!gyv}" "${!mwv}" >>"$outdir/topology.graph"

    # First materialize types and worker artifacts.
    for obj in "${objs[@]}"; do
        ns="${smap[$obj]}"; type="${types[$obj]}"
        printf -v "${ns}_OBJECT_TYPE" '%s' "$type"; printf -v "${ns}_MAX_JOBS" '%s' "${!mwv}"
        printf 'OBJECT\t%s\t%s\t%s\n' "$obj" "$type" "$ns" >>"$outdir/topology.graph"
        worker_file="${wf[$obj]:-}"
        if [[ -n "$worker_file" ]]; then
            cp "$worker_file" "$outdir/${ns}.worker.bash" || return
            __asyncscript_implant_worker "$ns" "$worker_file" || return
            local -n wa="${as}_WORKER_ARTIFACT" wh="${as}_WORKER_SHA256" wo="${as}_WORKER_ORIGIN"
            wa["$obj"]="$outdir/${ns}.worker.bash"
            wh["$obj"]="$(__dalo_sha256_file "${wa[$obj]}")" || return
            wo["$obj"]="IMPLANTED"
            printf 'WORKER\t%s\t%s\t%s\t%s\n' "$obj" "$ns" "${wh[$obj]}" "${wo[$obj]}" >>"$outdir/topology.graph"
        else
            printf '# no implanted worker code for %s (%s)\n' "$obj" "$ns" >"$outdir/${ns}.worker.bash"
        fi
    done

    # Y entry points must exist before upstream forwarding hooks are compiled.
    for obj in "${objs[@]}"; do
        [[ "${types[$obj]}" == Y ]] || continue
        ns="${smap[$obj]}"
        __asyncscript_find_edge "$as" "$obj" out dst1 port1 || return 30
        call1="$(__asyncscript_target_call "$dst1" "$port1")" || return
        # define_y_structural_hooks expects a namespace with summon_worker; for
        # nonstandard destination ports use a tiny generated adapter namespace.
        if [[ "$port1" == in ]]; then
            define_y_structural_hooks "$ns" "$dst1" || return
        else
            local adapter="${ns}_yout_adapter"
            eval "${adapter}_summon_worker() { ${call1} \"\$@\"; }"
            define_y_structural_hooks "$ns" "$adapter" || return
        fi
    done

    # Compile structural forwarding.
    for obj in "${objs[@]}"; do
        ns="${smap[$obj]}"; type="${types[$obj]}"
        case "$type" in
            T)
                __asyncscript_find_edge "$as" "$obj" out1 dst1 port1 || return 20
                __asyncscript_find_edge "$as" "$obj" out2 dst2 port2 || return 21
                call1="$(__asyncscript_target_call "$dst1" "$port1")" || return
                call2="$(__asyncscript_target_call "$dst2" "$port2")" || return
                local a1="${ns}_out1_adapter" a2="${ns}_out2_adapter"
                eval "${a1}_summon_worker() { ${call1} \"\$@\"; }"
                eval "${a2}_summon_worker() { ${call2} \"\$@\"; }"
                define_t_forward_hook "$ns" "$a1" "$a2" || return
                ;;
            Y|ENDPOINT|DRIVER|GOD) ;;
            *)
                if __asyncscript_find_edge "$as" "$obj" out dst1 port1; then
                    call1="$(__asyncscript_target_call "$dst1" "$port1")" || return
                    local a="${ns}_out_adapter"
                    eval "${a}_summon_worker() { ${call1} \"\$@\"; }"
                    define_forward_hook "$ns" "$a" || return
                fi
                ;;
        esac
    done

    for e in "${edges[@]}"; do
        IFS=$'\t' read -r s sp d dp <<<"$e"
        printf 'EDGE\t%s\t%s\t%s\t%s\n' "$s" "$sp" "$d" "$dp" >>"$outdir/topology.graph"
    done

    for obj in "${objs[@]}"; do
        ns="${smap[$obj]}"
        case "${rk[$obj]:-}" in
            file) IFS=$'\t' read -r path mode <<<"${ra[$obj]}"; open_file "$ns" "$path" "$mode" >/dev/null || return ;;
            stdin)  printf -v "${ns}_RESOURCE_FD" '%s' 0; printf -v "${ns}_RESOURCE_TYPE" '%s' stdin ;;
            stdout) printf -v "${ns}_RESOURCE_FD" '%s' 1; printf -v "${ns}_RESOURCE_TYPE" '%s' stdout ;;
            stderr) printf -v "${ns}_RESOURCE_FD" '%s' 2; printf -v "${ns}_RESOURCE_TYPE" '%s' stderr ;;
        esac
    done
    printf -v "$cv" '%s' 1
}


# ============================================================================
# 13. MIGRATABLE WORKER ARTIFACT ABI v1
# ============================================================================
# Bundle layout:
#   object.snapshot
#   worker.bash
#   worker.sha256
# The worker filename inside a bundle is namespace-neutral. Destination binds it
# to its fresh namespace and may emit <new_ns>.worker.bash locally.

migration_export_with_worker() {
    [ $# -eq 3 ] || return 2
    local as="$1" obj="$2" bundle_dir="$3"
    local -n smap="${as}_DECL_SLOT" wa="${as}_WORKER_ARTIFACT" wh="${as}_WORKER_SHA256"
    [[ -v smap["$obj"] ]] || return 3
    local ns="${smap[$obj]}" artifact="${wa[$obj]:-}" expected="${wh[$obj]:-}" actual
    [[ -n "$artifact" && -r "$artifact" && -n "$expected" ]] || return 4
    mkdir -p "$bundle_dir" || return

    # Full migration barrier: request -> quiesce -> canonical snapshot.
    "${ns}_migration_request" || return
    "${ns}_migration_quiesce" || return
    "${ns}_snapshot_write" "$bundle_dir/raw.snapshot" || return
    migration_export "$ns" "$bundle_dir/object.snapshot" || return
    local object_type_var="${ns}_OBJECT_TYPE"
    printf '%s\n' "${!object_type_var:-BLANK}" >"$bundle_dir/object.type"
    sed -i $'s/^OBJECT_TYPE\t.*/OBJECT_TYPE\tBLANK/' "$bundle_dir/object.snapshot"

    cp "$artifact" "$bundle_dir/worker.bash" || return
    actual="$(__dalo_sha256_file "$bundle_dir/worker.bash")" || return
    [[ "$actual" == "$expected" ]] || return 5
    printf '%s\n' "$expected" >"$bundle_dir/worker.sha256"
    printf '%s\n' "${ns}_UUID" >"$bundle_dir/source.uuid.var"
    printf '%s\n' "${ns}_OBJ_ID" >"$bundle_dir/source.obj_id.var"
}

migration_import_with_worker() {
    [ $# -eq 3 ] || return 2
    local bundle_dir="$1" out_ns="$2" out_obj_id="$3" new_ns=""
    local expected actual old_uuid uuid obj_id
    [[ -r "$bundle_dir/object.snapshot" && -r "$bundle_dir/worker.bash" &&
       -r "$bundle_dir/worker.sha256" ]] || return 3
    IFS= read -r expected <"$bundle_dir/worker.sha256" || return
    actual="$(__dalo_sha256_file "$bundle_dir/worker.bash")" || return
    [[ "$actual" == "$expected" ]] || return 4

    # STEP16 migration_import(snapshot,new_ns) creates a fresh object identity,
    # then rebinds the stable UUID carried by the snapshot.
    local imported_ns imported_obj_id
    migration_import "$bundle_dir/object.snapshot" imported_ns imported_obj_id || return
    new_ns="$imported_ns"
    if [[ -r "$bundle_dir/object.type" ]]; then
        local restored_type
        IFS= read -r restored_type <"$bundle_dir/object.type" || return
        printf -v "${new_ns}_OBJECT_TYPE" '%s' "$restored_type"
    fi

    local oid_var="${new_ns}_OBJECT_ID" uuid_var="${new_ns}_OBJECT_UUID"
    obj_id="${!oid_var:-$imported_obj_id}"; uuid="${!uuid_var}"

    __asyncscript_implant_worker "$new_ns" "$bundle_dir/worker.bash" || return
    cp "$bundle_dir/worker.bash" "$bundle_dir/${new_ns}.worker.bash" || return
    printf -v "${new_ns}_WORKER_SHA256" '%s' "$expected"
    printf -v "${new_ns}_WORKER_ORIGIN" '%s' MIGRATED
    printf -v "${new_ns}_WORKER_ARTIFACT" '%s' "$bundle_dir/${new_ns}.worker.bash"
    declare -g "$out_ns" "$out_obj_id"
    printf -v "$out_ns" '%s' "$new_ns"
    printf -v "$out_obj_id" '%s' "$obj_id"
}



# ============================================================================
# 14. COMM API + POINT-TO-POINT TCP BRIDGE ABI v2 (STEP34)
# ============================================================================
# The Python helper is transport-only. A BRIDGE is a compiled point-to-point
# edge endpoint, never a router.
#
# Local DATA path:
#     object -> Bridge_A            DIRECT
# Remote transport:
#     Bridge_A <-> Bridge_B         TCP
# Destination DATA path:
#     Bridge_B -> one compiled hook DIRECT
#
# CONTROL/FIFO keeps the FIFO Frame ABI unchanged. The raw FIFO frame is
# wrapped by the STEP24 capability envelope while crossing TCP, then Bridge_B
# performs exactly one local FIFO forward to its pre-bound destination.
#
# Wire records:
#     BRIDGE<TAB>1<TAB>DATA<TAB><payload:%q>
#     CTRL<TAB>src<TAB>dst<TAB>capability<TAB><raw FIFO frame>
#
# DATA and CONTROL therefore share one TCP connection without conflating their
# semantics. Newlines in DATA are encoded by %q into one physical TCP record.

define_comm_api() {
    local ns="$1" body
    body=$(cat <<'COMM_EOF'
__NS___tcp_init() {
    [ $# -ge 3 ] && [ $# -le 4 ] || return 2
    local mode="$1" host="$2" port="$3" helper="${4:-${ASYNC_TCP_HELPER:-/mnt/data/async_tcp_helper_step33.py}}"
    [[ "$mode" == listen || "$mode" == connect ]] || return 2
    [[ "$port" =~ ^[0-9]+$ && -x "$helper" ]] || return 3

    coproc { exec "$helper" --mode "$mode" --host "$host" --port "$port"; }
    local rfd="${COPROC[0]}" wfd="${COPROC[1]}" pid="$COPROC_PID"
    printf -v "__NS___TCP_RX_FD" '%s' "$rfd"
    printf -v "__NS___TCP_TX_FD" '%s' "$wfd"
    printf -v "__NS___TCP_PID" '%s' "$pid"
}

__NS___tcp_send() {
    local raw="$*" fd="${__NS___TCP_TX_FD:-}"
    [[ -n "$fd" ]] || return 1
    [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 3
    printf '%s\n' "$raw" >&"$fd"
}

__NS___tcp_receive() {
    local out="$1" timeout="${2:-0}" fd="${__NS___TCP_RX_FD:-}" _tcp_line
    [[ -n "$fd" ]] || return 1
    if [[ "$timeout" == 0 ]]; then
        IFS= read -r -u "$fd" _tcp_line || return
    else
        IFS= read -r -t "$timeout" -u "$fd" _tcp_line || return
    fi
    printf -v "$out" '%s' "$_tcp_line"
}

__NS___forward_tcp() { __NS___tcp_send "$1"; }

# Bind the one and only DATA continuation of this bridge endpoint.
__NS___bridge_bind_data_target() {
    [ $# -eq 1 ] || return 2
    printf -v "__NS___BRIDGE_DATA_TARGET" '%s' "$1"
}

# Bind the one and only local FIFO destination for received CONTROL.
# The target is an object namespace, not an fd, so the fd may be recreated.
__NS___bridge_bind_control_target() {
    [ $# -eq 1 ] || return 2
    printf -v "__NS___BRIDGE_CONTROL_TARGET_NS" '%s' "$1"
}

__NS___bridge_forward_control_local() {
    [ $# -eq 1 ] || return 2
    local raw="$1" target="${__NS___BRIDGE_CONTROL_TARGET_NS:-}" fdvar fd
    [[ -n "$target" ]] || return 1
    fdvar="${target}_FIFO_FD"
    fd="${!fdvar:-}"
    [[ -n "$fd" ]] || return 1
    printf '%s\n' "$raw" >&"$fd"
}

__NS___bridge_data_encode() {
    [ $# -eq 2 ] || return 2
    local out="$1" payload="$2" q
    printf -v q '%q' "$payload"
    printf -v "$out" 'BRIDGE\t1\tDATA\t%s' "$q"
}

__NS___bridge_data_decode() {
    [ $# -eq 2 ] || return 2
    local raw="$1" out="$2" tag ver kind encoded value
    IFS=$'\t' read -r tag ver kind encoded <<<"$raw"
    [[ "$tag" == BRIDGE && "$ver" == 1 && "$kind" == DATA && -n "$encoded" ]] || return 3
    __asyncobj_decode_q "$encoded" value || return
    printf -v "$out" '%s' "$value"
}

# Normal graph DATA enters Bridge_A directly through this function.
__NS___bridge_send_data() {
    [ $# -eq 1 ] || return 2
    local frame
    __NS___bridge_data_encode frame "$1" || return
    __NS___tcp_send "$frame"
}

# Worker-compatible adapter retained for object/job-pool integration.
__NS___bridge_worker_func() {
    local worker_dir="$1" slot_id="$2"; shift 2
    local payload="${__NS___INPUT_DATA_VECTOR[$slot_id]:-$*}"
    __NS___bridge_send_data "$payload"
}

# Receive exactly one transport record and perform at most one local forward.
__NS___bridge_receive_once() {
    local line payload target
    __NS___tcp_receive line "${1:-1}" || return

    case "$line" in
        BRIDGE$'\t'1$'\t'DATA$'\t'*)
            __NS___bridge_data_decode "$line" payload || return
            target="${__NS___BRIDGE_DATA_TARGET:-}"
            [[ -n "$target" ]] || return 4
            "$target" "$payload"
            ;;
        CTRL$'\t'*)
            __NS___tcp_capability_gate "$line" || return
            __NS___bridge_forward_control_local "$__NS___TCP_GATE_RAW"
            ;;
        *)
            return 5
            ;;
    esac
}

__NS___tcp_close() {
    local pid="${__NS___TCP_PID:-}" txfd="${__NS___TCP_TX_FD:-}" rxfd="${__NS___TCP_RX_FD:-}"
    [[ -n "$txfd" ]] && eval "exec ${txfd}>&-" 2>/dev/null || true
    [[ -n "$rxfd" ]] && eval "exec ${rxfd}<&-" 2>/dev/null || true
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
    unset __NS___TCP_PID __NS___TCP_TX_FD __NS___TCP_RX_FD
}
COMM_EOF
)
    body="${body//__NS__/$ns}"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

# ============================================================================
# 14B. STEP32 ANT RESOURCE EXCHANGE ABI v1
#
# Explicit peer addresses only. There is no broadcast/discovery requirement.
#
# HOME MACHINE owns:
#   job identity, worker artifact, input, completion/retry state.
#
# HOST MACHINE owns:
#   physical ant processes, admission, capacity, and lease lifetime.
#
# Protocol records are line-safe and %q encoded:
#   ANT<TAB>1<TAB>TYPE<TAB>argc<TAB>arg1:%q...
#
# A lease reserves execution capacity; it does not migrate an object.
# ============================================================================

__ant_frame_encode() {
    [ $# -ge 2 ] || return 2
    local out="$1" type="$2"; shift 2
    [[ "$type" =~ ^[A-Z_]+$ ]] || return 2
    local _ant_encoded="" arg q
    printf -v _ant_encoded 'ANT\t1\t%s\t%d' "$type" "$#"
    for arg in "$@"; do
        [[ "$arg" != *$'\n'* && "$arg" != *$'\r'* ]] || return 3
        printf -v q '%q' "$arg"
        _ant_encoded+=$'\t'"$q"
    done
    printf -v "$out" '%s' "$_ant_encoded"
}

__ant_decode_q() {
    [ $# -eq 2 ] || return 2
    local out="$1" encoded="$2" value
    # %q is produced locally/by a cooperating MACHINE. Reject obvious command
    # substitutions before eval; this is framing, not an authorization layer.
    [[ "$encoded" != *'$('* && "$encoded" != *'`'* ]] || return 3
    eval "value=$encoded" || return
    printf -v "$out" '%s' "$value"
}

__ant_frame_decode() {
    [ $# -eq 3 ] || return 2
    local _ant_raw="$1" _ant_type_out="$2" _ant_argv_out="$3"
    local _ant_tag _ant_ver _ant_type _ant_argc _ant_value
    local -a _ant_fields=()
    IFS=$'\t' read -r -a _ant_fields <<<"$_ant_raw"
    ((${#_ant_fields[@]} >= 4)) || return 3
    _ant_tag="${_ant_fields[0]}"; _ant_ver="${_ant_fields[1]}"
    _ant_type="${_ant_fields[2]}"; _ant_argc="${_ant_fields[3]}"
    [[ "$_ant_tag" == ANT && "$_ant_ver" == 1 && "$_ant_type" =~ ^[A-Z_]+$ && "$_ant_argc" =~ ^[0-9]+$ ]] || return 3
    ((${#_ant_fields[@]} == 4 + _ant_argc)) || return 3
    local -a _ant_decoded=()
    local _ant_i
    for ((_ant_i=0; _ant_i<_ant_argc; _ant_i++)); do
        __ant_decode_q _ant_value "${_ant_fields[4+_ant_i]}" || return
        _ant_decoded+=("$_ant_value")
    done
    printf -v "$_ant_type_out" '%s' "$_ant_type"
    local -n _ant_argv_ref="$_ant_argv_out"
    _ant_argv_ref=("${_ant_decoded[@]}")
}

define_ant_exchange_api() {
    local ns="$1" body
    body=$(cat <<'ANT_EOF'
__NS___ant_init() {
    eval "declare -g -A __NS___ANT_LEASE_LIMIT=()"
    eval "declare -g -A __NS___ANT_LEASE_BUSY=()"
    eval "declare -g -A __NS___ANT_LEASE_OWNER=()"
    eval "declare -g -A __NS___ANT_JOB_LEASE=()"
    eval "declare -g -A __NS___ANT_JOB_PID=()"
    eval "declare -g -A __NS___ANT_JOB_RESULT_FILE=()"
    eval "declare -g -A __NS___ANT_JOB_DIR=()"
    eval "declare -g -A __NS___ANT_JOB_RESULT_FILE=()"
    eval "declare -g -A __NS___ANT_RESULT_RC=()"
    eval "declare -g -A __NS___ANT_RESULT_DATA=()"
    printf -v "__NS___ANT_LEASE_SEQ" '%s' 0
    printf -v "__NS___ANT_JOB_SEQ" '%s' 0
    printf -v "__NS___ANT_RESERVED" '%s' 0
}

__NS___ant_available() {
    __NS___resource_refresh_workers || return
    local free="${__NS___RESOURCE[workers.free]:-0}" reserved="${__NS___ANT_RESERVED:-0}"
    free=$((free - reserved)); ((free < 0)) && free=0
    printf '%s\n' "$free"
}

__NS___ant_send() {
    [ $# -ge 1 ] || return 2
    local frame
    __ant_frame_encode frame "$@" || return
    __NS___tcp_send "$frame"
}

__NS___ant_request_resources() {
    __NS___ant_send RESOURCE_QUERY
}

__NS___ant_request_lease() {
    [ $# -eq 1 ] || return 2
    [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 2
    __NS___ant_send LEASE_REQUEST "$1"
}

__NS___ant_release_lease() {
    [ $# -eq 1 ] || return 2
    __NS___ant_send LEASE_RELEASE "$1"
}

__NS___ant_submit() {
    [ $# -ge 3 ] || return 2
    local lease="$1" artifact="$2"; shift 2
    [[ -r "$artifact" ]] || return 3
    local code hash job_id
    code="$(base64 <"$artifact" | tr -d '\n')" || return
    hash="$(sha256sum "$artifact" | awk '{print $1}')" || return
    printf -v "__NS___ANT_JOB_SEQ" '%s' "$(( ${__NS___ANT_JOB_SEQ:-0} + 1 ))"
    job_id="${__NS___ANT_JOB_SEQ}"
    __NS___ant_send JOB "$lease" "$job_id" "$hash" "$code" "$@"
    printf '%s\n' "$job_id"
}

__NS___ant_handle_resource_query() {
    local total free offered
    __NS___resource_refresh_workers || return
    total="${__NS___RESOURCE[workers.total]:-0}"
    free="$(__NS___ant_available)" || return
    offered="$free"
    __NS___ant_send RESOURCE_REPLY "$total" "$free" "$offered"
}

__NS___ant_handle_lease_request() {
    local wanted="$1" available grant lease
    [[ "$wanted" =~ ^[1-9][0-9]*$ ]] || return 2
    available="$(__NS___ant_available)" || return
    grant="$wanted"; ((grant > available)) && grant="$available"
    if ((grant == 0)); then
        __NS___ant_send LEASE_DENY no_capacity
        return
    fi
    printf -v "__NS___ANT_LEASE_SEQ" '%s' "$(( ${__NS___ANT_LEASE_SEQ:-0} + 1 ))"
    lease="lease_${__NS___ANT_LEASE_SEQ}"
    __NS___ANT_LEASE_LIMIT["$lease"]="$grant"
    __NS___ANT_LEASE_BUSY["$lease"]=0
    __NS___ANT_LEASE_OWNER["$lease"]="peer"
    printf -v "__NS___ANT_RESERVED" '%s' "$(( ${__NS___ANT_RESERVED:-0} + grant ))"
    __NS___ant_send LEASE_GRANT "$lease" "$grant"
}

__NS___ant_handle_lease_release() {
    local lease="$1" limit busy
    [[ -v __NS___ANT_LEASE_LIMIT["$lease"] ]] || { __NS___ant_send ERROR unknown_lease; return 1; }
    busy="${__NS___ANT_LEASE_BUSY[$lease]:-0}"
    ((busy == 0)) || { __NS___ant_send ERROR lease_busy "$lease" "$busy"; return 1; }
    limit="${__NS___ANT_LEASE_LIMIT[$lease]}"
    printf -v "__NS___ANT_RESERVED" '%s' "$(( ${__NS___ANT_RESERVED:-0} - limit ))"
    ((__NS___ANT_RESERVED < 0)) && printf -v "__NS___ANT_RESERVED" '%s' 0
    unset '__NS___ANT_LEASE_LIMIT[$lease]' '__NS___ANT_LEASE_BUSY[$lease]' '__NS___ANT_LEASE_OWNER[$lease]'
    __NS___ant_send LEASE_RELEASED "$lease"
}

__NS___ant_handle_job() {
    [ $# -ge 4 ] || return 2
    local lease="$1" job_id="$2" expected_hash="$3" code64="$4"; shift 4
    local limit busy dir artifact actual_hash pid result_file
    [[ -v __NS___ANT_LEASE_LIMIT["$lease"] ]] || { __NS___ant_send RESULT "$job_id" 125 unknown_lease; return 1; }
    limit="${__NS___ANT_LEASE_LIMIT[$lease]}"; busy="${__NS___ANT_LEASE_BUSY[$lease]:-0}"
    ((busy < limit)) || { __NS___ant_send RESULT "$job_id" 126 lease_full; return 1; }
    dir="$(mktemp -d "${TMPDIR:-/tmp}/__NS__.ant.${job_id}.XXXXXX")" || return
    artifact="$dir/worker.bash"; result_file="$dir/result.frame"
    printf '%s' "$code64" | base64 -d >"$artifact" || { rm -rf "$dir"; return; }
    actual_hash="$(sha256sum "$artifact" | awk '{print $1}')" || { rm -rf "$dir"; return; }
    [[ "$actual_hash" == "$expected_hash" ]] || { rm -rf "$dir"; __NS___ant_send RESULT "$job_id" 127 hash_mismatch; return 1; }
    bash -n "$artifact" || { rm -rf "$dir"; __NS___ant_send RESULT "$job_id" 128 syntax_error; return 1; }
    __NS___ANT_LEASE_BUSY["$lease"]=$((busy + 1))
    # Child owns only execution. It returns one local frame through an atomic
    # rename; only the canonical HOST parent owns and writes the TCP endpoint.
    (
        set +e; source "$artifact"
        if declare -F worker >/dev/null; then result="$(worker "$dir" 0 "$@" 2>&1)"; rc=$?; else result=missing_worker_function; rc=129; fi
        frame=""; __ant_frame_encode frame CHILD_RESULT "$job_id" "$rc" "$result" || exit 130
        printf '%s\n' "$frame" >"${result_file}.tmp" && mv -f "${result_file}.tmp" "$result_file"
    ) &
    pid=$!
    __NS___ANT_JOB_LEASE["$job_id"]="$lease"; __NS___ANT_JOB_PID["$job_id"]="$pid"
    __NS___ANT_JOB_RESULT_FILE["$job_id"]="$result_file"; __NS___ANT_JOB_DIR["$job_id"]="$dir"
}

__NS___ant_reap() {
    local job pid lease busy file raw type dir
    local -a argv=()
    for job in "${!__NS___ANT_JOB_PID[@]}"; do
        pid="${__NS___ANT_JOB_PID[$job]}"; file="${__NS___ANT_JOB_RESULT_FILE[$job]}"
        if [[ -s "$file" ]]; then
            IFS= read -r raw <"$file" || continue; argv=(); __ant_frame_decode "$raw" type argv || continue
            [[ "$type" == CHILD_RESULT && "${argv[0]}" == "$job" ]] || continue
            __NS___ant_send RESULT "$job" "${argv[1]}" "${argv[2]-}" || return
            wait "$pid" 2>/dev/null || true
        elif ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true; __NS___ant_send RESULT "$job" 131 child_lost || return
        else
            continue
        fi
        lease="${__NS___ANT_JOB_LEASE[$job]}"; busy="${__NS___ANT_LEASE_BUSY[$lease]:-1}"
        ((busy > 0)) && __NS___ANT_LEASE_BUSY["$lease"]=$((busy - 1))
        dir="${__NS___ANT_JOB_DIR[$job]:-}"; [[ -n "$dir" ]] && rm -rf "$dir"
        unset '__NS___ANT_JOB_PID[$job]' '__NS___ANT_JOB_LEASE[$job]' '__NS___ANT_JOB_RESULT_FILE[$job]' '__NS___ANT_JOB_DIR[$job]'
    done
}

__NS___ant_receive_once() {
    local raw type
    local -a argv=()
    __NS___ant_reap || return
    __NS___tcp_receive raw "${1:-1}" || { __NS___ant_reap || true; return 1; }
    __ant_frame_decode "$raw" type argv || return
    case "$type" in
        RESOURCE_QUERY) __NS___ant_handle_resource_query ;;
        RESOURCE_REPLY)
            __NS___PEER_RESOURCE["explicit|workers.total"]="${argv[0]}"
            __NS___PEER_RESOURCE["explicit|workers.free"]="${argv[1]}"
            __NS___PEER_RESOURCE["explicit|workers.offered"]="${argv[2]}"
            ;;
        LEASE_REQUEST) __NS___ant_handle_lease_request "${argv[0]}" ;;
        LEASE_GRANT)
            printf -v "__NS___ANT_REMOTE_LEASE" '%s' "${argv[0]}"
            printf -v "__NS___ANT_REMOTE_GRANTED" '%s' "${argv[1]}"
            ;;
        LEASE_DENY) printf -v "__NS___ANT_LAST_ERROR" '%s' "${argv[*]}" ;;
        LEASE_RELEASE) __NS___ant_handle_lease_release "${argv[0]}" ;;
        LEASE_RELEASED)
            [[ "${__NS___ANT_REMOTE_LEASE:-}" == "${argv[0]}" ]] && {
                unset __NS___ANT_REMOTE_LEASE __NS___ANT_REMOTE_GRANTED
            }
            ;;
        JOB) __NS___ant_handle_job "${argv[@]}" ;;
        RESULT)
            __NS___ANT_RESULT_RC["${argv[0]}"]="${argv[1]}"
            __NS___ANT_RESULT_DATA["${argv[0]}"]="${argv[2]-}"
            ;;
        ERROR) printf -v "__NS___ANT_LAST_ERROR" '%s' "${argv[*]}" ;;
        *) return 4 ;;
    esac
    __NS___ant_reap
}

__NS___ant_wait_result() {
    [ $# -ge 1 ] && [ $# -le 2 ] || return 2
    local job="$1" timeout="${2:-30}" deadline
    deadline=$((SECONDS + timeout))
    while [[ ! -v __NS___ANT_RESULT_RC["$job"] ]]; do
        __NS___ant_receive_once 1 || true
        ((SECONDS < deadline)) || return 124
    done
    printf '%s\n' "${__NS___ANT_RESULT_DATA[$job]}"
    return "${__NS___ANT_RESULT_RC[$job]}"
}
ANT_EOF
)
    body="${body//__NS__/$ns}"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

ant_endpoint_constructor() {
    [ $# -ge 4 ] && [ $# -le 5 ] || return 2
    local ns="$1" mode="$2" host="$3" port="$4" helper="${5:-${ASYNC_TCP_HELPER:-/mnt/data/async_tcp_helper_step33.py}}"
    asyncobj_constructor "$ns" "" || return
    printf -v "${ns}_OBJECT_TYPE" '%s' RESOURCE_CONTAINER
    define_comm_api "$ns" || return
    define_ant_exchange_api "$ns" || return
    "${ns}_ant_init" || return
    "${ns}_tcp_init" "$mode" "$host" "$port" "$helper"
}

bridge_constructor() {
    [ $# -ge 4 ] && [ $# -le 6 ] || return 2
    local ns="$1" mode="$2" host="$3" port="$4" data_target="${5:-}" helper="${6:-${ASYNC_TCP_HELPER:-/mnt/data/async_tcp_helper_step33.py}}"
    asyncobj_constructor "$ns" "" || return
    printf -v "${ns}_OBJECT_TYPE" '%s' BRIDGE
    printf -v "${ns}_BRIDGE_DATA_TARGET" '%s' "$data_target"
    printf -v "${ns}_BRIDGE_CONTROL_TARGET_NS" '%s' ""
    define_comm_api "$ns" || return
    define_tcp_capability_gate "$ns" || return
    printf -v "${ns}_TARGET_WORKER_FUNC" '%s' "${ns}_bridge_worker_func"
    "${ns}_tcp_init" "$mode" "$host" "$port" "$helper"
}


# ============================================================================
# 15. CONTROL SECURITY ABI v1
# ============================================================================
# Security boundary is TCP -> FIFO, not FIFO itself.
# Local FIFO remains fully capable (including X/C).
#
# Remote policy:
#   X : denied unconditionally
#   C : only explicitly allowed function names
#   O/S/A and unknown tags : denied by default
#
# A bridge may extend its allow-list explicitly.

define_remote_control_gate() {
    [ $# -eq 1 ] || return 2
    local ns="$1" body
    body=$(cat <<'GATE_EOF'
declare -g -A __NS___REMOTE_C_ALLOW=()
__NS___REMOTE_CONTROL_ACCEPTED=0
__NS___REMOTE_CONTROL_DENIED=0

__NS___remote_allow_call() {
    [ $# -eq 1 ] || return 2
    __NS___REMOTE_C_ALLOW["$1"]=1
}

__NS___remote_deny_call() {
    [ $# -eq 1 ] || return 2
    unset '__NS___REMOTE_C_ALLOW[$1]'
}

__NS___remote_control_gate() {
    [ $# -eq 1 ] || return 2
    local raw="$1" tag argc encoded_func func
    IFS=$'\t' read -r tag argc encoded_func _ <<<"$raw"

    case "$tag" in
        X)
            ((__NS___REMOTE_CONTROL_DENIED++)) || true
            return 77
            ;;
        C)
            [[ "$argc" =~ ^[0-9]+$ && "$argc" -ge 1 && -n "$encoded_func" ]] || {
                ((__NS___REMOTE_CONTROL_DENIED++)) || true
                return 78
            }
            __asyncobj_decode_q "$encoded_func" func || {
                ((__NS___REMOTE_CONTROL_DENIED++)) || true
                return 78
            }
            [[ -n "${__NS___REMOTE_C_ALLOW[$func]:-}" ]] || {
                ((__NS___REMOTE_CONTROL_DENIED++)) || true
                return 79
            }
            ;;
        *)
            ((__NS___REMOTE_CONTROL_DENIED++)) || true
            return 80
            ;;
    esac

    ((__NS___REMOTE_CONTROL_ACCEPTED++)) || true
    return 0
}

__NS___tcp_forward_fifo_guarded() {
    [ $# -eq 1 ] || return 2
    local raw="$1"
    __NS___remote_control_gate "$raw" || return
    __NS___tcp_forward_fifo "$raw"
}
GATE_EOF
)
    body="${body//__NS__/$ns}"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}



# ============================================================================
# 16. TCP CAPABILITY GATE ABI v2
# ============================================================================
# Authorization applies ONLY to control frames that crossed TCP.
# Local FIFO remains untouched and retains the full FIFO ABI, including X/C.
#
# TCP control envelope:
#   CTRL<TAB>src_obj_id<TAB>dst_obj_id<TAB>capability<TAB><raw FIFO frame>
#
# Authorization key:
#   src_obj_id -> dst_obj_id -> capability -> FIFO operation
#
# Operation is:
#   X
#   C:<function>
#   <tag>              for other FIFO tags

define_tcp_capability_gate() {
    [ $# -eq 1 ] || return 2
    local ns="$1" body
    body=$(cat <<'CAP_EOF'
declare -g -A __NS___TCP_CAPS=()
__NS___TCP_CAP_ACCEPTED=0
__NS___TCP_CAP_DENIED=0

__NS___tcp_cap_key() {
    [ $# -eq 4 ] || return 2
    local out="$1" src="$2" dst="$3" spec="$4"
    printf -v "$out" '%s' "$src"$'\034'"$dst"$'\034'"$spec"
}

# Grant one exact operation to a source/target pair.
# Examples:
#   ns_tcp_cap_grant AS_A:1 AS_B:2 CONTROL C:foo
#   ns_tcp_cap_grant AS_A:1 AS_B:2 MUTATE_CODE X
__NS___tcp_cap_grant() {
    [ $# -eq 4 ] || return 2
    local src="$1" dst="$2" capability="$3" operation="$4" key
    __NS___tcp_cap_key key "$src" "$dst" "$capability:$operation" || return
    __NS___TCP_CAPS["$key"]=1
}

__NS___tcp_cap_revoke() {
    [ $# -eq 4 ] || return 2
    local src="$1" dst="$2" capability="$3" operation="$4" key
    __NS___tcp_cap_key key "$src" "$dst" "$capability:$operation" || return
    unset '__NS___TCP_CAPS[$key]'
}

__NS___tcp_cap_operation() {
    [ $# -eq 2 ] || return 2
    local raw="$1" out="$2" tag argc encoded_func func
    IFS=$'\t' read -r tag argc encoded_func _ <<<"$raw"
    case "$tag" in
        C)
            [[ "$argc" =~ ^[0-9]+$ && "$argc" -ge 1 && -n "$encoded_func" ]] || return 78
            __asyncobj_decode_q "$encoded_func" func || return 78
            printf -v "$out" 'C:%s' "$func"
            ;;
        X)
            printf -v "$out" '%s' X
            ;;
        *)
            printf -v "$out" '%s' "$tag"
            ;;
    esac
}

__NS___tcp_control_wrap() {
    [ $# -eq 5 ] || return 2
    local out="$1" src="$2" dst="$3" capability="$4" raw="$5"
    [[ "$src" != *$'\t'* && "$dst" != *$'\t'* && "$capability" != *$'\t'* ]] || return 3
    printf -v "$out" 'CTRL\t%s\t%s\t%s\t%s' "$src" "$dst" "$capability" "$raw"
}

__NS___tcp_control_unwrap() {
    [ $# -eq 6 ] || return 2
    local envelope="$1" out_src="$2" out_dst="$3" out_cap="$4" out_raw="$5" out_op="$6"
    local kind _src _dst _cap _raw _op
    IFS=$'\t' read -r kind _src _dst _cap _raw <<<"$envelope"
    [[ "$kind" == CTRL && -n "$_src" && -n "$_dst" && -n "$_cap" && -n "$_raw" ]] || return 81
    __NS___tcp_cap_operation "$_raw" _op || return
    printf -v "$out_src" '%s' "$_src"
    printf -v "$out_dst" '%s' "$_dst"
    printf -v "$out_cap" '%s' "$_cap"
    printf -v "$out_raw" '%s' "$_raw"
    printf -v "$out_op" '%s' "$_op"
}

__NS___tcp_capability_gate() {
    [ $# -eq 1 ] || return 2
    local envelope="$1" src dst cap raw op key
    __NS___tcp_control_unwrap "$envelope" src dst cap raw op || {
        ((__NS___TCP_CAP_DENIED++)) || true
        return 81
    }

    # The receiving bridge may optionally be pinned to one destination.
    if [[ -n "${__NS___TCP_EXPECT_DST:-}" && "$dst" != "${__NS___TCP_EXPECT_DST}" ]]; then
        ((__NS___TCP_CAP_DENIED++)) || true
        return 82
    fi

    __NS___tcp_cap_key key "$src" "$dst" "$cap:$op" || return
    [[ -n "${__NS___TCP_CAPS[$key]:-}" ]] || {
        ((__NS___TCP_CAP_DENIED++)) || true
        return 83
    }

    printf -v __NS___TCP_GATE_RAW '%s' "$raw"
    printf -v __NS___TCP_GATE_SRC '%s' "$src"
    printf -v __NS___TCP_GATE_DST '%s' "$dst"
    printf -v __NS___TCP_GATE_CAP '%s' "$cap"
    printf -v __NS___TCP_GATE_OP '%s' "$op"
    ((__NS___TCP_CAP_ACCEPTED++)) || true
}

__NS___tcp_forward_fifo_capability() {
    [ $# -eq 1 ] || return 2
    __NS___tcp_capability_gate "$1" || return
    __NS___tcp_forward_fifo "$__NS___TCP_GATE_RAW"
}

# Send a FIFO frame over TCP with explicit authority metadata.
__NS___forward_tcp_control() {
    [ $# -eq 4 ] || return 2
    local src="$1" dst="$2" capability="$3" raw="$4" envelope
    __NS___tcp_control_wrap envelope "$src" "$dst" "$capability" "$raw" || return
    __NS___tcp_send "$envelope"
}
CAP_EOF
)
    body="${body//__NS__/$ns}"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}



# ============================================================================
# 17. ASYNC_SCRIPT AS FIRST-CLASS ASYNC_OBJECT ABI v1
# ============================================================================
# ASYNC_SCRIPT now owns the same base identity/control-plane substrate as every
# other async_object: UUID, obj_id, ns and FIFO.  Its X*Y BLANK pool remains
# children/capacity and is not itself the script identity.

create_blank_async_script() {
    [ $# -eq 4 ] || return 2
    local as="$1" x="$2" y="$3" n="$4"
    [[ "$as" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 2
    [[ "$x" =~ ^[1-9][0-9]*$ && "$y" =~ ^[1-9][0-9]*$ && "$n" =~ ^[1-9][0-9]*$ ]] || return 2

    # Allocate the script itself first. This is NOT one of the X*Y blank slots.
    create_blank_object "$as" || return
    local script_obj_id="${as}_OBJECT_ID" script_uuid="${as}_OBJECT_UUID"
    local script_obj_id_v="${!script_obj_id}" script_uuid_v="${!script_uuid}"

    # Existing compiler constructor remains authoritative for topology storage
    # and the X*Y child BLANK pool.
    __create_blank_async_script_topology_legacy "$as" "$x" "$y" "$n" || return

    # Restore/declare first-class script identity after legacy initialization.
    printf -v "${as}_OBJECT_ID" '%s' "$script_obj_id_v"
    printf -v "${as}_OBJECT_UUID" '%s' "$script_uuid_v"
    printf -v "${as}_OBJECT_TYPE" '%s' ASYNC_SCRIPT
    printf -v "${as}_SCRIPT_OBJECT_ID" '%s' "$script_obj_id_v"
    printf -v "${as}_SCRIPT_UUID" '%s' "$script_uuid_v"

    # Explicit ownership metadata: BLANK slots belong to this ASYNC_SCRIPT.
    local slots_var="${as}_SLOTS" slot_ns
    if declare -p "$slots_var" &>/dev/null; then
        local -n _slots="$slots_var"
        for slot_ns in "${_slots[@]}"; do
            [[ -n "$slot_ns" ]] || continue
            printf -v "${slot_ns}_OWNER_SCRIPT_OBJ_ID" '%s' "$script_obj_id_v"
            printf -v "${slot_ns}_OWNER_SCRIPT_UUID" '%s' "$script_uuid_v"
        done
    fi
}

async_script_owns_object() {
    [ $# -eq 2 ] || return 2
    local as="$1" child_ns="$2"
    local sid_var="${as}_OBJECT_ID" owner_var="${child_ns}_OWNER_SCRIPT_OBJ_ID"
    [[ -n "${!sid_var:-}" && "${!owner_var:-}" == "${!sid_var}" ]]
}



# ============================================================================
# 18. PROJECT ABI v2 + STANDALONE MACHINE LINKER
# ============================================================================
#
# PROJECT and MACHINE are deliberately separate domains.
#
# PROJECT:
#   - editor/compiler source representation
#   - owns an A x B field and declarations only
#   - does NOT allocate runtime async objects
#   - does NOT create FIFOs, FDs, UUIDs, obj_ids, tasks, or worker pools
#   - remains editable after every compilation
#
# MACHINE:
#   - generated standalone async_script.bash
#   - materializes only declared runtime objects
#   - allocates runtime identity/FIFO state when the generated script starts
#   - contains linked worker code and compiled graph wiring
#
# The older create_blank_async_script/compile_topology APIs remain above for
# compatibility with earlier runtime experiments. New project code MUST use
# create_project + compile_project.

__asyncproject_q() { local out="$1" value="$2"; printf -v "$out" '%q' "$value"; }
__asyncproject_unq() { [ $# -eq 2 ] || return 2; __asyncobj_decode_q "$1" "$2"; }

create_project() {
    [ $# -eq 4 ] || return 2
    local project="$1" x="$2" y="$3" max_workers="$4"
    __asyncscript_safe_name "$project" || return 2
    [[ "$x" =~ ^[1-9][0-9]*$ && "$y" =~ ^[1-9][0-9]*$ &&
       "$max_workers" =~ ^[1-9][0-9]*$ ]] || return 2

    # A project is metadata, not a live async object. In particular, do not call
    # create_blank_object/create_blank_async_script here.
    printf -v "${project}_PROJECT_ABI" '%s' 2
    printf -v "${project}_PROJECT_STATE" '%s' EDITABLE
    printf -v "${project}_GRID_X" '%s' "$x"
    printf -v "${project}_GRID_Y" '%s' "$y"
    printf -v "${project}_MAX_WORKERS_PER_OBJECT" '%s' "$max_workers"

    eval "declare -g -a ${project}_DECL_OBJECTS=() ${project}_EDGES=()"
    eval "declare -g -A ${project}_DECL_TYPE=() ${project}_DECL_X=() ${project}_DECL_Y=()"
    eval "declare -g -A ${project}_DECL_WORKER_FILE=() ${project}_DECL_WORKERS=()"
    eval "declare -g -A ${project}_DECL_RESOURCE_KIND=() ${project}_DECL_RESOURCE_ARG=()"
    eval "declare -g -a ${project}_PARAM_ORDER=()"
    eval "declare -g -A ${project}_PARAM_TYPE=() ${project}_PARAM_DEFAULT=() ${project}_PARAM_REQUIRED=()"
    printf -v "${project}_ENTRY_OBJECT" '%s' ""
    # Worker execution policy. Local object-to-object delivery itself is always
    # direct; FIFO is reserved for crossing back from a child process.
    eval "declare -g -A ${project}_EXEC_MODE=()"
}

project_register_object() {
    [ $# -ge 3 ] && [ $# -le 5 ] || return 2
    local project="$1" name="$2" type="$3" x="${4:-}" y="${5:-}"
    local abi="${project}_PROJECT_ABI"
    [[ "${!abi:-}" == 2 ]] || return 3
    __asyncscript_safe_name "$name" || return 2
    case "$type" in
        ORIGIN|PIPE|ENDPOINT|T|Y|BIFURCATOR|SENSOR|SCHEDULER|DRIVER|GOD|RESOURCE_CONTAINER|BRIDGE) ;;
        *) return 2 ;;
    esac

    local gx="${project}_GRID_X" gy="${project}_GRID_Y"
    local -n objs="${project}_DECL_OBJECTS" types="${project}_DECL_TYPE"
    local -n xs="${project}_DECL_X" ys="${project}_DECL_Y"
    [[ ! -v types["$name"] ]] || return 4

    # If coordinates are omitted, place declarations row-major in the project
    # field. Coordinates are source/editor metadata and are not runtime identity.
    if [[ -z "$x" || -z "$y" ]]; then
        local idx="${#objs[@]}"
        x=$((idx % ${!gx}))
        y=$((idx / ${!gx}))
    fi
    [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] || return 2
    (( x < ${!gx} && y < ${!gy} )) || return 5

    local other
    for other in "${objs[@]}"; do
        [[ "${xs[$other]}" != "$x" || "${ys[$other]}" != "$y" ]] || return 6
    done

    objs+=("$name")
    types["$name"]="$type"
    xs["$name"]="$x"
    ys["$name"]="$y"
}

project_connect_objects() {
    [ $# -eq 5 ] || return 2
    local project="$1" src="$2" src_port="$3" dst="$4" dst_port="$5"
    local -n types="${project}_DECL_TYPE" edges="${project}_EDGES"
    [[ -v types["$src"] && -v types["$dst"] ]] || return 4
    __asyncscript_port_valid "${types[$src]}" out "$src_port" || return 5
    __asyncscript_port_valid "${types[$dst]}" in "$dst_port" || return 6
    edges+=("$src"$'\t'"$src_port"$'\t'"$dst"$'\t'"$dst_port")
}

project_implant_worker_code() {
    [ $# -eq 3 ] || return 2
    local project="$1" obj="$2" file="$3"
    [[ -r "$file" ]] || return 3
    bash -n "$file" || return 4
    local -n types="${project}_DECL_TYPE" wf="${project}_DECL_WORKER_FILE"
    [[ -v types["$obj"] ]] || return 5
    wf["$obj"]="$file"
}

project_set_object_workers() {
    [ $# -eq 3 ] || return 2
    local project="$1" obj="$2" workers="$3" maxv="${1}_MAX_WORKERS_PER_OBJECT"
    [[ "$workers" =~ ^[1-9][0-9]*$ ]] || return 2
    (( workers <= ${!maxv} )) || return 4
    local -n types="${project}_DECL_TYPE" dw="${project}_DECL_WORKERS"
    [[ -v types["$obj"] ]] || return 5
    dw["$obj"]="$workers"
}

__asyncproject_add_resource() {
    [ $# -eq 4 ] || return 2
    local project="$1" obj="$2" kind="$3" arg="$4"
    local -n types="${project}_DECL_TYPE"
    local -n rk="${project}_DECL_RESOURCE_KIND" ra="${project}_DECL_RESOURCE_ARG"
    [[ -v types["$obj"] ]] || return 4
    rk["$obj"]="$kind"; ra["$obj"]="$arg"
}
project_add_file()   { [ $# -ge 3 ] && [ $# -le 4 ] || return 2; __asyncproject_add_resource "$1" "$2" file "$3"$'\t'"${4:-r}"; }
project_add_stdin()  { [ $# -eq 2 ] || return 2; __asyncproject_add_resource "$1" "$2" stdin ""; }
project_add_stdout() { [ $# -eq 2 ] || return 2; __asyncproject_add_resource "$1" "$2" stdout ""; }
project_add_stderr() { [ $# -eq 2 ] || return 2; __asyncproject_add_resource "$1" "$2" stderr ""; }

# Define one positional runtime parameter of the generated MACHINE.
# Types are intentionally small in ABI v1: int, uint, bool, string.
# A missing default means the parameter is required.
project_define_parameter() {
    [ $# -ge 3 ] && [ $# -le 4 ] || return 2
    local project="$1" name="$2" type="$3" default_marker="${4+x}" default="${4:-}"
    __asyncscript_safe_name "$name" || return 2
    case "$type" in int|uint|bool|string) ;; *) return 3 ;; esac
    local -n order="${project}_PARAM_ORDER" types="${project}_PARAM_TYPE"
    local -n defaults="${project}_PARAM_DEFAULT" required="${project}_PARAM_REQUIRED"
    [[ ! -v types["$name"] ]] || return 4
    order+=("$name"); types["$name"]="$type"
    if [[ -n "$default_marker" ]]; then
        defaults["$name"]="$default"; required["$name"]=0
    else
        defaults["$name"]=""; required["$name"]=1
    fi
}

project_set_entrypoint() {
    [ $# -eq 2 ] || return 2
    local project="$1" obj="$2"
    local -n types="${project}_DECL_TYPE"
    [[ -v types["$obj"] ]] || return 3
    printf -v "${project}_ENTRY_OBJECT" '%s' "$obj"
}

project_set_execution_mode() {
    [ $# -eq 3 ] || return 2
    local project="$1" obj="$2" mode="$3"
    local -n types="${project}_DECL_TYPE" modes="${project}_EXEC_MODE"
    [[ -v types["$obj"] ]] || return 3
    [[ "$mode" == DIRECT ]] && mode=INLINE
    case "$mode" in ASYNC|INLINE|PERSISTENT) ;; *) return 4 ;; esac
    modes["$obj"]="$mode"
}

project_enable_local_data_fastpath() {
    # STEP31 compatibility shim. Local DATA delivery is direct by invariant.
    [ $# -ge 1 ] && [ $# -le 2 ] || return 2
    return 0
}

save_project() {
    [ $# -eq 2 ] || return 2
    local project="$1" file="$2"
    local gx="${project}_GRID_X" gy="${project}_GRID_Y" mw="${project}_MAX_WORKERS_PER_OBJECT"
    local abi="${project}_PROJECT_ABI"
    [[ "${!abi:-}" == 2 ]] || return 3
    local -n objs="${project}_DECL_OBJECTS" types="${project}_DECL_TYPE"
    local -n xs="${project}_DECL_X" ys="${project}_DECL_Y"
    local -n wf="${project}_DECL_WORKER_FILE" dw="${project}_DECL_WORKERS"
    local -n rk="${project}_DECL_RESOURCE_KIND" ra="${project}_DECL_RESOURCE_ARG"
    local -n edges="${project}_EDGES"

    local tmp="${file}.tmp.$$" obj qn qt qs qk qa
    mkdir -p -- "$(dirname -- "$file")" || return
    : >"$tmp" || return
    printf 'PHI_ASYNC_PROJECT\t2\n' >>"$tmp"
    printf 'FIELD\t%s\t%s\t%s\n' "${!gx}" "${!gy}" "${!mw}" >>"$tmp"

    local -n porder="${project}_PARAM_ORDER" ptypes="${project}_PARAM_TYPE"
    local -n pdefaults="${project}_PARAM_DEFAULT" prequired="${project}_PARAM_REQUIRED"
    local pname qpname qptype qpdefault
    for pname in "${porder[@]}"; do
        __asyncproject_q qpname "$pname"; __asyncproject_q qptype "${ptypes[$pname]}"
        __asyncproject_q qpdefault "${pdefaults[$pname]:-}"
        printf 'PARAM\t%s\t%s\t%s\t%s\n' "$qpname" "$qptype" "${prequired[$pname]}" "$qpdefault" >>"$tmp"
    done
    local entryv="${project}_ENTRY_OBJECT"
    if [[ -n "${!entryv:-}" ]]; then __asyncproject_q qn "${!entryv}"; printf 'ENTRY\t%s\n' "$qn" >>"$tmp"; fi

    for obj in "${objs[@]}"; do
        __asyncproject_q qn "$obj"; __asyncproject_q qt "${types[$obj]}"
        printf 'OBJECT\t%s\t%s\t%s\t%s\t%s\n' "$qn" "$qt" "${xs[$obj]}" "${ys[$obj]}" "${dw[$obj]:-${!mw}}" >>"$tmp"
        if [[ -n "${wf[$obj]:-}" ]]; then
            [[ -r "${wf[$obj]}" ]] || { rm -f -- "$tmp"; return 4; }
            __asyncproject_q qs "$(cat -- "${wf[$obj]}")"
            printf 'WORKER_SOURCE\t%s\t%s\n' "$qn" "$qs" >>"$tmp"
        fi
        if [[ -n "${rk[$obj]:-}" ]]; then
            __asyncproject_q qk "${rk[$obj]}"; __asyncproject_q qa "${ra[$obj]:-}"
            printf 'RESOURCE\t%s\t%s\t%s\n' "$qn" "$qk" "$qa" >>"$tmp"
        fi
    done

    local e src sp dst dp qsrc qsp qdst qdp
    for e in "${edges[@]}"; do
        IFS=$'\t' read -r src sp dst dp <<<"$e"
        __asyncproject_q qsrc "$src"; __asyncproject_q qsp "$sp"
        __asyncproject_q qdst "$dst"; __asyncproject_q qdp "$dp"
        printf 'EDGE\t%s\t%s\t%s\t%s\n' "$qsrc" "$qsp" "$qdst" "$qdp" >>"$tmp"
    done
    printf 'END\n' >>"$tmp"
    mv -f -- "$tmp" "$file"
}

load_project() {
    [ $# -eq 2 ] || return 2
    local project="$1" file="$2"
    [[ -r "$file" ]] || return 3
    local line tag a b c d e version="" gx="" gy="" mw=""
    local -a records=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        records+=("$line")
        IFS=$'\t' read -r tag a b c d e <<<"$line"
        [[ "$tag" == PHI_ASYNC_PROJECT ]] && version="$a"
        [[ "$tag" == FIELD ]] && { gx="$a"; gy="$b"; mw="$c"; }
    done <"$file"
    [[ "$version" == 2 ]] || return 4
    create_project "$project" "$gx" "$gy" "$mw" || return

    local q1 q2 q3 q4 q5 name type x y workers source path kind arg src sp dst dp
    for line in "${records[@]}"; do
        IFS=$'\t' read -r tag q1 q2 q3 q4 q5 <<<"$line"
        [[ "$tag" == OBJECT ]] || continue
        __asyncproject_unq "$q1" name || return
        __asyncproject_unq "$q2" type || return
        x="$q3"; y="$q4"; workers="$q5"
        project_register_object "$project" "$name" "$type" "$x" "$y" || return
        project_set_object_workers "$project" "$name" "$workers" || return
    done

    local source_dir
    source_dir="$(mktemp -d "${TMPDIR:-/tmp}/${project}.project-workers.XXXXXX")" || return
    printf -v "${project}_PROJECT_SOURCE_DIR" '%s' "$source_dir"

    # Parameters and entrypoint are source-level declarations and therefore
    # restored before executable artifacts are linked.
    for line in "${records[@]}"; do
        IFS=$'\t' read -r tag q1 q2 q3 q4 q5 <<<"$line"
        case "$tag" in
            PARAM)
                __asyncproject_unq "$q1" name || return
                __asyncproject_unq "$q2" type || return
                __asyncproject_unq "$q4" source || return
                if [[ "$q3" == 1 ]]; then
                    project_define_parameter "$project" "$name" "$type" || return
                else
                    project_define_parameter "$project" "$name" "$type" "$source" || return
                fi ;;
            ENTRY)
                __asyncproject_unq "$q1" name || return
                printf -v "${project}_ENTRY_OBJECT" '%s' "$name" ;;
        esac
    done

    for line in "${records[@]}"; do
        IFS=$'\t' read -r tag q1 q2 q3 q4 q5 <<<"$line"
        case "$tag" in
            EXEC)
                __asyncproject_unq "$q1" name || return
                __asyncproject_unq "$q2" type || return
                project_set_execution_mode "$project" "$name" "$type" || return ;;
            WORKER_SOURCE)
                __asyncproject_unq "$q1" name || return
                __asyncproject_unq "$q2" source || return
                path="$source_dir/${name}.worker.bash"; printf '%s\n' "$source" >"$path"
                project_implant_worker_code "$project" "$name" "$path" || return ;;
            RESOURCE)
                __asyncproject_unq "$q1" name || return
                __asyncproject_unq "$q2" kind || return
                __asyncproject_unq "$q3" arg || return
                __asyncproject_add_resource "$project" "$name" "$kind" "$arg" || return ;;
            EDGE)
                __asyncproject_unq "$q1" src || return; __asyncproject_unq "$q2" sp || return
                __asyncproject_unq "$q3" dst || return; __asyncproject_unq "$q4" dp || return
                project_connect_objects "$project" "$src" "$sp" "$dst" "$dp" || return ;;
        esac
    done
}

__asyncmachine_emit_worker() {
    [ $# -eq 3 ] || return 2
    local ns="$1" file="$2" out="$3" def impl="${ns}_worker_impl"
    def="$(bash -c 'source "$1"; declare -f "$2" 2>/dev/null || declare -f worker' _ "$file" "${ns}_worker")" || return 5
    if [[ "$def" == worker\ \(\)* ]]; then
        def="${def/#worker ()/${impl} ()}"
    else
        def="${def/#${ns}_worker ()/${impl} ()}"
    fi
    printf '\n# Linked worker implementation for %s.\n%s\n' "$ns" "$def" >>"$out"
    # Worker ABI v1:
    #   $1 = worker_dir, $2 = slot_id, remaining args = DATA payload.
    # ASYNC_WORKER_NS lets generic source code address its owning object without
    # knowing the compiler-assigned machine namespace in advance.
    printf '%s_worker() { local ASYNC_WORKER_NS=%q; %s "$@"; }\n' "$ns" "$ns" "$impl" >>"$out"
}
__asyncproject_target_call() {
    [ $# -eq 4 ] || return 2
    local project="$1" dst="$2" port="$3" out="$4"
    local -n machine_ns="${project}_COMPILE_NS"
    local ns="${machine_ns[$dst]:-}"
    [[ -n "$ns" ]] || return 3
    case "$port" in
        in)  printf -v "$out" '%s_summon_worker' "$ns" ;;
        in1) printf -v "$out" '%s_receive_in1' "$ns" ;;
        in2) printf -v "$out" '%s_receive_in2' "$ns" ;;
        *) return 4 ;;
    esac
}

__asyncproject_find_edge() {
    [ $# -eq 5 ] || return 2
    local project="$1" src="$2" sport="$3" out_dst="$4" out_port="$5"
    local -n edges="${project}_EDGES"
    local edge s sp d dp
    for edge in "${edges[@]}"; do
        IFS=$'\t' read -r s sp d dp <<<"$edge"
        [[ "$s" == "$src" && "$sp" == "$sport" ]] || continue
        printf -v "$out_dst" '%s' "$d"; printf -v "$out_port" '%s' "$dp"; return 0
    done
    return 1
}

__asyncmachine_link() {
    [ $# -eq 4 ] || return 2
    local project="$1" project_file="$2" out="$3" project_hash="$4"
    local library_source="${BASH_SOURCE[0]}"
    [[ -r "$library_source" ]] || return 3

    local -n objs="${project}_DECL_OBJECTS" types="${project}_DECL_TYPE"
    local -n wf="${project}_DECL_WORKER_FILE" dw="${project}_DECL_WORKERS"
    local -n rk="${project}_DECL_RESOURCE_KIND" ra="${project}_DECL_RESOURCE_ARG"
    eval "declare -g -A ${project}_COMPILE_NS=()"
    local -n machine_ns="${project}_COMPILE_NS"

    # Machine namespaces are compiler-assigned symbols. Runtime obj_id/UUID/FIFO
    # identity is deliberately NOT allocated in the compiler process.
    local i obj ns
    for ((i=0; i<${#objs[@]}; i++)); do
        obj="${objs[$i]}"
        printf -v ns 'm_%04d_%s' "$i" "$obj"
        machine_ns["$obj"]="$ns"
    done

    {
        printf '#!/bin/bash\n'
        printf '# ==============================================================================\n'
        printf '# GENERATED ASYNC MACHINE -- DO NOT EDIT BY HAND\n'
        printf '# Machine ABI: 2\n# Project SHA256: %s\n' "$project_hash"
        printf '# Runtime identity and FIFOs are created only when this machine starts.\n'
        printf '# ==============================================================================\n\n'
        tail -n +2 "$library_source"
        printf '\n# ============================================================================\n# GENERATED MACHINE IMAGE\n# ============================================================================\n'
        printf 'ASYNC_MACHINE_ABI=2\nASYNC_MACHINE_PROJECT_SHA256=%q\nASYNC_MACHINE_NAME=%q\n' "$project_hash" "$project"
    } >"$out" || return

    # Materialize the ASYNC_SCRIPT runtime owner. It is separate from all
    # declared graph objects and owns their runtime identities.
    {
        printf '\n# First-class runtime owner of this generated MACHINE.\n'
        printf 'create_blank_object ASYNC_MACHINE || exit $?\n'
        printf 'printf -v ASYNC_MACHINE_OBJECT_TYPE %%s ASYNC_SCRIPT\n'
        printf 'ASYNC_MACHINE_SCRIPT_OBJ_ID="$ASYNC_MACHINE_OBJECT_ID"\n'
        printf 'ASYNC_MACHINE_SCRIPT_UUID="$ASYNC_MACHINE_OBJECT_UUID"\n'
    } >>"$out"

    # Link positional parameter ABI directly into the executable.
    local -n porder="${project}_PARAM_ORDER" ptypes="${project}_PARAM_TYPE"
    local -n pdefaults="${project}_PARAM_DEFAULT" prequired="${project}_PARAM_REQUIRED"
    {
        printf '\nasync_machine_parse_args() {\n'
        printf '  local argc="$#" idx=1 value name type required default\n'
    } >>"$out"
    local pname
    for pname in "${porder[@]}"; do
        printf '  name=%q; type=%q; required=%q; default=%q\n' \
            "$pname" "${ptypes[$pname]}" "${prequired[$pname]}" "${pdefaults[$pname]:-}" >>"$out"
        printf '  if (( idx <= argc )); then eval "value=\\${$idx}"; else value="$default"; [[ "$required" == 0 ]] || { printf "Missing required parameter: %%s\\\\n" "$name" >&2; return 64; }; fi\n' >>"$out"
        printf '  case "$type" in int) [[ "$value" =~ ^-?[0-9]+$ ]] || return 65;; uint) [[ "$value" =~ ^[0-9]+$ ]] || return 65;; bool) [[ "$value" == 0 || "$value" == 1 ]] || return 65;; string) :;; esac\n' >>"$out"
        printf '  printf -v "ASYNC_MACHINE_PARAM_${name}" "%%s" "$value"; export "ASYNC_MACHINE_PARAM_${name}"; ((idx++))\n' >>"$out"
    done
    {
        printf '  (( idx > argc )) || { printf "Too many machine arguments\\\\n" >&2; return 64; }\n'
        printf '}\n'
    } >>"$out"

    local maxv="${project}_MAX_WORKERS_PER_OBJECT" type workers
    for obj in "${objs[@]}"; do
        ns="${machine_ns[$obj]}"; type="${types[$obj]}"; workers="${dw[$obj]:-${!maxv}}"
        {
            printf '\n# Materialize declared runtime object %q.\n' "$obj"
            printf 'create_blank_object %q || exit $?\n' "$ns"
            printf 'printf -v %q %%s "$ASYNC_MACHINE_SCRIPT_OBJ_ID"\n' "${ns}_OWNER_SCRIPT_OBJ_ID"
            printf 'printf -v %q %%s "$ASYNC_MACHINE_SCRIPT_UUID"\n' "${ns}_OWNER_SCRIPT_UUID"
            printf 'printf -v %q %%s %q\n' "${ns}_OBJECT_TYPE" "$type"
            printf 'printf -v %q %%s %q\n' "${ns}_MAX_JOBS" "$workers"
        } >>"$out"
        if [[ -n "${wf[$obj]:-}" ]]; then
            __asyncmachine_emit_worker "$ns" "${wf[$obj]}" "$out" || return
            printf 'printf -v %q %%s %q\n' "${ns}_TARGET_WORKER_FUNC" "${ns}_worker" >>"$out"
        fi
    done

    # Generic DATA routing. The compiler resolves canonical EDGE records into
    # concrete namespace/port triples. Runtime never reads Object JSON.
    local edge esrc esport edst edport dst_ns route_count
    for obj in "${objs[@]}"; do
        ns="${machine_ns[$obj]}"; type="${types[$obj]}"; route_count=0
        printf '\n# Generic output-vector routes for %q.\n' "$obj" >>"$out"
        printf 'define_vector_forward_hook %q %q' "$ns" "$type" >>"$out"
        for edge in "${project}_EDGES"; do :; done
        local -n __route_edges="${project}_EDGES"
        for edge in "${__route_edges[@]}"; do
            IFS=$'\t' read -r esrc esport edst edport <<<"$edge"
            [[ "$esrc" == "$obj" ]] || continue
            dst_ns="${machine_ns[$edst]:-}"
            [[ -n "$dst_ns" ]] || return 33
            printf ' %q %q %q' "$esport" "$dst_ns" "$edport" >>"$out"
            ((route_count+=1))
        done
        printf '\n' >>"$out"
    done

    # STEP31 process-boundary execution lowering.
    #
    # INLINE      = worker executes in the owning shell. Local DATA propagation
    #               to the next object is a direct Bash function call.
    # ASYNC       = one child process per job. The child returns to its owner
    #               through FIFO because a child cannot mutate parent Bash state.
    # PERSISTENT  = long-lived child workers. They likewise return through FIFO.
    #
    # This is the central runtime invariant: FIFO is not a local graph transport.
    # It exists at ownership/process boundaries. Once the parent receives a
    # child result, graph propagation continues directly again.
    local -n execm="${project}_EXEC_MODE"
    local emode
    for obj in "${objs[@]}"; do
        ns="${machine_ns[$obj]}"
        type="${types[$obj]}"
        [[ -n "${wf[$obj]:-}" ]] || continue
        emode="${execm[$obj]:-INLINE}"
        [[ "$emode" == DIRECT ]] && emode=INLINE

        if [[ "$emode" == INLINE ]]; then
            {
                printf '\n# Generic vector-aware INLINE execution for %s.\n' "$ns"
                printf '%s_fast_slot=0\n' "$ns"
                printf '%s_fifo_output() {\n' "$ns"
                printf '  local slot_id="$1"; shift\n'
                printf '  %s_OUTPUT_DATA_VECTOR["$slot_id|out"]="$*"\n' "$ns"
                printf '}\n'
                printf '%s_fifo_output_port() {\n' "$ns"
                printf '  [[ $# -ge 3 ]] || return 2\n'
                printf '  local slot_id="$1" output_port="$2"; shift 2\n'
                printf '  %s_OUTPUT_DATA_VECTOR["$slot_id|$output_port"]="$*"\n' "$ns"
                printf '}\n'
                printf '%s_summon_worker() {\n' "$ns"
                printf '  [[ $# -ge 1 ]] || return 2\n'
                printf '  local input_port="$1"; shift\n'
                printf '  %s_fast_slot=$((%s_fast_slot + 1))\n' "$ns" "$ns"
                printf '  local slot_id="$%s_fast_slot" key\n' "$ns"
                printf '  %s_INPUT_DATA_VECTOR["$slot_id|$input_port"]="$*"\n' "$ns"
                printf '  for key in "${!%s_OUTPUT_DATA_VECTOR[@]}"; do [[ "$key" == "$slot_id|"* ]] && unset '\''%s_OUTPUT_DATA_VECTOR['\''"$key"'\'']'\''; done\n' "$ns" "$ns"
                printf '  %s_worker "${TMPDIR:-/tmp}" "$slot_id" "$@"\n' "$ns"
                printf '  %s_on_job_completed "$slot_id" 0\n' "$ns"
                printf '}\n'
                printf '%s_job_pool_wait() { :; }\n' "$ns"
            } >>"$out"

        elif [[ "$emode" == PERSISTENT ]]; then
            {
                printf '\n# Port-aware PERSISTENT worker pool for %s.\n' "$ns"
                # Persistent children never mutate canonical parent vectors.
                # DATA output returns as O frames; completion returns as a C frame.
                printf '%s_PERSIST_FIFO="${TMPDIR:-/tmp}/%s.persist.$$.fifo"\n' "$ns" "$ns"
                printf '%s_PERSIST_PIDS=()\n' "$ns"
                printf '%s_PERSIST_SEQ=0\n' "$ns"
                printf '%s_persistent_start() {\n' "$ns"
                printf '  [[ -p "$%s_PERSIST_FIFO" ]] || mkfifo "$%s_PERSIST_FIFO" || return\n' "$ns" "$ns"
                printf '  local i line seq input_port payload rc\n'
                printf '  for ((i=0;i<%s_MAX_JOBS;i++)); do\n' "$ns"
                printf '    ( while IFS= read -r line; do\n'
                printf '        [[ "$line" == STOP ]] && break\n'
                printf '        IFS=$'"'"'\\t'"'"' read -r seq input_port payload <<<"$line"\n'
                printf '        input_port="$(printf "%%b" "$input_port")"\n'
                printf '        payload="$(printf "%%b" "$payload")"\n'
                printf '        rc=0\n'
                printf '        %s_worker "${TMPDIR:-/tmp}" "$seq" "$payload" || rc=$?\n' "$ns"
                printf '        %s_fifo_call_parent %s_on_job_completed "$seq" "$rc"\n' "$ns" "$ns"
                printf '      done <"$%s_PERSIST_FIFO" ) &\n' "$ns"
                printf '    %s_PERSIST_PIDS+=("$!")\n' "$ns"
                printf '  done\n'
                printf '  exec {%s_PERSIST_FD}<>"$%s_PERSIST_FIFO"\n' "$ns" "$ns"
                printf '}\n'
                printf '%s_summon_worker() {\n' "$ns"
                printf '  [[ $# -ge 1 ]] || return 2\n'
                printf '  local input_port="$1"; shift\n'
                printf '  [[ "$input_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 2\n'
                printf '  %s_PERSIST_SEQ=$((%s_PERSIST_SEQ+1))\n' "$ns" "$ns"
                printf '  local seq="$%s_PERSIST_SEQ" payload="$*" key\n' "$ns"
                printf '  %s_INPUT_DATA_VECTOR["$seq|$input_port"]="$payload"\n' "$ns"
                printf '  for key in "${!%s_OUTPUT_DATA_VECTOR[@]}"; do [[ "$key" == "$seq|"* ]] && unset '\''%s_OUTPUT_DATA_VECTOR['\''"$key"'\'']'\''; done\n' "$ns" "$ns"
                printf '  input_port="${input_port//\\\\/\\\\\\\\}"; input_port="${input_port//$'"'"'\\t'"'"'/\\\\t}"; input_port="${input_port//$'"'"'\\n'"'"'/\\\\n}"\n'
                printf '  payload="${payload//\\\\/\\\\\\\\}"; payload="${payload//$'"'"'\\t'"'"'/\\\\t}"; payload="${payload//$'"'"'\\n'"'"'/\\\\n}"\n'
                printf '  printf "%%s\\t%%s\\t%%s\\n" "$seq" "$input_port" "$payload" >&"$%s_PERSIST_FD"\n' "$ns"
                printf '}\n'
                printf '%s_persistent_stop() {\n' "$ns"
                printf '  local _; for _ in "${%s_PERSIST_PIDS[@]}"; do printf "STOP\\n" >&"$%s_PERSIST_FD"; done\n' "$ns" "$ns"
                printf '  exec {%s_PERSIST_FD}>&-\n' "$ns"
                printf '  for _ in "${%s_PERSIST_PIDS[@]}"; do wait "$_" 2>/dev/null || true; done\n' "$ns"
                printf '  rm -f "$%s_PERSIST_FIFO"; %s_PERSIST_PIDS=()\n' "$ns" "$ns"
                printf '}\n'
                # Drain until queued output/completion frames are visible to owner.
                printf '%s_job_pool_wait() { sleep 0.02; %s_drain_fifo || true; }\n' "$ns" "$ns"
                printf '%s_persistent_start || exit $?\n' "$ns"
            } >>"$out"
        fi
    done

    local path mode
    for obj in "${objs[@]}"; do
        ns="${machine_ns[$obj]}"
        case "${rk[$obj]:-}" in
            file) IFS=$'\t' read -r path mode <<<"${ra[$obj]}"
                  printf 'open_file %q %q %q >/dev/null || exit $?\n' "$ns" "$path" "$mode" >>"$out" ;;
            stdin)  printf 'printf -v %q %%s 0; printf -v %q %%s stdin\n' "${ns}_RESOURCE_FD" "${ns}_RESOURCE_TYPE" >>"$out" ;;
            stdout) printf 'printf -v %q %%s 1; printf -v %q %%s stdout\n' "${ns}_RESOURCE_FD" "${ns}_RESOURCE_TYPE" >>"$out" ;;
            stderr) printf 'printf -v %q %%s 2; printf -v %q %%s stderr\n' "${ns}_RESOURCE_FD" "${ns}_RESOURCE_TYPE" >>"$out" ;;
        esac
    done
    local entryv="${project}_ENTRY_OBJECT" entry="" entry_ns=""
    entry="${!entryv:-}"
    [[ -z "$entry" ]] || entry_ns="${machine_ns[$entry]:-}"
    {
        printf '\nASYNC_MACHINE_READY=1\n'
        printf 'async_machine_wait_all() {\n'
    } >>"$out"
    for obj in "${objs[@]}"; do
        ns="${machine_ns[$obj]}"
        printf '  %s_job_pool_wait || return\n' "$ns" >>"$out"
    done
    {
        printf '}\n'
        printf 'async_machine_main() {\n'
        printf '  async_machine_parse_args "$@" || return\n'
    } >>"$out"
    if [[ -n "$entry_ns" ]]; then
        printf '  %s_summon_worker "$@" || return\n' "$entry_ns" >>"$out"
        printf '  async_machine_wait_all\n' >>"$out"
    fi
    {
        printf '}\n'
        printf 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then async_machine_main "$@"; fi\n'
    } >>"$out"
    chmod +x "$out"
    bash -n "$out"
}

compile_project() {
    [ $# -eq 2 ] || return 2
    local project="$1" outdir="$2" abi="${1}_PROJECT_ABI"
    [[ "${!abi:-}" == 2 ]] || return 3
    mkdir -p -- "$outdir" || return
    local source="$outdir/project.dalo" machine="$outdir/async_script.bash" hash
    save_project "$project" "$source" || return
    hash="$(__dalo_sha256_file "$source")" || return
    __asyncmachine_link "$project" "$source" "$machine" "$hash" || return

    # Compilation is non-destructive: the project remains editable and may be
    # compiled again after further graph/worker/resource changes.
    printf -v "${project}_LAST_PROJECT_FILE" '%s' "$source"
    printf -v "${project}_LAST_PROJECT_SHA256" '%s' "$hash"
    printf -v "${project}_LAST_MACHINE_FILE" '%s' "$machine"
}


# ============================================================================
# 19. STEP28 PERFORMANCE INSTRUMENTATION / BENCHMARK ABI v1
# ============================================================================
#
# This layer measures the existing execution path before changing it.
# Measurements are deliberately optional: normal machines pay no timing cost
# unless ASYNC_PERF_ENABLE=1 is exported.
#
# PERF records are emitted to ASYNC_PERF_FILE as TSV:
#   timestamp_ns  event  object_ns  task_or_slot  value_ns
#
# The instrumentation is diagnostic only. It must never become canonical
# object state and must never cross migration as semantic state.

ASYNC_PERF_ENABLE="${ASYNC_PERF_ENABLE:-0}"
ASYNC_PERF_FILE="${ASYNC_PERF_FILE:-}"

__async_perf_now_ns() {
    # GNU date is available in the target Linux environment. Keeping this
    # behind the enable flag avoids an external process on the normal hot path.
    date +%s%N
}

async_perf_event() {
    [[ "${ASYNC_PERF_ENABLE:-0}" == 1 && -n "${ASYNC_PERF_FILE:-}" ]] || return 0
    [ $# -ge 3 ] || return 2
    local event="$1" object_ns="$2" id="$3" value="${4:-0}" now
    now="$(__async_perf_now_ns)" || return
    printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$event" "$object_ns" "$id" "$value" >>"$ASYNC_PERF_FILE"
}

# Wrap an existing namespaced function exactly once. The wrapper records wall
# time around the original call while preserving arguments and return status.
async_perf_wrap_function() {
    [ $# -eq 3 ] || return 2
    local ns="$1" suffix="$2" event="$3"
    local fn="${ns}_${suffix}" original="${fn}__perf_original" def
    declare -F "$fn" >/dev/null || return 3
    declare -F "$original" >/dev/null && return 0
    def="$(declare -f "$fn")" || return
    def="${def/#$fn ()/$original ()}"
    eval "$def" || return
    eval "
$fn() {
    local __perf_start __perf_end __perf_rc
    if [[ \${ASYNC_PERF_ENABLE:-0} == 1 ]]; then
        __perf_start=\$(__async_perf_now_ns)
        $original \"\$@\"
        __perf_rc=\$?
        __perf_end=\$(__async_perf_now_ns)
        async_perf_event '$event' '$ns' \"\${1:-0}\" \$((__perf_end-__perf_start))
        return \"\$__perf_rc\"
    fi
    $original \"\$@\"
}"
}

async_perf_instrument_object() {
    [ $# -eq 1 ] || return 2
    local ns="$1"
    # Missing functions are acceptable because structural object types expose
    # different subsets of the runtime ABI.
    async_perf_wrap_function "$ns" summon_worker SUMMON_NS 2>/dev/null || true
    async_perf_wrap_function "$ns" on_job_completed COMPLETE_HOOK_NS 2>/dev/null || true
    async_perf_wrap_function "$ns" fifo_output FIFO_OUTPUT_NS 2>/dev/null || true
}

async_perf_instrument_machine() {
    local ns
    for ns in "$@"; do async_perf_instrument_object "$ns"; done
}

async_perf_report() {
    [ $# -eq 1 ] || return 2
    local file="$1"
    [[ -r "$file" ]] || return 3
    awk -F '\t' '
      { n[$2]++; sum[$2]+=$5; if (min[$2]==0 || $5<min[$2]) min[$2]=$5; if ($5>max[$2]) max[$2]=$5 }
      END {
        printf "%-24s %10s %14s %14s %14s\n", "EVENT", "COUNT", "AVG_US", "MIN_US", "MAX_US";
        for (e in n)
          printf "%-24s %10d %14.3f %14.3f %14.3f\n", e,n[e],sum[e]/n[e]/1000,min[e]/1000,max[e]/1000;
      }' "$file"
}
