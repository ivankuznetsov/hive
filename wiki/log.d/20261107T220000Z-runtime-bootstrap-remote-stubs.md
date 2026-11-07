---
title: Isolate remote preflight in runtime bootstrap fixtures
date: 2026-11-07
---

Updated the copied-launcher runtime fixture with remote preflight, dispatcher,
and invocation-wrapper stubs. The launcher had loaded the real remote policy
against the fixture's incomplete argv policy, raising before activation,
registration, or inspection-cleanup assertions could run. Existing status
error-envelope integration tests cover the corrected fixture.

Recorded the separate CI dependency blocker: Rails-backed root integration
fixtures select the web Gemfile, but coverage shard jobs install only the root
bundle. No CI dependency or test-placement changes are included in this fix.
