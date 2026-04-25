require "thor"

module Hive
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    # `--json` is honoured by `status` and `run`; other commands accept the
    # flag silently so an automated caller can pass it uniformly.
    class_option :json, type: :boolean, default: false,
                        desc: "emit a single JSON document on stdout (commands that support it)"

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
  end
end
