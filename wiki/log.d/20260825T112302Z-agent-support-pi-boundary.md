---
title: Pi provider behavior moved behind AgentSupport
type: change
created: 2026-08-25
tags: [agent-support, pi, selective-loading, architecture]
---

Added the convention-based `Hive::AgentSupport` boundary and migrated Pi's
message, identity, credential, review, skill/setup, inventory, and managed
runtime decisions into its provider namespace. Generic process, credential
write, artifact, and workflow owners remain authoritative. Clean-process tests
prove that Pi and its heavier facets are loaded only when selected, while a
live source scan prevents Pi behavior from returning to generic core.
