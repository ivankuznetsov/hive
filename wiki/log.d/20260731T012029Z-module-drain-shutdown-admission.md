---
title: Module event drain closes admission during daemon shutdown
date: 2026-07-31
tags: [daemon, modules, events, shutdown, attempts]
---

- The daemon now passes its private process-lifetime admission predicate into
  `Hive::Modules::DaemonRuntime`.
- Module retry, setup-outbox, schedule, event, selection, and hook boundaries
  recheck admission so a signal observed during one hook cannot admit a later
  hook or project from the same tick.
- A partially drained event retains its prior cursor. On restart the event
  replays, the decision journal deduplicates hooks admitted before shutdown,
  and hooks not yet admitted remain eligible.
