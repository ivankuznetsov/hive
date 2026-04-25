require "json"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/git_ops"
require "hive/agent"
require "hive/stages"

module Hive
  module Commands
    class Run
      def initialize(folder, json: false)
        @folder = File.expand_path(folder)
        @json = json
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

      def report(task, result)
        marker = Hive::Markers.current(task.state_file)
        if @json
          report_json(task, result, marker)
        else
          report_text(task, result, marker)
        end
      end

      # Stable schema for agent / wrapper consumption. The closed set of
      # `next_action.kind` values is exported as Hive::Schemas::NextActionKind
      # so producer and tests share a single source of truth.
      def report_json(task, result, marker)
        payload = {
          "schema" => "hive-run",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-run"),
          "slug" => task.slug,
          "stage" => task.stage_name,
          "stage_index" => task.stage_index,
          "folder" => task.folder,
          "state_file" => task.state_file,
          "marker" => marker.name.to_s,
          "attrs" => marker.attrs,
          "commit_action" => result.is_a?(Hash) ? result[:commit] : nil,
          "next_action" => json_next_action(task, marker)
        }
        # The JSON payload is written to stdout *before* the raise. bin/hive
        # rescues Hive::Error and calls `exit(e.exit_code)`; Ruby's normal
        # interpreter shutdown flushes stdout via IO finalizers, so the
        # caller receives the full JSON document AND a non-zero exit code
        # (3, TASK_IN_ERROR) as a dual signal.
        puts JSON.generate(payload)
        raise Hive::TaskInErrorState, "stage recorded :error (#{marker.attrs.inspect})" if marker.name == :error
      end

      def json_next_action(task, marker)
        kind = Hive::Schemas::NextActionKind
        case marker.name
        when :waiting, :execute_waiting
          { "kind" => kind::EDIT, "target" => task.state_file, "rerun_with" => "hive run #{task.folder}" }
        when :complete
          approve_action(task, next_stage_dir(task))
        when :execute_complete
          approve_action(task, File.join(task.hive_state_path, "stages", "5-pr"))
        when :execute_stale
          { "kind" => kind::RECOVER_STALE,
            "instructions" => "edit reviews/, lower task.md frontmatter pass:, remove EXECUTE_STALE marker, re-run" }
        when :error
          { "kind" => Hive::Schemas::NextActionKind::NO_OP, "error" => marker.attrs }
        else
          { "kind" => Hive::Schemas::NextActionKind::NO_OP }
        end
      end

      # Emit an APPROVE action with `--from <stage>` so a retry after a
      # partial success fails with WRONG_STAGE (4) instead of advancing
      # twice. The `command` field is a copy-paste-executable shell line.
      def approve_action(task, dest_path)
        kind = Hive::Schemas::NextActionKind
        return { "kind" => kind::NO_OP, "reason" => "final_stage" } unless dest_path

        from_stage_dir = "#{task.stage_index}-#{task.stage_name}"
        {
          "kind" => kind::APPROVE,
          "slug" => task.slug,
          "from" => task.folder,
          "from_stage" => from_stage_dir,
          "to" => "#{dest_path}/",
          "to_stage" => File.basename(dest_path),
          "command" => "hive approve #{task.slug} --from #{from_stage_dir}"
        }
      end

      def report_text(task, _result, marker)
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
          raise Hive::TaskInErrorState, "stage recorded :error (#{marker.attrs.inspect})"
        end
      end

      def next_stage_dir(task)
        next_name = Hive::Stages.next_dir(task.stage_index)
        return nil unless next_name

        File.join(task.hive_state_path, "stages", next_name)
      end
    end
  end
end
