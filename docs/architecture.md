# Architecture

Hive is a Ruby CLI around filesystem state, agent subprocesses, and git worktrees. This page explains the user-facing architecture; the deep reference remains in [wiki/architecture.md](../wiki/architecture.md).

## The Three Trees

```text
~/Dev/your-project/
|-- app files...
`-- .hive-state/                    # worktree of orphan branch hive/state
    |-- config.yml
    |-- stages/
    `-- logs/

~/Dev/your-project.worktrees/
`-- <slug>/                         # feature worktree created by 4-execute
    `-- app files...

~/Dev/hive/
|-- bin/hive
|-- lib/hive/
`-- config.yml                      # global registry
```

The project checkout holds code. `.hive-state/` holds durable Hive state on the separate `hive/state` branch. The feature worktree holds code changes for one task branch.

Managed Honeycomb workflows add immutable package generations below
`.hive-state/workflows/<name>/versions/<source-commit>/`. A canonical
`honeycomb.lock.json` is the only activation pointer. Lifecycle changes share a
workflow mutation lock and durable transaction journal; package placement is
inert until the pointer is atomically replaced and the scoped state commit
succeeds. Task metadata pins the source commit plus manifest digest, so a task
resolves its exact generation without registering duplicate workflow ids in the
process-wide Loader overlay.

## Storage Layout

`hive init .` creates the per-project storage tree:

```text
<project>/.hive-state/
|-- config.yml
|-- .commit-lock                    # (only while a commit is in flight)
|-- stages/
|   |-- 1-inbox/<slug>/
|   |-- 2-brainstorm/<slug>/
|   |-- 3-plan/<slug>/
|   |-- 4-execute/<slug>/
|   |-- 5-open-pr/<slug>/
|   |-- 6-review/<slug>/
|   |-- 7-artifacts/<slug>/
|   |-- 8-finalize/<slug>/
|   `-- 9-done/<slug>/
`-- logs/<slug>/<stage>-<UTC-ts>.log
```

Each stage has one state file: `idea.md` (1-inbox), `brainstorm.md` (2-brainstorm), `plan.md` (3-plan), `task.md` (shared across 4-execute, 6-review, 9-done), `artifact.md` (7-artifacts), `pr.md` (shared across 5-open-pr and 8-finalize), or `summary.md` (8-finalize). `worktree.yml` points from Hive state to the feature worktree created during execute. The xbookmark walkthrough captures a mid-run tree in [docs/assets/xbookmark-state-tree.txt](assets/xbookmark-state-tree.txt).

## Local Web Runtime

Hive web is the shared Rails application and a managed runtime dependency. The
CLI gem packages the gem metadata needed for an installed package root to be a
valid Bundler path dependency; the Rails source itself remains in the managed
web bundle. `hive web` resolves `HIVE_WEB_APP_DIR`, then
`${XDG_DATA_HOME}/hive/web`, then a source checkout `web/`. Released bundles
are authenticated through the release's cosign-signed checksum manifest before
extraction or execution. A custom remote `HIVE_WEB_BUNDLE_URL` also requires
an exact `HIVE_WEB_BUNDLE_SHA256`; local bundle directories remain a
development-only input. `hive setup` and `hive web` prepare the managed app in
a staging directory, install its Rails bundle, precompile production CSS and
JavaScript, and verify the required entrypoints plus every manifest asset
before activating it. A current bundle with missing assets is repaired on the
next setup or launch. The deprecated `HIVEBOX_WEB_APP_DIR` alias remains
accepted through the next major release with migration guidance. The web
storage directory remains under
`${XDG_STATE_HOME}/hive/web-storage`, so the TUI, daemon, and web UI operate
on the same local registry, project `.hive-state/` directories, and task
folders. Local loopback requests use the `hive` identity and do not require
GitHub; connecting GitHub only enables repository listing and cloning. The
trust check requires both the actual socket peer and the normalized Host to be
loopback. Rails accepts any other hostname so a reverse proxy or tunnel needs
no provider-specific Hive configuration, but those requests use the GitHub
device-flow owner gate even when the proxy connects over localhost. The Host
decision uses the literal `HTTP_HOST` authority and ignores
`X-Forwarded-Host`. A proxy or TCP forwarder that lets an untrusted client send
`Host: localhost` enters the local trust boundary and must authenticate or
restrict its clients. An ownerless instance reached through an owner-gated
hostname is claimed by its first successful GitHub login. Hivebox is the
separate container deployment of the same Rails application.

Normal `hive setup` installs, enables, starts, and probes the per-user service
on supported Linux/macOS while preserving drifted units. Bare `hive web` is the
blocking foreground path. The default URL is loopback-only and setup never
creates exposure; Windows uses WSL with systemd or the Hivebox container path.

The canonical shared-app environment settings are `HIVE_WEB_APP_DIR`,
`HIVE_WEB_ORIGIN`, `HIVE_WEB_STORAGE_DIR`, `HIVE_WEB_LOCAL_LOOPBACK`,
`HIVE_WEB_DIFF_TIMEOUT_SEC`, and `HIVE_WEB_CLONE_TIMEOUT_SEC`. Their named
legacy aliases use the same suffix under `HIVEBOX_*` (with
`HIVEBOX_WEB_APP_DIR` for the app directory) through the next major release.
Blank values are unset; a canonical value wins over its alias, including when
the canonical value is invalid, and a migration warning names the replacement.
Warnings appear on stderr, in setup/web JSON, and as `kind: warning` doctor
rows. Container-only variables such as `HIVEBOX_IMAGE`, `HIVEBOX_NAME`,
`HIVEBOX_BIND`, `HIVEBOX_PORT`, `HIVEBOX_DATA`, `HIVEBOX_REPOS_DIR`,
`HIVEBOX_SESSION_SECRET`, and `HIVEBOX_SUPERVISOR_PID` remain canonical and do
not warn.

## Agents

Hive has built-in agent profiles for `claude`, `codex`, `pi`, and `grok`. A profile defines the binary, version check, prompt-delivery style, add-dir behavior, skill invocation syntax, and status-detection mode. Stage runners look up the configured profile before spawning the subprocess. Grok runs headlessly with `grok -p <prompt> --always-approve --output-format streaming-json`; it accepts `XAI_API_KEY` or device-login credentials, honors an absolute `GROK_HOME`, and lets an absolute `GROK_AUTH_PATH` select the credential file directly with higher precedence.

Default new-project setup uses `claude` for planning, `codex` for execute, a normal reviewer set that can include Claude, Codex, and PR review toolkit agents, and a narrower patrol PR reviewer set that defaults to Codex only. The profile details live in [wiki/modules/agent_profile.md](../wiki/modules/agent_profile.md).

## Managed Agent Skills

[`config/agent-skills.yml`](../config/agent-skills.yml) is the authoritative,
packaged mapping from stable Hive capabilities to agent-specific package
sources, compatible versions, invocations, probes, prerequisites, and aliases.
The initial managed set is:

| Package | Capabilities | Agents |
|---|---|---|
| `compound-engineering@compound-engineering-plugin` | `ce-brainstorm`, `ce-code-review`, `ce-test-browser` | Claude, Codex, Pi |
| `llm-wiki` | `wiki-plan` | Claude, Codex, Pi |
| `pr-review-toolkit@claude-plugins-official` | `pr-review-toolkit:review-pr` | Claude |

`hive doctor` combines bounded native inventory with the same filesystem
resolution rules stages use. It is read-only and reports `healthy`, `missing`,
`stale`, `incompatible`, `conflicting`, or `unavailable`. `hive setup-agents`
turns only missing/stale managed rows into one immutable operation plan,
obtains consent once, revalidates ownership/state, uses supported native CLIs,
and then runs the shared inspector again. Package work is deduplicated while
capability health remains per row. Narrow filters recursively retain declared
package prerequisites; an uninspectable or unhealthy prerequisite blocks its
dependent operation. Native commands run in owned process groups that are
terminated and reaped before a timeout is reported.

Hive owns a Claude `/plan` alias only when absent or already Hive-owned. A
user-authored alias, higher-precedence shadow skill, or mismatched Codex
marketplace/plugin owner is a conflict: setup leaves it byte-identical and
prints manual guidance. Custom workflow skills remain unmanaged.

Run:

```bash
hive doctor
hive setup-agents             # one aggregate preview and prompt
hive setup-agents --yes --json
```

To extend a built-in default, add its capability and per-agent contracts to
the manifest, expose it through the runtime default constants/template, and
update the manifest-coverage plus live-resolution tests. The coverage test
fails when a built-in coding default drifts beyond the manifest.

## Config Schema

Global registry lives at `~/Dev/hive/config.yml`:

```yaml
registered_projects:
  - name: your-project
    path: /home/you/Dev/your-project
    hive_state_path: /home/you/Dev/your-project/.hive-state
