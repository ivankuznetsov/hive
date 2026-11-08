# 2026-11-04 — Muse agent profile and operating skill

**Action:** Added Muse (`muse`) as a sixth built-in `AgentProfile`,
appended after OpenCode so no default agent selection changes: Claude remains
the default stage agent and `DEFAULT_GLOBAL_AGENTS` stays `claude + codex`.
The `agent-cli-runtime` gem gained the `muse` profile (`muse exec --json`,
positional prompt, `--model`/`--reasoning-effort`, `--yolo` unscoped path,
sandboxed `workspace-write`/`read-only` flag sets, `run.usage` metering,
`run.terminal.*` error extraction, XDG auth/settings resolution), plus two
generic contract points: dual-form version output (`1.4.14 (1.4.14-R7309.1)`)
is unambiguous when all tokens share one numeric core, and profiles may own a
`configuration_directory_probe`. Hive added `Hive::AgentSupport::Muse`
(terminal final-message extraction with prompt-echo log opacity,
subscription-only preflight that scrubs `META_API_KEY`, XDG default-model
resolution, flat-id skill verification across all Muse skill roots),
config/routing/schema/TUI/web enumeration wiring, and a `muse login`
operator-ward web flow. The canonical Hive operating skill is now projected
for Muse as `/hive` and published by the bundled skillpack path into
`$XDG_CONFIG_HOME/muse/skills/hive`.

**Boundaries:** Compound Engineering is not Hive-provisionable for Muse yet
(Muse refuses the upstream plugin bundle's symlink entries), managed
workflow actors fail closed without a `Runtime` facet, prompts share the
positional-argv ceiling, and Meta models have unknown USD cost. Recorded in
[[gaps]].

**Verification:** New focused tests (`test/unit/muse_agent_test.rb`,
`test/unit/agent_skills/muse_skill_test.rb`,
`components/agent-cli-runtime/test/muse_profile_test.rb`) cover argv,
permission modes, version/auth/default-model handling, routing, skill
resolution, spawn success/failure/timeout through `test/fixtures/fake-muse`,
and the XDG skill publish cycle. The projected skill passes
`muse skills validate` (valid, zero diagnostics) and is discovered by
`muse skills list`; a live Hive spawn through the real binary in `--provider
echo` mode completed with a structured final message. Existing
agent/profile/skillpack/config/web test files pass; three enumeration
expectations were updated for the new provider.

**Wiki:** Updated [[index]], [[modules/agent_profile]],
[[modules/agent_cli_runtime]], [[modules/config]], and [[gaps]].
