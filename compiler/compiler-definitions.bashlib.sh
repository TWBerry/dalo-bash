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
 local f="$1" t; jq -e '.abi==1 and (.type|type=="string") and (.ports|type=="object") and ((.port_patterns//[])|type=="array") and ((.instance_fields//{})|type=="object") and ((.features//[])|type=="array")' "$f" >/dev/null || return 5
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
 for f in "$root"/definitions/features/*.json; do [[ -e "$f" ]] || continue; dalo_feature_definition_register "$f" || return; done
 for f in "$root"/definitions/objects/*.json; do [[ -e "$f" ]] || continue; dalo_object_definition_register "$f" || return; done
 for f in "$root"/definitions/workers/*.json; do [[ -e "$f" ]] || continue; dalo_worker_definition_register "$f" || return; done
}
dalo_definition_validate_ir(){
 local p="$1" o type file field field_type required min value
 local -n objs="${p}_OBJECTS" types="${p}_OBJECT_TYPE" fields="${p}_OBJECT_FIELD"
 for o in "${objs[@]}"; do
   type="${types[$o]}"
   [[ -n "$type" ]] || { printf 'daloc: OBJECT %s missing TYPE\n' "$o" >&2; return 30; }
   file="${DALO_OBJECT_DEF_FILE[$type]:-}"
   [[ -n "$file" ]] || { printf 'daloc: undefined object type %s\n' "$type" >&2; return 31; }

   while IFS=$'\t' read -r field field_type required min; do
     [[ -n "$field" ]] || continue
     value="${fields["$o.$field"]:-}"
     [[ "$required" != true || -n "$value" ]] || {
       printf 'daloc: OBJECT %s (%s) requires field %s\n' "$o" "$type" "$field" >&2; return 32;
     }
     [[ -n "$value" ]] || continue
     case "$field_type" in
       uint)
         [[ "$value" =~ ^[0-9]+$ ]] || {
           printf 'daloc: OBJECT %s field %s must be uint\n' "$o" "$field" >&2; return 33;
         }
         if [[ "$min" != null ]] && (( value < min )); then
           printf 'daloc: OBJECT %s field %s must be >= %s\n' "$o" "$field" "$min" >&2; return 34
         fi
         ;;
       *) printf 'daloc: unsupported instance field type %s\n' "$field_type" >&2; return 35 ;;
     esac
   done < <(jq -r '(.instance_fields//{}) | to_entries[] |
       [.key,.value.type,(.value.required//false),(.value.min//null)] | @tsv' "$file")

   local -n worker_code="${p}_WORKER_CODE" worker_type="${p}_WORKER_TYPE"
   local worker_required mode
   worker_required="$(jq -r '(.worker.required // false)' "$file")"
   if [[ "$worker_required" == true && -z "${worker_code[$o]:-}" ]]; then
       printf 'daloc: OBJECT %s (%s) requires WORKER CODE\n' "$o" "$type" >&2; return 36
   fi
   if [[ -n "${worker_code[$o]:-}" ]]; then
       [[ -r "${worker_code[$o]}" ]] || { printf 'daloc: WORKER CODE not readable: %s\n' "${worker_code[$o]}" >&2; return 37; }
       bash -n "${worker_code[$o]}" || return 38
       mode="${worker_type[$o]:-inline}"
       case "$mode" in
         inline) jq -e '.execution | index("INLINE") != null' "$file" >/dev/null || {
             printf 'daloc: OBJECT %s does not allow INLINE execution\n' "$o" >&2; return 39; } ;;
         include) jq -e '.execution | index("INCLUDE") != null' "$file" >/dev/null || {
             printf 'daloc: OBJECT %s does not allow INCLUDE execution\n' "$o" >&2; return 39; } ;;
       esac
   fi
 done
}
