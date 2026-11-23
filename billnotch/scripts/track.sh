#!/bin/sh
# BillNotch passive tracking for Claude Code.
#
# Called by the plugin's hooks with the hook payload on stdin. It turns a session
# into blocks of active time: a block opens on a prompt, stays open while prompts
# keep arriving within the idle cutoff, and covers the whole of each turn however
# long Claude works. Closed blocks are queued on disk and uploaded to BillNotch's
# idempotent batch endpoint, so a retry or a crash never double-counts.
#
# What leaves the machine: the project folder name, the git branch, start and end
# times. Never prompts, code, file names or the transcript.
#
# This script must stay silent: stdout from SessionStart and UserPromptSubmit
# hooks is added to Claude's context. It always exits 0 so tracking can never
# block a prompt.

exec 2>/dev/null

input=$(cat)

KEY=${CLAUDE_PLUGIN_OPTION_API_KEY:-}
API=${CLAUDE_PLUGIN_OPTION_API_URL:-https://api.billnotch.com}
API=${API%/}
DATA=${CLAUDE_PLUGIN_DATA:-}

case "${CLAUDE_PLUGIN_OPTION_AUTO_TRACK:-true}" in
  false | False | FALSE | 0 | no | off) exit 0 ;;
esac
[ -n "$KEY" ] && [ -n "$DATA" ] || exit 0

IDLE_MIN=${CLAUDE_PLUGIN_OPTION_IDLE_MINUTES:-5}
case "$IDLE_MIN" in
  '' | *[!0-9]*) IDLE_MIN=5 ;;
esac
[ "$IDLE_MIN" -ge 1 ] || IDLE_MIN=1
IDLE=$((IDLE_MIN * 60))

MIN_BLOCK=60         # blocks shorter than this are noise, not work
CRASHED_AFTER=21600  # a turn "running" this long belongs to a session that died
QUEUE_TTL_DAYS=30    # undeliverable blocks are dropped after this
BATCH=200

SESSIONS=$DATA/sessions
QUEUE=$DATA/queue
mkdir -p "$SESSIONS" "$QUEUE" || exit 0

field() {
  printf '%s' "$input" | tr -d '\n' |
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

event=$(field hook_event_name)
sid=$(field session_id | tr -cd 'A-Za-z0-9_-')
[ -n "$event" ] && [ -n "$sid" ] || exit 0

now=$(date +%s)
state=$SESSIONS/$sid

# Keep only characters that are safe inside a JSON string and a file name.
clean() { printf '%s' "$1" | tr -c 'A-Za-z0-9._/-' '-' | cut -c1-120; }

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

sha1() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum; else shasum -a 1; fi | cut -c1-32
}

# A stable UUID per (session, block start): re-uploading a block is a no-op.
event_id() {
  h=$(printf 'billnotch-claude-code|%s|%s' "$1" "$2" | sha1)
  printf '%s-%s-5%s-8%s-%s' \
    "$(printf '%s' "$h" | cut -c1-8)" "$(printf '%s' "$h" | cut -c9-12)" \
    "$(printf '%s' "$h" | cut -c14-16)" "$(printf '%s' "$h" | cut -c18-20)" \
    "$(printf '%s' "$h" | cut -c21-32)"
}

read_state() {
  s_start=$(sed -n 's/^start=//p' "$1")
  s_last=$(sed -n 's/^last=//p' "$1")
  s_busy=$(sed -n 's/^busy=//p' "$1")
  s_label=$(sed -n 's/^label=//p' "$1")
  s_project=$(sed -n 's/^project=//p' "$1")
  s_billable=$(sed -n 's/^billable=//p' "$1")
  case "$s_start$s_last" in
    '' | *[!0-9]*) return 1 ;;
  esac
}

write_state() {
  tmp=$state.$$
  {
    printf 'start=%s\nlast=%s\nbusy=%s\n' "$s_start" "$s_last" "$s_busy"
    printf 'label=%s\nproject=%s\nbillable=%s\n' "$s_label" "$s_project" "$s_billable"
  } >"$tmp" && mv -f "$tmp" "$state"
}

