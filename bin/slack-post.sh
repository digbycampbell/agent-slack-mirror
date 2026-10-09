#!/usr/bin/env bash
# Post one Slack message as firstmate's bot, and register the thread it creates
# so a captain reply inside that thread is still captured.
#
# Usage:
#   slack-post.sh <channel> <text>...
#   slack-post.sh <channel> --file <path>
#   slack-post.sh <channel> ... --thread <ts>
#   slack-post.sh <channel> ... --worker-details "<model> <effort>"
#   slack-post.sh <channel> ... --origin manual|mirror
#
# <channel> is either a raw Slack channel id (uppercase alphanumerics) or a name
# defined in SLACK_CHANNELS_FILE, one `name=<channel id>` per line; a
# leading `#` is accepted and ignored. An unknown name is a refusal, never a
# guess, so a typo cannot post into the wrong channel.
#
# The message body is the remaining arguments joined with spaces, or the whole
# contents of `--file <path>` when that is given; exactly one of the two must be
# present. Text is never expanded by a shell: it is carried into the JSON request
# body by jq and posted from a private temporary file, so nothing in it can be
# re-split, interpolated, or executed.
#
# `--thread <ts>` posts the message as a reply inside that thread instead of at
# the channel's top level.
#
# `--worker-details "<model> <effort>"` appends the standing completion
# convention to the message. This flag is the single owner of that convention:
# the message gains a blank line and then `_worker: <model> <effort>_`, so a
# completion post always says which model and effort produced the work. The value
# is bounded and restricted to plain identifier characters.
#
# TOKEN - `SLACK_BOT_TOKEN` in the file named by SLACK_TOKEN_FILE, read exactly
# as bin/slack-captain.sh reads it and handed to curl through `--config -` on
# stdin. It never appears in argv, in a log line, in a printed diagnostic, or in
# the request body file. Nothing here echoes a response body.
#
# On success the posted message timestamp is printed on stdout and nothing else,
# so a caller can thread onto it. A Slack error is a loud nonzero refusal naming
# the Slack error code.
#
# BOUNDED. The curl call is wrapped in a hard wall-clock ceiling
# (SLACK_POST_HARD_TIMEOUT, default SLACK_POST_MAX_TIME + 5) on top of
# curl's own --max-time, so a stalled Slack can never hang the caller even if
# curl fails to honor its in-band bound. Hitting the ceiling is a loud nonzero
# refusal like any other Slack failure; the detached mirror delivery discards
# that status, so the guarantee is defense in depth for the synchronous callers.
#
# ORIGIN. A successful post to the configured captain channel is recorded with
# slack-mirror.sh `note-post --body-file -`, with the message text as written
# (before the worker-details stamp and the quote bar) on stdin, which is how the
# terminal mirror knows the host already said this and must not mirror a reply
# that repeats it.
# `--origin mirror` marks the mirror's own delivery and skips that record, so
# the mirror cannot suppress itself on the following turn. The default is
# `manual`, so every ordinary hand-written post counts.
#
# THREAD REGISTRATION. When the target channel is the configured captain channel
# and this post is itself a reply (`--thread <ts>` was given), the replied-to
# thread is registered with bin/slack-captain.sh `track-thread`,
# which is what makes a captain reply written inside that thread reach the
# host. A top-level post is not yet a thread and is not registered here: if
# it later grows replies, the adapter's own channel-window scan tracks it the
# first time a reply naming it is captured. A host with no captain-channel
# configuration simply skips this step.
#
# QUOTE BAR. Every body is posted as a Slack blockquote, so consecutive long
# messages are easy to tell apart: each line gains a `> ` prefix and a blank
# line becomes a bare `>`, so the bar stays unbroken, and a fenced code block
# keeps working because each of its lines is prefixed the same way. The
# `--worker-details` stamp sits inside the quote. `quote_replies=off` in
# SLACK_CONFIG_FILE posts bodies as written. A captain's terminal prompt
# that the mirror relays is never quoted: it is the one post with `--origin
# mirror` whose body starts with the mirror's prompt label, read the way
# slack-mirror.sh reads it (SLACK_MIRROR_PROMPT_LABEL, then
# FM_SLACK_MIRROR_PROMPT_LABEL, then `mirror_prompt_label` in
# SLACK_CONFIG_FILE). A host that configures no label cannot tell that post
# apart, so it is quoted like the rest.
#
# REPLIED REACTION. A successful post to the configured captain channel, from
# either origin, calls bin/slack-captain.sh `mark-replied` with the
# thread it posted into, so the captain messages it answers swap their `eyes`
# reaction for a check mark, except the relayed terminal prompt above, which
# answers nothing. That adapter owns which messages a reply answers
# and the `reactions` switch. The call runs detached, so it never delays or
# fails a post Slack already accepted; SLACK_POST_REACTIONS_SYNC=1 runs it
# inline instead, for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
. "$PACKAGE_ROOT/lib/env.sh"
# shellcheck source=lib/run-timed.sh
. "$PACKAGE_ROOT/lib/run-timed.sh"

