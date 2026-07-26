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
- Production asset compilation also uses that Ruby directly, preventing a
  system `ruby` elsewhere on `PATH` from silently taking over.
- The packaged bootstrap gate now runs with only `/usr/bin:/bin` on `PATH` and
  still installs the real Rails bundle and compiles its assets.
