# Headless Agent CLI Matrix

**Date captured:** 2026-04-25
**Spike unit:** U11 (per `docs/plans/2026-04-25-001-feat-5-review-stage-plan.md`)
**Purpose:** Document the headless invocation contract for every agent CLI hive evaluates as a candidate `AgentProfile` in U12, so the user can pick any supported CLI per role (CI-fix, reviewer, triage, fix, browser-test) per project config.

This doc is the authoritative source for the `AgentProfile` instances under `lib/hive/agent_profiles/` (created in U12). If a CLI's behavior changes upstream, update this doc and the corresponding profile in lockstep.

> **Scope decision (2026-04-25, post-spike):** **opencode is dropped from v1 scope.** Reasons captured in the per-CLI summary below: (a) no native CE plugin → hive must inline SKILL.md content, losing plugin-update propagation; (b) per-spawn filesystem isolation requires temp-config writing rather than a simple flag, which is non-trivial to implement and harder to reason about than the per-spawn `--add-dir` model; (c) hive's v1 default reviewer set already covers two profile-supported CLIs (claude + codex), so opencode adds maintenance surface without unique signal. The opencode column below is preserved as evidence of evaluation; U12 ships profiles for **claude, codex, and pi only**. Opencode can be revisited in v1.1 if a user needs it (e.g., for OpenCode Zen cost reasons).

---

## Comparison matrix

