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
