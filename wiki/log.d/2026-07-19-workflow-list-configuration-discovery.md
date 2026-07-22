---
date: 2026-07-19
slug: workflow-list-configuration-discovery
---

- Bumped `hive workflow list --json` to schema v2 and made verified selected
  managed rows rediscoverable by active configuration digest and stable-slot
  agent/model/effort mapping.
- Added optional-input binding and availability disclosure without environment
  values; built-in/authored rows retain their prior shape.
- Distinguished task-retained configuration pins from a newer active
  configuration on the same immutable package generation.
