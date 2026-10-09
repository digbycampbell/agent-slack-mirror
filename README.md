# agent-slack-mirror

The Slack package for a coding-agent host: a captain-channel listener, a poster, and a terminal-to-Slack mirror.

Each finished turn's final human-facing reply is posted to Slack exactly as the terminal rendered it - not a paraphrase the agent wrote by hand, and not something the agent can forget to do.
When the human opened the turn by typing at the terminal, their prompt is posted first, labelled, so Slack shows both sides of the exchange.
The listener captures captain messages (including thread replies and image attachments) so the host can wake on them.
The poster is the one outbound path: quote bar, channel names, thread registration, and the seen/replied reactions.

The mirror is a turn-end hook: the host agent's harness fires it when a turn finishes, it decides locally whether the reply is worth mirroring, and a detached child delivers the post.
It is deliberately not a gate - every path exits 0 before the network is touched, so a Slack outage or a bug here can never block or fail the agent's turn.

## What it contains

| Path | Role |
| --- | --- |
| `slack-mirror.sh` | Mirror core. `adapters/` owns per-harness turn-end payload shapes. |
| `bin/slack-captain.sh` | Listener: poll, handle, classify, track-thread, mark-replied. |
| `bin/slack-post.sh` | Poster: `chat.postMessage`, quote bar, thread registration, replied reaction. |
| `bin/firstmate-extension` | `process-event-adapter/1` handshake and invoke entrypoint. |
| `firstmate-extension.json` | Package manifest for a firstmate bind. |
| `docs/firstmate-integration.md` | Exact firstmate follow-up: env table, wrappers, and why bind is not the production poll path. |

The header comment in `slack-mirror.sh` is the authoritative contract for mirroring.
The header in `bin/slack-captain.sh` owns capture, read positions, debounce, threads, attachments, and reactions.
The header in `bin/slack-post.sh` owns the quote bar, channel map, and token confinement.

## What the mirror does

- **Verbatim mirroring** of the finished turn's own final assistant text: not tool output, not thinking, not intermediate narration. URLs, markdown, and code spans survive.
- **The human's own prompt**: a prompt typed at the terminal is posted as `<Name> (terminal): <prompt>` immediately before the reply it produced, in the same thread. Slack-originated turns, injected prompts (task notifications, hook feedback, watcher wakes, system reminders, host envelopes, compaction summaries), and skill expansions are never posted; a slash command posts only the command line typed. A re-delivered turn end posts the prompt once.
- **Acknowledgement suppression**: a single short prose line with no link, code span, bullet, or reference is not mirrored, so supervision chatter never buries the channel. Two consecutive identical bodies are never both sent. For a typed prompt the rule applies to the exchange: the prompt goes out before any mirrored reply, and on its own only when it is itself substantive.
- **No double post**: when the host posts to the channel deliberately (`note-post <channel> --body-file <path>`, or `-` for stdin; `bin/slack-post.sh` does this itself for a manual post), the digest of that body is recorded, and the turn's reply is skipped only if it repeats a body posted since the turn began. A deliberate post that says something different leaves the reply to be mirrored. A `note-post` with no body records the time alone and suppresses nothing.
- **Thread correctness**: a reply to a message written in a Slack thread is filed back into that thread, resolved by the event that actually opened the turn, so interleaved conversations never misfile.

## Harness coverage

