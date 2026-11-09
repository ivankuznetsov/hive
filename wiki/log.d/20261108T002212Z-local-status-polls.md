---
title: Keep bot and digest status polls local
type: changelog
created: 2026-11-08
tags: [bot, digest, remote, cli]
---

`Bot::StatusWatcher` now routes native Hive status launches through
`CliArgvPolicy.local_child_argv`, keeping its hidden internal task-graph reads
local even when an operator selects a remote client context. This shared poll
serves bot notifications, bot status replies, and answer-digest. An integration
regression checks that the poll succeeds while the saved remote context remains
selected. Other internal native launch sites already select the local context.
