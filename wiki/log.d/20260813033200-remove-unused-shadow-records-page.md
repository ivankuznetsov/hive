---
title: Remove unused shadow comparison page facade
date: 2026-08-13
---

- Removed the uncalled
  `Hive::Modules::Migration::ShadowComparator#records_page` API and its private
  result type. Migration commands and reports continue to stream validated
  comparison history through `each_record`.
- Retargeted restart, ordering, bounded page-size, and invalid-input coverage to
  the live iterator.
