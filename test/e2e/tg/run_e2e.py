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
    devnull = open(os.devnull, "w")
    # CI installs gems via bundler, so the bot must run under `bundle exec`;
    # locally BOT_LAUNCHER defaults to a bare `ruby`.
    launcher = os.environ.get("BOT_LAUNCHER", "ruby").split()
    proc = subprocess.Popen(
        [*launcher, os.path.join(HERE, "bot_harness.rb")],
        env=env, stdout=devnull, stderr=devnull,
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


def wait_for(client, predicate, timeout=40, after_id=0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for msg in client.iter_messages(BOT, limit=8):
            if msg.id <= after_id or msg.out:
                continue
            if predicate(msg):
                return msg
        time.sleep(1.5)
    return None


def _session():
    # CI passes the session as a StringSession via TG_SESSION (no interactive
    # login possible); locally we fall back to the hive_e2e file session.
    s = os.environ.get("TG_SESSION")
    return StringSession(s) if s else SESSION


def drive():
    client = TelegramClient(_session(), API_ID, API_HASH)
    client.connect()
    try:
        if not client.is_user_authorized():
            print("FAIL driver not authorized"); return 1
        baseline = max((m.id for m in client.iter_messages(BOT, limit=1)), default=0)
        nonce = f"e2e ack probe {int(time.time())}"
        print(f"IDEA_TEXT={nonce}")
        client.send_message(BOT, f"/idea {nonce}")
        picker = wait_for(client, lambda m: bool(m.buttons), after_id=baseline)
        if not picker:
            print("FAIL no project picker"); return 1
        target = None
        for row in picker.buttons:
            for btn in row:
                if btn.text.replace("★", "").strip() == PROJECT:
                    target = btn
        if not target:
            print("FAIL project button not found:",
                  [b.text for r in picker.buttons for b in r]); return 1
        target.click()
        ack = wait_for(client, lambda m: "Captured your idea" in (m.message or ""),
                       timeout=40, after_id=picker.id)
        if not ack:
            print("FAIL no capture acknowledgment"); return 1
        ok = PROJECT in ack.message
        print(f"{'PASS' if ok else 'FAIL'} ack={ack.message!r}")
        return 0 if ok else 1
    finally:
        client.disconnect()


def main():
    proc = start_bot()
    if proc is None:
        print("FAIL bot did not start"); return 1
    try:
        return drive()
    finally:
        stop_bot(proc)


if __name__ == "__main__":
    sys.exit(main())
