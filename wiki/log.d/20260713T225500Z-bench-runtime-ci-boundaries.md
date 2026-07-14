---
title: Benchmark runtime CI boundaries
type: change
date: 2026-07-13
---

- Kept the packaged benchmark runtime synchronized with hive-bench while
  excluding the snapshot from Hive's separate RuboCop style policy.
- Retained Brakeman coverage over the runtime and documented three argv-form
  `Open3.capture3` false positives in the root ignore file.
- Replaced ShellCheck-sensitive word splitting and `ls` parsing in both the
  canonical harness and packaged snapshot.
