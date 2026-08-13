---
title: Remove unused module secret accessor
date: 2026-08-13
---

- Removed the uncalled
  `Hive::Modules::CapabilityContext#require_secret!` accessor. Module execution
  consumes validated secret grants through target configuration; no runtime
  adapter requested individual bindings through this facade.
- Capability snapshots still require and validate the `secrets` grant set.
