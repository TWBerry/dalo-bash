#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/runtime/dalo.bash"
for f in "$ROOT"/definitions/objects/*.json; do async_object_definition_register "$f"; done
for f in "$ROOT"/definitions/workers/*.json; do async_worker_definition_register "$f"; done
async_worker_definition_has passthrough
[[ "$(async_worker_definition_field passthrough language)" == bash ]]
async_worker_definition_object_allowed passthrough PIPE
! async_worker_definition_object_allowed passthrough T
async_worker_definition_validate_for_object passthrough ORIGIN
async_worker_definition_validate_for_object passthrough PIPE
async_worker_definition_validate_for_object passthrough ENDPOINT
! async_worker_definition_validate_for_object passthrough T
cp "$ROOT/definitions/workers/passthrough.json" "$ROOT/definitions/workers/.bad-hash.json"
jq '.sha256="0000000000000000000000000000000000000000000000000000000000000000"' "$ROOT/definitions/workers/.bad-hash.json" > "$ROOT/definitions/workers/.bad-hash.tmp"
mv "$ROOT/definitions/workers/.bad-hash.tmp" "$ROOT/definitions/workers/.bad-hash.json"
! async_worker_definition_register "$ROOT/definitions/workers/.bad-hash.json" 2>/dev/null
rm -f "$ROOT/definitions/workers/.bad-hash.json"
echo DALO_WORKER_DEFINITION_PASS
