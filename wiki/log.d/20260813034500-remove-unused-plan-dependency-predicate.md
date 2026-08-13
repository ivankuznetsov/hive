---
title: Remove unused plan dependency predicate
date: 2026-08-13
---

- Removed the uncalled `Hive::PlanFrontmatter::Result#depends_on_present?`
  predicate. Dependency consumers continue to inspect the normalized
  `depends_on` value directly.
- Retargeted absent and present dependency assertions to that canonical result
  field.
