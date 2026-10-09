#!/usr/bin/env bash
# Behavior tests for mirroring the human's own terminal prompt.
#
# The core is driven exactly as a host drives it: a Claude-shaped Stop payload on
# stdin naming a real transcript file, the environment contract set, and
# SLACK_MIRROR_POST_CMD pointing at a fake poster that records every call it
# receives - its arguments and the posted text - in order. What would reach Slack
# is asserted rather than inferred, and nothing here touches the network.
# Delivery runs inline (SLACK_MIRROR_SYNC=1) so each case is deterministic.
#
# Run: tests/prompts.test.sh   (needs bash, jq, and sha256sum or shasum)
# shellcheck disable=SC2016 # literal backticks are Slack code spans under test
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MIRROR="$ROOT/slack-mirror.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/slack-mirror-prompts.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR"

CHANNEL=C0TESTCHAN
FAILURES=0
PASSES=0

fail() { printf 'FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
pass() { PASSES=$((PASSES + 1)); }

POSTER="$TMP_ROOT/fake-post"
cat > "$POSTER" <<'SH'
#!/usr/bin/env bash
# Stand-in for the host's poster: one record per call, in call order.
# shellcheck disable=SC2016 # literal backticks are Slack code spans under test
set -u
channel=$1; shift
file=; args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --file) file=$2; shift 2 ;;
    *) args+=( "$1" ); shift ;;
  esac
done
{
  printf '=== POST channel=%s args=%s\n' "$channel" "${args[*]-}"
  cat "$file"
  printf '=== END\n'
} >> "$FAKE_POST_LOG"
SH
chmod +x "$POSTER"
export FAKE_POST_LOG="$TMP_ROOT/posts.log"

# A fresh host: its own state directory and configuration file.
new_host() {  # <name> [extra config lines...]
  local host="$TMP_ROOT/$1"
  shift
  mkdir -p "$host/state"
  {
    printf 'channel=%s\n' "$CHANNEL"
    printf 'mirror_prompt_label=Digby (terminal):\n'
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$host/config"
  printf '%s\n' "$host"
}

# One transcript entry per call, in the shape Claude Code writes.
human_prompt() {  # <path> <uuid> <text> [timestamp]
  jq -n -c --arg uuid "$2" --arg text "$3" --arg ts "${4:-2026-10-09T10:00:00.000Z}" '{
      type: "user", isSidechain: false, uuid: $uuid, timestamp: $ts,
      promptId: "p-\($uuid)", promptSource: "typed", origin: {kind: "human"},
      message: {role: "user", content: $text}
    }' >> "$1"
}

# A user entry carrying an explicit origin object (or none for "-").
user_entry() {  # <path> <uuid> <origin-kind-or-dash> <text> [extra-jq-object]
  jq -n -c --arg uuid "$2" --arg kind "$3" --arg text "$4" --argjson extra "${5:-{\}}" '{
      type: "user", isSidechain: false, uuid: $uuid, timestamp: "2026-10-09T10:00:00.000Z",
      message: {role: "user", content: [{type: "text", text: $text}]}
    } + (if $kind == "-" then {} else {origin: {kind: $kind}} end) + $extra' >> "$1"
}

assistant_reply() {  # <path> <text> [timestamp]
  jq -n -c --arg text "$2" --arg ts "${3:-2026-10-09T10:00:05.000Z}" '{
      type: "assistant", isSidechain: false, timestamp: $ts,
      message: {model: "claude-opus-5-5", content: [{type: "text", text: $text}]},
      effort: "low"
    }' >> "$1"
}

tool_round() {  # <path>
  jq -n -c '{type: "assistant", isSidechain: false, timestamp: "2026-10-09T10:00:02.000Z",
      message: {model: "claude-opus-5-5", content: [{type: "tool_use", id: "t1", name: "Bash", input: {}}]}}' >> "$1"
  jq -n -c '{type: "user", isSidechain: false, timestamp: "2026-10-09T10:00:03.000Z",
      message: {role: "user", content: [{type: "tool_result", tool_use_id: "t1", content: "ok"}]}}' >> "$1"
}

# Fire the turn end exactly as a Claude Stop hook does.
run_turn_end() {  # <host> <transcript> [env assignments...]
  local host=$1 transcript=$2
  shift 2
  env SLACK_MIRROR_STATE_DIR="$host/state" SLACK_MIRROR_CONFIG_FILE="$host/config" \
    SLACK_MIRROR_POST_CMD="$POSTER" SLACK_MIRROR_SYNC=1 "$@" \
    "$MIRROR" turn-end <<EOF
{"hook_event_name":"Stop","session_id":"s-1","stop_hook_active":false,"transcript_path":"$transcript","cwd":"$host"}
EOF
}

