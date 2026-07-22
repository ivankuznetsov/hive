require "hive/completion_time"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/markers"
require "hive/task"
require "hive/task_action"
require "hive/task_meta"

module Hive
  # Bounded, idempotent producer-side migration for archived legacy tasks.
  # A discovered clock is returned only after metadata and its hive/state
  # commit both succeed; every failure therefore keeps the row visible.
  class CompletedAtBackfiller
    BATCH_SIZE = 100

    def initialize(history: Hive::CompletionTime::History.new, batch_size: BATCH_SIZE)
      @history = history
      @batch_size = batch_size
    end

    def call(tasks)
      Array(tasks).first(@batch_size).to_h do |task|
        [ task.folder, completed_at_for(task) ]
      end
    end

    def completed_at_for(task)
      stored = Hive::CompletionTime.parse(task.completed_at, warn_context: task.folder)
      return stored if stored
      return nil unless File.directory?(task.folder)

      Hive::Lock.with_commit_lock(task.hive_state_path) do
        Hive::Lock.with_task_lock(task.folder, slug: task.slug, op: "completed_at_backfill") do
          fresh = Hive::Task.new(task.folder)
          stored = Hive::CompletionTime.parse(fresh.completed_at, warn_context: fresh.folder)
          return stored if stored
          return nil unless archived?(fresh)

          persist_discovered_time(fresh)
        end
      end
    rescue Interrupt
      raise
    rescue StandardError => e
      warn "hive: completed_at backfill failed for #{task.folder}: #{e.class}: #{e.message}; keeping task visible"
      nil
    end

    private

    def archived?(task)
      marker = Hive::Markers.current(task.state_file)
      config = Hive::Config.load(task.project_root)
      Hive::TaskAction.for(task, marker, config: config).key == Hive::Schemas::TaskActionKind::ARCHIVED
    rescue Hive::Error, Psych::Exception, SystemCallError, IOError => e
      warn "hive: completed_at could not classify #{task.folder}: #{e.class}: #{e.message}; keeping task visible"
      false
    end

    def persist_discovered_time(task)
      discovered = Hive::CompletionTime.discover(task, history: @history)
      unless discovered
        warn "hive: completed_at has no credible source for #{task.folder}; keeping task visible"
        return nil
      end

      snapshot = Hive::TaskMeta.snapshot(task.folder)
      begin
        value = Hive::TaskMeta.write_completed_at_once(task.folder, discovered)
        commit(task)
        Hive::CompletionTime.parse(value)
      rescue Interrupt
        restore(task, snapshot)
        raise
      rescue StandardError => e
        begin
          restore(task, snapshot)
        rescue StandardError => rollback_error
          warn "hive: completed_at rollback failed for #{task.folder}: " \
               "#{rollback_error.class}: #{rollback_error.message}"
        end
        warn "hive: completed_at persistence failed for #{task.folder}: " \
             "#{e.class}: #{e.message}; keeping task visible"
        nil
      end
    end

    def commit(task)
      Hive::GitOps.new(task.project_root).hive_commit(
        stage_name: "#{task.stage_index}-#{task.stage_name}",
        slug: task.slug,
        action: "completed_at_backfilled",
        pathspecs: [ relative_meta_path(task) ]
      )
    end

    def restore(task, snapshot)
      Hive::TaskMeta.restore(task.folder, snapshot)
      Hive::GitOps.new(task.project_root).run_git!(
        "-C", task.hive_state_path, "add", "-A", "--", relative_meta_path(task)
      )
    end

    def relative_meta_path(task)
      File.join("stages", "#{task.stage_index}-#{task.stage_name}", task.slug, "meta.yml")
    end
  end
end
