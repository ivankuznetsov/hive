---
title: Isolate the committed managed-Web builder environment
type: change
date: 2026-08-04
---

- Launched the committed managed-Web helper with a minimal allowlisted
  path/locale environment instead of inherited Ruby, Bundler, and coverage
  startup hooks.
- Added a focused regression for the default-json/locked-json activation
  conflict that failed the hosted release-candidate artifact test.
