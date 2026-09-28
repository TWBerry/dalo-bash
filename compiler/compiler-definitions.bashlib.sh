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
 local p="$1" o type file field field_type required min value enum_json
 local -n objs="${p}_OBJECTS" types="${p}_OBJECT_TYPE" fields="${p}_OBJECT_FIELD"
 local -n worker_code="${p}_WORKER_CODE" worker_type="${p}_WORKER_TYPE" worker_execution="${p}_WORKER_EXECUTION" worker_def_map="${p}_WORKER_DEF" worker_start="${p}_WORKER_START" worker_poll="${p}_WORKER_POLL" worker_stop="${p}_WORKER_STOP" worker_keepalive="${p}_WORKER_KEEPALIVE" worker_requires="${p}_WORKER_RUNTIME_REQUIRES"
 for o in "${objs[@]}"; do
   type="${types[$o]}"
   [[ -n "$type" ]] || { printf 'daloc: OBJECT %s missing TYPE\n' "$o" >&2; return 30; }
   file="${DALO_OBJECT_DEF_FILE[$type]:-}"
   [[ -n "$file" ]] || { printf 'daloc: undefined object type %s\n' "$type" >&2; return 31; }

   while IFS=$'\t' read -r field field_type required min enum_json; do
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
         if [[ "$min" != __NULL__ ]] && (( value < min )); then
           printf 'daloc: OBJECT %s field %s must be >= %s\n' "$o" "$field" "$min" >&2; return 34
         fi
         ;;
       string) : ;;
       *) printf 'daloc: unsupported instance field type %s\n' "$field_type" >&2; return 35 ;;
     esac
     if [[ "$enum_json" != '"__NULL__"' ]] && ! jq -e --arg v "$value" 'index($v) != null' <<<"$enum_json" >/dev/null; then
       printf 'daloc: OBJECT %s field %s has invalid value %s\n' "$o" "$field" "$value" >&2
       return 35
     fi
     case "$field_type" in
       uint|string) : ;;
     esac
   done < <(jq -r '(.instance_fields//{}) | to_entries[] |
       [.key,.value.type,(.value.required//false),(.value.min//"__NULL__"),((.value.enum//"__NULL__")|tojson)] | @tsv' "$file")

   local worker_required mode default_worker worker_def artifact base execution
   worker_required="$(jq -r '(.worker.required // false)' "$file")"
   default_worker="$(jq -r '(.worker.default // "")' "$file")"
   if [[ -z "${worker_code[$o]:-}" && -n "$default_worker" ]]; then
       worker_def="${DALO_WORKER_DEF_FILE[$default_worker]:-}"
       [[ -n "$worker_def" ]] || { printf 'daloc: OBJECT %s default worker %s is undefined\n' "$o" "$default_worker" >&2; return 36; }
       jq -e --arg t "$type" '(.object_types // []) | index($t) != null' "$worker_def" >/dev/null || {
           printf 'daloc: worker %s does not support OBJECT type %s\n' "$default_worker" "$type" >&2; return 36;
       }
       artifact="$(jq -r '.artifact // ""' "$worker_def")"
       [[ -n "$artifact" ]] || { printf 'daloc: worker %s has no artifact\n' "$default_worker" >&2; return 36; }
       base="$(cd -- "$(dirname -- "$worker_def")" && pwd)" || return
       worker_code["$o"]="$base/$artifact"
       worker_type["$o"]="inline"
       execution="$(jq -r '(.execution // "INLINE")' "$worker_def")"
       worker_execution["$o"]="$execution"
       worker_def_map["$o"]="$worker_def"
       worker_start["$o"]="$(jq -r '(.lifecycle.start // "")' "$worker_def")"
       worker_poll["$o"]="$(jq -r '(.lifecycle.poll // "")' "$worker_def")"
       worker_stop["$o"]="$(jq -r '(.lifecycle.stop // "")' "$worker_def")"
       worker_keepalive["$o"]="$(jq -r 'if (.lifecycle.keepalive // false) then "1" else "0" end' "$worker_def")"
       worker_requires["$o"]="$(jq -r '(.runtime_requires // []) | join(" ")' "$worker_def")"
   fi
   if [[ "$worker_required" == true && -z "${worker_code[$o]:-}" ]]; then
       printf 'daloc: OBJECT %s (%s) requires WORKER CODE or descriptor default\n' "$o" "$type" >&2; return 36
   fi
   if [[ -n "${worker_code[$o]:-}" ]]; then
       [[ -r "${worker_code[$o]}" ]] || { printf 'daloc: WORKER CODE not readable: %s\n' "${worker_code[$o]}" >&2; return 37; }
       bash -n "${worker_code[$o]}" || return 38
       mode="${worker_type[$o]:-inline}"
       case "$mode" in
         inline|include) ;;
         *) printf 'daloc: OBJECT %s has invalid WORKER TYPE %s\n' "$o" "$mode" >&2; return 39 ;;
       esac
       local execution="${worker_execution[$o]:-INLINE}"
       jq -e --arg execution "$execution" '.execution | index($execution) != null' "$file" >/dev/null || {
           printf 'daloc: OBJECT %s (%s) does not allow execution mode %s\n' "$o" "$type" "$execution" >&2
           return 40
       }
   fi
 done
}
