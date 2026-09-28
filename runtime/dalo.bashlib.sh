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
#   O<TAB>argc<TAB>...  internal worker output/completion transport
#   Q<TAB>argc<TAB>...  Control ABI v1 request envelope
#   K<TAB>argc<TAB>...  Control ABI v1 ACK response
#   E<TAB>argc<TAB>...  Control ABI v1 ERROR response
# Legacy S/A/C/X frames remain accepted during the ABI-v1 transition.
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
__NS___fifo_field_encode() {
    [ $# -eq 2 ] || return 2
    local __in="$1" __out_name="$2" __encoded
    __encoded="${__in//%/%25}"
    __encoded="${__encoded//$'\t'/%09}"
    __encoded="${__encoded//$'\n'/%0A}"
    __encoded="${__encoded//$'\r'/%0D}"
    printf -v "$__out_name" '%s' "$__encoded"
}

__NS___fifo_field_decode() {
    [ $# -eq 2 ] || return 2
    local __in="$1" __out_name="$2" __decoded
    __decoded="${__in//%0D/$'\r'}"
    __decoded="${__decoded//%0A/$'\n'}"
    __decoded="${__decoded//%09/$'\t'}"
    __decoded="${__decoded//%25/%}"
    printf -v "$__out_name" '%s' "$__decoded"
}

__NS___fifo_frame_encode() {
    local tag="$1"; shift
    local frame encoded arg
    [[ "$tag" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || return 2
    printf -v frame '%s\t%d' "$tag" "$#"
    for arg in "$@"; do
        __NS___fifo_field_encode "$arg" encoded || return
        frame+=$'\t'"$encoded"
    done
    printf '%s' "$frame"
}

__NS___fifo_frame_decode() {
    local frame="$1" out_tag_name="$2" out_argv_name="$3"
    local _tag _argc _field i decoded_field
    local -a fields=() decoded=()
    local -n out_tag_ref="$out_tag_name"
    local -n out_argv_ref="$out_argv_name"

    IFS=$'\t' read -r -a fields <<< "$frame"
    ((${#fields[@]} >= 2)) || return 2
    _tag="${fields[0]}"
    _argc="${fields[1]}"
    [[ "$_tag" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || return 5
    [[ "$_argc" =~ ^[0-9]+$ ]] || return 3
    ((${#fields[@]} == _argc + 2)) || return 4

    for ((i=0; i<_argc; i++)); do
        _field="${fields[i+2]}"
        __NS___fifo_field_decode "$_field" decoded_field || return
        decoded[i]="$decoded_field"
    done
    out_tag_ref="$_tag"
    out_argv_ref=("${decoded[@]}")
}

__NS___fifo_atomic_max() {
    local path="${1:-${__NS___FIFO_PATH:-}}" out="${2:-}" __atomic_value
    if [[ -n "$path" && "$path" != "${__NS___FIFO_PATH:-}" ]]; then
        __atomic_value="$(getconf PIPE_BUF "$path" 2>/dev/null || true)"
        [[ "$__atomic_value" =~ ^[0-9]+$ ]] || __atomic_value=512
    else
        __atomic_value="${__NS___FIFO_ATOMIC_MAX:-}"
        if [ -z "$__atomic_value" ]; then
            __atomic_value="$(getconf PIPE_BUF "$path" 2>/dev/null || true)"
            [[ "$__atomic_value" =~ ^[0-9]+$ ]] || __atomic_value=512
            __NS___FIFO_ATOMIC_MAX="$__atomic_value"
        fi
    fi
    if [ -n "$out" ]; then printf -v "$out" '%s' "$__atomic_value"; else printf '%s' "$__atomic_value"; fi
}

__NS___fifo_send_raw_fd() {
    [ $# -ge 2 ] || return 2
    local fd="$1" frame="$2" path="${3:-${__NS___FIFO_PATH:-}}" frame_bytes atomic_max
    [[ -n "$fd" ]] || return 1
    [[ "$frame" != *$'\n'* && "$frame" != *$'\r'* ]] || return 91
    __NS___fifo_atomic_max "$path" atomic_max || return
    frame_bytes="$(LC_ALL=C printf '%s\n' "$frame" | wc -c)"
    frame_bytes="${frame_bytes//[[:space:]]/}"
    if (( frame_bytes > atomic_max )); then
        printf 'Chyba [__NS__]: FIFO frame je příliš velký (%d > PIPE_BUF %d bytes)\n' \
            "$frame_bytes" "$atomic_max" >&2
        return 90
    fi
    printf '%s\n' "$frame" >&"$fd"
}

__NS___fifo_send_raw() {
    local fd="${__NS___FIFO_FD:-}"; [ -n "$fd" ] || return 1
    __NS___fifo_send_raw_fd "$fd" "$1" "${__NS___FIFO_PATH:-}"
}

__NS___fifo_send() {
    local tag="$1"; shift
    local frame
    frame="$(__NS___fifo_frame_encode "$tag" "$@")" || return
    __NS___fifo_send_raw "$frame"
}

# Control ABI v1 envelope:
#   Q 1 REQUEST_ID SOURCE TARGET REPLY_TARGET OP FLAGS ARGS...
# Targets are logical control endpoints. v1 local routing accepts ns:<namespace>
# (and bare namespaces for compatibility); '-' means no endpoint/fire-and-forget.
__NS___control_next_request_id() {
    [ $# -eq 1 ] || return 2
    local __out_name="$1" __request_value
    ((__NS___CONTROL_REQUEST_SEQ=${__NS___CONTROL_REQUEST_SEQ:-0}+1)) || true
    printf -v __request_value '%s:%s:%s' '__NS__' "${BASHPID:-$$}" "$__NS___CONTROL_REQUEST_SEQ"
    printf -v "$__out_name" '%s' "$__request_value"
}

__NS___control_local_ns_from_target() {
    [ $# -eq 2 ] || return 2
    local target="$1" out="$2" resolved
    case "$target" in
        ns:*) resolved="${target#ns:}" ;;
        -|'') return 1 ;;
        *) resolved="$target" ;; # compatibility with pre-v1 local callers
    esac
    [[ "$resolved" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    printf -v "$out" '%s' "$resolved"
}

__NS___control_send_frame_to() {
    [ $# -ge 2 ] || return 2
    local target="$1" tag="$2"; shift 2
    local target_ns fdvar pathvar fd path frame
    __NS___control_local_ns_from_target "$target" target_ns || return
    fdvar="${target_ns}_FIFO_FD"; pathvar="${target_ns}_FIFO_PATH"
    fd="${!fdvar:-}"; path="${!pathvar:-}"
    [[ -n "$fd" ]] || return 1
    frame="$(__NS___fifo_frame_encode "$tag" "$@")" || return
    __NS___fifo_send_raw_fd "$fd" "$frame" "$path"
}

# Send a request to an arbitrary logical target. SOURCE and REPLY_TARGET are
# explicit so the wire ABI is independent of Bash namespaces and transport.
__NS___control_send_to() {
    [ $# -ge 5 ] || return 2
    local target="$1" source="$2" reply_target="$3" op="$4" flags="$5"; shift 5
    local request_id
    __NS___control_next_request_id request_id || return
    __NS___control_send_frame_to "$target" Q 1 "$request_id" "$source" "$target" "${reply_target:--}" "$op" "$flags" "$@"
}

# Child -> own parent convenience path. The physical FIFO is already known;
# the logical target remains explicit in the envelope.
__NS___control_send() {
    [ $# -ge 3 ] || return 2
    local reply_target="$1" op="$2" flags="$3"; shift 3
    local request_id source='ns:__NS__' target='ns:__NS__'
    __NS___control_next_request_id request_id || return
    __NS___fifo_send Q 1 "$request_id" "$source" "$target" "${reply_target:--}" "$op" "$flags" "$@"
}

__NS___control_send_response() {
    [ $# -ge 3 ] || return 2
    local reply_target="$1" tag="$2" request_id="$3"; shift 3
    [[ "$reply_target" != '-' && -n "$reply_target" ]] || return 0
    __NS___control_send_frame_to "$reply_target" "$tag" "$request_id" "$@"
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
    __NS___control_send - CALL 0 "$func" "$@"
}

# Public OBJECT Control ABI v1 send helpers. These only construct/rout requests;
# the target dispatcher remains the sole owner of canonical OBJECT state.
__NS___object_control_set() {
    [ $# -eq 5 ] || return 2
    local target="$1" source="$2" reply_target="$3" field="$4" value="$5"
    __NS___control_send_to "$target" "$source" "$reply_target" OBJECT_SET 0 "$field" "$value"
}

__NS___object_control_array_push() {
    [ $# -eq 5 ] || return 2
    local target="$1" source="$2" reply_target="$3" field="$4" value="$5"
    __NS___control_send_to "$target" "$source" "$reply_target" OBJECT_ARRAY_PUSH 0 "$field" "$value"
}

__NS___object_control_call() {
    [ $# -ge 4 ] || return 2
    local target="$1" source="$2" reply_target="$3" method="$4"; shift 4
    __NS___control_send_to "$target" "$source" "$reply_target" OBJECT_CALL 0 "$method" "$@"
}

__NS___object_control_exec() {
    [ $# -eq 4 ] || return 2
    local target="$1" source="$2" reply_target="$3" code="$4"
    # Flag bit 0 is the explicit privileged-operation marker in Control ABI v1.
    __NS___control_send_to "$target" "$source" "$reply_target" OBJECT_EXEC 1 "$code"
}

__NS___object_control_replace_worker() {
    [ $# -eq 4 ] || return 2
    local target="$1" source="$2" reply_target="$3" method="$4"
    __NS___control_send_to "$target" "$source" "$reply_target" OBJECT_REPLACE_WORKER 0 "$method"
}

__NS___object_control_reconnect() {
    [ $# -eq 6 ] || return 2
    local target="$1" source="$2" reply_target="$3" src_port="$4" dst_ns="$5" dst_port="$6"
    __NS___control_send_to "$target" "$source" "$reply_target" OBJECT_RECONNECT 0 \
        "$src_port" "$dst_ns" "$dst_port"
}

# FIFO Control lifecycle uses ordered barrier frames in the same FIFO stream.
# Q frames before DRAIN are admitted; Q frames after it receive ERROR 69.
__NS___control_lifecycle_init() { __NS___CONTROL_STATE=ACTIVE; }
__NS___control_begin_drain() {
    [[ "${__NS___CONTROL_STATE:-ACTIVE}" == ACTIVE ]] || return 0
    __NS___fifo_send L DRAIN
}
__NS___control_close() {
    [[ "${__NS___CONTROL_STATE:-ACTIVE}" != CLOSED ]] || return 0
    __NS___fifo_send L CLOSE
}
__NS___control_state() { printf '%s\n' "${__NS___CONTROL_STATE:-ACTIVE}"; }

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
            L)
               ((${#argv[@]} == 1)) || continue
               case "${argv[0]}" in
                   DRAIN) [[ "${__NS___CONTROL_STATE:-ACTIVE}" == ACTIVE ]] && __NS___CONTROL_STATE=DRAINING ;;
                   CLOSE) __NS___CONTROL_STATE=CLOSED ;;
               esac
               ;;
            Q)
               ((${#argv[@]} >= 7)) || continue
               local ctl_ver="${argv[0]}" ctl_req="${argv[1]}" ctl_source="${argv[2]}" ctl_target="${argv[3]}" ctl_reply="${argv[4]}" ctl_op="${argv[5]}" ctl_flags="${argv[6]}" ctl_rc=0
               local -a ctl_args=("${argv[@]:7}")
               [[ "$ctl_ver" == 1 && "$ctl_req" =~ ^[A-Za-z0-9_.:-]+$ ]] || continue
               [[ "$ctl_target" == 'ns:__NS__' || "$ctl_target" == '__NS__' ]] || ctl_rc=68
               if ((ctl_rc == 0)); then
                   case "${__NS___CONTROL_STATE:-ACTIVE}" in
                       DRAINING) ctl_rc=69 ;;
                       CLOSED) ctl_rc=70 ;;
                   esac
                   if ((ctl_rc != 0)); then
                       __NS___control_send_response "$ctl_reply" E "$ctl_req" "$ctl_op" "$ctl_rc" || true
                       continue
                   fi
               fi
               local -a ctl_result=()
               case "$ctl_op" in
                   # Legacy Control ABI v1 primitives. Kept for compatibility;
                   # new orchestration code should use OBJECT_* operations below.
                   SET)
                       ((${#ctl_args[@]} == 2)) || ctl_rc=64
                       ((ctl_rc)) || printf -v "${ctl_args[0]}" '%s' "${ctl_args[1]}" || ctl_rc=$?
                       ;;
                   ARRAY_PUSH)
                       ((${#ctl_args[@]} == 2)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           local -n _ctl_arr_ref="${ctl_args[0]}"
                           _ctl_arr_ref+=("${ctl_args[1]}") || ctl_rc=$?
                           unset -n _ctl_arr_ref
                       fi
                       ;;
                   CALL)
                       ((${#ctl_args[@]} >= 1)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           local ctl_func="${ctl_args[0]}"
                           [[ "$ctl_func" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || ctl_rc=65
                           if ((ctl_rc == 0)); then
                               declare -F "$ctl_func" >/dev/null || ctl_rc=66
                           fi
                           if ((ctl_rc == 0)); then
                               "$ctl_func" "${ctl_args[@]:1}" || ctl_rc=$?
                           fi
                       fi
                       ;;
                   EXEC)
                       ((${#ctl_args[@]} == 1)) || ctl_rc=64
                       ((ctl_rc)) || __NS___apply_code "${ctl_args[0]}" || ctl_rc=$?
                       ;;

                   # OBJECT Control ABI v1. Fields and methods are relative to
                   # the target OBJECT namespace; arbitrary parent-shell names
                   # are deliberately not accepted here.
                   OBJECT_SET)
                       ((${#ctl_args[@]} == 2)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           local ctl_field="${ctl_args[0]}" ctl_var
                           [[ "$ctl_field" =~ ^[A-Z][A-Z0-9_]*$ ]] || ctl_rc=71
                           ctl_var="__NS___${ctl_field}"
                           if ((ctl_rc == 0)); then
                               # OBJECT_SET mutates existing canonical state only.
                               declare -p "$ctl_var" >/dev/null 2>&1 || ctl_rc=71
                           fi
                           if ((ctl_rc == 0)); then
                               printf -v "$ctl_var" '%s' "${ctl_args[1]}" || ctl_rc=$?
                               ctl_result=("$ctl_field" "${ctl_args[1]}")
                           fi
                       fi
                       ;;
                   OBJECT_ARRAY_PUSH)
                       ((${#ctl_args[@]} == 2)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           local ctl_field="${ctl_args[0]}" ctl_var ctl_decl
                           [[ "$ctl_field" =~ ^[A-Z][A-Z0-9_]*$ ]] || ctl_rc=71
                           ctl_var="__NS___${ctl_field}"
                           if ((ctl_rc == 0)); then
                               ctl_decl="$(declare -p "$ctl_var" 2>/dev/null)" || ctl_rc=71
                           fi
                           if ((ctl_rc == 0)); then
                               [[ "$ctl_decl" == 'declare -a '* || "$ctl_decl" == 'declare -A '* ]] || ctl_rc=72
                           fi
                           if ((ctl_rc == 0)); then
                               local -n _ctl_obj_arr_ref="$ctl_var"
                               _ctl_obj_arr_ref+=("${ctl_args[1]}") || ctl_rc=$?
                               ctl_result=("$ctl_field" "${#_ctl_obj_arr_ref[@]}")
                               unset -n _ctl_obj_arr_ref
                           fi
                       fi
                       ;;
                   OBJECT_CALL)
                       ((${#ctl_args[@]} >= 1)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           local ctl_method="${ctl_args[0]}" ctl_func
                           [[ "$ctl_method" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || ctl_rc=71
                           ctl_func="__NS___${ctl_method}"
                           if ((ctl_rc == 0)); then
                               declare -F "$ctl_func" >/dev/null || ctl_rc=66
                           fi
                           if ((ctl_rc == 0)); then
                               # Run in the canonical parent process. Do not use
                               # command substitution here: it would fork away
                               # method-side state mutations. stdout remains the
                               # method's normal data stream; ACK carries status.
                               "$ctl_func" "${ctl_args[@]:1}" || ctl_rc=$?
                               ((ctl_rc == 0)) && ctl_result=("$ctl_method")
                           fi
                       fi
                       ;;
                   SCHED_RESERVE)
                       ((${#ctl_args[@]} == 2)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           declare -F "__NS___scheduler_reserve" >/dev/null 2>&1 || ctl_rc=67
                       fi
                       if ((ctl_rc == 0)); then
                           local sched_rid
                           __NS___scheduler_reserve sched_rid "$ctl_source" \
                               "${ctl_args[0]}" "${ctl_args[1]}" || ctl_rc=$?
                           ((ctl_rc == 0)) && ctl_result=("$sched_rid")
                       fi
                       ;;
                   SCHED_RELEASE)
                       ((${#ctl_args[@]} == 1)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           declare -F "__NS___scheduler_release" >/dev/null 2>&1 || ctl_rc=67
                       fi
                       if ((ctl_rc == 0)); then
                           __NS___scheduler_release "$ctl_source" "${ctl_args[0]}" || ctl_rc=$?
                           ((ctl_rc == 0)) && ctl_result=("${ctl_args[0]}")
                       fi
                       ;;
                   SCHED_QUERY)
                       ((${#ctl_args[@]} == 0)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           declare -F "__NS___scheduler_diagnose" >/dev/null 2>&1 || ctl_rc=67
                       fi
                       if ((ctl_rc == 0)); then
                           __NS___scheduler_diagnose || ctl_rc=$?
                           ((ctl_rc == 0)) && ctl_result=(
                               "${__NS___CPU_TOTAL:-0}" "${__NS___CPU_RESERVED:-0}"
                               "${__NS___MEMORY_TOTAL:-0}" "${__NS___MEMORY_RESERVED:-0}"
                           )
                       fi
                       ;;
                   RECONFIG_PREPARE)
                       ((${#ctl_args[@]} == 0)) || ctl_rc=64
                       ((ctl_rc != 0)) || __NS___reconfiguration_prepare || ctl_rc=$?
                       ;;
                   RECONFIG_COMMIT)
                       ((${#ctl_args[@]} == 0)) || ctl_rc=64
                       ((ctl_rc != 0)) || __NS___reconfiguration_commit_prepared || ctl_rc=$?
                       ;;
                   RECONFIG_ABORT)
                       ((${#ctl_args[@]} == 0)) || ctl_rc=64
                       ((ctl_rc != 0)) || __NS___reconfiguration_abort_prepared || ctl_rc=$?
                       ;;
                   RECONFIG_RECONNECT_PREPARED)
                       ((${#ctl_args[@]} == 3)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           __NS___reconfiguration_reconnect_prepared \
                               "${ctl_args[0]}" "${ctl_args[1]}" "${ctl_args[2]}" || ctl_rc=$?
                       fi
                       ;;
                   OBJECT_RECONNECT)
                       ((${#ctl_args[@]} == 3)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           __NS___reconfiguration_reconnect \
                               "${ctl_args[0]}" "${ctl_args[1]}" "${ctl_args[2]}" || ctl_rc=$?
                           ((ctl_rc == 0)) && ctl_result=(
                               "${ctl_args[0]}" "${ctl_args[1]}" "${ctl_args[2]}"
                               "${__NS___RECONFIG_GENERATION:-0}"
                           )
                       fi
                       ;;
                   OBJECT_REPLACE_WORKER)
                       ((${#ctl_args[@]} == 1)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           __NS___reconfiguration_replace_worker "${ctl_args[0]}" || ctl_rc=$?
                           ((ctl_rc == 0)) && ctl_result=(
                               "${ctl_args[0]}"
                               "${__NS___TARGET_WORKER_FUNC:-}"
                               "${__NS___RECONFIG_GENERATION:-0}"
                           )
                       fi
                       ;;
                   OBJECT_EXEC)
                       ((${#ctl_args[@]} == 1)) || ctl_rc=64
                       if ((ctl_rc == 0)); then
                           [[ "$ctl_flags" =~ ^[0-9]+$ ]] || ctl_rc=73
                           ((ctl_rc)) || (( (10#$ctl_flags & 1) != 0 )) || ctl_rc=72
                       fi
                       ((ctl_rc)) || __NS___apply_code "${ctl_args[0]}" || ctl_rc=$?
                       ((ctl_rc == 0)) && ctl_result=("EXECUTED")
                       ;;
                   *) ctl_rc=67 ;;
               esac
               if ((ctl_rc == 0)); then
                   __NS___control_send_response "$ctl_reply" K "$ctl_req" "$ctl_op" "${ctl_result[@]}" || true
               else
                   __NS___control_send_response "$ctl_reply" E "$ctl_req" "$ctl_op" "$ctl_rc" || true
               fi
               ;;
            K|E)
               if declare -f "__NS___on_control_response" >/dev/null 2>&1; then
                   "__NS___on_control_response" "$tag" "${argv[@]}"
               elif declare -f "__NS___on_fifo_message" >/dev/null 2>&1; then
                   "__NS___on_fifo_message" "$tag" "${argv[@]}"
               fi
               ;;
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

    # Completion has two valid wire forms:
    #   non-task worker: slot, pid, rc
    #   task attempt:    slot, pid, rc, task_id, attempt
    # Never serialize absent optional identity as empty trailing FIFO fields.
    if [ -n "\$task_id" ]; then
        [ -n "\$attempt" ] || {
            printf 'Chyba [${ns}]: task completion bez attempt: slot=%s pid=%s task=%s\n' \
                "\$slot_id" "\$BASHPID" "\$task_id" >&2
            exit 76
        }
        ${ns}_fifo_call_parent "${ns}_mark_job_completed" \
            "\$slot_id" "\$BASHPID" "\$exit_code" "\$task_id" "\$attempt"
    else
        ${ns}_fifo_call_parent "${ns}_mark_job_completed" \
            "\$slot_id" "\$BASHPID" "\$exit_code"
    fi
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
    ${ns}_SCHEDULER_NS=
    ${ns}_SCHED_CPU_PER_JOB=0
    ${ns}_SCHED_MEMORY_PER_JOB=0
    declare -gA ${ns}_SLOT_RESERVATION=()

    declare -gA ${ns}_INPUT_DATA_VECTOR=()
    declare -gA ${ns}_OUTPUT_DATA_VECTOR=()
    declare -gA ${ns}_EXIT_CODE_VECTOR=()
    declare -gA ${ns}_JOB_STATUS_VECTOR=()
    declare -gA ${ns}_WORKER_TMP_DIR=()
    declare -gA ${ns}_WORKER_PIDS=()
    declare -gA ${ns}_COMPLETED_PIDS=()
    declare -gA ${ns}_COMPLETION_EXIT_CODES=()
    declare -gA ${ns}_REAPED_PIDS=()
    declare -gA ${ns}_REAP_EXIT_CODES=()

    # Persistent task storage. No task API or argv storage yet (STEP 1 only).
    declare -gA ${ns}_TASK_STATUS=()
    declare -gA ${ns}_TASK_FUNC=()
    declare -gA ${ns}_TASK_INPUT_PORT=()
    declare -gA ${ns}_TASK_ATTEMPT=()
    declare -gA ${ns}_TASK_RETRIES=()
    declare -gA ${ns}_TASK_CREATED=()
    declare -gA ${ns}_TASK_STARTED=()
    declare -gA ${ns}_TASK_FINISHED=()
    declare -gA ${ns}_DIAG=()
    declare -gA ${ns}_RESOURCE=()
    declare -gA ${ns}_BACKEND_SCOPE=()
    declare -gA ${ns}_BACKEND_CAPABILITIES=()
    declare -gA ${ns}_PEER_BACKEND=()
    declare -gA ${ns}_PEER_PROTOCOL=()
    declare -gA ${ns}_PEER_RESOURCE=()

    # Execution binding: ephemeral slot/attempt -> persistent task identity.
    declare -gA ${ns}_SLOT_TASK_ID=()
    declare -gA ${ns}_SLOT_ATTEMPT=()

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
    [ \$# -ge 2 ] || return 2
    local input_port="\$1" worker_func="\$2"
    shift 2
    [[ "\$input_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$ ]] || return 2

    local task_id="\${${ns}_NEXT_TASK_ID}"
    ${ns}_NEXT_TASK_ID=\$((task_id + 1))

    ${ns}_TASK_STATUS[\$task_id]="QUEUED"
    ${ns}_TASK_FUNC[\$task_id]="\$worker_func"
    ${ns}_TASK_INPUT_PORT[\$task_id]="\$input_port"
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
            [ \$# -ge 2 ] || {
                echo "Chyba: ${ns}_task submit vyžaduje INPUT_PORT a worker funkci." >&2
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
    local input_port="\${${ns}_TASK_INPUT_PORT[\$task_id]:-}"
    [[ "\$input_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$ ]] || return 2
    local -a argv=()
    ${ns}_task_argv_get "\$task_id" argv || return 1
    local attempt=\$(( \${${ns}_TASK_ATTEMPT[\$task_id]:-0} + 1 ))

    # Canonical identity is published before the child can report completion.
    ${ns}_TASK_ATTEMPT["\$task_id"]="\$attempt"
    ${ns}_task_transition "\$task_id" QUEUED RUNNING || return 1
    printf -v "${ns}_TASK_STARTED[\$task_id]" '%(%s)T' -1
    unset "${ns}_TASK_FINISHED[\$task_id]" 2>/dev/null || true

    if ${ns}_job_pool_submit_task_port "\$task_id" "\$attempt" "\$input_port" "\$func" "" "\${argv[@]}"; then
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

    ${ns}_scheduler_release_slot "\$slot_id" || {
        printf 'Chyba [${ns}]: scheduler reservation release selhal: slot=%s\n' "\$slot_id" >&2
        return 1
    }
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

    ${ns}_scheduler_release_slot "\$slot_id" || {
        printf 'Chyba [${ns}]: scheduler reservation release selhal: slot=%s\n' "\$slot_id" >&2
        return 1
    }
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
    [ \$# -eq 3 ] || [ \$# -eq 5 ] || return 64
    local slot_id="\$1" worker_pid="\$2" exit_code="\$3"
    local task_id="\${4:-}" attempt="\${5:-}"
    if [ \$# -eq 5 ]; then
        [ -n "\$task_id" ] && [ -n "\$attempt" ] || return 64
    fi
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

define_scheduler_binding_api() {
    local ns="$1" body
    body=$(cat <<EOF
${ns}_scheduler_bind() {
    [ \$# -eq 3 ] || return 64
    local scheduler_ns="\$1" cpu="\$2" memory="\$3"
    [[ "\$scheduler_ns" =~ ^[A-Za-z_][A-Za-z0-9_]*\$ ]] || return 71
    [[ "\$cpu" =~ ^[0-9]+\$ && "\$memory" =~ ^[0-9]+\$ ]] || return 64
    declare -F "\${scheduler_ns}_scheduler_reserve" >/dev/null 2>&1 || return 66
    declare -F "\${scheduler_ns}_scheduler_release" >/dev/null 2>&1 || return 66
    ${ns}_SCHEDULER_NS="\$scheduler_ns"
    ${ns}_SCHED_CPU_PER_JOB="\$cpu"
    ${ns}_SCHED_MEMORY_PER_JOB="\$memory"
}
${ns}_scheduler_unbind() {
    [ \$# -eq 0 ] || return 64
    (( \${#${ns}_SLOT_RESERVATION[@]} == 0 )) || return 74
    ${ns}_SCHEDULER_NS=
    ${ns}_SCHED_CPU_PER_JOB=0
    ${ns}_SCHED_MEMORY_PER_JOB=0
}
${ns}_scheduler_reserve_slot() {
    [ \$# -eq 2 ] || return 64
    local slot_id="\$1" outvar="\$2" scheduler_ns="\${${ns}_SCHEDULER_NS:-}"
    local slot_reservation_id=
    [ -n "\$scheduler_ns" ] || { printf -v "\$outvar" '%s' ''; return 0; }
    "\${scheduler_ns}_scheduler_reserve" slot_reservation_id "ns:${ns}" \
        "\${${ns}_SCHED_CPU_PER_JOB:-0}" "\${${ns}_SCHED_MEMORY_PER_JOB:-0}" || return
    ${ns}_SLOT_RESERVATION["\$slot_id"]="\$slot_reservation_id"
    printf -v "\$outvar" '%s' "\$slot_reservation_id"
}
${ns}_scheduler_release_slot() {
    [ \$# -eq 1 ] || return 64
    local slot_id="\$1" rid="\${${ns}_SLOT_RESERVATION[\$slot_id]:-}" scheduler_ns="\${${ns}_SCHEDULER_NS:-}"
    [ -n "\$rid" ] || return 0
    [ -n "\$scheduler_ns" ] || return 84
    "\${scheduler_ns}_scheduler_release" "ns:${ns}" "\$rid" || return
    unset '${ns}_SLOT_RESERVATION['"\$slot_id"']'
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
    [ \$# -ge 5 ] || return 2
    local task_id="\$1" attempt="\$2" cmd_func="\$3" cleanup_func="\${4:-}" input_port="\$5"
    shift 5
    [[ "\$input_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$ ]] || return 2

    # Generic reconfiguration admission barrier. Check both before and after
    # capacity waiting so a safepoint cannot admit a late worker.
    ${ns}_reconfiguration_admission_open || return 75

    while [ "\${${ns}_PENDING_JOBS}" -ge "\${${ns}_MAX_JOBS}" ]; do
        ${ns}_reap_one
    done

    ${ns}_reconfiguration_admission_open || return 75

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

    local scheduler_reservation=
    ${ns}_scheduler_reserve_slot "\$slot_id" scheduler_reservation || return
    if ! ${ns}_reconfiguration_admission_open; then
        ${ns}_scheduler_release_slot "\$slot_id" || true
        return 75
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

        # Capture cleanup identity NOW. A trap executes after this function's
        # locals may no longer be safely addressable; a deferred attempt value (and
        # peers) can therefore collapse to empty and corrupt the completion
        # frame. %q produces one shell-safe word per captured value.
        local _trap_cmd _q_worker_dir _q_slot_id _q_cleanup_func _q_task_id _q_attempt
        printf -v _q_worker_dir '%q' "\$worker_dir"
        printf -v _q_slot_id '%q' "\$slot_id"
        printf -v _q_cleanup_func '%q' "\$cleanup_func"
        printf -v _q_task_id '%q' "\$task_id"
        printf -v _q_attempt '%q' "\$attempt"
        printf -v _trap_cmd '%s %s %s %s %s %s' \
            '${ns}_worker_cleanup_wrapper' \
            "\$_q_worker_dir" "\$_q_slot_id" "\$_q_cleanup_func" "\$_q_task_id" "\$_q_attempt"
        trap "\$_trap_cmd" EXIT INT TERM

        "\$cmd_func" "\$worker_dir" "\$slot_id" "\$@"
    ) &

    ${ns}_WORKER_PIDS["\$slot_id"]=\$!
}


${ns}_job_pool_submit_port() {
    local input_port="\$1" cmd_func="\$2" cleanup_func="\${3:-}"
    shift 3 2>/dev/null || shift \$#
    ${ns}_job_pool_submit_core "" "" "\$cmd_func" "\$cleanup_func" "\$input_port" "\$@"
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
    local slot key port worker_dir pid ec have_input have_output
    local -a input_members output_members
    for (( slot=1; slot<=\${${ns}_MAX_JOBS}; slot++ )); do
        input_members=()
        output_members=()
        have_input=0
        have_output=0

        for key in "\${!${ns}_INPUT_DATA_VECTOR[@]}"; do
            [[ "\$key" == "\$slot|"* ]] || continue
            port="\${key#"\$slot|"}"
            input_members+=("\$port=\${${ns}_INPUT_DATA_VECTOR[\$key]}")
            have_input=1
        done
        (( have_input )) || continue

        for key in "\${!${ns}_OUTPUT_DATA_VECTOR[@]}"; do
            [[ "\$key" == "\$slot|"* ]] || continue
            port="\${key#"\$slot|"}"
            output_members+=("\$port=\${${ns}_OUTPUT_DATA_VECTOR[\$key]}")
            have_output=1
        done

        worker_dir="\${${ns}_WORKER_TMP_DIR[\$slot]:-}"
        pid="\${${ns}_WORKER_PIDS[\$slot]:-none}"
        echo "Worker Slot [\$slot] (PID \$pid):"

        if (( ! have_output )); then
            echo "  └─ [FAIL] Output vector undefined."
            "\$validate_func" "\$slot" "UNFINISHED" \
                "\${input_members[*]}" "" "\$worker_dir"
        else
            ec="\${${ns}_EXIT_CODE_VECTOR[\$slot]:-?}"
            if "\$validate_func" "\$slot" "COMPLETED" \
                "\${input_members[*]}" "\${output_members[*]}" "\$worker_dir"; then
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
    local slot_id="\$1" exit_code="\$2"
    [ "\$exit_code" -eq 0 ] || return 0
    local output="\${${ns}_OUTPUT_DATA_VECTOR["\$slot_id|out"]:-}"
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
# 7b. OBJECT RECONFIGURATION / QUIESCENCE ABI v1
# ============================================================================
# This is the generic safe-mutation barrier for every OBJECT.
#
# DATA/work admission and CONTROL admission are deliberately separate:
#   RECONFIG_ADMISSION=0 stops new worker submissions.
#   CONTROL_STATE governs FIFO Q-frame admission/lifecycle.
#
# A reconfiguration request itself is handled synchronously by the canonical
# parent dispatcher, so queued CONTROL frames cannot execute concurrently with
# the mutation. DATA/work must still be explicitly closed and drained.

define_reconfiguration_api() {
    local ns="$1" body
    body="$(cat <<'RECONFIG_EOF'
__NS___reconfiguration_init() {
    __NS___RECONFIG_ADMISSION=1
    __NS___RECONFIG_STATE=ACTIVE
    __NS___RECONFIG_GENERATION=${__NS___RECONFIG_GENERATION:-0}
}

__NS___reconfiguration_admission_open() {
    [[ "${__NS___RECONFIG_ADMISSION:-1}" == 1 ]]
}

__NS___reconfiguration_begin() {
    [[ "${__NS___RECONFIG_STATE:-ACTIVE}" == ACTIVE ]] || return 74
    __NS___RECONFIG_ADMISSION=0
    __NS___RECONFIG_STATE=QUIESCING
}

__NS___reconfiguration_quiesce() {
    case "${__NS___RECONFIG_STATE:-ACTIVE}" in
        ACTIVE) __NS___reconfiguration_begin || return ;;
        QUIESCING) ;;
        QUIESCED) return 0 ;;
        *) return 74 ;;
    esac

    __NS___job_pool_wait || {
        __NS___RECONFIG_STATE=FAILED
        return 1
    }
    __NS___drain_fifo || {
        __NS___RECONFIG_STATE=FAILED
        return 1
    }

    (( ${__NS___PENDING_JOBS:-0} == 0 )) || {
        __NS___RECONFIG_STATE=FAILED
        return 1
    }
    (( ${#__NS___WORKER_PIDS[@]} == 0 )) || {
        __NS___RECONFIG_STATE=FAILED
        return 1
    }
    __NS___diagnose || {
        __NS___RECONFIG_STATE=FAILED
        return 1
    }

    __NS___RECONFIG_STATE=QUIESCED
}

__NS___reconfiguration_resume() {
    [[ "${__NS___RECONFIG_STATE:-ACTIVE}" == QUIESCED ||
       "${__NS___RECONFIG_STATE:-ACTIVE}" == FAILED ]] || return 74
    __NS___RECONFIG_GENERATION=$(( ${__NS___RECONFIG_GENERATION:-0} + 1 ))
    __NS___RECONFIG_ADMISSION=1
    __NS___RECONFIG_STATE=ACTIVE
}

__NS___reconfiguration_replace_worker() {
    [ $# -eq 1 ] || return 64
    local method="$1" candidate old_worker old_generation rc
    [[ "$method" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71
    candidate="__NS___${method}"
    declare -F "$candidate" >/dev/null 2>&1 || return 66

    old_worker="${__NS___TARGET_WORKER_FUNC:-}"
    old_generation="${__NS___RECONFIG_GENERATION:-0}"

    __NS___reconfiguration_begin || return
    if ! __NS___reconfiguration_quiesce; then
        rc=$?
        __NS___TARGET_WORKER_FUNC="$old_worker"
        __NS___RECONFIG_GENERATION="$old_generation"
        __NS___reconfiguration_abort || true
        return "$rc"
    fi

    __NS___TARGET_WORKER_FUNC="$candidate"
    if [[ "${__NS___TARGET_WORKER_FUNC:-}" != "$candidate" ]] ||
       ! declare -F "${__NS___TARGET_WORKER_FUNC}" >/dev/null 2>&1; then
        __NS___TARGET_WORKER_FUNC="$old_worker"
        __NS___RECONFIG_GENERATION="$old_generation"
        __NS___reconfiguration_abort || true
        return 77
    fi

    if ! __NS___reconfiguration_resume; then
        rc=$?
        __NS___TARGET_WORKER_FUNC="$old_worker"
        __NS___RECONFIG_GENERATION="$old_generation"
        __NS___RECONFIG_ADMISSION=1
        __NS___RECONFIG_STATE=ACTIVE
        return "$rc"
    fi
}

__NS___reconfiguration_prepare() {
    [ $# -eq 0 ] || return 64
    __NS___reconfiguration_begin || return
    if ! __NS___reconfiguration_quiesce; then
        local rc=$?
        __NS___reconfiguration_abort || true
        return "$rc"
    fi
}

__NS___reconfiguration_commit_prepared() {
    [ $# -eq 0 ] || return 64
    [[ "${__NS___RECONFIG_STATE:-ACTIVE}" == QUIESCED ]] || return 74
    __NS___reconfiguration_resume
}

__NS___reconfiguration_abort_prepared() {
    [ $# -eq 0 ] || return 64
    case "${__NS___RECONFIG_STATE:-ACTIVE}" in
        QUIESCING|QUIESCED|FAILED) __NS___reconfiguration_abort ;;
        ACTIVE) return 0 ;;
        *) return 74 ;;
    esac
}

__NS___reconfiguration_reconnect_prepared() {
    [ $# -eq 3 ] || return 64
    local src_port="$1" dst_ns="$2" dst_port="$3"
    [[ "${__NS___RECONFIG_STATE:-ACTIVE}" == QUIESCED ]] || return 74
    [[ "$src_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 71
    [[ "$dst_ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71
    [[ "$dst_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 71
    declare -F "${dst_ns}_summon_worker" >/dev/null 2>&1 || return 66
    [[ -v "__NS___ROUTE_DST_NS[$src_port]" && -v "__NS___ROUTE_DST_PORT[$src_port]" ]] || return 71
    __NS___ROUTE_DST_NS["$src_port"]="$dst_ns"
    __NS___ROUTE_DST_PORT["$src_port"]="$dst_port"
}

__NS___reconfiguration_reconnect() {
    [ $# -eq 3 ] || return 64
    local src_port="$1" dst_ns="$2" dst_port="$3"
    local old_dst old_port old_generation rc

    [[ "$src_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 71
    [[ "$dst_ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71
    [[ "$dst_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 71
    declare -F "${dst_ns}_summon_worker" >/dev/null 2>&1 || return 66
    [[ -v "__NS___ROUTE_DST_NS[$src_port]" && -v "__NS___ROUTE_DST_PORT[$src_port]" ]] || return 71

    old_dst="${__NS___ROUTE_DST_NS[$src_port]}"
    old_port="${__NS___ROUTE_DST_PORT[$src_port]}"
    old_generation="${__NS___RECONFIG_GENERATION:-0}"

    __NS___reconfiguration_begin || return
    if ! __NS___reconfiguration_quiesce; then
        rc=$?
        __NS___RECONFIG_GENERATION="$old_generation"
        __NS___reconfiguration_abort || true
        return "$rc"
    fi

    __NS___ROUTE_DST_NS["$src_port"]="$dst_ns"
    __NS___ROUTE_DST_PORT["$src_port"]="$dst_port"

    if [[ "${__NS___ROUTE_DST_NS[$src_port]:-}" != "$dst_ns" ||
          "${__NS___ROUTE_DST_PORT[$src_port]:-}" != "$dst_port" ]] ||
       ! declare -F "${dst_ns}_summon_worker" >/dev/null 2>&1; then
        __NS___ROUTE_DST_NS["$src_port"]="$old_dst"
        __NS___ROUTE_DST_PORT["$src_port"]="$old_port"
        __NS___RECONFIG_GENERATION="$old_generation"
        __NS___reconfiguration_abort || true
        return 77
    fi

    if ! __NS___reconfiguration_resume; then
        rc=$?
        __NS___ROUTE_DST_NS["$src_port"]="$old_dst"
        __NS___ROUTE_DST_PORT["$src_port"]="$old_port"
        __NS___RECONFIG_GENERATION="$old_generation"
        __NS___RECONFIG_ADMISSION=1
        __NS___RECONFIG_STATE=ACTIVE
        return "$rc"
    fi
}

__NS___reconfiguration_abort() {
    # v1 abort is valid only before structural state has been committed.
    # Mutation-specific rollback is layered above this primitive.
    case "${__NS___RECONFIG_STATE:-ACTIVE}" in
        QUIESCING|QUIESCED|FAILED) ;;
        *) return 74 ;;
    esac
    __NS___RECONFIG_ADMISSION=1
    __NS___RECONFIG_STATE=ACTIVE
}
RECONFIG_EOF
)"
    body="${body//__NS__/$ns}"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}



# ============================================================================
# PROJECT ORCHESTRATOR FOUNDATION
# ============================================================================
# The ORCHESTRATOR is a PROJECT-level CONTROL endpoint. It owns only control
# intent/request state; canonical OBJECT state remains owned by each OBJECT's
# FIFO dispatcher. It therefore never reads another OBJECT's FIFO.
define_orchestrator_api() {
    [ $# -eq 1 ] || return 2
    local ns="$1" body
    body="$(cat <<'ORCH_EOF'
__NS___orchestrator_init() {
    __NS___ORCHESTRATOR_STATE=ACTIVE
    declare -gA __NS___ORCH_PENDING=()
    declare -gA __NS___ORCH_STATUS=()
    declare -gA __NS___ORCH_OPERATION=()
    declare -gA __NS___ORCH_RESULT=()
    declare -gA __NS___ORCH_ERROR=()
}

__NS___orchestrator_issue() {
    [ $# -ge 4 ] || return 64
    [[ "${__NS___ORCHESTRATOR_STATE:-ACTIVE}" == ACTIVE ]] || return 74
    local outvar="$1" target="$2" op="$3" flags="$4"; shift 4
    [[ "$outvar" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 64
    local request_id source='ns:__NS__' reply_target='ns:__NS__'
    __NS___control_next_request_id request_id || return
    __NS___ORCH_PENDING["$request_id"]=1
    __NS___ORCH_STATUS["$request_id"]=PENDING
    __NS___ORCH_OPERATION["$request_id"]="$op"
    __NS___ORCH_RESULT["$request_id"]=
    __NS___ORCH_ERROR["$request_id"]=
    if ! __NS___control_send_frame_to "$target" Q 1 "$request_id" \
            "$source" "$target" "$reply_target" "$op" "$flags" "$@"; then
        local rc=$?
        unset '__NS___ORCH_PENDING['"$request_id"']'
        __NS___ORCH_STATUS["$request_id"]=SEND_ERROR
        __NS___ORCH_ERROR["$request_id"]="$rc"
        return "$rc"
    fi
    printf -v "$outvar" '%s' "$request_id"
}

__NS___on_control_response() {
    [ $# -ge 3 ] || return 64
    local tag="$1" request_id="$2" op="$3"; shift 3
    [[ "$tag" == K || "$tag" == E ]] || return 67
    [[ -v "__NS___ORCH_PENDING[$request_id]" ]] || return 76
    [[ "${__NS___ORCH_OPERATION[$request_id]:-}" == "$op" ]] || return 78

    if [[ "$tag" == K ]]; then
        __NS___ORCH_STATUS["$request_id"]=ACK
        __NS___ORCH_RESULT["$request_id"]="$*"
        __NS___ORCH_ERROR["$request_id"]=
    else
        __NS___ORCH_STATUS["$request_id"]=ERROR
        __NS___ORCH_RESULT["$request_id"]=
        __NS___ORCH_ERROR["$request_id"]="${1:-1}"
    fi
    unset '__NS___ORCH_PENDING['"$request_id"']'
}

__NS___orchestrator_wait() {
    [ $# -eq 1 ] || return 64
    local request_id="$1" spins=0
    [[ -v "__NS___ORCH_STATUS[$request_id]" ]] || return 76
    while [[ "${__NS___ORCH_STATUS[$request_id]}" == PENDING ]]; do
        __NS___drain_fifo || return
        [[ "${__NS___ORCH_STATUS[$request_id]}" != PENDING ]] && break
        ((spins+=1))
        ((spins < 10000)) || return 79
        sleep 0.001
    done
    [[ "${__NS___ORCH_STATUS[$request_id]}" == ACK ]]
}

__NS___orchestrator_set() {
    [ $# -eq 4 ] || return 64
    __NS___orchestrator_issue "$1" "$2" OBJECT_SET 0 "$3" "$4"
}
__NS___orchestrator_array_push() {
    [ $# -eq 4 ] || return 64
    __NS___orchestrator_issue "$1" "$2" OBJECT_ARRAY_PUSH 0 "$3" "$4"
}
__NS___orchestrator_call() {
    [ $# -ge 3 ] || return 64
    local outvar="$1" target="$2" method="$3"; shift 3
    __NS___orchestrator_issue "$outvar" "$target" OBJECT_CALL 0 "$method" "$@"
}
__NS___orchestrator_exec() {
    [ $# -eq 3 ] || return 64
    __NS___orchestrator_issue "$1" "$2" OBJECT_EXEC 1 "$3"
}
__NS___orchestrator_replace_worker() {
    [ $# -eq 3 ] || return 64
    __NS___orchestrator_issue "$1" "$2" OBJECT_REPLACE_WORKER 0 "$3"
}
__NS___orchestrator_reconnect() {
    [ $# -eq 5 ] || return 64
    __NS___orchestrator_issue "$1" "$2" OBJECT_RECONNECT 0 "$3" "$4" "$5"
}


# Multi-OBJECT topology transaction v1.
# Spec format per reconnect: TARGET SRC_PORT DST_NS DST_PORT.
__NS___orchestrator_tx_reconnect() {
    [ $# -ge 5 ] || return 64
    local outvar="$1"; shift
    (( $# % 4 == 0 )) || return 64
    [[ "$outvar" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 64

    local txid="tx:${BASHPID}:${__NS___CONTROL_REQUEST_SEQ:-0}"
    local -a specs=("$@") participants=() prepared=() snapshots=()
    local i target src_port dst_ns dst_port req rc=0 p seen

    # Build unique source-object participant set and snapshot routes before closing admission.
    for ((i=0;i<${#specs[@]};i+=4)); do
        target="${specs[i]}"; src_port="${specs[i+1]}"
        dst_ns="${specs[i+2]}"; dst_port="${specs[i+3]}"
        local tns="${target#ns:}"
        [[ "$tns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71
        declare -F "${tns}_summon_worker" >/dev/null 2>&1 || return 66
        [[ -v "${tns}_ROUTE_DST_NS[$src_port]" && -v "${tns}_ROUTE_DST_PORT[$src_port]" ]] || return 71
        declare -F "${dst_ns}_summon_worker" >/dev/null 2>&1 || return 66
        local -n _rns="${tns}_ROUTE_DST_NS" _rport="${tns}_ROUTE_DST_PORT"
        snapshots+=("$tns" "$src_port" "${_rns[$src_port]}" "${_rport[$src_port]}")
        seen=0; for p in "${participants[@]}"; do [[ "$p" == "$target" ]] && seen=1; done
        ((seen)) || participants+=("$target")
    done

    # Phase 1: PREPARE every participant.
    for target in "${participants[@]}"; do
        __NS___orchestrator_issue req "$target" RECONFIG_PREPARE 0 || { rc=$?; break; }
        # Object dispatcher and reply endpoint share this shell in v1 tests/runtime.
        local tns="${target#ns:}"
        "${tns}_drain_fifo" || true
        __NS___drain_fifo || true
        if ! __NS___orchestrator_wait "$req"; then rc="${__NS___ORCH_ERROR[$req]:-1}"; break; fi
        prepared+=("$target")
    done

    if ((rc != 0)); then
        for target in "${prepared[@]}"; do
            __NS___orchestrator_issue req "$target" RECONFIG_ABORT 0 || true
            local ans="${target#ns:}"; "${ans}_drain_fifo" 2>/dev/null || true
            __NS___drain_fifo || true
        done
        printf -v "$outvar" '%s' "$txid"
        return "$rc"
    fi

    # Phase 2: apply mutations while every participant remains QUIESCED.
    for ((i=0;i<${#specs[@]};i+=4)); do
        target="${specs[i]}"; src_port="${specs[i+1]}"; dst_ns="${specs[i+2]}"; dst_port="${specs[i+3]}"
        __NS___orchestrator_issue req "$target" RECONFIG_RECONNECT_PREPARED 0 "$src_port" "$dst_ns" "$dst_port" || { rc=$?; break; }
        local pns="${target#ns:}"; "${pns}_drain_fifo" || true; __NS___drain_fifo || true
        if ! __NS___orchestrator_wait "$req"; then rc="${__NS___ORCH_ERROR[$req]:-1}"; break; fi
    done

    # Roll back route snapshots before reopening admission if mutation failed.
    if ((rc != 0)); then
        for ((i=0;i<${#snapshots[@]};i+=4)); do
            local sns="${snapshots[i]}" sport="${snapshots[i+1]}"
            local -n _rns="${sns}_ROUTE_DST_NS" _rport="${sns}_ROUTE_DST_PORT"
            _rns["$sport"]="${snapshots[i+2]}"
            _rport["$sport"]="${snapshots[i+3]}"
        done
        for target in "${prepared[@]}"; do
            __NS___orchestrator_issue req "$target" RECONFIG_ABORT 0 || true
            local ans="${target#ns:}"; "${ans}_drain_fifo" 2>/dev/null || true; __NS___drain_fifo || true
        done
        printf -v "$outvar" '%s' "$txid"
        return "$rc"
    fi

    # Phase 3: commit/reopen all participants.
    for target in "${prepared[@]}"; do
        __NS___orchestrator_issue req "$target" RECONFIG_COMMIT 0 || { rc=$?; break; }
        local pns="${target#ns:}"; "${pns}_drain_fifo" || true; __NS___drain_fifo || true
        if ! __NS___orchestrator_wait "$req"; then rc="${__NS___ORCH_ERROR[$req]:-1}"; break; fi
    done
    printf -v "$outvar" '%s' "$txid"
    return "$rc"
}
ORCH_EOF
)"
    body="${body//__NS__/$ns}"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

orchestrator_constructor() {
    [ $# -eq 1 ] || return 2
    local ns="$1"
    [[ "$ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    define_fifo_api "$ns"
    define_orchestrator_api "$ns"
    # Reuse the proven FIFO/job-pool initialization solely to provision the
    # endpoint FIFO and common control state. The ORCHESTRATOR never submits jobs.
    define_job_pool_init "$ns"
    "${ns}_job_pool_init"
    "${ns}_control_lifecycle_init"
    "${ns}_orchestrator_init"
}


# ============================================================================
# PER-MACHINE SCHEDULER FOUNDATION
# ============================================================================
# One SCHEDULER owns one MACHINE resource ledger. It is a CONTROL endpoint,
# not an OBJECT-state owner. v1 accounts abstract CPU slots and memory bytes.
define_scheduler_api() {
    [ $# -eq 1 ] || return 2
    local ns="$1" body
    body="$(cat <<'SCHED_EOF'
__NS___scheduler_init() {
    [ $# -eq 2 ] || return 64
    local cpu_total="$1" memory_total="$2"
    [[ "$cpu_total" =~ ^[0-9]+$ && "$memory_total" =~ ^[0-9]+$ ]] || return 64
    __NS___SCHEDULER_STATE=ACTIVE
    __NS___CPU_TOTAL="$cpu_total"
    __NS___CPU_RESERVED=0
    __NS___MEMORY_TOTAL="$memory_total"
    __NS___MEMORY_RESERVED=0
    __NS___RESERVATION_SEQ=0
    declare -gA __NS___RES_CPU=()
    declare -gA __NS___RES_MEMORY=()
    declare -gA __NS___RES_OWNER=()
}

__NS___scheduler_available_cpu() {
    printf '%s\n' "$(( __NS___CPU_TOTAL - __NS___CPU_RESERVED ))"
}
__NS___scheduler_available_memory() {
    printf '%s\n' "$(( __NS___MEMORY_TOTAL - __NS___MEMORY_RESERVED ))"
}

# Read-only placement/admission probe.  Unlike reserve+release this does not
# mutate reservation sequence, ledgers, or accounting state.
__NS___scheduler_can_fit() {
    [ $# -eq 2 ] || return 64
    local cpu="$1" memory="$2"
    [[ "$cpu" =~ ^[0-9]+$ && "$memory" =~ ^[0-9]+$ ]] || return 64
    [[ "${__NS___SCHEDULER_STATE:-ACTIVE}" == ACTIVE ]] || return 74
    (( cpu <= __NS___CPU_TOTAL - __NS___CPU_RESERVED )) || return 80
    (( memory <= __NS___MEMORY_TOTAL - __NS___MEMORY_RESERVED )) || return 81
}

__NS___scheduler_reserve() {
    [ $# -eq 4 ] || return 64
    local outvar="$1" owner="$2" cpu="$3" memory="$4"
    [[ "$outvar" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 64
    [[ "$owner" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 71
    [[ "$cpu" =~ ^[0-9]+$ && "$memory" =~ ^[0-9]+$ ]] || return 64
    [[ "${__NS___SCHEDULER_STATE:-ACTIVE}" == ACTIVE ]] || return 74
    (( cpu <= __NS___CPU_TOTAL - __NS___CPU_RESERVED )) || return 80
    (( memory <= __NS___MEMORY_TOTAL - __NS___MEMORY_RESERVED )) || return 81

    __NS___RESERVATION_SEQ=$(( __NS___RESERVATION_SEQ + 1 ))
    local _sched_generated_reservation_id="res:__NS__:${BASHPID}:${__NS___RESERVATION_SEQ}"
    __NS___RES_CPU["$_sched_generated_reservation_id"]="$cpu"
    __NS___RES_MEMORY["$_sched_generated_reservation_id"]="$memory"
    __NS___RES_OWNER["$_sched_generated_reservation_id"]="$owner"
    __NS___CPU_RESERVED=$(( __NS___CPU_RESERVED + cpu ))
    __NS___MEMORY_RESERVED=$(( __NS___MEMORY_RESERVED + memory ))
    printf -v "$outvar" '%s' "$_sched_generated_reservation_id"
}

__NS___scheduler_release() {
    [ $# -eq 2 ] || return 64
    local owner="$1" rid="$2"
    [[ -v "__NS___RES_OWNER[$rid]" ]] || return 82
    [[ "${__NS___RES_OWNER[$rid]}" == "$owner" ]] || return 83
    local cpu="${__NS___RES_CPU[$rid]}" memory="${__NS___RES_MEMORY[$rid]}"
    __NS___CPU_RESERVED=$(( __NS___CPU_RESERVED - cpu ))
    __NS___MEMORY_RESERVED=$(( __NS___MEMORY_RESERVED - memory ))
    unset '__NS___RES_CPU['"$rid"']' '__NS___RES_MEMORY['"$rid"']' '__NS___RES_OWNER['"$rid"']'
}

__NS___scheduler_diagnose() {
    (( __NS___CPU_RESERVED >= 0 && __NS___CPU_RESERVED <= __NS___CPU_TOTAL )) || return 84
    (( __NS___MEMORY_RESERVED >= 0 && __NS___MEMORY_RESERVED <= __NS___MEMORY_TOTAL )) || return 84
    local rid cpu_sum=0 memory_sum=0
    for rid in "${!__NS___RES_OWNER[@]}"; do
        [[ -v "__NS___RES_CPU[$rid]" && -v "__NS___RES_MEMORY[$rid]" ]] || return 84
        cpu_sum=$(( cpu_sum + __NS___RES_CPU[$rid] ))
        memory_sum=$(( memory_sum + __NS___RES_MEMORY[$rid] ))
    done
    (( cpu_sum == __NS___CPU_RESERVED && memory_sum == __NS___MEMORY_RESERVED ))
}
SCHED_EOF
)"
    body="${body//__NS__/$ns}"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
}

scheduler_constructor() {
    [ $# -eq 3 ] || return 2
    local ns="$1" cpu_total="$2" memory_total="$3"
    [[ "$ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    define_fifo_api "$ns"
    define_scheduler_api "$ns"
    define_job_pool_init "$ns"
    "${ns}_job_pool_init"
    "${ns}_control_lifecycle_init"
    "${ns}_scheduler_init" "$cpu_total" "$memory_total"
}

# ============================================================================
# 8. CONSTRUCTORS
# ============================================================================

asyncobj_constructor() {
    local ns="$1"

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
    define_reconfiguration_api      "$ns"
    define_scheduler_binding_api    "$ns"

    "${ns}_job_pool_init"
    "${ns}_reconfiguration_init"
    "${ns}_backend_register" fifo local send receive
    "${ns}_backend_register" tcp universal connect send receive listen
    "${ns}_resource_refresh_workers"
}

# Origin: vždy má downstream (nebo je sám o sobě jednorázový stage).
async_pipeline_origin_constructor() {
    local ns="$1" ns_out="${2:-}"
    asyncobj_constructor "$ns"
    if [[ -n "$ns_out" ]]; then
        define_vector_forward_hook "$ns" ORIGIN out "$ns_out" in
    fi
}

# Legacy convenience constructor. Its scalar downstream argument is translated
# once into the canonical vector route out -> downstream.in.
async_pipeline_pipe_constructor() {
    local ns="$1" ns_out="${2:-}"
    if [ -z "$ns_out" ]; then
        echo "Chyba: async_pipeline_pipe_constructor '$ns' bez \$2 = endpoint." >&2
        echo "       Použij: async_pipeline_endpoint_constructor $ns <out_fd> [buffer_file] [threshold]" >&2
        return 1
    fi
    asyncobj_constructor "$ns"
    define_vector_forward_hook "$ns" PIPE out "$ns_out" in
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
    local target_worker_var="${ns}_TARGET_WORKER_FUNC"
    if [[ -z "${!target_worker_var:-}" ]]; then
        printf -v "$target_worker_var" '%s' "${ns}_default_endpoint_worker"
    fi
}


# ============================================================================
# 8b. MIGRATION RESOURCE ADMISSION ABI v1
# ============================================================================
# This layer coordinates source quiescence with destination MACHINE capacity.
# It deliberately does not perform transport or reconstruction.
#
# Transaction states:
#   PREPARING -> PREPARED -> COMMITTED
#                         \-> ABORTED
#
# PREPARE:
#   1. close source admission + reach quiescence
#   2. reserve destination scheduler capacity
# COMMIT:
#   retain the destination reservation as the migrated OBJECT's machine lease,
#   while reopening the source only when explicitly requested by the caller.
# ABORT:
#   release destination capacity and reopen the source.
#
# The caller owns cutover ordering between PREPARE and COMMIT.

__dalo_migration_resource_init() {
    declare -p DALO_MIGRATION_TX_STATE >/dev/null 2>&1 || declare -gA DALO_MIGRATION_TX_STATE=()
    declare -p DALO_MIGRATION_TX_SOURCE >/dev/null 2>&1 || declare -gA DALO_MIGRATION_TX_SOURCE=()
    declare -p DALO_MIGRATION_TX_DEST_SCHED >/dev/null 2>&1 || declare -gA DALO_MIGRATION_TX_DEST_SCHED=()
    declare -p DALO_MIGRATION_TX_RESERVATION >/dev/null 2>&1 || declare -gA DALO_MIGRATION_TX_RESERVATION=()
    declare -p DALO_MIGRATION_TX_CPU >/dev/null 2>&1 || declare -gA DALO_MIGRATION_TX_CPU=()
    declare -p DALO_MIGRATION_TX_MEMORY >/dev/null 2>&1 || declare -gA DALO_MIGRATION_TX_MEMORY=()
    declare -p DALO_MIGRATION_TX_LEASE_OWNER >/dev/null 2>&1 || declare -gA DALO_MIGRATION_TX_LEASE_OWNER=()
    : "${DALO_MIGRATION_TX_SEQ:=0}"
}

migration_resource_prepare() {
    [ $# -eq 5 ] || return 64
    local outvar="$1" source_ns="$2" dest_sched="$3" cpu="$4" memory="$5"
    [[ "$outvar" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 64
    [[ "$source_ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71
    [[ "$dest_sched" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71
    [[ "$cpu" =~ ^[0-9]+$ && "$memory" =~ ^[0-9]+$ ]] || return 64
    declare -F "${source_ns}_reconfiguration_prepare" >/dev/null 2>&1 || return 66
    declare -F "${source_ns}_reconfiguration_abort_prepared" >/dev/null 2>&1 || return 66
    declare -F "${dest_sched}_scheduler_reserve" >/dev/null 2>&1 || return 66
    declare -F "${dest_sched}_scheduler_release" >/dev/null 2>&1 || return 66

    __dalo_migration_resource_init
    DALO_MIGRATION_TX_SEQ=$(( DALO_MIGRATION_TX_SEQ + 1 ))
    local migration_tx_id="mig:${BASHPID}:${DALO_MIGRATION_TX_SEQ}"
    local lease_owner="migration:${migration_tx_id}"
    local _migration_reserved_id=

    DALO_MIGRATION_TX_STATE["$migration_tx_id"]=PREPARING
    DALO_MIGRATION_TX_SOURCE["$migration_tx_id"]="$source_ns"
    DALO_MIGRATION_TX_DEST_SCHED["$migration_tx_id"]="$dest_sched"
    DALO_MIGRATION_TX_CPU["$migration_tx_id"]="$cpu"
    DALO_MIGRATION_TX_MEMORY["$migration_tx_id"]="$memory"
    DALO_MIGRATION_TX_LEASE_OWNER["$migration_tx_id"]="$lease_owner"

    local prepare_rc=0 reserve_rc=0
    "${source_ns}_reconfiguration_prepare" || prepare_rc=$?
    if (( prepare_rc != 0 )); then
        DALO_MIGRATION_TX_STATE["$migration_tx_id"]=ABORTED
        return "$prepare_rc"
    fi

    "${dest_sched}_scheduler_reserve" _migration_reserved_id "$lease_owner" "$cpu" "$memory" || reserve_rc=$?
    if (( reserve_rc != 0 )); then
        local rollback_rc=0
        "${source_ns}_reconfiguration_abort_prepared" || rollback_rc=$?
        DALO_MIGRATION_TX_STATE["$migration_tx_id"]=ABORTED
        (( rollback_rc == 0 )) || return "$rollback_rc"
        return "$reserve_rc"
    fi

    DALO_MIGRATION_TX_RESERVATION["$migration_tx_id"]="$_migration_reserved_id"
    DALO_MIGRATION_TX_STATE["$migration_tx_id"]=PREPARED
    printf -v "$outvar" '%s' "$migration_tx_id"
}

migration_resource_abort() {
    [ $# -eq 1 ] || return 64
    local tx_id="$1"
    __dalo_migration_resource_init
    [[ "${DALO_MIGRATION_TX_STATE[$tx_id]:-}" == PREPARED ]] || return 74
    local source_ns="${DALO_MIGRATION_TX_SOURCE[$tx_id]}"
    local dest_sched="${DALO_MIGRATION_TX_DEST_SCHED[$tx_id]}"
    local reservation_id="${DALO_MIGRATION_TX_RESERVATION[$tx_id]}"
    local lease_owner="${DALO_MIGRATION_TX_LEASE_OWNER[$tx_id]}"
    local release_rc=0 reopen_rc=0

    "${dest_sched}_scheduler_release" "$lease_owner" "$reservation_id" || release_rc=$?
    "${source_ns}_reconfiguration_abort_prepared" || reopen_rc=$?

    # Do not claim ABORTED unless both rollback legs completed.
    (( release_rc == 0 )) || return "$release_rc"
    (( reopen_rc == 0 )) || return "$reopen_rc"
    DALO_MIGRATION_TX_STATE["$tx_id"]=ABORTED
}

migration_resource_commit() {
    [ $# -eq 2 ] || return 64
    local tx_id="$1" destination_ns="$2"
    __dalo_migration_resource_init
    [[ "${DALO_MIGRATION_TX_STATE[$tx_id]:-}" == PREPARED ]] || return 74
    [[ "$destination_ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71

    # Transfer reservation ownership from the temporary migration transaction
    # to the reconstructed destination OBJECT without changing totals.
    local dest_sched="${DALO_MIGRATION_TX_DEST_SCHED[$tx_id]}"
    local reservation_id="${DALO_MIGRATION_TX_RESERVATION[$tx_id]}"
    local -n owners="${dest_sched}_RES_OWNER"
    [[ -v "owners[$reservation_id]" ]] || return 82
    [[ "${owners[$reservation_id]}" == "${DALO_MIGRATION_TX_LEASE_OWNER[$tx_id]}" ]] || return 83
    owners["$reservation_id"]="ns:${destination_ns}"

    printf -v "${destination_ns}_MACHINE_RESERVATION" '%s' "$reservation_id"
    printf -v "${destination_ns}_MACHINE_SCHEDULER" '%s' "$dest_sched"
    printf -v "${destination_ns}_MACHINE_CPU" '%s' "${DALO_MIGRATION_TX_CPU[$tx_id]}"
    printf -v "${destination_ns}_MACHINE_MEMORY" '%s' "${DALO_MIGRATION_TX_MEMORY[$tx_id]}"
    DALO_MIGRATION_TX_STATE["$tx_id"]=COMMITTED
}

migration_resource_release_object() {
    [ $# -eq 1 ] || return 64
    local ns="$1"
    local sched_var="${ns}_MACHINE_SCHEDULER"
    local rid_var="${ns}_MACHINE_RESERVATION"
    local scheduler_ns="${!sched_var:-}" reservation_id="${!rid_var:-}"
    [ -n "$scheduler_ns" ] && [ -n "$reservation_id" ] || return 0
    "${scheduler_ns}_scheduler_release" "ns:${ns}" "$reservation_id" || return
    unset "${ns}_MACHINE_RESERVATION" "${ns}_MACHINE_SCHEDULER" \
          "${ns}_MACHINE_CPU" "${ns}_MACHINE_MEMORY"
}

migration_resource_source_retire() {
    [ $# -eq 1 ] || return 64
    local tx_id="$1"
    __dalo_migration_resource_init
    [[ "${DALO_MIGRATION_TX_STATE[$tx_id]:-}" == COMMITTED ]] || return 74
    local source_ns="${DALO_MIGRATION_TX_SOURCE[$tx_id]}"
    # Source stays closed after successful cutover. This marks ownership transfer;
    # destruction/registry cleanup remains the existing migration layer's job.
    local source_state_var="${source_ns}_RECONFIG_STATE"
    [[ "${!source_state_var:-}" == QUIESCED ]] || return 74
    printf -v "${source_ns}_MIGRATION_RESOURCE_STATE" '%s' RETIRED
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
    if ! __NS___reconfiguration_quiesce; then
        __NS___MIGRATION_STATE=FAILED
        return 1
    fi
    __NS___MIGRATION_STATE=QUIESCED
}
__NS___migration_resume() {
    __NS___reconfiguration_resume || return
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
    migration_policy_init_object "$ns" || return

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
    migration_policy_bind_resource_container "$ns" || { close_resource "$ns" || true; return 1; }
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

__migration_import_unsafe() {
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
    local body src dst_ns dst_port route_key

    # Canonical mutable routing state. Keys are source output ports and values
    # are "destination-namespace<TAB>destination-input-port". v1 deliberately
    # keeps one destination per source port, matching the current generated
    # case-router semantics.
    eval "declare -g -A ${ns}_ROUTE_DST_NS=() ${ns}_ROUTE_DST_PORT=()"
    while (( $# )); do
        src="$1"; dst_ns="$2"; dst_port="$3"; shift 3
        [[ "$src" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 2
        [[ "$dst_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 2
        declare -F "${dst_ns}_summon_worker" >/dev/null 2>&1 || return 66
        printf -v "${ns}_ROUTE_DST_NS[$src]" '%s' "$dst_ns"
        printf -v "${ns}_ROUTE_DST_PORT[$src]" '%s' "$dst_port"
    done

    body="$(cat <<'ROUTE_EOF'
__NS___forward_output_vector() {
    local slot_id="$1" key port prefix="$1|" dst_ns dst_port payload
    for key in "${!__NS___OUTPUT_DATA_VECTOR[@]}"; do
        [[ "$key" == "$prefix"* ]] || continue
        port="${key#"$prefix"}"

        # Use namerefs for associative routing tables. This avoids reparsing
        # dynamic subscripts under nounset/arithmetic contexts.
        local -n __route_ns_ref=__NS___ROUTE_DST_NS
        local -n __route_port_ref=__NS___ROUTE_DST_PORT
        dst_ns="${__route_ns_ref["$port"]-}"
        dst_port="${__route_port_ref["$port"]-}"
        payload="${__NS___OUTPUT_DATA_VECTOR["$key"]-}"

        if [[ -z "$dst_ns" || -z "$dst_port" ]] ||
           ! declare -F "${dst_ns}_summon_worker" >/dev/null 2>&1; then
            printf 'Chyba [__NS__/__TYPE__]: output port bez validni route: %s\n' "$port" >&2
            return 70
        fi
        "${dst_ns}_summon_worker" "$dst_port" "$payload"
    done
}
__NS___on_job_completed() {
    local slot_id="$1" exit_code="$2"
    (( exit_code == 0 )) || return 0
    __NS___forward_output_vector "$slot_id"
}
ROUTE_EOF
)"
    body="${body//__NS__/$ns}"
    body="${body//__TYPE__/$obj_type}"
    __asyncobj_eval_body "$ns" "${FUNCNAME[0]}" "$body"
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

    # Compile all DATA forwarding from the canonical EDGE graph. T, Y, PIPE,
    # COLUMN and future object types share the same vector routing mechanism.
    local route_args dst_ns
    for obj in "${objs[@]}"; do
        ns="${smap[$obj]}"; type="${types[$obj]}"
        route_args=()
        for e in "${edges[@]}"; do
            IFS=$'\t' read -r s sp d dp <<<"$e"
            [[ "$s" == "$obj" ]] || continue
            dst_ns="${smap[$d]:-}"
            [[ -n "$dst_ns" ]] || return 33
            route_args+=("$sp" "$dst_ns" "$dp")
        done
        define_vector_forward_hook "$ns" "$type" "${route_args[@]}" || return
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

__migration_import_with_worker_unsafe() {
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



# Transactional import guard.  Historical import code predates rollback-safe
# reconstruction and may return after allocating a fresh OBJECT.  Snapshot the
# namespace registry and discard every namespace created by a failed import.
__migration_capture_namespaces() {
    [ $# -eq 1 ] || return 64
    local outvar="$1" ns
    local -n _migration_ns_snapshot="$outvar"
    _migration_ns_snapshot=()
    __asyncobj_ensure_global_registries || return
    for ns in "${!ALL_NS[@]}"; do
        _migration_ns_snapshot["$ns"]=1
    done
}

__migration_cleanup_new_namespaces() {
    [ $# -eq 1 ] || return 64
    local before_name="$1" ns cleanup_rc=0
    local -n _migration_before="$before_name"
    __asyncobj_ensure_global_registries || return
    local -a created=()
    for ns in "${!ALL_NS[@]}"; do
        [[ -v "_migration_before[$ns]" ]] || created+=("$ns")
    done
    for ns in "${created[@]}"; do
        migration_discard_imported_object "$ns" || cleanup_rc=$?
    done
    (( cleanup_rc == 0 ))
}

migration_import() {
    [ $# -ge 2 ] && [ $# -le 3 ] || return 2
    local bundle="$1" out_ns="$2" out_obj_id="${3:-}"
    local -A _migration_before_ns=()
    local rc=0
    __migration_capture_namespaces _migration_before_ns || return
    __migration_import_unsafe "$bundle" "$out_ns" "$out_obj_id" || rc=$?
    if (( rc != 0 )); then
        __migration_cleanup_new_namespaces _migration_before_ns || true
        return "$rc"
    fi
}

migration_import_with_worker() {
    [ $# -eq 3 ] || return 2
    local bundle_dir="$1" out_ns="$2" out_obj_id="$3"
    local -A _migration_before_ns=()
    local rc=0
    __migration_capture_namespaces _migration_before_ns || return
    __migration_import_with_worker_unsafe "$bundle_dir" "$out_ns" "$out_obj_id" || rc=$?
    if (( rc != 0 )); then
        __migration_cleanup_new_namespaces _migration_before_ns || true
        return "$rc"
    fi
}


# ============================================================================
# 13b. RESOURCE-AWARE MIGRATION CUTOVER ABI v1
# ============================================================================
# Reuses the reconfiguration/resource PREPARE barrier.  Snapshot/export below
# therefore MUST NOT invoke migration_quiesce a second time.

migration_discard_imported_object() {
    [ $# -eq 1 ] || return 64
    local ns="$1"
    [[ "$ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71
    __asyncobj_ensure_global_registries || return

    local obj_id_var="${ns}_OBJECT_ID" uuid_var="${ns}_OBJECT_UUID"
    local fifo_fd_var="${ns}_FIFO_FD" fifo_path_var="${ns}_FIFO_PATH"
    local obj_id="${!obj_id_var:-}" uuid="${!uuid_var:-}"
    local fifo_fd="${!fifo_fd_var:-}" fifo_path="${!fifo_path_var:-}"
    local fd fn var

    # An imported destination must be idle; this primitive is rollback-only.
    local pending_var="${ns}_PENDING_JOBS"
    (( ${!pending_var:-0} == 0 )) || return 74

    # Drop a committed destination machine lease if one was already attached.
    migration_resource_release_object "$ns" || return

    if [[ -n "$fifo_fd" ]]; then
        fifo_close "$fifo_fd"
        unregister_fd "$fifo_fd" || true
    fi
    [[ -z "$fifo_path" ]] || rm -f -- "$fifo_path"
    [[ -z "$obj_id" ]] || unregister_fifo "$obj_id" || true

    if [[ -n "$uuid" && -v "UUID_TO_OBJ_ID[$uuid]" && "${UUID_TO_OBJ_ID[$uuid]}" == "$obj_id" ]]; then
        unset 'UUID_TO_OBJ_ID['"$uuid"']'
    fi
    if [[ -n "$obj_id" && -v "OBJ_ID_TO_NS[$obj_id]" && "${OBJ_ID_TO_NS[$obj_id]}" == "$ns" ]]; then
        unset 'OBJ_ID_TO_NS['"$obj_id"']'
    fi
    if [[ -v "ALL_NS[$ns]" ]]; then
        unset 'ALL_NS['"$ns"']'
    fi

    # Remove namespace-local generated functions and variables only after all
    # values needed for registry cleanup have been captured.
    while IFS= read -r fn; do
        [[ "$fn" == "${ns}_"* ]] || continue
        unset -f "$fn"
    done < <(declare -F | awk '{print $3}')
    while IFS= read -r var; do
        [[ "$var" == "${ns}_"* ]] || continue
        unset "$var"
    done < <(compgen -A variable "${ns}_")
}

migration_export_prepared_with_worker() {
    [ $# -eq 3 ] || return 64
    local as="$1" obj="$2" bundle_dir="$3"
    local -n smap="${as}_DECL_SLOT" wa="${as}_WORKER_ARTIFACT" wh="${as}_WORKER_SHA256"
    [[ -v "smap[$obj]" ]] || return 3
    local ns="${smap[$obj]}" artifact="${wa[$obj]:-}" expected="${wh[$obj]:-}" actual
    local state_var="${ns}_RECONFIG_STATE" pending_var="${ns}_PENDING_JOBS"
    [[ "${!state_var:-}" == QUIESCED ]] || return 74
    (( ${!pending_var:-0} == 0 )) || return 74
    [[ -n "$artifact" && -r "$artifact" && -n "$expected" ]] || return 4
    mkdir -p "$bundle_dir" || return

    # Existing snapshot ABI requires MIGRATION_STATE=QUIESCED.  Mirror the
    # already-proven reconfiguration safepoint; do not run a second quiesce.
    printf -v "${ns}_MIGRATION_STATE" '%s' QUIESCED
    printf -v "${ns}_MIGRATION_ADMISSION" '%s' 0
    "${ns}_snapshot_write" "$bundle_dir/raw.snapshot" || return

    local uuid_var="${ns}_OBJECT_UUID" type_var="${ns}_OBJECT_TYPE" id_var="${ns}_OBJECT_ID"
    local snapshot_payload="$bundle_dir/object.snapshot.snapshot"
    cp "$bundle_dir/raw.snapshot" "$snapshot_payload" || return
    {
        printf 'ASYNC_OBJECT_MIGRATION\t1\n'
        printf 'UUID\t%q\n' "${!uuid_var}"
        printf 'SOURCE_OBJ_ID\t%q\n' "${!id_var}"
        printf 'OBJECT_TYPE\t%q\n' BLANK
        printf 'SNAPSHOT\t%q\n' "$snapshot_payload"
        printf 'END\n'
    } > "$bundle_dir/object.snapshot" || return

    printf '%s\n' "${!type_var:-BLANK}" > "$bundle_dir/object.type" || return
    cp "$artifact" "$bundle_dir/worker.bash" || return
    actual="$(__dalo_sha256_file "$bundle_dir/worker.bash")" || return
    [[ "$actual" == "$expected" ]] || return 5
    printf '%s\n' "$expected" > "$bundle_dir/worker.sha256"
}

migration_cutover_with_worker() {
    [ $# -eq 8 ] || return 64
    local out_ns="$1" out_obj_id="$2" as="$3" obj="$4" dest_sched="$5" cpu="$6" memory="$7" bundle_dir="$8"
    [[ "$out_ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$out_obj_id" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 64
    local -n smap="${as}_DECL_SLOT"
    [[ -v "smap[$obj]" ]] || return 3
    local source_ns="${smap[$obj]}"
    local source_uuid_var="${source_ns}_OBJECT_UUID"
    local source_uuid="${!source_uuid_var:-}"
    [[ -n "$source_uuid" ]] || return 71

    local migration_tx= destination_ns= destination_obj_id=
    local rc=0 committed=0 migration_plan=

    # Policy gate MUST precede quiesce and destination reservation.
    migration_policy_plan migration_plan "$source_ns" || return $?
    migration_resource_prepare migration_tx "$source_ns" "$dest_sched" "$cpu" "$memory" || return

    migration_export_prepared_with_worker "$as" "$obj" "$bundle_dir" || rc=$?

    # Test/debug fault boundary. This is intentionally inert unless explicitly
    # requested by the caller environment.
    if (( rc == 0 )) && [[ "${DALO_MIGRATION_FAULT_POINT:-}" == AFTER_EXPORT ]]; then
        rc=90
    fi

    # Local/same-shell vertical slice: stable UUID is globally unique. Hand its
    # registry entry from source to destination only for the reconstruction
    # window. The source object itself remains intact until final retirement.
    local source_obj_id_var="${source_ns}_OBJECT_ID"
    local source_obj_id="${!source_obj_id_var:-}"
    local uuid_handoff=0
    if (( rc == 0 )); then
        if [[ -v "UUID_TO_OBJ_ID[$source_uuid]" && "${UUID_TO_OBJ_ID[$source_uuid]}" == "$source_obj_id" ]]; then
            unset 'UUID_TO_OBJ_ID['"$source_uuid"']'
            uuid_handoff=1
        else
            rc=86
        fi
    fi

    if (( rc == 0 )); then
        migration_import_with_worker "$bundle_dir" destination_ns destination_obj_id || rc=$?
    fi

    if (( rc == 0 )) && [[ "${DALO_MIGRATION_FAULT_POINT:-}" == AFTER_IMPORT ]]; then
        rc=91
    fi

    if (( rc == 0 )); then
        local destination_uuid_var="${destination_ns}_OBJECT_UUID"
        [[ "${!destination_uuid_var:-}" == "$source_uuid" ]] || rc=85
    fi

    if (( rc == 0 )); then
        migration_resource_commit "$migration_tx" "$destination_ns" || rc=$?
        (( rc == 0 )) && committed=1
    fi

    if (( rc == 0 )); then
        migration_resource_source_retire "$migration_tx" || rc=$?
    fi

    if (( rc != 0 )); then
        if [[ -n "$destination_ns" ]]; then
            migration_discard_imported_object "$destination_ns" || true
        fi
        if (( uuid_handoff == 1 )) && [[ ! -v "UUID_TO_OBJ_ID[$source_uuid]" ]]; then
            UUID_TO_OBJ_ID["$source_uuid"]="$source_obj_id"
        fi
        if (( committed == 0 )); then
            migration_resource_abort "$migration_tx" || true
        else
            # Commit transferred the reservation to destination.  If retirement
            # then fails, discard released that lease; reopen the source.
            "${source_ns}_reconfiguration_abort_prepared" || true
            DALO_MIGRATION_TX_STATE["$migration_tx"]=ABORTED
        fi
        return "$rc"
    fi

    declare -g "$out_ns" "$out_obj_id"
    printf -v "$out_ns" '%s' "$destination_ns"
    printf -v "$out_obj_id" '%s' "$destination_obj_id"
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
    local pathvar="${target}_FIFO_PATH" path
    fd="${!fdvar:-}"
    path="${!pathvar:-}"
    [[ -n "$fd" ]] || return 1
    __NS___fifo_send_raw_fd "$fd" "$raw" "$path"
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
__asyncmachine_link() {
    [ $# -eq 4 ] || return 2
    local project="$1" project_file="$2" out="$3" project_hash="$4"
    local library_source="${BASH_SOURCE[0]}"
    local helper_source
    helper_source="$(cd -- "$(dirname -- "$library_source")" && pwd)/helpers.bashlib.sh"
    [[ -r "$library_source" && -r "$helper_source" ]] || return 3

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
        # A MACHINE is standalone: embed helpers first, then the runtime body.
        # Remove only the runtime's library-relative helpers bootstrap because
        # helpers are already physically linked above.
        tail -n +2 "$helper_source"
        awk '
          /^__dalo_library_dir=.*BASH_SOURCE/ { skip=1; next }
          skip && /^source .*helpers\.bashlib\.sh/ { next }
          skip && /^unset __dalo_library_dir/ { skip=0; next }
          { print }
        ' "$library_source" | tail -n +2
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

    # MACHINE / PROJECT Command-Line ABI v1. DALO runtime options and PROJECT
    # arguments are parsed by the MACHINE owner; workers never inherit MACHINE $@.
    local -n porder="${project}_PARAM_ORDER" ptypes="${project}_PARAM_TYPE"
    local -n pdefaults="${project}_PARAM_DEFAULT" prequired="${project}_PARAM_REQUIRED"
    {
        printf '\nASYNC_MACHINE_PROJECT_ARGC=0\n'
        printf 'declare -a ASYNC_MACHINE_PROJECT_ARGV=()\n'
        printf 'declare -A ASYNC_MACHINE_PROJECT_ARG_SEEN=()\n'
        printf 'async_machine_parse_args() {\n'
        printf '  ASYNC_MACHINE_PROJECT_ARGC=0; ASYNC_MACHINE_PROJECT_ARGV=(); ASYNC_MACHINE_PROJECT_ARG_SEEN=()\n'
        printf '  local arg name value type required default found\n'
        printf '  while (($#)); do\n'
        printf '    arg="$1"; shift\n'
        printf '    [[ "$arg" != -- ]] || { ASYNC_MACHINE_PROJECT_ARGV=("$@"); ASYNC_MACHINE_PROJECT_ARGC=$#; break; }\n'
        printf '    [[ "$arg" == --* ]] || { printf "Unexpected MACHINE argument: %%s\\n" "$arg" >&2; return 64; }\n'
        printf '    if [[ "$arg" == *=* ]]; then name="${arg%%=*}"; name="${name#--}"; value="${arg#*=}"; else name="${arg#--}"; (($#)) || { printf "Missing value for --%%s\\n" "$name" >&2; return 64; }; value="$1"; shift; fi\n'
        printf '    found=0\n'
    } >>"$out"
    local pname
    for pname in "${porder[@]}"; do
        printf '    if [[ "$name" == %q ]]; then type=%q; found=1; fi\n' "$pname" "${ptypes[$pname]}" >>"$out"
    done
    {
        printf '    ((found)) || { printf "Unknown PROJECT argument: --%%s\\n" "$name" >&2; return 64; }\n'
        printf '    [[ ! -v ASYNC_MACHINE_PROJECT_ARG_SEEN[$name] ]] || { printf "Duplicate PROJECT argument: --%%s\\n" "$name" >&2; return 64; }; ASYNC_MACHINE_PROJECT_ARG_SEEN[$name]=1\n'
        printf '    case "$type" in int) [[ "$value" =~ ^-?[0-9]+$ ]] || return 65;; uint) [[ "$value" =~ ^[0-9]+$ ]] || return 65;; bool) [[ "$value" == 0 || "$value" == 1 ]] || return 65;; string) :;; esac\n'
        printf '    printf -v "ASYNC_MACHINE_PARAM_${name}" "%%s" "$value"; export "ASYNC_MACHINE_PARAM_${name}"\n'
        printf '  done\n'
    } >>"$out"
    for pname in "${porder[@]}"; do
        printf '  name=%q; type=%q; required=%q; default=%q\n' "$pname" "${ptypes[$pname]}" "${prequired[$pname]}" "${pdefaults[$pname]:-}" >>"$out"
        printf '  if [[ ! -v ASYNC_MACHINE_PARAM_${name} ]]; then if [[ "$required" == 1 ]]; then printf "Missing required PROJECT argument: --%%s\\n" "$name" >&2; return 64; else printf -v "ASYNC_MACHINE_PARAM_${name}" "%%s" "$default"; export "ASYNC_MACHINE_PARAM_${name}"; fi; fi\n' >>"$out"
    done
    printf '}\n' >>"$out"

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
                # DATA parent->child uses private anonymous pipes. The per-OBJECT
                # FIFO remains exclusively child->parent/control transport.
                printf '%s_PERSIST_PIDS=()\n' "$ns"
                printf '%s_PERSIST_DATA_FDS=()\n' "$ns"
                printf '%s_PERSIST_SEQ=0\n' "$ns"
                printf '%s_PERSIST_NEXT=0\n' "$ns"
                printf '%s_PERSIST_PENDING=0\n' "$ns"
                printf '%s_persistent_start() {\n' "$ns"
                printf '  local i fd pid\n'
                printf '  for ((i=0;i<%s_MAX_JOBS;i++)); do\n' "$ns"
                printf '    exec {fd}> >(%s_persistent_child_loop) || return\n' "$ns"
                printf '    pid=$!\n'
                printf '    %s_PERSIST_DATA_FDS[i]="$fd"\n' "$ns"
                printf '    %s_PERSIST_PIDS[i]="$pid"\n' "$ns"
                printf '  done\n'
                printf '}\n'
                printf '%s_persistent_child_loop() {\n' "$ns"
                printf '  local seq input_port payload rc\n'
                printf '  while IFS=$'"'"'\t'"'"' read -r seq input_port payload; do\n'
                printf '    [[ "$seq" == STOP ]] && break\n'
                printf '    [[ "$seq" =~ ^[0-9]+$ && -n "$input_port" ]] || continue\n'
                printf '    input_port="$(printf "%%b" "$input_port")"\n'
                printf '    payload="$(printf "%%b" "$payload")"\n'
                printf '    rc=0\n'
                printf '    %s_worker "${TMPDIR:-/tmp}" "$seq" "$payload" || rc=$?\n' "$ns"
                printf '    %s_fifo_call_parent %s_persistent_completed "$seq" "$rc"\n' "$ns" "$ns"
                printf '  done\n'
                printf '}\n'
                printf '%s_summon_worker() {\n' "$ns"
                printf '  [[ $# -ge 1 ]] || return 2\n'
                printf '  local input_port="$1"; shift\n'
                printf '  [[ "$input_port" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 2\n'
                printf '  %s_PERSIST_SEQ=$((%s_PERSIST_SEQ+1))\n' "$ns" "$ns"
                printf '  local seq="$%s_PERSIST_SEQ" payload="$*" key idx fd\n' "$ns"
                printf '  %s_INPUT_DATA_VECTOR["$seq|$input_port"]="$payload"\n' "$ns"
                printf '  for key in "${!%s_OUTPUT_DATA_VECTOR[@]}"; do [[ "$key" == "$seq|"* ]] && unset '\''%s_OUTPUT_DATA_VECTOR['\''"$key"'\'']'\''; done\n' "$ns" "$ns"
                printf '  input_port="${input_port//\\/\\\\}"; input_port="${input_port//$'"'"'\t'"'"'/\\t}"; input_port="${input_port//$'"'"'\n'"'"'/\\n}"\n'
                printf '  payload="${payload//\\/\\\\}"; payload="${payload//$'"'"'\t'"'"'/\\t}"; payload="${payload//$'"'"'\n'"'"'/\\n}"\n'
                printf '  idx="$%s_PERSIST_NEXT"\n' "$ns"
                printf '  %s_PERSIST_NEXT=$(((idx + 1) %% %s_MAX_JOBS))\n' "$ns" "$ns"
                printf '  fd="${%s_PERSIST_DATA_FDS[idx]}"\n' "$ns"
                printf '  %s_PERSIST_PENDING=$((%s_PERSIST_PENDING+1))\n' "$ns" "$ns"
                printf '  printf "%%s\\t%%s\\t%%s\\n" "$seq" "$input_port" "$payload" >&"$fd"\n'
                printf '}\n'
                printf '%s_persistent_stop() {\n' "$ns"
                printf '  local i fd pid\n'
                printf '  for ((i=0;i<${#%s_PERSIST_DATA_FDS[@]};i++)); do fd="${%s_PERSIST_DATA_FDS[i]}"; printf "STOP\\t_\\t_\\n" >&"$fd" 2>/dev/null || true; done\n' "$ns" "$ns"
                printf '  for ((i=0;i<${#%s_PERSIST_DATA_FDS[@]};i++)); do fd="${%s_PERSIST_DATA_FDS[i]}"; eval "exec ${fd}>&-"; done\n' "$ns" "$ns"
                printf '  for pid in "${%s_PERSIST_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done\n' "$ns"
                printf '  %s_PERSIST_PIDS=(); %s_PERSIST_DATA_FDS=()\n' "$ns" "$ns"
                printf '}\n'
                printf '%s_persistent_completed() {\n' "$ns"
                printf '  local seq="$1" rc="$2"\n'
                printf '  %s_on_job_completed "$seq" "$rc"\n' "$ns"
                printf '  ((%s_PERSIST_PENDING > 0)) && %s_PERSIST_PENDING=$((%s_PERSIST_PENDING-1))\n' "$ns" "$ns" "$ns"
                printf '}\n'
                printf '%s_job_pool_wait() {\n' "$ns"
                printf '  while ((%s_PERSIST_PENDING > 0)); do %s_drain_fifo || true; ((%s_PERSIST_PENDING > 0)) && sleep 0.001; done\n' "$ns" "$ns" "$ns"
                printf '}\n'
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
        printf '  local __dalo_pending\n'
        printf '  while :; do\n'
        printf '    __dalo_pending=0\n'
    } >>"$out"
    # PROJECT quiescence barrier. Never wait objects sequentially: draining one
    # object may directly enqueue work in another object, including one already
    # visited in this pass. Drain every object, inspect all execution-mode
    # counters, and iterate to a fixpoint.
    for obj in "${objs[@]}"; do
        ns="${machine_ns[$obj]}"
        printf '    %s_drain_fifo || return\n' "$ns" >>"$out"
    done
    for obj in "${objs[@]}"; do
        ns="${machine_ns[$obj]}"
        emode="${execm[$obj]:-INLINE}"
        [[ "$emode" == DIRECT ]] && emode=INLINE
        case "$emode" in
            ASYNC)
                printf '    if ((%s_PENDING_JOBS > 0)); then %s_reap_one || return; __dalo_pending=1; fi\n' "$ns" "$ns" >>"$out"
                ;;
            PERSISTENT)
                printf '    ((%s_PERSIST_PENDING > 0)) && __dalo_pending=1\n' "$ns" >>"$out"
                ;;
        esac
    done
    {
        printf '    ((__dalo_pending == 0)) && return 0\n'
        printf '    sleep 0.001\n'
        printf '  done\n'
        printf '}\n'
        printf 'async_machine_main() {\n'
        printf '  async_machine_parse_args "$@" || return\n'
    } >>"$out"
    if [[ -n "$entry_ns" ]]; then
        # __entry__ is a reserved MACHINE startup trigger. It is not a declared
        # DATA input port and never contains/forwards MACHINE command-line argv.
        printf '  %s_summon_worker __entry__ || return\n' "$entry_ns" >>"$out"
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
    # Canonical DATA ABI is strictly port-aware.
    async_perf_wrap_function "$ns" fifo_output_port FIFO_OUTPUT_NS 2>/dev/null || true
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

# ============================================================================
# 13c. MIGRATION POLICY + RESOURCE MIGRATION ABI v1
# ============================================================================
# Policy is evaluated before resource PREPARE, so a non-migratable object never
# closes admission or reserves destination capacity.

migration_policy_init_object() {
    [ $# -eq 1 ] || return 64
    local ns="$1"
    [[ "$ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71
    printf -v "${ns}_MIGRATION_POLICY" '%s' MOVABLE
    eval "declare -g -A ${ns}_MIGRATION_RESOURCE_POLICY=()"
    eval "declare -g -A ${ns}_MIGRATION_RESOURCE_KIND=()"
    eval "declare -g -A ${ns}_MIGRATION_RESOURCE_DESCRIPTOR=()"
    eval "declare -g -A ${ns}_MIGRATION_RESOURCE_BYTES=()"
}

migration_policy_set() {
    [ $# -eq 2 ] || return 64
    local ns="$1" policy="$2" type_var="${1}_OBJECT_TYPE"
    case "$policy" in MOVABLE|PINNED) ;; *) return 71;; esac
    # RESOURCE_CONTAINER policy is resource-derived; don't allow a scalar
    # MOVABLE flag to bypass a pinned FD/resource.
    if [[ "${!type_var:-}" == RESOURCE_CONTAINER && "$policy" == MOVABLE ]]; then
        return 87
    fi
    printf -v "${ns}_MIGRATION_POLICY" '%s' "$policy"
}

migration_resource_policy_add() {
    [ $# -ge 4 ] && [ $# -le 5 ] || return 64
    local ns="$1" name="$2" kind="$3" policy="$4" descriptor="${5:-}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 71
    case "$policy" in PINNED|RECONSTRUCT|TRANSFER) ;; *) return 71;; esac
    local -n p="${ns}_MIGRATION_RESOURCE_POLICY" k="${ns}_MIGRATION_RESOURCE_KIND"
    local -n d="${ns}_MIGRATION_RESOURCE_DESCRIPTOR" b="${ns}_MIGRATION_RESOURCE_BYTES"
    p["$name"]="$policy"; k["$name"]="$kind"; d["$name"]="$descriptor"; b["$name"]=0
}

migration_resource_policy_set_transfer_bytes() {
    [ $# -eq 3 ] || return 64
    local ns="$1" name="$2" bytes="$3"
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 71
    local -n p="${ns}_MIGRATION_RESOURCE_POLICY" b="${ns}_MIGRATION_RESOURCE_BYTES"
    [[ "${p[$name]:-}" == TRANSFER ]] || return 87
    b["$name"]="$bytes"
}

migration_policy_bind_resource_container() {
    [ $# -eq 1 ] || return 64
    local ns="$1" type_var="${1}_RESOURCE_TYPE" path_var="${1}_RESOURCE_PATH" mode_var="${1}_RESOURCE_MODE"
    local kind="${!type_var:-unknown}" desc=""
    case "$kind" in
        file) desc="path=${!path_var:-};mode=${!mode_var:-r}" ;;
        stdin|stdout|stderr) desc="fd=${kind}" ;;
        *) desc="type=${kind}" ;;
    esac
    printf -v "${ns}_MIGRATION_POLICY" '%s' PINNED
    migration_resource_policy_add "$ns" primary "$kind" PINNED "$desc"
}

migration_policy_plan() {
    [ $# -eq 2 ] || return 64
    local outvar="$1" ns="$2" policy_var="${2}_MIGRATION_POLICY" type_var="${2}_OBJECT_TYPE"
    local policy="${!policy_var:-MOVABLE}" name transfer=0 pinned=0 reconstruct=0
    local -n p="${ns}_MIGRATION_RESOURCE_POLICY" b="${ns}_MIGRATION_RESOURCE_BYTES"
    for name in "${!p[@]}"; do
        case "${p[$name]}" in
            PINNED) ((pinned+=1)) ;;
            RECONSTRUCT) ((reconstruct+=1)) ;;
            TRANSFER) ((transfer+=${b[$name]:-0})) ;;
            *) return 71 ;;
        esac
    done
    if [[ "$policy" == PINNED || $pinned -gt 0 ]]; then
        printf -v "$outvar" 'BLOCKED policy=%s pinned=%d reconstruct=%d transfer_bytes=%d type=%s' "$policy" "$pinned" "$reconstruct" "$transfer" "${!type_var:-UNKNOWN}"
        return 88
    fi
    printf -v "$outvar" 'MOVABLE policy=%s pinned=0 reconstruct=%d transfer_bytes=%d type=%s' "$policy" "$reconstruct" "$transfer" "${!type_var:-UNKNOWN}"
}

migration_policy_admit() {
    [ $# -eq 1 ] || return 64
    local plan
    migration_policy_plan plan "$1" || return $?
}


# ============================================================================
# 13d. SCHEDULER PLACEMENT ABI v1
# ============================================================================
# Placement is a read-only planning layer.  It MUST NOT quiesce the source,
# reserve destination capacity, or mutate migration/resource ledgers.
#
# Candidate format (v1): MACHINE_ID:SCHEDULER_NAMESPACE
# The order supplied by the caller is policy order.  The mechanism performs
# deterministic first-fit over that order after hard migration/resource gates.

placement_candidate_parse() {
    [ $# -eq 3 ] || return 64
    local _pcp_spec="$1" _pcp_out_machine="$2" _pcp_out_sched="$3"
    local _pcp_machine="${_pcp_spec%%:*}" _pcp_sched="${_pcp_spec#*:}"
    [[ "$_pcp_spec" == *:* && -n "$_pcp_machine" && -n "$_pcp_sched" ]] || return 71
    [[ "$_pcp_machine" =~ ^[A-Za-z0-9_.-]+$ ]] || return 71
    [[ "$_pcp_sched" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71
    printf -v "$_pcp_out_machine" '%s' "$_pcp_machine"
    printf -v "$_pcp_out_sched" '%s' "$_pcp_sched"
}

placement_probe_candidate() {
    [ $# -eq 6 ] || return 64
    local _ppc_outvar="$1" _ppc_source_ns="$2" _ppc_local_machine="$3"
    local _ppc_candidate="$4" _ppc_cpu="$5" _ppc_memory="$6"
    [[ "$_ppc_outvar" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 64
    [[ "$_ppc_source_ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 71
    [[ "$_ppc_local_machine" =~ ^[A-Za-z0-9_.-]+$ ]] || return 71
    [[ "$_ppc_cpu" =~ ^[0-9]+$ && "$_ppc_memory" =~ ^[0-9]+$ ]] || return 64

    local _ppc_machine="" _ppc_sched="" _ppc_policy_plan="" _ppc_policy_rc=0 _ppc_rc=0
    placement_candidate_parse "$_ppc_candidate" _ppc_machine _ppc_sched || return $?

    if [[ "$_ppc_machine" == "$_ppc_local_machine" ]]; then
        declare -F "${_ppc_sched}_scheduler_can_fit" >/dev/null 2>&1 || return 66
        if "${_ppc_sched}_scheduler_can_fit" "$_ppc_cpu" "$_ppc_memory"; then
            printf -v "$_ppc_outvar" 'ELIGIBLE scope=LOCAL machine=%s scheduler=%s cpu=%s memory=%s' "$_ppc_machine" "$_ppc_sched" "$_ppc_cpu" "$_ppc_memory"
            return 0
        else
            _ppc_rc=$?
        fi
        printf -v "$_ppc_outvar" 'NO_CAPACITY scope=LOCAL machine=%s scheduler=%s rc=%s cpu=%s memory=%s' "$_ppc_machine" "$_ppc_sched" "$_ppc_rc" "$_ppc_cpu" "$_ppc_memory"
        return "$_ppc_rc"
    fi

    migration_policy_plan _ppc_policy_plan "$_ppc_source_ns" || _ppc_policy_rc=$?
    if (( _ppc_policy_rc != 0 )); then
        if (( _ppc_policy_rc == 88 )); then
            printf -v "$_ppc_outvar" 'BLOCKED_POLICY scope=REMOTE machine=%s scheduler=%s %s' "$_ppc_machine" "$_ppc_sched" "$_ppc_policy_plan"
        fi
        return "$_ppc_policy_rc"
    fi

    declare -F "${_ppc_sched}_scheduler_can_fit" >/dev/null 2>&1 || return 66
    if "${_ppc_sched}_scheduler_can_fit" "$_ppc_cpu" "$_ppc_memory"; then
        printf -v "$_ppc_outvar" 'ELIGIBLE scope=REMOTE machine=%s scheduler=%s cpu=%s memory=%s %s' "$_ppc_machine" "$_ppc_sched" "$_ppc_cpu" "$_ppc_memory" "$_ppc_policy_plan"
        return 0
    else
        _ppc_rc=$?
    fi
    printf -v "$_ppc_outvar" 'NO_CAPACITY scope=REMOTE machine=%s scheduler=%s rc=%s cpu=%s memory=%s %s' "$_ppc_machine" "$_ppc_sched" "$_ppc_rc" "$_ppc_cpu" "$_ppc_memory" "$_ppc_policy_plan"
    return "$_ppc_rc"
}

placement_select_first_fit() {
    [ $# -ge 8 ] || return 64
    local _psf_out_machine="$1" _psf_out_sched="$2" _psf_out_plan="$3"
    local _psf_source_ns="$4" _psf_local_machine="$5" _psf_cpu="$6" _psf_memory="$7"
    shift 7
    [[ "$_psf_out_machine" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$_psf_out_sched" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$_psf_out_plan" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 64
    (($# > 0)) || return 64

    local _psf_candidate _psf_machine="" _psf_sched="" _psf_probe="" _psf_rc=0
    local _psf_saw_policy_block=0 _psf_saw_capacity=0
    for _psf_candidate in "$@"; do
        placement_candidate_parse "$_psf_candidate" _psf_machine _psf_sched || return $?
        _psf_probe=""
        if placement_probe_candidate _psf_probe "$_psf_source_ns" "$_psf_local_machine" "$_psf_candidate" "$_psf_cpu" "$_psf_memory"; then
            printf -v "$_psf_out_machine" '%s' "$_psf_machine"
            printf -v "$_psf_out_sched" '%s' "$_psf_sched"
            printf -v "$_psf_out_plan" '%s' "$_psf_probe"
            return 0
        else
            _psf_rc=$?
            case "$_psf_rc" in
                88) _psf_saw_policy_block=1 ;;
                80|81) _psf_saw_capacity=1 ;;
                *) return "$_psf_rc" ;;
            esac
        fi
    done

    if (( _psf_saw_capacity )); then
        printf -v "$_psf_out_plan" 'NO_CAPACITY'
        return 89
    fi
    if (( _psf_saw_policy_block )); then
        printf -v "$_psf_out_plan" 'BLOCKED_POLICY'
        return 88
    fi
    printf -v "$_psf_out_plan" 'NO_ELIGIBLE_CANDIDATE'
    return 89
}

# ============================================================================
# 13e. PLACEMENT -> MIGRATION CUTOVER E2E ABI v1
# ============================================================================
# Planning remains read-only.  This explicit execute boundary is the first point
# allowed to mutate placement/migration state.
#
# Candidate format remains MACHINE_ID:SCHEDULER_NAMESPACE.
#
# Results:
#   LOCAL    -> source OBJECT remains authoritative; no migration transaction.
#   MIGRATED -> selected remote scheduler is passed to the existing transactional
#               migration_cutover_with_worker() path.
#
# API:
# placement_execute_first_fit \
#   OUT_ACTION OUT_MACHINE OUT_SCHED OUT_NS OUT_OBJ_ID \
#   AS OBJECT LOCAL_MACHINE CPU MEMORY BUNDLE_DIR CANDIDATE...

placement_execute_first_fit() {
    [ $# -ge 12 ] || return 64
    local _pef_out_action="$1" _pef_out_machine="$2" _pef_out_sched="$3"
    local _pef_out_ns="$4" _pef_out_obj_id="$5"
    local _pef_as="$6" _pef_obj="$7" _pef_local_machine="$8"
    local _pef_cpu="$9" _pef_memory="${10}" _pef_bundle_dir="${11}"
    shift 11

    [[ "$_pef_out_action" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$_pef_out_machine" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$_pef_out_sched" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$_pef_out_ns" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$_pef_out_obj_id" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 64
    [[ "$_pef_as" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$_pef_obj" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$_pef_local_machine" =~ ^[A-Za-z0-9_.-]+$ ]] || return 71
    [[ "$_pef_cpu" =~ ^[0-9]+$ && "$_pef_memory" =~ ^[0-9]+$ ]] || return 64
    (($# > 0)) || return 64

    local -n _pef_smap="${_pef_as}_DECL_SLOT"
    [[ -v "_pef_smap[$_pef_obj]" ]] || return 3
    local _pef_source_ns="${_pef_smap[$_pef_obj]}"
    local _pef_source_obj_id_var="${_pef_source_ns}_OBJECT_ID"
    local _pef_source_obj_id="${!_pef_source_obj_id_var:-}"
    [[ -n "$_pef_source_obj_id" ]] || return 71

    local _pef_machine="" _pef_sched="" _pef_plan=""
    local _pef_destination_ns="" _pef_destination_obj_id=""

    # This call is deliberately the complete read-only planning phase.
    placement_select_first_fit _pef_machine _pef_sched _pef_plan \
        "$_pef_source_ns" "$_pef_local_machine" "$_pef_cpu" "$_pef_memory" "$@" || return $?

    if [[ "$_pef_machine" == "$_pef_local_machine" ]]; then
        printf -v "$_pef_out_action" '%s' LOCAL
        printf -v "$_pef_out_machine" '%s' "$_pef_machine"
        printf -v "$_pef_out_sched" '%s' "$_pef_sched"
        printf -v "$_pef_out_ns" '%s' "$_pef_source_ns"
        printf -v "$_pef_out_obj_id" '%s' "$_pef_source_obj_id"
        return 0
    fi

    # All state mutation starts here and is delegated to the already
    # transactional cutover implementation.
    migration_cutover_with_worker _pef_destination_ns _pef_destination_obj_id \
        "$_pef_as" "$_pef_obj" "$_pef_sched" "$_pef_cpu" "$_pef_memory" \
        "$_pef_bundle_dir" || return $?

    printf -v "$_pef_out_action" '%s' MIGRATED
    printf -v "$_pef_out_machine" '%s' "$_pef_machine"
    printf -v "$_pef_out_sched" '%s' "$_pef_sched"
    printf -v "$_pef_out_ns" '%s' "$_pef_destination_ns"
    printf -v "$_pef_out_obj_id" '%s' "$_pef_destination_obj_id"
}



# ============================================================================
# 13f. HOST_SHUTDOWN EVACUATION ABI v1
# ============================================================================
# MACHINE shutdown evacuation is a two-phase operation:
#
#   PREFLIGHT (read-only)
#     - every declared OBJECT must be remotely migratable
#     - LOCAL candidates are ignored: shutdown cannot evacuate onto itself
#     - destination capacity is tracked in a shadow ledger so aggregate demand
#       is validated before the first mutation
#
#   EXECUTE
#     - follows the frozen preflight plan
#     - each OBJECT uses the existing transactional migration cutover
#
# Static blockers therefore fail-before-mutate. Runtime failures during execute
# retain the existing per-OBJECT rollback semantics; v1 does not reverse already
# completed earlier OBJECT migrations.
#
# Return codes:
#   88  EVACUATION_BLOCKED by migration/resource policy
#   89  EVACUATION_BLOCKED by destination capacity / no remote candidate
#
# API:
# host_shutdown_evacuation \
#   OUT_STATUS AS LOCAL_MACHINE CPU_PER_OBJECT MEMORY_PER_OBJECT BUNDLE_ROOT \
#   CANDIDATE...

host_shutdown_evacuation() {
    [ $# -ge 7 ] || return 64
    local _hse_out_status="$1" _hse_as="$2" _hse_local_machine="$3"
    local _hse_cpu="$4" _hse_memory="$5" _hse_bundle_root="$6"
    shift 6

    [[ "$_hse_out_status" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$_hse_as" =~ ^[A-Za-z_][A-Za-z0-9_]*$ &&
       "$_hse_local_machine" =~ ^[A-Za-z0-9_.-]+$ ]] || return 71
    [[ "$_hse_cpu" =~ ^[0-9]+$ && "$_hse_memory" =~ ^[0-9]+$ ]] || return 64
    (($# > 0)) || return 64

    local -n _hse_objs="${_hse_as}_DECL_OBJECTS"
    local -n _hse_smap="${_hse_as}_DECL_SLOT"
    ((${#_hse_objs[@]} > 0)) || {
        printf -v "$_hse_out_status" '%s' EVACUATED
        return 0
    }

    local -a _hse_candidates=("$@")
    local -A _hse_shadow_cpu=() _hse_shadow_mem=()
    local -A _hse_plan_machine=() _hse_plan_sched=()
    local _hse_candidate _hse_machine="" _hse_sched=""
    local _hse_cpu_total_var _hse_cpu_reserved_var _hse_mem_total_var _hse_mem_reserved_var
    local _hse_avail_cpu _hse_avail_mem

    # Seed a read-only shadow ledger from each distinct remote scheduler.
    for _hse_candidate in "${_hse_candidates[@]}"; do
        placement_candidate_parse "$_hse_candidate" _hse_machine _hse_sched || return $?
        [[ "$_hse_machine" != "$_hse_local_machine" ]] || continue
        [[ -v "_hse_shadow_cpu[$_hse_sched]" ]] && continue
        declare -F "${_hse_sched}_scheduler_can_fit" >/dev/null 2>&1 || return 66
        _hse_cpu_total_var="${_hse_sched}_CPU_TOTAL"
        _hse_cpu_reserved_var="${_hse_sched}_CPU_RESERVED"
        _hse_mem_total_var="${_hse_sched}_MEMORY_TOTAL"
        _hse_mem_reserved_var="${_hse_sched}_MEMORY_RESERVED"
        _hse_avail_cpu=$(( ${!_hse_cpu_total_var:-0} - ${!_hse_cpu_reserved_var:-0} ))
        _hse_avail_mem=$(( ${!_hse_mem_total_var:-0} - ${!_hse_mem_reserved_var:-0} ))
        _hse_shadow_cpu["$_hse_sched"]="$_hse_avail_cpu"
        _hse_shadow_mem["$_hse_sched"]="$_hse_avail_mem"
    done

    # PREFLIGHT: migration policy + aggregate remote capacity.
    local _hse_obj _hse_ns _hse_policy_plan="" _hse_policy_rc=0 _hse_found=0
    for _hse_obj in "${_hse_objs[@]}"; do
        _hse_ns="${_hse_smap[$_hse_obj]}"
        _hse_policy_plan=""
        _hse_policy_rc=0
        migration_policy_plan _hse_policy_plan "$_hse_ns" || _hse_policy_rc=$?
        if (( _hse_policy_rc != 0 )); then
            if (( _hse_policy_rc == 88 )); then
                printf -v "$_hse_out_status" 'EVACUATION_BLOCKED object=%s reason=POLICY %s' \
                    "$_hse_obj" "$_hse_policy_plan"
            fi
            return "$_hse_policy_rc"
        fi

        _hse_found=0
        for _hse_candidate in "${_hse_candidates[@]}"; do
            placement_candidate_parse "$_hse_candidate" _hse_machine _hse_sched || return $?
            [[ "$_hse_machine" != "$_hse_local_machine" ]] || continue
            if (( ${_hse_shadow_cpu[$_hse_sched]:-0} >= _hse_cpu &&
                  ${_hse_shadow_mem[$_hse_sched]:-0} >= _hse_memory )); then
                _hse_plan_machine["$_hse_obj"]="$_hse_machine"
                _hse_plan_sched["$_hse_obj"]="$_hse_sched"
                _hse_shadow_cpu["$_hse_sched"]=$(( ${_hse_shadow_cpu[$_hse_sched]} - _hse_cpu ))
                _hse_shadow_mem["$_hse_sched"]=$(( ${_hse_shadow_mem[$_hse_sched]} - _hse_memory ))
                _hse_found=1
                break
            fi
        done
        if (( !_hse_found )); then
            printf -v "$_hse_out_status" 'EVACUATION_BLOCKED object=%s reason=NO_CAPACITY' "$_hse_obj"
            return 89
        fi
    done

    # EXECUTE: the complete preflight succeeded. Follow the frozen plan.
    mkdir -p "$_hse_bundle_root" || return
    local _hse_dest_ns="" _hse_dest_obj_id="" _hse_bundle
    for _hse_obj in "${_hse_objs[@]}"; do
        _hse_sched="${_hse_plan_sched[$_hse_obj]}"
        _hse_bundle="$_hse_bundle_root/$_hse_obj"
        _hse_dest_ns=""
        _hse_dest_obj_id=""
        migration_cutover_with_worker _hse_dest_ns _hse_dest_obj_id \
            "$_hse_as" "$_hse_obj" "$_hse_sched" "$_hse_cpu" "$_hse_memory" \
            "$_hse_bundle" || {
                local _hse_rc=$?
                printf -v "$_hse_out_status" 'EVACUATION_FAILED object=%s machine=%s scheduler=%s rc=%s' \
                    "$_hse_obj" "${_hse_plan_machine[$_hse_obj]}" "$_hse_sched" "$_hse_rc"
                return "$_hse_rc"
            }
    done

    printf -v "$_hse_out_status" '%s' EVACUATED
}
