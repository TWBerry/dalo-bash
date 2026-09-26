#!/usr/bin/env bash
# DALO dependency-aware Bash library loader v2.
# Public API: include NAME

if [ "${DALO_LIBRARY_LOADER_INCLUDE:-0}" -eq 0 ]; then
    DALO_LIBRARY_LOADER_INCLUDE=1
else
    return 0 2>/dev/null || exit 0
fi

DALO_LIBRARY_PATH="${DALO_LIBRARY_PATH:-.}"
declare -gA DALO_LIBRARY_LOADED=()
declare -gA DALO_LIBRARY_LOADED_FILE=()
declare -ga DALO_LIBRARY_LOAD_ORDER=()

__dalo_loader_error() { printf 'library.sh: %s\n' "$*" >&2; }

__dalo_find_library() {
    local name="$1" dir candidate oldifs="$IFS"
    IFS=':'
    for dir in $DALO_LIBRARY_PATH; do
        [ -n "$dir" ] || dir='.'
        for candidate in "$dir/$name.bashlib.sh" "$dir/$name"; do
            if [ -f "$candidate" ]; then
                IFS="$oldifs"
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done
    IFS="$oldifs"
    return 1
}

# Read literal metadata assignments without sourcing the library.
__dalo_metadata() {
    local file="$1" key="$2" line value
    line="$(grep -m1 -E "^[[:space:]]*${key}=[\"'][^\"']*[\"'][[:space:]]*$|^[[:space:]]*${key}=[0-9]+[[:space:]]*$" "$file")" || return 1
    value="${line#*=}"
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    printf '%s\n' "$value"
}

# Resolve and validate one dependency closure. Nothing is sourced here.
__dalo_resolve() {
    local name="$1" chain="${2:-}" file declared abi requires dep state
    local state_name="$3" file_name="$4" order_name="$5"
    local -n _state="$state_name" _file="$file_name" _order="$order_name"

    # Already loaded in this shell: dependency is satisfied immediately.
    if [ "${DALO_LIBRARY_LOADED[$name]:-0}" -eq 1 ]; then
        return 0
    fi

    state="${_state[$name]:-0}"
    [ "$state" -eq 2 ] && return 0
    if [ "$state" -eq 1 ]; then
        __dalo_loader_error "dependency cycle: ${chain}${name}"
        return 1
    fi
    _state["$name"]=1

    file="$(__dalo_find_library "$name")" || {
        __dalo_loader_error "missing library: $name (DALO_LIBRARY_PATH=$DALO_LIBRARY_PATH)"
        return 1
    }
    bash -n "$file" || {
        __dalo_loader_error "syntax error: $file"
        return 1
    }

    abi="$(__dalo_metadata "$file" DALO_LIBRARY_ABI)" || {
        __dalo_loader_error "missing DALO_LIBRARY_ABI metadata: $file"
        return 1
    }
    [ "$abi" -eq 1 ] 2>/dev/null || {
        __dalo_loader_error "unsupported library ABI '$abi': $file"
        return 1
    }

    declared="$(__dalo_metadata "$file" DALO_LIBRARY_NAME)" || {
        __dalo_loader_error "missing DALO_LIBRARY_NAME metadata: $file"
        return 1
    }
    [ "$declared" = "$name" ] || {
        __dalo_loader_error "library name mismatch: requested '$name', file declares '$declared' ($file)"
        return 1
    }

    requires="$(__dalo_metadata "$file" DALO_LIBRARY_REQUIRES)" || requires=''
    _file["$name"]="$file"
    for dep in $requires; do
        __dalo_resolve "$dep" "${chain}${name} -> " "$state_name" "$file_name" "$order_name" || return
    done

    _state["$name"]=2
    _order+=("$name")
}

include() {
    [ "$#" -eq 1 ] || {
        __dalo_loader_error 'include expects exactly one library name'
        return 2
    }

    local name="$1" lib file
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || {
        __dalo_loader_error "invalid library name: $name"
        return 2
    }

    # Idempotent fast path: do not resolve dependencies or run bash -n again.
    if [ "${DALO_LIBRARY_LOADED[$name]:-0}" -eq 1 ]; then
        return 0
    fi

    # Per-include transaction state. Validate the complete not-yet-loaded
    # dependency closure before sourcing its first library.
    local -A resolve_state=()
    local -A resolve_file=()
    local -a resolve_order=()

    __dalo_resolve "$name" '' resolve_state resolve_file resolve_order || return

    for lib in "${resolve_order[@]}"; do
        [ "${DALO_LIBRARY_LOADED[$lib]:-0}" -eq 1 ] && continue
        file="${resolve_file[$lib]}"
        source "$file" || {
            __dalo_loader_error "source failed: $file"
            return 1
        }
        DALO_LIBRARY_LOADED["$lib"]=1
        DALO_LIBRARY_LOADED_FILE["$lib"]="$file"
        DALO_LIBRARY_LOAD_ORDER+=("$lib")
    done
}
