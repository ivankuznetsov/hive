---
title: Remove unused manifest event-name projection
date: 2026-08-13
---

- Removed the uncalled `Hive::ModulePackage::Manifest#event_names` convenience
  projection. Runtime hook consumers continue to read the validated `hooks`
  entries directly, including each hook's event list.
