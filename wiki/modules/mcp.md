---
title: Hive-owned MCP (Hive::Mcp)
type: module
source: lib/hive/mcp.rb, lib/hive/mcp/*.rb, lib/hive/agent_support/*/mcp.rb
created: 2026-10-15
updated: 2026-10-15
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

- [[commands/mcp]] · [[commands/doctor]] · [[modules/config]] · [[modules/agent_profile]] · [[decisions]] · [[gaps]]
