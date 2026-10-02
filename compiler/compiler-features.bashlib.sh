DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="compiler-features"
DALO_LIBRARY_VERSION="1.0.1"
DALO_LIBRARY_REQUIRES="compiler-ir compiler-definitions"

[ "${DALO_COMPILER_FEATURES_INCLUDE:-0}" -eq 0 ] || return 0
DALO_COMPILER_FEATURES_INCLUDE=1

__dalo_feature_visit() {
    local feature="$1"
    local state_name="$2"
    local out_name="$3"
    local dep current file
    local -n __state_ref="$state_name"
    local -n __out_ref="$out_name"

    file="${DALO_FEATURE_DEF_FILE[$feature]:-}"
    [[ -n "$file" ]] || {
        printf 'daloc: undefined feature %s\n' "$feature" >&2
        return 60
    }

    current="${__state_ref[$feature]:-0}"
    [[ "$current" == 2 ]] && return 0
    [[ "$current" != 1 ]] || {
        printf 'daloc: feature dependency cycle at %s\n' "$feature" >&2
        return 61
    }

    __state_ref["$feature"]=1

    while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        __dalo_feature_visit "$dep" "$state_name" "$out_name" || return
    done < <(jq -r '(.requires // [])[]' "$file")

    __state_ref["$feature"]=2
    __out_ref+=("$feature")
}

dalo_features_lower_ir() {
    local ir="$1"
    local object type file feature
    local -A __feature_state=()
    local -n __objects_ref="${ir}_OBJECTS"
    local -n __types_ref="${ir}_OBJECT_TYPE"
    local -n __features_ref="${ir}_FEATURES"

    __features_ref=()

    for object in "${__objects_ref[@]}"; do
        type="${__types_ref[$object]}"
        file="${DALO_OBJECT_DEF_FILE[$type]:-}"
        [[ -n "$file" ]] || return 31

        while IFS= read -r feature; do
            [[ -n "$feature" ]] || continue
            __dalo_feature_visit "$feature" __feature_state __features_ref || return
        done < <(jq -r '(.features // [])[]' "$file")
    done
}

# Feature ABI v2 milestone 1: resolve per-object type + instance + WORKER
# requirements. Generator ownership remains explicitly unassigned until validated.
dalo_features_resolve_object_v2() {
    local ir="$1" object="$2" out_name="$3"
    local type file worker_file feature requested json
    local -n __types="${ir}_OBJECT_TYPE"
    local -n __fields="${ir}_OBJECT_FIELD"
    local -n __workers="${ir}_WORKER_DEF"
    local -n __out="$out_name"
    local -A __feature_state=()
    __out=()
    type="${__types[$object]:-}"
    file="${DALO_OBJECT_DEF_FILE[$type]:-}"
    [[ -n "$file" && -r "$file" ]] || { printf 'daloc: undefined object type %s\n' "$type" >&2; return 31; }
    json="$(jq -r '(.features // []) | if type=="array" and all(.[]; type=="string") then .[] else error("invalid object features") end' "$file")" || return 63
    while IFS= read -r feature; do
        [[ -n "$feature" ]] || continue
        __dalo_feature_visit "$feature" __feature_state "$out_name" || return
    done <<< "$json"
    # Only fields explicitly declared by the object descriptor may request FEATURES.
    requested="${__fields["$object.FEATURES"]:-}"
    if [[ -n "$requested" ]]; then
        jq -e '.instance_fields.FEATURES.type == "string"' "$file" >/dev/null || {
            printf 'daloc: OBJECT %s does not declare instance FEATURES\n' "$object" >&2; return 62;
        }
        local -a __requested=()
        IFS=',' read -r -a __requested <<< "$requested"
        for feature in "${__requested[@]}"; do
            feature="${feature//[[:space:]]/}"
            [[ -n "$feature" ]] || { printf 'daloc: empty feature in OBJECT %s\n' "$object" >&2; return 62; }
            __dalo_feature_visit "$feature" __feature_state "$out_name" || return
        done
    fi
    worker_file="${__workers[$object]:-}"
    if [[ -n "$worker_file" ]]; then
        [[ -r "$worker_file" ]] || { printf 'daloc: unreadable WORKER definition %s\n' "$worker_file" >&2; return 64; }
        json="$(jq -r '(.features // []) | if type=="array" and all(.[]; type=="string") then .[] else error("invalid worker features") end' "$worker_file")" || return 64
        while IFS= read -r feature; do
            [[ -n "$feature" ]] || continue
            __dalo_feature_visit "$feature" __feature_state "$out_name" || return
        done <<< "$json"
    fi
}

dalo_features_lower_ir_v2() {
    local ir="$1" object feature
    local -n __objects="${ir}_OBJECTS"
    local -n __features="${ir}_FEATURES"
    local -a __object_features=()
    local -A __seen=()
    __features=()
    for object in "${__objects[@]}"; do
        dalo_features_resolve_object_v2 "$ir" "$object" __object_features || return
        for feature in "${__object_features[@]}"; do
            [[ -v __seen["$feature"] ]] && continue
            __seen["$feature"]=1
            __features+=("$feature")
        done
    done
}
