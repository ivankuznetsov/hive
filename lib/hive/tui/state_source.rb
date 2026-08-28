require "digest"
require "hive"
require "hive/commands/status"
require "hive/config"
require "hive/tui/debug"
require "hive/tui/io_capture"
require "hive/tui/snapshot"

module Hive
  module Tui
    # One active-task poller shared by the TUI and Web. Routine refreshes skip
    # inert terminal history. The lossless archive is fetched once, in a
    # background thread, only after the operator explicitly opens it.
    class StateSource
      attr_reader :current_seen_at

      LIVENESS_REPARSE_FALLBACK_SECONDS = 3.0
      STAT_ERROR_BREADCRUMB_THRESHOLD = 5

      # A fresh value on every failed stat keeps uncertainty from comparing as
      # unchanged. Do not add value equality to this marker.
      class StatError; end

      def initialize(poll_interval_seconds: 1.0)
        @poll_interval_seconds = poll_interval_seconds
        @current = nil
        @current_payload = nil
        @active_snapshot = nil
        @dependency_context_snapshot = nil
        @current_seen_at = nil
        @last_error = nil
        @archive_last_error = nil
        @mtime_fingerprint = nil
        @policy_fingerprint = nil
        @file_signature_cache = {}
        @stat_error_streaks = {}
        @last_active_parse_at = nil
        @archive_refresh_requested = false
        @archive_refresh_thread = nil
        @archive_refresh_generation = nil
        @archive_refresh_mutex = Mutex.new
        @publication_mutex = Mutex.new
        @stop = false
        @lifecycle_generation = 0
        @thread = nil
        @thread_generation = nil
      end

      def current
        @current
      end

      def last_error
        @last_error || @archive_last_error
      end

      def refresh_now
        refresh_once
        current
      end

      def refresh_payload_now
        refresh_once
        raise @last_error if @last_error

        @current_payload
      end

      def dependency_context_snapshot
        @dependency_context_snapshot
      end

      def request_archive_refresh
        @archive_refresh_mutex.synchronize do
          # An in-flight request already represents the freshest possible
          # archive. Coalesce repeated UI renders instead of queuing another
          # lossless registry scan behind it.
          current_refresh = @archive_refresh_thread&.alive? &&
                            @archive_refresh_generation == @lifecycle_generation
          @archive_refresh_requested = true unless current_refresh
        end
        start_archive_refresh_if_needed
        nil
      end

      def start
        return if @thread&.alive? && @thread_generation == @lifecycle_generation && !@stop

        previous_thread = @thread
        @stop = false
        @lifecycle_generation += 1
        generation = @lifecycle_generation
        @thread_generation = generation
        @thread = Thread.new(previous_thread, generation) do |previous, current|
          # A stopped scan may outlive stop's bounded join. Serialize the new
          # lifecycle behind it so two pollers never mutate the same caches,
          # then start a current-generation poller as soon as it exits.
          previous.join if previous&.alive?
          poll_loop(current)
        end
      end

      def stop
        @stop = true
        @lifecycle_generation += 1
        thread = @thread
        thread&.join(0.5)
        if thread && !thread.alive? && @thread.equal?(thread)
          @thread = nil
          @thread_generation = nil
        end
        archive_thread = @archive_refresh_mutex.synchronize do
          @archive_refresh_thread
        end
        archive_thread&.join(0.5)
        @archive_refresh_mutex.synchronize do
          if archive_thread && !archive_thread.alive? &&
             @archive_refresh_thread.equal?(archive_thread)
            @archive_refresh_thread = nil
            @archive_refresh_generation = nil
          end
        end
        nil
      end

      def stalled?(now: Time.now, threshold_seconds: 5.0)
        return true if @current_seen_at.nil?

        (now - @current_seen_at) > threshold_seconds
      end

      private

      def poll_loop(generation)
        while lifecycle_active?(generation)
          refresh_once(generation)
          sleep_in_slices(@poll_interval_seconds, generation)
        end
      end

      def refresh_once(generation = @lifecycle_generation)
        refresh_now = Time.now.utc
        policy_unchanged = @current && policy_fingerprint_for(@current) == @policy_fingerprint
        if @current && @mtime_fingerprint && policy_unchanged &&
           mtime_fingerprint_unchanged? && !active_reparse_due?(now: refresh_now)
          return unless lifecycle_active?(generation)

          @current_seen_at = refresh_now
          @last_error = nil
          start_archive_refresh_if_needed(generation)
          return
        end

        projects = Hive::Config.registered_projects
        admission_context, payload = capture_status_io do
          context = Hive::DependencySnapshot.active_admission_context(projects)
          [
            context,
            Hive::Commands::Status.new.active_payload(
              projects, admission_context: context, now: refresh_now
            )
          ]
        end
        publish_active_snapshot(
          payload, admission_context: admission_context, generation: generation
        )
        start_archive_refresh_if_needed(generation)
      rescue StandardError => e
        return unless lifecycle_active?(generation)

        Hive::Tui::Debug.log(
          "state_source", "refresh failed: #{e.class}: #{e.message}"
        )
        @last_error = e
      end

      def active_reparse_due?(now: Time.now)
        return true if @last_active_parse_at.nil?

        (now - @last_active_parse_at) >= LIVENESS_REPARSE_FALLBACK_SECONDS
      end

      def mtime_fingerprint_unchanged?
        return false if @mtime_fingerprint.empty?

        @mtime_fingerprint.all? do |path, previous_mtime|
          safe_mtime(path) == previous_mtime
        end
      end

      def mtime_fingerprint_for(snapshot)
        paths = [ registry_config_path ]
        snapshot.projects.each do |project|
          paths.concat(project_watch_paths(project))
        end
        snapshot.rows.each do |row|
          paths << row.folder
          paths << row.state_file
          paths << File.join(row.folder, ".lock") if row.folder
        end
        paths.compact.uniq.to_h { |path| [ path, safe_mtime(path) ] }
      end

      def registry_config_path
        Hive::Config.global_config_path
      rescue StandardError => e
        Hive::Tui::Debug.log(
          "state_source", "registry_config_path failed: #{e.class}: #{e.message}"
        )
        nil
      end

      def project_watch_paths(project)
        stages_dir = File.join(project.hive_state_path.to_s, "stages")
        occupied_active_stages = project.rows.filter_map do |row|
          File.dirname(row.folder) unless row.folder.to_s.empty?
        end
        [ stages_dir, *occupied_active_stages ].uniq
      end

      def policy_fingerprint_for(snapshot)
        content_paths = [ registry_config_path ]
        snapshot.projects.each do |project|
          content_paths.concat(project_policy_paths(project))
        end
        fingerprint = content_paths.compact.uniq.sort.to_h do |path|
          [ path, safe_content_signature(path, always_digest: true) ]
        end
        snapshot.rows.filter_map { |row| task_meta_path(row.folder) }.uniq.sort.each do |path|
          fingerprint[path] = safe_content_signature(path)
        end
        @file_signature_cache.delete_if { |path, _entry| !fingerprint.key?(path) }
        fingerprint
      end

      def project_policy_paths(project)
        hive_state = project.hive_state_path.to_s
        workflow_dir = File.join(hive_state, "workflows")
        descriptor_paths = Dir.glob(File.join(workflow_dir, "**", "*.yml")).sort
        [
          File.join(project.path.to_s, ".hive-state", "config.yml"),
          File.join(hive_state, "config.yml"),
          workflow_dir,
          *descriptor_paths
        ]
      rescue StandardError => e
        Hive::Tui::Debug.log(
          "state_source", "policy paths failed for #{project.path}: #{e.class}: #{e.message}"
        )
        [ File.join(hive_state, "workflows") ]
      end

      def task_meta_path(folder)
        File.join(folder.to_s, "meta.yml") unless folder.to_s.empty?
      end

      def safe_content_signature(path, always_digest: false)
        unless path && File.exist?(path)
          @file_signature_cache.delete(path) if path
          return :absent
        end

        stat = File.stat(path)
        identity = [
          stat.ftype, stat.size, stat.mtime.to_r, stat.ctime.to_r,
          (stat.ino if stat.respond_to?(:ino))
        ]
        cached = @file_signature_cache[path]
        if !always_digest && cached && cached.fetch(:identity) == identity
          return cached.fetch(:signature)
        end

        digest = if stat.file?
          Digest::SHA256.file(path).hexdigest
        elsif stat.directory?
          Dir.children(path).sort.join("\0")
        end
        signature = [ *identity, digest ].freeze
        @file_signature_cache[path] = { identity: identity, signature: signature }
        signature
      rescue StandardError => e
        [ :stat_error, e.class.name ].freeze
      end

      def safe_mtime(path)
        return nil unless path && File.exist?(path)

        mtime = File.mtime(path)
        @stat_error_streaks.delete(path)
        mtime
      rescue StandardError => e
        note_stat_error(path, e)
        StatError.new
      end

      def note_stat_error(path, error)
        streak = (@stat_error_streaks[path] || 0) + 1
        @stat_error_streaks[path] = streak
        return unless streak == STAT_ERROR_BREADCRUMB_THRESHOLD

        Hive::Tui::Debug.log(
          "state_source",
          "stat error persists (#{streak}x) for #{path}: #{error.class}: #{error.message}"
        )
      end

      def publish_active_snapshot(payload, admission_context: nil,
                                  generation: @lifecycle_generation)
        active_snapshot = Snapshot.from_payload(payload)
        next_mtime_fingerprint = mtime_fingerprint_for(active_snapshot)
        next_policy_fingerprint = policy_fingerprint_for(active_snapshot)
        published_at = Time.now

        @publication_mutex.synchronize do
          return unless lifecycle_active?(generation)

          # The archive refresher may have completed while the active payload
          # was being built. Compose against the latest archive at publication
          # time so neither thread can overwrite the other's newer half.
          snapshot = Snapshot.new(
            generated_at: active_snapshot.generated_at,
            projects: active_snapshot.projects,
            archive_projects: @current&.archive_projects || []
          )
          @current_payload = payload
          @active_snapshot = active_snapshot
          if admission_context
            @dependency_context_snapshot = {
              context: admission_context,
              fingerprint: Hive::DependencySnapshot.semantic_fingerprint(admission_context)
            }.freeze
          end
          @current_seen_at = published_at
          @last_active_parse_at = published_at
          @mtime_fingerprint = next_mtime_fingerprint
          @policy_fingerprint = next_policy_fingerprint
          @last_error = nil
          @current = snapshot
        end
      end

      def start_archive_refresh_if_needed(generation = @lifecycle_generation)
        @archive_refresh_mutex.synchronize do
          return unless lifecycle_active?(generation)
          return if !@archive_refresh_requested || @current.nil?
          return if @archive_refresh_thread&.alive?

          projects = projects_from_snapshot(@current)
          @archive_refresh_requested = false
          @archive_refresh_generation = generation
          @archive_refresh_thread = Thread.new(projects, generation) do |entries, current|
            refresh_archive(entries, generation: current)
          end
        end
      end

      def projects_from_snapshot(snapshot)
        registered = Hive::Config.registered_projects.group_by do |entry|
          File.expand_path(entry.fetch("path"))
        end
        Array(snapshot.projects).map do |project|
          matches = registered[File.expand_path(project.path)] || []
          registry_entry = matches.one? ? matches.first : nil
          {
            "name" => project.name,
            "path" => project.path,
            "hive_state_path" => project.hive_state_path,
            "repository_identity" => registry_entry && registry_entry["repository_identity"]
          }
        end
      end

      def refresh_archive(projects, generation: @lifecycle_generation)
        payload = capture_status_io do
          Hive::Commands::Status.new(archive: true).json_payload(
            projects, now: Time.now.utc
          )
        end
        return unless lifecycle_active?(generation)

        archive_projects = Snapshot.from_payload(payload).projects
        @publication_mutex.synchronize do
          return unless lifecycle_active?(generation)

          active_snapshot = @active_snapshot
          archive_projects = merge_archive_projects(
            @current&.archive_projects || [], archive_projects
          )
          @current = Snapshot.new(
            generated_at: active_snapshot.generated_at,
            projects: active_snapshot.projects,
            archive_projects: archive_projects
          ) if active_snapshot
          @archive_last_error = nil
        end
      rescue StandardError => e
        @publication_mutex.synchronize do
          return unless lifecycle_active?(generation)

          @archive_last_error = e
        end
        Hive::Tui::Debug.log(
          "state_source", "archive refresh failed: #{e.class}: #{e.message}"
        )
      end

      def merge_archive_projects(previous, fresh)
        previous_by_path = Array(previous).to_h do |project|
          [ File.expand_path(project.path.to_s), project ]
        end
        Array(fresh).map do |project|
          prior = previous_by_path[File.expand_path(project.path.to_s)]
          if project.error && prior
            project.with(rows: prior.rows)
          else
            project
          end
        end
      end

      def capture_status_io(&block)
        Hive::Tui::IoCapture.capture(&block)
      end

      def sleep_in_slices(total_seconds, generation = @lifecycle_generation)
        slice = 0.05
        elapsed = 0.0
        while elapsed < total_seconds && lifecycle_active?(generation)
          remaining = total_seconds - elapsed
          sleep(remaining < slice ? remaining : slice)
          elapsed += slice
        end
      end

      def lifecycle_active?(generation)
        !@stop && generation == @lifecycle_generation
      end
    end
  end
end
