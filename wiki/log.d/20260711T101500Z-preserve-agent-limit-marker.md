---
title: Preserve generic-stage agent limit markers
type: fix
date: 2026-07-11
---

Generic workflow agent stages now distinguish an unchanged terminal marker
from a fresh marker written during the spawn. Error envelopes synthesize
`agent_preflight_failed` only in the unchanged/preflight case, preserving
specific runtime errors such as `limits_reached` and their daemon
`retry_after` metadata.

A regression covers the Codex usage-wall shape that previously lost its timed
retry as the generic runner returned.
