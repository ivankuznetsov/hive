---
title: Revalidate Patrol evidence when the default branch advances
date: 2026-08-15
tags: [patrol, fixer, evidence, git]
---

Ordinary Patrol no longer discards a fix candidate solely because the default
branch SHA advanced after review. The fixer keeps the reviewed SHA as
provenance, loads every bounded cited source line through Hive's Git boundary,
then checks it in a checkout of the fresh default. Evidence continues when the
full line is unchanged or moved byte-for-byte to one unique location.

Missing or ambiguous evidence fails closed as `stale_evidence` before an agent
starts. Baseline validation and the existing fail-before/pass-after proof still
run against the fresh base before Hive can publish a patch.
