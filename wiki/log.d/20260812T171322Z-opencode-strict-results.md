---
title: Normalize correlated OpenCode run and export evidence
date: 2026-08-12
tags: [agent-cli-runtime, opencode, results, usage]
---

**Change:** Added immutable termination, captured-result, parsed-run, route
identity, usage, inspection-command, and normalized-outcome values plus an
OpenCode profile parser hook. The strict parser selects text by the last
recognized terminal message and compiles a sanitized export inspection for the
same session.

**Evidence:** Completed outcomes require a unique correlated assistant record
from the sanitized export. Requested and actual `provider/model` routes remain
separate, and input/output/cache-read/cache-write/reasoning/cost preserve
unavailable values as `nil` rather than measured zero.

**Failures:** Timeout and cancellation take precedence over incomplete output;
non-zero exits classify authentication, configuration/route, and generic CLI
failures; zero exits with malformed or uncorrelated evidence become
`malformed_output`. Diagnostic and unknown-event evidence is bounded and
redacted without retaining opaque payloads.
