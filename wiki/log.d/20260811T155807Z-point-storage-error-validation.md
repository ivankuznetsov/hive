---
title: Point storage validates its domain error boundary before translation
date: 2026-08-11T15:58:07Z
tags: [components, storage, validation]
---

Kept invalid `Hive::PointStorage` domain error classes outside the managed
storage failure translator. They now raise the intended `ArgumentError`
directly instead of cascading into a `TypeError` while attempting to raise an
invalid caller-supplied class.
