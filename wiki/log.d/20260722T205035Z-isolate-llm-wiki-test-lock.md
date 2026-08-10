---
date: 2026-07-22
slug: isolate-llm-wiki-test-lock
pages: [testing]
---

Isolated LLM-wiki integration fixtures from the operator's machine-wide refresh
lock by assigning each fixture a private runtime directory. Concurrent real
wiki refreshes can no longer suppress fixture agents or leave their test queues
undrained. Explicit global-lock tests still provide their own shared runtime
directory and retain the production serialization contract. Updated [[testing]]
and did not edit compiled [[log]].
