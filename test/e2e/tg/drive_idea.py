#!/usr/bin/env python3
"""Headless E2E driver for the hive bot /idea flow.

Acts as a real Telegram user (Telethon): sends `/idea <nonce>` to the test
bot, taps the project picker button, and asserts the bot replies with the
capture acknowledgment. Prints a single PASS/FAIL line and exits 0/1.

Expects a bot already polling the test token (run_idea_e2e.sh owns that).
The shared send -> tap -> assert sequence lives in _drive.py.

Env: TG_API_ID, TG_API_HASH, TG_BOT_USERNAME, TG_CAPTURE_PROJECT (default shipped).
"""
import os
import sys

from telethon.sync import TelegramClient

from _drive import drive

API_ID = int(os.environ["TG_API_ID"])
API_HASH = os.environ["TG_API_HASH"]
BOT = os.environ["TG_BOT_USERNAME"]
PROJECT = os.environ.get("TG_CAPTURE_PROJECT", "shipped")
HERE = os.path.dirname(os.path.abspath(__file__))
SESSION = os.path.join(HERE, "hive_e2e")


def main():
    client = TelegramClient(SESSION, API_ID, API_HASH)
    client.connect()
    try:
        return drive(client, BOT, PROJECT)
    finally:
        client.disconnect()


if __name__ == "__main__":
    sys.exit(main())
