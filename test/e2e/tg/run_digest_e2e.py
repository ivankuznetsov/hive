#!/usr/bin/env python3
"""Deliver a formatted digest through Hive to the existing private test chat."""
import json
import os
import subprocess
import tempfile
import time

from telethon.sync import TelegramClient
from telethon.tl.types import MessageEntityBold, MessageEntityTextUrl
from run_e2e import API_HASH, API_ID, BOT, REPO, _session

DATE = "2026-09-01"
DOCUMENT = """# Recent changes — 1 September 2026

A calmer workspace and clearer task controls.

## Hive

### Cancel unwanted work
You can now **cancel a task** while keeping its work available for later.

[PR #1423](https://github.com/ivankuznetsov/hive/pull/1423)
"""
SEED = r'''
require "hive"
require "hive/daily_digest/store"
require "hive/daily_digest/migration"
require "json"
require "yaml"
root = ENV.fetch("HIVE_HOME")
File.write(File.join(root, "config.yml"), {
  "bot" => {"chat_id_allowlist" => [Integer(ENV.fetch("TG_DRIVER_ID"))]},
  "web" => {"origin" => "http://127.0.0.1"},
  "daily_digest" => {"enabled" => true, "time_zone" => "UTC"}
}.to_yaml)
Hive::DailyDigest::Migration.ensure!
start = Time.utc(2026, 9, 1)
Hive::DailyDigest::Store.new.write_base(
  "schema" => "hive-digest-record", "schema_version" => 1,
  "interval_id" => "c" * 64, "local_date" => "2026-09-01", "sequence" => 1,
  "time_zone" => "UTC", "starts_at" => start.iso8601,
  "ends_at" => (start + 86400).iso8601, "duration_seconds" => 86400,
  "boundary_kind" => "calendar_day", "cutover" => nil,
  "lifecycle" => "closed", "closed_at" => (start + 86401).iso8601,
  "completeness" => "complete", "content" => "non_empty",
  "last_materialized_at" => (start + 86401).iso8601,
  "projects" => [], "items" => [], "attention" => [], "gaps" => [],
  "source_frontiers" => {}, "document" => STDIN.read
)
'''


def run(env, args, input_text=None):
    result = subprocess.run(["bundle", "exec", "ruby", *args], cwd=REPO,
                            env=env, input=input_text, text=True, capture_output=True)
    if result.returncode:
        # Errors can include transport details; never echo credentials or raw output.
        raise RuntimeError(f"Hive command failed with exit {result.returncode}")
    return result.stdout


def main():
    with tempfile.TemporaryDirectory(prefix="hive-digest-e2e-") as home:
        env = dict(os.environ, HIVE_HOME=home,
                   HIVE_TELEGRAM_BOT_TOKEN=os.environ["HIVE_TEST_BOT_TOKEN"])
        run(env, ["-Ilib", "-e", SEED], DOCUMENT)
        client = TelegramClient(_session(), API_ID, API_HASH)
        client.connect()
        try:
            assert client.is_user_authorized(), "Telegram test driver is not authorized"
            baseline = max((m.id for m in client.iter_messages(BOT, limit=1)), default=0)
            result = json.loads(run(env, ["bin/hive", "digest", "send", "--date", DATE, "--json"]))
            assert result["outcome"] == "sent", "Digest was not sent"
            deadline = time.monotonic() + 30
            received = None
            while time.monotonic() < deadline:
                messages = list(client.iter_messages(BOT, min_id=baseline, limit=10))
                received = next((m for m in messages if "Cancel unwanted work" in (m.message or "")), None)
                if received:
                    break
                time.sleep(1)
            assert received, "Digest did not arrive in the test chat"
            assert "**" not in received.message and "##" not in received.message
            assert any(isinstance(e, MessageEntityBold) for e in received.entities or [])
            assert any(isinstance(e, MessageEntityTextUrl) and e.url ==
                       "https://github.com/ivankuznetsov/hive/pull/1423"
                       for e in received.entities or [])
            repeated = json.loads(run(env, ["bin/hive", "digest", "send", "--date", DATE, "--json"]))
            assert repeated["deduplicated"] is True, "Repeat delivery was not deduplicated"
            time.sleep(2)
            assert not list(client.iter_messages(BOT, min_id=received.id, limit=10)), "Duplicate message arrived"
            print("PASS: formatted digest received with bold headings and PR link; repeat deduplicated")
        finally:
            client.disconnect()


if __name__ == "__main__":
    main()
