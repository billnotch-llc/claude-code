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
# Session state and queued blocks name the user's folders and branches.
umask 077

input=$(cat)

KEY=${CLAUDE_PLUGIN_OPTION_API_KEY:-}
API=${CLAUDE_PLUGIN_OPTION_API_URL:-https://api.billnotch.com}
API=${API%/}
DATA=${CLAUDE_PLUGIN_DATA:-}

case "${CLAUDE_PLUGIN_OPTION_AUTO_TRACK:-true}" in
  false | False | FALSE | 0 | no | off) exit 0 ;;
esac
[ -n "$KEY" ] && [ -n "$DATA" ] || exit 0
# A key is tt_ plus URL-safe characters. Anything else is not one, and must not
# reach the curl config below where a quote or newline would change its meaning.
case "$KEY" in
  tt_*) ;;
  *) exit 0 ;;
esac
case "$KEY" in
  *[!A-Za-z0-9_-]*) exit 0 ;;
esac

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
ISOLATE_MAX=50       # entries retried one by one after a batch is refused

SESSIONS=$DATA/sessions
QUEUE=$DATA/queue
REJECTED=$DATA/rejected
mkdir -p "$SESSIONS" "$QUEUE" "$REJECTED" || exit 0

field() {
  printf '%s' "$input" | tr -d '\n' |
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

event=$(field hook_event_name)
sid=$(field session_id | tr -cd 'A-Za-z0-9_-')
[ -n "$event" ] && [ -n "$sid" ] || exit 0

now=$(date +%s)
state=$SESSIONS/$sid

# ---------------------------------------------------------------- locking
#
# Every read-modify-write of a session's state happens under that session's lock,
# so a sweep from another session can never act on a stale snapshot. mkdir is
# atomic on every filesystem this runs on. A hook is killed after its timeout, so
# a lock older than a minute belongs to a dead process.

LOCK=
release() {
  [ -n "$LOCK" ] && rmdir "$LOCK"
  LOCK=
}
trap release 0
trap 'release; exit 0' HUP INT TERM

find "$SESSIONS" -name '*.lock' -type d -mmin +1 -exec rmdir {} + 2>/dev/null
find "$QUEUE" -name '.lock' -type d -mmin +10 -exec rmdir {} + 2>/dev/null

# lock <session id> <wait: 1 to wait briefly, 0 for a single try>
lock() {
  release
  tries=0
  until mkdir "$SESSIONS/$1.lock"; do
    [ "$2" = 1 ] || return 1
    tries=$((tries + 1))
    [ "$tries" -lt 30 ] || return 1
    sleep 0.1 || sleep 1
  done
  LOCK=$SESSIONS/$1.lock
}

# ---------------------------------------------------------------- blocks

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
# Callers hold that session's lock.
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

# A block whose turn is still marked running long after it began was left behind
# by a process that died mid-turn. It ends at the last moment we know was work.
stale_busy() { [ "$s_busy" = 1 ] && [ $((now - s_last)) -gt "$CRASHED_AFTER" ]; }

# What the next block is called, and the project the repo is linked to (if any).
describe() {
  dir=${CLAUDE_PROJECT_DIR:-$PWD}
  n_label=$(clean "$(basename "$dir")")
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  [ -n "$branch" ] && [ "$branch" != HEAD ] && n_label="$n_label ($(clean "$branch"))"
  n_project=
  n_billable=
  if [ -f "$dir/.billnotch.json" ]; then
    link=$(tr -d '\n' <"$dir/.billnotch.json")
    n_project=$(printf '%s' "$link" |
      sed -n 's/.*"projectId"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F-]\{36\}\)".*/\1/p')
    printf '%s' "$link" | tr -d ' \t' | grep -q '"billable":true' && n_billable=true
  fi
}

# Close blocks left behind by other sessions that have gone quiet or died. A
# session whose lock is taken is busy right now and is left alone.
sweep() {
  for f in "$SESSIONS"/*; do
    [ -f "$f" ] || continue
    other=$(basename "$f")
    [ "$other" = "$sid" ] && continue
    case "$other" in *.[0-9]*) continue ;; esac
    lock "$other" 0 || continue
    # Re-read under the lock: the snapshot before it may already be stale.
    if [ -f "$f" ]; then
      if ! read_state "$f"; then
        rm -f "$f"
      elif stale_busy; then
        close_block "$other"
      elif [ "$s_busy" != 1 ] && [ $((now - s_last)) -gt "$IDLE" ]; then
        close_block "$other"
      fi
    fi
    release
  done
}

# ---------------------------------------------------------------- upload

# post <file holding a request body> -> prints "<http status> <error code>"
post() {
  out=$QUEUE/.resp.$$
  # The key goes in through a config on stdin, never on the command line, where
  # any user on the machine could read it in the process list.
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$KEY" |
    curl -sS -m 15 -K - -o "$out" -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' \
      --data-binary "@$1" "$API/time-entries/batch")
  err=$(tr -d '\n' <"$out" | sed -n 's/.*"code"[[:space:]]*:[[:space:]]*"\([A-Z_]*\)".*/\1/p')
  rm -f "$out"
  printf '%s %s' "${code:-000}" "${err:-NONE}"
}

# The API refused this entry itself, not the caller or the connection: a linked
# project that no longer exists, or an entry it cannot accept. Retrying the same
# body will never succeed.
refused() {
  case "$1" in
    '404 ENTITY_NOT_FOUND' | '422 UNPROCESSABLE' | '400 BAD_REQUEST') return 0 ;;
  esac
  return 1
}