post_count() { grep -c '^=== POST ' "$FAKE_POST_LOG" 2>/dev/null || true; }

# The text of the Nth post (1-based).
post_text() {  # <n>
  awk -v n="$1" '
    /^=== POST / { i++; inside = (i == n); next }
    /^=== END$/  { inside = 0; next }
    inside { print }
  ' "$FAKE_POST_LOG"
}

post_args() {  # <n>
  grep '^=== POST ' "$FAKE_POST_LOG" | sed -n "${1}p"
}

expect_eq() {  # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$2], got [$3]"; fi
}

expect_no_posts() {  # <label>
  expect_eq "$1: post count" 0 "$(post_count)"
}

SUBSTANTIVE_REPLY='Opened the PR: https://example.com/pr/1 and queued the review.'

# --- a typed prompt is posted before the reply, into the reply's thread -------

host=$(new_host typed)
t="$host/t.jsonl"
human_prompt "$t" u-typed-1 'can we sync the terminal and slack better?'
tool_round "$t"
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "typed: post count" 2 "$(post_count)"
expect_eq "typed: prompt first" 'Digby (terminal): can we sync the terminal and slack better?' "$(post_text 1)"
expect_eq "typed: reply second" "$SUBSTANTIVE_REPLY" "$(post_text 2)"
expect_eq "typed: prompt is a mirror post" "=== POST channel=$CHANNEL args=--origin mirror" "$(post_args 1)"

# Into the same thread the reply goes to, via the explicit reply-target record.
host=$(new_host threaded)
t="$host/t.jsonl"
human_prompt "$t" u-thread-1 'what is the status of the thread work?'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
env SLACK_MIRROR_STATE_DIR="$host/state" SLACK_MIRROR_CONFIG_FILE="$host/config" \
  "$MIRROR" note-reply-target "$CHANNEL" 1700000000.000100
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "threaded: post count" 2 "$(post_count)"
expect_eq "threaded: prompt thread" "=== POST channel=$CHANNEL args=--origin mirror --thread 1700000000.000100" "$(post_args 1)"
expect_eq "threaded: reply thread" "=== POST channel=$CHANNEL args=--origin mirror --thread 1700000000.000100" "$(post_args 2)"

# A multi-line prompt puts the label on its own line so the prompt renders as typed.
host=$(new_host multiline)
t="$host/t.jsonl"
human_prompt "$t" u-multi-1 "$(printf 'two things:\n- first\n- second')"
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "multiline: prompt" "$(printf 'Digby (terminal):\ntwo things:\n- first\n- second')" "$(post_text 1)"

# The label comes from configuration; the environment override wins.
host=$(new_host label 'mirror_prompt_label=Captain (tty):')
t="$host/t.jsonl"
human_prompt "$t" u-label-1 'please check the queue'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "label: configured" 'Captain (tty): please check the queue' "$(post_text 1)"
host=$(new_host label-env)
t="$host/t.jsonl"
human_prompt "$t" u-label-2 'please check the queue'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t" SLACK_MIRROR_PROMPT_LABEL='Ops:'
expect_eq "label: env override" 'Ops: please check the queue' "$(post_text 1)"

# mirror_prompts=off restores reply-only mirroring.
host=$(new_host prompts-off 'mirror_prompts=off')
t="$host/t.jsonl"
human_prompt "$t" u-off-1 'please check the queue'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "prompts off: post count" 1 "$(post_count)"
expect_eq "prompts off: reply only" "$SUBSTANTIVE_REPLY" "$(post_text 1)"

# A slash command posts the command line typed, never the skill it expanded into.
host=$(new_host slash)
t="$host/t.jsonl"
human_prompt "$t" u-slash-1 "$(printf '<command-message>ahoy</command-message>\n<command-name>/ahoy</command-name>\n<command-args>catch me up</command-args>')"
user_entry "$t" u-slash-2 - 'Base directory for this skill: /x/ahoy  # ahoy  Give the captain a recap' '{"isMeta": true}'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "slash: post count" 2 "$(post_count)"
expect_eq "slash: typed command line" 'Digby (terminal): /ahoy catch me up' "$(post_text 1)"

# --- a Slack-originated turn posts no prompt ----------------------------------

