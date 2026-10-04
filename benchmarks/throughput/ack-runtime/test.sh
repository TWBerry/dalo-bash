#!/usr/bin/env bash
# Exercise generic ACK bookkeeping, stale ACK isolation and library lifecycle.
# Parameters: $1 DALO repository root (defaults to current directory).
set -euo pipefail
ROOT="$(cd "${1:-.}" && pwd)"
export DALO_LIBRARY_PATH="$ROOT/runtime"
source "$ROOT/runtime/library.sh"
include ack
[[ "${DALO_LIBRARY_LOADED[ack]}" == 1 ]]
dalo_ack_register session1 child1 4
if dalo_ack_register session1 child1 4; then echo 'FAIL: reused pending ID' >&2; exit 1; else [[ $? -eq 3 ]]; fi
if dalo_ack_confirm oldsession child1 4; then echo 'FAIL: stale ACK accepted' >&2; exit 1; else [[ $? -eq 4 ]]; fi
dalo_ack_confirm session1 child1 4
if dalo_ack_confirm session1 child1 4; then echo 'FAIL: duplicate ACK accepted' >&2; exit 1; else [[ $? -eq 4 ]]; fi
dalo_ack_release session1 child1 4
[[ ${#DALO_ACK_PENDING[@]} -eq 0 ]]
dalo_ack_endpoint_accept session1 child1 4 sha256-a
if dalo_ack_endpoint_accept session1 child1 4 sha256-a; then echo 'FAIL: replay accepted as new' >&2; exit 1; else [[ $? -eq 10 ]]; fi
if dalo_ack_endpoint_accept session1 child1 4 sha256-b; then echo 'FAIL: conflicting replay accepted' >&2; exit 1; else [[ $? -eq 11 ]]; fi
dalo_ack_endpoint_accept session2 child1 4 sha256-a
[[ ${#DALO_ACK_APPLIED[@]} -eq 2 ]]
dalo_ack_close_instance session1
[[ ${#DALO_ACK_APPLIED[@]} -eq 1 ]]
# Check the loader's reverse-order FINI behavior, rather than sourcing ACK directly.
dalo_library_fini_all
[[ ${#DALO_ACK_APPLIED[@]} -eq 0 ]]
echo 'PASS: generic ACK library, stale/duplicate ACK, dedup, conflict, session isolation, FINI'
