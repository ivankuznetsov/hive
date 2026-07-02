# 2026-07-02 — arch-review-pairing atomic file helper coverage

Refreshed wiki coverage after `arch-review-pairing` extracted
`Hive::AtomicFile` and pointed the two new Telegram pairing state writers at
it. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]],
[[gaps]], and recent [[log]] entries first; `qmd search "AtomicFile atomic
write pairing queue tempfile rename fsync"` had no indexed hits, and the
configured master wiki path had no matching prior context. Inspected the
committed diff plus `lib/hive/atomic_file.rb`,
`lib/hive/bot/pairing_store.rb`,
`lib/hive/bot/pairing_approval_queue.rb`, and
`test/unit/atomic_file_test.rb`.

Added [[modules/atomic_file]] for the shared tempfile/rename/fsync state-write
contract, updated [[modules/bot]] so `PairingStore` and
`PairingApprovalQueue` point at the helper, updated [[testing]] for
`atomic_file_test.rb`, and updated [[gaps]]/[[index]] for source coverage and
the remaining migration debt. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/atomic_file]]
- [[modules/bot]]
- [[testing]]
- [[gaps]]
- [[index]]