# Queue the block held in s_* for the session id in $1, then forget its state.
close_block() {
  if [ $((s_last - s_start)) -ge "$MIN_BLOCK" ]; then
    id=$(event_id "$1" "$s_start")
    extra=
    case "$s_project" in
      ????????-????-????-????-????????????)
        billable=false
        [ "$s_billable" = true ] && billable=true
        extra=',"projectId":"'$s_project'","isBillable":'$billable
        ;;
    esac
    printf '{"activity":"Claude Code: %s","startedAt":"%s","endedAt":"%s","clientEventId":"%s","source":"agent"%s}\n' \
      "$s_label" "$(iso "$s_start")" "$(iso "$s_last")" "$id" "$extra" >"$QUEUE/$id.json.tmp" &&
      mv -f "$QUEUE/$id.json.tmp" "$QUEUE/$id.json"
  fi
  rm -f "$SESSIONS/$1"
}

# What this block is called, and the project the repo is linked to (if any).
describe() {
  dir=${CLAUDE_PROJECT_DIR:-$PWD}
  s_label=$(clean "$(basename "$dir")")
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  [ -n "$branch" ] && [ "$branch" != HEAD ] && s_label="$s_label ($(clean "$branch"))"
  s_project=
  s_billable=
  if [ -f "$dir/.billnotch.json" ]; then
    link=$(tr -d '\n' <"$dir/.billnotch.json")
    s_project=$(printf '%s' "$link" |
      sed -n 's/.*"projectId"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F-]\{36\}\)".*/\1/p')
    printf '%s' "$link" | tr -d ' \t' | grep -q '"billable":true' && s_billable=true
  fi
}

# Close blocks left behind by other sessions that have gone quiet or died.
sweep() {
  for f in "$SESSIONS"/*; do
    [ -f "$f" ] || continue
    other=$(basename "$f")
    [ "$other" = "$sid" ] && continue
    case "$other" in *.[0-9]*) continue ;; esac
    read_state "$f" || { rm -f "$f"; continue; }
    quiet=$((now - s_last))
    if [ "$s_busy" = 1 ]; then
      [ "$quiet" -gt "$CRASHED_AFTER" ] && close_block "$other"
    elif [ "$quiet" -gt "$IDLE" ]; then
      close_block "$other"
    fi
  done
}

upload() {
  find "$QUEUE" -name '*.json' -mtime +"$QUEUE_TTL_DAYS" -exec rm -f {} + 2>/dev/null
  set -- "$QUEUE"/*.json
  [ -f "$1" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0

  body=$QUEUE/.batch.$$
  sent=$QUEUE/.sent.$$
  : >"$sent"
  printf '{"entries":[' >"$body"
  n=0
  for f in "$@"; do
    [ "$n" -lt "$BATCH" ] || break
    [ "$n" -gt 0 ] && printf ',' >>"$body"
    tr -d '\n' <"$f" >>"$body"
    printf '%s\n' "$f" >>"$sent"
    n=$((n + 1))
  done
  printf ']}' >>"$body"

  code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    --data-binary "@$body" "$API/time-entries/batch")
  # Anything but success leaves the blocks queued for the next attempt.
  case "$code" in
    2??) while IFS= read -r f; do rm -f "$f"; done <"$sent" ;;
  esac
  rm -f "$body" "$sent"
}

upload_detached() { (upload </dev/null >/dev/null 2>&1 &); }

case "$event" in
  SessionStart)
    sweep
    upload_detached
    ;;

  UserPromptSubmit)
    if [ -f "$state" ] && read_state "$state"; then
      if [ "$s_busy" != 1 ] && [ $((now - s_last)) -gt "$IDLE" ]; then
        close_block "$sid"
        s_start=$now
      fi
    else
      s_start=$now
    fi
    s_last=$now
    s_busy=1
    describe
    write_state
    ;;

  Stop)
    if [ -f "$state" ] && read_state "$state"; then
      s_last=$now
      s_busy=0
      write_state
    fi
    set -- "$QUEUE"/*.json
    [ -f "$1" ] && upload_detached
    ;;

  SessionEnd)
    if [ -f "$state" ] && read_state "$state"; then
      [ "$s_busy" = 1 ] && s_last=$now
      close_block "$sid"
    fi
    upload_detached
    ;;
esac

exit 0