# The realistic shape: the turn is opened by a watcher wake naming the capture.
host=$(new_host slack-wake)
t="$host/t.jsonl"
env SLACK_MIRROR_STATE_DIR="$host/state" SLACK_MIRROR_CONFIG_FILE="$host/config" \
  "$MIRROR" note-trigger "$CHANNEL" slack-captain 7 1700000000.000200
user_entry "$t" u-wake-1 task-notification \
  "$(printf '<task-notification>\n<summary>firstmate watcher wake</summary>\ncheck: procevent slack-captain 7\n</task-notification>')"
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "slack wake: post count" 1 "$(post_count)"
expect_eq "slack wake: reply only" "$SUBSTANTIVE_REPLY" "$(post_text 1)"
expect_eq "slack wake: reply in the captured thread" \
  "=== POST channel=$CHANNEL args=--origin mirror --thread 1700000000.000200" "$(post_args 1)"

# Even a prompt a harness marked human-typed is held back when it names a
# captured Slack result, because that message is already in Slack.
host=$(new_host slack-typed)
t="$host/t.jsonl"
env SLACK_MIRROR_STATE_DIR="$host/state" SLACK_MIRROR_CONFIG_FILE="$host/config" \
  "$MIRROR" note-trigger "$CHANNEL" slack-captain 9 none
human_prompt "$t" u-slacktyped-1 'check: procevent slack-captain 9 - the captain asked about the release'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "slack typed: post count" 1 "$(post_count)"
expect_eq "slack typed: reply only" "$SUBSTANTIVE_REPLY" "$(post_text 1)"

# --- each class of injected prompt posts nothing ------------------------------

# Each case: the newest opener is injected, so the turn mirrors its reply alone.
injected_case() {  # <label> <writer-function>
  local label=$1 writer=$2 host t
  host=$(new_host "inj-$label")
  t="$host/t.jsonl"
  "$writer" "$t"
  assistant_reply "$t" "$SUBSTANTIVE_REPLY"
  : > "$FAKE_POST_LOG"
  run_turn_end "$host" "$t"
  expect_eq "injected $label: post count" 1 "$(post_count)"
  expect_eq "injected $label: reply only" "$SUBSTANTIVE_REPLY" "$(post_text 1)"
}

w_stop_hook() {
  user_entry "$1" u-inj-stop task-notification \
    "$(printf '<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>\n<system-reminder>\nStop hook blocking error\n</system-reminder>')"
}
w_watcher() {
  user_entry "$1" u-inj-watch task-notification \
    'firstmate watcher wake - one supervision event needs a handling turn now.'
}
w_task_notification() {
  user_entry "$1" u-inj-task task-notification \
    "$(printf '<task-notification>\n<task-id>abc</task-id>\n<status>completed</status>\n</task-notification>')"
}
w_scheduled() {
  user_entry "$1" u-inj-sched scheduled 'check on background db sync'
}
w_no_origin() {
  user_entry "$1" u-inj-none - '[Request interrupted by user for tool use]'
}
w_system_reminder_typed() {
  user_entry "$1" u-inj-sr human "$(printf '<system-reminder>\nreminder text\n</system-reminder>')"
}
w_invisible_separator() {
  user_entry "$1" u-inj-u2063 human "$(printf '\342\201\243FIRSTMATE_OP: v1 launch-brief: do the thing')"
}
w_firstmate_op() {
  user_entry "$1" u-inj-op human 'FIRSTMATE_OP: v1 steer: pause the lane'
}
w_compaction() {
  user_entry "$1" u-inj-compact - \
    'This session is being continued from a previous conversation that ran out of context.' \
    '{"isCompactSummary": true, "isVisibleInTranscriptOnly": true}'
}
w_meta() {
  user_entry "$1" u-inj-meta human 'Base directory for this skill: /x/skill' '{"isMeta": true}'
}

injected_case stop-hook-feedback w_stop_hook
injected_case watcher-wake w_watcher
injected_case task-notification w_task_notification
injected_case scheduled w_scheduled
injected_case no-origin w_no_origin
injected_case system-reminder w_system_reminder_typed
injected_case u2063 w_invisible_separator
injected_case firstmate-op w_firstmate_op
injected_case compaction-summary w_compaction
injected_case meta-only w_meta

