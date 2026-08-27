# 2026-08-22 — Each agent profile owns its default config root

## Summary

`Hive::AgentSkills::Adapters::Base#config_root` no longer branches over the
closed provider set (`claude`, `codex`, `pi`, `grok`, `opencode`) to pick a
default filesystem root. It delegates to the selected `AgentProfile`, whose
agent-cli-runtime profile owns both the default root and its environment
override. This stronger profile boundary supersedes the earlier per-adapter
constant design while preserving the finding's single-owner requirement.

## Motivation

The base adapter duplicated provider knowledge: adding or renaming a provider
required changing both provider registration and a central `case` statement.
Delegating to the profile keeps each provider's filesystem defaults beside
its other native runtime facts.

## Behavior

Observable paths are unchanged. Regression tests assert every registered
profile and its setup adapter resolve the same expected root when the override
is unset, and still honor the profile's override (for example
`CLAUDE_CONFIG_DIR`) when set.
