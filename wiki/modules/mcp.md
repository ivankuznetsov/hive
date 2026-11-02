---
title: Hive-owned MCP (Hive::Mcp)
type: module
source: lib/hive/mcp.rb, lib/hive/mcp/*.rb, lib/hive/agent_support/*/mcp.rb
created: 2026-10-15
updated: 2026-11-02
tags: [module, mcp, agent, config, decision]
---

**TLDR**: Every agent Hive launches gets only the MCP servers Hive grants it. Personal and project MCP configs of Claude, Codex, OpenCode and Pi are not loaded; Grok has no isolation flag and is reported by `hive doctor`. Servers are defined once in a global catalog (`mcp.servers` in `~/.config/hive/config.yml`, filled by [[commands/mcp]] or by hand) and granted per project or stage with `mcp.use`. `mcp.inherit_user: true` restores the old behaviour. Decision: ADR-054 in [[decisions]] (amends ADR-051).

## Config

```yaml
# ~/.config/hive/config.yml — the only place servers are defined
mcp:
  inherit_user: false
  servers:
    linear: { url: https://mcp.linear.app/mcp, imported_from: codex, oauth_logins: [codex] }
    context7:
      command: npx
      args: ["-y", "@upstash/context7-mcp@1.0.14"]
      env_from: { CONTEXT7_API_KEY: CONTEXT7_API_KEY }   # child var <- host var name
    internal-api: { url: https://mcp.example.com/mcp, bearer_token_env: INTERNAL_MCP_TOKEN }

# .hive-state/config.yml — grants
mcp: { use: [context7] }            # project default
execute: { mcp: { use: [context7, linear] } }   # a stage block replaces it
```

- Grant resolution (`Hive::Mcp::Settings.resolve(cfg, scope:)`): the most specific block's `mcp.use` (`review.fix`, then `review`), else the project `mcp.use`. `babysitter`, `patrol`, `refactor_patrol` and `daily_digest` never inherit the project grant.
- Secrets are env-var names only (`env_from`, `bearer_token_env`, `headers_env`). A literal `Authorization` header and secret-looking literal env keys or header names (`TOKEN`, `SECRET`, `PASSWORD`, `API_KEY`, also hyphenated like `X-Api-Key`) are rejected at load.
- `oauth_logins` lists the agents holding a saved OAuth login (presence only). A server with OAuth fields or that list renders only to agents in it; others skip it with a launch-log notice and a doctor warning pointing at `hive mcp login`.
- Project `mcp.servers` is rejected with a pointer to `hive mcp import`.

## Launch path

