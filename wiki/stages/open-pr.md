---
title: 5-open-pr stage
type: stage
source: lib/hive/stages/open_pr.rb, templates/open_pr_prompt.md.erb
created: 2026-05-13
updated: 2026-07-18
tags: [stage, pr, github]
---

**TLDR**: Pushes the feature branch and opens a draft GitHub PR before autonomous review starts. This gives humans a normal `gh pr checkout <number>` entry point while hive continues to use local files as the authoritative review state.

## Preconditions

1. `worktree.yml` must exist from 4-execute.
2. The pointed worktree must exist on disk.
3. `gh auth status` must succeed; unavailable GitHub auth is a hard failure.

The first two checks are the shared `Hive::Stages::Base.worktree_pointer_or_exit` policy also used by [[stages/finalize]], so their warnings and exit status cannot drift.

## Steps performed (`Stages::OpenPr.run!`)

1. Check pull requests for the branch with `gh pr list --head <branch> --state all`.
2. If an OPEN PR exists, write `pr.md` with `idempotent=true`, secret-scan it, and finish without spawning an agent.
3. If a MERGED PR exists for the current local `HEAD` (`headRefOid` match), write `pr.md` with `merged=true`, secret-scan it, write `summary.md`, and finish without spawning an agent.
4. Push the branch with `git push -u origin <branch>`.
5. Render `templates/open_pr_prompt.md.erb` with the plan and execute output wrapped in a per-spawn `<user_supplied>` nonce.
6. Spawn the open-pr agent in the worktree. The prompt invokes `/ce-commit-push-pr`, requires `gh pr create --draft`, forbids another push, requires `pr.md` frontmatter with `pr_url` / `pr_number`, and ends with a required completion section that makes the `<!-- COMPLETE pr_url=... is_draft=true -->` marker the last line.
7. Secret-scan the resulting `pr.md` and PR body before returning success.

## Marker → commit action

- `:complete` → `pr_opened_draft`.
- Existing OPEN PR → `open_pr_already_open` with `idempotent=true`.
- Existing MERGED PR for local HEAD → `open_pr_already_merged` with `merged=true` and `summary.md` written.
- Secret scan failure → `ERROR reason=secret_in_pr_body` or `ERROR reason=secret_scan_fetch_failed`.
- `ERROR reason=timeout` is daemon-retryable once when no live task lock exists. This covers tmux marker-skip stranding after the PR was externally created but `pr.md` was not stamped complete; `Hive::Daemon::StaleAgentHealer` clears the marker with a marker-id guard and a one-shot `stage_timeout` budget, then the normal dispatch path re-enters the existing-OPEN-PR branch without creating a second PR.

## Backlinks

- [[stages/execute]] · [[stages/review]] · [[state-model]]
