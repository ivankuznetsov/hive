---
date: 2026-08-13
slug: unused-babysitter-rerun-ci
pages: [modules/babysitter]
---

Removed the unused `Hive::Babysitter::GhOps.rerun_ci` helper and its
coverage-only assertion. No production caller dispatched that GitHub action;
the babysitter's live side-effect paths remain rebase, force-push, label
management, and PR comments. Updated [[modules/babysitter]] to match the
remaining API.
