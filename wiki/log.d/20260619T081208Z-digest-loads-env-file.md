---
date: 2026-06-19
slug: digest-loads-env-file
pages: [commands/digest, modules/digest]
---

A daemon-scheduled daily digest was never delivered on an operator box even
though the daemon was running: the `DigestScheduler` dispatched
`hive digest --date <day> --json` every tick, but each child exited 78
(`HIVE_TELEGRAM_BOT_TOKEN must be set`) and the scheduler hot-looped on its
failure backoff. Root cause: the daemon runs as a systemd/detached process
whose environment carries no `HIVE_TELEGRAM_BOT_TOKEN`, and only
`hive bot start` loaded `~/.config/hive/.env` (via `Hive::EnvFile.load!`) —
`hive digest` and `hive daemon` never did, so a manual `hive digest` failed the
same way unless the token was already exported in the shell.

Fix: `Hive::Digest.run` now calls `Hive::EnvFile.load!` for a real send (after
resolving `cfg`, before `Sender#preflight!`). A dry-run never sends, so it
skips the load — matching the dry-run "no token/chat lookup" contract — and an
already-exported env var still wins over the file. Because `~/.local/bin/hive`
is a symlink into the source checkout the daemon runs, the dispatched
`hive digest` child picks this up with no daemon restart. Added
`test/unit/digest/run_test.rb` coverage asserting the env file is loaded once on
a real run and not at all on a dry-run (singleton override; minitest/mock is not
bundled). Refreshed [[commands/digest]] and [[modules/digest]].
