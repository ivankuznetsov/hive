---
title: Stop mutating shallow checkouts during release staging
type: fix
tags: [release, packaging, github-actions, git]
---

- Hosted release-candidate staging now downloads reviewed tagged
  `Gemfile.lock` bytes and verifies their catalog SHA-256 values directly.
- Removed tag fetch/archive operations from the active shallow Actions
  checkout, preventing `shallow file has changed since we read it` races in
  parallel candidate campaigns.
- Added focused coverage for producer/observer lock selection and fail-closed
  digest drift.
- Updated the root and packaged-web sqlite3 locks to 2.9.6 after the release
  security gate identified GHSA-mwm8-39rw-8826 in 2.9.5.
