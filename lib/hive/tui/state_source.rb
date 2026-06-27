require "hive"
require "hive/archive_filter"
require "hive/commands/status"
require "hive/config"
require "hive/tui/snapshot"

module Hive
  module Tui
    # Background-thread poller for `hive status` JSON. Calls
    # `Hive::Commands::Status#json_payload` in-process at ~1 Hz, wraps
    # each successful payload in a Snapshot, and exposes the latest one
    # through `#current` for the render thread to read.
    #
    # The render thread reads `@current` without a Mutex. Under MRI's
    # GVL a pointer-sized reference assignment is atomic, so the reader
    # always sees either the previous Snapshot or the new one — never a
    # torn value. JRuby/TruffleRuby would need synchronisation; the boot
    # guard in `Hive::Tui.run` enforces MRI.
    #
    # On any StandardError during refresh the previous snapshot is held
    # and the failure is recorded in `@last_error` (overwritten each
    # retry; not a ring buffer, so the renderer only ever displays the
    # most recent error). The polling loop never crashes its own thread.
    class StateSource
      attr_reader :last_error, :current_seen_at

      # Upper bound on how long the mtime gate may reuse a cached
      # snapshot before forcing a full re-parse. The fingerprint only
      # tracks file mtimes, but some payload fields (`live_task_lock`,
      # `claude_pid_alive`) are derived from process liveness, which
      # flips without touching any file. Without this fallback a dead
      # lock holder's "live" indicator could never clear. The bound
      # keeps the indicator self-healing while still skipping most
      # idle-path parses.
      LIVENESS_REPARSE_FALLBACK_SECONDS = 3.0
      ARCHIVE_REFRESH_FALLBACK_SECONDS = 30.0

      def initialize(poll_interval_seconds: 1.0)
        @poll_interval_seconds = poll_interval_seconds
        @current = nil
        @current_seen_at = nil
        @last_error = nil
        @mtime_fingerprint = nil
        @last_full_parse_at = nil
        @last_active_payload = nil
        @archived_cache = empty_archived_cache
        @snapshot_archived_cache = @archived_cache
        @archive_dir_mtimes = {}
        @archive_last_refresh_at = nil
        @archive_refresh_dirty = false
        @archive_refresh_thread = nil
        @stop = false
        @thread = nil
      end

      # Latest Snapshot, or nil before the first successful poll.
      def current
        @current
      end

      # Synchronous refresh used during TUI boot to seed the first frame
      # before Bubbletea's input loop starts. The normal background
      # poller still owns subsequent refreshes.
      def refresh_now
        refresh_once
        current
      end

      def request_archive_refresh
        @archive_refresh_dirty = true
        nil
      end

      # Boots the polling thread. Idempotent: a second call while the
      # thread is alive is a no-op so accidental double-starts in test
      # setup don't leak threads.
      def start
        return if @thread&.alive?

        @stop = false
        @thread = Thread.new { poll_loop }
      end

      # Sets the stop sentinel and joins the thread with a 0.5s
      # deadline. The loop checks the sentinel between 0.05s sleep
      # slices so this returns fast enough for test teardown to assert
      # the thread is no longer in `Thread.list`.
      def stop
        @stop = true
        thread = @thread
        @thread = nil
        thread&.join(0.5)
        archive_thread = @archive_refresh_thread
        @archive_refresh_thread = nil
        archive_thread&.join(0.5)
        nil
      end

      # Boot state (no successful poll yet) counts as stalled so the
      # renderer can show a "loading" banner before the first frame.
      def stalled?(now: Time.now, threshold_seconds: 5.0)
        return true if @current_seen_at.nil?

        (now - @current_seen_at) > threshold_seconds
      end

      private

      def poll_loop
        until @stop
          refresh_once
          sleep_in_slices(@poll_interval_seconds)
        end
      end

      def refresh_once
        refresh_archive_signals(@current.projects) if @current
        request_archive_refresh if archive_refresh_due?
        start_archive_refresh_if_needed

        cache = @archived_cache
        cache_unchanged = cache.equal?(@snapshot_archived_cache)
        if @current && @mtime_fingerprint && cache_unchanged && mtime_fingerprint_unchanged? && !full_reparse_due?
          @current_seen_at = Time.now
          @last_error = nil
          return
        end

        projects = Hive::Config.registered_projects
        if @current.nil?
          payload = Hive::Commands::Status.new.json_payload(projects)
          @archived_cache = archived_cache_from_payload(payload)
          @archive_last_refresh_at = Time.now
          @last_active_payload = payload_without_archived_rows(payload)
          publish_snapshot(merge_archived_payload(@last_active_payload, @archived_cache),
                           archived_cache: @archived_cache)
          @archive_dir_mtimes = archive_dir_mtimes_for(@current.projects)
        else
          active_payload = Hive::Commands::Status.new.json_payload(
            projects,
            stages: active_stages,
            extra_dependency_tasks: archived_identities_from_cache(cache)
          )
          @last_active_payload = active_payload
          publish_snapshot(merge_archived_payload(active_payload, cache), archived_cache: cache)
          refresh_archive_signals(@current.projects)
          start_archive_refresh_if_needed
        end
      rescue StandardError => e
        @last_error = e
      end

      # Time-bounded fallback so the mtime gate can't mask liveness
      # state indefinitely (see LIVENESS_REPARSE_FALLBACK_SECONDS).
      def full_reparse_due?(now: Time.now)
        return true if @last_full_parse_at.nil?

        (now - @last_full_parse_at) >= LIVENESS_REPARSE_FALLBACK_SECONDS
      end

      def mtime_fingerprint_unchanged?
        return false if @mtime_fingerprint.empty?

        @mtime_fingerprint.all? do |path, previous_mtime|
          safe_mtime(path) == previous_mtime
        end
      end

      def mtime_fingerprint_for(snapshot)
        # Watch the global project registry too: `hive init`/`forget`
        # rewrite config.yml without touching any tracked state file,
        # so without this the gate would never see a project added or
        # removed and the displayed set would go stale indefinitely.
        paths = [ registry_config_path ]
        snapshot.projects.each do |project|
          paths.concat(project_watch_paths(project))
          project.rows.each do |row|
            next if archived_stage?(row.stage)

            paths << row.state_file
            # A runner can acquire the task lock before it writes
            # AGENT_WORKING, so the lock file is a status-affecting path.
            paths << File.join(row.folder, ".lock") if row.folder
          end
        end
        paths.compact.uniq.to_h { |path| [ path, safe_mtime(path) ] }
      end

      def registry_config_path
        Hive::Config.global_config_path
      rescue StandardError
        nil
      end

      def project_watch_paths(project)
        stages_dir = File.join(project.hive_state_path.to_s, "stages")
        [ stages_dir, *active_stages.map { |stage| File.join(stages_dir, stage) } ]
      end

      def safe_mtime(path)
        File.mtime(path) if path && File.exist?(path)
      rescue StandardError
        nil
      end

      def publish_snapshot(payload, archived_cache:)
        snapshot = Snapshot.from_payload(payload)
        @current = snapshot
        @current_seen_at = Time.now
        @last_full_parse_at = @current_seen_at
        @mtime_fingerprint = mtime_fingerprint_for(snapshot)
        @snapshot_archived_cache = archived_cache
        @last_error = nil
      end

      def active_stages
        Hive::Workflows.all_stage_dirs - [ Hive::ArchiveFilter::ARCHIVE_STAGE_DIR ]
      end

      def archived_stage?(stage)
        Hive::ArchiveFilter.archived?(stage)
      end

      def payload_without_archived_rows(payload)
        payload_with_filtered_tasks(payload) { |task| !archived_stage?(task["stage"]) }
      end

      def payload_with_filtered_tasks(payload)
        copy = payload.dup
        copy["projects"] = Array(payload["projects"]).map do |project|
          project_copy = project.dup
          project_copy["tasks"] = Array(project["tasks"]).select { |task| yield task }
          project_copy
        end
        copy
      end

      def merge_archived_payload(active_payload, archived_cache)
        cached_rows_by_path = archived_cache.fetch(:projects)
        copy = active_payload.dup
        copy["projects"] = Array(active_payload["projects"]).map do |project|
          project_copy = project.dup
          active_tasks = Array(project["tasks"])
          active_slugs = active_tasks.to_h { |task| [ task["slug"], true ] }
          cached_rows = project["error"] ? [] : cached_rows_by_path.fetch(project["path"], [])
          archived_rows = cached_rows.reject { |task| active_slugs.key?(task["slug"]) }
          project_copy["tasks"] = active_tasks + archived_rows
          project_copy
        end
        copy
      end

      def empty_archived_cache
        { projects: {}.freeze, identities: {}.freeze }.freeze
      end

      def archived_cache_from_payload(payload)
        projects = {}
        identities = {}
        Array(payload["projects"]).each do |project|
          path = project["path"]
          next unless path

          archived_rows = Array(project["tasks"]).select { |task| archived_stage?(task["stage"]) }
          frozen_rows = archived_rows.map { |task| task.dup.freeze }.freeze
          projects[path] = frozen_rows
          identities[path] = frozen_rows.map { |task| dependency_identity_for(task).freeze }.freeze
        end
        { projects: projects.freeze, identities: identities.freeze }.freeze
      end

      def dependency_identity_for(task)
        {
          "slug" => task["slug"],
          "id" => task["id"],
          "stage" => task["stage"]
        }
      end

      def archived_identities_from_cache(cache)
        cache.fetch(:identities)
      end

      def refresh_archive_signals(projects)
        mtimes = archive_dir_mtimes_for(projects)
        request_archive_refresh if @archive_dir_mtimes != mtimes
        @archive_dir_mtimes = mtimes
      end

      def archive_dir_mtimes_for(projects)
        Array(projects).to_h do |project|
          path = archive_dir_for(project)
          [ path, safe_mtime(path) ]
        end
      end

      def archive_dir_for(project)
        File.join(project.hive_state_path.to_s, "stages", Hive::ArchiveFilter::ARCHIVE_STAGE_DIR)
      end

      def archive_refresh_due?(now: Time.now)
        return false if @current.nil?
        return true if @archive_last_refresh_at.nil?

        (now - @archive_last_refresh_at) >= ARCHIVE_REFRESH_FALLBACK_SECONDS
      end

      def start_archive_refresh_if_needed(projects = nil)
        return unless @archive_refresh_dirty
        return if @current.nil? && projects.nil?
        return if @archive_refresh_thread&.alive?

        project_entries = projects || projects_from_snapshot(@current)
        @archive_refresh_dirty = false
        @archive_refresh_thread = Thread.new(project_entries) do |entries|
          refresh_archived_cache(entries)
        end
      end

      def projects_from_snapshot(snapshot)
        Array(snapshot&.projects).map do |project|
          {
            "name" => project.name,
            "path" => project.path,
            "hive_state_path" => project.hive_state_path
          }
        end
      end

      def refresh_archived_cache(projects)
        payload = Hive::Commands::Status.new.json_payload(
          projects,
          stages: [ Hive::ArchiveFilter::ARCHIVE_STAGE_DIR ]
        )
        @archived_cache = archived_cache_from_payload(payload)
        @archive_last_refresh_at = Time.now
      rescue StandardError => e
        warn "hive: tui archive refresh failed (#{e.class}: #{e.message})"
      end

      # Sleep in 0.05s slices so #stop joins quickly. Reading @stop
      # between slices is the same unsynchronised-reference-read pattern
      # the render thread uses on @current — safe under MRI's GVL.
      def sleep_in_slices(total_seconds)
        slice = 0.05
        elapsed = 0.0
        while elapsed < total_seconds && !@stop
          remaining = total_seconds - elapsed
          sleep(remaining < slice ? remaining : slice)
          elapsed += slice
        end
      end
    end
  end
end
