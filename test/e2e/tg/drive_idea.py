#!/usr/bin/env python3
"""Headless E2E driver for the hive bot /idea flow.

Acts as a real Telegram user (Telethon): sends `/idea <nonce>` to the test
bot, taps the project picker button, and asserts the bot replies with the
capture acknowledgment. Prints a single PASS/FAIL line and exits 0/1.

Env: TG_API_ID, TG_API_HASH, TG_BOT_USERNAME, TG_CAPTURE_PROJECT (default shipped).
Prints the derived idea text on stdout as `IDEA_TEXT=...` so the orchestrator
can clean up the scratch capture.
"""
import os
import sys
import time

from telethon.sync import TelegramClient

API_ID = int(os.environ["TG_API_ID"])
API_HASH = os.environ["TG_API_HASH"]
BOT = os.environ["TG_BOT_USERNAME"]
PROJECT = os.environ.get("TG_CAPTURE_PROJECT", "shipped")
HERE = os.path.dirname(os.path.abspath(__file__))
SESSION = os.path.join(HERE, "hive_e2e")

NONCE = f"e2e ack probe {int(time.time())}"


def wait_for(client, predicate, timeout=40, after_id=0):
    """Poll the bot chat for the newest incoming message matching predicate."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for msg in client.iter_messages(BOT, limit=8):
            if msg.id <= after_id or msg.out:
                continue
            if predicate(msg):
                return msg
        time.sleep(1.5)
    return None


def main():
    client = TelegramClient(SESSION, API_ID, API_HASH)
    client.connect()
    try:
        if not client.is_user_authorized():
            print("FAIL not authorized; run login.py first")
            return 1

        baseline = max((m.id for m in client.iter_messages(BOT, limit=1)), default=0)
        print(f"IDEA_TEXT={NONCE}")
        client.send_message(BOT, f"/idea {NONCE}")

        picker = wait_for(client, lambda m: bool(m.buttons), after_id=baseline)
        if not picker:
            print("FAIL no project picker appeared")
            return 1

        # Find and click the target project button (label may be plain or
        # star-prefixed for the last-used project).
        target = None
        for row in picker.buttons:
            for btn in row:
                if btn.text.replace("★", "").strip() == PROJECT:
                    target = btn
        if not target:
            labels = [b.text for row in picker.buttons for b in row]
            print(f"FAIL project '{PROJECT}' not in picker; saw {labels}")
            return 1
        target.click()

        ack = wait_for(
            client,
            lambda m: "Captured your idea" in (m.message or ""),
            timeout=40,
            after_id=picker.id,
        )
        if not ack:
            print("FAIL no capture acknowledgment after tapping picker")
            return 1

        ok = PROJECT in ack.message
        print(f"{'PASS' if ok else 'FAIL'} ack={ack.message!r}")
        return 0 if ok else 1
    finally:
        client.disconnect()


if __name__ == "__main__":
    sys.exit(main())
