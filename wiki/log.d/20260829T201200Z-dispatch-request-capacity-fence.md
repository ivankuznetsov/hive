---
date: 2026-08-29
title: Preserve dispatch-request order across capacity changes
tags: [daemon, dispatch-queue, attempts, capacity]
---

- Stop a chronological dispatch-request scan after an older request observes
  global or generic durable-attempt capacity exhaustion.
- Keep later requests pending for the next scan so a short-lived worker cannot
  reopen a slot and let a younger request bypass the older one.
- Fence project and daily caps only within their project, leaving unrelated
  request delivery available.
- Cover controller-global, project-local, and durable-attempt capacity paths.
