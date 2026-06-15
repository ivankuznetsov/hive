### 2026-06-15 — Daily digest review fix pass 3

Applied the accepted findings from stage 6-review pass 3:

- **Wedge fix**: the `digest` verb now ships a non-zero default
  `daemon.child_verb_timeouts` (3600s). A wedged `hive digest` child holds the
  single global digest slot (`can_dispatch_digest?`); without a cap a hung
  `ship_times` `git log` or a black-holed Telegram socket would pin the slot
  forever and disable all future digests. User overrides deep-merge, so the
  backstop survives; `{digest: 0}` disables it.
- `Dispatcher#reap_dry_run` now mirrors `reap_completed`'s digest completion
  hook, so a dry-run daemon clears `DigestScheduler`'s `@pending` marker and no
  longer wedges after one digest.
- `ConcurrencyController#record_dispatch` skips the `@daily_counts` increment
  for `kind: :digest` (the early-return in `record_completion` never refunded
  it → one leaked `[project, date]` entry per day).
- Categorizer now converts agent spawn/run `SystemCallError`s (e.g. a missing
  `digest.agent` binary → `Errno::ENOENT` from `Process.spawn`) to
  `ModelError`, so the existing failed-notice path fires instead of failing
  silently.
- Prompt hardening: `templates/digest_prompt.md.erb` fences every per-item
  field (project, display name, title, body) in the per-spawn nonce tag and
  drops the unused, attacker-influenceable PR URL line.
- Renderer caps the display label (`MAX_LABEL_LENGTH`) before escaping, so an
  overlong label can't push a MarkdownV2 link line past Telegram's chunk
  boundary.
- `hive digest --json` emits the `hive-digest` `ErrorPayload` on a bad `--date`
  (`error_kind: config`, exit 78) and now carries the resolved `chat_id`
  (optional, back-compatible) in the success envelope; CLI `long_desc` gains an
  exit-code table and examples.
- Config validates `budget_usd.digest` / `timeout_sec.digest` as positive
  numbers.
- Type/comment polish: symmetric `SendResult` dry_run/chat_id invariant,
  `Sender.blank?` made `private_class_method`, dead `VALID_CATEGORIES` alias
  removed, strip-based `ShippedItem#display_label` blank check, and corrected
  at-least-once / chunker / `RUN_DIR_RETENTION` comments.
- Strengthened the live e2e to inspect the categorizer's `items.json` (every
  fixture id covered, valid category + non-empty summary, at least one
  non-fallback summary) so it can't pass on an empty model response.

**Refreshed pages:**
- [[commands/digest]]
- [[commands/daemon]]