post_tune() {  # <suffix> <default>
  local own="SLACK_POST$1" legacy="FM_SLACK_POST$1"
  if [ -n "${!own-}" ]; then
    printf '%s\n' "${!own}"
  elif [ -n "${!legacy-}" ]; then
    printf '%s\n' "${!legacy}"
  else
    printf '%s\n' "$2"
  fi
}

captain_api() {
  if [ -n "${SLACK_CAPTAIN_API:-}" ]; then
    printf '%s\n' "$SLACK_CAPTAIN_API"
  elif [ -n "${FM_SLACK_CAPTAIN_API:-}" ]; then
    printf '%s\n' "$FM_SLACK_CAPTAIN_API"
  else
    printf '%s\n' https://slack.com/api
  fi
}

SLACK_API="$(captain_api)"
CURL_MAX_TIME=$(post_tune _MAX_TIME 20)
case "$CURL_MAX_TIME" in ''|*[!0-9]*) CURL_MAX_TIME=20 ;; esac
# A hard wall-clock ceiling around the whole curl process group. curl's own
# --max-time is a single in-band guard, so a curl wedged outside its own
# transfer accounting - a stalled resolver, a proxy that never speaks, a build
# that ignores the option - can outlast it and hang the caller indefinitely.
# slack_run_timed kills the group and returns 124 exactly when this ceiling is
# hit, so no Slack call - the detached mirror delivery or a synchronous
# hand-post - can ever hang a turn. The default sits above --max-time so curl's
# graceful timeout fires first on an ordinary slow network; an explicit override
# is used verbatim.
HARD_TIMEOUT=$(post_tune _HARD_TIMEOUT $((CURL_MAX_TIME + 5)))
case "$HARD_TIMEOUT" in ''|*[!0-9]*|0) HARD_TIMEOUT=$((CURL_MAX_TIME + 5)) ;; esac
MAX_BODY_BYTES=$(post_tune _MAX_BYTES 40000)

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

env_file() {
  [ -n "${SLACK_TOKEN_FILE:-}" ] || die "SLACK_TOKEN_FILE is not set"
  printf '%s\n' "$SLACK_TOKEN_FILE"
}
channels_file() {
  [ -n "${SLACK_CHANNELS_FILE:-}" ] || return 1
  printf '%s\n' "$SLACK_CHANNELS_FILE"
}
captain_config_file() {
  [ -n "${SLACK_CONFIG_FILE:-}" ] || return 1
  printf '%s\n' "$SLACK_CONFIG_FILE"
}
MIRROR_CMD="${SLACK_MIRROR_CMD:-$PACKAGE_ROOT/slack-mirror.sh}"
CAPTAIN_CMD="${SLACK_CAPTAIN_CMD:-$SCRIPT_DIR/slack-captain.sh}"

valid_slack_id() {
  case "${1-}" in
    ''|*[!A-Z0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

valid_ts() {
  case "${1-}" in
    ''|*[!0-9.]*|*.*.*) return 1 ;;
  esac
  return 0
}

# The same reader the captain adapter uses, refused rather than defaulted.
read_token() {
  local token file
  file=$(env_file)
  [ -f "$file" ] && [ ! -L "$file" ] || die "SLACK_TOKEN_FILE is unavailable, so SLACK_BOT_TOKEN cannot be read"
  token=$(slack_env_get SLACK_BOT_TOKEN "$file")
  [ -n "$token" ] || die "SLACK_BOT_TOKEN is not set in SLACK_TOKEN_FILE"
  case "$token" in
    *[[:space:]]*) die "SLACK_BOT_TOKEN contains whitespace" ;;
  esac
  printf '%s\n' "$token"
}

