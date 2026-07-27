require "json"
require "open3"
require "securerandom"
require "time"
require "hive/commands/approve"
require "hive/git_ops"
require "hive/lock"
require "hive/markers"
require "hive/task"
require "hive/task_action"
require "hive/task_meta"
require "hive/task_resolver"

module Hive
  module Commands
    # Apply one descriptor-declared outcome to a durable human workflow stage.
    # The decision identity is minted when the task enters the stage and carried
    # by its WAITING marker, so retries can distinguish the current visit from a
    # prior reject/return cycle without a second workflow language.
    class Decide
      include Hive::Schemas::EnvelopeEmitter

      RECORD_RE = /<!-- HIVE_DECISION_V1 (?<payload>\{.*\}) -->/.freeze
      DEFAULT_CLOCK = -> { Time.now.utc }
      SUCCESS_KEYS = %w[
        schema schema_version ok applied noop slug workflow from_stage outcome
        decision_id note decided_at completed artifact artifact_path to
        current_stage task_folder next_action
      ].freeze

      def self.latest_record(path)
        latest_record_from_content(read_state_file(path))
      end

      def self.latest_record_from_content(content)
        content.to_s.each_line.filter_map do |line|
          match = RECORD_RE.match(line)
          JSON.parse(match[:payload]) if match
        rescue JSON::ParserError
          nil
        end.last
      end

      def self.read_state_file(path, binary: false)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink?
          raise Hive::InvalidTaskPath,
                "human stage state file #{File.basename(path).inspect} must be a regular file, not a symlink"
        end

        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        body = File.open(path, flags) do |file|
          opened = file.stat
          unless opened.file? && opened.dev == stat.dev && opened.ino == stat.ino
            raise Hive::InvalidTaskPath,
                  "human stage state file #{File.basename(path).inspect} changed while opening it"
          end
          file.read
        end
        return body if binary

        body.force_encoding(Encoding::UTF_8)
        unless body.valid_encoding?
          raise Hive::InvalidTaskPath,
                "human stage state file #{File.basename(path).inspect} must contain valid UTF-8"
        end
        body
      rescue Errno::ENOENT
        nil
      rescue Errno::ELOOP, Errno::EMLINK
        raise Hive::InvalidTaskPath,
              "human stage state file #{File.basename(path).inspect} must be a regular file, not a symlink"
      end

      def initialize(target, outcome, from:, decision_id: nil, note: nil, project: nil, json: false,
                     clock: DEFAULT_CLOCK)
        @target = target
        @outcome_name = outcome.to_s.strip
        @from = from.to_s.strip
        @decision_id = decision_id.to_s.strip
        @note = note
        @project_filter = project
        @json = json
        @clock = clock
      end

      def call
        call_with_envelope { do_call }
      end

      def envelope_schema = "hive-decide"

      def envelope_error_kind(error)
        case error
        when Hive::WrongStage then "wrong_stage"
        when Hive::AmbiguousSlug then "ambiguous_slug"
        when Hive::InvalidTaskPath then "invalid_task_path"
        when Hive::ConcurrentRunError then "concurrent_run"
        when Hive::ConfigError then "config"
        when Hive::GitError then "git"
        when Hive::InternalError then "internal"
        else "error"
        end
      end

      def envelope_serialization_failure_policy = :raise

      private

      def do_call
        validate_arguments!
        task = resolve_task
        stage = resolve_human_stage!(task)
        outcome = resolve_outcome!(stage)
        state_body = self.class.read_state_file(File.join(task.folder, stage.state_file))
        record = self.class.latest_record_from_content(state_body)
        expected_dir = stage.dir
        actual_dir = "#{task.stage_index}-#{task.stage_name}"

        if actual_dir != expected_dir
          return emit_replay_or_stale!(task, stage, outcome, record)
        end

        marker = Hive::Markers.current_from_content(state_body)
        if marker.name == :waiting
          current_id = marker.attrs["decision_id"].to_s
          unless current_id.match?(/\A[0-9a-f]{16}\z/) && current_id == @decision_id
            return emit_same_or_conflicting!(task, stage, outcome, record) if
              current_record?(record, @decision_id)

            raise Hive::WrongStage.new(
              "decision observation is stale; task or decision identity changed",
              current_stage: actual_dir, target_stage: expected_dir
            )
          end
        elsif current_record?(record, @decision_id)
          return emit_same_or_conflicting!(task, stage, outcome, record)
        else
          raise Hive::WrongStage.new(
            "task #{task.slug} is not awaiting a decision at #{stage.dir}",
            current_stage: actual_dir, target_stage: expected_dir
          )
        end

        outcome.complete ? complete!(task, stage, outcome, @decision_id) : return_to_stage!(task, stage, outcome, @decision_id)
      end

      def validate_arguments!
        raise Hive::InvalidTaskPath, "--from must name the expected human stage" if @from.empty?
        unless @decision_id.match?(/\A[0-9a-f]{16}\z/)
          raise Hive::InvalidTaskPath,
                "--decision-id must be the 16-character identity reported for this human-stage visit"
        end
        raise Hive::InvalidTaskPath, "outcome must be a non-empty name" if @outcome_name.empty?
        return if @note.nil? || @note.is_a?(String)

        raise Hive::InvalidTaskPath, "--note must be text"
      end

      def resolve_task
        Hive::TaskResolver.new(@target, project_filter: @project_filter).resolve
      end

      def resolve_human_stage!(task)
        dir = task.workflow.resolve_stage_ref(@from) ||
              raise(Hive::InvalidTaskPath,
                    "unknown --from stage #{@from.inspect}; valid: #{task.workflow.stage_dirs.join(', ')}")
        stage = task.workflow.stage_for_dir(dir)
        return stage if stage.kind == :human

        raise Hive::InvalidTaskPath, "stage #{dir} is not a human stage"
      end

      def resolve_outcome!(stage)
        stage.outcomes[@outcome_name] ||
          raise(Hive::InvalidTaskPath,
                "unknown outcome #{@outcome_name.inspect} for #{stage.dir}; " \
                "allowed: #{stage.outcomes.keys.join(', ')}")
      end

      def current_record?(record, decision_id)
        record && !decision_id.empty? && record["decision_id"] == decision_id
      end

      def emit_replay_or_stale!(task, stage, outcome, record)
        if record && record["from"] == stage.name && record["decision_id"] == @decision_id
          return emit_same_or_conflicting!(task, stage, outcome, record)
        end

        raise Hive::WrongStage.new(
          "task is at #{task.stage_index}-#{task.stage_name} but --from expected #{stage.dir}",
          current_stage: "#{task.stage_index}-#{task.stage_name}", target_stage: stage.dir
        )
      end

      def emit_same_or_conflicting!(task, stage, outcome, record)
        unless record["outcome"] == outcome.name
          raise Hive::WrongStage.new(
            "decision #{record['decision_id']} already recorded #{record['outcome'].inspect}; " \
            "cannot apply conflicting outcome #{outcome.name.inspect}",
            current_stage: "#{task.stage_index}-#{task.stage_name}", target_stage: stage.dir
          )
        end

        emit_success(task, stage, outcome, record, applied: false)
      end

      def complete!(task, stage, outcome, decision_id)
        record = nil
        snapshot = nil
        meta_snapshot = nil
        ops = Hive::GitOps.new(task.project_root)

        Hive::Lock.with_commit_lock(task.hive_state_path) do
          begin
            Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "decide") do
              locked = Hive::Task.new(task.folder)
              locked_record = self.class.latest_record(File.join(locked.folder, stage.state_file))
              return emit_same_or_conflicting!(locked, stage, outcome, locked_record) if
                current_record?(locked_record, decision_id)

              validate_current_decision!(locked, stage, decision_id)
              artifact_path = File.join(locked.folder, outcome.artifact)
              validate_publishable_artifact!(artifact_path, locked.folder, stage, outcome)
              record = decision_record(
                locked, stage, outcome, decision_id,
                artifact_path: artifact_path, artifact_status: "publish_ready"
              )
              snapshot = snapshot_files(locked.folder, [ stage.state_file ])
              meta_snapshot = Hive::TaskMeta.snapshot(locked.folder)
              record["decided_at"] = Hive::TaskMeta.write_completed_at_once(
                locked.folder, Time.iso8601(record.fetch("decided_at"))
              )
              write_decision_record(File.join(locked.folder, stage.state_file), record)
            end
            ops.hive_commit(stage_name: stage.dir, slug: task.slug,
                            action: "decide #{stage.name} #{outcome.name}")
          rescue StandardError, Interrupt
            if snapshot
              restore_files(task.folder, snapshot)
              Hive::TaskMeta.restore(task.folder, meta_snapshot) if meta_snapshot
              restage_restored_files(
                task, snapshot, extra_names: meta_snapshot ? [ Hive::TaskMeta::FILENAME ] : []
              )
            end
            raise
          end
        end

        emit_success(task, stage, outcome, record, applied: true)
      end

      def validate_publishable_artifact!(artifact_path, task_folder, stage, outcome)
        expanded = File.expand_path(artifact_path)
        task_root = "#{File.expand_path(task_folder)}/"
        raise Hive::WrongStage, "artifact leaves the task folder" unless expanded.start_with?(task_root)

        stat = File.lstat(expanded)
        raise Hive::WrongStage, "artifact must be a regular task-local file" unless stat.file? && !stat.symlink?

        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        body = File.open(expanded, flags) do |file|
          opened = file.stat
          unless opened.file? && opened.dev == stat.dev && opened.ino == stat.ino
            raise Hive::WrongStage, "artifact identity changed while opening it"
          end

          file.read
        end
        publishable = body && !Hive::Markers.without_markers(body).strip.empty?
        return if publishable

        raise Hive::WrongStage.new(
          "outcome #{outcome.name.inspect} requires non-empty artifact #{outcome.artifact.inspect}",
          current_stage: stage.dir, target_stage: stage.dir
        )
      rescue Hive::WrongStage, SystemCallError, IOError
        raise Hive::WrongStage.new(
          "outcome #{outcome.name.inspect} requires non-empty artifact #{outcome.artifact.inspect}",
          current_stage: stage.dir, target_stage: stage.dir
        )
      end

      def return_to_stage!(task, stage, outcome, decision_id)
        target = task.workflow.stage_named(outcome.to)
        return repeat_stage!(task, stage, outcome, decision_id) if target.dir == stage.dir

        record = decision_record(task, stage, outcome, decision_id)
        snapshot = nil
        mutation = lambda do |locked|
          validate_current_decision!(locked, stage, decision_id)
          snapshot = snapshot_files(locked.folder, [ stage.state_file, target.state_file ])
          write_decision_record(File.join(locked.folder, stage.state_file), record)
          Hive::Markers.set(File.join(locked.folder, target.state_file), :waiting)
        end

        begin
          Hive::Lock.with_commit_lock(task.hive_state_path) do
            Hive::Commands::Approve.new(
              task.slug, to: target.dir, from: stage.dir, project: task.project_name,
              force: true, quiet: true, observation_guard: mutation, commit_lock: false
            ).call
          end
        rescue Hive::WrongStage => error
          folder = File.directory?(task.folder) ? task.folder : File.join(
            task.hive_state_path, "stages", target.dir, task.slug
          )
          restore_files(folder, snapshot) if snapshot
          replay = resolve_task
          replay_record = self.class.latest_record(File.join(replay.folder, stage.state_file))
          return emit_same_or_conflicting!(replay, stage, outcome, replay_record) if
            current_record?(replay_record, decision_id)

          raise error
        rescue StandardError, Interrupt
          folder = File.directory?(task.folder) ? task.folder : File.join(
            task.hive_state_path, "stages", target.dir, task.slug
          )
          restore_files(folder, snapshot) if snapshot
          raise
        end

        moved = Hive::Task.new(File.join(task.hive_state_path, "stages", target.dir, task.slug))
        emit_success(moved, stage, outcome, record, applied: true)
      end

      def repeat_stage!(task, stage, outcome, decision_id)
        record = decision_record(task, stage, outcome, decision_id)
        snapshot = nil
        ops = Hive::GitOps.new(task.project_root)

        Hive::Lock.with_commit_lock(task.hive_state_path) do
          begin
            Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "decide") do
              locked = Hive::Task.new(task.folder)
              locked_record = self.class.latest_record(File.join(locked.folder, stage.state_file))
              return emit_same_or_conflicting!(locked, stage, outcome, locked_record) if
                current_record?(locked_record, decision_id)

              validate_current_decision!(locked, stage, decision_id)
              snapshot = snapshot_files(locked.folder, [ stage.state_file ])
              state_path = File.join(locked.folder, stage.state_file)
              write_decision_record(state_path, record)
              Hive::Markers.set(
                state_path, :waiting, "decision_id" => SecureRandom.hex(8)
              )
            end
            ops.hive_commit(
              stage_name: stage.dir, slug: task.slug,
              action: "decide #{stage.name} #{outcome.name}"
            )
          rescue StandardError, Interrupt
            if snapshot
              restore_files(task.folder, snapshot)
              restage_restored_files(task, snapshot)
            end
            raise
          end
        end

        emit_success(Hive::Task.new(task.folder), stage, outcome, record, applied: true)
      end

      def validate_current_decision!(task, stage, decision_id)
        actual = "#{task.stage_index}-#{task.stage_name}"
        body = self.class.read_state_file(File.join(task.folder, stage.state_file))
        marker = Hive::Markers.current_from_content(body)
        return if actual == stage.dir && marker.name == :waiting && marker.attrs["decision_id"] == decision_id

        raise Hive::WrongStage.new(
          "decision observation is stale; task or decision identity changed",
          current_stage: actual, target_stage: stage.dir
        )
      end

      def decision_record(task, stage, outcome, decision_id, artifact_path: nil, artifact_status: nil)
        {
          "schema_version" => 1,
          "decision_id" => decision_id,
          "from" => stage.name,
          "outcome" => outcome.name,
          "note" => @note,
          "artifact" => outcome.artifact,
          "artifact_path" => artifact_path,
          "artifact_status" => artifact_status,
          "to" => outcome.to,
          "decided_at" => @clock.call.utc.iso8601
        }
      end

      def write_decision_record(path, record)
        Hive::Markers.with_markers_lock(path) do
          body = self.class.read_state_file(path) || ""
          complete = Hive::Markers.build_marker(
            "COMPLETE", "decision_id" => record.fetch("decision_id"), "outcome" => record.fetch("outcome")
          )
          updated, count = Hive::Markers.replace_last_marker(body, complete)
          updated = "#{updated}#{updated.end_with?("\n") || updated.empty? ? "" : "\n"}#{complete}\n" if count.zero?
          updated = "#{updated}#{updated.end_with?("\n") ? "" : "\n"}" \
                    "<!-- HIVE_DECISION_V1 #{JSON.generate(record)} -->\n"
          Hive::Markers.write_atomic(path, updated)
        end
      end

      def snapshot_files(folder, names)
        names.uniq.to_h do |name|
          path = File.join(folder, name)
          body = self.class.read_state_file(path, binary: true)
          [ name, { existed: !body.nil?, body: body } ]
        end
      end

      def restore_files(folder, snapshots)
        snapshots.each do |name, snapshot|
          path = File.join(folder, name)
          if snapshot.fetch(:existed)
            Hive::Markers.write_atomic(path, snapshot.fetch(:body))
          else
            File.delete(path) if File.exist?(path) || File.symlink?(path)
          end
        end
      end

      def restage_restored_files(task, snapshots, extra_names: [])
        ops = Hive::GitOps.new(task.project_root)
        (snapshots.keys + extra_names).uniq.each do |name|
          rel = File.join("stages", "#{task.stage_index}-#{task.stage_name}", task.slug, name)
          ops.run_git!("-C", task.hive_state_path, "add", "-A", "--", rel)
        end
      rescue Hive::GitError
        nil
      end

      def emit_success(task, stage, outcome, record, applied:)
        current_stage = "#{task.stage_index}-#{task.stage_name}"
        next_action = if outcome.complete
          { "kind" => Hive::Schemas::NextActionKind::NO_OP, "reason" => "workflow_complete" }
        else
          action = Hive::TaskAction.for(task, Hive::Markers.current(task.state_file))
          { "kind" => action.key, "command" => action.command }
        end
        payload = {
          "schema" => "hive-decide",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-decide"),
          "ok" => true,
          "applied" => applied,
          "noop" => !applied,
          "slug" => task.slug,
          "workflow" => task.workflow.id.to_s,
          "from_stage" => stage.dir,
          "outcome" => outcome.name,
          "decision_id" => record.fetch("decision_id"),
          "note" => record["note"],
          "decided_at" => record.fetch("decided_at"),
          "completed" => outcome.complete,
          "artifact" => record["artifact"],
          "artifact_path" => record["artifact_path"],
          "to" => record["to"],
          "current_stage" => current_stage,
          "task_folder" => task.folder,
          "next_action" => next_action
        }
        puts JSON.generate(SUCCESS_KEYS.to_h { |key| [ key, payload.fetch(key) ] }) if @json
        unless @json
          puts "hive: decided #{task.slug} #{stage.name}=#{outcome.name}"
          puts "  current_stage: #{current_stage}"
        end
        payload
      end
    end
  end
end
