---
date: 2026-08-28
tags: [plan-review, config, init, timeout]
pages: [modules/config]
---

# New projects keep the 30-minute plan-review timeout

The generated project configuration now matches Hive's built-in plan-review
attempt timeout of 1,800 seconds. Existing projects that omit the setting keep
inheriting the same default instead of diverging from newly initialized
projects.
