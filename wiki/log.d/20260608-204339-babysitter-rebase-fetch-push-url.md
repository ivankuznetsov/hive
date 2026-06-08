---
ts: 2026-06-08T20:43:39Z
slug: babysitter-rebase-fetch-push-url
tags: [babysitter, github, git, bugfix, headless]
---

## Babysitter: fetch the rebase base over the push URL so auto-rebase works headless

**Bug.** `GhOps.rebase_onto_base` (lib/hive/babysitter/gh_ops.rb) fetched the base with `git fetch origin <base>` via `Hive::Gh.capture3`. `capture3` forces `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`. In the babysitter's systemd `--user` service there is no SSH agent (`SSH_AUTH_SOCK` unset), and origin's **fetch** URL is SSH (`git@github.com:…`). The fetch died with `Permission denied (publickey)`, so `rebase_onto_base` returned `:failure` every tick and green-but-`BEHIND` PRs stayed `BEHIND` (`action=rebase outcome=failure` on each pass). The force-push already worked: origin's **push** URL is HTTPS (`git remote get-url --push origin`) and gh's credential helper authenticates it.

Empirical results:
- `git fetch origin main` → works (interactive)
- `GIT_SSH_COMMAND="ssh -o BatchMode=yes" git fetch origin main` → fails (publickey denied)
- `git fetch <https-push-url> main` → works

**Fix.** `rebase_onto_base` now resolves the remote's effective push URL via `git remote get-url --push origin` (new `GhOps.fetch_source` helper) and fetches the base from that URL (`git fetch <push-url> <base>`), then rebases onto `FETCH_HEAD` (instead of `origin/<base>` — avoids touching the shared tracking ref). If the push URL can't be resolved (command fails or returns empty) it falls back to the literal `"origin"` so non-github / unusual remotes behave as before. Conflict handling is unchanged: rebase failure → best-effort `git rebase --abort` → `:conflict`; fetch failure → `:failure`; dry-run is still a no-op success. `RebaseResult` shape and `success?`/`conflict?` predicates unchanged. `Hive::Gh.capture3` (BatchMode is intentional for other callers) and `force_push_with_lease` are untouched.

**Tests.** `gh_ops_test`: fetch targets the resolved push URL (`https://github.com/o/r.git`) not bare `origin`, then `git rebase FETCH_HEAD`; push-url resolve failure → fallback to `origin`; empty push URL → fallback to `origin`; conflict path (rebase fails → `--abort` → `:conflict`); fetch-failure path (`:failure`, stops after resolve+fetch); dry-run skips git. `pr_fixer_test` stubs `rebase_onto_base` directly so its auto-rebase tests are unaffected. Full `rake test` gate passed at 100% line coverage; rubocop clean on changed files.

**Refreshed pages:**
- [[modules/babysitter]]
