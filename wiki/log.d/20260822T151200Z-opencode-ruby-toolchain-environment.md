---
title: Preserve Ruby gem paths in isolated OpenCode runs
date: 2026-08-22
---

OpenCode invocations now retain the operator-selected `GEM_HOME` and
`GEM_PATH` while keeping their XDG configuration, data, cache, state, and
temporary roots isolated. This lets checked-in Ruby and Rails binstubs load
the operator's Bundler installation instead of failing on `bundler/setup` only
inside Hive. The boundary stays narrow: Hive does not forward `RUBYOPT`,
Bundler configuration variables, or arbitrary ambient environment entries.
