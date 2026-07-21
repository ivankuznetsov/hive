## 2026-07-21 — Align public category and native-web claims

Updated the README and RubyGems metadata to describe Hive as a durable,
local-first workflow engine for AI agents, with software delivery as flagship
proof rather than a coding-only boundary. The public overview now names the
built-in `content` and `bench` workflows, installable Honeycombs, owner-authored
workflows, Claude/Codex/Pi/Grok profiles, OpenClaw, and the native local web UI.

Replaced the obsolete FAQ claim that Hive had no built-in web UI with the
current `hive setup` / `hive web` contract over shared local workflow state and
closed the matching known gap. The source evidence remains [[commands/web]],
[[modules/agent_profile]], [[commands]], and [[operating]].

**Tests:** focused public-credibility assertions in
`test/unit/release_contract_test.rb`; release metadata and workflow contracts
remain covered by their existing focused suites.