post_one() {
  printf '{"entries":[' >"$2"
  tr -d '\n' <"$1" >>"$2"
  printf ']}' >>"$2"
  post "$2"
}

# One entry at a time, after a batch was refused, so a single bad entry cannot hold
# back the rest of the queue. A refused entry is retried without its project, which
# keeps the time in BillNotch (uncategorized, to be sorted on review); only one the
# API refuses even then is set aside in rejected/, never deleted.
isolate() {
  one=$QUEUE/.one.$$
  n=0
  while IFS= read -r f; do
    [ "$n" -lt "$ISOLATE_MAX" ] || break
    n=$((n + 1))
    [ -f "$f" ] || continue
    result=$(post_one "$f" "$one")
    case "$result" in
      2??\ *) rm -f "$f"; continue ;;
    esac
    refused "$result" || break # auth, billing, rate limit or network: try later
    if grep -q '"projectId"' "$f"; then
      sed 's/,"projectId":"[^"]*","isBillable":[a-z]*//' "$f" >"$f.bare"
      result=$(post_one "$f.bare" "$one")
      rm -f "$f.bare"
      case "$result" in
        2??\ *) rm -f "$f"; continue ;;
      esac
      refused "$result" || break
    fi
    mv -f "$f" "$REJECTED/"
  done
  rm -f "$one"
}

upload() {
  # One uploader at a time; another one already running will see these blocks.
  mkdir "$QUEUE/.lock" || return 0
  trap 'rmdir "$QUEUE/.lock"' 0
  find "$QUEUE" "$REJECTED" -name '*.json' -mtime +"$QUEUE_TTL_DAYS" -exec rm -f {} + 2>/dev/null
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

  result=$(post "$body")
  case "$result" in
    2??\ *) while IFS= read -r f; do rm -f "$f"; done <"$sent" ;;
    *) refused "$result" && isolate <"$sent" ;;
  esac
  # Anything else leaves the blocks queued for the next attempt.
  rm -f "$body" "$sent"
}

upload_detached() {
  release
  (upload </dev/null >/dev/null 2>&1 &)
}

# ---------------------------------------------------------------- events

case "$event" in
  SessionStart)
    sweep
    if lock "$sid" 1 && [ -f "$state" ] && read_state "$state"; then
      # A resumed session runs in a new process, so a turn still marked running
      # died with the old one. Without this, the next prompt would extend that block
      # across all the time the session was closed.
      if [ "$s_busy" = 1 ] && { [ "$(field source)" = resume ] || stale_busy; }; then
        close_block "$sid"
      elif [ "$s_busy" != 1 ] && [ $((now - s_last)) -gt "$IDLE" ]; then
        close_block "$sid"
      fi
    fi
    upload_detached
    ;;

  UserPromptSubmit)
    lock "$sid" 1 || exit 0
    describe
    if [ -f "$state" ] && read_state "$state"; then
      if stale_busy; then
        close_block "$sid"
        s_start=$now
      elif [ "$s_busy" != 1 ] && [ $((now - s_last)) -gt "$IDLE" ]; then
        close_block "$sid"
        s_start=$now
      elif [ "$n_project" != "$s_project" ] || [ "$n_billable" != "$s_billable" ]; then
        # The repository was linked, unlinked or relinked mid-block. Time so far
        # keeps the project it was tracked under; the link applies from here.
        s_last=$now
        close_block "$sid"
        s_start=$now
      fi
    else
      s_start=$now
    fi
    s_last=$now
    s_busy=1
    s_label=$n_label
    s_project=$n_project
    s_billable=$n_billable
    write_state
    ;;

  Stop)
    if lock "$sid" 1 && [ -f "$state" ] && read_state "$state"; then
      if stale_busy; then
        close_block "$sid"
      else
        s_last=$now
        s_busy=0
        write_state
      fi
    fi
    set -- "$QUEUE"/*.json
    [ -f "$1" ] && upload_detached
    ;;

  SessionEnd)
    if lock "$sid" 1 && [ -f "$state" ] && read_state "$state"; then
      [ "$s_busy" = 1 ] && ! stale_busy && s_last=$now
      close_block "$sid"
    fi
    upload_detached
    ;;
esac

exit 0
