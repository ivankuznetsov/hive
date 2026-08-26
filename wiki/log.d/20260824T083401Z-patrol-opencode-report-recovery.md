---
title: Patrol Fix OpenCode report recovery
type: change
date: 2026-08-24
tags: [patrol-fix, opencode, artifact-custody]
---

Prepared OpenCode launches now bypass stdout-producing tool-manager shims so
their strict JSONL result stream remains parseable. Managed Patrol Fix stages
also retain Artifact Firewall custody while accepting an absent report only
when the successful agent returned the exact, untruncated JSON object as its
final response; existing paths and symlinks remain fail-closed.
