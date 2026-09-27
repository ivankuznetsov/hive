---
title: CI history restore and receipt branch coverage
date: 2026-09-27
tags: [testing, receipts, web, turbo]
---

Back and Forward navigation again retain the URL-selected project across the
Turbo render that follows `popstate`, while a later explicit visit clears the
pending history selection. Focused receipt tests now exercise the recovery,
authority, admission, and replay branches reported uncovered by the hosted
exact-coverage gate. Fresh pin and successor admission also fails closed when
the caller does not provide a canonical project root instead of consulting a
nonexistent namespace path field.