# A name resolves only through the local channel map; an id passes through.
resolve_channel() {  # <channel>
  local name=${1#\#} file id
  if valid_slack_id "$name"; then
    printf '%s\n' "$name"
    return 0
  fi
  case "$name" in
    ''|*[!A-Za-z0-9_-]*) die "invalid channel name: $1" ;;
  esac
  file=$(channels_file) || die "SLACK_CHANNELS_FILE is not set, so the channel name '$name' cannot be resolved"
  [ -f "$file" ] && [ ! -L "$file" ] \
    || die "SLACK_CHANNELS_FILE is unavailable, so the channel name '$name' cannot be resolved"
  id=$(sed -n "s/^[[:space:]]*$name=//p" "$file" | tail -n1 | tr -d '[:space:]')
  [ -n "$id" ] || die "SLACK_CHANNELS_FILE has no entry for '$name'"
  valid_slack_id "$id" || die "SLACK_CHANNELS_FILE maps '$name' to an invalid channel id"
  printf '%s\n' "$id"
}

# One free-text key from config/slack-captain, inner spacing kept and only the
# surrounding whitespace trimmed; empty when absent or unsafe.
captain_config_text() {  # <key>
  local file value
  file=$(captain_config_file) || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  value=$(sed -n "s/^[[:space:]]*$1=//p" "$file" | tail -n1)
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

# 0 when this post is the mirror relaying the captain's own terminal prompt.
is_mirrored_prompt() {  # <text>
  local label
  [ "$ORIGIN" = mirror ] || return 1
  label=${SLACK_MIRROR_PROMPT_LABEL:-${FM_SLACK_MIRROR_PROMPT_LABEL:-}}
  [ -n "$label" ] || label=$(captain_config_text mirror_prompt_label)
  [ -n "$label" ] || return 1
  case "$1" in
    "$label"*) return 0 ;;
  esac
  return 1
}

# The body as a Slack blockquote: `> ` before each line, a bare `>` for a blank
# one, so the bar is continuous through paragraphs and code fences.
quote_body() {  # <text>
  printf '%s\n' "$1" | awk '{ if ($0 ~ /^[[:space:]]*$/) print ">"; else print "> " $0 }'
}

# The configured captain channel, or empty when this home watches none.
captain_channel() {
  local file id
  file=$(captain_config_file) || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  id=$(sed -n 's/^[[:space:]]*channel=//p' "$file" | tail -n1 | tr -d '[:space:]')
  valid_slack_id "$id" || return 0
  printf '%s\n' "$id"
}

CHANNEL=
THREAD=
FILE=
DETAILS=
ORIGIN=manual
TEXT_ARGS=()

[ "$#" -gt 0 ] || usage
case "${1-}" in
  ''|-h|--help|help) usage ;;
esac
CHANNEL=$1
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)   [ "$#" -ge 2 ] || die "--file needs a path"; FILE=$2; shift 2 ;;
    --thread) [ "$#" -ge 2 ] || die "--thread needs a timestamp"; THREAD=$2; shift 2 ;;
    --worker-details)
      [ "$#" -ge 2 ] || die "--worker-details needs a \"<model> <effort>\" value"
      DETAILS=$2; shift 2 ;;
    --origin)
      [ "$#" -ge 2 ] || die "--origin needs a value"
      case "$2" in
        manual|mirror) ORIGIN=$2 ;;
        *) die "--origin accepts only manual or mirror" ;;
      esac
      shift 2 ;;
    -h|--help) usage ;;
    --*) die "unknown option: $1" ;;
    *) TEXT_ARGS+=("$1"); shift ;;
  esac
done

command -v curl >/dev/null 2>&1 || die "curl is not installed"
command -v jq >/dev/null 2>&1 || die "jq is not installed"

channel=$(resolve_channel "$CHANNEL") || exit 1
[ -z "$THREAD" ] || valid_ts "$THREAD" || die "invalid thread timestamp: $THREAD"
case "$DETAILS" in
  '') ;;
  *[!A-Za-z0-9\ ._/-]*) die "--worker-details accepts only plain model and effort names" ;;
  *) [ "${#DETAILS}" -le 80 ] || die "--worker-details is too long" ;;
esac

if [ -n "$FILE" ]; then
  [ "${#TEXT_ARGS[@]}" -eq 0 ] || die "give message text or --file, not both"
  [ -f "$FILE" ] && [ ! -L "$FILE" ] || die "message file is unavailable or unsafe: $FILE"
  text=$(cat "$FILE")
else
  [ "${#TEXT_ARGS[@]}" -gt 0 ] || die "no message text; give text or --file"
  text="${TEXT_ARGS[*]}"
