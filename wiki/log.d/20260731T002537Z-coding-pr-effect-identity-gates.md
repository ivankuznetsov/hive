---
title: Coding PR effects require exact controller identity
date: 2026-07-31
tags: [coding, open-pr, review, finalize, github, security]
---

# Coding PR effects require exact controller identity

The coding workflow no longer lets an agent-authored or subsequently tampered
`pr_url` select a controller-owned GitHub effect before identity proof.

- Open PR validates the exact branch, URL, and local/remote head before a
  post-agent body scan or rejected-PR remediation. An unobserved marker URL is
  recorded as an error but is never fetched, edited, or closed.
- Review comment publication binds the target to the owned worktree, exact
  task branch, persisted controller head, origin repository, and one matching
  OPEN pull request before comment lookup or posting.
- Finalize resolves the URL through the task repository before URL-bound
  scans or lifecycle reads, preserves the existing local-state/push gate for
  review commits, and then requires exact local/remote head parity before
  body or ready-state mutation.

Focused regressions cover forged cross-repository URLs, absent controller
observations, branch/head drift, and ordering before URL-bound effects.
