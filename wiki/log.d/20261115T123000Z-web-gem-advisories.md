---
title: Hive web bundle patches puma and msgpack advisories
type: change
created: 2026-11-15
updated: 2026-11-15
tags: [dependencies, security, web, ci]
---

`bundler-audit` began failing on `main` for every PR after new advisories
against `web/Gemfile.lock`:

- **msgpack 1.8.3 (High):** the JRuby decoder makes uncapped header-count
  allocations. Fixed in 1.8.7.
- **puma 7.2.1:** pumactl does not verify the TLS identity of SSL control
  servers; graceful shutdown waits forever on trickled request bodies; the
  reactor timeout queue loses order. Fixed in `~> 7.2.2`.

The update is patch-level and conservative (`bundle update --patch
--conservative puma msgpack`): puma 7.2.1 → 7.2.2 and msgpack 1.8.3 → 1.8.7.
No other gem changed, and puma deliberately stays on 7.2.x rather than 8.x.
`bundler-audit` reports no vulnerabilities for either lockfile.
