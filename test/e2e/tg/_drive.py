"""Shared /idea drive logic for the headless E2E harness.

Both entrypoints reuse this: run_e2e.py (owns the bot child, CI path) and
drive_idea.py (bare driver invoked by run_idea_e2e.sh). Keeping the
send -> tap-picker -> assert-ack sequence in one place stops the two
drivers from drifting (e.g. the ack string or the star-prefix label rule).
"""
import time

POLL_INTERVAL_SEC = 1.5
DEFAULT_TIMEOUT_SEC = 40
SCAN_LIMIT = 8
ACK_MARKER = "Captured your idea"


def wait_for(client, bot, predicate, timeout=DEFAULT_TIMEOUT_SEC, after_id=0):
    """Poll the bot chat for the newest incoming message matching predicate."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for msg in client.iter_messages(bot, limit=SCAN_LIMIT):
            if msg.id <= after_id or msg.out:
                continue
            if predicate(msg):
                return msg
        time.sleep(POLL_INTERVAL_SEC)
    return None


def drive(client, bot, project):
    """Send /idea, tap the project picker, assert the capture ack.

    Returns a process exit code (0 PASS / 1 FAIL) and prints a single
    PASS/FAIL line plus the derived idea text (IDEA_TEXT=...).
    """
    if not client.is_user_authorized():
        print("FAIL driver not authorized; run login.py first")
        return 1

    baseline = max((m.id for m in client.iter_messages(bot, limit=1)), default=0)
    nonce = f"e2e ack probe {int(time.time())}"
    print(f"IDEA_TEXT={nonce}")
    client.send_message(bot, f"/idea {nonce}")

    picker = wait_for(client, bot, lambda m: bool(m.buttons), after_id=baseline)
    if not picker:
        print("FAIL no project picker appeared")
        return 1

    # Button label may be plain or star-prefixed for the last-used project.
    target = None
    for row in picker.buttons:
        for btn in row:
            if btn.text.replace("★", "").strip() == project:
                target = btn
    if not target:
        labels = [b.text for row in picker.buttons for b in row]
        print(f"FAIL project '{project}' not in picker; saw {labels}")
        return 1
    target.click()

    ack = wait_for(client, bot, lambda m: ACK_MARKER in (m.message or ""),
                   after_id=picker.id)
    if not ack:
        print("FAIL no capture acknowledgment after tapping picker")
        return 1

    ok = project in ack.message
    print(f"{'PASS' if ok else 'FAIL'} ack={ack.message!r}")
    return 0 if ok else 1
