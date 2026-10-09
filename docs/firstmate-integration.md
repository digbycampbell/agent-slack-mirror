# Firstmate integration

This document is the contract for the firstmate-side follow-up that removes Slack logic from the firstmate fork.
This package does not edit firstmate.

## What this package now owns

- `slack-mirror.sh` and `adapters/` — the terminal-to-Slack mirror core.
- `bin/slack-captain.sh` — the captain-channel listener (poll, handle, classify, thread tracking, reactions, attachments).
- `bin/slack-post.sh` — the poster (quote bar, channel map, thread registration, replied reaction).
- `bin/firstmate-extension` and `firstmate-extension.json` — a `process-event-adapter/1` identity.

Behaviour of poll, handle, attachments, `poll_interval`, the quiet window, thread tracking, read positions, reactions, the quote bar, label handling, and never-a-gate is the same as firstmate `main` at the copy date.

## Environment contract

The package never reads `FM_HOME`, `FM_ROOT`, `config/slack-captain` by a relative home path, or firstmate's `bin/`.
The host sets these:

| Variable | Who uses it | Meaning |
| --- | --- | --- |
| `SLACK_CONFIG_FILE` | listener, poster, mirror | Captain `key=value` file (`channel=`, `bot_user=`, `allowed_user=`, `peer_bots=`, `quiet_window=`, `poll_interval=`, `reactions=`, `quote_replies=`, `mirror*` keys) |
| `SLACK_STATE_DIR` | listener, poster, mirror | Cursors, attachments, reactions, and mirror records |
| `SLACK_TOKEN_FILE` | listener, poster | `.env` style file holding `SLACK_BOT_TOKEN` |
| `SLACK_CHANNELS_FILE` | poster | Optional `name=<channel id>` map |
| `SLACK_MIRROR_STATE_DIR` | mirror | Defaults to `SLACK_STATE_DIR` when unset |
| `SLACK_MIRROR_CONFIG_FILE` | mirror | Defaults to `SLACK_CONFIG_FILE` when unset |
| `SLACK_MIRROR_POST_CMD` | mirror | Path to `bin/slack-post.sh` |
| `SLACK_MIRROR_CMD` | listener, poster | Path to `slack-mirror.sh`; defaults to this package |
| `SLACK_CAPTAIN_CMD` | poster | Path to `bin/slack-captain.sh`; defaults to this package |

Legacy `FM_SLACK_CAPTAIN_*`, `FM_SLACK_POST_*`, and `FM_SLACK_MIRROR_*` tuning names still win only when the `SLACK_*` spelling is unset.

Firstmate's thin caller must export the table from its home:

```sh
export SLACK_CONFIG_FILE="$CONFIG/slack-captain"
export SLACK_STATE_DIR="$STATE/slack-captain"
export SLACK_TOKEN_FILE="$FM_HOME/.env"
export SLACK_CHANNELS_FILE="$CONFIG/slack-channels"
export SLACK_MIRROR_STATE_DIR="$STATE/slack-captain"
export SLACK_MIRROR_CONFIG_FILE="$CONFIG/slack-captain"
export SLACK_MIRROR_POST_CMD="$PACKAGE/bin/slack-post.sh"
export SLACK_MIRROR_CMD="$PACKAGE/slack-mirror.sh"
export SLACK_CAPTAIN_CMD="$PACKAGE/bin/slack-captain.sh"
```

`$PACKAGE` is the installed checkout (`SLACK_MIRROR_HOME` today).

## Why `process-event-adapter/1` cannot be the production listener

The package satisfies handshake and the four operations, so `fm-extension.sh bind` and `verify` can record it.
Do not use `source.poll` as the only capture path in the follow-up.

Evidence:

1. **No autohandle.** `docs/extension-bindings.md` withholds `autohandle` and `answers` from external adapters.
   `bin/slack-captain.sh autohandle` advances the channel and thread read positions after durable capture, records the mirror reply target, prunes attachments and reaction markers, then exits 1 so the result stays unhandled and still wakes firstmate.
   Without that step, the next poll recaptures the same window until a human handles the wake.

2. **32,768-byte envelope.** Extension results are capped at 32,768 bytes.
   The built-in runner allows 1 MiB (`FM_PROCEVENT_MAX_OUTPUT_BYTES`).
   A capture with image paths and voice transcripts can exceed 32,768 bytes.
   The entrypoint refuses that output rather than truncate it.

