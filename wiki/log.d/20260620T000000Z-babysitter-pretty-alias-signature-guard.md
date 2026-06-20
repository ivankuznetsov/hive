## [2026-06-20T00:00:00Z] babysitter — default-deny pretty/format aliases that expand to signature placeholders

**Action:** Closed a bypass of the dry-run git signature guard in `bin/hive-babysitter-stub-git`. The guard previously scanned only the literal `--format` / `--pretty` value for `%G`, so `git log --pretty=<alias>` (or `--format=<alias>`) slipped through when the value named a repo-local `pretty.<name>` alias whose expansion in `.git/config` carried a `%G*` placeholder — letting an otherwise read-only history command invoke the repo-local `gpg.program`.

The glued `=<value>` form is now **default-deny** (`signature_capable_format_value?`): it passes only when provably signature-free — a builtin format (`oneline`/`short`/`medium`/`full`/`fuller`/`reference`/`email`/`raw`/`mboxrd`), a visible inline format or `format:`/`tformat:` template with no `%G`, or empty. Any other bare name is rejected as a potential alias. Since a git config key cannot contain `%`, a `%`-bearing value is always a visible inline format (never an alias), so visible formats without `%G` stay readable and are not over-blocked. The separate-word case is unchanged: git only reads the format from a glued `=<value>`, so a following word stays a revision and a bare `--pretty`/`--format` still passes.

Extended `test_git_stub_skips_signature_verification_before_local_gpg_program` with repo-local `pretty.*` aliases expanding to `%GK` / `%G?` (proving the bypass is now skipped before the fake `gpg.program` runs), and added integration cases asserting opaque aliases skip while builtin / inline-`%` / `format:` reads pass through.

**Refreshed pages:**
- [[modules/babysitter]]
- [[commands/babysit]]
