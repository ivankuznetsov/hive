---
title: Recover clean Patrol output after Pi retries a provider turn
type: fix
tags: [patrol-fix, pi, agent, artifact-firewall]
---

Patrol Fix managed report stages now accept a zero-exit Pi run when an earlier
provider error was retried internally and the final controller custody report
proves the required output is valid and protected anchors are unchanged.
Missing or invalid output, timeout, nonzero exit, and custody tampering still
fail closed.
