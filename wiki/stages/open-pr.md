---
title: 5-open-pr stage
type: stage
source: lib/hive/stages/open_pr.rb, templates/open_pr_prompt.md.erb
created: 2026-05-13
updated: 2026-07-24
tags: [stage, pr, github]
---

**TLDR**: Pushes the feature branch and opens a draft GitHub PR before autonomous review starts. This gives humans a normal `gh pr checkout <number>` entry point while hive continues to use local files as the authoritative review state.

## Preconditions

1. `worktree.yml` must be a regular controller-owned pointer from 4-execute
   with the exact task slug as its branch and deterministic path.
2. The pointed worktree must exist, be registered by the project repository,
   have that branch checked out, and share the project's Git common directory.
3. `gh auth status` must succeed; unavailable GitHub auth is a hard failure.

The first two checks are the shared `Hive::Stages::Base.worktree_pointer_or_exit` policy also used by [[stages/finalize]], so their warnings and exit status cannot drift.

## Steps performed (`Stages::OpenPr.run!`)

1. Check pull requests for the branch with `gh pr list --head <branch> --state all`.
2. Secret-scan every current OPEN PR body before pushing or spawning a
   body-authoring agent. This closes the retry window where a known leaked body
   could otherwise be republished before the next post-write scan.
3. If an OPEN PR exists, write `pr.md` with `idempotent=true` and the
   controller-observed full `head_oid`, secret-scan it, and finish without
   spawning an agent.
4. If a MERGED PR exists for the current local `HEAD` (`headRefOid` match),
   write `pr.md` with `merged=true` and that immutable head binding,
   secret-scan it, write `summary.md`, and finish without spawning an agent.
5. Secret-scan the local PR source, then push the branch with `git push -u origin <branch>`.
   A missing `pr.md` is the normal first-entry shape and contributes an empty
   local source; remote bodies are still fetched and scanned.
6. Render `templates/open_pr_prompt.md.erb` with the plan and execute output wrapped in a per-spawn `<user_supplied>` nonce.
7. Spawn the open-pr agent in the worktree. Controller-owned task files are
   captured before spawn and restored atomically on a mismatch; the resulting
   error carries `reason=open_pr_tampered` and `restored=true|false`. The prompt
   invokes `/ce-commit-push-pr`, requires `gh pr create --draft`, forbids
   another push, requires `pr.md` frontmatter with `pr_url`, `pr_number`, and
   full `head_oid`, and
   ends with a required completion section that makes the
   `<!-- COMPLETE pr_url=... is_draft=true -->` marker the last line.
8. Secret-scan the resulting `pr.md` and PR body, revalidate that GitHub's
   `headRefOid` is the exact local `HEAD`, and canonicalize the immutable PR
   identity in frontmatter before returning success.

## Marker → commit action

- `:complete` → `pr_opened_draft`.
- Existing OPEN PR → `open_pr_already_open` with `idempotent=true`.
- Existing MERGED PR for local HEAD → `open_pr_already_merged` with `merged=true` and `summary.md` written.
- Secret scan failure → `ERROR reason=secret_in_pr_body` or `ERROR reason=secret_scan_fetch_failed`.
- Every `ERROR`, including `timeout`, remains daemon-retryable after the shared
  cooldown when no live task lock exists and current safety evidence passes.
  The ordinary stage re-entry discovers an externally created OPEN PR instead
  of creating a duplicate. A repeated failure writes a new marker and restarts
  the cooldown; retries do not exhaust.

## Backlinks

- [[stages/execute]] · [[stages/review]] · [[state-model]]
