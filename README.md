<p align="center">
  <img src="docs/assets/logo.svg" alt="Hive" width="96" height="96">
</p>

# Hive

Hive turns a rough software idea into a merge-ready pull request through a multi-agent pipeline you can watch as it works. You sketch an idea in a few sentences, open the `hive tui` dashboard, and watch the work move forward: brainstorm pins down what you actually want, plan fixes the approach, execute writes the code, review hardens it, and finalize ships the PR. You can step in at any stage with a normal editor — every artefact is a markdown file in a stage folder, inspectable and editable by you or by another agent.

The mental model is folders. Every task is a directory; the folder's location is the task state. Moving a task from `2-brainstorm/` to `3-plan/` is the approval gesture, and every stage writes a durable artefact the next stage can trust. That practice — making each step's output strong enough for the next one to run autonomously — is called *compound engineering*. It's how Hive carries work from rough idea to merged PR while letting humans drop in on their own terms instead of a chat thread's.

```text
1-inbox  ->  2-brainstorm  ->  3-plan  ->  4-execute  ->  5-open-pr  ->  6-review  ->  7-finalize  ->  8-done
capture       refine           design      build          draft PR       harden        publish         archive
```

Read the model in depth in [docs/concepts.md](docs/concepts.md) — folder-as-agent, the marker protocol that lets stages negotiate handoff, the eight stages in detail, and the trade-offs that come with making everything a file.

## Quickstart

