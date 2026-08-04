---
title: Route module hooks through the Attempts facade
type: change
date: 2026-08-04
tags: [attempts, modules, daemon, admission]
---

- Added `Attempts::API#dispatch_module_hook` so the module daemon reaches the
  configured durable-attempt adapter through the same stable facade as task
  admission and recovery.
- Kept the public keyword contract explicit and closed while adding focused
  delegation and unknown-key coverage for the complete supported module-hook
  admission payload.
