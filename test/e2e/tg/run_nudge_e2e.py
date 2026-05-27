#!/usr/bin/env python3
"""Headless E2E: the bot proactively pushes the update-available nudge.

Seeds a nudge into the bot's update_check.json, starts the test bot as a child
(reusing run_e2e.py's lifecycle), and asserts via Telethon that the bot pushes
"hive <ver> is available … Update: <command>" to the driver account. The driver
sends nothing — the push is unsolicited, fired from the bot's status loop.

Runs under an isolated HIVE_HOME (a fresh tmpdir) so neither the seed nor the
bot ever touches the developer's real ~/.local/state/hive on a local run. No
release probe runs — we seed the nudge directly, isolating the bot's push
surface end-to-end over real Telegram. Manual / secrets-gated, same as run_e2e.py.
"""
import json
import os
import subprocess
import sys
import tempfile

from telethon.sync import TelegramClient

from _drive import drive_nudge
from run_e2e import API_HASH, API_ID, BOT, REPO, _session, start_bot, stop_bot

VERSION = "999.0.0"
COMMAND = "brew upgrade ivankuznetsov/hive/hive"


def seed_nudge(hive_home):
    """Write a nudge to the bot's update_check.json under the isolated HIVE_HOME.

    Resolves the path via the SAME env the bot runs with (so the seed lands
    where the status loop reads it), then refuses to write unless it is inside
    the isolated home — a guard against ever clobbering real developer state.
    Returns the path on success, None on any failure (with a FAIL line).
    """
    env = dict(os.environ, HIVE_HOME=hive_home)
    try:
        path = subprocess.check_output(
            ["ruby", "-Ilib", "-e",
             'require "hive/update_check/state"; print Hive::UpdateCheck::State.default_path'],
            cwd=REPO, env=env, text=True, stderr=subprocess.STDOUT).strip()
    except subprocess.CalledProcessError as e:
        print(f"FAIL could not resolve update_check.json path: {e.output.strip()}")
        return None
    if not path or not os.path.realpath(path).startswith(os.path.realpath(hive_home) + os.sep):
        print(f"FAIL refusing to seed outside the isolated HIVE_HOME (resolved {path!r})")
        return None
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({
            "schema_version": 1,
            "last_check_at": None,
            "last_notified_version": None,  # null → the bot pushes once
            "nudge": {"latest": VERSION, "channel": "brew", "command": COMMAND},
        }, fh)
    print(f"seeded nudge ({VERSION}) at {path}")
    return path


def main():
    hive_home = tempfile.mkdtemp(prefix="hive-nudge-e2e-")
    os.environ["HIVE_HOME"] = hive_home  # isolates the seed AND the spawned bot
    if seed_nudge(hive_home) is None:
        return 1
    client = TelegramClient(_session(), API_ID, API_HASH)
    client.connect()
    try:
        if not client.is_user_authorized():
            print("FAIL driver not authorized; run login.py first")
            return 1
        # Baseline the chat BEFORE the bot starts pushing, so the wait excludes
        # any same-version push from a prior run but catches this run's push
        # even though it can arrive the instant the bot boots.
        baseline = max((m.id for m in client.iter_messages(BOT, limit=1)), default=0)
        proc = start_bot()
        if proc is None:
            return 1  # start_bot already printed the FAIL + bot output
        try:
            return drive_nudge(client, BOT, VERSION, COMMAND, after_id=baseline)
        finally:
            stop_bot(proc)
    finally:
        client.disconnect()


if __name__ == "__main__":
    sys.exit(main())
