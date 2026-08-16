---
title: Keep managed Codex provenance probes machine-readable
date: 2026-08-16
tags: [codex, honeycomb, permissions, mise, reliability]
---

Managed Honeycomb actors now silence mise version-selection notices while Hive
runs the isolated `codex doctor --json` provenance probe. This preserves the
empty temporary Codex state root and strict JSON parsing while allowing the
existing fail-closed policy to accept valid runtime provenance even when an
unrelated aggregate doctor check fails.

The regression test models a noisy mise-backed wrapper and requires the probe
environment to suppress that banner before parsing the doctor document.
