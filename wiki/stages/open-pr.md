---
title: 5-open-pr stage
type: stage
source: lib/hive/stages/open_pr.rb, templates/open_pr_prompt.md.erb
created: 2026-05-13
updated: 2026-05-13
tags: [stage, pr, github]
---

**TLDR**: Pushes the feature branch and opens a draft GitHub PR before autonomous review starts. This gives humans a normal `gh pr checkout <number>` entry point while hive continues to use local files as the authoritative review state.

## Preconditions

1. `worktree.yml` must exist from 4-execute.
2. The pointed worktree must exist on disk.
3. `gh auth status` must succeed; unavailable GitHub auth is a hard failure.

## Steps performed (`Stages::OpenPr.run!`)

1. Check for an existing PR for the branch with `gh pr list --head <branch> --state all`.
2. If one exists, write `pr.md` with `idempotent=true` and `is_draft=true` and finish without spawning an agent.
3. Push the branch with `git push -u origin <branch>`.
4. Render `templates/open_pr_prompt.md.erb` with the plan and execute output wrapped in a per-spawn `<user_supplied>` nonce.
5. Spawn the open-pr agent in the worktree. The prompt invokes `compound-engineering:ce-commit-push-pr`, requires `gh pr create --draft`, forbids another push, and requires `pr.md` frontmatter with `pr_url` / `pr_number`.
6. Secret-scan the resulting `pr.md` and PR body before returning success.

## Marker → commit action

- `:complete` → `pr_opened_draft`.
- Existing PR → `open_pr_already_open`.
- Secret scan failure → `ERROR reason=secret_in_pr_body`.

## Backlinks

- [[stages/execute]] · [[stages/review]] · [[state-model]]
