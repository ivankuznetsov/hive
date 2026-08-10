require "hive/completion_time"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/markers"
require "hive/task"
require "hive/task_action"
require "hive/task_meta"
require "hive/atomic_file"
require "hive/paths"
require "digest"
require "json"

module Hive
  # Bounded, idempotent producer-side migration for archived legacy tasks.
  # A discovered clock is returned only after metadata and its hive/state
  # commit both succeed; every failure therefore keeps the row visible.
  class CompletedAtBackfiller
    BATCH_SIZE = 100
    REFRESH_DEADLINE_SECONDS = 1.0

    class CursorStore
      def initialize(root: File.join(Hive::Paths.state_home, "completed-at-backfill"))
        @root = root
      end

      def read(hive_state_path)
        with_lock(hive_state_path) do |path|
          JSON.parse(File.read(path)).fetch("last_folder", nil)
        rescue Errno::ENOENT, JSON::ParserError, TypeError
          nil
        end
      end

      def write(hive_state_path, folder)
        with_lock(hive_state_path) do |path|
          Hive::AtomicFile.write(
            path, "#{JSON.generate("last_folder" => folder)}\n", mode: 0o600, fsync: false
          )
        end
      rescue SystemCallError, IOError => e
        warn "hive: completed_at cursor update failed: #{e.class}: #{e.message}"
        nil
      end

      def rotating_batch(tasks, batch_size)
        ordered = Array(tasks).sort_by(&:folder)
        return [] if ordered.empty?

        with_lock(ordered.first.hive_state_path) do |path|
          last = begin
            JSON.parse(File.read(path)).fetch("last_folder", nil)
          rescue Errno::ENOENT, JSON::ParserError, TypeError
            nil
          end
          start = last ? ordered.index { |task| task.folder > last } || 0 : 0
          selected = ordered.rotate(start).first(batch_size)
          if selected.any?
            Hive::AtomicFile.write(
              path, "#{JSON.generate("last_folder" => selected.last.folder)}\n",
              mode: 0o600, fsync: false
            )
          end
          selected
        end
      rescue SystemCallError, IOError => e
        warn "hive: completed_at cursor rotation failed: #{e.class}: #{e.message}"
        ordered.first(batch_size)
      end

      private

      def with_lock(hive_state_path)
        key = Digest::SHA256.hexdigest(File.expand_path(hive_state_path))
        FileUtils.mkdir_p(@root)
        path = File.join(@root, "#{key}.json")
        File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield path
        end
      end
    end

    class << self
      def rotating_batch(tasks, batch_size, cursor_store: CursorStore.new)
        ordered = Array(tasks).sort_by(&:folder)
        return [] if ordered.empty?
        return cursor_store.rotating_batch(ordered, batch_size) if
          cursor_store.respond_to?(:rotating_batch)

        state = ordered.first.hive_state_path
        last = cursor_store.read(state)
        start = last ? ordered.index { |task| task.folder > last } || 0 : 0
        selected = ordered.rotate(start).first(batch_size)
        cursor_store.write(state, selected.last.folder) if selected.any?
        selected
      end

      def reset_progress! = nil
    end

    def initialize(history: nil, batch_size: BATCH_SIZE,
                   deadline_seconds: REFRESH_DEADLINE_SECONDS,
                   monotonic_clock: -> { Hive::Lock.monotonic_now },
                   cursor_store: CursorStore.new,
                   command_runner: Hive::CompletionTime::CommandRunner.new,
                   shared_refresh_deadline: false)
      @command_runner = command_runner
      @history = history || Hive::CompletionTime::History.new(
        command_runner: command_runner, monotonic_clock: monotonic_clock
      )
      @batch_size = batch_size
      @deadline_seconds = deadline_seconds
      @monotonic_clock = monotonic_clock
      @cursor_store = cursor_store
      @refresh_deadline =
        @monotonic_clock.call + @deadline_seconds if shared_refresh_deadline
    end

    def call(tasks)
      deadline = @refresh_deadline || (@monotonic_clock.call + @deadline_seconds)
      return {} if @monotonic_clock.call >= deadline

      self.class.rotating_batch(
        tasks, @batch_size, cursor_store: @cursor_store
      ).each_with_object({}) do |task, clocks|
        break clocks if @monotonic_clock.call >= deadline

        clocks[task.folder] = completed_at_for(task, deadline: deadline)
      end
    end

    def completed_at_for(task, deadline: nil)
      stored = Hive::CompletionTime.parse(task.completed_at, warn_context: task.folder)
      return stored if stored
      return nil unless File.directory?(task.folder)
      deadline ||= @refresh_deadline || (@monotonic_clock.call + @deadline_seconds)

      remaining = [ deadline - @monotonic_clock.call, 0 ].max
      Hive::Lock.with_commit_lock(task.hive_state_path, timeout: remaining) do
        return nil unless File.directory?(task.folder)

        Hive::Lock.with_task_lock(
          task.folder, { slug: task.slug, op: "completed_at_backfill" }, create: false
        ) do
          return nil unless File.directory?(task.folder)

          fresh = Hive::Task.new(
            task.folder, workflow_generation: task.workflow_generation
          )
          stored = Hive::CompletionTime.parse(fresh.completed_at, warn_context: fresh.folder)
          return stored if stored
          return nil unless archived?(fresh, config: task.workflow_generation&.config)

          persist_discovered_time(fresh, deadline: deadline)
        end
      end
    rescue Interrupt
      raise
    rescue StandardError => e
      warn "hive: completed_at backfill failed for #{task.folder}: #{e.class}: #{e.message}; keeping task visible"
      nil
    end

    private

    def archived?(task, config: nil)
      marker = Hive::Markers.current(task.state_file)
      config ||= Hive::Config.load(task.project_root)
      Hive::TaskAction.for(task, marker, config: config).key == Hive::Schemas::TaskActionKind::ARCHIVED
    rescue Hive::Error, Psych::Exception, SystemCallError, IOError => e
      warn "hive: completed_at could not classify #{task.folder}: #{e.class}: #{e.message}; keeping task visible"
      false
    end

    def persist_discovered_time(task, deadline:)
      discovered = Hive::CompletionTime.discover(
        task, history: @history, deadline: deadline, monotonic_clock: @monotonic_clock
      )
      unless discovered
        warn "hive: completed_at has no credible source for #{task.folder}; keeping task visible"
        return nil
      end

      snapshot = Hive::TaskMeta.snapshot(task.folder)
      begin
        ensure_before_deadline!(deadline)
        value = Hive::TaskMeta.write_completed_at_once(task.folder, discovered)
        ensure_before_deadline!(deadline)
        commit(task, deadline: deadline)
        Hive::CompletionTime.parse(value)
      rescue Interrupt
        restore(task, snapshot, deadline: cleanup_deadline(deadline))
        raise
      rescue StandardError => e
        begin
          restore(task, snapshot, deadline: cleanup_deadline(deadline))
        rescue StandardError => rollback_error
          warn "hive: completed_at rollback failed for #{task.folder}: " \
               "#{rollback_error.class}: #{rollback_error.message}"
        end
        warn "hive: completed_at persistence failed for #{task.folder}: " \
             "#{e.class}: #{e.message}; keeping task visible"
        nil
      end
    end

    def commit(task, deadline:)
      path = relative_meta_path(task)
      capture_git!(task, [ "add", "-A", "--", path ], deadline: deadline)
      diff = capture_git(
        task, [ "diff", "--cached", "--quiet", "--", path ], deadline: deadline
      )
      return :nothing_to_commit if diff.status.success?

      capture_git!(
        task,
        [
          "commit", "--only", "-m",
          "hive: #{task.stage_index}-#{task.stage_name}/#{task.slug} completed_at_backfilled",
          "--", path
        ],
        deadline: deadline
      )
      :committed
    end

    def restore(task, snapshot, deadline:)
      Hive::TaskMeta.restore(task.folder, snapshot)
      capture_git!(
        task, [ "add", "-A", "--", relative_meta_path(task) ], deadline: deadline
      )
    end

    def relative_meta_path(task)
      File.join("stages", "#{task.stage_index}-#{task.stage_name}", task.slug, "meta.yml")
    end

    def capture_git!(task, args, deadline:)
      result = capture_git(task, args, deadline: deadline)
      return result if result.status.success?

      detail = result.err.strip.empty? ? result.out : result.err
      raise Hive::GitError, "git #{args.first} failed in #{task.hive_state_path}: #{detail}"
    end

    def capture_git(task, args, deadline:)
      @command_runner.capture(
        [ "git", "-C", task.hive_state_path, *args ],
        deadline: deadline, monotonic_clock: @monotonic_clock
      )
    end

    def ensure_before_deadline!(deadline)
      return if @monotonic_clock.call < deadline

      raise Hive::CompletionTime::DeadlineExceeded, "completed_at backfill deadline exceeded"
    end

    def cleanup_deadline(deadline)
      [ deadline, @monotonic_clock.call + 0.1 ].max
    end
  end
end
