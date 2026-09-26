#!/usr/bin/env bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="helpers"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES=""
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

__dalo_sha256_file() {
    [ $# -eq 1 ] || return 2
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$1" | awk '{print $1}'
    else
        return 127
    fi
}

