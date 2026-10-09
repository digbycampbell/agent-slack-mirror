#!/usr/bin/env bash
# Handshake and invoke coverage for the process-event-adapter/1 entrypoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EXT="$ROOT/bin/firstmate-extension"
TMP_ROOT=$(fm_test_tmproot slack-extension)
export TMPDIR="$TMP_ROOT/tmp"
mkdir -p "$TMPDIR"

handshake_req='{
  "schema": "firstmate.extension-handshake-request.v1",
  "request_id": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "host_protocols": [1],
  "extension_id": "org.digbycampbell.agent-slack-mirror",
  "extension_version": "1.0.0",
  "package_digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "capability": {
    "name": "process-event-adapter",
    "versions": [1],
    "adapter_names": ["slack-captain"]
  }
}'

out=$(printf '%s\n' "$handshake_req" | "$EXT" handshake)
assert_equals firstmate.extension-handshake-response.v1 "$(printf '%s' "$out" | jq -r .schema)" \
  "handshake schema"
assert_equals org.digbycampbell.agent-slack-mirror "$(printf '%s' "$out" | jq -r .extension_id)" \
  "handshake id"
assert_equals slack-captain "$(printf '%s' "$out" | jq -r '.adapter_names[0]')" \
  "handshake adapter name"
pass "handshake returns the package identity"

invoke() {  # <operation> <input-json>
  jq -nc --arg op "$1" --argjson input "$2" '{
    schema: "firstmate.extension-request.v1",
    request_id: "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    host_protocol: 1,
    extension_id: "org.digbycampbell.agent-slack-mirror",
    extension_version: "1.0.0",
    package_digest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    capability: "process-event-adapter",
    capability_version: 1,
    adapter: "slack-captain",
    operation: $op,
    input: $input
  }' | "$EXT" invoke
}

out=$(invoke result.terminal '{"source_id":"slack-captain-C0TESTCHAN","sequence":1,"content":"x"}')
assert_equals false "$(printf '%s' "$out" | jq -r .result.value)" "terminal is always false"
out=$(invoke result.silent '{"source_id":"slack-captain-C0TESTCHAN","sequence":1,"content":"x"}')
assert_equals false "$(printf '%s' "$out" | jq -r .result.value)" "silent is always false"
pass "terminal and silent stay false so a capture still wakes the host"

content=$'schema=fm-slack-captain.v1\nstatus=messages\nchannel=C0TESTCHAN\nfrom_ts=0\nto_ts=1.0\ncount=1\nuntrusted=0\nreason=\n\n{"ts":"1.0","user":"U1","trusted":true,"text":"hi"}\n'
out=$(invoke result.classify "$(jq -nc --arg content "$content" '{source_id:"s",sequence:1,content:$content}')")
assert_equals messages "$(printf '%s' "$out" | jq -r .result.classification)" "classify messages"
pass "result.classify uses the native classifier"

out=$(invoke source.poll '{"source_id":"s","config_ref":"not-paths"}')
assert_equals false "$(printf '%s' "$out" | jq -r .ok)" "bad config_ref fails"
assert_equals invalid-request "$(printf '%s' "$out" | jq -r .error.code)" "bad config_ref code"
pass "source.poll refuses a malformed config_ref"

home="$TMP_ROOT/home"
mkdir -p "$home/state/slack-captain" "$home/config"
printf 'channel=C0TESTCHAN\n' > "$home/config/slack-captain"
printf 'SLACK_BOT_TOKEN=xoxb-fake\n' > "$home/.env"
ref="config=$home/config/slack-captain,state=$home/state/slack-captain,token=$home/.env"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
out=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && out=$arg
  prev=$arg
done
[ -n "$out" ] || exit 1
printf '{"ok":true,"messages":[]}\n' > "$out"
exit 0
SH
chmod +x "$FAKEBIN/curl"
out=$(PATH="$FAKEBIN:$PATH" SLACK_CAPTAIN_MAX_LOOPS=1 SLACK_CAPTAIN_INTERVAL=0 \
  invoke source.poll "$(jq -nc --arg ref "$ref" '{source_id:"s",config_ref:$ref}')")
assert_equals true "$(printf '%s' "$out" | jq -r .ok)" "quiet poll ok"
assert_equals no-result "$(printf '%s' "$out" | jq -r .result.status)" "quiet poll is no-result"
pass "source.poll maps a quiet channel to no-result"
