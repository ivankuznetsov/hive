---
title: Let Hive own the isolated OpenCode lifecycle
date: 2026-08-12
tags: [agent, opencode, lifecycle, permissions]
---

**Change:** Mirrored the additive prepared-invocation and strict-result values
through `Hive::AgentRuntime`. `Hive::Agent` now owns OpenCode preparation,
bounded run capture, zero-exit sanitized export inspection, typed
normalization, and invocation cleanup while leaving the four existing agent
spawn paths unchanged.

**Permissions:** Hive maps only declared read-only/scoped permission presets
to OpenCode's deny-first overlay and carries resolved read/write roots into
preparation. OpenCode yolo, unrestricted Bash, omitted additional-root
classification, arbitrary CLI flags, and ordinary tool-list passthrough fail
before the model process starts.

**Lifecycle:** The main process is supervised once, inspection runs at most
once and only after a successful main exit, and cleanup runs after success,
non-zero exit, malformed output, inspection failure, timeout, and pre-spawn
failure. Credential forwarding is allowlisted by environment-variable name;
ambient provider credentials are not inherited.

**Compatibility:** Hive retains its existing mutable run result and exposes the
component `NormalizedOutcome` through `observable_result` for OpenCode. Legacy
profile argv, process handling, and permission behavior remain unchanged.
