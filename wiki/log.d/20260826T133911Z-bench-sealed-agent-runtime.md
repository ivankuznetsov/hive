---
title: Seal benchmark controller runtime from candidates
category: security
date: 2026-08-26
---

- Packaged the canonical benchmark's root-only, commit-labelled Hive control
  bundle and Hive-free candidate gem tree.
- Added Pi and OpenCode launchers that hand off `/work` to uid 1000, clear Linux
  capabilities, and prevent the model from reading controller implementation.
- Added `isolation.sealed_agent_runtime` campaign validation and propagation;
  the driver fails before model spend on a stale image SHA or unsupported agent.
- Bound runtime visibility into generation identity alongside depth-one source
  history and provider-only egress, preventing reuse of older exposed artifacts.
- Left fresh sealed Ox Alpha Pi/OpenCode generation, judging, deliberation, and
  publication as live follow-through after the new commit is dogfooded.
