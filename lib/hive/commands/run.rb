require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/git_ops"
require "hive/agent"

module Hive
  module Commands
    class Run
      def initialize(folder)
        @folder = File.expand_path(folder)
      end

      def call
        task = Hive::Task.new(@folder)
        cfg = Hive::Config.load(task.project_root)

        Hive::Lock.with_task_lock(task.folder, slug: task.slug, stage: task.stage_name) do
          runner = pick_runner(task)
          result = runner.call(task, cfg)
          commit_after(task, result)
          report(task, result)
        end
      end

      def pick_runner(task)
        case task.stage_name
        when "inbox"
          require "hive/stages/inbox"
          Hive::Stages::Inbox.method(:run!)
        when "brainstorm"
          require "hive/stages/brainstorm"
          Hive::Stages::Brainstorm.method(:run!)
        when "plan"
          require "hive/stages/plan"
          Hive::Stages::Plan.method(:run!)
        when "execute"
          require "hive/stages/execute"
          Hive::Stages::Execute.method(:run!)
        when "pr"
          require "hive/stages/pr"
          Hive::Stages::Pr.method(:run!)
        when "done"
          require "hive/stages/done"
          Hive::Stages::Done.method(:run!)
        else
          raise StageError, "no runner for stage #{task.stage_name}"
        end
      end

      def commit_after(task, result)
        return unless result && result[:commit]

        ops = Hive::GitOps.new(task.project_root)
        Hive::Lock.with_commit_lock(task.hive_state_path) do
          ops.hive_commit(stage_name: "#{task.stage_index}-#{task.stage_name}",
                          slug: task.slug,
                          action: result[:commit])
        end
      end

      def report(task, _result)
        marker = Hive::Markers.current(task.state_file)
        puts "hive: marker=#{marker.name}"
        puts "  state_file: #{task.state_file}"
        case marker.name
        when :waiting, :execute_waiting
          puts "  next: edit the file, then `hive run #{task.folder}` again"
        when :complete
          next_stage = next_stage_dir(task)
          puts "  next: mv #{task.folder} #{next_stage}/" if next_stage
        when :execute_complete
          puts "  next: mv #{task.folder} #{File.join(task.hive_state_path, 'stages', '5-pr/')}"
        when :execute_stale
          puts "  next: edit reviews/, lower task.md frontmatter pass:, remove EXECUTE_STALE marker, re-run"
        when :error
          warn "  status: ERROR (#{marker.attrs.inspect})"
          exit 1
        end
      end

      def next_stage_dir(task)
        next_idx = task.stage_index + 1
        next_name = case next_idx
                    when 2 then "2-brainstorm"
                    when 3 then "3-plan"
                    when 4 then "4-execute"
                    when 5 then "5-pr"
                    when 6 then "6-done"
                    end
        return nil unless next_name

        File.join(task.hive_state_path, "stages", next_name)
      end
    end
  end
end
