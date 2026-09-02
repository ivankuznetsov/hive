---
title: Harden command owner review contracts
date: 2026-09-02
tags: [cli, wiki, commands, regression-guard, review]
---

- Pinned every durable aggregate owner mapping, the complete daemon exit
  matrix, alias/canonical collision rejection, and exact two-column separator
  handling in focused command-index coverage.
- Kept owner validation section-bounded and per command, and rejected an
  incidental behavior heading that merely contains a contract keyword.
- Corrected `hive version` to document exit `64` for malformed invocation and
  exit `1` for an uncaught JSON serialization failure; removed the unsupported
  exit `70` claim.
- Expanded the integration no-write proof around public help plus both guard
  evaluations and metadata validation. Its repository snapshot now hashes
  tracked, untracked, and ignored files, including mode, size, mtime, and
  content or symlink identity.
