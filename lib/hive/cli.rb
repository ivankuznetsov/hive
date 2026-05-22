require "thor"
require "hive/stages"

module Hive
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    # `--json` is honoured by `status`, `run`, `approve`, `findings`,
    # `accept-finding`, `reject-finding`, and the workflow verbs
    # (`brainstorm`, `plan`, `develop`, `pr`, `archive`). `init` and `new`
    # accept the flag silently so an automated caller can pass it
    # uniformly. Each emitting command produces a typed JSON document on
    # success and a structured error envelope on every failure path.
    class_option :json, type: :boolean, default: false,
                        desc: "emit a single JSON document on stdout (commands that support it)"

    APPROVE_TO_ENUM = (Hive::Stages::DIRS + Hive::Stages::NAMES).freeze
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

      On a TTY, init asks the operator five questions before writing
      anything to disk:

        1. Planning agent (drives 2-brainstorm + 3-plan)         — default claude
        2. Brainstorm runtime for Claude                         — default headless
        3. Development agent (drives 4-execute)                  — default codex
        4. Review agents (multi-select over 3 default reviewers) — default all
        5. Per-stage budget+timeout (9 stage/role pairs)         — default generous

      Each prompt accepts a name (e.g. `codex`, `claude-ce-code-review`)
      OR a 1-based index. Blank input takes the default. Answer `n` at
      the final confirmation to abort with no disk side effects.

      On non-TTY (CI, pipes, scripted callers) the prompts are skipped
      and a one-line summary is emitted to stdout so the caller can see
      which defaults landed:

        hive: using defaults — planning=claude, claude_mode=tmux, dev=codex,
        reviewers=all3, triage=courageous, limits=defaults, daemon=enabled

      To set non-default values from automation, run init and then
      hand-edit `.hive-state/config.yml` (see `wiki/modules/config.md`
      for the schema). Piped STDIN is intentionally NOT consumed.

      Exit codes:
        0  — initialised successfully
        1  — generic / unexpected error
        2  — already initialised (`hive/state` branch already exists)
        64 — user aborted at the confirmation prompt

      See `wiki/commands/init.md` for the full prompt flow and ADR-023.
    DESC
    option :force, type: :boolean, default: false, desc: "skip clean-tree check"
    def init(project_path = Dir.pwd)
      require "hive/commands/init"
      Hive::Commands::Init.new(project_path, force: options[:force]).call
    end

    desc "forget NAME", "Remove a project from the global registry (inverse of `hive init`)"
    long_desc <<~DESC
      Drops the entry whose `name` matches NAME from ~/Dev/hive/config.yml.
      The project's .hive-state directory on disk (if any) is left alone.

      An unknown name is a USAGE error (64), mirroring `hive metrics
      --project NAME`. To bulk-remove every entry whose path no longer
      exists, use `hive prune` instead.

      Exit codes: 0 success; 64 unknown project / missing NAME positional;
      70 internal error; 78 bad config (malformed config.yml or typoed
      $HIVE_HOME).

      Examples:

        hive forget demo                  # remove the entry named 'demo'
        hive forget demo --json           # same, machine-readable envelope
        hive forget nonexistent --json    # error envelope w/ error_kind: unknown_project
    DESC
    def forget(name = nil)
      require "hive/commands/forget"
      Hive::Commands::Forget.new(name, json: options[:json]).call
    end

    desc "prune", "Drop registry entries whose project path no longer exists"
    long_desc <<~DESC
      Walks ~/Dev/hive/config.yml and removes every `registered_projects`
      entry whose `path` is not a directory on disk OR whose row shape is
      invalid (non-Hash, missing `path`, etc. — hand-edit accidents).
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

    desc "doctor", "Verify each stage's configured skill is installed for its agent"
    long_desc <<~DESC
      Walks the brainstorm and plan stage configs and asks the
      configured agent profile (claude / codex / pi) to probe whether
      its skill (`<stage>.skill` in config.yml) actually resolves to
      an installed slash-command or skill on disk.

      Hive ships expecting both llm-wiki (`/plan`) and
      compound-engineering (`/compound-engineering:ce-*`) to be
      installed alongside your agent CLI. `hive doctor` is the
      preflight that catches a missing install before a stage spawns
      and the agent reports `skill not found` mid-run.

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

      Exit codes: 0 all checks present or N/A; 65 at least one missing
      skill; 78 config error.

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

    desc "new PROJECT TEXT", "Create a new task in 1-inbox of PROJECT"
    def new_task(project, *text_parts)
      require "hive/commands/new"
      text = text_parts.join(" ")
      raise Hive::Error, "missing task text" if text.strip.empty?

      Hive::Commands::New.new(project, text).call
    end
    map "new" => :new_task

    desc "run TARGET", "Run the stage agent for TARGET (slug or task folder)"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :stage, type: :string, enum: APPROVE_TO_ENUM,
                   desc: "scope slug lookup to one stage (full '4-execute' or short 'execute')"
    option :no_rebase, type: :boolean, default: false,
                       desc: "skip the auto-rebase pre-step for this run only (one-off override of cfg.rebase.enabled)"
    def run_task(target)
      require "hive/commands/run"
      Hive::Commands::Run.new(
        target,
        project: options[:project],
        stage: options[:stage],
        json: options[:json],
        no_rebase: options[:no_rebase]
      ).call
    end
    map "run" => :run_task

    desc "rebase-status TARGET", "Print the auto-rebase status for TARGET without running anything (read-only)"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :stage, type: :string, enum: APPROVE_TO_ENUM,
                   desc: "scope slug lookup to one stage (full '4-execute' or short 'execute')"
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
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def brainstorm(target)
      run_stage_action("brainstorm", target)
    end

    desc "plan TARGET", "Move a completed brainstorm task into plan, or run an existing plan task"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def plan(target)
      run_stage_action("plan", target)
    end

    desc "develop TARGET", "Move a completed plan task into execute, or run an existing execute task"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def develop(target)
      run_stage_action("develop", target)
    end

    desc "open-pr TARGET", "Move a completed execute task into open-pr, or run an existing open-pr task"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def open_pr(target)
      run_stage_action("open-pr", target)
    end
    map "open-pr" => :open_pr
    map "pr" => :open_pr

    desc "review TARGET", "Move a completed open-pr task into review, or run an existing review task"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def review(target)
      run_stage_action("review", target)
    end

    desc "artifacts TARGET", "Move a completed review task into artifacts, or run an existing artifacts task"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def artifacts(target)
      run_stage_action("artifacts", target)
    end

    desc "finalize TARGET", "Move a completed artifacts task into finalize, or run an existing finalize task"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def finalize(target)
      run_stage_action("finalize", target)
    end

    desc "archive TARGET", "Move a completed finalize task into done, or run an existing done task"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def archive(target)
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
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; raises WRONG_STAGE on mismatch"
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

    desc "status", "Show all active tasks across registered projects"
    long_desc <<~DESC
      Default: prints a grouped table of every task across registered
      projects, ordered by stage. Combine with --json to emit the
      `hive-status` envelope (schema v2); every row carries a required
      nullable `diagnostic` field — null for green rows, populated with
      a bounded summary + artifact tail + marker signature for red
      recovery/error rows.

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
    option :stage, type: :string, enum: APPROVE_TO_ENUM,
                   desc: "scope --diagnose slug lookup to one stage"
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
    option :to, type: :string, enum: APPROVE_TO_ENUM,
                desc: "destination stage (full '3-plan' or short 'plan'); default: next stage"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; raises WRONG_STAGE on mismatch (idempotency)"
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
    option :stage, type: :string, enum: APPROVE_TO_ENUM,
                   desc: "scope slug lookup to one stage (default: any stage)"
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
    option :stage, type: :string, enum: APPROVE_TO_ENUM,
                   desc: "scope slug lookup to one stage (default: any stage)"
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
    option :stage, type: :string, enum: APPROVE_TO_ENUM,
                   desc: "scope slug lookup to one stage (default: any stage)"
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
        hive markers clear FOLDER --name ERROR --match-attr exit_code=143

      Use --match-attr KEY=VALUE to refuse the clear unless the current marker
      carries the named attribute. The auto-healer in `hive tui` uses this to
      avoid erasing a real-failure marker that landed between observation and
      heal under cross-process concurrency.

      Exit codes: 0 success; 4 marker mismatch / attr mismatch / not in
      allowlist; 64 unknown subcommand or unknown task; 70 internal error.
    DESC
    option :name, type: :string, required: true,
                  desc: "marker name to remove (e.g. REVIEW_STALE)"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    option :match_attr, type: :string,
                        desc: "refuse clear unless marker has the named attr (KEY=VALUE)"
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

    desc "daemon SUBCOMMAND [PROJECT]", "Manage the hive daemon (start / stop / status / reload / tail / install / enable / disable)"
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
      if targets.length > 1
        emit_daemon_argv_error(
          subcommand: subcommand,
          message: "hive daemon #{subcommand}: too many positional arguments " \
                   "#{targets.inspect}; expected exactly one PROJECT (or --all)",
          error_kind: Hive::Schemas::EnrollErrorKind::PROJECT_AND_ALL
        )
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
        force: options[:force]
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
    end

    desc "bot SUBCOMMAND", "Manage the Telegram bot (start / stop / status / reload / tail)"
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

      The bot reads the global `bot:` block from ~/.config/hive/config.yml.
      Its Telegram token comes only from HIVE_TELEGRAM_BOT_TOKEN. Incoming
      updates from chat IDs outside bot.chat_id_allowlist are ignored.

      Exit codes: 0 success; 1 bot-not-running for status/reload; 64 usage;
      70 internal error; 75 TEMPFAIL when start finds a live bot; 78 CONFIG
      when runtime config or HIVE_TELEGRAM_BOT_TOKEN is missing.
    DESC
    option :foreground, type: :boolean, default: false,
                        desc: "run in the foreground instead of backgrounding"
    option :detach, type: :boolean, default: false, hide: true,
                    desc: "deprecated; start already backgrounds by default"
    option :dry_run, type: :boolean, default: false,
                     desc: "log/send would-be actions without spawning child commands"
    def bot(subcommand = nil)
      require "hive/commands/bot"
      if options[:foreground] && options[:detach]
        raise Hive::InvalidTaskPath,
              "hive bot start: --detach is the default; do not combine it with --foreground"
      end

      Hive::Commands::Bot.new(
        subcommand,
        foreground: options[:foreground],
        dry_run: options[:dry_run],
        json: options[:json]
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
        Hive::Commands::StageAction.new(
          verb,
          target,
          project: options[:project],
          from: options[:from],
          json: options[:json]
        ).call
      end
    end
  end
end
