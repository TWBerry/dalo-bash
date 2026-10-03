# Handle a parent FIFO message when no target-specific hook is installed.
# Parameters: $1 source OBJECT, $2 target OBJECT, $3 payload.
printf 'PARENT source=%s target=%s bytes=%d\n' "$1" "$2" "${#3}"
