#!/usr/bin/env python3
"""One-time interactive login for the headless E2E Telegram user-client.

Usage:
  python login.py request            # send the SMS/app code to TG_PHONE
  python login.py confirm <CODE>     # sign in (or sign up a new account)
  python login.py confirm <CODE> --password <2FA>   # if 2FA is set
  python login.py whoami             # print the logged-in account id/name

Reads TG_API_ID / TG_API_HASH / TG_PHONE from the environment.
Persists the session to hive_e2e.session and the code hash to .code_hash.
Uses explicit connect()/disconnect() so Telethon never prompts on stdin.
"""
import os
import sys
import json

from telethon.sync import TelegramClient
from telethon.tl.functions.auth import ResendCodeRequest
from telethon.errors import (
    PhoneNumberUnoccupiedError,
    SessionPasswordNeededError,
)

API_ID = int(os.environ["TG_API_ID"])
API_HASH = os.environ["TG_API_HASH"]
PHONE = os.environ["TG_PHONE"]
HERE = os.path.dirname(os.path.abspath(__file__))
SESSION = os.path.join(HERE, "hive_e2e")
HASH_FILE = os.path.join(HERE, ".code_hash")


def _client():
    c = TelegramClient(SESSION, API_ID, API_HASH)
    c.connect()
    return c


def request():
    client = _client()
    try:
        if client.is_user_authorized():
            me = client.get_me()
            print(f"ALREADY_AUTHORIZED id={me.id} name={me.first_name!r}")
            return
        sent = client.send_code_request(PHONE)
        with open(HASH_FILE, "w") as fh:
            fh.write(sent.phone_code_hash)
        print(f"CODE_SENT type={sent.type.__class__.__name__}")
        print("Now run: python login.py confirm <CODE>")
    finally:
        client.disconnect()


def resend():
    with open(HASH_FILE) as fh:
        phone_code_hash = fh.read().strip()
    client = _client()
    try:
        sent = client(ResendCodeRequest(phone_number=PHONE, phone_code_hash=phone_code_hash))
        with open(HASH_FILE, "w") as fh:
            fh.write(sent.phone_code_hash)
        nxt = sent.next_type.__class__.__name__ if sent.next_type else None
        print(f"RESENT type={sent.type.__class__.__name__} next_type={nxt}")
    finally:
        client.disconnect()


def confirm(code, password=None):
    with open(HASH_FILE) as fh:
        phone_code_hash = fh.read().strip()
    client = _client()
    try:
        try:
            client.sign_in(phone=PHONE, code=code, phone_code_hash=phone_code_hash)
        except PhoneNumberUnoccupiedError:
            client.sign_up(code=code, first_name="Hive E2E",
                           phone=PHONE, phone_code_hash=phone_code_hash)
        except SessionPasswordNeededError:
            if not password:
                print("2FA_REQUIRED: re-run with --password <your-2fa-password>")
                sys.exit(2)
            client.sign_in(password=password)
        me = client.get_me()
        print(f"LOGGED_IN id={me.id} name={me.first_name!r} username={me.username!r}")
    finally:
        client.disconnect()


def whoami():
    client = _client()
    try:
        if not client.is_user_authorized():
            print("NOT_AUTHORIZED")
            sys.exit(1)
        me = client.get_me()
        print(json.dumps({"id": me.id, "first_name": me.first_name,
                          "username": me.username, "phone": me.phone}))
    finally:
        client.disconnect()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "request":
        request()
    elif cmd == "resend":
        resend()
    elif cmd == "confirm":
        pw = None
        if "--password" in sys.argv:
            pw = sys.argv[sys.argv.index("--password") + 1]
        confirm(sys.argv[2], pw)
    elif cmd == "whoami":
        whoami()
    else:
        print(__doc__)
        sys.exit(1)
