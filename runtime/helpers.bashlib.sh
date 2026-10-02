#!/usr/bin/env bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="helpers"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="python"
DALO_LIBRARY_INIT="dalo_helpers_init"
DALO_LIBRARY_FINI="dalo_helpers_fini"
# DALO shared helper library

if [ "${DALO_HELPERS_INCLUDE:-0}" -eq 0 ]; then
    DALO_HELPERS_INCLUDE=1
else
    return 0
fi

__asyncobj_ensure_variable_storage() {
    local ns="$1"
    declare -p "${ns}_VARIABLE_TYPE" >/dev/null 2>&1 || eval "declare -gA ${ns}_VARIABLE_TYPE=()"
    declare -p "${ns}_VARIABLE_VALUE" >/dev/null 2>&1 || eval "declare -gA ${ns}_VARIABLE_VALUE=()"
    declare -p "${ns}_CODE_ORDER" >/dev/null 2>&1 || eval "declare -ga ${ns}_CODE_ORDER=()"
    local code_var="${ns}_variables_code"
    if ! declare -p "$code_var" >/dev/null 2>&1; then
        printf -v "$code_var" '%s' ""
    fi
}

__asyncobj_record_code() {
    local ns="$1" component="$2" code="$3"
    __asyncobj_ensure_variable_storage "$ns"

    local type_name="${ns}_VARIABLE_TYPE"
    local value_name="${ns}_VARIABLE_VALUE"
    local order_name="${ns}_CODE_ORDER"
    local -n _types="$type_name" _values="$value_name" _order="$order_name"
    local key="code.${component}"

    if [[ ! -v _types["$key"] ]]; then
        _order+=("$key")
    fi
    _types["$key"]="bash"
    _values["$key"]="$code"

    local aggregate="" k
    for k in "${_order[@]}"; do
        aggregate+="${_values[$k]}"$'\n'
    done
    printf -v "${ns}_variables_code" '%s' "$aggregate"
}

__asyncobj_eval_body() {
    local ns="$1" component="$2" body="$3"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/asyncobj-body.XXXXXX")" || return 1
    printf '%s\n' "$body" > "$tmp"
    if ! bash -n "$tmp"; then
        rm -f -- "$tmp"
        printf 'Chyba [%s]: generated component %s neprošel bash -n\n' "$ns" "$component" >&2
        return 2
    fi
    rm -f -- "$tmp"

    eval "$body" || return
    __asyncobj_record_code "$ns" "$component" "$body"
}

__asyncobj_random_hex() {
    local bytes="${1:-8}" out=""
    if [ -r /dev/urandom ]; then
        out="$(od -An -N "$bytes" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return
    else
        printf -v out '%08x%08x' "$RANDOM$RANDOM" "$RANDOM$RANDOM"
    fi
    printf '%s\n' "$out"
}

__asyncobj_decode_q() {
    [ $# -eq 2 ] || return 2
    local encoded="$1" outvar="$2" decoded
    eval "decoded=$encoded" || return
    printf -v "$outvar" '%s' "$decoded"
}

# Compute a lowercase SHA-256 digest for a readable file.
# Parameters:
#   $1: Path to the file whose contents must be hashed.
# Output: Exactly 64 hexadecimal characters followed by a newline on success.
# Returns: 0 on success, 2 for invalid arguments, 127 if no hashing tool is
#   installed, or the underlying hashing tool's nonzero exit status.
# Notes: Avoid pipelines so a failed hash command cannot be masked by awk.
# Hash a readable file using an explicitly reserved persistent Python worker or native tools.
# Parameters:
#   $1: Path to the file whose bytes are hashed; paths may contain spaces or Unicode.
# Output: One lowercase, 64-character SHA-256 digest followed by a newline.
# Returns: 0 on success; 2 on invalid arguments; native-tool status on fallback failure.
# Notes: Python is opt-in. Call dalo_hash_python_enable in the owning shell first.
#        The native fallback remains available to early bootstrap and migration.
__dalo_sha256_file() {
    [ "$#" -eq 1 ] || return 2
    local path="$1" output digest code
    [ -f "$path" ] && [ -r "$path" ] || return 1
    if [ -n "${DALO_HASH_PY_HANDLE:-}" ] && declare -F inline_python >/dev/null 2>&1; then
        # Encode filename bytes using Bash builtins; avoid shell/Python quoting hazards.
        # LC_ALL=C ensures each substring is exactly one byte, including UTF-8 paths.
        local hex='' byte i LC_ALL=C
        for ((i=0; i<${#path}; i++)); do
            printf -v byte '%02x' "'${path:i:1}"
            hex+="$byte"
        done
        code="__import__('hashlib').file_digest(open(bytes.fromhex('$hex').decode('utf-8','surrogateescape'),'rb'),'sha256').hexdigest()"
        output="$(inline_python -t "$DALO_HASH_PY_HANDLE" "$code")" || return
        # EVAL returns Python repr for strings; remove its surrounding quotes.
        if [[ "${output:0:1}" == "'" && "${output: -1}" == "'" ]]; then output="${output:1:${#output}-2}"; fi
        [[ "$output" =~ ^[[:xdigit:]]{64}$ ]] || return 1
        printf '%s
' "${output,,}"
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        output="$(sha256sum -- "$1")" || return
    elif command -v shasum >/dev/null 2>&1; then
        output="$(shasum -a 256 -- "$1")" || return
    else
        return 127
    fi
    digest="${output%% *}"
    [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s
' "${digest,,}"
}

# Reserve a dedicated Python execution slot for file hashing in the owning shell.
# Parameters: none. Requires the caller to load the python library using `include python`.
# Returns: zero if a valid slot was reserved; nonzero if Python is unavailable or busy.
# Notes: Do not invoke this inside command substitution: the reservation must survive.
# Initialize the helpers library after its declared Python dependency is ready.
# Parameters: none.
# Returns: zero in all supported configurations; native SHA-256 remains available
#          if no Python worker can be reserved.
# Side effects: reserves one persistent Python execution slot when available.
dalo_helpers_init() {
    [ "$#" -eq 0 ] || return 2
    if ! dalo_hash_python_enable; then
        unset DALO_HASH_PY_HANDLE
        printf '%s\n' 'DALO helpers: Python hash slot unavailable; using native SHA-256' >&2
    fi
    return 0
}

# Release the helpers-owned Python slot before the Python library shuts down.
# Parameters: none.
# Returns: zero; shutdown continues even if the Python supervisor is unavailable.
# Side effects: releases the hash lease if it is still valid.
dalo_helpers_fini() {
    [ "$#" -eq 0 ] || return 2
    dalo_hash_python_disable || return 0
    return 0
}

dalo_hash_python_enable() {
    [ "$#" -eq 0 ] || return 2
    declare -F init_python_thread >/dev/null 2>&1 || return 127
    [ -z "${DALO_HASH_PY_HANDLE:-}" ] || return 0
    local handle
    handle="$(init_python_thread)" || return
    [[ "$handle" == OK\|* ]] || return 1
    DALO_HASH_PY_HANDLE="$handle"
}

# Release the dedicated hash slot without shutting down the shared Python supervisor.
# Parameters: none.
# Returns: zero when no slot is held or when release succeeds; otherwise nonzero.
dalo_hash_python_disable() {
    [ "$#" -eq 0 ] || return 2
    [ -n "${DALO_HASH_PY_HANDLE:-}" ] || return 0
    local handle="$DALO_HASH_PY_HANDLE"
    unset DALO_HASH_PY_HANDLE
    release_python_thread "$handle" >/dev/null
}

