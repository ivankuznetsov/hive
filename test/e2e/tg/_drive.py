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
                break
        if target:
            break
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


def drive_voice(client, bot, project, fixture_path, expected_text):
    """Send a Telegram voice note, confirm its transcript, tap project, assert ack."""
    if not client.is_user_authorized():
        print("FAIL driver not authorized; run login.py first")
        return 1

    baseline = max((m.id for m in client.iter_messages(bot, limit=1)), default=0)
    print(f"VOICE_FIXTURE={fixture_path}")
    client.send_file(bot, fixture_path, voice_note=True)

    transcript = wait_for(
        client,
        bot,
        lambda m: bool(m.buttons) and expected_text.lower() in (m.message or "").lower(),
        timeout=90,
        after_id=baseline,
    )
    if not transcript:
        print(f"FAIL no transcript confirmation containing {expected_text!r}")
        return 1

    confirm = None
    for row in transcript.buttons:
        for btn in row:
            if btn.text == "Confirm":
                confirm = btn
                break
        if confirm:
            break
    if not confirm:
        print("FAIL transcript message had no Confirm button")
        return 1
    confirm.click()

    picker = wait_for(client, bot, lambda m: bool(m.buttons), after_id=transcript.id)
    if not picker:
        print("FAIL no project picker appeared after confirming transcript")
        return 1

    target = None
    for row in picker.buttons:
        for btn in row:
            if btn.text.replace("★", "").strip() == project:
                target = btn
                break
        if target:
            break
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
    print(f"{'PASS' if ok else 'FAIL'} voice_ack={ack.message!r}")
    return 0 if ok else 1


def drive_voice_answer(client, bot, slug, fixture_path, expected_text, answer_path=None):
    """Start /answer for a seeded brainstorm task, answer Q1 by voice, assert disk write."""
    if not client.is_user_authorized():
        print("FAIL driver not authorized; run login.py first")
        return 1

    baseline = max((m.id for m in client.iter_messages(bot, limit=1)), default=0)
    print(f"VOICE_ANSWER_SLUG={slug}")
    client.send_message(bot, f"/answer {slug}")

    prompt = wait_for(
        client,
        bot,
        lambda m: "Q1:" in (m.message or "") and "Reply with your answer" in (m.message or ""),
        after_id=baseline,
    )
    if not prompt:
        print(f"FAIL no answer prompt appeared for {slug!r}")
        return 1

    client.send_file(bot, fixture_path, voice_note=True)
    ack = wait_for(
        client,
        bot,
        lambda m: "Got Q1." in (m.message or ""),
        timeout=90,
        after_id=prompt.id,
    )
    if not ack:
        print("FAIL no answer acknowledgment after sending voice note")
        return 1

    if answer_path:
        try:
            with open(answer_path, encoding="utf-8") as fh:
                content = fh.read()
        except OSError as exc:
            print(f"FAIL could not read answer file {answer_path!r}: {exc}")
            return 1
        if expected_text.lower() not in content.lower():
            print(f"FAIL transcript {expected_text!r} not found in {answer_path!r}")
            return 1

    print(f"PASS voice_answer_ack={ack.message!r}")
    return 0


def drive_nudge(client, bot, version, command, after_id=0):
    """Assert the bot proactively pushes the update nudge.

    Unlike the /idea flow, the push is unsolicited: the bot's status loop reads
    the seeded update_check.json and sends "hive <version> is available …". The
    driver sends nothing — it waits for the incoming push and checks both the
    version and the exact update command. `after_id` MUST be a chat baseline
    captured BEFORE the bot was started, so a same-version push left by a prior
    run can't satisfy the wait (false PASS) — and so the real push, which can
    arrive the instant the bot boots, is never excluded (false FAIL).
    """
    if not client.is_user_authorized():
        print("FAIL driver not authorized; run login.py first")
        return 1

    marker = f"{version} is available"
    push = wait_for(client, bot, lambda m: marker in (m.message or ""), after_id=after_id)
    if not push:
        print(f"FAIL no update nudge push containing {marker!r}")
        return 1

    ok = command in push.message
    print(f"{'PASS' if ok else 'FAIL'} nudge={push.message!r}")
    return 0 if ok else 1
