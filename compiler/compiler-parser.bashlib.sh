DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="compiler-parser"
DALO_LIBRARY_VERSION="1.0.0"
DALO_LIBRARY_REQUIRES="compiler-ir"

[ "${DALO_COMPILER_PARSER_INCLUDE:-0}" -eq 0 ] || return 0
DALO_COMPILER_PARSER_INCLUDE=1

dalo_parse_project() {
    [ $# -eq 2 ] || return 2
    local file="$1" ir="$2" raw line indent text key value current="" current_object="" lineno=0
    local project_dir
    project_dir="$(cd -- "$(dirname -- "$file")" && pwd)" || return
    [[ -r "$file" ]] || { printf 'daloc: cannot read %s\n' "$file" >&2; return 3; }
    dalo_ir_init "$ir"

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        ((++lineno))
        raw="${raw%$'\r'}"
        [[ "$raw" =~ ^[[:space:]]*$ || "$raw" =~ ^[[:space:]]*# ]] && continue
        if [[ "$raw" == *"    "* && "$raw" =~ ^[[:space:]] ]]; then
            printf 'daloc:%d: indentation must use TABs\n' "$lineno" >&2; return 10
        fi
        indent=0; line="$raw"
        while [[ "$line" == $'\t'* ]]; do ((++indent)); line="${line#$'\t'}"; done
        [[ "$line" != *$'\t'* ]] || { printf 'daloc:%d: TAB allowed only for indentation\n' "$lineno" >&2; return 11; }
        text="$line"

        if ((indent==0)); then
            current=""; current_object=""
            case "$text" in
                PROJECT) current="PROJECT" ;;
                OBJECT\ *)
                    value="${text#OBJECT }"
                    [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { printf 'daloc:%d: invalid OBJECT name\n' "$lineno" >&2; return 12; }
                    dalo_ir_add_object "$ir" "$value" || return
                    current="OBJECT"; current_object="$value"
                    ;;
                CONNECT\ *) dalo_ir_add_connect_text "$ir" "${text#CONNECT }" || return ;;
                *) printf 'daloc:%d: unknown top-level statement: %s\n' "$lineno" "$text" >&2; return 13 ;;
            esac
            continue
        fi

        if ((indent==1)); then
            if [[ "$current" == OBJECT && "$text" == WORKER ]]; then
                current="WORKER"
                continue
            fi
            key="${text%% *}"; value="${text#"$key"}"; value="${value# }"
            case "$current" in
                PROJECT)
                    case "$key" in
                        NAME) dalo_ir_set_project_name "$ir" "$value" ;;
                        VERSION) dalo_ir_set_project_version "$ir" "$value" ;;
                        *) printf 'daloc:%d: unknown PROJECT field %s\n' "$lineno" "$key" >&2; return 15 ;;
                    esac ;;
                OBJECT)
                    case "$key" in
                        TYPE) dalo_ir_set_object_type "$ir" "$current_object" "$value" ;;
                        [A-Z][A-Z0-9_]*) dalo_ir_set_object_field "$ir" "$current_object" "$key" "$value" ;;
                        *) printf 'daloc:%d: invalid OBJECT field %s\n' "$lineno" "$key" >&2; return 16 ;;
                    esac ;;
                WORKER)
                    # A one-tab line after WORKER closes that block and is again
                    # interpreted as an OBJECT field.
                    current="OBJECT"
                    case "$key" in
                        TYPE) dalo_ir_set_object_type "$ir" "$current_object" "$value" ;;
                        [A-Z][A-Z0-9_]*) dalo_ir_set_object_field "$ir" "$current_object" "$key" "$value" ;;
                        *) printf 'daloc:%d: invalid OBJECT field %s\n' "$lineno" "$key" >&2; return 16 ;;
                    esac ;;
                *) printf 'daloc:%d: indented field without PROJECT/OBJECT\n' "$lineno" >&2; return 17 ;;
            esac
            continue
        fi

        if ((indent==2)) && [[ "$current" == WORKER ]]; then
            key="${text%% *}"; value="${text#"$key"}"; value="${value# }"
            case "$key" in
                CODE)
                    [[ -n "$value" ]] || { printf 'daloc:%d: WORKER CODE is empty\n' "$lineno" >&2; return 18; }
                    [[ "$value" == /* ]] || value="$project_dir/$value"
                    dalo_ir_set_worker_code "$ir" "$current_object" "$value"
                    ;;
                TYPE)
                    case "$value" in inline|include) dalo_ir_set_worker_type "$ir" "$current_object" "$value" ;;
                        *) printf 'daloc:%d: WORKER TYPE must be inline or include\n' "$lineno" >&2; return 19 ;;
                    esac ;;
                EXECUTION)
                    case "$value" in INLINE|ASYNC|PERSISTENT) dalo_ir_set_worker_execution "$ir" "$current_object" "$value" ;;
                        *) printf 'daloc:%d: WORKER EXECUTION must be INLINE, ASYNC, or PERSISTENT\n' "$lineno" >&2; return 19 ;;
                    esac ;;
                *) printf 'daloc:%d: unknown WORKER field %s\n' "$lineno" "$key" >&2; return 19 ;;
            esac
            continue
        fi

        printf 'daloc:%d: unsupported nesting depth %d\n' "$lineno" "$indent" >&2
        return 14
    done < "$file"
    dalo_ir_validate_header "$ir"
}
