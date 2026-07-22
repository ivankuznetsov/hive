---
title: Share transition error kinds
type: changed
date: 2026-07-18
---

Workflow stage actions now delegate their transition error-kind classification
to `Hive::Commands::Approve`, the command they compose for promotion. Direct
approve and outer stage-action envelopes retain the same closed enum, exit
codes, structured extras, and public schemas.
