# 2026-11-25 — Antigravity CLI (`agy`) agent profile, operating skill, and Compound Engineering

**Action:** Added Antigravity CLI (`agy`) as the seventh built-in
`AgentProfile`, appended after `muse` so no default agent selection changes:
Claude remains the default planning/execute stage agent and
`DEFAULT_GLOBAL_AGENTS` stays `claude + codex`. The `agent-cli-runtime` gem
gained the `:agy` profile (`agy --input-format=text` with `:piped_stdin`
keeping large prompts out of argv, `--dangerously-skip-permissions`, repeatable
`--add-dir`, `--model`, `--effort`, `--output-format stream-json`,
`step_update`/`result` usage extraction with `thinking_tokens` and
`cache_read_tokens`, non-`SUCCESS` `result` error extraction, and binary-safe
`File.binread` auth file probing for `~/.gemini/antigravity-cli/antigravity-oauth-token`).
Hive added `Hive::AgentProfiles::AGY`, `Hive::AgentSupport::Agy` (`result`
final-message extraction, `step_update` and successful-`result` log opacity,
`Stream::TokenMeter` for `{"event":"result"}` termination, `settings.json`
display-name-to-slug model normalization, `plan_review_launch_kwargs` for
disposable-worktree plan review and planner revisions, workspace/global/enabled-plugin skill
resolution under `~/.gemini/config`, and native `agy plugin install`/`enable`
Compound Engineering setup adapter), `reviewer_agy_ce_code_review.md.erb`,
config/routing/schema/TUI/UsageDb/init wiring, and paste-back Hive Web OAuth
via `agy acp --login`. The canonical Hive operating skill projects for `agy`
as `/hive` into `~/.gemini/config/skills/hive`.

**Boundaries:** Scoped `workspace-write`/`read-only` sandbox modes, managed
workflow actors (no `Runtime` facet), and named launch bindings (no config-dir
env override in `agy`) fail closed; `input_includes_cache_read` and USD pricing
stay unknown. Recorded in [[gaps]].

**Verification:** Live `agy 1.5.17` probes confirmed `--version` (`1.5.17`),
`--input-format=text` piped and tempfile stdin print mode, exact `init` /
`step_update` / `result` NDJSON payloads, `agy acp --login` paste-back OAuth,
and offline `agy plugin install`/`list --json`/`enable`/`disable` behavior.
New focused tests (`components/agent-cli-runtime/test/agy_profile_test.rb`,
`test/unit/agy_agent_test.rb`, `test/unit/agent_skills/agy_skill_test.rb`,
`test/unit/agent_skills/agy_ce_test.rb`) and `test/fixtures/fake-agy` cover
runtime compilation, binary-safe OAuth checks, display-name normalization,
routing, stream metering, spawn lifecycle, bundled `/hive` publication, and
native CE provisioning.

**Wiki:** Updated [[index]], [[modules/agent_cli_runtime]],
[[modules/agent_profile]], [[modules/agent_support]], [[modules/config]],
[[commands/setup-agents]], [[commands/web]], [[token-usage]], and [[gaps]].
