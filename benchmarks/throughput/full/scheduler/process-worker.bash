#!/usr/bin/env bash
# Persistent benchmark control worker. Not a substitute for DALO transport.
# Parameters: $1 zero-based lane identifier, supplied at process startup.
lane="${1:-}"
[[ "$lane" =~ ^[0-3]$ ]] || exit 64
while IFS=$'\t' read -r seq payload; do
    [[ "$seq" =~ ^[1-9][0-9]*$ && "$payload" =~ ^[a-zA-Z0-9_.-]*$ ]] || exit 65
    printf '%s\t%s\n' "$seq" "$BASHPID" || exit 74
done
