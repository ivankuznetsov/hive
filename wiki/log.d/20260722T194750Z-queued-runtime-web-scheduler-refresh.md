---
title: Refresh queued runtime, patrol, web, scheduler, and CI-plan contracts
date: 2026-07-22
tags: [runtime, patrol, web, llm-wiki, installer, ci]
---

Coalesced ten queued source commits from four branch lines. Runtime handoff
hardening (`5c1a20e9`) drains final attempt frames after terminal
state observation, keeps still-launching reservations live, preserves complete
predecessor outputs for successors, bounds structured agent messages without
presenting a truncated prefix as complete, shares Pi's configured agent home,
and carries exact Codex config snapshots between package operations.

Operational changes (`01e85c89`, finalized by `05784893`) declare the Base64
runtime dependency, normalize custom
project state roots for babysitter artifacts, short-circuit already-green fork
PRs before the mutation-only fork boundary, restore caller branch or detached
HEAD around bench submissions, report repository-relative entry/ref/SHA
metadata, remove daemon/bot/web services independently during uninstall, and
keep installer rollback armed through staged wrapper/shim activation so exact
prior bytes, modes, and symlink shape survive partial failures.

The latest `fix/all-worthy-patrol-findings` head (`05784893`, incorporating
`9c4b4d69`; `2f25207c` is an earlier simplification snapshot) uses one shared
dry-run startup/loader environment boundary and a direct Ruby GitHub stub.
Patrol now admits findings against exact target SHAs and configured validation
keys, reuses same-target active records for shipping retries, permits
newer-target recurrence without rewriting terminal history, binds ledger
outcomes to their target, and publishes v3 patrol/finding schemas while
retaining the original v2 compatibility shapes. Generic usage errors no longer
masquerade as invalid task paths. E2E cleanup prefers namespaced retention
variables while warning on legacy fallbacks, and missing asciinema degrades
capture rather than failing scenario preflight.

Rails branch commits `96b06792` and `4455fc06` remove the web dispatcher:
filesystem-backed `Task`, `Project`, and `Daemon` resources own mutations while
controllers remain HTTP boundaries. Status scanning is acquired and released
by confirmed Cable subscribers, with per-channel race fencing, one shared
five-second poller, canonical semantic snapshot tokens for cross-worker
catch-up, and one fully rendered Turbo Stream message per broadcast. An idle
server with no subscribed pages performs no fleet scan.

Headless wiki fix `8944dfba` (the newer-base equivalent of `aae95f78`)
reconstructs user-systemd bus variables from the standard socket, retains the
installer-owned scheduler marker when signaling falls back to host-wide
serialization, and ignores compiled-`wiki/log.md`-only commits before queueing.
It prepares v0.6.8 metadata but does not prove a public release.

Finally, `ae2c5d2d` is plan-only: it requires exact covered/total equality
before optimizing strict CI, then proposes measured, isolated candidates for
Git fixtures, coverage injection, local/hosted workers, and later web/E2E
parallelism with exact-head hosted evidence. No CI optimization is implemented
by that commit.
