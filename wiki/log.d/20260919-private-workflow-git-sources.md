---
title: Direct private Git workflow imports
date: 2026-09-19
---

Added `hive workflow install ID --from REPOSITORY --ref REF` for owner-selected
authored workflows. Git authentication is reused without storing credentials;
imports resolve a commit and record source provenance. Existing workflows are
preserved, previews do not mutate project state, source hooks are not executed,
and invalid trees fail before activation. Managed Honeycomb lifecycle is unchanged.
