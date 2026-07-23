---
title: Restrict wiki refreshes to configured providers
date: 2026-07-22T21:23:00Z
tags: [wiki, security, providers, scheduler]
---

Removed the undocumented `LLM_WIKI_REFRESH_CMD` arbitrary executable override
from Hive's shipped llm-wiki worker. Production refreshes now dispatch only to
the explicitly configured Codex, Claude Code, or Pi provider through their
fixed command names, bounded argument shapes, and existing per-command
timeouts. Integration tests inject their deterministic command seam only into
a disposable worker copy and assert that the committed production template
does not expose the override.

This hardening accompanies the four-hour outer service timeout in v0.6.9 and
moves Hive onto the canonical `%t/llm-wiki-refresh.lock` already used by
standalone llm-wiki and the marketplace plugin. Mixed installations now share
one machine-wide provider admission point instead of serializing only within
each package. Queue retention, the 4 GiB/no-swap limit, and wiki-only
publication to `llm-wiki/refresh` remain unchanged.
