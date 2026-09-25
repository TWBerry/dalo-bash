#!/usr/bin/env bash
set -euo pipefail
H="$(cd "$(dirname "$0")" && pwd)"
source "$H/async_library_object_definition_step35.bash"
for f in "$H"/object_definitions_step35/*.json; do
    async_object_definition_register "$f"
done

[[ "$(async_object_definition_port PIPE in direction)" == input ]]
[[ "$(async_object_definition_port PIPE out direction)" == output ]]
[[ "$(async_object_definition_port T out2 plane)" == data ]]
async_object_definition_worker_required PIPE
! async_object_definition_worker_required T
async_object_definition_execution_allowed PIPE ASYNC
! async_object_definition_execution_allowed T ASYNC

# Isolated PROJECT metadata: test the new ABI without invoking legacy constructors.
declare -a P35_DECL_OBJECTS=(source pipe sink)
declare -A P35_DECL_TYPE=([source]=ORIGIN [pipe]=PIPE [sink]=ENDPOINT)
declare -a P35_EDGES=($'source\tout\tpipe\tin' $'pipe\tout\tsink\tin')
async_project_validate_definitions P35

P35_EDGES+=($'source\tout\tsink\tmissing')
! async_project_validate_definitions P35

echo STEP35_OBJECT_DEFINITION_PASS
printf 'PIPE_FEATURES=%s\n' "$(async_object_definition_list PIPE features | paste -sd, -)"
