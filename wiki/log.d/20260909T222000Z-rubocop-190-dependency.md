---
title: Update root development RuboCop to 1.90
date: 2026-09-09
---

The root development/test bundle now requires RuboCop `~> 1.90` and locks
1.90.0. Its compatible `parallel` dependency resolves to 2.2.0. The runtime
gem dependencies and configured Omakase rule set are unchanged. Updated the
root-bundle version in `wiki/dependencies.md`.
