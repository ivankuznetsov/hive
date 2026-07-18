require "digest"
require "yaml"
require "hive/attempts/generation"
require "hive/attempts/process_identity"
require "hive/task"

module Hive
  module Attempts
    # Conservative migration for legacy task locks. A compatibility lease is
    # created only when task, live PID, and recorded start fingerprint agree.
    class LegacyBackfiller
      def initialize(store:, process_identity: ProcessIdentity.new, logger: nil,
                     projects: -> { Hive::Config.registered_projects })
        @store = store
        @process_identity = process_identity
        @logger = logger
        @projects = projects
      end

      def backfill(now: Time.now.utc)
        created = []
        @projects.call.each do |project|
          hive_state = project["hive_state_path"] || File.join(project.fetch("path"), ".hive-state")
          Dir.glob(File.join(hive_state, "stages", "*", "*", ".lock")).sort.each do |lock_path|
            record = backfill_lock(lock_path, project: project, now: now)
            created << record if record
          end
        end
        created
      end

      private

      def backfill_lock(lock_path, project:, now:)
        lock = YAML.safe_load(File.read(lock_path), permitted_classes: [ Time ])
        return nil unless lock.is_a?(Hash)
        return nil if lock["attempt_id"]

        expected = {
          "pid" => lock["pid"],
          "start_fingerprint" => lock["process_start_time"],
          "session_id" => lock["session_id"],
          "process_group_id" => lock["process_group_id"]
        }
        return nil unless @process_identity.status(expected) == :matching

        task = Hive::Task.new(File.dirname(lock_path))
        intended_stage = "#{task.stage_index}-#{task.stage_name}"
        generation = Generation.resolve(
          task: task, project: project.fetch("name"), intended_stage: intended_stage,
          attempt_store: @store
        )
        created = nil
        @store.with_admission_lock do
          @store.with_generation_lock(generation.task_generation) do
            existing = @store.scan.records.any? do |attempt|
              attempt.task_generation == generation.task_generation
            end
            next if existing

            created = @store.create_compatibility_running(
              attempt_id: compatibility_id(generation, expected),
              task_id: generation.task_id&.to_s,
              project: generation.project,
              task_slug: generation.task_slug,
              intended_stage: generation.intended_stage,
              task_generation: generation.task_generation,
              progress_token: generation.progress_token,
              owner: expected,
              provider: "legacy",
              starting_revision: starting_revision(task),
              now: now
            )
          end
        end
        if created && @logger
          @logger.event(
            :attempt_legacy_backfilled,
            attempt_id: created.attempt_id,
            task_generation: created.task_generation,
            project: created["project"], slug: created["task_slug"]
          )
        end
        created
      rescue Hive::Error, Psych::Exception, SystemCallError, KeyError
        nil
      end

      def compatibility_id(generation, identity)
        digest = ::Digest::SHA256.hexdigest(
          [ generation.task_generation, identity["pid"], identity["start_fingerprint"] ].join("\0")
        )
        "compat-#{digest[0, 24]}"
      end

      def starting_revision(task)
        path = task.worktree_path
        return nil unless path && File.directory?(path)

        IO.popen([ "git", "-C", path, "rev-parse", "HEAD" ], err: File::NULL, &:read).strip.then do |value|
          value.empty? ? nil : value
        end
      rescue SystemCallError
        nil
      end
    end
  end
end
