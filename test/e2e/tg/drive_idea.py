#!/usr/bin/env python3
"""Headless E2E driver for the hive bot /idea flow.

Acts as a real Telegram user (Telethon): sends `/idea <nonce>` to the test
bot, taps the project picker button, and asserts the bot replies with the
capture acknowledgment. Prints a single PASS/FAIL line and exits 0/1.

Expects a bot already polling the test token (run_idea_e2e.sh owns that).
The shared send -> tap -> assert sequence lives in _drive.py.

Env: TG_API_ID, TG_API_HASH, TG_BOT_USERNAME, TG_CAPTURE_PROJECT (default shipped).
Set TG_IDEA_MODE=voice with TG_VOICE_FIXTURE and HIVE_WHISPER_API_KEY for the
real voice-note transcription path.
"""
import os
import sys

from telethon.sync import TelegramClient

from _drive import drive, drive_voice

API_ID = int(os.environ["TG_API_ID"])
API_HASH = os.environ["TG_API_HASH"]
BOT = os.environ["TG_BOT_USERNAME"]
PROJECT = os.environ.get("TG_CAPTURE_PROJECT", "shipped")
MODE = os.environ.get("TG_IDEA_MODE", "text")
VOICE_FIXTURE = os.environ.get("TG_VOICE_FIXTURE")
VOICE_EXPECT = os.environ.get("TG_VOICE_EXPECT", "voice idea")
HERE = os.path.dirname(os.path.abspath(__file__))
SESSION = os.path.join(HERE, "hive_e2e")


def main():
    client = TelegramClient(SESSION, API_ID, API_HASH)
    client.connect()
    try:
        if MODE == "voice":
            if not os.environ.get("HIVE_WHISPER_API_KEY"):
                # Voice mode is requested explicitly, so this is a hard
                # configuration failure. The shell wrapper already hard-requires
                # HIVE_TEST_BOT_TOKEN; keep the Whisper-backed path equally
                # honest instead of reporting a green skip.
                print("FAIL voice mode requires HIVE_WHISPER_API_KEY")
                return 1
            if not VOICE_FIXTURE or not os.path.exists(VOICE_FIXTURE):
                # The secret IS set, so the voice path MUST run. A missing
                # fixture is a hard FAILURE, not a skip: U8 requires a
                # checked-in speech sample, and silently returning 0 here would
                # let the unimplemented path masquerade as passing.
                print(f"FAIL voice fixture not found at {VOICE_FIXTURE!r}; "
                      "U8 requires a checked-in speech sample saying "
                      f"{VOICE_EXPECT!r} (default test/fixtures/voice/voice-idea.oga)")
                return 1
            return drive_voice(client, BOT, PROJECT, VOICE_FIXTURE, VOICE_EXPECT)
        return drive(client, BOT, PROJECT)
    finally:
        client.disconnect()


if __name__ == "__main__":
    sys.exit(main())