| Dimension | claude | codex | pi | opencode |
|-----------|--------|-------|----|----|
| Version captured | `2.1.118 (Claude Code)` | `codex-cli 0.125.0` | `0.70.2` | `1.14.25` |
| Headless flag | `-p` / `--print` | `codex exec [PROMPT]` (subcommand, alias `e`) | `-p` / `--print` | `opencode run [message..]` (subcommand) |
| Permission-skip flag | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` (full bypass; matches claude's intent) — alternatives: `-s workspace-write` + `--ask-for-approval never`, or `--full-auto` (sandboxed auto-execute) | **none** — pi has no permission gate; tools (`read`, `bash`, `edit`, `write`) are enabled by default. Tool-level restriction via `--tools <allowlist>` or `--no-tools` is the only knob. | `--dangerously-skip-permissions` (boolean, same name as claude). Bypasses opencode's built-in permission system. |
| Filesystem-isolation flag (`--add-dir` equivalent) | `--add-dir <directories...>` (multi-arg, single flag) | `--add-dir <DIR>` (single arg per flag, repeatable). Also `-C, --cd <DIR>` for working root. | **none — gap.** No `--add-dir`, no chroot, no sandbox flag. Filesystem access is bounded only by the process's own cwd + the OS user's permissions. ADR-008's `--add-dir` boundary cannot be reproduced. Workaround: spawn pi from a deeper cwd (e.g., the task folder) to reduce blast radius — but the bash tool can `cd` out, so this is convention not enforcement. | **partial.** No per-spawn `--add-dir`; opencode has a config-level permission system at `~/.config/opencode/opencode.json` with `external_directory` ask/allow rules per pattern. `--dir <path>` sets the working root per spawn. To bound to a task folder, set `--dir <task folder>` AND configure `external_directory: {pattern: "*", action: "deny"}` at config level. Per-spawn isolation requires writing a temp config; not as ergonomic as claude's `--add-dir`. |
| Budget cap flag | `--max-budget-usd <amount>` (requires `--print`) | **none** — no built-in dollar-budget cap. Hive must enforce wall-clock timeout only. | **none** — wall-clock timeout only. | **none** — wall-clock timeout only. (`opencode stats` reports usage post-hoc; not a per-spawn cap.) |
| Output format flag | `--output-format text\|json\|stream-json` + `--include-partial-messages` + `--verbose` | `--json` (emit JSONL events to stdout) + `-o, --output-last-message <FILE>` (write the agent's last message to a known path) | `--mode text\|json\|rpc` (default text) | `--format default\|json` (default formatted text or raw JSON events) |
| Version-print flag | `-v` / `--version` → `<semver> (<ProductName>)` | `-V` / `--version` → `codex-cli <semver>` | `-v` / `--version` → `<semver>` | `-v` / `--version` → `<semver>` (e.g., `1.14.25`) |
| Cwd model | Implicit from process `cwd`; auto-discovers `CLAUDE.md`, `.claude/skills/`, `.claude/agents/`, `.claude/settings.json` from cwd | Implicit from process `cwd`, or explicit via `-C, --cd <DIR>`. Auto-discovers `AGENTS.md`, `~/.codex/plugins/` (CE skills installed there), `.codex/` config | Implicit from process `cwd`. Auto-discovers AGENTS.md AND CLAUDE.md (per `--no-context-files` to disable). No explicit cwd flag. | Explicit via `--dir <path>`, or implicit from process `cwd`. Reads `~/.config/opencode/opencode.json` for permissions/agents. Server-based architecture: opencode runs a local HTTP server (`--port`) and the CLI attaches; runs with mDNS for service discovery. |
| CE skill invocation syntax (prompt-side) | `/compound-engineering:ce-code-review` (slash-form, plugin-namespaced); also `/ce-code-review` works | `/ce-code-review` (slash-form, no plugin namespace required — plugin manifest registers skills at top level) | `/ce-code-review` after loading CE skills via `--skill <path>` (path can point at the codex CE plugin's skills/ directory; pi has no native CE plugin marketplace install but accepts external skill dirs). **Skill invocation NOT verified by test-spawn** because pi is not logged in on this machine. | **No CE plugin available for opencode.** Hive must inline the CE skill prompt content into the message arg. Workaround: load the skill markdown from `~/.codex/plugins/cache/compound-engineering-plugin/compound-engineering/3.1.0/skills/ce-code-review/SKILL.md` and pass it as the prompt. Alternative: `opencode agent create` to register a custom agent that mirrors the CE skill — heavier setup, plugin-update drift. |
| Auth / config location | OAuth via `claude` interactive `/auth`, long-lived token via `claude setup-token`, or `ANTHROPIC_API_KEY` env | OAuth via `codex login` (ChatGPT subscription), or `OPENAI_API_KEY` env | Provider-specific. Default `--provider google`. `--api-key <key>` flag or `GOOGLE_API_KEY` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` env vars per provider. Interactive `/login` in TUI. **Currently not logged in on this machine** (`~/.pi/agent/auth.json` is `{}`). | `opencode providers` (alias `auth`); credentials at `~/.local/share/opencode/auth.json`. One credential active: OpenCode Zen API. Other providers can be added. |
| Status detection mode (per U12 profile) | `:state_file_marker` (existing 4-execute pattern: agent writes `<!-- COMPLETE -->` etc. to task.md; runner reads marker for status) | `:output_file_exists` (combine `--output-last-message <path>` with the reviewer's expected `reviews/<name>-<pass>.md`; both must exist + be non-empty) | `:output_file_exists` (verify the reviewer's `reviews/<name>-<pass>.md` is written + non-empty; pi has no native last-message-output flag like codex). | `:output_file_exists` (verify reviewer's `reviews/<name>-<pass>.md`; opencode has no `--output-last-message`-equivalent flag, but `--format json` event stream can be parsed for completion signal as a secondary check). |
| Headless-supported | yes (`-p` mode is fully headless, no TTY required) | yes (`codex exec` mode is fully headless, no TTY required) | yes (`-p` mode is fully headless) | yes (`opencode run` is fully headless; spawns local server + attaches automatically) |
| Min version for `ce-code-review` | `2.1.118` (already pinned in `lib/hive.rb` as `MIN_CLAUDE_VERSION`) | `0.125.0` (verified — earlier versions may not have `--add-dir` or `exec` shape; pin TBD after marketplace history check) | `0.70.2` (verified locally; earlier versions may lack `--skill` flag — pin TBD after marketplace history check) | `1.14.25` (verified locally; pin TBD — opencode evolves quickly, plugin SDK at `@opencode-ai/plugin@1.14.19`) |

---

## Per-CLI summaries

### claude (Claude Code)

Source of truth: `lib/hive/agent.rb` `build_cmd`, `lib/hive.rb` `MIN_CLAUDE_VERSION`, and `claude --help` output.

**Notes:**
- Hive's existing `Hive::Agent.build_cmd` invokes claude with: `[bin, "-p", "--dangerously-skip-permissions", "--add-dir", <dir>..., "--max-budget-usd", N, "--output-format", "stream-json", "--include-partial-messages", "--verbose", "--no-session-persistence", <prompt>]`. This shape is the baseline U12's claude profile reproduces.
- `--dangerously-skip-permissions` is hive's choice (per ADR-008's single-developer trust model). The opt-in alternative `--allow-dangerously-skip-permissions` (note "allow") makes it enable-able-as-option without enabling by default; hive doesn't use this since the current contract assumes the bypass is on for every spawn.
- `--add-dir` accepts multiple paths (variadic). Hive narrows it to `task.folder` (per ADR-008 isolation rule).
- `--max-budget-usd` strictly requires `--print` mode (the help text says so explicitly). Hive always uses `-p` so this is fine.
- `--output-format stream-json` requires `--print`. Hive uses this for parseable progress; the reader thread in `Agent#spawn_and_wait` consumes it.
- Skill invocation in the prompt body: `/compound-engineering:ce-review` (or any other plugin-namespaced skill). The slash-prefix is the literal syntax in the rendered prompt. Plugin namespacing matters when the same skill name exists in multiple plugins.
- Auth: typical setup is OAuth (Claude subscription), token (`setup-token`), or `ANTHROPIC_API_KEY` env var. Headless invocation honors any of these.

