---
title: Make the routine e2e runtime hermetic under Bundler and host overrides
date: 2026-07-16
tags: [e2e, bundler, tmux, fixtures]
---

- Started harness-owned TUI tmux servers inside the unbundled environment so a root `bundle exec` cannot combine startup flags with the sample project's lockfile.
- Pinned nested Hive commands to the checkout binary and fake Claude to headless mode, preventing operator environment overrides and interactive readiness races.
- Refreshed the full-pipeline artifacts output and TUI scope anchors to the current production contracts, restoring all existing scenarios in the new routine CI job.
