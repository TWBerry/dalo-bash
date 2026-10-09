#!/usr/bin/env bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="python"
DALO_LIBRARY_VERSION="1.1.0"
DALO_LIBRARY_REQUIRES=""
DALO_LIBRARY_INIT="python_init"
DALO_LIBRARY_FINI="python_shutdown"
DALO_LIBRARY_ARTIFACTS="python_supervisor.py"
[ "${DALO_PYTHON_INCLUDE:-0}" -eq 0 ] || return 0
DALO_PYTHON_INCLUDE=1
# Start or attach to a verified supervisor, recovering only demonstrably stale state.
# Parameters: none; PYTHON_THREADS and DALO_PY_ROOT configure the requested instance.
python_init(){
 local supervisor n i lock have_lock=0 oldpid='' reply='' instance='' capacity='' ping='' recovery_token='' start_time
 dalo_library_artifact_path python python_supervisor.py supervisor || return
 n="${PYTHON_THREADS:-$(nproc)}"
 [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 2
 DALO_PY_ROOT="${DALO_PY_ROOT:-${TMPDIR:-/tmp}/dalo-python-${UID}}"
 mkdir -p "$DALO_PY_ROOT" || return
 chmod 700 "$DALO_PY_ROOT" || return
 lock="$DALO_PY_ROOT/start.lock"
 for ((i=0;i<500;i++)); do
  if mkdir "$lock" 2>/dev/null; then
   have_lock=1
   printf '%s\n' "$BASHPID" >"$lock/owner.pid"
   break
  fi
  # A lock without a live owner may be reclaimed after a grace period.
  # Never remove a lock belonging to a live process.
  oldpid=''
  if [ -r "$lock/owner.pid" ]; then IFS= read -r oldpid <"$lock/owner.pid" || oldpid=''; fi
  if [[ "$oldpid" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$oldpid" 2>/dev/null; then
   python3 - "$lock" <<'PYLOCK'
import os, sys, time
p=sys.argv[1]
try:
    if time.time()-os.stat(p).st_mtime > 2:
        os.unlink(p+'/owner.pid')
        os.rmdir(p)
except (OSError, ValueError):
    pass
PYLOCK
  fi
  sleep .01
 done
 if [ "$have_lock" -ne 1 ]; then
  printf 'python_init: bootstrap lock timed out: %s\n' "$lock" >&2
  return 1
 fi
 # Under the bootstrap lock, never replace a process which is still alive.
 oldpid=''
 if [ -r "$DALO_PY_ROOT/supervisor.pid" ]; then
  IFS= read -r oldpid <"$DALO_PY_ROOT/supervisor.pid" || oldpid=''
 fi
 if [[ "$oldpid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$oldpid" 2>/dev/null; then
  if [ ! -r "$DALO_PY_ROOT/ready" ] || [ ! -p "$DALO_PY_ROOT/request.fifo" ]; then
   printf 'python_init: supervisor PID %s is alive but not ready; refusing unsafe cleanup\n' "$oldpid" >&2
   rm -f "$lock/owner.pid"; rmdir "$lock" 2>/dev/null || true
   return 1
  fi
 else
  # Stale state: the recorded supervisor is dead (or was never started).
  rm -f "$DALO_PY_ROOT/ready" "$DALO_PY_ROOT/request.fifo" "$DALO_PY_ROOT/supervisor.pid"
  python3 "$supervisor" --root "$DALO_PY_ROOT" --workers "$n" </dev/null >>"$DALO_PY_ROOT/supervisor.log" 2>&1 &
  DALO_PY_SUPERVISOR_PID=$!
  for ((i=0;i<500;i++)); do
   [ -r "$DALO_PY_ROOT/ready" ] && [ -p "$DALO_PY_ROOT/request.fifo" ] && break
   kill -0 "$DALO_PY_SUPERVISOR_PID" 2>/dev/null || break
   sleep .01
  done
 fi
 rm -f "$lock/owner.pid"; rmdir "$lock" 2>/dev/null || true
 [ -r "$DALO_PY_ROOT/ready" ] && [ -p "$DALO_PY_ROOT/request.fifo" ] || return 1
 DALO_PY_SESSION_STATE=READY
 DALO_PY_SESSION_ERROR=''
 DALO_PY_SESSION="$DALO_PY_ROOT/session-${BASHPID}-${RANDOM}-${RANDOM}"
 mkdir -m 700 "$DALO_PY_SESSION" || return
 if ! mkfifo -m 600 "$DALO_PY_SESSION/in" "$DALO_PY_SESSION/out"; then
  rm -rf -- "$DALO_PY_SESSION"; unset DALO_PY_SESSION; return 1
 fi
 if ! exec {DALO_PY_INFD}<>"$DALO_PY_SESSION/in" || ! exec {DALO_PY_OUTFD}<>"$DALO_PY_SESSION/out"; then
  __python_session_cleanup; return 1
 fi
 if ! printf 'REGISTER|%s|%s|%s\n' "$BASHPID" "$DALO_PY_SESSION/in" "$DALO_PY_SESSION/out" >"$DALO_PY_ROOT/request.fifo"; then
  __python_session_cleanup; return 1
 fi
 # The first framed request proves that this instance is responsive and
 # advertises its actual worker capacity (not the caller's requested value).
 if ! __python_request $'PING\n' reply; then
  printf 'python_init: supervisor did not answer PING\n' >&2
  __python_session_cleanup; return 1
 fi
 IFS='|' read -r ping instance capacity recovery_token <<<"${reply%%$'\n'*}"
 if [ "$ping" != OK ] || ! [[ "$capacity" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "$instance" =~ ^[0-9a-f]{32}$ ]] || ! [[ "$recovery_token" =~ ^[0-9a-f]{64}$ ]]; then
  printf 'python_init: invalid supervisor PING: %s\n' "$reply" >&2
  __python_session_cleanup; return 1
 fi
 DALO_PY_INSTANCE="$instance"
 DALO_PY_RECOVERY_TOKEN="$recovery_token"
 DALO_PY_SUPERVISOR_IDENTITY_PID=''
 if [ -r "$DALO_PY_ROOT/supervisor.pid" ]; then
  IFS= read -r DALO_PY_SUPERVISOR_IDENTITY_PID <"$DALO_PY_ROOT/supervisor.pid" || DALO_PY_SUPERVISOR_IDENTITY_PID=''
 fi
 if (( capacity < n )); then
  printf 'python_init: supervisor has %s slots; requested %s; use a fresh DALO_PY_ROOT or stop its clients\n' "$capacity" "$n" >&2
  __python_request "SHUTDOWN|$instance"$'\n' reply >/dev/null 2>&1 || true
  __python_session_cleanup; return 1
 fi
}

# Close and remove only the current client's private session resources.
# Parameters: none.
__python_session_cleanup(){
 if [ -n "${DALO_PY_INFD:-}" ]; then eval "exec ${DALO_PY_INFD}>&-" 2>/dev/null || true; unset DALO_PY_INFD; fi
 if [ -n "${DALO_PY_OUTFD:-}" ]; then eval "exec ${DALO_PY_OUTFD}>&-" 2>/dev/null || true; unset DALO_PY_OUTFD; fi
 if [ -n "${DALO_PY_SESSION:-}" ]; then rm -f -- "$DALO_PY_SESSION/in" "$DALO_PY_SESSION/out"; rmdir -- "$DALO_PY_SESSION" 2>/dev/null || true; unset DALO_PY_SESSION; fi
}

python_shutdown(){
 [ -n "${DALO_PY_ROOT:-}" ] || return 0
 local instance reply='' supervisor_pid='' rc=0 i
 if [ -r "$DALO_PY_ROOT/supervisor.pid" ];then IFS= read -r supervisor_pid <"$DALO_PY_ROOT/supervisor.pid" || supervisor_pid=''; fi
 if [ -r "$DALO_PY_ROOT/ready" ] && [ -n "${DALO_PY_INFD:-}" ] && [ -n "${DALO_PY_OUTFD:-}" ];then
  IFS= read -r instance <"$DALO_PY_ROOT/ready" || instance=''
  if [ -n "$instance" ];then
   reply=''; __python_request "SHUTDOWN|$instance"$'\n' reply || rc=$?
   [[ "$reply" == OK\|SHUTDOWN\|* ]] || rc=1
  fi
 fi
 __python_session_cleanup
 # Only the final client waits for shared supervisor teardown. Other clients
 # must not interfere with active sessions or wait for a process they do not own.
 if [[ "$reply" == OK\|SHUTDOWN\|*\|LAST ]];then
  for((i=0;i<500;i++));do
   [ ! -e "$DALO_PY_ROOT/ready" ] && [ ! -e "$DALO_PY_ROOT/request.fifo" ] && break
   sleep .01
  done
  if [ -e "$DALO_PY_ROOT/ready" ] || [ -e "$DALO_PY_ROOT/request.fifo" ];then
   printf 'python_shutdown: final supervisor teardown timed out: %s\n' "$DALO_PY_ROOT" >&2
   rc=1
  fi
 fi
 unset DALO_PY_SESSION DALO_PY_SUPERVISOR_PID DALO_PY_INSTANCE DALO_PY_RECOVERY_TOKEN DALO_PY_SUPERVISOR_IDENTITY_PID
 return "$rc"
}
# Fence the current session after an ambiguous request outcome.
# Parameters: $1 is the diagnostic reason. The previous lease state remains
# unknown until the supervisor has independently confirmed session teardown.
__python_fence_session(){
 local reason="${1:-UNKNOWN}"
 DALO_PY_SESSION_STATE=UNCERTAIN
 DALO_PY_SESSION_ERROR="$reason"
 __python_session_cleanup
 printf 'DALO-PY: session fenced (%s); previous leases are UNCERTAIN\n' "$reason" >&2
}

# Send one framed request and read its complete matching response.
# Parameters: $1 is the request payload; optional $2 names the output variable.
# DALO_PY_REQUEST_TIMEOUT is a positive integer timeout in seconds for each
# blocking read. A timeout or malformed frame permanently fences this session.
__python_request(){
 local payload="${1:-}" outvar="${2:-}" rid delim marker h v typ rr plen response timeout
 if [ "${DALO_PY_SESSION_STATE:-READY}" != READY ] ||
    [ -z "${DALO_PY_INFD:-}" ] || [ -z "${DALO_PY_OUTFD:-}" ]; then
  printf 'DALO-PY: no healthy session; reconnect requires reconciliation\n' >&2
  return 1
 fi
 timeout="${DALO_PY_REQUEST_TIMEOUT:-5}"
 if ! [[ "$timeout" =~ ^[1-9][0-9]*$ ]]; then
  printf 'DALO-PY: invalid DALO_PY_REQUEST_TIMEOUT: %s\n' "$timeout" >&2
  return 2
 fi
 rid="$(( (BASHPID << 32) ^ (RANDOM << 16) ^ RANDOM ))"
 while :; do
  delim="DALO_PY_END_${BASHPID}_${rid}_${RANDOM}_${RANDOM}"
  marker=$'\n'"$delim"$'\n'
  [[ "$payload" == *"$marker"* ]] || break
 done
 if ! printf 'DALO-PY|1.1|REQ|%s|%s\n%s%s' "$rid" "$delim" "$payload" "$marker" >&"$DALO_PY_INFD"; then
  __python_fence_session WRITE_FAILED
  return 1
 fi
 # Both reads are bounded. A partial response is never reused by a later call.
 if ! IFS='|' read -r -t "$timeout" h v typ rr plen <&"$DALO_PY_OUTFD"; then
  __python_fence_session HEADER_TIMEOUT_OR_EOF
  return 1
 fi
 if [ "$h|$v|$typ|$rr" != "DALO-PY|1|RESP|$rid" ] ||
    ! [[ "$plen" =~ ^(0|[1-9][0-9]*)$ ]] || (( plen > 16777216 )); then
  __python_fence_session INVALID_RESPONSE_HEADER
  return 1
 fi
 response=''
 if (( plen > 0 )); then
  if ! IFS= read -r -N "$plen" -t "$timeout" response <&"$DALO_PY_OUTFD"; then
   __python_fence_session BODY_TIMEOUT_OR_EOF
   return 1
  fi
 fi
 if [ -n "$outvar" ]; then printf -v "$outvar" '%s' "$response"; else printf '%s' "$response"; fi
 DALO_PY_LAST_REQUEST_ID="$rid"
}

# Reconnect a fenced client through a new session, then revoke its old leases.
# Parameters: none. Requires a recovery token from the previous PING.
# On any ambiguous outcome the new session is fenced; no old handle is reused.
python_reconnect(){
 local old_instance old_token old_pid new_instance reply='' current_pid=''
 [ "${DALO_PY_SESSION_STATE:-}" = UNCERTAIN ] || {
  printf 'DALO-PY: reconnect requires an UNCERTAIN session\n' >&2
  return 2
 }
 old_instance="${DALO_PY_INSTANCE:-}"
 old_token="${DALO_PY_RECOVERY_TOKEN:-}"
 old_pid="${DALO_PY_SUPERVISOR_IDENTITY_PID:-}"
 if ! [[ "$old_instance" =~ ^[0-9a-f]{32}$ ]] ||
    ! [[ "$old_token" =~ ^[0-9a-f]{64}$ ]]; then
  printf 'DALO-PY: missing valid recovery identity; refusing reconnect\n' >&2
  return 1
 fi
 # Preserve the prior identity until a new connection has been established.
 # python_init creates a private FIFO session and authenticates its PING.
 if ! python_init; then
  DALO_PY_INSTANCE="$old_instance"
  DALO_PY_RECOVERY_TOKEN="$old_token"
  DALO_PY_SUPERVISOR_IDENTITY_PID="$old_pid"
  DALO_PY_SESSION_STATE=UNCERTAIN
  return 1
 fi
 new_instance="$DALO_PY_INSTANCE"
 if [ "$new_instance" = "$old_instance" ]; then
  if ! __python_request "RECOVER|$old_instance|$old_token"$'\n' reply ||
     [ "$reply" != "OK|RECOVER|$old_instance|DETACHED"$'\n' ]; then
   __python_fence_session RECOVERY_NOT_CONFIRMED
   return 1
  fi
 else
  # A changed instance alone does not prove the previous supervisor exited.
  # Reject a potential split-brain while the old PID is still observable.
  if [[ "$old_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$old_pid" 2>/dev/null; then
   __python_fence_session OLD_SUPERVISOR_STILL_ALIVE
   return 1
  fi
 fi
 DALO_PY_SESSION_STATE=READY
 DALO_PY_SESSION_ERROR=''
 return 0
}

init_python_thread(){ __python_request $'RESERVE\n'; }
# Pin a reserved Python worker process to one CPU through its supervisor.
# Parameters: $1 is the current worker handle; $2 is a nonnegative logical CPU ID.
# The supervisor validates the lease and generation before changing affinity.
set_python_thread_cpu(){
 local h="${1:-}" cpu="${2:-}" ok inst slot gen lease reply
 [ "$#" -eq 2 ] && [[ "$cpu" =~ ^(0|[1-9][0-9]*)$ ]] || return 2
 IFS='|' read -r ok inst slot gen lease <<<"$h"
 [ "$ok" = OK ] && [ -n "$lease" ] || return 2
 __python_request "AFFINITY|$inst|$slot|$gen|$lease|$cpu"$'\n' reply || return
 case "$reply" in OK\|AFFINITY\|*) printf '%s' "$reply";; *) printf '%s' "$reply" >&2; return 1;; esac
}
stop_python_thread(){ local h="$1" ok inst slot gen lease; IFS='|' read -r ok inst slot gen lease<<<"$h"; __python_request "STOP|$inst|$slot|$gen|$lease"$'\n'; }
release_python_thread(){ local h="$1" ok inst slot gen lease; IFS='|' read -r ok inst slot gen lease<<<"$h"; __python_request "RELEASE|$inst|$slot|$gen|$lease"$'\n'; }
python_job_status(){ [ $# -eq 1 ]||return 2; __python_request "STATUS|$1"$'\n'; }
inline_python(){
 local mode=EVAL handle='' async=0 opt code ok inst slot gen lease r line st rl ol el body result out err flags=0 OPTIND=1
 while getopts ':t:xa' opt;do case $opt in t)handle=$OPTARG;;x)mode=EXEC;;a)async=1;;*)return 2;;esac;done;shift $((OPTIND-1));[ $# -eq 1 ]||return 2;code=$1
 [ "$async" -eq 0 ] || [ "$mode" = EXEC ] || { printf 'inline_python: -a requires -x\n' >&2;return 2; }
 if [ -z "$handle" ];then handle="$(init_python_thread)"||return;fi; IFS='|' read -r ok inst slot gen lease<<<"$handle";[ "$ok" = OK ]||return 1
 [ "$async" -eq 1 ]&&flags=1
 __python_request "$mode|$inst|$slot|$gen|$lease|-|$flags"$'\n'"$code" r||return
 if [ "$async" -eq 1 ];then
  line=${r%%$'\n'*}; IFS='|' read -r ok st inst slot gen<<<"$line"; [ "$ok" = ACCEPTED ]||{ printf '%s\n' "$r" >&2;return 1;}; printf '%s\n' "$st"; return 0
 fi
 line=${r%%$'\n'*};IFS='|' read -r ok st rl ol el<<<"$line"
 [ "$ok" = DONE ]||{ printf '%s\n' "$r" >&2;return 1;};body=${r#*$'\n'};result=${body:0:rl};out=${body:rl:ol};err=${body:rl+ol:el};[ -n "$out" ]&&printf '%s' "$out" >&2;[ -n "$err" ]&&printf '%s' "$err" >&2;[ "$st" = OK ]||return 1;[ "$mode" = EVAL ]&&printf '%s\n' "$result"; return 0
}
