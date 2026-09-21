---
title: Allow local shell inspection during brainstorm
---

The brainstorm prompt now explicitly allows read-only shell commands while
restricting edits to `brainstorm.md` and retaining the network and Git-state
restrictions. The previous blanket shell ban caused Writero task 43131 to stop
without writing its brainstorm because Codex needed shell tools to read local
context. The rendered-prompt regression covers the allowed reads and retained
write and network boundaries.
