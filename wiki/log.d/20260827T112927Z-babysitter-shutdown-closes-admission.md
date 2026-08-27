---
title: Close babysitter admission during signal shutdown
type: fix
created: 2026-08-27
tags: [babysitter, signals, shutdown, agents]
---

TERM and INT now close one babysitter-wide admission predicate. The dispatcher
rechecks it between projects, `ProjectTick` rechecks it between selected PRs,
and `PrFixer` rechecks it after blocking status/context reads and at the final
agent-launch boundary. Repairs accepted before shutdown still drain, while
later projects, PRs, rebases, and agents from the same tick remain unstarted.
