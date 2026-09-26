#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DALO_LIBRARY_PATH="$ROOT/compiler:$ROOT/runtime"
export DALO_LIBRARY_PATH
source "$ROOT/runtime/library.sh"
include compiler-parser
include compiler-definitions
include compiler-connect
include compiler-linker

[[ $# -eq 1 ]] || { printf 'usage: %s PROJECT.dalo\n' "${0##*/}" >&2; exit 2; }
input="$1"
dalo_definitions_load_tree "$ROOT"
dalo_parse_project "$input" DALO_IR
dalo_definition_validate_ir DALO_IR
dalo_connect_lower_all DALO_IR
name="${DALO_IR_NAME}"
out="$(dirname -- "$input")/${name}.dalo.bash"
dalo_link_machine "$ROOT" DALO_IR "$out"
printf '%s\n' "$out"
