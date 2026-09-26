DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="compiler-ir"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES=""

[ "${DALO_COMPILER_IR_INCLUDE:-0}" -eq 0 ] || return 0
DALO_COMPILER_IR_INCLUDE=1

dalo_ir_init() {
    local p="$1"
    printf -v "${p}_NAME" '%s' ""
    printf -v "${p}_VERSION" '%s' ""
    eval "declare -g -a ${p}_OBJECTS=() ${p}_CONNECT_TEXT=() ${p}_EDGES=() ${p}_FEATURES=()"
    eval "declare -g -A ${p}_OBJECT_TYPE=() ${p}_OBJECT_FIELD=() ${p}_WORKER_CODE=() ${p}_WORKER_TYPE=() ${p}_WORKER_EXECUTION=()"
}
dalo_ir_set_project_name() {
    [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { printf 'daloc: invalid PROJECT NAME %s\n' "$2" >&2; return 20; }
    printf -v "${1}_NAME" '%s' "$2"
}
dalo_ir_set_project_version() {
    [[ "$2" =~ ^[0-9]+\.[0-9]+$ ]] || { printf 'daloc: VERSION must be vermaj.vermin\n' >&2; return 21; }
    printf -v "${1}_VERSION" '%s' "$2"
}
dalo_ir_add_object() {
    local -n a="${1}_OBJECTS" t="${1}_OBJECT_TYPE"
    [[ ! -v t["$2"] ]] || { printf 'daloc: duplicate OBJECT %s\n' "$2" >&2; return 22; }
    a+=("$2"); t["$2"]=""
}
dalo_ir_set_object_type(){ local -n t="${1}_OBJECT_TYPE"; [[ -v t["$2"] ]] || return 23; t["$2"]="$3"; }
dalo_ir_set_object_field(){ local -n f="${1}_OBJECT_FIELD"; f["$2.$3"]="$4"; }
dalo_ir_add_connect_text(){ local -n a="${1}_CONNECT_TEXT"; a+=("$2"); }
dalo_ir_add_edge(){ local -n a="${1}_EDGES"; a+=("$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"); }
dalo_ir_validate_header(){
    local nv="${1}_NAME" vv="${1}_VERSION"
    [[ -n "${!nv}" ]] || { printf 'daloc: PROJECT NAME is required\n' >&2; return 24; }
    [[ -n "${!vv}" ]] || { printf 'daloc: PROJECT VERSION is required\n' >&2; return 25; }
}

dalo_ir_set_worker_code(){ local -n a="${1}_WORKER_CODE"; a["$2"]="$3"; }
dalo_ir_set_worker_type(){ local -n a="${1}_WORKER_TYPE"; a["$2"]="$3"; }

dalo_ir_set_worker_execution(){ local -n a="${1}_WORKER_EXECUTION"; a["$2"]="$3"; }