```

Per-project config lives at `<project>/.hive-state/config.yml`. The block below is an annotated example; see [`templates/project_config.yml.erb`](../templates/project_config.yml.erb) for the full live template (it ships extra inline comments and ERB-resolved defaults, including a `gh.network_timeout_sec` knob):

```yaml
project_name: your-project
default_branch: main
worktree_root: /home/you/Dev/your-project.worktrees
hive_state_path: .hive-state

brainstorm:
  agent: claude
plan:
  agent: claude
execute:
  agent: codex
conditions:
  authority: markers
  stages: {}
open_pr:
  agent: claude
finalize:
  agent: claude

budget_usd:
  brainstorm: 50
  plan: 100
  execute_implementation: 500
  open_pr: 50
  finalize: 50
  review_ci: 100
  review_triage: 75
  review_fix: 500
  review_browser: 100
  patrol: 100

timeout_sec:
  brainstorm: 1800
  plan: 3600
  execute_implementation: 14400
  open_pr: 1800
  finalize: 1800
  review_ci: 3600
  review_triage: 1800
  review_fix: 14400
  review_browser: 3600
  patrol: 3600

review:
  ci:
    command: null            # path to project CI command; null skips the CI-fix phase
    max_attempts: 3
    agent: claude
    prompt_template: ci_fix_prompt.md.erb
  triage:
    enabled: true
    agent: claude
    bias: courageous         # or `safetyist`
  fix:
    agent: claude
    prompt_template: fix_prompt.md.erb
    auto_commit:
      scope_check:
        enabled: true
  browser_test:
    enabled: false
    agent: claude
    prompt_template: browser_test_prompt.md.erb
    max_attempts: 2
  github_publish:
    enabled: true
    max_attempts: 2
  max_passes: 2
  max_wall_clock_sec: 14400
  reviewers: []              # `hive init` writes the recommended set here