Run `./slack-mirror.sh adapters` for the current table.
As of this writing: Claude Code and Grok are covered and proven live, and Claude Code also mirrors the human's typed prompt (its transcript marks typed prompts `origin.kind: "human"`); Grok's transcript does not mark a typed prompt apart from an injected one, so on Grok only the reply is mirrored. Codex emits the same Claude-shaped Stop payload and is read by the same adapter (registration is the host's job); Kimi, Cursor, opencode, and Pi are recorded gaps because their turn boundaries expose no payload naming the finished turn's final message.

## Environment contract

The package learns nothing about the host's layout.
The host supplies paths through the environment:

| Variable | Meaning |
| --- | --- |
| `SLACK_CONFIG_FILE` | required for listener and poster; `key=value` captain configuration (`channel=` and optional `mirror*`, `bot_user=`, `allowed_user=`, `peer_bots=`, `quiet_window=`, `poll_interval=`, `reactions=`, `quote_replies=`) |
| `SLACK_STATE_DIR` | required for listener and poster; cursors, attachments, reactions, mirror records |
| `SLACK_TOKEN_FILE` | required for network; `.env` style file holding `SLACK_BOT_TOKEN` |
| `SLACK_CHANNELS_FILE` | optional; `name=<channel id>` map for the poster |
| `SLACK_MIRROR_STATE_DIR` | required for the mirror; defaults to `SLACK_STATE_DIR` when the listener or poster invokes it |
| `SLACK_MIRROR_CONFIG_FILE` | required for the mirror; defaults to `SLACK_CONFIG_FILE` in that same case |
| `SLACK_MIRROR_POST_CMD` | required for delivery; an executable invoked as `<cmd> <channel> --file <path> --origin mirror [--thread <ts>] [--worker-details <d>]`. `bin/slack-post.sh` is this package's poster. It owns the Slack token. No secret reaches the mirror. |
| `SLACK_MIRROR_HARNESS` | optional; pins the adapter instead of asking each adapter to claim the payload |

With no `channel=` in the configuration file, nothing is mirrored and the listener refuses to arm a watch.

## How a host plugs it in

1. Install this checkout (firstmate clones it to `${XDG_DATA_HOME:-$HOME/.local/share}/agent-slack-mirror`).
2. Export the environment table from the host home. Firstmate's mapping is in `docs/firstmate-integration.md`.
3. Register `slack-mirror.sh turn-end` on the harness turn-end hook, with the Stop payload on stdin, and set `SLACK_MIRROR_POST_CMD` to `bin/slack-post.sh`.
4. Register `bin/slack-captain.sh poll` as the process-event child for the captain channel. After the host durably captures a result, call `autohandle` (apply read positions, keep the wake) and later `handle` (apply again, then the host records acknowledgement).
5. Optionally bind `firstmate-extension.json` for identity. Do not use `source.poll` as the production capture path; the integration doc states why.

[Firstmate](https://github.com/digbycampbell/firstmate) is the reference host.
Until its follow-up lands, it still ships its own copies of the listener and poster.
This package is the one they must call.

## Configuration keys

Beside `channel=` in `SLACK_CONFIG_FILE`, all optional: `mirror=on|off`, `mirror_ack_max_chars`, `mirror_thread_window`, `mirror_turn_window`, `mirror_max_chars`, `mirror_worker_details=on|off`, `mirror_prompts=on|off`, `mirror_prompt_label`, `bot_user`, `allowed_user`, `peer_bots`, `quiet_window`, `poll_interval`, `reactions=on|off`, `quote_replies=on|off`.
The prompt label defaults to `<Name> (terminal):`, where `<Name>` is the first word of the account's full name or its capitalised login.
Defaults and exact semantics live in the script headers.

## Tests

`tests/run.sh` runs every `tests/*.test.sh`. Needs bash, jq, and sha256sum or shasum.

- `tests/prompts.test.sh` — mirror `turn-end` against a fake poster.
- `tests/slack-captain.test.sh` — listener: capture, read positions, threads, attachments, debounce, reactions.
- `tests/slack-post.test.sh` — poster: quote bar, token confinement, hang ceiling, thread registration.
- `tests/extension.test.sh` — handshake and invoke.

CI runs `tests/run.sh` on every pull request.

## License

MIT - see [LICENSE](LICENSE).
The listener and poster were copied, with tests, from the [firstmate](https://github.com/digbycampbell/firstmate) repository so that repository can track upstream without Slack divergence.
