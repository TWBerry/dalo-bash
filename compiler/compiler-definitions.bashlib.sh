DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="compiler-definitions"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="helpers"

[ "${DALO_COMPILER_DEFINITIONS_INCLUDE:-0}" -eq 0 ] || return 0
DALO_COMPILER_DEFINITIONS_INCLUDE=1

DALO_OBJECT_DEFINITION_ABI=1
DALO_FEATURE_DEFINITION_ABI=1
DALO_WORKER_DEFINITION_ABI=1
declare -gA DALO_OBJECT_DEF_FILE=() DALO_FEATURE_DEF_FILE=() DALO_WORKER_DEF_FILE=()

dalo_object_definition_register(){
 local f="$1" t; jq -e '.abi==1 and (.type|type=="string") and (.ports|type=="object") and ((.features//[])|type=="array")' "$f" >/dev/null || return 5
 t="$(jq -r .type "$f")"; DALO_OBJECT_DEF_FILE["$t"]="$f"
}
dalo_feature_definition_register(){
 local f="$1" n; jq -e '.abi==1 and (.name|type=="string") and ((.requires//[])|type=="array")' "$f" >/dev/null || return 5
 n="$(jq -r .name "$f")"; DALO_FEATURE_DEF_FILE["$n"]="$f"
}
dalo_worker_definition_register(){
 local f="$1" n; jq -e '.abi==1 and (.name|type=="string") and ((.features//[])|type=="array")' "$f" >/dev/null || return 5
 n="$(jq -r .name "$f")"; DALO_WORKER_DEF_FILE["$n"]="$f"
}
dalo_definitions_load_tree(){
 local root="$1" f
 command -v jq >/dev/null || { printf 'daloc: jq is required\n' >&2; return 4; }
 for f in "$root"/definitions/features/*.json; do [[ -e "$f" ]] && dalo_feature_definition_register "$f" || return; done
 for f in "$root"/definitions/objects/*.json; do [[ -e "$f" ]] && dalo_object_definition_register "$f" || return; done
 for f in "$root"/definitions/workers/*.json; do [[ -e "$f" ]] && dalo_worker_definition_register "$f" || return; done
}
dalo_definition_validate_ir(){
 local p="$1" o type
 local nv="${p}_NAME"
 local -n objs="${p}_OBJECTS" types="${p}_OBJECT_TYPE"
 for o in "${objs[@]}"; do
   type="${types[$o]}"
   [[ -n "$type" ]] || { printf 'daloc: OBJECT %s missing TYPE\n' "$o" >&2; return 30; }
   [[ -n "${DALO_OBJECT_DEF_FILE[$type]:-}" ]] || { printf 'daloc: undefined object type %s\n' "$type" >&2; return 31; }
 done
}
