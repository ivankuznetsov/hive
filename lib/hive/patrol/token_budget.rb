require "time"
require "digest"
require "fileutils"
require "hive/usage_db"

module Hive
  module Patrol
    # Per-agent emergency stop for ordinary and architecture Patrol. Scheduling,
    # concurrency, turn, and wall-clock limits live with their owning runtimes;
    # this guard only prevents one agent process from running away.
    #
    # UsageDb remains best-effort telemetry. It never decides whether the next
    # launch is admitted.
    class TokenBudget
      DEFAULT_MAX_TOKENS_PER_AGENT = 100_000_000

      attr_reader :last_exhaustion

      def initialize(project_root, cfg:, usage_db: Hive::UsageDb, clock: -> { Time.now.utc })
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @usage_db = usage_db
        @clock = clock
        @max_tokens_per_agent = cfg.dig("patrol", "max_tokens_per_agent") ||
                                DEFAULT_MAX_TOKENS_PER_AGENT
      end

      def acquire(minimum_tokens: 0)
        unless acquire_launch_lock
          reason = @launch_lock_error ? "launch_lock_unavailable" : "agent_in_flight"
          @last_exhaustion = { reason: reason }
          return false
        end

        if minimum_tokens > @max_tokens_per_agent
          @last_exhaustion = {
            reason: "insufficient_launch_headroom",
            required_tokens: minimum_tokens,
            available_tokens: @max_tokens_per_agent
          }
          release_launch_lock
          return false
        end

        @last_exhaustion = nil
        true
      end

      def exhaustion_message
        detail = @last_exhaustion || { reason: "unknown" }
        if detail[:required_tokens]
          return "patrol agent runaway ceiling is below its initial context " \
                 "(required=#{detail.fetch(:required_tokens)} tokens, " \
                 "available=#{detail.fetch(:available_tokens)})"
        end

        "patrol agent launch blocked (#{detail.fetch(:reason)})"
      end

      def resource_exhaustion
        detail = @last_exhaustion
        return nil unless detail

        if detail.fetch(:reason) == "insufficient_launch_headroom"
          return {
            reason: detail.fetch(:reason),
            limit: detail.fetch(:available_tokens).to_i,
            observed: detail.fetch(:required_tokens).to_i
          }
        end

        { reason: detail.fetch(:reason), limit: 1, observed: 1 }
      end

      def max_tokens
        @max_tokens_per_agent
      end

      def record!(result:, profile:, stage:, started_at:)
        usage = result.is_a?(Hash) && result[:usage].is_a?(Hash) ? result[:usage] : {}
        input = integer(usage[:input])
        output = integer(usage[:output])
        cached = integer(usage[:cached])
        metered = (input + output + cached).positive?
        recorded_stage = metered ? stage : "#{stage}-unmetered"

        model = usage[:model]
        model ||= result[:model] if result.is_a?(Hash)
        @usage_db.record!(
          agent: profile_name(profile, stage),
          model: model,
          project_slug: File.basename(@project_root),
          task_slug: stage,
          stage: recorded_stage,
          started_at: started_at,
          ended_at: now.iso8601,
          input: input,
          output: output,
          cached: cached
        )
      rescue StandardError => e
        warn "[hive] patrol usage record failed: #{e.message}"
        false
      ensure
        release_launch_lock
      end

      private

      # Hold one advisory lock for the full lifetime of a Patrol agent. The
      # daemon has wider concurrency controls; this lock prevents ordinary and
      # architecture Patrol from launching over each other inside one project.
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
        digest = ::Digest::SHA256.hexdigest(@project_root)[0, 16]
        "#{@usage_db.path}.patrol-#{digest}.lock"
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
