---
title: Supervise the host Claude and Codex bench judges with bundled Ruby
type: change
date: 2026-11-28
tags: [bench, judge, workflows]
---

The host CLI judges now accept scores only after prompt handling, judge exit
and output collection finish within the configured deadline. Their packaged
Ruby supervisor retains the group leader through TERM and KILL, and enforces
cleanup if the harness dies. This removes the host GNU `timeout` dependency.
Generation and judging give an explicit refresh command for older snapshots
on hosts missing that executable. See [[modules/workflows]] for the time
bounds and [[gaps]] for the pending native macOS checks.
