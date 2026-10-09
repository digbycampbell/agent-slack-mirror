#!/usr/bin/env bash
# Shared primitives for this package's behavior tests.
# shellcheck disable=SC2034
set -u

if [ -n "${SLACK_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
SLACK_TEST_LIB_SOURCED=1

umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

SLACK_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.slack-test-cleanup.$$.XXXXXX") || return 1

fm_test_cleanup() {
  local dir
  if [ -f "$SLACK_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      rm -rf -- "$dir"
    done < "$SLACK_TEST_CLEANUP_REGISTRY"
    rm -f -- "$SLACK_TEST_CLEANUP_REGISTRY"
  fi
}

fm_test_tmproot() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/${1:-slack-test}.XXXXXX") || return 1
  printf '%s\n' "$dir" >> "$SLACK_TEST_CLEANUP_REGISTRY"
  printf '%s\n' "$dir"
}

trap fm_test_cleanup EXIT INT TERM

fm_fakebin() {
  local dir="$1/fakebin"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

assert_equals() {
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

assert_present() {
  [ -e "$1" ] || fail "$2"
}

# Map a fixture home (config/, state/, .env) onto the package environment
# contract. The package itself never derives those paths from a home.
use_home() {
  local home=$1
  export SLACK_CONFIG_FILE="$home/config/slack-captain"
  export SLACK_STATE_DIR="$home/state/slack-captain"
  export SLACK_TOKEN_FILE="$home/.env"
  export SLACK_CHANNELS_FILE="$home/config/slack-channels"
  export SLACK_MIRROR_STATE_DIR="$home/state/slack-captain"
  export SLACK_MIRROR_CONFIG_FILE="$home/config/slack-captain"
  export SLACK_MIRROR_POST_CMD="$ROOT/bin/slack-post.sh"
  export SLACK_MIRROR_CMD="$ROOT/slack-mirror.sh"
  export SLACK_CAPTAIN_CMD="$ROOT/bin/slack-captain.sh"
  export SLACK_POST_CMD="$ROOT/bin/slack-post.sh"
}
