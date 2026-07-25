# 2026-07-25: Use Grok's native Compound Engineering plugin

- Added Grok as a managed Compound Engineering provider with native plugin
  install, enable, update, live inventory, and read-only filesystem inventory.
- Added `Hive::SkillCheck::Grok` so enabled plugin skills resolve from
  `GROK_HOME` before a stage spawns.
- Replaced the temporary self-contained Grok review prompt with a real
  `/ce-code-review` invocation and exposed `grok-ce-code-review` as an opt-in
  ordinary reviewer without changing fresh-project defaults.
