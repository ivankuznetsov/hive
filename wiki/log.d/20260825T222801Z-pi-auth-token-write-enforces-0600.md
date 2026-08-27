# 2026-08-25T22:28:01Z — pi auth token rewrite enforces owner-private mode

## Summary

`Hive::Web::AgentsAuth#write_pi_token` now persists `~/.pi/agent/auth.json`
through `Hive::AtomicFile.write(..., mode: 0o600)` instead of
`File.write(..., perm: 0o600)`. The old call's permission argument only
applied through `O_CREAT` on first creation, so a pre-existing auth.json with
looser modes (e.g. 0644) kept them while fresh secrets were written into it.

Atomic replacement also means readers see the old or new credential bytes,
never a torn write. Covered by
`test_pi_token_writer_replaces_an_existing_loose_mode_file_with_0600` in
`test/unit/web/agents_auth_test.rb`.

## Affected pages

- [[modules/atomic_file]] — new caller class: agent login token persistence.
- [[commands/web]] — the web login relay's pi-token write path is now atomic
  and mode-enforcing.

## Uncertainty

None recorded for this change.
