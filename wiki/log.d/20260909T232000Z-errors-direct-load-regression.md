---
title: Verify standalone error taxonomy loading
date: 2026-09-09
---

The PR sweep confirmed the taxonomy relocation preserves its definitions exactly.
A fresh Ruby subprocess now verifies that hive/errors loads representative concrete
errors without loading hive.rb, preserving exit codes and inheritance.
