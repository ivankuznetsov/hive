require "thor"
require "hive/stages"

module Hive
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    # `--json` is honoured by `status`, `run`, and `approve`; other commands
    # accept the flag silently so an automated caller can pass it uniformly.
    class_option :json, type: :boolean, default: false,
                        desc: "emit a single JSON document on stdout (commands that support it)"

    APPROVE_TO_ENUM = (Hive::Stages::DIRS + Hive::Stages::NAMES).freeze

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

    desc "run FOLDER", "Run the stage agent for the task at FOLDER"
    def run_task(folder)
      require "hive/commands/run"
      Hive::Commands::Run.new(folder, json: options[:json]).call
    end
    map "run" => :run_task

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
  end
end
