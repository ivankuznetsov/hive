# 2026-11-02 — Refresh Addressable after audit advisories

- The `bundler-audit` CI job began flagging transitive addressable 2.9.0 for
  seven advisories. Both lockfiles now resolve addressable 2.9.2, satisfying
  the advisory database's `>= 2.9.1` floor without changing dependency
  constraints or application behavior.
- The web lock also retained sqlite3 2.9.6, which the same advisory database
  flags for GHSA-4fqr-96q8-xrfx. It now resolves sqlite3 2.10.2 on every
  packaged platform, matching the root lock's security floor.