For the retained uncertainty and historical evidence, see [Pi floor lives only on the Hive side (2026-10-15)](#pi-floor-lives-only-on-the-hive-side-2026-10-15).

`Hive::Mcp.prepare(profile:, policy:, cwd:, version:)` returns a `Launch` (argv, default argv, env, passthrough env names, config overlay, cleanup paths, isolation, notices) from the agent's facet `AgentSupport::<Agent>::Mcp` (`Hive::Mcp.adapter`). Each facet also declares `ISOLATES` and `ACCEPTS_GRANTS`, implements `discover` for `hive mcp import`, and Codex/Claude implement `login_argv`; agent-specific code stays under `lib/hive/agent_support/<agent>/`:

| Agent | Isolation | Granted servers |
|---|---|---|
| claude | `--strict-mcp-config --mcp-config <0700 dir>/mcp.json` (0600) | entries in that file; secrets as `${VAR}`; name/type/url/headers kept identical so a saved login is found |
| codex | `--ignore-user-config` (kept once when a sandbox preset already passes it) | `-c mcp_servers.<name>.*`; `bearer_token_env_var`, `env_http_headers`, `env_vars`, `oauth_resource` |
| opencode | `opencode debug config` in the launch cwd, each server disabled in `OPENCODE_CONFIG_CONTENT` | same overlay, `{env:VAR}`; a failed probe launches with a notice (`isolation=partial`) |
| pi (>= 1.0.4) | `--no-mcp` | not possible; dropped with a notice |
| grok, custom profiles | none | none; `isolation=none` notice |

Because Codex ignores `config.toml`, the Codex launch replays `model`, `model_reasoning_effort`, `service_tier`, `personality`, `model_provider` (+ `model_providers`), `profile` (+ `profiles`), `openai_base_url` and `mcp_oauth_credentials_store` as defaults that an identity or routing argument for the same key overrides (`Launch#arguments_for`), and re-enables the managed-skill plugins (`config/agent-skills.yml`) that `config.toml` enables. Provider keys that may hold a credential are not replayed. `Hive::AgentSupport::Codex::UserConfig` is the line-based reader.

Wiring:

- `Stages::Base.spawn_agent(mcp_scope:)` resolves the grant (scope defaults to the task stage, `4-execute` → `execute`), prepares after preflight, and removes rendered files in `ensure`. Explicit scopes: `babysitter`, `rebase`, `plan_review`, `review.fix`/`.triage`/`.ci`/`.browser_test`, `artifacts`, workflow stage names.
- A bare `Hive::Agent` renders the cfg-less grant itself and cleans up after `run!`. Direct callers (patrol `patrol`/`patrol.fix`, refactor patrol) use `Hive::Mcp.with_launch`. The diagnosis (`diagnose`), daily digest (`daily_digest`) and display-name launchers use `with_launch` + `Hive::Mcp.compile`.
- A managed `RuntimePolicy` with `mcp_isolated` (strict Claude policy, Codex/Pi/Grok managed actors) gets nothing extra; a yolo `direct_policy` is not isolated and gets normal rendering.
- The agent log records `[hive] mcp isolation=<isolated|partial|none|inherit|managed>` and each notice.
- `test/unit/mcp/launch_site_contract_test.rb` fails on any `AgentRuntime.compile(` / `Hive::Agent.new(` / `profile.bin` argv site that does not reference `Hive::Mcp`; the TUI steer session is the listed exemption.
- The native Codex reviewer (`AgentSupport::Codex::Reviewer`, scope `review`) runs `codex exec review` inside `Hive::Mcp.with_launch`, so it gets the same `--ignore-user-config` + `-c` launch as other Codex launches (top-level `codex review` has no such flag). The launch's notices go to the task's `isolation-warnings.log`, since the adapter keeps no agent log. See [[modules/reviewers]].

## Doctor

`Hive::Mcp::DoctorCheck` adds `hive doctor` rows (stage `mcp`): unreadable catalog, `inherit_user` on, roles on agents Hive cannot isolate (Grok), roles whose agent cannot receive grants (Pi, Grok), OAuth grants without a login, referenced env vars unset (names only), Codex settings carried over (informational `present` row), personal servers not in the catalog, and drifted or vanished catalog entries. See [[commands/doctor]].

## Backlinks

- [[commands/mcp]] · [[commands/doctor]] · [[modules/config]] · [[modules/agent_profile]] · [[decisions]] · [Known gaps](#known-gaps)

## Known gaps

### Pi floor lives only on the Hive side (2026-10-15)

#### Source S04, lines 60–62: Hive-owned MCP follow-ups (2026-10-15)

Hive now renders MCP for every agent it launches (plan
2026-10-15-001; [[modules/mcp]]). Open items:

#### Source S04, lines 63–67: Hive-owned MCP follow-ups (2026-10-15)

- **Pi floor lives only on the Hive side.** `agents.pi.min_version` defaults to
  `1.0.4` (the first Pi with `--no-mcp`), but the `agent-cli-runtime`
  component's `PI` profile still says `0.70.2`. Raising it needs its own
  package change and release (`docs/RELEASING.md`, "Releasing
  agent-cli-runtime"); until then cfg-less profile lookups keep the old floor.

### Bench harness Pi profiles (2026-10-15)

#### Source S04, lines 74–75: Hive-owned MCP follow-ups (2026-10-15)

- **Bench harness Pi profiles** (`templates/builtins/bench/runtime/harness/`)
  launch Pi outside Hive and still declare `0.70.2`; they pass no `--no-mcp`.

### Native Codex reviewer parser and live-pass evidence (2026-10-16)

The unresolved qualifications remain verbatim in the [native reviewer isolation history](#native-codex-reviewer-isolation-2026-10-16).

### Resolved

#### Live-skills workflow Pi package (2026-10-15)

##### Source S04, lines 68–73: Hive-owned MCP follow-ups (2026-10-15)

- **Closed 2026-10-15: live-skills workflow Pi package.** The
  live-agent-skills workflow installed the deprecated
  `@mariozechner/pi-coding-agent` (latest 0.73.1, below the new floor); it now
  installs `@earendil-works/pi-coding-agent`, which the npm registry names as
  its replacement. (The Hivebox image that pinned `@mariozechner/pi@0.70.2` was
  removed by ADR-055.)

#### Native Codex reviewer isolation (2026-10-16)

##### Source S04, lines 76–83: Hive-owned MCP follow-ups (2026-10-15)

- **Closed 2026-10-16: native Codex reviewer isolation.** The `codex_review`
  reviewer ran top-level `codex review`, which has no `--ignore-user-config`,
  so it kept personal MCP servers. It now runs `codex exec review` with the
  standard Codex MCP launch ([[modules/reviewers]]). Still open: the parser's
  fixtures are one real codex-cli 0.162.1 findings run; the clean-verdict and
  usage-limit fixtures are derived from it, not captured, and no live patrol
  pass has run on the new argv yet.
