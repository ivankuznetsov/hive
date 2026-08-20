require "time"
require "digest"
require "fileutils"
require "securerandom"
require "hive/usage_db"

module Hive
  module Patrol
    # Project-wide launch gate shared by ordinary and Architecture Patrol.
    # Modes bound the number of agent processes started per UTC day; token
    # totals remain telemetry and never participate in admission.
    class LaunchBudget
      DAILY_EXHAUSTION_REASONS = %w[daily_agent_spawn_limit].freeze
      DEFAULT_MAX_AGENT_SPAWNS_PER_DAY = 8

      attr_reader :last_exhaustion

      def self.resource_exhaustion_backoff_sec(reasons, now:, fallback:)
        reasons = Array(reasons).map(&:to_s)
        return fallback unless reasons.any? &&
                               (reasons - DAILY_EXHAUSTION_REASONS).empty?

        current = now.utc
        next_day = Time.utc(current.year, current.month, current.day) + 86_400
        [ (next_day - current).ceil, 1 ].max
      end

      def initialize(project_root, cfg:, project_name: nil, usage_db: Hive::UsageDb,
                     clock: -> { Time.now.utc })
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @usage_db = usage_db
        @clock = clock
        @project_slug = project_name.to_s.strip
        @project_slug = fallback_project_slug if @project_slug.empty?
        @max_agent_spawns_per_day =
          cfg.dig("patrol", "max_agent_spawns_per_day") ||
          DEFAULT_MAX_AGENT_SPAWNS_PER_DAY
      end

      def acquire(profile:, stage:, started_at:)
        unless acquire_launch_lock
          reason = @launch_lock_error ? "launch_lock_unavailable" : "agent_in_flight"
          @last_exhaustion = exhaustion(reason, today_activity)
          return false
        end

        activity = today_activity
        reason = if @usage_store_failed || activity.fetch(:available) == false
          "usage_store_unavailable"
        elsif activity.fetch(:agent_spawns) >= @max_agent_spawns_per_day
          "daily_agent_spawn_limit"
        end
        if reason
          @last_exhaustion = exhaustion(reason, activity)
          release_launch_lock
          return false
        end

        unless reserve_launch!(profile: profile, stage: stage, started_at: started_at)
          @last_exhaustion = exhaustion("usage_store_unavailable", activity)
          release_launch_lock
          return false
        end

        @last_exhaustion = nil
        true
      end

      def remaining_launches
        activity = today_activity
        if @usage_store_failed || activity.fetch(:available) == false
          @last_exhaustion = exhaustion("usage_store_unavailable", activity)
          return 0
        end

        remaining = [ @max_agent_spawns_per_day - activity.fetch(:agent_spawns), 0 ].max
        @last_exhaustion = if remaining.zero?
          exhaustion("daily_agent_spawn_limit", activity)
        end
        remaining
      end

      def exhaustion_message
        detail = @last_exhaustion || exhaustion("unknown", today_activity)
        if detail.fetch(:reason) == "daily_agent_spawn_limit"
          return "patrol agent daily launch limit reached " \
                 "(#{detail.fetch(:observed)}/#{detail.fetch(:limit)} launches today)"
        end

        "patrol agent launch blocked (#{detail.fetch(:reason)})"
      end

      def resource_exhaustion
        detail = @last_exhaustion
        return nil unless detail

        {
          reason: detail.fetch(:reason),
          limit: detail.fetch(:limit),
          observed: detail.fetch(:observed)
        }
      end

      def record!(result:, profile:, stage:, started_at:)
        reservation = @active_reservation
        unless reservation
          @usage_store_failed = true
          warn "[hive] patrol usage record failed: missing launch reservation"
          return false
        end

        usage = result.is_a?(Hash) && result[:usage].is_a?(Hash) ? result[:usage] : {}
        input = integer(usage[:input])
        output = integer(usage[:output])
        cached = integer(usage[:cached])
        metered = (input + output + cached).positive?
        recorded_stage = metered ? stage : "#{stage}-unmetered"

        model = usage[:model]
        model ||= result[:model] if result.is_a?(Hash)
        recorded = @usage_db.record!(
          agent: profile_name(profile, stage),
          model: model,
          project_slug: @project_slug,
          task_slug: stage,
          stage: recorded_stage,
          started_at: started_at,
          ended_at: now.iso8601,
          input: input,
          output: output,
          cached: cached,
          attempt_id: reservation.fetch(:attempt_id),
          session_id: reservation.fetch(:session_id),
          task_generation: 0,
          source: "patrol_launch"
        )
        @usage_store_failed = true unless recorded
        recorded
      rescue StandardError => e
        @usage_store_failed = true
        warn "[hive] patrol usage record failed: #{e.message}"
        false
      ensure
        @active_reservation = nil
        release_launch_lock
      end

      private

      # Hold one advisory lock for the full lifetime of a Patrol agent so the
      # next lane observes the launch row before it computes daily headroom.
      def acquire_launch_lock
        return false if @launch_lock

        FileUtils.mkdir_p(File.dirname(launch_lock_path))
        handle = File.open(launch_lock_path, File::RDWR | File::CREAT, 0o600)
        unless handle.flock(File::LOCK_EX | File::LOCK_NB)
          handle.close
          return false
        end

        @launch_lock = handle
        @launch_lock_error = nil
        true
      rescue StandardError => e
        @launch_lock_error = e
        false
      end

      def release_launch_lock
        handle = @launch_lock
        @launch_lock = nil
        return unless handle

        handle.flock(File::LOCK_UN)
      rescue StandardError
        nil
      ensure
        handle&.close
      end

      def launch_lock_path
        digest = ::Digest::SHA256.hexdigest(@project_slug)[0, 16]
        "#{@usage_db.path}.patrol-#{digest}.lock"
      end

      def today_activity
        @usage_db.patrol_activity(
          scope: { project_slug: @project_slug }, now: now
        )
      end

      # Persist the launch before the provider child starts. If the controller
      # process dies, this unmetered row remains a consumed slot. A normal exit
      # updates the same session row with final token telemetry in #record!.
      def reserve_launch!(profile:, stage:, started_at:)
        session_id = "patrol-launch-#{SecureRandom.uuid}"
        attempt_id = session_id
        recorded = @usage_db.record!(
          agent: profile_name(profile, stage),
          model: nil,
          project_slug: @project_slug,
          task_slug: stage,
          stage: "#{stage}-unmetered",
          started_at: started_at,
          ended_at: nil,
          input: 0,
          output: 0,
          cached: 0,
          attempt_id: attempt_id,
          session_id: session_id,
          task_generation: 0,
          source: "patrol_launch"
        )
        unless recorded
          @usage_store_failed = true
          return false
        end

        @active_reservation = { attempt_id: attempt_id, session_id: session_id }
        true
      rescue StandardError => e
        @usage_store_failed = true
        warn "[hive] patrol launch reservation failed: #{e.message}"
        false
      end

      def fallback_project_slug
        digest = ::Digest::SHA256.hexdigest(@project_root)[0, 12]
        "#{File.basename(@project_root)}-#{digest}"
      end

      def exhaustion(reason, activity)
        {
          reason: reason,
          limit: reason == "daily_agent_spawn_limit" ? @max_agent_spawns_per_day : 1,
          observed: reason == "daily_agent_spawn_limit" ? activity.fetch(:agent_spawns) : 1
        }
      end

      def now
        value = @clock.call
        value.respond_to?(:utc) ? value.utc : Time.parse(value.to_s).utc
      end

      def profile_name(profile, stage)
        return profile.name.to_s if profile.respond_to?(:name)

        if stage.start_with?("refactor-patrol-fix")
          (@cfg.dig("refactor_patrol", "auto_fix", "agent") || "codex").to_s
        elsif stage.start_with?("refactor-patrol")
          (@cfg.dig("refactor_patrol", "agent") || "claude").to_s
        else
          (@cfg.dig("patrol", "agent") || "claude").to_s
        end
      end

      def integer(value)
        [ value.to_i, 0 ].max
      end
    end
  end
end
