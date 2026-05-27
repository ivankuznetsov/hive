#!/usr/bin/env python3
"""Single-process headless E2E: own the test bot as a child, drive it, kill it.

The bot child's stdout/stderr go to /dev/null (it logs to /tmp/hive-e2e-bot.log
on its own), so it never holds this process's stdout pipe. We stay foreground
the whole time and exit 0/1 with a PASS/FAIL line.
"""
import os
import sys
import time
import signal
import subprocess

from telethon.sync import TelegramClient
from telethon.sessions import StringSession

from _drive import drive

REPO = os.environ.get("HIVE_REPO", "/home/asterio/Dev/hive")
HERE = os.path.join(REPO, "test/e2e/tg")
API_ID = int(os.environ["TG_API_ID"])
API_HASH = os.environ["TG_API_HASH"]
BOT = os.environ.get("TG_BOT_USERNAME", "Testivanshive_bot")
PROJECT = os.environ.get("TG_CAPTURE_PROJECT", "shipped")
DRIVER_ID = os.environ["TG_DRIVER_ID"]
SESSION = os.path.join(HERE, "hive_e2e")
LOG = "/tmp/hive-e2e-bot.log"


def start_bot():
    for p in ("/tmp/hive-e2e-bot.log", "/tmp/hive-e2e-bot.last_seen",
              "/tmp/hive-e2e-bot.alerts", "/tmp/hive-e2e-bot.pid"):
        try:
            os.remove(p)
        except FileNotFoundError:
            pass
    env = dict(os.environ, HIVE_TEST_ALLOWLIST=DRIVER_ID)
    # CI installs gems via bundler, so the bot must run under `bundle exec`;
    # locally BOT_LAUNCHER defaults to a bare `ruby`. The bot logs to LOG on
    # its own, so its stdout/stderr go to DEVNULL (subprocess owns/closes the FD).
    launcher = os.environ.get("BOT_LAUNCHER", "ruby").split()
    proc = subprocess.Popen(
        [*launcher, os.path.join(HERE, "bot_harness.rb")],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        stdin=subprocess.DEVNULL, start_new_session=True, cwd=REPO,
    )
    for _ in range(40):
        if proc.poll() is not None:
            return None
        try:
            if '"event":"bot_started"' in open(LOG).read():
                return proc
        except FileNotFoundError:
            pass
        time.sleep(0.5)
    return proc  # started but no log line; let driver try anyway


def stop_bot(proc):
    if not proc:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait(timeout=5)


def _session():
    # CI passes the session as a StringSession via TG_SESSION (no interactive
    # login possible); locally we fall back to the hive_e2e file session.
    s = os.environ.get("TG_SESSION")
    return StringSession(s) if s else SESSION


def main():
    proc = start_bot()
    if proc is None:
        print("FAIL bot did not start"); return 1
    client = TelegramClient(_session(), API_ID, API_HASH)
    client.connect()
    try:
        return drive(client, BOT, PROJECT)
    finally:
        client.disconnect()
        stop_bot(proc)


if __name__ == "__main__":
    sys.exit(main())
