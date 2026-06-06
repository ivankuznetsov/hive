#!/usr/bin/env bash
# End-to-end test of the bot /idea capture-acknowledgment flow, fully headless.
# Starts the fixed bot (test token, /tmp state, driver in allowlist), drives it
# with the Telethon user-client, asserts the ack, then restores the scratch
# project's state repo to its pre-test HEAD. Never touches the production bot.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="${HIVE_E2E_REPO:-$(cd "$SCRIPT_DIR/../../.." && pwd -P)}"
HERE="$REPO/test/e2e/tg"
cd "$REPO" || exit 1

set -a
# shellcheck source=/dev/null  # .env is gitignored, not present at lint time
[ ! -f ./.env ] || . ./.env
set +a
: "${HIVE_TEST_BOT_TOKEN:?}"; : "${TG_API_ID:?}"; : "${TG_API_HASH:?}"; : "${TG_DRIVER_ID:?}"
export HIVE_TEST_ALLOWLIST="$TG_DRIVER_ID"
export TG_BOT_USERNAME="Testivanshive_bot"
export TG_CAPTURE_PROJECT="${TG_CAPTURE_PROJECT:-shipped}"
export TG_IDEA_MODE="${TG_IDEA_MODE:-text}"
export TG_VOICE_EXPECT="${TG_VOICE_EXPECT:-voice idea}"
if [ "$TG_IDEA_MODE" = "voice" ]; then
  export TG_VOICE_FIXTURE="${TG_VOICE_FIXTURE:-$REPO/test/fixtures/voice/voice-idea.oga}"
  export TG_VOICE_ANSWER_EXPECT="${TG_VOICE_ANSWER_EXPECT:-$TG_VOICE_EXPECT}"
  if [ -z "${HIVE_WHISPER_API_KEY:-}" ]; then
    echo "voice E2E requested but HIVE_WHISPER_API_KEY is unset; driver will fail voice mode"
  fi
fi

# Resolve the scratch project's state repo. The `&.` guards an unregistered
# project (find_project -> nil): without it, an empty STATE_REPO would make the
# cleanup `git reset --hard` below operate on the MAIN hive checkout (cwd).
STATE_REPO="$(ruby -Ilib -e 'require "hive"; require "hive/config"; p = Hive::Config.find_project(ENV["TG_CAPTURE_PROJECT"]); print(p&.fetch("hive_state_path", nil) || "")')"
if [ -z "$STATE_REPO" ] || [ "$(git -C "$STATE_REPO" rev-parse --show-toplevel 2>/dev/null)" != "$(cd "$STATE_REPO" 2>/dev/null && pwd -P)" ]; then
  echo "ERROR: TG_CAPTURE_PROJECT='$TG_CAPTURE_PROJECT' is not a registered hive project with its own state git repo." >&2
  echo "       Refusing to run — cleanup would otherwise git-reset the wrong repo. Register it with 'hive init' first." >&2
  exit 1
fi
BASELINE="$(git -C "$STATE_REPO" rev-parse HEAD)"
echo "scratch state repo: $STATE_REPO @ baseline $BASELINE"

if [ "$TG_IDEA_MODE" = "voice" ]; then
  export TG_VOICE_ANSWER_SLUG="${TG_VOICE_ANSWER_SLUG:-voice-answer-e2e-$(date +%s)}"
  export TG_VOICE_ANSWER_PATH="$STATE_REPO/stages/2-brainstorm/$TG_VOICE_ANSWER_SLUG/brainstorm.md"
  mkdir -p "$(dirname "$TG_VOICE_ANSWER_PATH")"
  cat >"$TG_VOICE_ANSWER_PATH" <<MARKDOWN
## Round 1

### Q1. What answer should the voice E2E write?

### A1.

### Q2. What should happen next?

### A2.

<!-- WAITING -->
MARKDOWN
  echo "seeded voice-answer task: $TG_VOICE_ANSWER_SLUG"
fi

# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
  [ -n "${BOT_PID:-}" ] && kill "$BOT_PID" 2>/dev/null
  sleep 1; [ -n "${BOT_PID:-}" ] && kill -9 "$BOT_PID" 2>/dev/null
  # Restore scratch project state to pre-test HEAD (drops the test capture
  # commit + its dispatch logs). Safe: baseline was captured this run.
  if [ -n "${BASELINE:-}" ]; then
    git -C "$STATE_REPO" reset --hard "$BASELINE" >/dev/null 2>&1
    git -C "$STATE_REPO" clean -fdq stages/1-inbox 2>/dev/null
    if [ -n "${TG_VOICE_ANSWER_SLUG:-}" ]; then
      git -C "$STATE_REPO" clean -fdq "stages/2-brainstorm/$TG_VOICE_ANSWER_SLUG" 2>/dev/null
    fi
    echo "restored $STATE_REPO to $BASELINE"
  fi
  rm -f /tmp/hive-e2e-bot.log /tmp/hive-e2e-bot.last_seen /tmp/hive-e2e-bot.alerts /tmp/hive-e2e-bot.pid /tmp/hive-e2e-bot.out
}
trap cleanup EXIT

rm -f /tmp/hive-e2e-bot.*
ruby "$HERE/bot_harness.rb" >/tmp/hive-e2e-bot.out 2>&1 &
BOT_PID=$!

# Wait for the bot to come up (bot_started in its log).
for _ in $(seq 1 30); do
  grep -q '"event":"bot_started"' /tmp/hive-e2e-bot.log 2>/dev/null && break
  kill -0 "$BOT_PID" 2>/dev/null || { echo "BOT DIED:"; cat /tmp/hive-e2e-bot.out; exit 1; }
  sleep 0.5
done
echo "bot up (pid $BOT_PID); driving..."

# shellcheck source=/dev/null  # venv activate script is generated, not in-repo
. "$HERE/.venv/bin/activate"
python "$HERE/drive_idea.py"
RESULT=$?

echo "=== bot dispatch events ==="
grep -E '"event":"(update_received|command_completed|send_failure)"' /tmp/hive-e2e-bot.log 2>/dev/null | tail -6
exit $RESULT
