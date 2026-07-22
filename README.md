<p align="center">
  <img src="docs/assets/logo.svg" alt="Hive" width="96" height="96">
</p>

# Hive

**Website &amp; docs: [hivecli.sh](https://hivecli.sh)** — quickstart, concepts, the full command reference, and an [`llms.txt`](https://hivecli.sh/llms.txt) for agents.

Community: [join the Hive Discord](https://discord.gg/Qg5E7rMt) for questions,
feedback, and release discussions.

Hive is a durable, local-first workflow engine for AI agents. It orchestrates Claude, Codex, Grok, and Pi to run multi-step work as a *folder-as-agent pipeline*. Its flagship **`coding`** workflow turns a rough software idea into a merge-ready pull request: you sketch an idea in a few sentences, open the `hive tui` dashboard or native local web UI, and watch the work move forward — brainstorm pins down what you actually want, plan fixes the approach, execute writes the code, review hardens it, and finalize ships the PR. You can step in at any stage with a normal editor — every artefact is a markdown file in a stage folder, inspectable and editable by you or by another agent. Software delivery is the flagship proof, not the product boundary: Hive also ships `content` and `bench` workflows, installs reviewed Honeycombs, and runs the ones you author yourself for writing, research, triage, audits, and operations (see [Custom Workflows](#custom-workflows)).

The mental model is folders. Every task is a directory; the folder's location is the task state. Moving a task from `2-brainstorm/` to `3-plan/` is the approval gesture, and every stage writes a durable artefact the next stage can trust. That practice — making each step's output strong enough for the next one to run autonomously — is called *compound engineering*. It's how Hive carries work from rough idea to merged PR while letting humans drop in on their own terms instead of a chat thread's.

The `coding` workflow runs nine stages, each a folder:

```text
1-inbox  ->  2-brainstorm  ->  3-plan  ->  4-execute  ->  5-open-pr  ->  6-review  ->  7-artifacts  ->  8-finalize  ->  9-done
capture       refine           design      build          draft PR       harden        collect        publish         archive
```

Read the model in depth in [docs/concepts.md](docs/concepts.md) — folder-as-agent, the marker protocol that lets stages negotiate handoff, the nine stages in detail, and the trade-offs that come with making everything a file.

## Demo

A sub-two-minute reel of the whole loop — install, `hive init`, capture an idea in the TUI, answer brainstorm questions in vim, and archive the finished task once Hive has shipped it:

![Hive demo](docs/assets/hive-demo.webp)

Full-quality MP4 (~4&nbsp;MB): [docs/assets/hive-demo.mp4](docs/assets/hive-demo.mp4).

The result Hive built in that reel lives at [ivankuznetsov/shipped](https://github.com/ivankuznetsov/shipped) — a real public repo seeded with a one-sentence idea ("a Telegram bot that sends a daily digest of what was shipped"), driven through brainstorm → plan → execute → multi-agent review → finalize, and landed as [PR #1](https://github.com/ivankuznetsov/shipped/pull/1).

> [!IMPORTANT]
> **Hive is a token-heavy workflow.** You can customize it, but by default it runs a lot of subagents and several different coding agents, and it burns through a LOT of tokens. I strongly recommend a **Claude Max** subscription plus **ChatGPT Pro** for Codex to run it properly — the best results come from the top-tier subscriptions. If you're really tight on budget, you might try the **Pi** agent with the latest **Kimi** model for some parts of the workflow, though the Pi integration is not yet properly tested or performance-evaluated.

## Install

Hive ships as a rubygem (`hive-cli`) plus a managed Hive web bundle attached to each GitHub Release. A cosign-signed checksum manifest authenticates both artifacts before installation or extraction. Each native channel installs the same gem; the normal `hive setup` then installs Hive-owned dependencies, the daemon, and the managed loopback web service. Project initialization still controls daemon enrollment independently.

| Platform | Channel |
|----------|---------|
| macOS arm64 | [`brew install ivankuznetsov/hive/hive`](https://github.com/ivankuznetsov/homebrew-hive) |
| Ubuntu 22.04+ / glibc Linux x86_64/aarch64 | <code>tmpdir="$(mktemp -d)" && trap 'rm -rf "$tmpdir"' EXIT && curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.6.5/install.sh -o "$tmpdir/hive-install.sh" && bash "$tmpdir/hive-install.sh"</code> |
| Arch Linux x86_64/aarch64 | [`yay -S hive-bin`](https://aur.archlinux.org/packages/hive-bin) |

Prerequisites: **Ruby 3.4** (the gem and its runtime deps install against this), git ≥ 2.40, authenticated `claude` ≥ 2.1.118, `codex` ≥ 0.125.0 for the default execute agent, `grok` ≥ 0.2.90 when selected, authenticated `gh`, `tmux` ≥ 3.0 when the project uses the default `claude.mode: tmux`, `cosign` for release identity verification, and Node.js/npm for managed QMD install/repair. The bash installer reports its own installer-side prereqs (`curl`, `jq`, `cosign`, `gem`, checksum tool) on first run; if npm is missing, Hive still installs and `hive doctor` reports the QMD gap non-fatally.

The vendored gems land under `${XDG_DATA_HOME:-~/.local/share}/hive/gems/` so the install is self-contained and uninstall is a clean `rm -rf`. Full install matrix, XDG paths, Apache Hive collision behavior (`hv` shim), update, uninstall, and autostart details live in [wiki/operating.md#install](wiki/operating.md#install) and [wiki/operating.md#autostart](wiki/operating.md#autostart).

### From a development clone

If you're hacking on Hive itself, install from a clone instead:

```bash
git clone https://github.com/ivankuznetsov/hive ~/Dev/hive
cd ~/Dev/hive
bundle install
mkdir -p ~/.local/bin
ln -sf ~/Dev/hive/bin/hive ~/.local/bin/hive
```

If `~/.local/bin` is not on `PATH`, put the symlink in a directory that is. Verify with `hive --version`, then run `hive setup`. A source checkout is the explicit development input and does not download a release bundle; setup still uses the same systemd-user or launchd installers.

### Hive web (default native experience)

On supported Linux and macOS installations, the normal first run is:

```bash
hive setup
```

`hive setup` checks Ruby 3.4, git, tmux, `gh`, Claude, Codex, Node/npm,
QMD, SQLite, and the Rails bundle. Before other mutations it previews and
provisions Hive's operating skill for Claude, Codex, and Pi. It then installs
the Hive-owned pieces it can manage, installs the daemon and Hive web services,
enrolls the current project, and reports the effective URL plus installed,
enabled, running, and readiness state. Interactive setup confirms once; JSON
or non-TTY setup must pass `--yes` or it makes no changes. The untouched
configuration is loopback-only at `http://127.0.0.1:4567`; setup never creates
LAN/public binding or Tailscale exposure. Use `hive setup --no-service` to skip
every web-service mutation, or bare `hive web` to bootstrap as needed and serve
in the foreground. Explicit repair remains `hive web install --force`.

Bare `hive web` uses loopback-only no-auth mode over the same local project
registry and workflow state as the TUI. GitHub is an optional connection for
repository browsing and cloning, not a prerequisite or ownership claim. A
local reverse proxy such as Tailscale Serve remains part of the access boundary
because Hive sees its loopback connection; authenticate and restrict its
clients, and never expose an unrestricted forwarder. Set
`web.local_loopback: false` to require GitHub login even there. See
[wiki/commands/web.md](wiki/commands/web.md).

Windows users should run the native path inside WSL with systemd enabled, or
use Hivebox. **Choose [Hivebox](packaging/docker/README.md) when you need
container isolation, multiple local instances, containment for untrusted
agents, or a reproducible server/NAS deployment.** Hivebox remains fully
supported; it is the container distribution of the same Rails app.

### Install via a coding agent

To have Claude Code, Codex, or another agent CLI install Hive for you (with OS detection, channel selection, Apache Hive collision handling, and `hive init` follow-up), paste the prompt at [install.md](install.md) into the agent. It's the canonical source for agent-driven install — keep it pinned in your agent's context if you reinstall often.

## Works with OpenClaw.ai

Hive publishes one OpenClaw skill through ClawHub:

```bash
openclaw skills install @ivankuznetsov/hive-cli
```

Public listing: <https://clawhub.ai/ivankuznetsov/skills/hive-cli>.

That listing installs the `/hive` slash command. Ask OpenClaw to run the guided
setup:

```text
/hive setup
```

The guided setup keeps package-manager confirmation visible, verifies
`hive`/`hv`, and—after approval—runs
`hive setup --no-init --yes --json` for core provisioning. The result reports
the effective native Hive web URL and distinct installed, enabled, running, and
readiness state alongside the daemon outcome. Project enrollment is a separate
`hive init .` in the user's real terminal so patrol, architecture, daemon, and
babysitter defaults can be reviewed before confirmation. After setup, pass Hive
CLI commands through `/hive ...`, for example
`/hive status --operational --json`, `/hive watch <project>:<task>`,
`/hive new . "build this feature"`, and `/hive review <task-slug>`.

For local checkout testing, run `openclaw skills install ./openclaw/skills/hive
--as hive`. See [openclaw/README.md](openclaw/README.md) for the publish
checklist and the reason the ClawHub slug is `hive-cli` while the slash command
is `/hive`.

## Five-Minute TUI Getting Started

The normal Hive loop is simple: the daemon advances ready tasks, and the TUI is where you watch the queue and answer only when Hive needs human input. You do not need to learn the stage commands on day one.

1. Attach Hive to a real project.

   ```bash
   cd ~/Dev/your-project
   hive init .
   ```

   Interactive init offers to provision any unresolved built-in agent skills,
   including Hive's own operating skill. The same skill has native invocation
   `/hive` in Claude, `$hive` in Codex, and `/skill:hive` in Pi.
   You can also inspect and provision them explicitly:

   ```bash
   hive doctor
   hive setup-agents          # preview, then confirm once
   ```

   For unattended setup use `hive setup-agents --yes`; add `--json` for the
   versioned automation envelope. Without `--yes`, JSON/non-TTY setup returns
   a typed refusal before diagnostics or native agent discovery, so even an
   upstream CLI's nominally read-only bootstrap cannot alter the user's home.
   Doctor is always read-only and derives agent/ClawHub health from durable
   filesystem evidence without launching Claude, Codex, Pi, or OpenClaw.

   During `hive init`, choose the Claude launch mode and permission mode for the project. `tmux` is the default: Claude-backed stages run in attachable tmux sessions using your logged-in Claude session. With the upcoming Anthropic pricing changes this is the mode we now suggest for most users, but treat it as an **experimental workflow** for now — expect some rough edges. The recommended permission default is `bypassPermissions` so local dogfood runs do not pause on file-operation approvals; choose `auto` when you want Claude Code auto-mode rules. Pick `headless` for service-only hosts or CI-style runs that should use normal non-interactive CLI spawns.

   When `hive init` asks about the daemon, keep the project enabled. The service itself is already global autostart infrastructure; this prompt only controls whether this project is picked up. The daemon is the worker: it polls Hive, starts the next stage when a task is ready, and stops at human-input or recovery gates.

2. Open the dashboard.

   ```bash
   hive daemon status            # should say running
   hive tui
   ```

   If the daemon is not running yet, run `hive daemon install` to repair autostart, or start it once with `hive daemon start --detach` while you troubleshoot. The left pane is your registered projects; the right pane is the live queue.

3. Capture one rough idea.

   Press `n`, choose the project if Hive asks, type the thing you want built or investigated, and press `Enter`. The new row starts in `1-inbox`, backed by an `idea.md` file under `.hive-state/`.

4. Watch Hive move it forward.

   Leave the TUI open. The daemon picks up the new row, turns the idea into `brainstorm.md`, promotes completed work into `plan.md`, and keeps moving through the pipeline while each stage is ready. Long stages show as running; completed stages leave files behind for the next stage and for you.

5. Answer only when Hive asks.

   When a row says it needs input, highlight it and press `Enter`. Hive opens the right markdown file in your editor. Fill the answer blocks, save, and close the editor. The daemon sees the edit, waits for the file to settle, and continues the task automatically.

That is enough to understand what Hive does: it turns a rough idea into durable stage files, then keeps advancing the same task toward code, a pull request, review, and archive. Manual TUI keys still exist for power users who want to steer a specific stage themselves; the happy path is daemon-first. See [wiki/commands/tui.md](wiki/commands/tui.md) for the full dashboard reference.

## Digest Reports

`hive digest` sends the daily shipped-task digest for the local day that just ended. It scans completed `9-done` tasks, uses the configured digest agent for summaries when there is work to report, and delivers through Telegram.

For a read-only GitHub report of pull requests merged on a local day, use:

```bash
hive digest --source merged-prs --dry-run
hive digest --source merged-prs --date 2026-06-13 --repo owner/name --json
```

The merged-PR source never mutates Hive state and does not run an LLM; it groups merged PRs by repo with mechanical MarkdownV2 output. See [wiki/commands/digest.md](wiki/commands/digest.md) for the full contract and JSON schema details.

## Manage Hive From Telegram in 2 Minutes

Hive can notify you, show the queue, and accept approvals from Telegram. It uses long polling, so there is no webhook, public URL, or tunnel to configure.

1. Create a bot with `@BotFather`.

   Send `/newbot`, choose a display name, then choose a username ending in `bot`. BotFather gives you a token like `123456789:ABCdef...`. Keep it secret.

2. Message your bot once.

   Open the new bot chat and send `/start` or `hi`. Telegram only exposes your chat id after you have messaged the bot.

3. Get your numeric chat id.

   ```bash
   export HIVE_TELEGRAM_BOT_TOKEN='paste-token-from-botfather'

   curl -s "https://api.telegram.org/bot${HIVE_TELEGRAM_BOT_TOKEN}/getUpdates" |
     ruby -rjson -e 'data = JSON.parse(STDIN.read); ids = data.fetch("result", []).filter_map { |u| (u["message"] || u["edited_message"] || u.dig("callback_query", "message"))&.dig("chat", "id") }; abort("No chat id yet: send your bot a fresh message and retry") if ids.empty?; puts ids.last'
   ```

   Use this number, not your `@username`.

4. Allow that chat in Hive.

   Add the bot block to `~/.config/hive/config.yml`, preserving any existing `registered_projects:` entries:

   ```yaml
   bot:
     enabled: true
     chat_id_allowlist:
       - 123456789
   ```

5. Start Hive bot.

   ```bash
   hive bot start
   hive bot status --json
   ```

Now send `/help`, `/status`, or `/queue` in Telegram. Useful local commands:

```bash
hive bot tail        # follow ~/.local/state/hive/logs/bot.log
hive bot reload      # pick up allowlist/config changes
hive bot stop        # stop the background bot
```

If the bot stays silent, check `hive bot tail`, confirm the allowlist contains the numeric chat id, and send a fresh Telegram message before rerunning `getUpdates`. A Telegram `404 Not Found` usually means the token is missing or mistyped. If a token leaks, rotate it in `@BotFather` with `/revoke` and restart `hive bot`.

Voice-note idea capture also needs an OpenAI-compatible transcription key. Put it in the same env file as the Telegram token, for example `HIVE_WHISPER_API_KEY=...`; the key is read from the environment and is never written into Hive config.

## Drive Hive From Your Coding Agent

Hive's other primary surface is a coding agent — Claude Code, Codex, Grok, Gemini, Pi, or anything that can read terminal output and run shell commands. You describe intent in natural language ("brainstorm the bookmark service idea", "run review on the failing task and report the findings"), the agent translates that into `hive <verb>` calls, and you watch the result in the TUI or read the markdown artefacts directly. `hive status --operational --json` is the agent-first status contract; it reports one closed state per active task, exact blocker ownership and reasons, scheduler freshness, and safe tokenized routine actions. Stage-driving workflow verbs support `--json` and emit typed envelopes (schemas under [schemas/](schemas/), contract in [docs/cli.md#json-output](docs/cli.md#json-output)), so agent-side parsing is structured rather than scraped. `hive new` is the capture exception: it still prints prose, so agents should read the printed task path/slug instead of JSON-parsing it.

Useful prompt shapes once Hive is installed:

- *Capture an idea:* `Run hive new your-project "<title>" and report the slug it printed.`
- *Triage what's waiting:* `Run hive status --operational --json and report the state, blocker_owner, reason, and freshness for every non-idle task.`
- *Drive a task through one stage:* `Run hive review <slug> --json and summarize the resulting envelope, including any waiting markers.`
- *Watch a long-running task:* `Run hive watch <project>:<slug> --json-lines and stop on its final event.`
- *Take a safe next step:* `Read a fresh operational action descriptor, then run hive act <action_id> <target> --observation <token> --json.`

For commands that emit JSON, the schema is versioned under [schemas/](schemas/), so agent prompts can rely on field shapes without scraping. `hive status --json` deliberately remains the complete compatibility graph for daemon/bot/TUI consumers; agents should prefer the additive operational view. `hive watch` is a stream and therefore uses `--json-lines`, not the global `--json` document mode. `hive tui` remains human-only. For installation via an agent, point it at [install.md](install.md).

## Custom Workflows

Hive ships three workflows out of the box — `coding` (the nine-stage idea → PR pipeline), `content`, and `bench` — but the engine underneath is generic. Selecting `bench` installs a versioned harness snapshot into the project state, so running a campaign does not require a separate [hive-bench](https://github.com/ivankuznetsov/hive-bench) checkout:

```bash
hive init /path/to/benchmark-project --workflow bench
hive new benchmark-project "benchmark campaign"
```

A workflow is just an **ordered list of stages in a YAML descriptor**, so you can author your own per project: writing, research, triage, translation, a weekly-report generator — any task that moves through a sequence of steps where an AI agent does the work at each one. You describe the stages; the daemon runs the pipeline.

Architecture, Writing, and SEO Content ship as full reviewed Honeycomb workflows. Installation chooses an agent for every stage/reviewer slot, suggests runnable defaults from `hive init`, and keeps those choices in project configuration rather than the package:

```bash
hive workflow install honeycomb/architecture --yes
hive workflow install honeycomb/writing --yes
hive workflow install honeycomb/seo-content --yes --allow-escalation
```

Scaffold one from a sample and run it:

```bash
# Bootstrap a project bound to a new owner-authored workflow.
hive init --new-workflow weekly-report ~/Dev/reports
cd ~/Dev/reports

# Edit the descriptor and stage instruction, then drop in an idea.
hive new reports "summarize this week's shipped work"
hive status
```

A descriptor is short enough to read top to bottom — an entry gate, agent stages that each do one job, an exit gate:

```yaml
id: "writing"
stages:
  - { name: inbox,    kind: terminal, state_file: idea.md }
  - { name: research, kind: agent,    state_file: research.md, instruction: ./writing/research.md }
  - { name: draft,    kind: agent,    state_file: draft.md,    instruction: ./writing/draft.md }
  - { name: edit,     kind: agent,    state_file: edit.md,     instruction: ./writing/edit.md }
  - { name: done,     kind: terminal, state_file: done.md }
```

Three commands cover authoring: `hive workflow new ID` (scaffold a blank starter in an existing project), `hive workflow new ID --template research` (seed from the multi-stage research sample), and `hive init --new-workflow ID` (bootstrap a project and bind the workflow as its default in one go). Custom workflows are discovered from `.hive-state/workflows/*.yml` and run through the same surfaces as the built-ins — `hive new --workflow`, `status`, `run`, `approve`, and the daemon.

**Full walkthrough** — mental model, descriptor anatomy, writing stage instructions, advanced options (terminal approval gates, `skill:` stages, per-stage permissions), and gotchas: **[hivecli.sh/docs/custom-workflows](https://hivecli.sh/docs/custom-workflows/)** (also in-repo at [docs/workflows.md](docs/workflows.md)).

## Power-User / Scripting CLI

The TUI is the recommended human interface and an agent-driven CLI is the recommended automation surface, but the workflow commands are also available directly on `bin/hive` (or the `hv` shim when Apache Hive shadows the name) for scripting, debugging, and recovery. Stage-driving verbs support `--json` and return typed envelopes; `hive new` remains plain text and prints the captured task path plus the next-step hint.

| Group | Verbs | What it's for |
|---|---|---|
| Native setup & web | `hive setup`, `hive web`, `hive web status/install/start/stop` | Provision the default loopback Hive web service, run the foreground server, or observe/repair the managed unit. `--no-service` opts out of web-service mutation. See [docs/cli.md#day-to-day-workflow](docs/cli.md#day-to-day-workflow). |
| Workflow | `hive new`, `hive brainstorm`, `hive plan`, `hive develop`, `hive open-pr`, `hive review`, `hive artifacts`, `hive finalize`, `hive archive`, `hive run`, `hive approve` | Drive a single stage of a single task by hand. `--from <stage>` lets you re-run a stage in place. See [docs/cli.md#day-to-day-workflow](docs/cli.md#day-to-day-workflow). |
| Workflow authoring | `hive workflow new` | Scaffold a project-local workflow descriptor under `.hive-state/workflows/` (`--template research` seeds from a sample). See [Custom Workflows](#custom-workflows) and [docs/workflows.md](docs/workflows.md). |
| Review findings | `hive findings`, `hive accept-finding`, `hive reject-finding` | Inspect GFM-checkbox findings from the latest review pass and tick which ones should feed the next fix pass. See [docs/cli.md#findings-triage](docs/cli.md#findings-triage). |
| Patrol | `hive patrol` | Run one opt-in repository patrol cycle: map feature slices, review them, validate fixes, and open PRs for passed fixes only. See [docs/cli.md#patrol](docs/cli.md#patrol). |
| Daemon | `hive daemon install/enable/start/status/tail/stop/disable` | Manage the global daemon service plus per-project enrollment. The service polls `hive status --json` and dispatches workflow verbs for enrolled projects. Read [wiki/operating.md](wiki/operating.md) before going live. See [docs/cli.md#daemon](docs/cli.md#daemon). |
| Diagnostics & agent setup | `hive status [--operational|--full]`, `hive watch`, `hive act`, `hive doctor`, `hive setup-agents`, `hive rebase-status`, `hive markers clear`, `hive metrics rollback-rate` | Inspect compact or full task state, observe semantic transitions, execute a fresh closed routine action, diagnose configured skills without writes, consent to provision managed built-ins, or use the explicit recovery diagnostics. See [docs/cli.md#diagnostics](docs/cli.md#diagnostics). |
| Registry & lifecycle | `hive init`, `hive update`, `hive uninstall`, `hive forget`, `hive prune`, `hive migrate`, `hive tree` | Attach Hive to a project, upgrade to the latest release, remove the installed CLI, prune the global registry, rename old stage folders, or print the Thor command tree. See [docs/cli.md#lower-level-surface](docs/cli.md#lower-level-surface). |

Full per-command reference, every flag, every envelope field, and every exit code lives in [docs/cli.md](docs/cli.md).

## Documentation

- **[hivecli.sh](https://hivecli.sh)** — The public website: an outcome-first overview plus curated docs (getting started, concepts, configuration, the user-facing command reference, and operating). Agent-friendly too: every page is available as raw markdown and there's an [`llms.txt`](https://hivecli.sh/llms.txt) index. Start here if you're new.
- **[install.md](install.md)** — The canonical agent-installer prompt: OS/arch detection, channel selection (brew / yay / install.sh), Apache Hive collision handling, daemon autostart setup, `hive init` follow-up, and optional skills package wiring. Paste this into your agent CLI when you want it to install or upgrade Hive for you.
- **[docs/concepts.md](docs/concepts.md)** — The conceptual deep-dive: folder-as-agent, the nine stages in detail, the marker protocol that lets stages negotiate handoff, and what compound engineering looks like in practice. Read this when you want to understand *why* Hive is shaped the way it is, or before extending a stage and needing to know what the artefact contract is.
- **[docs/getting-started.md](docs/getting-started.md)** — A CLI-first walkthrough against a real project, from prerequisites through capturing an idea, running brainstorm, and promoting to plan. Read this when you want to drive stages manually or script the `hive init` → `hive new` → `hive brainstorm` shape.
- **[wiki/commands/tui.md](wiki/commands/tui.md)** — The TUI deep reference: the two-pane layout, red-status detail, log tail, new-idea composer with image paste, the per-mode keybinding map, the terminal-hostility contract (resize, SIGTSTP, SIGHUP, non-tty rejection), and the subprocess-dispatch model. Read this when the TUI does something surprising or you want the full keystroke surface.
- **[docs/architecture.md](docs/architecture.md)** — The user-facing architecture: the three trees (project checkout, `.hive-state/` orphan branch, feature worktree), the storage layout `hive init` creates, and how stages, agents, configs, and worktrees compose. Read this when you want to know where files live and which process owns what.
- **[docs/cli.md](docs/cli.md)** — The full command surface exposed by `bin/hive`: every verb, every flag, every `--json` envelope contract, and every exit code. Read this when you're scripting Hive or wiring it into an agent that needs the full CLI map.
- **[docs/workflows.md](docs/workflows.md)** — How to author a project-local workflow descriptor: `hive workflow new` (with `--template`), `hive init --new-workflow`, `skill:` versus `instruction:`, and per-stage permissions. The full public walkthrough lives at **[hivecli.sh/docs/custom-workflows](https://hivecli.sh/docs/custom-workflows/)**.
- **[docs/condition-rollout.md](docs/condition-rollout.md)** — Operator runbook for execute-stage marker/shadow/condition authority, projection repair, divergence triage, explicit promotion, and lossless rollback.
- **[wiki/operating.md](wiki/operating.md)** — Day-2 operations: install matrix, XDG paths, autostart (systemd-user on Linux, launchd on macOS), enrolling existing projects, the mandatory `--dry-run` shakedown, bot setup, tuning concurrency, cost-runaway response, troubleshooting. Read this before running the daemon live and any time you operate Hive across more than one project.
- **[docs/recipes.md](docs/recipes.md)** — Concrete end-to-end workflows, including the xbookmark dogfood replay (linked to the real PR and a committed transcript of the run). Read this when you want to see what a complete idea-to-PR run looks like before trying it yourself.
- **[docs/faq.md](docs/faq.md)** — Troubleshooting and design-rationale answers: why folders instead of a database, why per-stage subprocesses instead of a long-running orchestrator, why commit `.hive-state/` to an orphan branch, why project-level daemon enrollment, how native Hive web shares the file-backed state model, and when to choose Hivebox instead. Read this when you hit a surprise or want to know "why is it like this?".
- **[wiki/index.md](wiki/index.md)** — The catalog of the LLM-maintained engineering wiki under `wiki/`, which is the deepest source of reference material for every command, module, and stage. Read this when the user-facing docs above don't have the depth you need.