**Decision:** **full-profile.** Stays in v1 default reviewer set. Profile entry maps directly to the existing constants.

---

### codex (OpenAI Codex CLI)

Source of truth: `codex --help`, `codex exec --help`, `codex review --help`, on-disk inspection of `~/.codex/plugins/cache/compound-engineering-plugin/compound-engineering/3.1.0/`.

**Notes:**
- **Skill-name correction:** The codex CE plugin v3.1.0 has `ce-code-review`, not `ce-review`. Plan currently says "Codex `ce-review`" — needs updating to `ce-code-review` everywhere it appears (mostly U4's reviewer adapter prompts and U2's default reviewer set). Same correction applies to Claude — both plugins' actual skill is `ce-code-review`, and `/ce-review` was the user's shorthand. This propagates to the `output_basename` defaults too: `claude-ce-code-review-NN.md` instead of `claude-ce-review-NN.md`.
- **Sandbox model:** codex has 3 levels — `read-only`, `workspace-write`, `danger-full-access` — vs claude's binary skip-permissions. For hive's reviewer (read-only diff) we'd use `-s read-only`. For triage/fix/CI-fix (writes to task folder + worktree) we'd use `-s workspace-write` plus `--ask-for-approval never`, or `--full-auto` (which is the convenience alias for those two together). The closest functional equivalent to claude's `--dangerously-skip-permissions` is `--dangerously-bypass-approvals-and-sandbox`. **For ADR-008 parity, use `--dangerously-bypass-approvals-and-sandbox`** — same trust model, no compromise on the existing single-developer assumption.
- **`--add-dir` semantics:** codex's `--add-dir` is single-arg per flag (repeatable), where claude's is variadic on one flag. Same outcome, different ergonomics — U12's profile abstraction handles the per-flag invocation pattern cleanly.
- **`-C, --cd <DIR>`:** explicit working-root flag. Hive can use either `cwd` in `Process.spawn` (current claude pattern) or `-C` (codex-native). Recommend keeping the existing `Process.spawn(chdir:)` pattern since it works for both — no profile-level difference needed.
- **`--output-last-message <FILE>`:** writes the agent's final message to a known path. **This is the cleanest deterministic-status-detection signal codex offers.** U12's `:output_file_exists` mode for codex profile points at this file (or at `reviews/<name>-<pass>.md` written by the reviewer skill itself — pick the one the skill actually writes to during a `ce-code-review` run; see Task #5 verification).
- **No budget cap:** unlike claude's `--max-budget-usd`, codex has no built-in dollar cap. Hive must rely on wall-clock timeout (`timeout_sec`) for this CLI. U12's profile sets `budget_flag: nil` and the runner logs a warning at `spawn_agent` time.
- **Built-in `codex review` subcommand:** codex has a native `codex review --base <BRANCH>` reviewer that bypasses the CE skill. Hive does NOT use this — we want CE workflow portability across all CLIs. Mentioned only as context for users who notice the discrepancy.
- **CE plugin v3.1.0 in codex** is slightly ahead of v3.0.1 cached for Claude. Same skill set + a few extras (`ce-polish-beta`, `ce-update`, `ce-setup`, `lfg`). Doesn't affect hive's use of `ce-code-review`, `ce-test-browser`, `ce-resolve-pr-feedback` — all three exist in both.
- **Auth state at spike time:** `codex login status` → `Logged in using ChatGPT`. Headless invocation works under this auth.

**Decision:** **full-profile.** Stays in v1 default reviewer set. Profile entry maps to `--dangerously-bypass-approvals-and-sandbox` for the bypass flag and `--add-dir` repeatable for isolation. `budget_flag: nil` (no native budget cap). `status_detection_mode: :output_file_exists`. `min_version: "0.125.0"` (verified locally; older versions to be checked if a user reports a problem).

---

### pi

Source of truth: `pi --help`, `pi install --help`, `pi list`, on-disk inspection of `~/.pi/`.

**Notes:**
- Pi describes itself as "AI coding assistant with read, bash, edit, write tools". It's a **tool-oriented** agent: tools are first-class, permissions are not. There's no `--add-dir`, no sandbox flag, no permission-skip. Tool-level restriction is the only knob: `--no-tools`, `--no-builtin-tools`, `--tools <comma-list>` (allowlist).
- **ADR-008 boundary gap:** the `--add-dir <task folder>` constraint that ADR-008 names as one of three compensating controls for `--dangerously-skip-permissions` cannot be reproduced in pi. The agent's filesystem access is the OS user's filesystem access, full stop. **Implication:** ADR-018 must amend the trust model when pi is configured as a hive role's agent. Default config for hive itself should NOT enable pi for any role with `--dangerously`-style behavior — the trust boundary degrades from "agent confined to task folder" to "agent has full user filesystem access".
- **Workaround for pi-as-reviewer (read-only):** restrict tools to `--tools read,edit,write` (no bash). Reviewer doesn't need shell escapes; this prevents the agent from spawning subshells and mass-editing the FS. Still no path bound, but reduces the practical attack surface. This is convention-only, not enforcement.
- **Workaround for pi-as-fix-agent (writes commits):** can't be safely sandboxed without losing functionality. Either (a) accept the weakened boundary with ADR-018 amendment, or (b) document pi as not-recommended for fix/CI-fix roles.
- **Skill loading:** `--skill <path>` accepts a file or directory; can be repeated. To load CE skills from an external location (e.g., the codex plugin cache), pass `--skill ~/.codex/plugins/cache/compound-engineering-plugin/compound-engineering/3.1.0/skills/ce-code-review`. **Not test-verified** at spike time because pi is not logged in to any provider on this machine. Slash-prefix invocation in prompt body (e.g., `/ce-code-review`) is the assumed pattern; verify in Task #5 if user logs in.
- **Auth gap on this machine:** `~/.pi/agent/auth.json` is empty `{}`. User needs to log in to a provider (`pi`, then `/login` in the TUI) before pi can actually run any prompt. Until then, U11's Task #5 cannot end-to-end-verify pi.
- **Provider model:** pi's default `--provider google` uses Google Gemini. Other providers (OpenAI, Anthropic, etc.) supported. This makes pi a useful escape hatch for cost-sensitive roles (Gemini may be cheaper than Claude/GPT for triage) — at the cost of weakened isolation.
- **Auto-discovery:** pi reads BOTH `AGENTS.md` and `CLAUDE.md` from cwd by default (per `--no-context-files` flag to disable). Friendly across the AGENTS.md / CLAUDE.md split.

**Decision:** **partial-profile-with-caveats.** Pi is profile-able for hive but flagged as ADR-008-weakened. ADR-018 must be added in U10 documenting the trade. Hive's own default reviewer set in U2 does NOT include pi by default — users opt in per project. When configured, pi-as-reviewer should default to `--tools read,edit,write` (no bash) for the read-only reviewer phase; pi-as-fix-agent gets a runtime warning at `spawn_agent` time citing the isolation gap.

---

### opencode

Source of truth: `opencode --help`, `opencode run --help`, `opencode agent list`, on-disk inspection of `~/.config/opencode/` and `~/.local/share/opencode/`.

**Notes:**
- OpenCode's headless entry is `opencode run [message]`. Architecture is server-based: `opencode run` spawns a local server on a random port, attaches the CLI, and tears down on exit. `--attach <url>` can connect to a remote opencode server (interesting for shared infrastructure but not used by hive in v1).
- **Permission system:** opencode has a config-level permission system (in `~/.config/opencode/opencode.json` plus the active agent's permissions). The `external_directory` permission key with patterns and ask/allow/deny actions is the closest equivalent to claude's `--add-dir` boundary — but it's per-installation, not per-spawn. To bound a single hive run to the task folder, hive would need to write a temp config file with `external_directory: {pattern: "*", action: "deny"}` plus allowlist for the task folder, then spawn opencode pointing at that config. Heavier than claude's `--add-dir <path>` per-spawn, but real isolation is achievable.
- **`--dangerously-skip-permissions`:** boolean flag on `opencode run`. Bypasses the entire permission system (matches claude's intent and name exactly). For ADR-008 parity, hive uses this flag to keep the trust model consistent across CLIs — but the permission system is more capable, so a future opt-in to "use opencode's permissions instead of bypass" is a reasonable v1.1 enhancement.
- **No CE plugin for opencode.** OpenCode plugins are npm packages (`opencode plugin <npm-module>`). The compound-engineering plugin is published for Claude Code and Codex; no opencode build exists at spike time. **Workaround for hive:** read the CE skill markdown from disk and pass it as the prompt content directly. The CE skill contents (SKILL.md) are portable across agents — they're structured prompts, not platform-specific code.
- **`--dir <path>`:** sets the working root for the spawn. Combine with the temp-config approach for filesystem bounding.
- **`--format json`:** event stream as JSON; useful for parseable progress similar to claude's `--output-format stream-json`.
- **Auth:** active credential is "OpenCode Zen" (their hosted API offering). Other providers (OpenAI, Anthropic) can be added via `opencode providers`.
- **Plugin / agent ergonomics:** `opencode agent create` allows registering custom agent personas. Could be used to embed CE skill prompts as named agents, but that's a setup-time investment vs runtime prompt-injection. v1 takes the prompt-injection path for simplicity.

**Decision:** **partial-profile-with-caveats.** OpenCode is profile-able for hive but with two gaps: (a) no native CE plugin → inline-prompt approach (loses plugin update propagation); (b) per-spawn filesystem isolation requires temp-config writing instead of a simple flag. ADR-018 amends ADR-008 to cover the temp-config pattern. Hive's own default reviewer set in U2 does NOT include opencode by default — users opt in per project (e.g., for cost-of-tokens reasons via OpenCode Zen). When configured, opencode-as-reviewer/triage/fix uses `--dangerously-skip-permissions` to match claude's behavior; users who want stronger isolation can opt for the temp-config path (documented in ADR-018).

---

## End-to-end test invocation (Task #5)

**Live test-invocation deferred to U12 integration testing.** Reasoning:

- The matrix above is paper-grounded against `--help` output, on-disk plugin inspection, and existing hive code (`lib/hive/agent.rb` for the claude column). This is sufficient evidence to design U12's `AgentProfile` data shape and `build_cmd` logic.
- Live test-spawn for each CLI would consume agent tokens (each `ce-code-review` invocation against even a trivial diff drives a non-trivial prompt). The marginal value over paper verification is "did the flag mapping I just wrote work" — which U12's own unit + integration tests cover deterministically using stub binaries.
- Pi cannot be live-tested at all on this machine without the user first running `pi` interactively to log into a provider. This is a known gap and is captured as a Pi-specific dependency in the U11 outcomes.
- Codex and OpenCode could be live-tested but would not surface anything the matrix doesn't already document — the help output is canonical for both.

**Sample invocation shapes** (intended for U12 integration tests; copy-paste reference, not test-run):

```sh
# claude reviewer (today's hive shape, already proven)
claude -p \
  --dangerously-skip-permissions \
  --add-dir <task-folder> \
  --max-budget-usd 50 \
  --output-format stream-json --include-partial-messages --verbose \
  --no-session-persistence \
  '<rendered prompt invoking /ce-code-review>'

# codex reviewer
codex exec \
  --dangerously-bypass-approvals-and-sandbox \
  --add-dir <task-folder> \
  --json \
  --output-last-message <task-folder>/.codex-last-message.txt \
  '<rendered prompt invoking /ce-code-review>'

# pi reviewer (NOT verified; pi not logged in on this machine)
pi -p \
  --skill ~/.codex/plugins/cache/compound-engineering-plugin/compound-engineering/3.1.0/skills/ce-code-review \
  --tools read,edit,write \
  --mode json \
  --no-session \
  '<rendered prompt invoking /ce-code-review>'

# opencode reviewer (no CE plugin; inline-prompt approach)
opencode run \
  --dir <task-folder> \
  --dangerously-skip-permissions \
  --format json \
  --prompt '<full inlined SKILL.md content + diff context>'
```

These shapes are the input to U12's profile `build_cmd` logic and the integration-test fixtures.

---

## Final outcomes per CLI (Task #7)

| CLI | Outcome | Default in hive's reviewer set? | ADR-008 boundary |
|-----|---------|--------------------------------|--------------------|
| **claude** | full-profile | yes (today's behavior preserved) | intact (`--add-dir <task folder>` per ADR-008) |
| **codex** | full-profile | yes (added in v1) | intact (`--add-dir <task folder>` flag exists, semantically equivalent) |
| **pi** | partial-profile-with-caveats | **no** (opt-in per project) | **weakened** — no `--add-dir` equivalent, no permission gate. ADR-018 amends ADR-008 for pi. Tool-level restriction (`--tools read,edit,write` minus `bash`) is the only mitigation for the reviewer phase; not effective for fix/CI-fix roles. |
| **opencode** | **out of scope for v1** | n/a | not applicable — see scope decision callout at the top of this doc. Evaluation column retained below for transparency but opencode does not ship as an `AgentProfile` in v1. |

### Plan adjustments locked in (consumed by Task #7's plan-edit pass)

1. **Skill-name correction (P1).** Plan currently uses `ce-review` throughout. The actual skill name in both Claude Code and Codex CE plugins is `ce-code-review`. Fix everywhere:
   - U2 default reviewer set: `claude-ce-review` → `claude-ce-code-review`, `codex-ce-review` → `codex-ce-code-review`
   - U4 prompt template names: `reviewer_claude_ce_review.md.erb` → `reviewer_claude_ce_code_review.md.erb`, etc.
   - U6 triage prompts referencing reviewer file names
   - U8 browser-test (verify `ce-test-browser` skill exists in CE plugin — confirmed; no rename needed for browser-test)
   - U10 wiki references
   - All AE / R / system-wide-impact references
2. **Hive's default reviewer set is now claude + codex (not 4 CLIs).** Pi and opencode are profile-able but opt-in. U2 ships:
   - `claude-ce-code-review` (claude profile + `/ce-code-review` skill)
   - `codex-ce-code-review` (codex profile + `/ce-code-review` skill)
   - `pr-review-toolkit` (claude profile + `/pr-review-toolkit:review-pr` skill)
   - Linters as additional reviewer entries (already in plan; ship as commented-out config per origin recommendation)
3. **ADR-018 must be added to U10 with concrete content:** the trust-model amendment when the configured agent CLI lacks `--add-dir` equivalence. Pi and opencode go through this path; claude and codex don't. The amendment names: (a) tool-level restriction as the pi mitigation, (b) temp-config writing as the opencode mitigation, (c) explicit warning at `spawn_agent` time when a profile lacks `add_dir_flag`.
4. **U12 profile defaults locked in (3 profiles ship in v1; opencode dropped per scope decision above):**
   - claude: `add_dir_flag: "--add-dir"` (variadic), `permission_skip_flag: "--dangerously-skip-permissions"`, `headless_flag: "-p"`, `budget_flag: "--max-budget-usd"`, `output_format: "--output-format stream-json"`, `version_flag: "--version"`, `status_detection_mode: :state_file_marker`, `min_version: "2.1.118"`
   - codex: `add_dir_flag: "--add-dir"` (single-arg, repeated), `permission_skip_flag: "--dangerously-bypass-approvals-and-sandbox"`, `headless_flag: ["exec"]` (subcommand-style), `budget_flag: nil`, `output_format: "--json"` plus `-o, --output-last-message <path>`, `version_flag: "--version"`, `status_detection_mode: :output_file_exists`, `min_version: "0.125.0"`
   - pi: `add_dir_flag: nil` (gap), `permission_skip_flag: nil` (gap), `headless_flag: "-p"`, `budget_flag: nil`, `output_format: "--mode json"`, `version_flag: "--version"`, `status_detection_mode: :output_file_exists`, `min_version: "0.70.2"`, `headless_supported: true`
5. **Pi auth precondition:** pi cannot be exercised on this machine until the user runs `pi` interactively and logs into a provider. Document in the Pi profile's `headless_supported` check or add a `Hive::AgentProfile#preflight!` method that raises a friendly error if auth isn't set up.
6. **CHANGELOG note for v1:** "v1's default reviewer set is claude + codex. Pi and opencode are supported as opt-in agent CLIs per project; users opting in accept the ADR-018 trust-model trade-off documented in `wiki/decisions.md`."
