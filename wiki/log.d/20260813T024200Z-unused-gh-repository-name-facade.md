---
date: 2026-08-13
slug: unused-gh-repository-name-facade
pages: [modules/gh]
---

Removed the unused `Hive::Gh.repo_name_with_owner` convenience wrapper and its
wrapper-only tests. Runtime consumers already use the retained host-aware
`repository_identity` API, whose coverage continues to protect origin parsing,
error handling, and GitHub Enterprise identities. Updated [[modules/gh]] to
name the live API only.
