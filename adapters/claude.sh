#!/usr/bin/env bash
# Turn-end adapter for Claude-shaped Stop payloads.
#
# Usage (the adapter contract every file in this directory implements):
#   claude.sh claims     payload on stdin; exit 0 when this adapter owns it
#   claude.sh extract    payload on stdin; one JSON turn record on stdout
#   claude.sh describe   one coverage line for `slack-mirror.sh adapters`
#
# The turn record's fields, all optional and all ignored when absent or of the
# wrong type:
#   final_text   the finished turn's own final assistant text; empty means
#                nothing to mirror, which is an ordinary silent outcome
#   trigger_text the text of the message that OPENED the turn; empty means the
#                trigger could not be read at all, which is what selects the
#                mirror's newest-inbound fallback rather than its auto-detect
#   turn_epoch   when this turn started, in epoch seconds, for the
#                deliberate-post window; empty falls back to an assumed length
#   model,effort what produced the reply, for the optional worker-details stamp
#   prompt_text  the human-typed prompt that opened the turn, as the human typed
#                it; empty when the turn was not opened by a human-typed prompt,
#                which is an ordinary silent outcome
#   prompt_id    a stable identity for that prompt, so a re-delivered turn end
#                cannot post it twice; empty lets the core fall back to the text
#
# CLAIMS. A Stop payload whose event name is the Claude spelling, or, for a
# payload that omits it, one carrying the snake_case `transcript_path` field.
# Codex's Stop payload is the same snake_case shape (`stop.command.input` in
# codex-cli 0.149.0 carries `hook_event_name: "Stop"`, `last_assistant_message`,
# `transcript_path`, `model`, `session_id`, `stop_hook_active`, `turn_id`), so
# this adapter reads it too; its rollout transcript is a different format, so a
# Codex turn simply reports no trigger and routes by the mirror's fallback.
#
# WHAT IT READS. The payload's own `last_assistant_message` is preferred because
# it describes the turn that just ended and cannot race the transcript write,
# which is not guaranteed to have flushed the final entry by the time Stop fires.
# When a payload omits it, the transcript named by the payload is read instead:
# sidechain (subagent) entries are excluded, and the text must be newer than the
# turn's own opening message, so a turn that produced no reply of its own never
# re-posts an older one. The opening message is read either way, so the trigger
# stays readable even when the turn produced no assistant text.
#
# THE HUMAN PROMPT. The turn's opener is the newest main-thread user entry that
# carries text and is not harness bookkeeping: `isMeta` entries (skill
# expansions, image notes, injected reminders) and compaction summaries
# (`isCompactSummary`, `isVisibleInTranscriptOnly`) are passed over, because none
# of them opens a turn. The opener is reported as `prompt_text` only when Claude
# marks it `origin.kind == "human"`, the field Claude Code writes on every prompt
# entered at the terminal (`promptSource` typed, queued, or
# suggestion_accepted) and on no injected one: task notifications, Stop hook
# feedback, watcher wakes, scheduled and SDK prompts, and auto-continuations each
# carry a different kind or none. An entry without the field is never reported,
# so an older transcript format fails closed rather than posting a synthetic
# prompt. A slash command is reported as the command line the human typed
# (`/name args`), never as the skill text it expanded into. Its `uuid` is the
# `prompt_id`.
set -u