fi
[ -n "$text" ] || die "the message is empty"
[ "${#text}" -le "$MAX_BODY_BYTES" ] || die "the message is longer than $MAX_BODY_BYTES characters"
posted_text=$text
[ -z "$DETAILS" ] || text=$(printf '%s\n\n_worker: %s_' "$text" "$DETAILS")
mirrored_prompt=0
! is_mirrored_prompt "$text" || mirrored_prompt=1
case "$(captain_config_text quote_replies)" in
  ''|on) [ "$mirrored_prompt" = 1 ] || text=$(quote_body "$text") ;;
  off) ;;
  *) die "the captain configuration has an invalid quote_replies value; use on or off" ;;
esac

TMP=$(mktemp -d "${TMPDIR:-/tmp}/slack-post.XXXXXX") || die "cannot create a staging directory"
trap 'rm -rf -- "$TMP"' EXIT
body="$TMP/body.json"
resp="$TMP/response.json"

jq -n --arg channel "$channel" --arg text "$text" --arg thread "$THREAD" '
  {channel: $channel, text: $text}
  + (if $thread == "" then {} else {thread_ts: $thread} end)
' > "$body" || die "cannot build the Slack request body"

token=$(read_token) || exit 1
curl_rc=0
printf 'header = "Authorization: Bearer %s"\n' "$token" \
  | slack_run_timed "$HARD_TIMEOUT" curl -sS --config - --max-time "$CURL_MAX_TIME" \
      -H 'Content-Type: application/json; charset=utf-8' \
      --data-binary "@$body" \
      "$SLACK_API/chat.postMessage" -o "$resp" 2>/dev/null \
  || curl_rc=$?
case "$curl_rc" in
  0) ;;
  124) die "the Slack request timed out after ${HARD_TIMEOUT}s" ;;
  *) die "the Slack request failed" ;;
esac

jq -e . "$resp" >/dev/null 2>&1 || die "Slack returned an unreadable response"
if ! jq -e '.ok == true' "$resp" >/dev/null 2>&1; then
  err=$(jq -r '.error // "unknown"' "$resp" 2>/dev/null || printf 'unknown')
  case "$err" in
    ''|*[!A-Za-z0-9_-]*) err=unknown ;;
  esac
  die "Slack refused the message: $err"
fi

ts=$(jq -r '.ts // ""' "$resp")
valid_ts "$ts" || die "Slack accepted the message but returned no usable timestamp"

# Register the thread this post replies into, so a captain reply inside it is
# captured. A top-level post is not yet a thread, so it is not registered: doing
# so would consume a tracked-thread slot and an extra poll request for a thread
# that may never exist. A home that watches no captain channel needs nothing
# here, and a registration failure never invalidates a message Slack already
# accepted.
watched=$(captain_channel)
# The terminal mirror's duplicate test; a failure here never invalidates a
# message Slack already accepted.
if [ -n "$watched" ] && [ "$watched" = "$channel" ] && [ "$ORIGIN" = manual ]; then
  export SLACK_MIRROR_STATE_DIR="${SLACK_MIRROR_STATE_DIR:-${SLACK_STATE_DIR:-}}"
  export SLACK_MIRROR_CONFIG_FILE="${SLACK_MIRROR_CONFIG_FILE:-${SLACK_CONFIG_FILE:-}}"
  export SLACK_MIRROR_POST_CMD="${SLACK_MIRROR_POST_CMD:-$SCRIPT_DIR/slack-post.sh}"
  if [ -x "$MIRROR_CMD" ]; then
    printf '%s\n' "$posted_text" \
      | "$MIRROR_CMD" note-post "$channel" --body-file - >/dev/null 2>&1 || true
  fi
fi
if [ -n "$watched" ] && [ "$watched" = "$channel" ] && [ -n "$THREAD" ]; then
  "$CAPTAIN_CMD" track-thread "$channel" "$THREAD" >/dev/null 2>&1 \
    || printf 'slack-post: could not register thread %s for capture\n' "$THREAD" >&2
fi
if [ -n "$watched" ] && [ "$watched" = "$channel" ] && [ "$mirrored_prompt" = 0 ]; then
  mark=( "$CAPTAIN_CMD" mark-replied "$channel" "${THREAD:-none}" )
  reactions_sync=${SLACK_POST_REACTIONS_SYNC:-${FM_SLACK_POST_REACTIONS_SYNC:-}}
  if [ "$reactions_sync" = 1 ]; then
    "${mark[@]}" </dev/null >/dev/null 2>&1 || true
  elif command -v setsid >/dev/null 2>&1; then
    setsid "${mark[@]}" </dev/null >/dev/null 2>&1 &
  else
    "${mark[@]}" </dev/null >/dev/null 2>&1 &
  fi
fi

printf '%s\n' "$ts"