3. **Host timeout versus native poll.** `source.poll` must return `no-result` before the host bound (default five minutes).
   Native poll defaults to 90 loops of 20 seconds.
   The entrypoint caps loops at 3 so a bind-and-invoke path cannot hang the host.
   That cap is a shorter quiet wait than today's listener.

4. **Commands outside the four operations.** `track-thread`, `mark-replied`, `source-id`, and the poster are not `source.poll` / `result.classify` / `result.terminal` / `result.silent`.
   `result.terminal` is always false.
   `result.silent` is always false: a Slack capture must wake firstmate.

`config_ref` for a later bind, if firstmate grows the protocol, is:

```
config=/absolute/slack-captain,state=/absolute/state-dir,token=/absolute/.env,channels=/absolute/slack-channels
```

Consent facts in the manifest are `network` and `credential-store`.

## Production plug-in shape for the follow-up

Keep a built-in adapter *name* so the existing runner, 1 MiB capture, `autohandle`, and `register` argv path stay in force.
Replace the Slack bodies with exec wrappers that only set the environment contract and call this package.

### 1. Delete Slack logic from firstmate

Remove the implementations of:

- `bin/fm-procevent-slack-captain.sh`
- `bin/fm-slack-post.sh`

Keep the filenames as wrappers.
Keep `bin/fm-slack-mirror.sh` as the thin caller it already is; point `SLACK_MIRROR_POST_CMD` at `$PACKAGE/bin/slack-post.sh`.

### 2. Wrapper: `bin/fm-procevent-slack-captain.sh`

```sh
# set the environment table from this home, then:
exec "$PACKAGE/bin/slack-captain.sh" "$@"
```

Map today's commands:

| Firstmate command | Package command | Notes |
| --- | --- | --- |
| `arm` | host `fm-procevent.sh register slack-captain <id> -- "$PACKAGE/bin/slack-captain.sh" poll` | Stay in the wrapper. The package has no `arm`. |
| `poll <home> <channel>` | `poll [channel]` | Drop `<home>` from argv. Paths come from the environment table. |
| `handle` / `autohandle` / `classify` / `terminal` / `track-thread` / `mark-replied` / `source-id` | same | `handle` no longer calls `fm-procevent.sh handled`. |
| `retire` | host `fm-procevent.sh retire` | Stay in the wrapper. The package has no `retire`. |

`autohandle` in the package still applies read positions and exits 1.
The wrapper must not swallow that exit, so the runner still leaves the result unhandled.

`handle` in the package applies read positions only.
The wrapper's `handle` must then call `fm-procevent.sh handled <source-id> <sequence>` so firstmate's acknowledgement files stay identical.

### 3. Wrapper: `bin/fm-slack-post.sh`

```sh
exec "$PACKAGE/bin/slack-post.sh" "$@"
```

Same flags. Same stdout timestamp. Same quote-bar and reaction behaviour, through `SLACK_CAPTAIN_CMD`.

### 4. Tests that stay in firstmate

Move nothing that drives `fm-procevent.sh start`, `.wake-queue`, or `procevent-inbox/*.handled`.
Those tests stay in firstmate and run through the wrappers.
This package already covers poll, handle, attachments, reactions, quote bar, and token confinement without the runner.

### 5. Docs and bootstrap in firstmate

Point `docs/configuration.md` Slack sections at this package's headers.
Keep the clone of `agent-slack-mirror` as the install.
Bootstrap already requires `slack-mirror.sh`; also require `bin/slack-captain.sh` and `bin/slack-post.sh`.

Do not register `slack-captain` through `register-extension` until firstmate adds an apply-after-capture operation and a result envelope of at least 1 MiB.

## Handle versus autohandle

Read positions still advance only after a result exists, never inside `poll`.

- `autohandle` — runner, immediately after durable capture. Apply cursors. Exit 1. Result stays eligible for a `check` wake.
- `handle` — firstmate after it has dealt with the wake. Apply cursors (idempotent). The wrapper records `handled`.

A covered older capture still prints `superseded:` and does not move the cursor.

## Out of scope for the follow-up

New Slack features, a protocol change to `process-event-adapter/1`, and behaviour changes other than the env-contract and wrapper split above.
