---
title: Managed web bootstrap uses its locked Bundler directly
category: fixed
modules:
  - web
  - packaging
---

- Managed `hive web install` no longer depends on a `bundle` wrapper being on
  `PATH`; it resolves the authenticated web lockfile's Bundler and invokes it
  through the current Ruby.
- `hive-cli` now carries that exact Bundler as a runtime dependency, including
  when its package manager isolates Hive from system gems.
- Production asset compilation uses locked `bundle exec` over that Ruby,
  preventing a system Ruby or newer host Bundler from silently taking over.
- The packaged bootstrap gate now runs with only `/usr/bin:/bin` on `PATH` and
  still installs the real Rails bundle and compiles its assets.
