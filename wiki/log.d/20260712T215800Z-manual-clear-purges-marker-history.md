---
title: Manual marker recovery purges shadowed history
module: markers
tags: [markers, recovery, daemon]
---

## [2026-07-12T21:58:00Z] markers — manual recovery leaves a markerless retry artifact

**Action:** Changed `hive markers clear` to remove all recognized marker comments
after its current-marker and optional `--match-attr` guards succeed. Generic
stage runs append terminal markers after transient `AGENT_WORKING` markers, so
removing only the newest `ERROR` could expose the completed run's older working
marker and make the daemon defer redispatch until stale-agent recovery. Manual
and daemon-managed recovery now share the same markerless postcondition while
preserving state-file prose and the guarded clear audit commit.

**Coverage:** Added an integration regression with a shadowed
`AGENT_WORKING` plus a marker-ID-guarded `ERROR` clear; it asserts no marker is
current afterward and surrounding implementation prose remains intact.
