require "thor"
require "hive/stages"
require "hive/workflows/registry"

module Hive
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    # Stage vocabulary embedded in `--from`/`--to`/`--stage` option help so
    # `hive help run|approve|status` still advertises the valid stages to an
    # agent reading `--help`. R1 dropped Thor's static `enum:` (it couldn't
    # hold runtime workflows and auto-generated a "Possible values:" list), so
    # this derives the same list from the default coding workflow descriptor —
    # no literal stage dirs in source, so it stays in sync with a renumber.
    STAGE_VOCABULARY = "stages: #{Hive::Stages::DIRS.join(', ')}".freeze

    # Built-in workflow names embedded in the `--workflow` help on both `init`
    # and `new`. Frozen at class load, when only built-ins are registered;
    # project workflows load later via Workflows::Project.load!, so this stays
    # built-ins-only by design. The static tail in .workflow_option_desc covers
    # project-authored workflows; making the list project-aware later means
    # editing only that one method.
    WORKFLOW_VOCABULARY = Hive::Workflows::Registry.ids.join(", ").freeze
    INIT_SCHEMA_ID = "hive-init.v#{Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-init")}".freeze

    # The one place the `--workflow` help is composed, shared by `init` and
    # `new` so they stay symmetric.
    def self.workflow_option_desc
      "#{WORKFLOW_VOCABULARY}, or any project-authored workflow " \
        "(author one with `hive workflow new ID`)"
    end

    # `--json` is honoured by `init`, `status`, `run`, `approve`, `findings`,
    # `accept-finding`, `reject-finding`, `pairing`, and the workflow verbs
    # (`brainstorm`, `plan`, `develop`, `pr`, `archive`). `new` accepts
    # the flag silently so an automated caller can pass it uniformly. Most
    # emitting commands produce a typed JSON document on success and a
    # structured error envelope on every failure path; init currently
    # publishes the success envelope while precondition failures keep the
    # legacy stderr + exit-code contract.
    class_option :json, type: :boolean, default: false,
                        desc: "emit a single JSON document on stdout (commands that support it)"

    FINDING_SEVERITY_ENUM = %w[high medium low nit].freeze

    desc "version", "Print hive version"
    def version
      puts Hive::VERSION
    end
    map "--version" => :version

    desc "init [PROJECT_PATH]", "Bootstrap .hive-state (orphan hive/state branch); TTY-prompts for agents + limits"
    long_desc <<~DESC
      Initialises hive in PROJECT_PATH (defaults to the current directory):
      creates the orphan `hive/state` branch, attaches it as a worktree at
      `<project>/.hive-state/`, scaffolds stage folders, ignores
      `.hive-state/` on master, bootstraps managed llm-wiki project
      context with Codex as the headless wiki refresher, and registers
      the project globally.

      On a TTY, init asks the operator the following questions before
      writing anything to disk:

        0. Workflow (when >1 workflow is registered)             — default coding
        1. Planning agent (drives 2-brainstorm + 3-plan)         — default claude
        2. Claude launch mode (project-global, tmux/headless)    — default tmux
        3. Claude permission mode (all Claude-backed stages)     — default bypassPermissions
           (one of bypassPermissions/auto/default/acceptEdits/dontAsk/plan)
        4. Development agent (drives 4-execute)                  — default codex
        5. Review agents (multi-select over 3 default reviewers) — default all
        6. Patrol PR review agents                               — default codex only
        7. Triage bias (courageous / safetyist)                  — default courageous
        8. Per-stage budget+timeout (10 stage/role pairs)        — default generous
        9. Daemon enrollment                                     — default enabled
       10. Hive babysitter enrollment                            — default enabled
       11. Daemon autostart                                      — default disabled

      Each prompt accepts a name (e.g. `codex`, `claude-ce-code-review`)
      OR a 1-based index. Blank input takes the default. Answer `n` at
      the final confirmation to abort with no disk side effects.

      The Workflow step (item 0) is shown only when the project has more
      than one workflow registered; it lists the workflow ids plus an
      `author a new workflow` entry. A bare Enter keeps the current
      default — `coding` on a fresh init, the project's existing
      `default_workflow` on a re-init — so it never silently downgrades a
      non-coding default. Choosing the author entry prompts for a new id
      and scaffolds it through the same path as `--new-workflow` (below)
      before the remaining questions resume.

      On non-TTY (CI, pipes, scripted callers) the prompts are skipped
      and a one-line summary is emitted to stdout so the caller can see
      which defaults landed:

        hive: using defaults — planning=claude, claude_mode=tmux,
        claude_permission_mode=bypassPermissions, dev=codex, reviewers=all3,
        patrol_reviewers=codex-native-review, triage=courageous, limits=defaults,
        daemon=enabled, babysitter=enabled, daemon_autostart=disabled

      With --json, init suppresses that prose and emits a single
      #{INIT_SCHEMA_ID} success payload containing the resolved answers plus
      project path, default branch, hive-state path, and worktree root.
      When used with --new-workflow, the payload also includes
      descriptor_path and instruction_path.

      After project creation, interactive init diagnoses the enabled managed
      agent skills and offers to invoke the same consent-safe engine as
      `hive setup-agents`. Declining prints standalone remediation. Non-TTY
      and --json init never offer or mutate agent state, and optional setup
      failure never rolls back the initialized project.

      To bootstrap a new custom workflow in one pass, use:

        hive init --new-workflow writing ~/Dev/writing

      This scaffolds `.hive-state/workflows/writing.yml` plus
      `.hive-state/workflows/writing/work.md`, binds
      `default_workflow: "writing"`, and prints the paths to edit before
      running `hive new` without --workflow. The descriptor and the
      `config.yml` binding are committed together on `hive/state` on both the
      fresh and already-initialized paths, so the bound default survives a
      hive-state reset. `--new-workflow` is mutually exclusive with
      `--workflow`, reuses `hive workflow new`'s reserved-id checks, and on an
      already-initialized project scaffolds the workflow and rebinds the
      default in one hive-state commit.

      Headless callers can explicitly select architecture discovery before
      any state is written with --refactor-patrol or --no-refactor-patrol;
      omitting both keeps the fresh-project default enabled. Set other
      non-default values after init in `.hive-state/config.yml` (see
      `wiki/modules/config.md` for the schema). Existing projects reject both
      selectors rather than silently ignoring them during a workflow rebind.
      Legacy Compound Engineering skill values such as
      `/compound-engineering:ce-brainstorm` are normalized to the current
      `/ce-brainstorm` form before prompts are rendered. Piped STDIN is
      intentionally NOT consumed.

      Exit codes:
        0  — initialised successfully
        1  — generic / unexpected error
        2  — already initialised (`hive/state` branch already exists)
        64 — user aborted at the confirmation prompt

      See `wiki/commands/init.md` for the full prompt flow and ADR-023.
    DESC
    option :force, type: :boolean, default: false, desc: "skip clean-tree check"
    option :workflow, type: :string, desc: workflow_option_desc
    option :new_workflow, type: :string,
                          desc: "scaffold custom workflow ID, bind it as this project's default, and print paths to edit"
    option :refactor_patrol, type: :boolean, default: nil,
                             desc: "enable or disable post-merge architecture discovery before init writes state"
    def init(project_path = Dir.pwd)
      require "hive/commands/init"
      Hive::Commands::Init.new(
        project_path,
        force: options[:force],
        json: options[:json],
        workflow: options[:workflow],
        new_workflow: options[:new_workflow],
        refactor_patrol: options[:refactor_patrol]
      ).call
    end

    desc "forget NAME", "Remove a project from the global registry (inverse of `hive init`)"
    long_desc <<~DESC
      Drops the entry whose `name` matches NAME from the global registry
      (`~/.config/hive/config.yml` by default, or `HIVE_HOME/config.yml`
      when overridden).
      The project's .hive-state directory on disk (if any) is left alone.

      An unknown name is a USAGE error (64), mirroring `hive metrics
      --project NAME`. Pass --if-exists when a retry-safe cleanup script
      should exit 0 if the entry is already absent. To bulk-remove every
      entry whose path no longer exists, use `hive prune` instead.

      Exit codes: 0 success; 64 unknown project / missing NAME positional;
      70 internal error; 78 bad config (malformed config.yml or typoed
      $HIVE_HOME).

      Examples:

        hive forget demo                  # remove the entry named 'demo'
        hive forget demo --json           # same, machine-readable envelope
        hive forget demo --if-exists      # exit 0 even when demo is already absent
        hive forget nonexistent --json    # error envelope w/ error_kind: unknown_project
    DESC
    option :if_exists, type: :boolean, default: false, desc: "exit 0 if NAME is already absent"
    def forget(name = nil)
      require "hive/commands/forget"
      Hive::Commands::Forget.new(name, json: options[:json], if_exists: options[:if_exists]).call
    end

    desc "prune", "Drop stale, retargeted, or malformed registry entries"
    long_desc <<~DESC
      Walks the global config.yml and removes every `registered_projects`
      entry whose `path` is not a directory on disk, whose stored
      `real_path` no longer matches the current target, OR whose row shape
      is invalid (non-Hash, missing `path`, etc. — hand-edit accidents).
      Useful after running `hive init` against `mktemp -d` directories
      that have since been cleaned up — the entries linger forever
      otherwise and the TUI's project list keeps showing them as
      `(missing)`.

      With `--dry-run` the registry is not rewritten; the would-be-removed
      list is printed (or returned via --json) for review.

      Exit codes: 0 success; 70 internal error; 78 bad config.

      Examples:

        hive prune                        # write; print one-line summary
        hive prune --dry-run              # preview; do not write
        hive prune --json                 # write; emit hive-prune.v1 envelope
        hive prune --dry-run --json       # preview as JSON for agent review
    DESC
    option :dry_run, type: :boolean, default: false, desc: "preview without writing"
    def prune
      require "hive/commands/prune"
      Hive::Commands::Prune.new(dry_run: options[:dry_run], json: options[:json]).call
    end

    desc "doctor", "Inspect managed agent skill health without changing agent state"
    long_desc <<~DESC
      Resolves the effective enabled stages, named reviewers, browser hooks,
      and their configured agent profiles (claude / codex / pi / grok)
      against Hive's packaged agent-skills manifest. For each managed
      capability it combines bounded native CLI inventory with the exact
      filesystem path that would win at runtime. Custom skills and capabilities
      unsupported by the manifest remain visible but unmanaged.

      The manifest currently maps Compound Engineering (`/ce-*`), llm-wiki
      planning (`/plan`, `/llm-wiki:wiki-plan`, or `/skill:wiki-plan`), and
      Claude's PR Review Toolkit. `hive doctor` catches missing, stale,
      incompatible, or shadowed installs before a stage spawns.

      Per-agent search rules:
      - claude: `~/.claude/{commands/<name>.md, skills/<name>/SKILL.md}`
        for plain `/<name>`; `~/.claude/plugins/marketplaces/<plug>*/skills/...`
        for `/<plug>:<name>`. Project-level paths checked too.
      - codex: `~/.codex/skills/<name>/SKILL.md` (and `.system/`) for
        plain; `~/.codex/plugins/cache/*/<plug>/*/skills/...` for
        plug-namespaced.
      - pi: `/skill:<name>` only. Probes (in order) `~/.pi/agent/skills`
        (recursive, plus root `<name>.md`), `~/.agents/skills` (recursive,
        cross-agent), `<project>/.pi/skills` (recursive), every ancestor
        `<dir>/.agents/skills` up to the nearest `.git`, paths listed in
        `~/.pi/agent/settings.json` and `<project>/.pi/settings.json`
        (`skills`/`packages` keys, jailed under settings dir / home /
        project), `npm root -g`, `~/.pi/npm/node_modules/*/skills`,
        `~/.pi/agent/git` repos (host/user/repo bounded prefix), and any package-root
        whose `package.json#pi.skills` lists a path (jailed under
        package_root). Each row's `message` field is the authoritative
        install hint.

      Managed rows report healthy, missing, stale, incompatible, conflicting,
      or unavailable with native inventory and resolver-path evidence. An
      unavailable CLI is a visible non-blocking warning; other unresolved
      managed rows include an exact `hive setup-agents --agent ... --skill ...`
      remediation. Doctor never installs or writes agent state.

      --json emits the versioned hive-doctor.v2 envelope. The v1 schema file
      remains packaged for consumers pinned to the former resolution-only
      contract.

      Exit codes: 0 all available managed skills healthy (unavailable-only is
      non-blocking); 65 actionable skill/dependency failure; 78 config error.

      Examples:

        hive doctor                       # tabular output
        hive doctor --json                # machine-readable envelope
    DESC
    def doctor
      require "hive/commands/doctor"
      cfg = Hive::Config.load(Dir.pwd)
      exit Hive::Commands::Doctor.new(
        config: cfg,
        project_root: Dir.pwd,
        json: options[:json]
      ).call
    end

    desc "setup-agents", "Provision managed skills for configured Claude, Codex, and Pi agents"
    long_desc <<~DESC
      Inspects every enabled, manifest-managed coding workflow capability,
      prints one aggregate plan of native commands and Hive-owned files, and
      performs the plan only after explicit consent. The plan is revalidated
      immediately before execution and each independent agent/package
      continues if another operation fails.

      Without --yes, stdin must be a TTY and the operator must confirm. JSON
      mode never prompts, so --json requires --yes whenever mutations are
      planned. Repeat --agent/--skill values (or pass several values after one
      flag) to scope setup to effective managed targets.

      Exit codes: 0 healthy/no-op; 1 attempted or residual failure;
      64 consent required/refused; 78 invalid manifest/config/filter.
    DESC
    option :yes, type: :boolean, default: false, desc: "accept the revalidated aggregate plan"
    option :agent, type: :array, desc: "scope to configured agent name(s)"
    option :skill, type: :array, desc: "scope to managed capability id(s)"
    def setup_agents
      require "hive/commands/setup_agents"
      cfg = Hive::Config.load(Dir.pwd)
      exit Hive::Commands::SetupAgents.new(
        config: cfg,
        project_root: Dir.pwd,
        yes: options[:yes],
        json: options[:json],
        agents: options[:agent],
        skills: options[:skill]
      ).call
    end

    desc "setup", "Provision local Hive web mode, daemon service, and project enrollment"
    option :service, type: :boolean, default: false, desc: "also install the managed web service"
    option :no_bootstrap, type: :boolean, default: false, desc: "diagnose only; do not install qmd or web bundle"
    option :no_init, type: :boolean, default: false, desc: "do not initialize or enroll the current project"
    def setup
      require "hive/commands/setup"
      exit Hive::Commands::Setup.new(
        json: options[:json],
        service: options[:service],
        no_bootstrap: options[:no_bootstrap],
        no_init: options[:no_init]
      ).call
    end

    desc "update", "Update hive via the install channel that installed it"
    long_desc <<~DESC
      Reads the install-channel marker written by the installer and delegates
      to the native updater:

        brew  → brew upgrade ivankuznetsov/hive/hive
        aur   → yay -Syu hive-bin (or paru when yay is unavailable)
        bash  → download the pinned install.sh to a tempfile, then run it
        dev   → prints git pull && bundle install guidance

      Hive never swaps its own binary in place and never guesses across
      channels.
    DESC
    option :dry_run, type: :boolean, default: false, desc: "print the selected updater command without executing it"
    def update
      require "hive/commands/update"
      Hive::Commands::Update.new(dry_run: options[:dry_run]).call
    end

    desc "connect SERVICE", "Connect an external service (screenote)"
    long_desc <<~DESC
      Runs the OAuth 2.1 setup flow for SERVICE (currently only `screenote`).
      Discovers Screenote OAuth/MCP metadata, opens an authorize URL in the
      browser via a loopback redirect + PKCE, lists Screenote projects over
      MCP, prompts for a default project, and stores the credential at
      `~/.config/hive/screenote.json` (mode 0600). The loopback waits up to
      300s for the browser callback before timing out, so an automated driver
      should set an outer deadline above that.

      --base-url overrides the resolved Screenote base URL (config /
      HIVE_SCREENOTE_BASE_URL / default https://screenote.ai).

      --json streams structured lines: an `authorize` line carrying the
      `authorize_url` (the fallback when the browser cannot auto-open),
      followed by a success document with `issuer`, `client_id`,
      `project_id`, `base_url`, and `credential_path`. A lone project is
      auto-selected; when several projects exist and no default can be chosen
      non-interactively, connect instead emits a `{ "ok": false, "stage":
      "needs_project_selection", "projects": [...] }` line and exits non-zero
      — re-run connect interactively (without --json) to pick the default.
    DESC
    option :base_url, type: :string, desc: "Screenote base URL (defaults to config or https://screenote.ai)"
    def connect(service)
      require "hive/commands/connect"
      Hive::Commands::Connect.new(service, base_url: options[:base_url], json: options[:json]).call
    end

    desc "disconnect SERVICE", "Disconnect an external service (screenote)"
    long_desc <<~DESC
      Revokes the stored token for SERVICE (currently only `screenote`) when
      possible and clears the local credential at
      `~/.config/hive/screenote.json`. Missing credentials are an idempotent
      no-op; a revoke failure (or unreachable endpoint) is warned about but
      still clears the local file.

      --json emits `{ "disconnected": ..., "revoked": ..., "reason": ... }`.
      Revocation is idempotent (RFC 7009), so when `revoked` is false the
      `reason` is `no_token`, `unreadable_credential`, or the raw revoke
      error message.
    DESC
    def disconnect(service)
      require "hive/commands/disconnect"
      Hive::Commands::Disconnect.new(service, json: options[:json]).call
    end

    desc "uninstall", "Remove hive user registrations and runtime files without destroying work"
    long_desc <<~DESC
      Stops and deregisters the per-user daemon service, removes hive config
      and cache directories, and removes versioned bash-install payloads.
      It preserves accumulated work under XDG state and project .hive-state
      directories by default.

      --purge is non-interactive for CI but still preserves accumulated work.
      --force-purge-state is the explicit destructive escape hatch.
    DESC
    option :purge, type: :boolean, default: false, desc: "non-interactive cleanup; still preserves state"
    option :force_purge_state, type: :boolean, default: false,
                               desc: "also remove XDG state and registered project .hive-state directories"
    def uninstall
      require "hive/commands/uninstall"
      Hive::Commands::Uninstall.new(
        purge: options[:purge],
        force_purge_state: options[:force_purge_state]
      ).call
    end

    desc "migrate [PROJECT_PATH]", "Rename in-flight task folders from the pre-open-pr stage layout"
    def migrate(project_path = Dir.pwd)
      require "hive/commands/migrate"
      Hive::Commands::Migrate.new(project_path).call
    end

    desc "wiki SUBCOMMAND", "Manage generated wiki artifacts (compile-log)"
    long_desc <<~DESC
      Subcommands:
        compile-log [PROJECT_PATH]    Rebuild wiki/log.md from wiki/log.d/*.md
                                      fragments plus the legacy log body.

      PRs should add a uniquely named fragment under wiki/log.d/ instead of
      editing wiki/log.md directly; run this command after merge/rebase when a
      concrete checkout needs the compiled changelog.
    DESC
    option :check, type: :boolean, default: false,
                   desc: "exit non-zero when wiki/log.md is not the generated output"
    def wiki(subcommand, project_path = Dir.pwd)
      require "hive/commands/wiki"
      Hive::Commands::Wiki.new(
        subcommand,
        project_path,
        check: options[:check]
      ).call
    end

    desc "workflow SUBCOMMAND [ID]", "Manage project workflows and reviewed Honeycomb packages"
    long_desc <<~DESC
      Subcommands:
        new ID    Scaffold a per-project workflow descriptor under
                  <hive_state_path>/workflows/ID.yml plus its stage
                  instruction(s) under <hive_state_path>/workflows/ID/.
        install honeycomb/NAME[@VERSION]  Verify and install a reviewed package.
        list                              Inspect built-in, authored, and managed workflows.
        update NAME                       Diff and advance a managed package.
        remove NAME                       Disable a managed package for new tasks.
        publish ID                        Package an authored workflow and open a registry PR.

      By default `new` scaffolds the blank `inbox -> work -> done` stub. Pass
      `--template NAME` to seed from a richer sample workflow instead (e.g.
      writing, research). Either way: edit the scaffolded stage instruction(s),
      then run `hive new PROJECT --workflow ID "<your idea>"`.
    DESC
    option :template, type: :string,
                      desc: "for `new`: seed from a named sample workflow (e.g. writing, research) instead of the blank stub"
    option :yes, type: :boolean, default: false,
                 desc: "confirm install/update/remove in JSON or non-interactive mode"
    option :dry_run, type: :boolean, default: false,
                     desc: "for `install`, `update`, or `remove`: validate and report without changing project state"
    option :allow_escalation, type: :boolean, default: false,
                              desc: "for `install`/`update`: separately allow unbounded or increased capabilities"
    option :mapping, type: :array, default: [],
                     desc: "for `install`/`update`: SLOT=AGENT[,model=MODEL][,effort=EFFORT] overrides"
    option :input_binding, type: :array, default: [],
                           desc: "for `install`/`update`: optional input NAME=ENV_NAME bindings"
    option :version, type: :string,
                     desc: "for `publish`: semantic package version"
    def workflow(subcommand = nil, id = nil)
      require "hive/commands/workflow"
      Hive::Commands::Workflow.new(
        subcommand,
        id,
        project_root: Dir.pwd,
        json: options[:json],
        template: options[:template],
        yes: options[:yes],
        dry_run: options[:dry_run],
        allow_escalation: options[:allow_escalation],
        mapping_overrides: options[:mapping],
        input_bindings: options[:input_binding],
        version: options[:version]
      ).call
    end

    desc "bench SUBCOMMAND [SLUG]", "Contribute to hive-bench: `bench submit SLUG` extracts a 9-done task and opens a PR"
    long_desc <<~DESC
      Subcommands:

        submit SLUG    Extract the completed (9-done) task SLUG into a hive-bench
                       corpus entry and open a submission PR. Locates the
                       hive-bench checkout via HIVE_BENCH_PATH (default
                       ~/Dev/hive-bench). Runs a local secret/PII preflight and
                       aborts before opening a PR if anything is found.
    DESC
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def bench(subcommand, slug = nil)
      require "hive/commands/bench_submit"
      case subcommand
      when "submit"
        Hive::Commands::BenchSubmit.new(slug, project: options[:project], json: options[:json]).call
      else
        warn "hive bench: unknown subcommand '#{subcommand}' (expected: submit)"
        exit Hive::ExitCodes::USAGE
      end
    end

    desc "new PROJECT TEXT", "Create a new task in PROJECT"
    long_desc <<~DESC
      Create a new task in PROJECT from the free-text TEXT. By default, the task
      uses the project's default workflow; pass --workflow to pin a registered
      workflow for this task. (Options may also follow the text.)

      --depends-on stacks this task on a prerequisite: the daemon holds
      auto-advance until the prerequisite reaches the project's dependency
      gate stage (8-finalize by default, configurable via
      `dependency_gate_stage`). Use a prerequisite task id or slug for the
      same project, or project:slug for an explicit cross-project dependency.

      Examples:

        hive new myproj --workflow content "write the launch post"

        hive new myproj --depends-on 42 "add export button"

        hive new myproj --depends-on add-export-endpoint-260618-ab12 "wire up export API"

        hive new myproj --depends-on api:add-export-endpoint-260618-ab12 "wire up export UI"
    DESC
    option :depends_on, type: :string,
                        desc: "depend on a same-project id/slug or explicit project:slug; hold daemon " \
                              "auto-advance until it reaches the dependency gate stage " \
                              "(8-finalize by default)"
    option :workflow, type: :string, desc: workflow_option_desc
    def new_task(project, *text_parts)
      require "hive/commands/new"
      text = text_parts.join(" ")
      raise Hive::Error, "missing task text" if text.strip.empty?

      Hive::Commands::New.new(
        project,
        text,
        depends_on: options[:depends_on],
        workflow: options[:workflow]
      ).call
    end
    map "new" => :new_task

    desc "generate-name TARGET", "Generate a human-readable display name for TARGET"
    option :project, type: :string, desc: "scope lookup to one registered project"
    option :stage, type: :string,
                   desc: "scope lookup to one stage, full or short form (#{STAGE_VOCABULARY})"
    def generate_name(target)
      require "hive/commands/generate_name"
      Hive::Commands::GenerateName.new(
        target,
        project: options[:project],
        stage: options[:stage]
      ).call
    end
    map "generate-name" => :generate_name

    desc "run TARGET", "Run the stage agent for TARGET (slug or task folder)"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :stage, type: :string,
                   desc: "scope slug lookup to one stage, full or short form (#{STAGE_VOCABULARY})"
    option :no_rebase, type: :boolean, default: false,
                       desc: "skip the auto-rebase pre-step for this run only (one-off override of cfg.rebase.enabled)"
    def run_task(target)
      require "hive/commands/run"
      Hive::Commands::Run.new(
        target,
        project: options[:project],
        stage: options[:stage],
        json: options[:json],
        no_rebase: options[:no_rebase],
        durable: true
      ).call
    end
    map "run" => :run_task

    desc "rebase-status TARGET", "Print the auto-rebase status for TARGET without running anything (read-only)"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :stage, type: :string,
                   desc: "scope slug lookup to one stage, full or short form (#{STAGE_VOCABULARY})"
    def rebase_status(target)
      require "hive/commands/rebase_status"
      Hive::Commands::RebaseStatus.new(
        target,
        project: options[:project],
        stage: options[:stage],
        json: options[:json]
      ).call
    end
    map "rebase-status" => :rebase_status

    desc "brainstorm TARGET", "Move an inbox task into brainstorm, or run an existing brainstorm task"
    option :from, type: :string,
                  desc: "expected current stage; use to disambiguate same-slug tasks (#{STAGE_VOCABULARY})"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def brainstorm(target)
      run_stage_action("brainstorm", target)
    end

    desc "plan TARGET", "Move a completed brainstorm task into plan, or run an existing plan task"
    option :from, type: :string,
                  desc: "expected current stage; use to disambiguate same-slug tasks (#{STAGE_VOCABULARY})"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def plan(target)
      run_stage_action("plan", target)
    end

    desc "develop TARGET", "Move a completed plan task into execute, or run an existing execute task"
    option :from, type: :string,
                  desc: "expected current stage; use to disambiguate same-slug tasks (#{STAGE_VOCABULARY})"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def develop(target)
      run_stage_action("develop", target)
    end

    desc "open-pr TARGET", "Move a completed execute task into open-pr, or run an existing open-pr task"
    option :from, type: :string,
                  desc: "expected current stage; use to disambiguate same-slug tasks (#{STAGE_VOCABULARY})"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def open_pr(target)
      run_stage_action("open-pr", target)
    end
    map "open-pr" => :open_pr
    map "pr" => :open_pr

    desc "review [TARGET]", "Move a completed open-pr task into review, run an existing review task, or --pr PR"
    option :from, type: :string,
                  desc: "expected current stage; use to disambiguate same-slug tasks (#{STAGE_VOCABULARY})"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :pr, type: :string, desc: "run an ad-hoc review for PR number, #number, or GitHub PR URL"
    def review(target = nil)
      if options[:pr]
        emit_review_usage_error("hive review: pass either TARGET or --pr, not both") if target
        # `--from` only disambiguates same-slug tasks for a TARGET lookup; an
        # ad-hoc `--pr` review resolves a deterministic slug and never consults
        # it. Refuse the combo (mirroring the TARGET + `--pr` guard above)
        # rather than silently dropping the flag.
        emit_review_usage_error("hive review: --from is not valid with --pr") if options[:from]

        require "hive/commands/adhoc_review"
        require "hive/commands/stage_action"
        # AdhocReview emits its own --json error envelope on create-phase
        # failures and re-raises. On success it returns the resolved project
        # name; forward it (not the raw, possibly-nil options[:project]) so
        # StageAction resolves the slug against the same project AdhocReview
        # used, never a same-named slug in another registered repo.
        result = Hive::Commands::AdhocReview.new(
          pr: options[:pr],
          project: options[:project],
          json: options[:json]
        ).enqueue
        return Hive::Commands::StageAction.new(
          "review",
          result.fetch(:slug),
          project: result.fetch(:project),
          json: options[:json],
          durable: true
        ).call
      end

      emit_review_usage_error("hive review: missing TARGET (or pass --pr PR)") unless target

      run_stage_action("review", target)
    end

    desc "artifacts TARGET", "Move a completed review task into artifacts, or run an existing artifacts task"
    option :from, type: :string,
                  desc: "expected current stage; use to disambiguate same-slug tasks (#{STAGE_VOCABULARY})"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def artifacts(target)
      run_stage_action("artifacts", target)
    end

    desc "finalize TARGET", "Move a completed artifacts task into finalize, or run an existing finalize task"
    option :from, type: :string,
                  desc: "expected current stage; use to disambiguate same-slug tasks (#{STAGE_VOCABULARY})"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def finalize(target)
      run_stage_action("finalize", target)
    end

    desc "archive [TARGET]", "List done tasks, or move a completed finalize task into done"
    long_desc <<~DESC
      With no TARGET, lists every task currently in 9-done across registered
      projects. Pass --json for the same archive-scoped status payload.

      With TARGET, preserves the workflow behavior: move a completed finalize
      task into done, or run an existing done task.
    DESC
    option :from, type: :string,
                  desc: "expected current stage; use to disambiguate same-slug tasks (#{STAGE_VOCABULARY})"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :recover_merged_error_reason, type: :string,
                                          desc: "internal: archive a merged PR despite this finalize ERROR reason"
    def archive(target = nil)
      if target.nil?
        if options[:from]
          warn "hive archive: --from is ignored when listing; it only disambiguates same-slug tasks for `hive archive TARGET`"
        end
        require "hive/commands/status"
        return Hive::Commands::Status.new(json: options[:json], project: options[:project], archive: true).call
      end

      run_stage_action("archive", target)
    end

    desc "drop TARGET", "Hard-delete a task: kill agent, remove folder(s)/worktree/branch, close draft PR"
    long_desc <<~DESC
      TARGET is a task folder path or a bare slug. A bare slug is resolved
      across registered projects; pass --project to disambiguate cross-project
      collisions and --from to assert the source stage on retry.

      Drop is irreversible: there is no archive/dropped bucket, no undo, no
      reason prompt. Cleanup is idempotent — re-running drop after an interrupt
      completes the remaining steps.

      Tasks already at 9-done are refused with exit code 64 and
      error_kind: already_archived.

      Exit codes:
        0  — dropped successfully
        1  — generic / uncategorised failure (error_kind: error)
        4  — --from did not match the task's current stage (wrong_stage)
        64 — unknown slug, ambiguous slug, or already archived
              (invalid_task_path / ambiguous_slug / already_archived)
        70 — internal, git, or worktree failure during cleanup
              (internal / git / worktree)
        75 — hive/state commit-lock contention (retryable; error_kind: error)
        78 — malformed project or global config (config)
    DESC
    option :from, type: :string,
                  desc: "expected current stage; raises WRONG_STAGE on mismatch (#{STAGE_VOCABULARY})"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def drop(target)
      require "hive/commands/drop"
      Hive::Commands::Drop.new(
        target,
        project: options[:project],
        from: options[:from],
        json: options[:json]
      ).call
    end

    desc "patrol PROJECT", "Run one repository patrol scan cycle for a registered project"
    long_desc <<~DESC
      Maps the registered project's repository into language-neutral
      component slices under <project>/.hive-state/patrol/, asks the
      configured patrol agent for bounded, source-verified production defects
      across a persisted rotating feature batch,
      globally ranks semantic root causes above the alpha gate, requires
      an independently observed fail-before/pass-after proof on a fresh base,
      validates configured commands, and opens ready
      (non-draft) PRs for validated fixes (set patrol.draft_prs: true for
      draft PRs). By default, each opened patrol PR is also handed to the
      standard 6-review flow as a visible "Patrol: ..." task; set
      patrol.review_prs: false to keep PR-only output.

      Use --dry-run to map and review without creating fix worktrees,
      pushing branches, or opening PRs. With --json, emits
      hive-patrol.v2.
    DESC
    option :dry_run, type: :boolean, default: false,
                     desc: "map and review, but do not fix, push, or open PRs"
    def patrol(project)
      require "hive/commands/patrol"
      Hive::Commands::Patrol.new(
        project,
        json: options[:json],
        dry_run: options[:dry_run]
      ).call
    end

    desc "refactor-patrol PROJECT", "Discover ranked refactor theses for a registered project"
    long_desc <<~DESC
      Maps the registered project's repository into feature slices, asks the
      configured refactor-patrol agent for evidence-backed architecture
      theses, scores them by leverage, flags scope/guardrail risks, and emits
      a ranked report. v1 is reporting-only: it does not edit worktrees, open
      PRs, or enqueue review tasks.

      Scope hints use precedence --feature, then --entrypoint, then --path.
      With --changed-since alone, changed features are boosted but full
      discovery still runs; combined with a scope hint, changed files further
      restrict that scoped set. With --json, emits hive-refactor-patrol.v1.

      Use --pr with a merged PR number or URL to analyze only its immutable
      changed-path manifest from a clean registered default-branch checkout.
      PR mode requires --json, cannot be combined with legacy scope hints, and
      emits hive-refactor-patrol.v2 through an enforceable read-only agent.

      The daemon uses --actions with --job-manifest to resume the immutable
      per-thesis action ledger after discovery. It emits the same v2 contract.

      Use --list or --show JOB_ID to inspect the authoritative durable job
      ledger without enqueueing, claiming, replaying, or resuming work. With
      --json these operations emit hive-refactor-patrol-jobs.v1. List output is
      paginated with --limit/--cursor. Show output bounds retry/publication
      histories by --limit unless --full explicitly requests every entry.
    DESC
    option :dry_run, type: :boolean, default: false,
                     desc: "preview without persisting refactor-patrol state"
    option :feature, type: :string, desc: "only review matching mapped feature id"
    option :entrypoint, type: :string, desc: "only review the feature owning this entrypoint"
    option :path, type: :string, desc: "only review features with owned files under this path"
    option :changed_since, type: :string, desc: "git ref used for changed-feature ranking/filtering"
    option :pr, type: :string, desc: "analyze one merged PR number or URL with the v2 read-only contract"
    option :job_manifest, type: :string,
                          desc: "analyze one immutable merge-intake manifest (daemon/internal)"
    option :actions, type: :boolean, default: false,
                     desc: "resume actions for --job-manifest (daemon/internal)"
    option :result_file, type: :string,
                         desc: "write daemon completion envelope to a fenced result file (internal)"
    option :list, type: :boolean, default: false,
                  desc: "list durable architecture-patrol jobs without changing state"
    option :show, type: :string,
                  desc: "show one durable architecture-patrol job without changing state"
    option :limit, type: :numeric,
                   desc: "query page/history limit (1-100; default: 100)"
    option :cursor, type: :string,
                    desc: "continue a --list query from an opaque cursor"
    option :full, type: :boolean, default: false,
                  desc: "include complete unbounded histories with --show"
    def refactor_patrol(project)
      require "hive/commands/refactor_patrol"
      Hive::Commands::RefactorPatrol.new(
        project,
        json: options[:json],
        dry_run: options[:dry_run],
        feature: options[:feature],
        entrypoint: options[:entrypoint],
        path: options[:path],
        changed_since: options[:changed_since],
        pr: options[:pr],
        job_manifest: options[:job_manifest],
        actions: options[:actions],
        result_file: options[:result_file],
        list: options[:list],
        show: options[:show],
        limit: options[:limit],
        cursor: options[:cursor],
        full: options[:full]
      ).call
    end

    desc "digest", "Generate and send the daily shipped digest"
    # wrap: false so the Examples / Exit codes blocks keep their line breaks
    # instead of being reflowed into one paragraph.
    long_desc <<~DESC, wrap: false
      Collects tasks that shipped on the requested local calendar date
      across all registered projects, asks the configured digest agent to
      write friendly changelog lines, and sends a Telegram MarkdownV2 message
      (split into multiple messages when it exceeds Telegram's length limit)
      to the configured digest chat.

      Without --date, uses the local calendar day that just ended. Use
      --dry-run to print the composed message instead of sending Telegram.

      The run reports one of three outcomes (the `status` field with
      --json): `empty` — nothing shipped that day, so no agent runs and a
      short "nothing shipped" notice is sent; `sent` — a normal digest was
      categorized and delivered; `failed_notice` — the categorizer agent
      failed, so a short failure notice is sent instead (`ok` is false).

      With --json, emits the hive-digest (v1) envelope: a SuccessPayload
      (ok/status/date/dry_run/chat_id/message) for empty/sent/failed_notice,
      or an ErrorPayload (ok:false/error_kind/exit_code/message) for a bad
      --date (error_kind=config) or bad flags (error_kind=usage).

      The default source is the shipped-task digest described above. Use
      --source merged-prs to build a read-only GitHub report of pull requests
      merged on the requested local day. That source never mutates Hive state
      and uses a mechanical renderer instead of the digest agent. Add --repo
      owner/name to restrict the merged-PR report to one or more explicit
      repositories; --repo implies --source merged-prs.

      Examples:
        hive digest                          # yesterday, send to Telegram
        hive digest --date 2026-06-13        # a specific local day
        hive digest --dry-run                # print the composed message, send nothing
        hive digest --date 2026-06-13 --json # machine-readable hive-digest envelope
        hive digest --source merged-prs --dry-run
        hive digest --repo owner/name --repo other/repo --json

      Exit codes:
        0  empty / sent / failed_notice (a notice was delivered)
        78 bad --date or missing chat config (Hive::ConfigError)
        64 bad flags / malformed --json (Thor usage error)
        70 unexpected internal error
    DESC
    option :date, type: :string, desc: "local calendar date to digest (YYYY-MM-DD)"
    option :dry_run, type: :boolean, default: false, desc: "print the digest instead of sending Telegram"
    option :source, type: :string,
                    desc: "digest data source: 'merged-prs' for a GitHub merged-PR report (default: shipped Hive tasks)"
    # repeatable: true so a repeated `--repo a/b --repo c/d` accumulates
    # (Thor collects each occurrence into a nested array) instead of the last
    # flag silently overwriting the earlier ones — the space-listed form
    # `--repo a/b c/d` still works too. `.flatten` collapses both forms to a
    # flat list of owner/name slugs for the command.
    option :repo, type: :array, default: [], repeatable: true,
                  desc: "restrict merged-PR source to explicit owner/name repos (repeatable); implies --source merged-prs"
    def digest
      require "hive/commands/digest"
      Hive::Commands::Digest.new(
        date: options[:date],
        dry_run: options[:dry_run],
        json: options[:json],
        source: options[:source],
        repos: options[:repo].flatten
      ).call
    end

    desc "answer-digest", "Send a daily digest of tasks waiting on human input"
    # wrap: false so the Examples / Exit codes blocks keep their line breaks.
    long_desc <<~DESC, wrap: false
      Fetches the global hive status snapshot, filters it to tasks waiting on
      human input, and sends one Telegram message with inline buttons for each
      listed task. Empty snapshots are silent and still exit successfully.

      --date does NOT scope the waiting set (always the live snapshot) and does
      NOT dedup sends — it is only echoed into the JSON `date` field. Scheduler
      idempotency (once per local day) lives in the daemon's
      answer_digest_state.json, not this command.

      With --json, emits the hive-answer-digest (v1) envelope. The SuccessPayload
      carries `sent` (true only on a real send), `reason`
      (null=sent / "empty" / "dry_run"), `chat_id`, `button_count` (capped at the
      10-task display cap), `count` (the true waiting total), and `tasks[]` (one
      `{project,slug,id,title,stage,pr}` per waiting task, present even on a real
      send). The ErrorPayload carries `error_kind`: `config` (bad --date / missing
      chat), `status_unavailable` (status snapshot unusable — retryable),
      `usage` (bad flags), or `internal`.

      Agent read path: `--dry-run --json` is side-effect-free — it loads no .env,
      resolves no chat/token, and sends NOTHING to Telegram — so an agent may run
      it purely to READ the waiting set (count / tasks[]). Omitting --dry-run
      SENDS a Telegram message as a side effect.

      There is no `hive answer` verb for the brainstorm "answer" button an agent
      sees as an answer-waiting task: to clear one, an agent fills the matching
      `### A` slot in that task's brainstorm.md — the same edit the bot/web
      "Answer" button performs via BrainstormAnswerWriter.

      Examples:
        hive answer-digest
        hive answer-digest --date 2026-06-27 --json
        hive answer-digest --dry-run --json   # side-effect-free read

      Exit codes:
        0  sent / nothing waiting (empty is silent) / dry-run
        64 bad flags / malformed invocation (error_kind=usage)
        69 status snapshot unavailable (error_kind=status_unavailable, retryable)
        70 internal error (error_kind=internal)
        78 bad --date or missing chat config (error_kind=config)
    DESC
    option :date, type: :string,
                  desc: "local calendar date echoed into the JSON `date` field; does not scope data or dedup (YYYY-MM-DD)"
    option :dry_run, type: :boolean, default: false, desc: "print the digest instead of sending Telegram"
    def answer_digest
      require "hive/commands/answer_digest"
      Hive::Commands::AnswerDigest.new(
        date: options[:date],
        dry_run: options[:dry_run],
        json: options[:json]
      ).call
    end

    desc "status", "Show all active tasks across registered projects"
    long_desc <<~DESC
      Default: prints a grouped table of every task across registered
      projects, ordered by stage. Combine with --json to emit the
      `hive-status` envelope (schema v#{Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status")}); every row carries a required
      nullable `diagnostic` field — null for green rows, populated with
      a bounded summary + artifact tail + marker signature for red
      recovery/error rows, plus a nullable `pr_url` field — null until a
      PR exists, then the pull-request URL once one is opened. Each row also
      carries an optional `workflow` field — the descriptor id that resolved
      the task (e.g. "coding"); omitted on older/synthetic producers, where
      consumers should default to "coding".

      --diagnose <slug>: switch to the `hive-status-diagnose` envelope
      (schema v1) and emit the diagnostic for a single task. Useful
      for agents that want to inspect one row without paying the
      full snapshot cost. Pair with --project / --stage to disambiguate
      when the same slug exists across multiple projects or stages.

      --diagnose <slug> --write: spawn the project's configured execute
      AgentProfile to write `<task.folder>/diagnostics/red-status.md`,
      then return the path. The agent run is bounded (default 600s,
      $5 budget) and does NOT claim the task lock or touch markers.
      A freshness gate (marker_signature SHA256) refuses to write
      stale diagnoses when the marker rotates mid-spawn.

      --write requires --diagnose AND a task in a red recovery state
      (recover_review / error / recover_execute); green tasks emit a
      structured error rather than burning agent budget on a healthy
      row. When a previous agent-written artifact already matches the
      current marker_signature, --write short-circuits and returns
      the existing path without re-spawning; pass --force to bypass
      that idempotency check. Empty --diagnose values are rejected.
    DESC
    option :diagnose, type: :string, desc: "diagnose one red task slug or folder"
    option :project, type: :string, desc: "scope --diagnose slug lookup to one registered project"
    option :stage, type: :string,
                   desc: "scope --diagnose slug lookup to one stage (#{STAGE_VOCABULARY})"
    option :write, type: :boolean, default: false,
                   desc: "with --diagnose, write diagnostics/red-status.md using the configured execute agent"
    option :force, type: :boolean, default: false,
                   desc: "with --diagnose --write, re-spawn the agent even when a fresh agent-written artifact already exists"
    def status
      require "hive/commands/status"
      Hive::Commands::Status.new(
        json: options[:json],
        diagnose: options[:diagnose],
        project: options[:project],
        stage: options[:stage],
        write: options[:write],
        force: options[:force]
      ).call
    end

    desc "approve TARGET", "Move a task to the next stage (or --to <stage>); agent-callable equivalent of `mv`"
    long_desc <<~DESC
      TARGET is either a task folder path or a bare slug. A bare slug is
      resolved across registered projects; if the slug appears in two
      projects, pass --project to disambiguate. Multi-stage hits inside one
      project are also flagged as ambiguous — pass an absolute folder path.

      Forward auto-advance requires a terminal marker (:complete or
      :execute_complete). Use --to <stage> for an explicit destination
      (including backward moves for recovery), or --force to bypass the
      terminal-marker check.

      Pass --from <stage> on retry to assert the task is at the named stage
      before advancing — a previously successful call would fail with exit
      code 4 (WRONG_STAGE) instead of silently advancing a second stage.
    DESC
    option :to, type: :string,
                desc: "destination stage, full or short form; default: next stage (#{STAGE_VOCABULARY})"
    option :from, type: :string,
                  desc: "expected current stage; raises WRONG_STAGE on mismatch, idempotency (#{STAGE_VOCABULARY})"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :force, type: :boolean, default: false, desc: "skip terminal-marker check on forward move"
    def approve(target)
      require "hive/commands/approve"
      Hive::Commands::Approve.new(
        target,
        to: options[:to],
        from: options[:from],
        project: options[:project],
        force: options[:force],
        json: options[:json]
      ).call
    end

    desc "findings TARGET", "List findings in the latest reviews/ce-review-NN.md (or --pass N)"
    long_desc <<~DESC
      TARGET is either a 4-execute task folder path or a bare slug. Findings
      are GFM-checkbox lines in the review file written by the execute-stage
      reviewer; an unchecked `[ ]` finding is pending, a checked `[x]` will
      be re-injected into the next implementation pass via
      `Hive::Stages::Execute#collect_accepted_findings`.

      Use `hive accept-finding TARGET ID...` (or --all / --severity) to tick
      `[x]`, `hive reject-finding TARGET ID...` to untick.
    DESC
    option :pass, type: :numeric, desc: "review pass to inspect (default: latest on disk)"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :stage, type: :string,
                   desc: "scope slug lookup to one stage, default any (#{STAGE_VOCABULARY})"
    def findings(target)
      require "hive/commands/findings"
      Hive::Commands::Findings.new(
        target,
        pass: options[:pass],
        project: options[:project],
        stage: options[:stage],
        json: options[:json]
      ).call
    end

    desc "accept-finding TARGET [ID...]", "Tick `[x]` on review findings (toggle to accepted)"
    long_desc <<~DESC
      Toggle one or more review findings to `[x]` so they are re-injected
      into the next implementation pass. IDs are 1-based and listed by
      `hive findings`. Combine `ID...` positionals with `--severity high`
      (accept all of one severity) or `--all` (accept everything in the
      review file).
    DESC
    option :all, type: :boolean, default: false, desc: "accept every finding in the review file"
    option :severity, type: :string, enum: FINDING_SEVERITY_ENUM,
                      desc: "accept all findings of the given severity"
    option :pass, type: :numeric, desc: "review pass to edit (default: latest on disk)"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :stage, type: :string,
                   desc: "scope slug lookup to one stage, default any (#{STAGE_VOCABULARY})"
    def accept_finding(target, *ids)
      require "hive/commands/finding_toggle"
      Hive::Commands::FindingToggle.new(
        Hive::Commands::FindingToggle::ACCEPT,
        target, ids: ids, all: options[:all], severity: options[:severity],
                pass: options[:pass], project: options[:project], stage: options[:stage], json: options[:json]
      ).call
    end
    map "accept-finding" => :accept_finding

    desc "reject-finding TARGET [ID...]", "Untick `[x]` on review findings (toggle to rejected)"
    long_desc <<~DESC
      Inverse of `accept-finding`: returns a finding to the unchecked `[ ]`
      state so it is NOT re-injected into the next implementation pass.
      Same flags: positional IDs, `--severity`, `--all`.
    DESC
    option :all, type: :boolean, default: false, desc: "reject every finding in the review file"
    option :severity, type: :string, enum: FINDING_SEVERITY_ENUM,
                      desc: "reject all findings of the given severity"
    option :pass, type: :numeric, desc: "review pass to edit (default: latest on disk)"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :stage, type: :string,
                   desc: "scope slug lookup to one stage, default any (#{STAGE_VOCABULARY})"
    def reject_finding(target, *ids)
      require "hive/commands/finding_toggle"
      Hive::Commands::FindingToggle.new(
        Hive::Commands::FindingToggle::REJECT,
        target, ids: ids, all: options[:all], severity: options[:severity],
                pass: options[:pass], project: options[:project], stage: options[:stage], json: options[:json]
      ).call
    end
    map "reject-finding" => :reject_finding

    desc "markers SUBCOMMAND FOLDER", "Manage state-file markers (clear)"
    long_desc <<~DESC
      Subcommands:
        clear FOLDER --name <NAME>    Remove the named marker from the task's state file.

      Allowed marker names (recovery markers only):
        REVIEW_STALE  REVIEW_CI_STALE  REVIEW_ERROR  EXECUTE_STALE  ERROR

      Terminal-success markers (REVIEW_COMPLETE / EXECUTE_COMPLETE / COMPLETE)
      cannot be cleared this way — use `hive approve` to advance the task or
      move the folder backward via `hive approve --to <stage>`.

      Examples:
        hive markers clear FOLDER --name REVIEW_STALE
        hive markers clear my-task-slug --name REVIEW_CI_STALE --project myproj
        hive markers clear FOLDER --name REVIEW_ERROR --json
        hive markers clear FOLDER --name ERROR --match-attr marker_id=abc123
        hive markers clear FOLDER --name ERROR --match-attr reason=exit_code,exit_code=143

      Use --match-attr KEY=VALUE, or comma-separated KEY=VALUE pairs, to refuse
      the clear unless the current marker carries the named attributes. The TUI
      prefers generated ERROR marker_id attrs when available, with observed
      reason/exit_code attrs as the legacy fallback, so stale recovery workers
      cannot erase a fresh ERROR marker that landed between observation and heal.

      Exit codes: 0 success; 4 marker mismatch / attr mismatch / not in
      allowlist; 64 unknown subcommand or unknown task; 70 internal error.
    DESC
    option :name, type: :string, required: true,
                  desc: "marker name to remove (e.g. REVIEW_STALE)"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :match_attr, type: :string,
                        desc: "refuse clear unless marker has attr(s): KEY=VALUE[,KEY=VALUE]"
    def markers(subcommand, target = nil)
      require "hive/commands/markers"
      Hive::Commands::Markers.new(
        subcommand,
        target,
        name: options[:name],
        project: options[:project],
        match_attr: options[:match_attr],
        json: options[:json]
      ).call
    end

    desc "babysit SUBCOMMAND [PROJECT]", "Manage the experimental PR babysitter"
    long_desc <<~DESC
      Subcommands:
        start [--detach] [--dry-run]      Run the babysitter loop.
        stop                              Send SIGTERM to the running babysitter.
        restart [--detach] [--dry-run]   Stop then start the babysitter.
        status                            Show running / not-running.
        reload                            Send SIGHUP to reload config/log settings.
        tail                              Stream babysitter.log.

      One-shot:
        hive babysit --once PROJECT       Run one babysitter pass for PROJECT.
        hive babysit --once --all         Run one pass for every enabled project.

      The babysitter is separate from `hive daemon`. It walks open PRs in
      projects whose `.hive-state/config.yml` has `babysitter.enabled: true`
      and asks the configured development agent to keep them mergeable.
    DESC
    option :once, type: :boolean, default: false,
                  desc: "run one pass and exit; PROJECT positional required unless --all"
    option :detach, type: :boolean, default: false, desc: "fork to background after start"
    option :dry_run, type: :boolean, default: false,
                     desc: "run with babysitter dry-run side-effect guards"
    option :all, type: :boolean, default: false,
                 desc: "with --once, run one pass for every enabled project"
    def babysit(subcommand = nil, *targets)
      require "hive/commands/babysit"
      if options[:once] && Hive::Commands::Babysit::VALID_SUBCOMMANDS.include?(subcommand.to_s)
        raise Hive::InvalidTaskPath,
              "hive babysit: --once is a mode, not a modifier for #{subcommand.inspect}; " \
              "use `hive babysit --once PROJECT`"
      end
      if targets.length > 1
        raise Hive::InvalidTaskPath,
              "hive babysit #{subcommand}: too many positional arguments #{targets.inspect}; expected one PROJECT"
      end

      target = options[:once] ? (targets.first || subcommand) : targets.first
      Hive::Commands::Babysit.new(
        options[:once] ? nil : subcommand,
        target,
        detach: options[:detach],
        dry_run: options[:dry_run],
        once: options[:once],
        all: options[:all]
      ).call
    end

    desc "daemon SUBCOMMAND [PROJECT]", "Manage the hive daemon (start / stop / status / reload / tail / install / enable / disable / queue)"
    long_desc <<~DESC
      Subcommands:
        start [--detach] [--dry-run]      Run the dispatcher loop. Without
                                          --detach, runs in the foreground.
        stop [--json]                     Send SIGTERM to the running daemon.
                                          --json emits hive-daemon-stop.v1.
        status [--json]                   Show running / not-running.
        reload [--json]                   Send SIGHUP to reload config.
                                          --json emits hive-daemon-reload.v1.
        tail                              Stream daemon.log.
        install [--force] [--json]        (Re)write the platform-native unit
                                          file. Without --force, refuses to
                                          overwrite a pre-existing unit and
                                          exits 64 (USAGE). With --force,
                                          saves the previous file to a
                                          timestamped <path>.bak-<UTC-stamp>
                                          (never overwritten) and restarts
                                          the running daemon so new
                                          Environment= lines take effect.
                                          --json emits hive-daemon-install.v1.
        enable  PROJECT|--all [--json]    Set daemon.enabled: true in
                                          <project>/.hive-state/config.yml.
                                          --all = every registered project;
                                          --json emits hive-daemon-enroll.v1.
        disable PROJECT|--all [--json]    Set daemon.enabled: false there.
        queue [list|show <id>|prune]      Inspect the dispatch-request queue
                                          the bot writes and the daemon
                                          consumes. `list` (default) shows
                                          pending requests with age + verb;
                                          `show <id>` dumps one request;
                                          `prune` removes expired/malformed
                                          files. --json emits
                                          hive-daemon-queue.v1.

      The daemon polls `hive status --json` periodically and dispatches
      workflow verbs (`hive plan` / `develop` / `review` / `pr`) on tasks
      ready to advance, plus auto-archives the finalize stage after PR merge (gated on
      `gh pr view --json state`). Stops at human-input gates (waiting
      markers, recovery markers).

      Per-project enrollment is asked at `hive init` (default Y) for new
      projects; for projects that pre-date the daemon, run
      `hive daemon enable <project>` (or `--all`).

      Exit codes: 0 success; 1 daemon-not-running — `reload` exits 1 when
      no daemon is up (caller MUST start one first); `stop` is idempotent
      and exits 0 in the same condition (re-running stop is always safe);
      `status` exits 1 to make it scriptable as a precondition probe.
      64 (USAGE) for `enable`/`disable` against an
      unknown project, missing PROJECT, conflicting PROJECT+--all, or an
      uninitialised project; 70 (SOFTWARE) for uncategorised internal
      errors; 75 (TEMPFAIL) when `start` finds an existing live daemon;
      78 (CONFIG) when `enable`/`disable` reads malformed config.yml or
      rejects an inline-flow / non-2-space-indented `daemon:` block.

      `queue` exit codes: `list` and `prune` exit 0; `show <id>` exits 0
      when the request is found and 1 when it isn't; any `queue` action
      exits 64 (USAGE) on an unknown action or a missing `show` REQUEST_ID,
      and 70 (SOFTWARE) on an internal IO/parse error (the `--json`
      hive-daemon-queue.v1 error envelope carries the same `error_kind`).

      See `wiki/commands/daemon.md`, `wiki/operating.md`, and ADR-024.
    DESC
    option :detach, type: :boolean, default: false, desc: "fork to background after start"
    option :dry_run, type: :boolean, default: false,
                     desc: "log dispatch decisions without spawning real children"
    option :all, type: :boolean, default: false,
                 desc: "for enable/disable: apply to every registered project"
    option :force, type: :boolean, default: false,
                   desc: "for install: overwrite an existing unit (saves <path>.bak)"
    def daemon(subcommand = nil, *targets)
      require "hive/commands/daemon"
      # Argv-shape errors raise BEFORE Hive::Commands::Daemon.new, so
      # call_with_envelope inside the command can't catch them. Emit
      # the hive-daemon-enroll ErrorPayload inline under --json so
      # agents get the same structured envelope as in-command failures.
      if subcommand.nil?
        emit_daemon_argv_error(
          subcommand: nil,
          message: "hive daemon: missing SUBCOMMAND " \
                   "(expected: #{Hive::Commands::Daemon::VALID_SUBCOMMANDS.join(', ')})",
          error_kind: Hive::Schemas::EnrollErrorKind::MISSING_PROJECT
        )
      end
      # `queue` takes up to two positionals (ACTION + optional REQUEST_ID,
      # e.g. `queue show <id>`); every other subcommand takes at most one
      # (PROJECT or --all).
      max_targets = subcommand == "queue" ? 2 : 1
      if targets.length > max_targets
        message = if subcommand == "queue"
          "hive daemon queue: too many positional arguments #{targets.inspect}; " \
            "expected `queue [list|show <id>|prune]`"
        else
          "hive daemon #{subcommand}: too many positional arguments " \
            "#{targets.inspect}; expected exactly one PROJECT (or --all)"
        end
        if subcommand == "queue"
          emit_daemon_queue_argv_error(action: targets.first, message: message)
        else
          emit_daemon_argv_error(
            subcommand: subcommand,
            message: message,
            error_kind: Hive::Schemas::EnrollErrorKind::PROJECT_AND_ALL
          )
        end
      end
      if options[:force] && subcommand != "install"
        emit_daemon_argv_error(
          subcommand: subcommand,
          message: "hive daemon #{subcommand}: --force only applies to `install`; " \
                   "drop it or use `hive daemon install --force`",
          error_kind: Hive::Schemas::EnrollErrorKind::WRONG_SUBCOMMAND_FLAG
        )
      end
      Hive::Commands::Daemon.new(
        subcommand, targets.first,
        detach: options[:detach],
        dry_run: options[:dry_run],
        all: options[:all],
        json: options[:json],
        force: options[:force],
        queue_args: targets
      ).call
    end

    no_commands do
      # Emit a hive-daemon-enroll ErrorPayload to stdout when --json is
      # set, then raise so the bin/hive top-level rescue maps to the
      # right exit code. UsageError carries the closed error_kind so
      # the envelope matches every other --json failure on this surface.
      def emit_daemon_argv_error(subcommand:, message:, error_kind:)
        require "hive/commands/daemon"
        require "json"
        error = Hive::Commands::Daemon::UsageError.new(message, error_kind: error_kind)
        if options[:json]
          payload = Hive::Schemas::ErrorEnvelope.build(
            schema: "hive-daemon-enroll",
            error: error,
            error_kind: error_kind
          )
          begin
            puts JSON.generate(payload)
          rescue Errno::EPIPE, JSON::GeneratorError
            # caller went away or payload not serialisable — fall
            # through to the bare-text rescue path below.
          end
        else
          warn message
        end
        raise error
      end

      # `hive review` raises usage errors from inside the method body: the
      # optional TARGET (so `--pr` can stand alone) and the
      # both/neither-given checks surface as Hive::Error, not the Thor::Error
      # that bin/hive's JSON usage envelope keys on. Emit the same
      # hive-stage-action envelope StageAction emits for `hive review <slug>
      # --json` so every `hive review --json` failure stays symmetric, then
      # raise so bin/hive maps the exit code (and prints the stderr line).
      # AdhocReview and StageAction own their own envelopes, so neither is
      # wrapped by this helper — no double emit.
      def emit_review_usage_error(message)
        require "json"
        error = Hive::InvalidTaskPath.new(message)
        if options[:json]
          payload = Hive::Schemas::ErrorEnvelope.build(
            schema: "hive-stage-action",
            error: error,
            error_kind: "invalid_task_path",
            extras: { "verb" => "review" }
          )
          begin
            puts JSON.generate(payload)
          rescue Errno::EPIPE
            # caller went away — fall through to the bare-text rescue in bin/hive.
          rescue JSON::GeneratorError => e
            # A non-serialisable payload is a bug, not a closed pipe — surface
            # it rather than hide it (the bare-text rescue in bin/hive still
            # carries the failure for the exit code + stderr line).
            warn "[hive.review] review usage-error envelope was not serialisable: #{e.class}: #{e.message}"
          end
        end
        raise error
      end

      def emit_daemon_queue_argv_error(action:, message:)
        require "hive/commands/daemon"
        require "json"
        if options[:json]
          puts JSON.generate(
            "schema" => "hive-daemon-queue",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-daemon-queue"),
            "ok" => false,
            "action" => action,
            "error_kind" => "invalid_arguments",
            "message" => message
          )
        else
          warn message
        end
        raise Hive::InvalidTaskPath, message
      end

      def emit_bot_argv_error(message:, error_kind:)
        require "hive/commands/bot"
        require "json"
        error = Hive::InvalidTaskPath.new(message)
        if options[:json]
          payload = Hive::Commands::Bot.json_usage_error_payload(
            error: error,
            error_kind: error_kind
          )
          begin
            puts JSON.generate(payload)
          rescue Errno::EPIPE, JSON::GeneratorError
            nil
          end
        end
        raise error
      end
    end

    desc "bot SUBCOMMAND", "Manage the Telegram bot (start / stop / status / reload / tail / install)"
    long_desc <<~DESC
      Subcommands:
        start [--foreground] [--dry-run]  Run the Telegram long-poll bot in the background.
                                          Use --foreground for systemd/launchd/debugging.
        stop [--json]                     Send SIGTERM to the running bot.
                                          --json emits hive-bot-stop.v1.
        status [--json]                   Show running / not-running.
                                          --json emits hive-bot-status.v1.
        reload [--json]                   Send SIGHUP to reload bot config.
                                          --json emits hive-bot-reload.v1.
        tail                              Stream bot.log.
        install [--force] [--json]        (Re)write the platform-native unit
                                          file and enable autostart. Without
                                          --force, refuses to overwrite a
                                          pre-existing unit and exits 64
                                          (USAGE). With --force, saves the
                                          previous file to a timestamped
                                          <path>.bak-<UTC-stamp> (never
                                          overwritten) and restarts the
                                          running bot. Autostart is opt-in:
                                          `hive install` never touches it.
                                          --json emits hive-bot-install.v1;
                                          branch on its `outcome`
                                          (written/upgraded/unchanged/
                                          unsupported/drifted/failed) rather
                                          than parsing prose — on `drifted`,
                                          re-run with --force.

      The bot reads the global `bot:` block from ~/.config/hive/config.yml.
      Its Telegram token comes only from HIVE_TELEGRAM_BOT_TOKEN. Incoming
      updates from chat IDs outside bot.chat_id_allowlist are ignored.

      Exit codes: 0 success; 1 bot-not-running for status/reload; 64 usage
      (also `install` drift without --force — retry with --force); 70
      internal error (also `install` service-manager failure); 75 TEMPFAIL
      when start finds a live bot; 78 CONFIG when runtime config or
      HIVE_TELEGRAM_BOT_TOKEN is missing.
    DESC
    option :foreground, type: :boolean, default: false,
                        desc: "run in the foreground instead of backgrounding"
    option :detach, type: :boolean, default: false, hide: true,
                    desc: "deprecated; start already backgrounds by default"
    option :dry_run, type: :boolean, default: false,
                     desc: "log/send would-be actions without spawning child commands"
    option :force, type: :boolean, default: false,
                   desc: "for install: overwrite an existing unit (saves <path>.bak)"
    def bot(subcommand = nil)
      require "hive/commands/bot"
      if options[:foreground] && options[:detach]
        emit_bot_argv_error(
          message: "hive bot start: --detach is the default; do not combine it with --foreground",
          error_kind: "wrong_subcommand_flag"
        )
      end
      if options[:force] && subcommand != "install"
        emit_bot_argv_error(
          message: "hive bot #{subcommand}: --force only applies to `install`; " \
                   "drop it or use `hive bot install --force`",
          error_kind: "wrong_subcommand_flag"
        )
      end

      Hive::Commands::Bot.new(
        subcommand,
        foreground: options[:foreground],
        dry_run: options[:dry_run],
        json: options[:json],
        force: options[:force]
      ).call
    end

    desc "pairing SUBCOMMAND", "Approve Telegram pairing requests (list / approve)"
    long_desc <<~DESC
      Subcommands:
        list [--json]                         Show pending Telegram pairing requests.
                                              --json emits hive-pairing-list.v1.
        approve telegram <CODE> [--json]      Approve a pending Telegram pairing code.
                                              The platform argument is the fixed
                                              literal `telegram`.
                                              --json emits hive-pairing-approve.v1.

      Pairing requests are created when an unknown Telegram DM sends /start and
      bot.pairing_enabled is true. Approval appends the chat_id to the global
      bot.chat_id_allowlist, requests a live bot reload when a live bot PID is
      present, and queues an approval DM for the running bot to send.

      Exit codes: 0 success; 64 invalid arguments; 78 bad global bot config;
      1 is a catch-all for every other failure (unknown/expired code, but also
      a failed approval-notice write, an unreadable pairing store, or an
      internal error). With --json, branch on the `error_kind` field — not the
      exit code — to tell these apart (e.g. `unknown_code`, `expired_code`,
      `notice_write_failed`, `store_read_failed`, `internal_error`).
    DESC
    def pairing(subcommand = nil, *pairing_args)
      require "hive/commands/pairing"
      Hive::Commands::Pairing.new(
        subcommand,
        args: pairing_args,
        json: options[:json]
      ).call
    end

    desc "web [SUBCOMMAND]", "Run or manage the hive web UI"
    option :bind, type: :string, desc: "override web.bind"
    option :port, type: :numeric, desc: "override web.port"
    option :no_bootstrap, type: :boolean, default: false, desc: "do not install the managed web app if missing"
    option :unsafe, type: :boolean, default: false, desc: "allow non-loopback bind without configured owner"
    option :allow_public, type: :boolean, default: false, desc: "alias for --unsafe"
    option :force, type: :boolean, default: false, desc: "for install: overwrite existing service unit"
    option :detach, type: :boolean, default: false, desc: "for start: start the managed service instead of foreground Rails"
    def web(subcommand = nil)
      if options[:json]
        unless %w[install status].include?(subcommand.to_s)
          require "json"
          message = "hive web has no JSON output for foreground server commands. " \
                    "Use 'hive web status --json' or 'hive status --json'."
          puts JSON.generate(
            "ok" => false,
            "error_class" => "InvalidTaskPath",
            "error_kind" => "invalid_task_path",
            "exit_code" => Hive::ExitCodes::USAGE,
            "message" => message
          )
          raise Hive::InvalidTaskPath, message
        end
      end

      require "hive/commands/web"
      # Every option defaults to false/nil, so there is no present-vs-defaulted
      # distinction to preserve — pass them straight through (subcommand is nil
      # for the foreground server, which is the constructor's default).
      Hive::Commands::Web.new(
        subcommand,
        bind: options[:bind],
        port: options[:port],
        no_bootstrap: options[:no_bootstrap],
        unsafe: options[:unsafe] || options[:allow_public],
        force: options[:force],
        json: options[:json],
        detach: options[:detach]
      ).call
    end

    desc "tui", "Open the live, keystroke-driven dashboard for every active task"
    long_desc <<~DESC
      Opens a full-screen Charm bubbletea + lipgloss dashboard over `hive status`.
      Polls the same data source at 1Hz, groups rows by action label, and
      dispatches every workflow verb (`brainstorm` / `plan` / `develop` /
      `review` / `pr` / `archive`) as a fresh subprocess on a single
      keystroke. `?` inside the TUI opens the full per-mode keybinding
      cheatsheet; `q` quits.

      Modes (each with its own keymap):

        grid (default)
          b/p/d/r/P/F/a dispatch hive brainstorm/plan/develop/review/open-pr/finalize/archive
          j/k or Down/Up cursor up/down (jumps across projects at edges)
          Enter         contextual: agent_running opens log tail,
                        recoverable errors rerun, ready_* dispatches
          o             open the focused task folder in $EDITOR for browse-only inspection
          s             steer the focused task manually in the configured dev agent;
                        marks MANUAL_STEERING and archives it on agent exit
          n             open the new-idea prompt
          /             open the slug-filter prompt
          1-9           scope to the Nth registered project; 0 clears scope
          ?             open this help overlay
          q             quit

        log_tail (entered via Enter on agent_running / error rows)
          q / Esc       back to grid

        filter (entered via /)
          printable     append to the buffer
          Backspace     delete one char
          Enter         commit the typed buffer as the active filter
          Esc           cancel and clear the buffer (preserves any prior filter)

      Human-only — `hive tui --json` is rejected with EX_USAGE (64).
      Agent-callable surfaces stay JSON via `hive status` and the
      typed verbs.

      See `wiki/commands/tui.md` for modes, bindings, and limits.
    DESC
    def tui
      if options[:json]
        require "json"
        message = "hive tui has no JSON output (it is human-only). " \
                  "Use 'hive status --json' for the same data."
        # TUI does not have a registered hive-* schema; emit an envelope with the
        # standard error fields except `schema` so JSON consumers see structured
        # error data without a SCHEMA_VERSIONS bump.
        puts JSON.generate(
          "ok" => false,
          "error_class" => "InvalidTaskPath",
          # Match the error_kind value other InvalidTaskPath emit
          # sites use across the CLI (markers/findings/run/etc.) so
          # JSON consumers can switch on a single canonical value
          # rather than special-casing TUI's previous "unsupported_flag".
          "error_kind" => "invalid_task_path",
          "exit_code" => Hive::ExitCodes::USAGE,
          "message" => message
        )
        raise Hive::InvalidTaskPath, message
      end

      require "hive/tui"
      Hive::Tui.run
    end

    desc "metrics SUBCOMMAND", "Report metrics across registered projects (rollback-rate)"
    long_desc <<~DESC
      Subcommands:
        rollback-rate    Fraction of hive fix-agent commits later reverted.

      A high rollback rate signals the triage bias is too courageous for the
      project; a low rate validates the autonomous loop. Trailers emitted by
      fix-prompt / ci-fix-prompt templates (Hive-Fix-Pass, Hive-Triage-Bias,
      Hive-Fix-Phase) are the source of truth for what counts as a fix-agent
      commit.

      Examples:
        hive metrics rollback-rate
        hive metrics rollback-rate --days 30 --project writero --json

      --project NAME matches the 'name' field of a registered project (see
      hive status).
      --days N is a positive integer count of calendar days; the command
      walks 'git log --since="N days ago"'.

      Exit codes: 0 success; 64 unknown subcommand or project; 70 git failure.
    DESC
    option :days, type: :numeric, desc: "limit window to commits within N days"
    option :project, type: :string, desc: "scope to one registered project"
    def metrics(subcommand = "rollback-rate")
      require "hive/commands/metrics"
      Hive::Commands::Metrics.new(
        subcommand,
        days: options[:days],
        project: options[:project],
        json: options[:json]
      ).call
    end

    no_commands do
      def run_stage_action(verb, target)
        require "hive/commands/stage_action"
        kwargs = {
          project: options[:project],
          from: options[:from],
          json: options[:json]
        }
        reason = options[:recover_merged_error_reason]
        kwargs[:recover_merged_error_reason] = reason unless reason.nil?

        Hive::Commands::StageAction.new(
          verb,
          target,
          **kwargs,
          durable: true
        ).call
      end
    end
  end
end