# A Stop hook continuation: the human prompt opened the turn and was mirrored,
# then hook feedback reopened it; the second turn end must not re-post the prompt.
host=$(new_host continuation)
t="$host/t.jsonl"
human_prompt "$t" u-cont-1 'ship the mirror change please'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "continuation: first turn end posts both" 2 "$(post_count)"
w_stop_hook "$t"
assistant_reply "$t" 'Fixed the hook finding; see `bin/x.sh` for the change.' 2026-10-09T10:01:00.000Z
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "continuation: second turn end posts the reply only" 1 "$(post_count)"
expect_eq "continuation: reply" 'Fixed the hook finding; see `bin/x.sh` for the change.' "$(post_text 1)"

# Compaction mid-turn: the summary is passed over, so the human prompt that
# opened the turn before it is still the one posted, and the summary never is.
host=$(new_host compaction-mid-turn)
t="$host/t.jsonl"
human_prompt "$t" u-compact-1 'refactor the poster and tell me when done'
tool_round "$t"
w_compaction "$t"
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "compaction mid-turn: post count" 2 "$(post_count)"
expect_eq "compaction mid-turn: opener posted" 'Digby (terminal): refactor the poster and tell me when done' "$(post_text 1)"

# An empty prompt posts nothing.
host=$(new_host empty)
t="$host/t.jsonl"
human_prompt "$t" u-empty-1 '   '
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "empty: post count" 1 "$(post_count)"
expect_eq "empty: reply only" "$SUBSTANTIVE_REPLY" "$(post_text 1)"

# --- re-delivery posts once ---------------------------------------------------

host=$(new_host redeliver)
t="$host/t.jsonl"
# Substantive by itself (a #reference), so only the record stops a second post.
human_prompt "$t" u-redeliver-1 'what is left on the board after #12?'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
run_turn_end "$host" "$t"
expect_eq "redeliver: total posts across both deliveries" 2 "$(post_count)"
expect_eq "redeliver: prompt once" 1 "$(grep -c '^Digby (terminal): what is left on the board after #12?$' "$FAKE_POST_LOG")"

# Re-delivery when the reply is not mirrored at all still posts the prompt once.
host=$(new_host redeliver-alone)
t="$host/t.jsonl"
human_prompt "$t" u-alone-1 "$(printf 'please look at https://example.com/issue/4 and tell me\nwhat you think')"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
run_turn_end "$host" "$t"
expect_eq "redeliver alone: prompt once" 1 "$(post_count)"

# --- the acknowledgement rule applies to the exchange -------------------------

# A short prompt answered by a mirrored reply is posted: it is the reply's context.
host=$(new_host ack-paired)
t="$host/t.jsonl"
human_prompt "$t" u-ack-1 'yes'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "ack paired: post count" 2 "$(post_count)"
expect_eq "ack paired: prompt" 'Digby (terminal): yes' "$(post_text 1)"

# A short prompt answered by an acknowledgement: neither side is mirrored.
host=$(new_host ack-both)
t="$host/t.jsonl"
human_prompt "$t" u-ack-2 'yes'
assistant_reply "$t" 'Done.'
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_no_posts "ack both"

# A substantive prompt is mirrored even when its reply is an acknowledgement.
host=$(new_host ack-reply)
t="$host/t.jsonl"
human_prompt "$t" u-ack-3 'merge #42 once the queue clears'
assistant_reply "$t" 'Will do.'
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "ack reply: post count" 1 "$(post_count)"
expect_eq "ack reply: prompt alone" 'Digby (terminal): merge #42 once the queue clears' "$(post_text 1)"

# A prompt posted alone carries no worker-details stamp.
host=$(new_host details 'mirror_worker_details=on')
t="$host/t.jsonl"
human_prompt "$t" u-details-1 'look at `bin/x.sh` please'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
: > "$FAKE_POST_LOG"
run_turn_end "$host" "$t"
expect_eq "details: prompt unstamped" "=== POST channel=$CHANNEL args=--origin mirror" "$(post_args 1)"
expect_eq "details: reply stamped" "=== POST channel=$CHANNEL args=--origin mirror --worker-details claude-opus-5-5 low" "$(post_args 2)"

# --- never a gate -------------------------------------------------------------

host=$(new_host gate)
t="$host/t.jsonl"
human_prompt "$t" u-gate-1 'check the queue'
assistant_reply "$t" "$SUBSTANTIVE_REPLY"
out=$(run_turn_end "$host" "$t" SLACK_MIRROR_POST_CMD="$TMP_ROOT/absent-poster")
status=$?
expect_eq "gate: exit status" 0 "$status"
expect_eq "gate: stdout" '' "$out"

printf '%s passed, %s failed\n' "$PASSES" "$FAILURES"
[ "$FAILURES" -eq 0 ]
