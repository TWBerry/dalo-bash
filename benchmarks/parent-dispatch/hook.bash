# Handle a FIFO message addressed to this OBJECT.
# Parameters: $1 source OBJECT, $2 target OBJECT, $3 payload.
printf 'HOOK source=%s target=%s bytes=%d\n' "$1" "$2" "${#3}"
