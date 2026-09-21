require "securerandom"
require "time"
require "hive/config"
require "hive/runtime_control_plane"
require "hive/usage_db"

module Hive
  module Patrol
    class LaunchBudget
      ENGINES = %i[ordinary architecture].freeze
      DISCOVERY_STAGES = {
        "patrol-review" => :ordinary,
        "refactor-patrol-review" => :architecture
      }.freeze
      DAILY_EXHAUSTION_REASONS = %w[daily_agent_spawn_limit].freeze
      DEFAULT_MAX_AGENT_SPAWNS_PER_DAY = 4
      MAX_RESERVATION_ID_BYTES = 256

      attr_reader :last_exhaustion

      def self.resource_exhaustion_backoff_sec(reasons, now:, fallback:)
        reasons = Array(reasons).map(&:to_s)
        return fallback unless reasons.any? && (reasons - DAILY_EXHAUSTION_REASONS).empty?

        current = now.utc
        next_day = Time.utc(current.year, current.month, current.day) + 86_400
        [ (next_day - current).ceil, 1 ].max
      end

      def initialize(project_root, cfg:, project_id: nil, project_name: nil,
                     engine: nil, usage_db: Hive::UsageDb,
                     database: Hive::RuntimeControlPlane.database,
                     clock: -> { Time.now.utc }, id_generator: -> { SecureRandom.uuid },
                     charge_discovery: true)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @usage_db = usage_db
        @database = database
        @clock = clock
        @id_generator = id_generator
        @project_slug = present_or(project_name, File.basename(@project_root))
        @project_id = project_id.to_s.strip
        @project_id = nil if @project_id.empty?
        @engine = normalize_engine(engine) unless engine.nil?
        @charge_discovery = charge_discovery == true
        patrol = cfg.is_a?(Hash) && cfg["patrol"].is_a?(Hash) ? cfg.fetch("patrol") : {}
        mode = patrol["mode"].to_s
        @limit = if mode == "off"
          0
        else
          patrol["scheduled_discovery_launches_per_engine_per_day"] ||
            Hive::Config::PATROL_MODE_KNOBS.dig(
              mode, "scheduled_discovery_launches_per_engine_per_day"
            ) || DEFAULT_MAX_AGENT_SPAWNS_PER_DAY
        end
      end

      def acquire(profile:, stage:, started_at:, reservation_id: nil)
        engine = @charge_discovery ? stage_engine(stage) : nil
        @active_telemetry_source = engine ? "patrol_discovery_launch" : "patrol_non_discovery_launch"
        if engine && !reserve_discovery!(
          engine: engine, profile: profile, started_at: started_at,
          reservation_id: reservation_id || @id_generator.call
        )
          return false
        end

        reserve_telemetry!(profile: profile, stage: stage, started_at: started_at) unless engine
        true
      end

      def remaining_launches(engine: @engine || :ordinary)
        allowance_snapshot(engine: engine).fetch(:remaining)
      end

      def allowance_snapshot(engine: @engine || :ordinary)
        engine = normalize_engine(engine)
        project_id!
        current = now
        used = @usage_db.patrol_discovery_count(
          project_slug: @project_slug, stage: discovery_stage(engine),
          at: current, database: @database
        )
        remaining = [ @limit - used, 0 ].max
        if remaining.zero?
          @last_exhaustion = exhaustion("daily_agent_spawn_limit", used, engine: engine)
        else
          @last_exhaustion = nil
        end
        {
          engine: engine.to_s, utc_date: date_for(current), limit: @limit,
          used: used, remaining: remaining,
          status: remaining.zero? ? "exhausted" : "available", retry_at: nil
        }
      rescue StandardError => error
        @ledger_error = error
        @last_exhaustion = exhaustion("usage_store_unavailable", 1, engine: engine)
        {
          engine: engine.to_s, utc_date: date_for(now), limit: @limit,
          used: nil, remaining: 0, status: "unavailable", retry_at: nil
        }
      end

      def exhaustion_message
        detail = @last_exhaustion || exhaustion("unknown", 1, engine: @engine || :ordinary)
        case detail.fetch(:reason)
        when "daily_agent_spawn_limit"
          "#{detail.fetch(:engine)} patrol daily discovery launch limit reached " \
            "(#{detail.fetch(:observed)}/#{detail.fetch(:limit)} launches today)"
        else
          "#{detail.fetch(:engine)} patrol discovery launch blocked (#{detail.fetch(:reason)})"
        end
      end

      def resource_exhaustion
        @last_exhaustion&.slice(:reason, :limit, :observed, :engine, :retry_at)&.compact
      end

      def record!(result:, profile:, stage:, started_at:)
        reservation = @active_telemetry
        usage = result.is_a?(Hash) && result[:usage].is_a?(Hash) ? result[:usage] : {}
        input = integer(usage[:input])
        output = integer(usage[:output])
        cached = integer(usage[:cached])
        recorded_stage = (input + output + cached).positive? ? stage : "#{stage}-unmetered"
        identity = reservation || telemetry_identity
        model = usage[:model] || (result[:model] if result.is_a?(Hash))
        recorded = @usage_db.record!(
          agent: profile_name(profile, stage), model: model,
          project_slug: @project_slug, task_slug: stage, stage: recorded_stage,
          started_at: started_at, ended_at: now.iso8601,
          input: input, output: output, cached: cached,
          attempt_id: identity.fetch(:attempt_id), session_id: identity.fetch(:session_id),
          task_generation: 0,
          source: @active_telemetry_source || "patrol_non_discovery_launch"
        )
        warn "[hive] patrol usage record failed; discovery allowance is unchanged" unless recorded
        recorded
      rescue StandardError => error
        warn "[hive] patrol usage record failed: #{error.message}"
        false
      ensure
        @active_telemetry = nil
        @active_telemetry_source = nil
      end

      private

      def reserve_discovery!(engine:, profile:, started_at:, reservation_id:)
        id = reservation_id.to_s
        raise ArgumentError, "discovery reservation id is invalid" if
          id.empty? || id.bytesize > MAX_RESERVATION_ID_BYTES
        project_id!
        result = @usage_db.reserve_patrol_discovery!(
          session_id: id, agent: profile_name(profile, discovery_stage(engine)),
          project_slug: @project_slug, stage: discovery_stage(engine),
          started_at: started_at, limit: @limit, database: @database
        )
        unless result.fetch(:reserved)
          @last_exhaustion = exhaustion(
            "daily_agent_spawn_limit", result.fetch(:used), engine: engine
          )
          return false
        end

        @active_telemetry = { attempt_id: nil, session_id: id }
        @last_exhaustion = nil
        true
      rescue StandardError => error
        @ledger_error = error
        @last_exhaustion = exhaustion("usage_store_unavailable", 1, engine: engine)
        false
      end

      def reserve_telemetry!(profile:, stage:, started_at:)
        identity = telemetry_identity
        recorded = @usage_db.record!(
          agent: profile_name(profile, stage), model: nil,
          project_slug: @project_slug, task_slug: stage,
          stage: "#{stage}-unmetered", started_at: started_at, ended_at: nil,
          input: 0, output: 0, cached: 0,
          attempt_id: identity.fetch(:attempt_id), session_id: identity.fetch(:session_id),
          task_generation: 0,
          source: @active_telemetry_source || "patrol_non_discovery_launch"
        )
        @active_telemetry = identity if recorded
        warn "[hive] patrol usage reservation failed; continuing without token telemetry" unless recorded
        recorded
      rescue StandardError => error
        warn "[hive] patrol usage reservation failed: #{error.message}; continuing without token telemetry"
        false
      end

      def project_id!
        return @project_id if @project_id

        state_root = File.join(@project_root, ".hive-state")
        project = @database.read do |db|
          db[:projects].where(observed_path: @project_root).first ||
            db[:projects].where(state_root_path: state_root).first
        end
        @project_id = project&.fetch(:project_id, nil)
        return @project_id if @project_id

        raise Hive::RuntimeControlPlane::IdentityError.new(
          "Patrol project is not registered in the runtime control plane",
          code: :missing_project_identity,
          action: "enroll the project and rerun Patrol"
        )
      end

      def exhaustion(reason, observed, engine:, retry_at: nil)
        {
          reason: reason, limit: @limit, observed: observed,
          engine: engine.to_s, retry_at: retry_at
        }
      end

      def telemetry_identity
        id = "patrol-launch-#{@id_generator.call}"
        # A standalone Patrol launch is a telemetry session, not an Attempts
        # lifecycle row. Keep it unattributed so the control-plane foreign key
        # cannot manufacture an attempt identity that does not exist.
        { attempt_id: nil, session_id: id }
      end

      def profile_name(profile, stage)
        return profile.name.to_s if profile.respond_to?(:name)
        return (@cfg.dig("refactor_patrol", "auto_fix", "agent") || "codex").to_s if
          stage.start_with?("refactor-patrol-fix")
        return (@cfg.dig("refactor_patrol", "agent") || "claude").to_s if
          stage.start_with?("refactor-patrol")

        (@cfg.dig("patrol", "agent") || "claude").to_s
      end

      def stage_engine(stage)
        inferred = DISCOVERY_STAGES[stage.to_s]
        return nil unless inferred
        return inferred unless @engine
        raise ArgumentError, "discovery stage does not match configured engine" unless inferred == @engine
        inferred
      end

      def discovery_stage(engine)
        DISCOVERY_STAGES.key(engine) || raise(ArgumentError, "unknown Patrol engine #{engine.inspect}")
      end

      def normalize_engine(value)
        engine = value.to_sym
        raise ArgumentError, "unknown patrol discovery engine #{value.inspect}" unless ENGINES.include?(engine)
        engine
      end

      def now = normalize_time(@clock.call)
      def date_for(value) = normalize_time(value).strftime("%Y-%m-%d")
      def normalize_time(value) = value.respond_to?(:utc) ? value.utc : Time.parse(value.to_s).utc
      def integer(value) = [ Integer(value || 0), 0 ].max
      def present_or(value, fallback) = value.to_s.strip.empty? ? fallback.to_s : value.to_s.strip
    end
  end
end
