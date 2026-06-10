## [2026-06-10T14:30:00Z] feat — codex native-review reviewer as the patrol PR reviewer

**Action:** Added `Hive::Reviewers::CodexReview` (`lib/hive/reviewers/codex_review.rb`), a new reviewer adapter that runs codex's native single-pass `codex review` subcommand and captures its stdout into the `reviews/<output_basename>-<pass>.md` GFM-checkbox findings file, replacing the expensive multi-persona `ce-code-review` fan-out for patrol PRs. Wired it as the DEFAULT `patrol.review.reviewers` entry in `Hive::Config::DEFAULTS` (`name: codex-native-review`, `kind: codex_review`, `agent: codex`, `prompt_template: reviewer_codex_native_review.md.erb`); human-PR `review.reviewers` is unchanged.

**Design notes (verified against codex-cli 0.139.0):**
- `codex review --base <BRANCH>` works but is MUTUALLY EXCLUSIVE with a custom `[PROMPT]` (`"the argument '--base <BRANCH>' cannot be used with '[PROMPT]'"`), and the native `--base` output is codex's own free-form summary, not Hive's checkbox format. So the adapter uses **custom-PROMPT mode**: argv is `[codex, "review", "--title", <title>, <prompt>]` (never `--base`), and the prompt itself scopes the review to `git diff <default_branch>...HEAD` and coerces the High/Medium/Nit output.
- Output is captured (combined stdout+stderr) under a wall-clock timeout with process-group TERM on timeout; validated to contain ≥1 `## High|Medium|Nit` header, else the per-reviewer error path runs and no malformed findings file is left for triage.
- No `UsageDb` recording — `codex review` surfaces no machine-parseable usage event (that's `codex exec --json` only); fabricating zeros would pollute the ledger.

**Dispatch / config:** `Hive::Reviewers.dispatch` gained a `codex_review` branch on the existing `kind` discriminator. `Hive::Config.validate_reviewer_entries!` now validates `kind` against `REVIEWER_KINDS = %w[agent codex_review linter]` and exempts `codex_review` from the `skill` requirement (name/output_basename uniqueness still enforced). `hive init`'s patrol-reviewer multiselect adds `codex-native-review` as index 1 / the blank default.

**Tests/quality:** New `test/unit/reviewers/codex_review_test.rb` + `test/fixtures/fake-codex` (fakes the codex subprocess; no real codex spawned). `bundle exec rake coverage` → 100.00% line coverage, gate passed, 0 failures. `bundle exec rubocop` on changed Ruby files → no offenses.

**Refreshed pages:**
- [[modules/reviewers]]
- [[modules/patrol]]
