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

    desc "init [PROJECT_PATH]", "Bootstrap .hive-state in a project (orphan hive/state branch)"
    option :force, type: :boolean, default: false, desc: "skip clean-tree check"
    def init(project_path = Dir.pwd)
      require "hive/commands/init"
      Hive::Commands::Init.new(project_path, force: options[:force]).call
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
    def run_task(target)
      require "hive/commands/run"
      Hive::Commands::Run.new(
        target,
        project: options[:project],
        stage: options[:stage],
        json: options[:json]
      ).call
    end
    map "run" => :run_task

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

    desc "review TARGET", "Move a completed execute task into review, or run an existing review task"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def review(target)
      run_stage_action("review", target)
    end

    desc "pr TARGET", "Move a completed review task into PR, or run an existing PR task"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def pr(target)
      run_stage_action("pr", target)
    end

    desc "archive TARGET", "Move a completed PR task into done, or run an existing done task"
    option :from, type: :string, enum: APPROVE_TO_ENUM,
                  desc: "expected current stage; use to disambiguate same-slug tasks"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def archive(target)
      run_stage_action("archive", target)
    end

    desc "status", "Show all active tasks across registered projects"
    def status
      require "hive/commands/status"
      Hive::Commands::Status.new(json: options[:json]).call
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

      Exit codes: 0 success; 4 marker mismatch / not in allowlist; 64 unknown
      subcommand or unknown task; 70 internal error.
    DESC
    option :name, type: :string, required: true,
                  desc: "marker name to remove (e.g. REVIEW_STALE)"
    option :project, type: :string, desc: "scope slug lookup to one registered project"
    def markers(subcommand, target = nil)
      require "hive/commands/markers"
      Hive::Commands::Markers.new(
        subcommand,
        target,
        name: options[:name],
        project: options[:project],
        json: options[:json]
      ).call
    end

    desc "tui", "Open the live, keystroke-driven dashboard for every active task"
    long_desc <<~DESC
      Opens a full-screen Charm bubbletea + lipgloss dashboard over `hive status`.
      Polls the same data source at 1Hz, groups rows by action label, and
      dispatches every workflow verb (`brainstorm` / `plan` / `develop` /
      `review` / `pr` / `archive`) as a fresh subprocess on a single
      keystroke. `?` shows the keybinding cheatsheet; `q` quits.

      Keystrokes: b/p/d/r/P/a dispatch the corresponding workflow verb on the highlighted task.

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
          "error_kind" => "unsupported_flag",
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