# An ISO-8601 instant from the transcript, as epoch seconds. GNU and BSD date
# disagree on the flag, so both are tried and an unreadable value is a refusal.
iso_epoch() {  # <iso-8601>
  local value=${1-} plain out
  [ -n "$value" ] || return 1
  if out=$(date -u -d "$value" +%s 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  plain=${value%%.*}
  plain=${plain%Z}
  if out=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$plain" +%s 2>/dev/null) && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  return 1
}

# The final assistant text of the finished turn. Sets FINAL_TEXT, FINAL_TS,
# FINAL_MODEL, FINAL_EFFORT, TURN_TS, and TURN_TEXT from the reversed transcript
# in $1. TURN_TS and TURN_TEXT describe the same message - the turn's newest
# opening user entry that carries text - and are set before any early return, so
# the trigger stays readable even when the turn produced no assistant text.
read_final_message() {  # <reversed-transcript>
  local meta
  FINAL_TEXT=; FINAL_TS=; FINAL_MODEL=; FINAL_EFFORT=; TURN_TS=; TURN_TEXT=
  TURN_TS=$(jq -r --slurp '
      map(select(.type == "user" and (.isSidechain != true)))
      | map(select(
          (.message.content | type) == "string"
          or ((.message.content | type) == "array"
              and (.message.content | any(.type == "text")))
        ))
      | (.[0].timestamp // "")
    ' "$1" 2>/dev/null) || return 1
  TURN_TEXT=$(jq -r --slurp '
      map(select(.type == "user" and (.isSidechain != true)))
      | map(select(
          (.message.content | type) == "string"
          or ((.message.content | type) == "array"
              and (.message.content | any(.type == "text")))
        ))
      | (.[0] // empty)
      | (if (.message.content | type) == "string" then .message.content
         else (.message.content | map(select(.type == "text") | .text // "") | join("\n")) end)
    ' "$1" 2>/dev/null) || TURN_TEXT=
  meta=$(jq -r --slurp '
      map(select(.type == "assistant" and (.isSidechain != true)))
      | map(select(((.message.content // []) | type) == "array"))
      | map(select((.message.content | map(select(.type == "text") | .text // "")
                    | join("")) != ""))
      | (.[0] // empty)
      | "\(.timestamp // "") \(.message.model // "") \(.effort // "")"
    ' "$1" 2>/dev/null) || return 1
  [ -n "$meta" ] || return 1
  read -r FINAL_TS FINAL_MODEL FINAL_EFFORT <<EOF
$meta
EOF
  FINAL_TEXT=$(jq -r --slurp '
      map(select(.type == "assistant" and (.isSidechain != true)))
      | map(select(((.message.content // []) | type) == "array"))
      | map(select((.message.content | map(select(.type == "text") | .text // "")
                    | join("")) != ""))
      | (.[0] // empty)
      | (.message.content | map(select(.type == "text") | .text // "") | join("\n"))
    ' "$1" 2>/dev/null) || return 1
  [ -n "$FINAL_TEXT" ] || return 1
  return 0
}

# The human-typed prompt that opened the turn, from the reversed transcript in
# $1. Sets PROMPT_TEXT and PROMPT_ID, both empty when the opener is not a
# human-typed prompt. The header's THE HUMAN PROMPT section owns the rules.
read_opening_prompt() {  # <reversed-transcript>
  local record
  PROMPT_TEXT=; PROMPT_ID=
  record=$(jq -c --slurp '
      map(select(.type == "user" and (.isSidechain != true)
                 and (.isMeta != true) and (.isCompactSummary != true)
                 and (.isVisibleInTranscriptOnly != true)))
      | map(select(
          (.message.content | type) == "string"
          or ((.message.content | type) == "array"
              and (.message.content | any(.type == "text")))
        ))
      | (.[0] // empty)
      | select((.origin | type) == "object" and .origin.kind == "human")
      | (if (.message.content | type) == "string" then .message.content
         else (.message.content | map(select(.type == "text") | .text // "") | join("\n")) end) as $text
      | (if ($text | test("^\\s*<command-(name|message)>")) then
           ([$text | capture("<command-name>(?<n>[^<]*)</command-name>").n] | .[0] // "") as $name
           | ([$text | capture("<command-args>(?<a>(.|\\n)*)</command-args>").a] | .[0] // "") as $args
           | (if $args == "" then $name else "\($name) \($args)" end)
         else $text end) as $prompt
      | {id: (if (.uuid | type) == "string" then .uuid else "" end), text: $prompt}
    ' "$1" 2>/dev/null) || return 1
  [ -n "$record" ] || return 0
  PROMPT_TEXT=$(printf '%s' "$record" | jq -r '.text' 2>/dev/null) || PROMPT_TEXT=
  PROMPT_ID=$(printf '%s' "$record" | jq -r '.id' 2>/dev/null) || PROMPT_ID=
  return 0
}

cmd_claims() {
  local payload
  command -v jq >/dev/null 2>&1 || return 1
  payload=$(cat 2>/dev/null) || return 1
  [ -n "$payload" ] || return 1
  printf '%s' "$payload" | jq -e '
      (type == "object")
      and (
        ((.hook_event_name | type) == "string" and (.hook_event_name | ascii_downcase) == "stop")
        or ((.hook_event_name == null) and ((.transcript_path | type) == "string"))
      )
    ' >/dev/null 2>&1
}

cmd_extract() {
  local payload payload_text transcript reversed tmpdir body
  local FINAL_TEXT='' FINAL_TS='' FINAL_MODEL='' FINAL_EFFORT='' TURN_TS='' TURN_TEXT=''
  local PROMPT_TEXT='' PROMPT_ID='' turn_epoch=''

  command -v jq >/dev/null 2>&1 || return 0
  payload=$(cat 2>/dev/null) || return 0
  [ -n "$payload" ] || return 0

  transcript=$(printf '%s' "$payload" | jq -r '
      if (.transcript_path | type) == "string" then .transcript_path else "" end
    ' 2>/dev/null) || return 0
  if [ -n "$transcript" ] && [ -f "$transcript" ] && [ ! -L "$transcript" ]; then
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/slack-mirror-claude.XXXXXX" 2>/dev/null) || return 0
    reversed="$tmpdir/reversed.jsonl"
    # Newest first, so each read stops at the first match instead of walking the
    # whole session.
    if tail -n "${SLACK_MIRROR_SCAN_LINES:-${FM_SLACK_MIRROR_SCAN_LINES:-400}}" "$transcript" \
        2>/dev/null | tac > "$reversed" 2>/dev/null; then
      read_final_message "$reversed" || true
      read_opening_prompt "$reversed" || true
    fi
    rm -rf -- "$tmpdir"
  fi

  # The payload's own account of the turn that just ended wins over the
  # transcript, which Stop can outrun.
  payload_text=$(printf '%s' "$payload" | jq -r '
      if (.last_assistant_message | type) == "string" then .last_assistant_message else "" end
    ' 2>/dev/null) || payload_text=
  if [ -n "$payload_text" ]; then
    body=$payload_text
    FINAL_EFFORT=$(printf '%s' "$payload" | jq -r '
        if (.effort.level | type) == "string" then .effort.level else "" end
      ' 2>/dev/null) || FINAL_EFFORT=
  else
    body=$FINAL_TEXT
    # A turn that ended without a reply of its own must never re-post an older
    # one. ISO-8601 UTC instants compare correctly as strings.
    if [ -n "$body" ] && [ -n "$TURN_TS" ] && [ ! "$FINAL_TS" ">" "$TURN_TS" ]; then
      body=
    fi
  fi

  turn_epoch=$(iso_epoch "$TURN_TS" 2>/dev/null || true)
  jq -n --arg harness claude --arg final "$body" --arg trigger "$TURN_TEXT" \
    --arg epoch "$turn_epoch" --arg model "$FINAL_MODEL" --arg effort "$FINAL_EFFORT" \
    --arg prompt "$PROMPT_TEXT" --arg prompt_id "$PROMPT_ID" \
    '{harness: $harness, final_text: $final, trigger_text: $trigger,
      turn_epoch: $epoch, model: $model, effort: $effort,
      prompt_text: $prompt, prompt_id: $prompt_id}'
}

# `claims` is a predicate, so its status must survive to the caller; every other
# path stays silent and successful.
case "${1-}" in
  claims)   cmd_claims; exit $? ;;
  extract)  cmd_extract ;;
  describe) printf 'claude: covered - Stop payload carries last_assistant_message and a transcript naming the turn trigger and the human-typed prompt (also matches Codex Stop, whose rollout transcript yields neither)\n' ;;
  *) printf 'usage: %s claims|extract|describe\n' "${0##*/}" >&2; exit 2 ;;
esac
exit 0
