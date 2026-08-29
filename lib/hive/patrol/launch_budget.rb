require "securerandom"
require "time"
require "hive/config"
require "hive/runtime_control_plane"
require "hive/usage_db"

module Hive
  module Patrol
    class LaunchBudget
      class SeedUnavailable < Hive::Error; end

      ENGINES = %i[ordinary architecture].freeze
      DISCOVERY_STAGES = {
        "patrol-review" => :ordinary,
        "refactor-patrol-review" => :architecture
      }.freeze
      DAILY_EXHAUSTION_REASONS = %w[daily_agent_spawn_limit legacy_attribution_ambiguous].freeze
      DEFAULT_MAX_AGENT_SPAWNS_PER_DAY = 4
      MAX_RESERVATION_ID_BYTES = 256
      MAX_RESERVATIONS_PER_LANE = 10_000

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
          engine: engine, started_at: started_at,
          reservation_id: reservation_id || @id_generator.call
        )
          return false
        end

        reserve_telemetry!(profile: profile, stage: stage, started_at: started_at)
        true
      end

      def remaining_launches(engine: @engine || :ordinary)
        allowance_snapshot(engine: engine).fetch(:remaining)
      end

      def allowance_snapshot(engine: @engine || :ordinary)
        engine = normalize_engine(engine)
        lane = ensure_lane(engine, date_for(now))
        hold = read_hold(engine)
        used = lane.fetch(:used)
        status = "available"
        remaining = [ @limit - used, 0 ].max
        retry_at = nil
        if retry_active?(hold)
          retry_at = hold.fetch(:retry_not_before)
          @last_exhaustion = exhaustion(
            "provider_lane_backoff", used, engine: engine, retry_at: retry_at
          )
          status = "provider_backoff"
          remaining = 0
        elsif lane.fetch(:seed_state) == "parked"
          @last_exhaustion = exhaustion("legacy_attribution_ambiguous", used, engine: engine)
          status = "legacy_attribution_ambiguous"
          remaining = 0
        elsif remaining.zero?
          @last_exhaustion = exhaustion("daily_agent_spawn_limit", used, engine: engine)
          status = "exhausted"
        else
          @last_exhaustion = nil
        end
        {
          engine: engine.to_s, utc_date: date_for(now), limit: @limit,
          used: used, remaining: remaining, status: status, retry_at: retry_at,
          seeded_launches: lane.fetch(:seeded_launches),
          ambiguous_legacy_rows: lane.fetch(:ambiguous_rows)
        }
      rescue StandardError => error
        @ledger_error = error
        @last_exhaustion = exhaustion("allowance_store_unavailable", 1, engine: engine)
        {
          engine: engine.to_s, utc_date: date_for(now), limit: @limit,
          used: nil, remaining: 0, status: "unavailable", retry_at: nil,
          seeded_launches: nil, ambiguous_legacy_rows: nil
        }
      end

      def park!(engine: @engine || :ordinary, retry_at:, reason:)
        engine = normalize_engine(engine)
        project_id!
        instant = normalize_time(retry_at)
        normalized_reason = reason.to_s.strip
        raise ArgumentError, "provider retry reason is invalid" if
          normalized_reason.empty? || normalized_reason.bytesize > 128

        timestamp = Hive::RuntimeControlPlane::Codec.dump_time(now)
        @database.transaction do |db|
          dataset = hold_dataset(db, engine)
          current = dataset.first
          current_retry = current && normalize_time(current.fetch(:retry_not_before))
          next if current_retry && current_retry >= instant

          dataset.insert_conflict(
            target: %i[project_id kind window_key],
            update: {
              retry_not_before: timestamp_for(instant), hold_reason: normalized_reason,
              revision: Sequel[:revision] + 1, updated_at: timestamp
            }
          ).insert(hold_row(engine, instant, normalized_reason, timestamp))
        end
        true
      rescue StandardError => error
        @ledger_error = error
        false
      end

      def clear_park!(engine: @engine || :ordinary)
        engine = normalize_engine(engine)
        project_id!
        @database.transaction { |db| hold_dataset(db, engine).delete }
        true
      rescue StandardError => error
        @ledger_error = error
        false
      end

      def exhaustion_message
        detail = @last_exhaustion || exhaustion("unknown", 1, engine: @engine || :ordinary)
        case detail.fetch(:reason)
        when "daily_agent_spawn_limit"
          "#{detail.fetch(:engine)} patrol daily discovery launch limit reached " \
            "(#{detail.fetch(:observed)}/#{detail.fetch(:limit)} launches today)"
        when "legacy_attribution_ambiguous"
          "#{detail.fetch(:engine)} patrol discovery is parked until the next UTC day " \
            "because legacy launch attribution is ambiguous"
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

      def reserve_discovery!(engine:, started_at:, reservation_id:)
        date = date_for(started_at)
        ensure_lane(engine, date)
        id = reservation_id.to_s
        raise ArgumentError, "discovery reservation id is invalid" if
          id.empty? || id.bytesize > MAX_RESERVATION_ID_BYTES

        @database.transaction do |db|
          row = lane_dataset(db, engine, date).first
          hold = hold_dataset(db, engine).first
          if retry_active?(hold, at: started_at)
            @last_exhaustion = exhaustion(
              "provider_lane_backoff", row.fetch(:used), engine: engine,
              retry_at: hold.fetch(:retry_not_before)
            )
            next false
          end
          if row.fetch(:seed_state) == "parked"
            @last_exhaustion = exhaustion(
              "legacy_attribution_ambiguous", row.fetch(:used), engine: engine
            )
            next false
          end
          ids = decode_ids(row.fetch(:reservation_ids_json))
          next true if ids.include?(id)
          if row.fetch(:used) >= @limit
            @last_exhaustion = exhaustion("daily_agent_spawn_limit", row.fetch(:used), engine: engine)
            next false
          end
          raise SeedUnavailable, "discovery reservations exceed the safety bound" if
            ids.length >= MAX_RESERVATIONS_PER_LANE

          ids << id
          lane_dataset(db, engine, date).update(
            used: row.fetch(:used) + 1,
            limit_value: [ @limit, row.fetch(:used) + 1 ].max,
            reservation_ids_json: Hive::RuntimeControlPlane::Codec.dump_json(ids),
            revision: row.fetch(:revision) + 1,
            updated_at: timestamp_for(normalize_time(started_at))
          )
          @last_exhaustion = nil
          true
        end
      rescue StandardError => error
        @ledger_error = error
        @last_exhaustion = exhaustion("allowance_store_unavailable", 1, engine: engine)
        false
      end

      def ensure_lane(engine, date)
        project_id!
        existing = @database.read { |db| lane_dataset(db, engine, date).first }
        return lane_from(existing) if existing

        seed = legacy_seed(date)
        raise SeedUnavailable, "legacy discovery seed is unavailable" unless seed
        lane_seed = seed.fetch(engine)
        count = lane_seed.fetch(:count)
        ambiguous = lane_seed.fetch(:ambiguous)
        raise SeedUnavailable, "legacy discovery seed exceeds the safety bound" if
          count > MAX_RESERVATIONS_PER_LANE
        ids = Array.new(count) { |index| "legacy:#{engine}:#{date}:#{index + 1}" }
        timestamp = timestamp_for(now)
        @database.transaction do |db|
          lane_dataset(db, engine, date).insert_conflict.insert(
            project_id: @project_id, kind: engine.to_s, window_key: date,
            used: count, limit_value: [ @limit, count ].max, revision: 0,
            reservation_ids_json: Hive::RuntimeControlPlane::Codec.dump_json(ids),
            seed_state: ambiguous.positive? ? "parked" : "complete",
            seeded_launches: count, ambiguous_rows: ambiguous,
            updated_at: timestamp
          )
          lane_from(lane_dataset(db, engine, date).first)
        end
      end

      def legacy_seed(date)
        return empty_seed unless @usage_db.respond_to?(:patrol_discovery_seed)
        result = @usage_db.patrol_discovery_seed(scope: { project_slug: @project_slug }, date: date)
        return nil unless result.is_a?(Hash) && result[:available] != false
        ENGINES.to_h do |engine|
          value = result.fetch(engine, {})
          [ engine, { count: integer(value[:count]), ambiguous: integer(value[:ambiguous]) } ]
        end
      rescue StandardError
        nil
      end

      def empty_seed = ENGINES.to_h { |engine| [ engine, { count: 0, ambiguous: 0 } ] }

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

      def lane_dataset(db, engine, date)
        db[:patrol_allowances].where(
          project_id: @project_id, kind: engine.to_s, window_key: date
        )
      end

      def hold_dataset(db, engine)
        db[:patrol_allowances].where(
          project_id: @project_id, kind: "#{engine}:hold", window_key: "provider"
        )
      end

      def hold_row(engine, instant, reason, timestamp)
        {
          project_id: @project_id, kind: "#{engine}:hold", window_key: "provider",
          used: 0, limit_value: 0, revision: 0, retry_not_before: timestamp_for(instant),
          hold_reason: reason, updated_at: timestamp
        }
      end

      def read_hold(engine)
        row = @database.read { |db| hold_dataset(db, engine).first }
        row && { retry_not_before: row.fetch(:retry_not_before), reason: row[:hold_reason] }
      end

      def lane_from(row)
        {
          used: row.fetch(:used), seed_state: row.fetch(:seed_state),
          seeded_launches: row.fetch(:seeded_launches), ambiguous_rows: row.fetch(:ambiguous_rows)
        }
      end

      def decode_ids(value)
        ids = Hive::RuntimeControlPlane::Codec.load_json(value)
        valid = ids.is_a?(Array) && ids.size <= MAX_RESERVATIONS_PER_LANE &&
          ids.all? { |id| id.is_a?(String) && !id.empty? && id.bytesize <= MAX_RESERVATION_ID_BYTES } &&
          ids.uniq.size == ids.size
        raise "discovery reservation ids are invalid" unless valid
        ids
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

      def retry_active?(hold, at: now)
        hold && normalize_time(hold.fetch(:retry_not_before)) > normalize_time(at)
      end

      def exhaustion(reason, observed, engine:, retry_at: nil)
        {
          reason: reason, limit: @limit, observed: observed,
          engine: engine.to_s, retry_at: retry_at
        }
      end

      def telemetry_identity
        id = "patrol-launch-#{SecureRandom.uuid}"
        # A standalone Patrol launch is a telemetry session, not an Attempts
        # lifecycle row. Keep it unattributed so the control-plane foreign key
        # cannot manufacture an attempt identity that does not exist.
        { attempt_id: nil, session_id: id }
      end

      def profile_name(profile, stage)
        profile.respond_to?(:name) ? profile.name.to_s : stage.to_s
      end

      def stage_engine(stage)
        inferred = DISCOVERY_STAGES[stage.to_s]
        return nil unless inferred
        return inferred unless @engine
        raise ArgumentError, "discovery stage does not match configured engine" unless inferred == @engine
        inferred
      end

      def normalize_engine(value)
        engine = value.to_sym
        raise ArgumentError, "unknown patrol discovery engine #{value.inspect}" unless ENGINES.include?(engine)
        engine
      end

      def now = normalize_time(@clock.call)
      def date_for(value) = normalize_time(value).strftime("%Y-%m-%d")
      def normalize_time(value) = value.respond_to?(:utc) ? value.utc : Time.parse(value.to_s).utc
      def timestamp_for(value) = Hive::RuntimeControlPlane::Codec.dump_time(normalize_time(value))
      def integer(value) = [ Integer(value || 0), 0 ].max
      def present_or(value, fallback) = value.to_s.strip.empty? ? fallback.to_s : value.to_s.strip
    end
  end
end
