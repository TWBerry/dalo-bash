DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="compiler-linker"
DALO_LIBRARY_VERSION="1.1.0"
DALO_LIBRARY_REQUIRES="compiler-ir compiler-definitions compiler-connect compiler-features dalo"

[ "${DALO_COMPILER_LINKER_INCLUDE:-0}" -eq 0 ] || return 0
DALO_COMPILER_LINKER_INCLUDE=1

dalo_link_machine(){
    [ $# -eq 3 ] || return 2
    local root="$1" p="$2" out="$3"
    local nv="${p}_NAME" vv="${p}_VERSION"
    local name="${!nv}" version="${!vv}" obj edge mode workers
    local -n objs="${p}_OBJECTS" types="${p}_OBJECT_TYPE" fields="${p}_OBJECT_FIELD"
    local -n edges="${p}_EDGES" worker_code="${p}_WORKER_CODE" worker_type="${p}_WORKER_TYPE"

    # Backend ABI expected by the established executable-machine linker.
    local backend="DALO_MACHINE_BUILD"
    eval "declare -g -a ${backend}_DECL_OBJECTS=() ${backend}_EDGES=() ${backend}_PARAM_ORDER=()"
    eval "declare -g -A ${backend}_DECL_TYPE=() ${backend}_DECL_WORKER_FILE=() ${backend}_DECL_WORKERS=()"
    eval "declare -g -A ${backend}_DECL_RESOURCE_KIND=() ${backend}_DECL_RESOURCE_ARG=() ${backend}_EXEC_MODE=()"
    eval "declare -g -A ${backend}_PARAM_TYPE=() ${backend}_PARAM_DEFAULT=() ${backend}_PARAM_REQUIRED=()"
    local -n b_objs="${backend}_DECL_OBJECTS" b_types="${backend}_DECL_TYPE"
    local -n b_wf="${backend}_DECL_WORKER_FILE" b_workers="${backend}_DECL_WORKERS"
    local -n b_edges="${backend}_EDGES" b_exec="${backend}_EXEC_MODE"

    b_objs=("${objs[@]}")
    b_edges=("${edges[@]}")
    for obj in "${objs[@]}"; do
        b_types["$obj"]="${types[$obj]}"
        workers="${fields["$obj.MAX_JOBS"]:-1}"
        b_workers["$obj"]="$workers"
        if [[ -n "${worker_code[$obj]:-}" ]]; then
            mode="${worker_type[$obj]:-inline}"
            [[ "$mode" == inline ]] || {
                printf 'daloc: WORKER TYPE include is not standalone in MACHINE ABI v1\\n' >&2
                return 70
            }
            b_wf["$obj"]="${worker_code[$obj]}"
            b_exec["$obj"]="INLINE"
        fi
    done
    printf -v "${backend}_MAX_WORKERS_PER_OBJECT" '%s' 1
    printf -v "${backend}_ENTRY_OBJECT" '%s' ""

    local hash hash_input
    printf -v hash_input '%s\\n' "$name" "$version" "${objs[@]}" "${edges[@]}"
    if command -v sha256sum >/dev/null 2>&1; then
        hash="$(printf '%s' "$hash_input" | sha256sum)" || return
        hash="${hash%% *}"
    else
        hash="$(printf '%s' "$hash_input" | shasum -a 256)" || return
        hash="${hash%% *}"
    fi
    __asyncmachine_link "$backend" "" "$out" "$hash" || return
}
