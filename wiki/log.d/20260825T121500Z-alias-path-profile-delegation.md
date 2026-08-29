# 2026-08-25 — Alias resolution delegates to the profile config root

## Summary

The last two provider-neutral hardcodes of Claude's filesystem default are
gone. `Hive::AgentSkills::Adapters::Base#alias_path` and
`Hive::AgentSkills::Inspector#alias_path_for` no longer branch on
`CLAUDE_CONFIG_DIR` / `~/.claude` themselves; both derive the alias directory
from the selected `AgentProfile` (`default_configuration_directory` plus
`configuration_directory`), the same single authority that already owns every
other adapter config root.

## Motivation

`Base#config_root` had already been reduced to profile delegation, but alias
path resolution kept a private copy of the provider default in shared code.
A provider renaming its config directory or override key would have had to be
re-taught to the neutral base and inspector, recreating the duplication this
boundary work removed.

## Behavior

Observable paths are unchanged for the shipped manifest (aliases are declared
relative to each provider's default configuration directory and validated
against that provider's `skill_alias_root`). The only semantic tightening:
an override environment value must be absolute, matching how
`AgentCliRuntime::Profile#configuration_directory` already treats overrides
for non-alias roots. Regression test: alias planning honors the profile's
override (`test_claude_alias_path_follows_the_profile_configuration_root`).
