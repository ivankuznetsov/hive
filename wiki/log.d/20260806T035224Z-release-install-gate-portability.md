---
title: Make the release install gate portable on macOS
type: fix
module: release
created: 2026-08-06
tags: [release, workflow, macos, portability]
---

The tag-time native gem-install gate now selects its sole candidate gem with a
Bash glob array and verifies that entry is non-empty. This replaces a string
comparison against `wc -l`, whose BSD implementation pads the count with
leading spaces and stopped the macOS gate before `gem install` despite an exact,
authenticated artifact.

The Linux ARM behavior and the fail-closed zero/multiple/empty-file checks are
preserved.
