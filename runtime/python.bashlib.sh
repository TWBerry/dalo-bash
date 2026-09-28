#!/usr/bin/env bash
DALO_LIBRARY_ABI=1
DALO_LIBRARY_NAME="python"
DALO_LIBRARY_VERSION="1.1.0"
DALO_LIBRARY_REQUIRES=""
DALO_LIBRARY_INIT="python_init"
[ "${DALO_PYTHON_INCLUDE:-0}" -eq 0 ] || return 0
DALO_PYTHON_INCLUDE=1
python_init(){
 local dir n i; dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"||return; n="${PYTHON_THREADS:-$(nproc)}"
 [[ "$n" =~ ^[1-9][0-9]*$ ]]||return 2; DALO_PY_ROOT="${DALO_PY_ROOT:-${TMPDIR:-/tmp}/dalo-python-${UID}}"; mkdir -p "$DALO_PY_ROOT"; chmod 700 "$DALO_PY_ROOT"
 # mkdir is the v1 inter-process bootstrap lock: atomic, portable, and off the request hot path.
 local lock="$DALO_PY_ROOT/start.lock" have_lock=0
 for((i=0;i<500;i++));do
  if mkdir "$lock" 2>/dev/null;then have_lock=1;break;fi
  [ -r "$DALO_PY_ROOT/ready" ] && [ -p "$DALO_PY_ROOT/request.fifo" ] && break
  sleep .01
 done
 if [ "$have_lock" -eq 1 ];then
  if [ ! -r "$DALO_PY_ROOT/ready" ] || [ ! -p "$DALO_PY_ROOT/request.fifo" ];then
   rm -f "$DALO_PY_ROOT/ready" "$DALO_PY_ROOT/request.fifo"
   python3 "$dir/python_supervisor.py" --root "$DALO_PY_ROOT" --workers "$n" </dev/null >>"$DALO_PY_ROOT/supervisor.log" 2>&1 & DALO_PY_SUPERVISOR_PID=$!
   for((i=0;i<500;i++));do [ -r "$DALO_PY_ROOT/ready" ]&&[ -p "$DALO_PY_ROOT/request.fifo" ]&&break;sleep .01;done
  fi
  rmdir "$lock" 2>/dev/null || true
 fi
 [ -p "$DALO_PY_ROOT/request.fifo" ]||return 1
 DALO_PY_SESSION="$DALO_PY_ROOT/session-${BASHPID}-${RANDOM}-${RANDOM}"; mkdir -m 700 "$DALO_PY_SESSION"||return
 mkfifo -m 600 "$DALO_PY_SESSION/in" "$DALO_PY_SESSION/out"||return
 exec {DALO_PY_INFD}<>"$DALO_PY_SESSION/in"; exec {DALO_PY_OUTFD}<>"$DALO_PY_SESSION/out"
 # REGISTER is deliberately the only shared-FIFO record and remains far below PIPE_BUF.
 printf 'REGISTER|%s|%s|%s\n' "$BASHPID" "$DALO_PY_SESSION/in" "$DALO_PY_SESSION/out" >"$DALO_PY_ROOT/request.fifo"
}
__python_request(){
 local payload="$1" outvar="${2:-}" rid="$(( (BASHPID << 32) ^ (RANDOM << 16) ^ RANDOM ))" delim marker h v typ rr plen response
 # Request ABI v1.1: Bash cannot portably obtain UTF-8 byte lengths without a subprocess.
 # Each session has a private FIFO, so frame requests with a per-request ASCII delimiter.
 # Regenerate the delimiter if the complete marker occurs in the payload.
 while :;do
  delim="DALO_PY_END_${BASHPID}_${rid}_${RANDOM}_${RANDOM}"
  marker=$'\n'"$delim"$'\n'
  [[ "$payload" == *"$marker"* ]]||break
 done
 printf 'DALO-PY|1.1|REQ|%s|%s\n%s%s' "$rid" "$delim" "$payload" "$marker" >&$DALO_PY_INFD
 # Responses intentionally retain the v1 byte-length frame ABI.
 IFS='|' read -r h v typ rr plen <&$DALO_PY_OUTFD||return 1
 [ "$h|$v|$typ|$rr" = "DALO-PY|1|RESP|$rid" ]||return 1
 IFS= read -r -N "$plen" response <&$DALO_PY_OUTFD || return 1
 if [ -n "$outvar" ];then printf -v "$outvar" '%s' "$response";else printf '%s' "$response";fi
 DALO_PY_LAST_REQUEST_ID="$rid"
}
init_python_thread(){ __python_request $'RESERVE\n'; }
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
