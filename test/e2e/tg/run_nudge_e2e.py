#!/usr/bin/env python3
"""Headless E2E: the bot proactively pushes the update-available nudge.

Seeds a nudge into the bot's update_check.json, starts the test bot as a child
(reusing run_e2e.py's lifecycle), and asserts via Telethon that the bot pushes
"hive <ver> is available … Update: <command>" to the driver account. The driver
sends nothing — the push is unsolicited, fired from the bot's status loop.

Unlike the daemon-side e2e scenarios, no release probe runs here: we seed the
nudge directly, so this isolates the bot's push surface end-to-end over real
Telegram. Manual / secrets-gated, same as run_e2e.py.
"""
import json
import os
import subprocess
import sys

from telethon.sync import TelegramClient

from _drive import drive_nudge
from run_e2e import API_HASH, API_ID, BOT, REPO, _session, start_bot, stop_bot

VERSION = "999.0.0"
COMMAND = "brew upgrade ivankuznetsov/hive/hive"


def seed_nudge():
    # Resolve the bot's update_check.json path under the SAME env the bot runs
    # with, so the seed lands exactly where the bot's status loop reads it.
    path = subprocess.check_output(
        ["ruby", "-Ilib", "-e",
         'require "hive/update_check/state"; print Hive::UpdateCheck::State.default_path'],
        cwd=REPO, text=True).strip()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump({
            "schema_version": 1,
            "last_check_at": None,
            "last_notified_version": None,  # null → the bot pushes once
            "nudge": {"latest": VERSION, "channel": "brew", "command": COMMAND},
        }, fh)
    print(f"seeded nudge ({VERSION}) at {path}")


def main():
    seed_nudge()
    proc = start_bot()
    if proc is None:
        return 1  # start_bot already printed the FAIL + bot output
    client = TelegramClient(_session(), API_ID, API_HASH)
    client.connect()
    try:
        return drive_nudge(client, BOT, VERSION, COMMAND)
    finally:
        client.disconnect()
        stop_bot(proc)


if __name__ == "__main__":
    sys.exit(main())
