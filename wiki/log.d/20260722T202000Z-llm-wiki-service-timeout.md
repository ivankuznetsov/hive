---
title: Cover bounded multi-batch wiki drains in systemd
date: 2026-07-22T20:20:00Z
tags: [wiki, systemd, scheduler, reliability]
---

Raised the managed llm-wiki systemd service timeout from 45 minutes to four
hours. A scheduled worker can consume three batches, and each batch may use a
30-minute headless-agent budget followed by two separate 15-minute QMD phases;
the old outer timeout could therefore terminate a healthy recovered queue
between batches. The worker remains bounded by its batch cap, per-command
timeouts, machine-wide provider lock, 4 GiB memory limit, and no-swap policy.

Focused scheduler coverage now pins the four-hour service limit.
