require "time"
require "digest"
require "fileutils"
require "hive/usage_db"

module Hive
  module Patrol
    # Project-wide patrol resource gate. Measured tokens and provider-agnostic
    # launch counts are both bounded so a backend that omits usage accounting
    # cannot turn a frequent patrol tier into an unlimited subscription drain.
    # Architecture work gets a larger cycle envelope without receiving a
    # separate daily pool, so it can inspect broad boundaries without evading
    # the project's shared subscription ceiling.
    class TokenBudget
      DEFAULT_LIMITS = {
        "max_tokens_per_cycle" => 200_000,
        "max_tokens_per_day" => 600_000,
        "max_tokens_per_agent" => 50_000,
        "max_agent_spawns_per_cycle" => 3,
        "max_agent_spawns_per_day" => 8,
        "max_budget_usd_per_agent" => 25,
        "architecture_budget_multiplier" => 2
      }.freeze

      attr_reader :last_exhaustion

      def initialize(project_root, cfg:, usage_db: Hive::UsageDb, clock: -> { Time.now.utc })
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @usage_db = usage_db
        @clock = clock
        patrol = cfg.fetch("patrol", {})
        @limits = DEFAULT_LIMITS.to_h do |key, fallback|
          [ key, patrol[key] || fallback ]
        end.freeze
        @cycle_tokens = 0
        @cycle_spawns = 0
        @cycle_unmetered_spawns = 0
      end

      def acquire(stage: "patrol", minimum_tokens: 0)
        unless acquire_launch_lock
          activity = today_activity
          reason = @launch_lock_error ? "budget_lock_unavailable" : "agent_in_flight"
          @last_exhaustion = exhaustion(reason, activity, stage)
          return false
        end

        activity = today_activity
        reason = exhaustion_reason(activity, stage)
        if reason
          @last_exhaustion = exhaustion(reason, activity, stage)
          release_launch_lock
          return false
        end

        available_tokens = available_tokens(activity, stage)
        if minimum_tokens > available_tokens
          @last_exhaustion = exhaustion(
            "insufficient_launch_headroom", activity, stage
          ).merge(required_tokens: minimum_tokens, available_tokens: available_tokens)
          release_launch_lock
          return false
        end

        @cycle_spawns += 1
        @last_exhaustion = nil
        true
      end

      def exhaustion_message
        detail = @last_exhaustion || exhaustion("unknown", today_activity, "patrol")
        headroom = ""
        if detail[:required_tokens]
          headroom = "required=#{detail.fetch(:required_tokens)} tokens, " \
                     "available=#{detail.fetch(:available_tokens)}; "
        end
        "patrol agent budget exhausted (#{detail.fetch(:reason)}; #{headroom}" \
          "cycle=#{detail.fetch(:cycle_tokens)}/#{detail.fetch(:max_tokens_per_cycle)} tokens, " \
          "today=#{detail.fetch(:today_tokens)}/#{detail.fetch(:max_tokens_per_day)} tokens, " \
          "spawns=#{detail.fetch(:cycle_spawns)}/#{detail.fetch(:max_agent_spawns_per_cycle)} cycle, " \
          "#{detail.fetch(:today_spawns)}/#{detail.fetch(:max_agent_spawns_per_day)} today)"
      end

      # Agent CLIs call this limit USD, but on subscription-backed providers it
      # is a budget-equivalent runaway guard rather than an additional charge.
      def max_budget_usd(configured, stage: "patrol")
        [ Float(configured), Float(@limits.fetch("max_budget_usd_per_agent")) ].min
      rescue ArgumentError, TypeError
        @limits.fetch("max_budget_usd_per_agent")
      end

      # Unlike cycle/day accounting, this limit is handed to the running agent
      # process and enforced from streamed usage events. Architecture receives
      # a larger token allowance, but not a looser native dollar-equivalent cap.
      def max_tokens(stage: "patrol")
        activity = today_activity
        available_tokens(activity, stage)
      end

      def record!(result:, profile:, stage:, started_at:)
        usage = result.is_a?(Hash) && result[:usage].is_a?(Hash) ? result[:usage] : {}
        input = integer(usage[:input])
        output = integer(usage[:output])
        cached = integer(usage[:cached])
        tokens = input + output + cached
        metered = tokens.positive?
        recorded_stage = metered ? stage : "#{stage}-unmetered"
        @cycle_tokens += tokens
        @cycle_unmetered_spawns += 1 unless metered

        model = usage[:model]
        model ||= result[:model] if result.is_a?(Hash)
        recorded = @usage_db.record!(
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
        @usage_store_failed = true unless recorded
        recorded
      rescue StandardError => e
        warn "[hive] patrol usage record failed: #{e.message}"
        false
      ensure
        release_launch_lock
      end

      def snapshot
        activity = today_activity
        {
          "limits" => @limits.dup,
          "cycle" => {
            "tokens" => @cycle_tokens,
            "agent_spawns" => @cycle_spawns,
            "unmetered_spawns" => @cycle_unmetered_spawns
          },
          "today" => stringify_keys(activity)
        }
      end

      private

      # Hold one advisory lock for the full lifetime of a patrol agent. This is
      # stronger than a best-effort token reservation: every worker recomputes
      # durable daily headroom only after the prior worker has recorded usage.
      # The kernel releases the lock automatically if a worker crashes.
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
        digest = ::Digest::SHA256.hexdigest(File.basename(@project_root))[0, 16]
        "#{@usage_db.path}.patrol-#{digest}.lock"
      end

      def today_activity
        @usage_db.patrol_activity(
          scope: { project_slug: File.basename(@project_root) }, now: now
        )
      end

      def exhaustion_reason(activity, stage)
        return "usage_store_unavailable" if @usage_store_failed || activity.fetch(:available) == false
        return "daily_token_limit" if activity.fetch(:tokens) >= @limits.fetch("max_tokens_per_day")
        if @cycle_tokens >= effective_limit("max_tokens_per_cycle", stage)
          return "cycle_token_limit"
        end
        if activity.fetch(:agent_spawns) >= @limits.fetch("max_agent_spawns_per_day")
          return "daily_agent_spawn_limit"
        end
        if @cycle_spawns >= effective_limit("max_agent_spawns_per_cycle", stage)
          return "cycle_agent_spawn_limit"
        end

        nil
      end

      def available_tokens(activity, stage)
        per_agent = effective_limit("max_tokens_per_agent", stage)
        cycle_remaining = effective_limit("max_tokens_per_cycle", stage) - @cycle_tokens
        daily_remaining = @limits.fetch("max_tokens_per_day") - activity.fetch(:tokens)
        [ per_agent, cycle_remaining, daily_remaining ].min
      end

      def exhaustion(reason, activity, stage)
        {
          reason: reason,
          stage: stage,
          cycle_tokens: @cycle_tokens,
          today_tokens: activity.fetch(:tokens),
          cycle_spawns: @cycle_spawns,
          today_spawns: activity.fetch(:agent_spawns),
          max_tokens_per_cycle: effective_limit("max_tokens_per_cycle", stage),
          max_tokens_per_day: @limits.fetch("max_tokens_per_day"),
          max_agent_spawns_per_cycle: effective_limit("max_agent_spawns_per_cycle", stage),
          max_agent_spawns_per_day: @limits.fetch("max_agent_spawns_per_day")
        }
      end

      def effective_limit(key, stage)
        value = @limits.fetch(key)
        return value unless architecture_stage?(stage)

        value * @limits.fetch("architecture_budget_multiplier")
      end

      def architecture_stage?(stage)
        stage.to_s.start_with?("refactor-patrol")
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

      def stringify_keys(hash)
        hash.to_h { |key, value| [ key.to_s, value ] }
      end
    end
  end
end
