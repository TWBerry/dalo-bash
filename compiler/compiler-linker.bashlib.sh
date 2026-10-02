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
    local -n objs="${p}_OBJECTS" types="${p}_OBJECT_TYPE" fields="${p}_OBJECT_FIELD" object_libs="${p}_OBJECT_LIBRARIES" object_init="${p}_OBJECT_INIT_CODE"
    local -n edges="${p}_EDGES" worker_code="${p}_WORKER_CODE" worker_type="${p}_WORKER_TYPE" worker_execution="${p}_WORKER_EXECUTION" worker_start="${p}_WORKER_START" worker_poll="${p}_WORKER_POLL" worker_stop="${p}_WORKER_STOP" worker_keepalive="${p}_WORKER_KEEPALIVE" worker_requires="${p}_WORKER_RUNTIME_REQUIRES"
    local -n params="${p}_PARAM_ORDER" param_type="${p}_PARAM_TYPE" param_default="${p}_PARAM_DEFAULT" param_required="${p}_PARAM_REQUIRED"
    dalo_definition_resolve_inits "$p" || return
    local -n init_order="${p}_INIT_ORDER" init_artifact="${p}_INIT_ARTIFACT" init_entry="${p}_INIT_ENTRY" init_runtime="${p}_INIT_RUNTIME_REQUIRES"

    # Backend ABI expected by the established executable-machine linker.
    local backend="DALO_MACHINE_BUILD"
    eval "declare -g -a ${backend}_DECL_OBJECTS=() ${backend}_EDGES=() ${backend}_PARAM_ORDER=() ${backend}_INIT_ORDER=()"
    eval "declare -g -A ${backend}_DECL_TYPE=() ${backend}_DECL_WORKER_FILE=() ${backend}_DECL_INIT_FILE=() ${backend}_DECL_WORKERS=() ${backend}_DECL_FIELD=()"
    eval "declare -g -A ${backend}_DECL_RESOURCE_KIND=() ${backend}_DECL_RESOURCE_ARG=() ${backend}_EXEC_MODE=() ${backend}_WORKER_START=() ${backend}_WORKER_POLL=() ${backend}_WORKER_STOP=() ${backend}_WORKER_KEEPALIVE=() ${backend}_WORKER_RUNTIME_REQUIRES=()"
    eval "declare -g -A ${backend}_PARAM_TYPE=() ${backend}_PARAM_DEFAULT=() ${backend}_PARAM_REQUIRED=() ${backend}_INIT_ARTIFACT=() ${backend}_INIT_ENTRY=() ${backend}_INIT_RUNTIME_REQUIRES=()"
    local -n b_objs="${backend}_DECL_OBJECTS" b_types="${backend}_DECL_TYPE"
    local -n b_wf="${backend}_DECL_WORKER_FILE" b_init="${backend}_DECL_INIT_FILE" b_workers="${backend}_DECL_WORKERS" b_fields="${backend}_DECL_FIELD"
    local -n b_edges="${backend}_EDGES" b_exec="${backend}_EXEC_MODE" b_start="${backend}_WORKER_START" b_poll="${backend}_WORKER_POLL" b_stop="${backend}_WORKER_STOP" b_keepalive="${backend}_WORKER_KEEPALIVE" b_requires="${backend}_WORKER_RUNTIME_REQUIRES"
    local -n b_params="${backend}_PARAM_ORDER" b_ptype="${backend}_PARAM_TYPE" b_pdefault="${backend}_PARAM_DEFAULT" b_prequired="${backend}_PARAM_REQUIRED"
    local -n b_init_order="${backend}_INIT_ORDER" b_init_artifact="${backend}_INIT_ARTIFACT" b_init_entry="${backend}_INIT_ENTRY" b_init_runtime="${backend}_INIT_RUNTIME_REQUIRES"

    b_objs=("${objs[@]}")
    b_edges=("${edges[@]}")
    b_params=("${params[@]}")
    b_init_order=("${init_order[@]}")
    local init_name
    for init_name in "${init_order[@]}"; do b_init_artifact["$init_name"]="${init_artifact[$init_name]}"; b_init_entry["$init_name"]="${init_entry[$init_name]}"; b_init_runtime["$init_name"]="${init_runtime[$init_name]}"; done
    for obj in "${params[@]}"; do
        b_ptype["$obj"]="${param_type[$obj]}"
        b_pdefault["$obj"]="${param_default[$obj]:-}"
        b_prequired["$obj"]="${param_required[$obj]}"
    done
    for obj in "${objs[@]}"; do
        b_types["$obj"]="${types[$obj]}"
        workers="${fields["$obj.MAX_JOBS"]:-1}"
        b_workers["$obj"]="$workers"
        local field_key field_prefix="$obj."
        for field_key in "${!fields[@]}"; do
            [[ "$field_key" == "$field_prefix"* ]] || continue
            b_fields["$field_key"]="${fields[$field_key]}"
        done
        # Preserve the per-instance INIT artifact separately from WORKER code.
        b_init["$obj"]="${object_init[$obj]:-}"
        if [[ -n "${worker_code[$obj]:-}" ]]; then
            mode="${worker_type[$obj]:-inline}"
            [[ "$mode" == inline ]] || {
                printf 'daloc: WORKER TYPE include is not standalone in MACHINE ABI v1\\n' >&2
                return 70
            }
            b_wf["$obj"]="${worker_code[$obj]}"
            b_exec["$obj"]="${worker_execution[$obj]:-INLINE}"
            b_start["$obj"]="${worker_start[$obj]:-}"; b_poll["$obj"]="${worker_poll[$obj]:-}"; b_stop["$obj"]="${worker_stop[$obj]:-}"; b_keepalive["$obj"]="${worker_keepalive[$obj]:-0}"; b_requires["$obj"]="${object_libs[$obj]:-} ${worker_requires[$obj]:-}"
        else
            b_requires["$obj"]="${object_libs[$obj]:-}"
        fi
    done
    printf -v "${backend}_MAX_WORKERS_PER_OBJECT" '%s' 1

    # MACHINE entry ABI v1: a single ORIGIN is the implicit startup entry.
    # Multiple ORIGINs remain explicit/manual until PROJECT syntax grows an
    # explicit ENTRY declaration; silently choosing one would be ambiguous.
    local entry_obj="" origin_count=0
    for obj in "${objs[@]}"; do
        if [[ "${types[$obj]}" == ORIGIN ]]; then
            entry_obj="$obj"
            ((origin_count+=1))
        fi
    done
    if (( origin_count == 1 )); then
        printf -v "${backend}_ENTRY_OBJECT" '%s' "$entry_obj"
    else
        printf -v "${backend}_ENTRY_OBJECT" '%s' ""
    fi

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