daemon:
  enabled: true

patrol:
  enabled: false
  trigger: continuous        # or `new_commits` / `timer`
  poll_interval_sec: 600
  agent: claude
  min_confidence_to_fix: medium
  min_alpha_to_fix: 70
  max_findings_per_feature: 3
  max_features_per_cycle: 12
  max_fixes_per_feature_per_cycle: 1
  max_fix_attempts_per_cycle: 6
  max_prs_per_cycle: 3
  draft_prs: false
  review_prs: true
  commands:
    format: null
    lint: null
    typecheck: null
    test: null

rebase:
  enabled: true
  conflict_resolution_timeout_sec: 2700
```

## Per-stage model routing

The optional top-level `models:` map overlays model and reasoning effort onto
Hive's built-in calls without changing their selected `agent:` provider. Model
and effort resolve independently: exact key, coarse family, the call's current
identity/default, then the legacy global fallback. This is a copyable
software-workflow configuration:

```yaml
brainstorm:
  agent: claude
plan:
  agent: codex
execute:
  agent: codex
review:
  reviewers:
    - name: architecture
      kind: agent
      agent: claude
      output_basename: architecture
      skill: ce-code-review
      prompt_template: reviewer_claude_ce_code_review.md.erb
    - name: implementation
      kind: agent
      agent: codex
      output_basename: implementation
      skill: ce-code-review
      prompt_template: reviewer_codex_ce_code_review.md.erb

models:
  plan:
    model: gpt-5.6-sol
    effort: xhigh
  execute:
    effort: high
  execute_implementation:
    model: gpt-5.6-sol
  review:
    effort: high
  review_fix:
    model: gpt-5.6-sol
```

`execute_implementation` inherits `execute.effort`; `review_fix` inherits
`review.effort`. The project keys are `brainstorm`, `plan`, `execute`,
`execute_implementation`, `rebase`, `diagnose`, `babysitter`, `review`,
`review_ci`, `review_reviewers`, `review_triage`, `review_fix`,
`review_browser`, `patrol`, `patrol_review`, `patrol_fix`, `open_pr`,
`artifacts`, and `finalize`. `digest` uses the same entry syntax but is owned
by the global config.

Execute, open-PR, review-fix, and review-CI selections are frozen in the
generation-scoped implementation identity. Retrying that generation does not
re-read edited routing config; a new generation may capture new values. Hive
validates an effective routed control against the already-selected profile
before a marker, journal identity, subprocess, or remote mutation. Codex
receives routed global controls before `exec` or `review`; other providers
receive only their native flags. Removing or omitting `models:` requires no
migration and preserves the legacy argv path.

Generation-scoped condition authority is intentionally staged. Existing
projects stay on `markers`; operators may set only `stages.4-execute` to
`shadow`, then to `conditions` after the parity bar is met. See the
[condition rollout runbook](condition-rollout.md). Other stages remain
marker-authoritative in this increment.

`hive init` writes the full per-project YAML from `templates/project_config.yml.erb`, including the recommended `review.reviewers` set and the narrower `patrol.review.reviewers` set. Workflow verbs `hive archive` and `hive migrate` do not take config blocks; they read project state and operate on stage folders.

`HIVE_HOME` changes where Hive reads the global registry. `HIVE_CLAUDE_BIN`, `HIVE_CODEX_BIN`, and `HIVE_PI_BIN` override agent binaries for tests or local shims.

## Locking

Hive uses two locks. A per-task `.lock` stays held for the full stage run, so two processes do not mutate the same task. A per-project `.commit-lock` serializes short commits on the `hive/state` branch while different tasks can still run in parallel.

## Markers And Idempotency

Stage commands are safe to retry because they inspect the task folder, current stage, and terminal marker before moving anything. The `--from <stage>` flag is the retry-safety assertion for agents: if a previous attempt already advanced the task, the retry returns `WRONG_STAGE` instead of advancing again.

## Deeper Engineering Reference

- [wiki/architecture.md](../wiki/architecture.md)
- [wiki/decisions.md](../wiki/decisions.md)
- [wiki/state-model.md](../wiki/state-model.md)
- [wiki/operating.md](../wiki/operating.md)
- [wiki/templates.md](../wiki/templates.md)
- [wiki/modules/lock.md](../wiki/modules/lock.md)
