# agent-slack-mirror

Mirror a coding agent's terminal conversation into a Slack channel, verbatim.

Each finished turn's final human-facing reply is posted to Slack exactly as the terminal rendered it - not a paraphrase the agent wrote by hand, and not something the agent can forget to do.
When the human opened the turn by typing at the terminal, their prompt is posted first, labelled, so Slack shows both sides of the exchange.
Slack then carries the same conversation the human sees in the terminal, so switching between the two never means hunting for "similar looking" text.

The tool is a turn-end hook: the host agent's harness fires it when a turn finishes, it decides locally whether the reply is worth mirroring, and a detached child delivers the post.
It is deliberately not a gate - every path exits 0 before the network is touched, so a Slack outage or a bug here can never block or fail the agent's turn.

## What it does

- **Verbatim mirroring** of the finished turn's own final assistant text: not tool output, not thinking, not intermediate narration. URLs, markdown, and code spans survive.
- **The human's own prompt**: a prompt typed at the terminal is posted as `<Name> (terminal): <prompt>` immediately before the reply it produced, in the same thread. Slack-originated turns, injected prompts (task notifications, hook feedback, watcher wakes, system reminders, host envelopes, compaction summaries), and skill expansions are never posted; a slash command posts only the command line typed. A re-delivered turn end posts the prompt once.
- **Acknowledgement suppression**: a single short prose line with no link, code span, bullet, or reference is not mirrored, so supervision chatter never buries the channel. Two consecutive identical bodies are never both sent. For a typed prompt the rule applies to the exchange: the prompt goes out before any mirrored reply, and on its own only when it is itself substantive.
- **No double post**: when the host posts to the channel deliberately in the same turn, the mirror stands down.
- **Thread correctness**: a reply to a message written in a Slack thread is filed back into that thread, resolved by the event that actually opened the turn, so interleaved conversations never misfile.

`slack-mirror.sh` is the whole core; `adapters/` owns the per-harness turn-end payload shapes.
The header comment in `slack-mirror.sh` is the authoritative contract for everything above.

## Harness coverage

Run `./slack-mirror.sh adapters` for the current table.
As of this writing: Claude Code and Grok are covered and proven live, and Claude Code also mirrors the human's typed prompt (its transcript marks typed prompts `origin.kind: "human"`); Grok's transcript does not mark a typed prompt apart from an injected one, so on Grok only the reply is mirrored. Codex emits the same Claude-shaped Stop payload and is read by the same adapter (registration is the host's job); Kimi, Cursor, opencode, and Pi are recorded gaps because their turn boundaries expose no payload naming the finished turn's final message.

## Hosting it

The tool is self-contained and learns nothing about your agent's layout.
The host supplies everything through an environment contract:

| Variable | Meaning |
| --- | --- |
| `SLACK_MIRROR_STATE_DIR` | required; the directory holding the tool's own records |
| `SLACK_MIRROR_CONFIG_FILE` | required; a `key=value` file holding `channel=` and the optional `mirror*` tuning keys |
| `SLACK_MIRROR_POST_CMD` | required for delivery; an executable invoked as `<cmd> <channel> --file <path> --origin mirror [--thread <ts>] [--worker-details <d>]`. It owns the Slack token entirely - no secret ever reaches this tool. |
| `SLACK_MIRROR_HARNESS` | optional; pins the adapter instead of asking each adapter to claim the payload |

With no `channel=` in the configuration file, nothing is mirrored at all.

The host then:

1. Registers `slack-mirror.sh turn-end` on its harness's turn-end hook, with the Stop payload on stdin.
2. Provides a poster command that actually talks to Slack (and holds the token).
3. Optionally records deliberate posts (`note-post`), inbound captures (`note-inbound`, `note-trigger`), and explicit reply targets (`note-reply-target`) so suppression and thread routing work; each subcommand is documented in the script header.

[Firstmate](https://github.com/digbycampbell/firstmate) is the reference host: see its `bin/fm-slack-mirror.sh` (the thin caller), `bin/fm-slack-post.sh` (the poster), and its `.claude/settings.json`, `.grok/hooks/`, and `.codex/hooks.json` registrations.

## Configuration keys

Beside `channel=` in `SLACK_MIRROR_CONFIG_FILE`, all optional: `mirror=on|off`, `mirror_ack_max_chars`, `mirror_thread_window`, `mirror_turn_window`, `mirror_max_chars`, `mirror_worker_details=on|off`, `mirror_prompts=on|off`, `mirror_prompt_label`.
The prompt label defaults to `<Name> (terminal):`, where `<Name>` is the first word of the account's full name or its capitalised login.
Defaults and exact semantics live in the `slack-mirror.sh` header, which is the single owner of the contract.

## Tests

`tests/prompts.test.sh` drives `turn-end` with Claude-shaped payloads and transcripts against a fake poster; it needs bash and jq.
Firstmate's `tests/fm-slack-mirror.test.sh` covers the rest of the contract through its thin caller; point `SLACK_MIRROR_HOME` at a checkout to run it against that checkout.

## License

MIT - see [LICENSE](LICENSE).
This tool was extracted, with its history, from the [firstmate](https://github.com/digbycampbell/firstmate) repository.
