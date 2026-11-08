---
title: Refresh the generated defaults reference after current-main integration
date: 2026-09-09
---

The PR sweep regenerated the defaults reference after integrating current main,
including the framework config/database allowlist and credential exclusions.
The read-only drift check failed before regeneration. Running the maintainer
command twice refreshed the page, then preserved its bytes and timestamps.
