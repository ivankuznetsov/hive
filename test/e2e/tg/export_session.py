#!/usr/bin/env python3
"""Print a Telethon StringSession for the existing hive_e2e file session.

Used once to seed the TG_SESSION GitHub Actions secret (CI can't do an
interactive login). Output is a secret — pipe it straight into
`gh secret set TG_SESSION`, never echo it to a shared log.
"""
import os

from telethon.sync import TelegramClient
from telethon.sessions import StringSession

API_ID = int(os.environ["TG_API_ID"])
API_HASH = os.environ["TG_API_HASH"]
HERE = os.path.dirname(os.path.abspath(__file__))

client = TelegramClient(os.path.join(HERE, "hive_e2e"), API_ID, API_HASH)
client.connect()
try:
    if not client.is_user_authorized():
        raise SystemExit("file session is not authorized; run login.py first")
    ss = StringSession()
    ss.set_dc(client.session.dc_id, client.session.server_address, client.session.port)
    ss.auth_key = client.session.auth_key
    print(StringSession.save(ss))
finally:
    client.disconnect()
