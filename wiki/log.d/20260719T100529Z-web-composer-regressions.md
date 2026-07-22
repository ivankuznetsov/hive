---
title: Composer failure and reconnect browser regressions
type: test
date: 2026-07-19
tags: [web, composer, turbo, stimulus, testing]
---

- Browser coverage now proves a failed Turbo submission preserves typed text,
  chips, and the staged upload transport.
- Browser coverage forces a real Stimulus disconnect/reconnect of the permanent
  composer, adds a second image, and submits both files to prove attachment
  state rebuilds from the preserved FileList.
- Loopback integration coverage now asserts all five primary navigation links,
  including Workflows.
