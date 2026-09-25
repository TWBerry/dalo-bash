#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/runtime/dalo.bash"
for f in "$ROOT"/definitions/objects/*.json; do async_object_definition_register "$f"; done
[[ "$(async_object_definition_port PIPE in direction)" == input ]]
[[ "$(async_object_definition_port PIPE out direction)" == output ]]
[[ "$(async_object_definition_port T out2 plane)" == data ]]
async_object_definition_worker_required PIPE
! async_object_definition_worker_required T
async_object_definition_execution_allowed PIPE ASYNC
! async_object_definition_execution_allowed T ASYNC
declare -a DALO_TEST_DECL_OBJECTS=(source pipe sink)
declare -A DALO_TEST_DECL_TYPE=([source]=ORIGIN [pipe]=PIPE [sink]=ENDPOINT)
declare -a DALO_TEST_EDGES=($'source\tout\tpipe\tin' $'pipe\tout\tsink\tin')
async_project_validate_definitions DALO_TEST
DALO_TEST_EDGES+=($'source\tout\tsink\tmissing')
! async_project_validate_definitions DALO_TEST 2>/dev/null
echo DALO_OBJECT_DEFINITION_PASS
printf 'PIPE_FEATURES=%s\n' "$(async_object_definition_list PIPE features | paste -sd, -)"
