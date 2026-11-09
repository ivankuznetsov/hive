---
title: Update Addressable and sqlite3 after CI audit failures
date: 2026-11-01
tags: [dependencies, security, ci]
---

- Updated both root and web lockfiles to Addressable 2.9.2 and sqlite3
  2.10.2 across their existing native platforms. The current advisory database
  flags Addressable below 2.9.1 for seven advisories and sqlite3 through
  2.10.1 for GHSA-4fqr-96q8-xrfx. Existing dependency constraints permit the
  patched versions; no application code or audit exceptions changed.