Hive is driven through a terminal dashboard (`hive tui`) that polls every task in every registered project once a second and dispatches stage commands on a single keystroke. New users should start there. If you have not installed Hive yet, jump to [Install](#install) below and come back.

Attach Hive to a project and open the dashboard:

```bash
cd ~/Dev/your-project
hive init .                     # creates .hive-state/ and registers the project globally
hive tui                        # opens the two-pane dashboard
```

You see a left pane listing your registered projects (with `★ All projects` on top) and a right pane showing tasks as a compact table — icon, slug, stage, status, age. From there everything is keystrokes:

| Key | What it does |
|---|---|
| `n` | Capture a new idea. The prompt accepts plain text, pasted screenshots, and dragged image paths. |
| `Enter` | Drive the highlighted task's next action — open its input file for brainstorm/plan/review answers, tail its agent log, or run the suggested recovery on a red row. |
| `b` / `p` / `d` / `P` / `r` / `F` / `a` | Run brainstorm / plan / develop / open-PR / review / finalize / archive on the highlighted task. |
| `o` | Open the task's `.hive-state/stages/<n>-<stage>/<slug>/` folder in your editor for read-only browsing. |
| `/` | Filter the visible rows. |
| `Tab` / `Shift+Tab` | Toggle focus between the projects pane and the tasks pane. |
| `?` | Help overlay. |
| `q` | Quit. |

Workflow keystrokes are non-blocking: dispatching `b` (brainstorm) on one task while another task's agent is still running is fine — both processes run in their own pgroup and the dashboard keeps polling. See [wiki/commands/tui.md](wiki/commands/tui.md) for the full layout, every mode (findings triage, red-status detail, log tail, new-idea composer with image paste), and the keybinding map per mode.

## Drive Hive From Your Coding Agent

Hive's other primary surface is a coding agent — Claude Code, Codex, Gemini, Pi, or anything that can read terminal output and run shell commands. You describe intent in natural language ("brainstorm the bookmark service idea", "run review on the failing task and report the findings"), the agent translates that into `hive <verb>` calls, and you watch the result in the TUI or read the markdown artefacts directly. Every workflow verb supports `--json` and emits a typed envelope (schemas under [schemas/](schemas/), contract in [docs/cli.md#json-output](docs/cli.md#json-output)), so agent-side parsing is structured rather than scraped.

### Install Hive via an agent

Paste this into Claude Code, Codex, or another agent CLI when you want it to install Hive for you. The block has explicit stop-conditions so the agent halts before clobbering existing state.

```text
Install Hive from the canonical GitHub source into ~/Dev/hive and put the hive binary on PATH.

Before changing anything:
- If ~/Dev/hive already exists, stop and ask whether to reuse it, pull it, or choose another directory.
- If `claude` is missing or `claude --version` is older than 2.1.118, stop and report the missing prerequisite.
- If `codex` is missing or `codex --version` is older than 0.125.0, stop and report that the default execute agent will not work until Codex is installed.
- If `gh auth status` fails, stop and ask the user to authenticate GitHub CLI.
- If ~/.local/bin is not on PATH, stop and ask which PATH directory should receive the symlink, then substitute that directory for ~/.local/bin in the link command below.
- If <bin-dir>/hive already exists (file, symlink, or another checkout's binary), stop and ask whether to overwrite it or pick a different bin directory before running the link command below.

Run these commands in order (replace <bin-dir> with the chosen PATH directory; default is ~/.local/bin):

git clone https://github.com/ivankuznetsov/hive ~/Dev/hive
cd ~/Dev/hive
bundle install
mkdir -p <bin-dir>
ln -sf ~/Dev/hive/bin/hive <bin-dir>/hive
hive --version

Report the installed version and the path returned by `command -v hive`.
```

### Operate Hive day-to-day via an agent

Once Hive is installed, you can hand any of the workflow verbs to an agent. Useful prompt shapes:

- *Capture an idea:* `Run hive new your-project "<title>" and report the slug it printed.`
- *Triage what's waiting:* `Run hive status --json and tell me which tasks are waiting for me (any row whose action_key is needs_input or review_findings).`
- *Drive a task through one stage:* `Run hive review <slug> --json and summarize the resulting envelope, including any waiting markers.`
- *Watch a long-running task:* `Run hive status --json --project <name> every 30 seconds and stop when the task at <slug> reaches a needs_input or completed action_key.`

The `--json` envelope is stable across versions (schemas live under [schemas/](schemas/)), so agent prompts can rely on field shapes without scraping. `hive tui` is intentionally human-only and rejects `--json` — use the CLI verbs and `hive status --json` for programmatic use.

## Install

Requires Ruby 3.4, git ≥ 2.40, an authenticated `claude` ≥ 2.1.118, `codex` ≥ 0.125.0 for the default execute agent, and an authenticated `gh`. See [docs/getting-started.md#prerequisites](docs/getting-started.md#prerequisites) for the full prerequisite list and the first-run walkthrough.

```bash
git clone https://github.com/ivankuznetsov/hive ~/Dev/hive
cd ~/Dev/hive
bundle install
mkdir -p ~/.local/bin
ln -sf ~/Dev/hive/bin/hive ~/.local/bin/hive
```

If `~/.local/bin` is not on `PATH`, put the symlink in a directory that is. The `-sf` form overwrites an existing `hive` at the target path; run `command -v hive` first if you already have one installed and don't want to clobber it. Verify the install with `hive --version` and `hive doctor`.

## Power-User / Scripting CLI

The TUI is the recommended human interface and an agent-driven CLI is the recommended automation surface, but every workflow verb is also available directly on `bin/hive` for scripting, debugging, and recovery. Each verb supports `--json` and returns a typed envelope, so wrapper scripts get structured output.

| Group | Verbs | What it's for |
|---|---|---|
| Workflow | `hive new`, `hive brainstorm`, `hive plan`, `hive develop`, `hive open-pr`, `hive review`, `hive finalize`, `hive archive`, `hive run`, `hive approve` | Drive a single stage of a single task by hand. `--from <stage>` lets you re-run a stage in place. See [docs/cli.md#day-to-day-workflow](docs/cli.md#day-to-day-workflow). |
| Findings triage | `hive findings`, `hive accept-finding`, `hive reject-finding` | Inspect GFM-checkbox findings from the latest review pass and tick which ones should feed the next fix pass. See [docs/cli.md#findings-triage](docs/cli.md#findings-triage). |
| Daemon | `hive daemon enable/start/status/tail/stop/disable` | Run the per-project daemon that polls `hive status --json` and auto-dispatches workflow verbs for tasks that can advance. Opt-in; read [wiki/operating.md](wiki/operating.md) before going live. See [docs/cli.md#daemon](docs/cli.md#daemon). |
| Diagnostics | `hive status`, `hive doctor`, `hive rebase-status`, `hive markers clear`, `hive metrics rollback-rate` | Inspect task state, validate configured stage/reviewer skills, check whether the next run would auto-rebase, clear a recovery marker by name, or report fix-agent rollback rate. See [docs/cli.md#diagnostics](docs/cli.md#diagnostics). |
| Registry | `hive init`, `hive forget`, `hive prune`, `hive migrate`, `hive tree` | Attach Hive to a project, remove projects from the global registry, prune missing paths, rename old stage folders, or print the Thor command tree. See [docs/cli.md#lower-level-surface](docs/cli.md#lower-level-surface). |

Full per-command reference, every flag, every envelope field, and every exit code lives in [docs/cli.md](docs/cli.md).

## Documentation

- **[docs/concepts.md](docs/concepts.md)** — The conceptual deep-dive: folder-as-agent, the eight stages in detail, the marker protocol that lets stages negotiate handoff, and what compound engineering looks like in practice. Read this when you want to understand *why* Hive is shaped the way it is, or before extending a stage and needing to know what the artefact contract is.
- **[docs/getting-started.md](docs/getting-started.md)** — A five-minute first-run walkthrough against a real project, from prerequisites through capturing an idea, watching brainstorm work, and promoting to plan. Read this on day one; come back if you ever forget the `hive init` → `hive new` → `hive brainstorm` shape.
- **[wiki/commands/tui.md](wiki/commands/tui.md)** — The TUI deep reference: the two-pane layout, every mode (findings triage, red-status detail, log tail, new-idea composer with image paste), the per-mode keybinding map, the terminal-hostility contract (resize, SIGTSTP, SIGHUP, non-tty rejection), and the subprocess-dispatch model. Read this when the TUI does something surprising or you want the full keystroke surface.
- **[docs/architecture.md](docs/architecture.md)** — The user-facing architecture: the three trees (project checkout, `.hive-state/` orphan branch, feature worktree), the storage layout `hive init` creates, and how stages, agents, configs, and worktrees compose. Read this when you want to know where files live and which process owns what.
- **[docs/cli.md](docs/cli.md)** — The full command surface exposed by `bin/hive`: every verb, every flag, every `--json` envelope contract, and every exit code. Read this when you're scripting Hive or wiring it into an agent that needs the full CLI map.
- **[docs/recipes.md](docs/recipes.md)** — Concrete end-to-end workflows, including the xbookmark dogfood replay (linked to the real PR and a committed transcript of the run). Read this when you want to see what a complete idea-to-PR run looks like before trying it yourself.
- **[docs/faq.md](docs/faq.md)** — Troubleshooting and design-rationale answers: why folders instead of a database, why per-stage subprocesses instead of a long-running orchestrator, why commit `.hive-state/` to an orphan branch, why opt-in daemon, why no built-in web UI. Read this when you hit a surprise or want to know "why is it like this?".
- **[wiki/index.md](wiki/index.md)** — The catalog of the LLM-maintained engineering wiki under `wiki/`, which is the deepest source of reference material for every command, module, and stage. Read this when the user-facing docs above don't have the depth you need.
