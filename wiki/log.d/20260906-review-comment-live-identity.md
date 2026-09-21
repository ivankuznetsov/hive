---
title: Review comments follow the live PR identity
date: 2026-09-06
---

- Removed the saved-commit veto from review comment publication. TopGreenDeals
  PR 402 had advanced while its saved head remained at the original commit,
  so comment publication silently skipped the correct open PR.
- Retained live repository, owned branch, PR number/URL, open-state, and
  uniqueness checks. Code push and CI exact-head checks are unchanged.
- Regression tests cover changed/missing saved heads and reject wrong branches,
  numbers, URLs, closed PRs, duplicate observations, and foreign repositories.
