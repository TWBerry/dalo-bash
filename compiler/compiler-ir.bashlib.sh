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
    eval "declare -g -a ${p}_OBJECTS=() ${p}_CONNECT_TEXT=() ${p}_EDGES=() ${p}_FEATURES=() ${p}_PARAM_ORDER=() ${p}_INIT_REQUESTS=() ${p}_INIT_ORDER=()"
    eval "declare -g -A ${p}_OBJECT_TYPE=() ${p}_OBJECT_FIELD=() ${p}_OBJECT_LIBRARIES=() ${p}_OBJECT_INIT_CODE=() ${p}_WORKER_CODE=() ${p}_WORKER_TYPE=() ${p}_WORKER_EXECUTION=() ${p}_WORKER_DEF=() ${p}_WORKER_START=() ${p}_WORKER_POLL=() ${p}_WORKER_STOP=() ${p}_WORKER_KEEPALIVE=() ${p}_WORKER_RUNTIME_REQUIRES=() ${p}_PARAM_TYPE=() ${p}_PARAM_DEFAULT=() ${p}_PARAM_REQUIRED=() ${p}_PARAM_HAS_DEFAULT=()"
}
dalo_ir_add_init() {
    [ $# -eq 2 ] || return 2
    [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { printf 'daloc: invalid INIT name %s\n' "$2" >&2; return 32; }
    local -n a="${1}_INIT_REQUESTS"
    a+=("$2")
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
# Store the user-owned INIT source path for one declared OBJECT instance.
# Parameters:
#   $1 - IR namespace containing the OBJECT declarations.
#   $2 - OBJECT instance name in that namespace.
#   $3 - Absolute or project-resolved path to the INIT Bash source file.
# Returns nonzero if the instance does not exist or INIT was already assigned.
dalo_ir_set_object_init_code() {
    [ "$#" -eq 3 ] || return 2
    local -n types="${1}_OBJECT_TYPE" init_code="${1}_OBJECT_INIT_CODE"
    [[ -v types["$2"] ]] || return 23
    [[ ! -v init_code["$2"] ]] || { printf 'daloc: duplicate OBJECT INIT for %s\n' "$2" >&2; return 33; }
    init_code["$2"]="$3"
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


dalo_ir_add_project_arg() {
    [ $# -eq 3 ] || return 2
    local p="$1" name="$2" type="$3"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'daloc: invalid ARG name %s\n' "$name" >&2; return 26; }
    case "$type" in int|uint|bool|string) ;; *) printf 'daloc: invalid ARG TYPE %s\n' "$type" >&2; return 27;; esac
    local -n order="${p}_PARAM_ORDER" types="${p}_PARAM_TYPE" defaults="${p}_PARAM_DEFAULT" required="${p}_PARAM_REQUIRED" has_default="${p}_PARAM_HAS_DEFAULT"
    [[ ! -v types["$name"] ]] || { printf 'daloc: duplicate ARG %s\n' "$name" >&2; return 28; }
    order+=("$name"); types["$name"]="$type"; defaults["$name"]=""; required["$name"]=0; has_default["$name"]=0
}
dalo_ir_set_project_arg_required() {
    [ $# -eq 3 ] || return 2
    local -n types="${1}_PARAM_TYPE" required="${1}_PARAM_REQUIRED" has_default="${1}_PARAM_HAS_DEFAULT"
    [[ -v types["$2"] ]] || return 29
    case "$3" in YES|yes|1|TRUE|true) [[ "${has_default[$2]:-0}" == 0 ]] || { printf 'daloc: ARG cannot be REQUIRED with DEFAULT\n' >&2; return 31; }; required["$2"]=1;; NO|no|0|FALSE|false) required["$2"]=0;; *) printf 'daloc: ARG REQUIRED must be YES or NO\n' >&2; return 30;; esac
}
dalo_ir_set_project_arg_default() {
    [ $# -eq 3 ] || return 2
    local -n types="${1}_PARAM_TYPE" defaults="${1}_PARAM_DEFAULT" required="${1}_PARAM_REQUIRED" has_default="${1}_PARAM_HAS_DEFAULT"
    [[ -v types["$2"] ]] || return 29
    [[ "${required[$2]:-0}" == 0 ]] || { printf 'daloc: ARG cannot have DEFAULT when REQUIRED\n' >&2; return 31; }
    defaults["$2"]="$3"; required["$2"]=0; has_default["$2"]=1
}

# Object-owned library dependencies, never inferred from WORKER include calls.
dalo_ir_set_object_libraries() {
    local -n libs="${1}_OBJECT_LIBRARIES"
    local lib
    for lib in $3; do
        [[ "$lib" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { printf 'daloc: invalid library name %s\n' "$lib" >&2; return 39; }
    done
    libs["$2"]="$3"
}
