---
date: 2026-08-28
tags: [execute, patrol-fix, recovery, agent]
pages: [stages/execute]
---

# Keep nil implementation results on the normal failure path

`Stages::Execute.append_implementation_output` now treats a nil implementation
spawn result as empty output instead of calling `empty?` on nil. The state file
remains unchanged, allowing the existing implementation-failure classifier and
recovery lifecycle to own the attempt.

A focused regression test passes nil directly and proves the working marker is
preserved without an exception.
