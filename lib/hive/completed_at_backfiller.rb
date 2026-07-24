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
    REFRESH_DEADLINE_SECONDS = 1.0
    @progress_mutex = Mutex.new
    @last_folder_by_state = {}

    class << self
      attr_reader :progress_mutex, :last_folder_by_state

      def rotating_batch(tasks, batch_size)
        ordered = Array(tasks).sort_by(&:folder)
        return [] if ordered.empty?

        state = ordered.first.hive_state_path
        progress_mutex.synchronize do
          last = last_folder_by_state[state]
          start = last ? ordered.index { |task| task.folder > last } || 0 : 0
          selected = ordered.rotate(start).first(batch_size)
          last_folder_by_state[state] = selected.last.folder if selected.any?
          selected
        end
      end

      def reset_progress!
        progress_mutex.synchronize { last_folder_by_state.clear }
      end
    end

    def initialize(history: Hive::CompletionTime::History.new, batch_size: BATCH_SIZE,
                   deadline_seconds: REFRESH_DEADLINE_SECONDS,
                   monotonic_clock: -> { Hive::Lock.monotonic_now })
      @history = history
      @batch_size = batch_size
      @deadline_seconds = deadline_seconds
      @monotonic_clock = monotonic_clock
    end

    def call(tasks)
      deadline = @monotonic_clock.call + @deadline_seconds
      self.class.rotating_batch(tasks, @batch_size).each_with_object({}) do |task, clocks|
        break clocks if @monotonic_clock.call >= deadline

        clocks[task.folder] = completed_at_for(task, deadline: deadline)
      end
    end

    def completed_at_for(task, deadline: nil)
      stored = Hive::CompletionTime.parse(task.completed_at, warn_context: task.folder)
      return stored if stored
      return nil unless File.directory?(task.folder)
      deadline ||= @monotonic_clock.call + @deadline_seconds

      remaining = [ deadline - @monotonic_clock.call, 0 ].max
      Hive::Lock.with_commit_lock(task.hive_state_path, timeout: remaining) do
        return nil unless File.directory?(task.folder)

        Hive::Lock.with_task_lock(
          task.folder, { slug: task.slug, op: "completed_at_backfill" }, create: false
        ) do
          return nil unless File.directory?(task.folder)

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
