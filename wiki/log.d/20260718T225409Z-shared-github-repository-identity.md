## 2026-07-18 — Share strict GitHub repository identity validation

- Added `Hive::Gh::RepositoryIdentity` as the single owner of GitHub/GHES
  hostname, owner/name slug, and combined repository-target validation.
- Routed both normal `Hive::Gh` operations and architecture-patrol's
  `GithubGateway` through that policy without changing accepted inputs or
  `Hive::GhError` messages.
- Verified transport, issue, and patrol publication boundaries together: 146
  runs, 799 assertions, zero failures, zero errors, and zero skips.
