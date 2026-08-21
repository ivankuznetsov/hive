require "digest"
require "date"
require "fileutils"
require "json"
require "securerandom"
require "time"

require "hive/atomic_file"
require "hive/managed_directory"
require "hive/usage_db"

module Hive
  module Patrol
    # Durable admission for scheduled discovery provider launches. The ledger
    # is intentionally separate from UsageDb: token rows are telemetry and a
    # telemetry failure cannot create or remove discovery capacity.
    class LaunchBudget
      class SeedUnavailable < Hive::Error; end

      SCHEMA = "hive-patrol-discovery-allowances".freeze
      SCHEMA_VERSION = 1
      ENGINES = %i[ordinary architecture].freeze
      DISCOVERY_STAGES = {
        "patrol-review" => :ordinary,
        "refactor-patrol-review" => :architecture
      }.freeze
      DAILY_EXHAUSTION_REASONS = %w[daily_agent_spawn_limit legacy_attribution_ambiguous].freeze
      DEFAULT_MAX_AGENT_SPAWNS_PER_DAY = 4
      MODE_LIMITS = {
        "low" => 2, "medium" => 4, "high" => 8, "ultrapatrol" => 16,
        "off" => 4
      }.freeze
      MAX_DAY_BYTES = 2 * 1024 * 1024
      MAX_HOLDS_BYTES = 2 * 1024 * 1024
      MAX_PROJECTS_PER_DAY = 4_096
      MAX_HELD_PROJECTS = 4_096
      MAX_RESERVATIONS_PER_LANE = 10_000
      DAY_DIRECTORY = "dates".freeze
      HOLDS_FILE = "provider-holds.json".freeze
      LOCK_FILE = "ledger.lock".freeze

      attr_reader :last_exhaustion

      def self.resource_exhaustion_backoff_sec(reasons, now:, fallback:)
        reasons = Array(reasons).map(&:to_s)
        return fallback unless reasons.any? &&
                               (reasons - DAILY_EXHAUSTION_REASONS).empty?

        current = now.utc
        next_day = Time.utc(current.year, current.month, current.day) + 86_400
        [ (next_day - current).ceil, 1 ].max
      end

      def initialize(project_root, cfg:, project_id: nil, project_name: nil,
                     engine: nil, usage_db: Hive::UsageDb,
                     ledger_path: nil, clock: -> { Time.now.utc },
                     id_generator: -> { SecureRandom.uuid },
                     charge_discovery: true)
        @project_root = File.expand_path(project_root)
        @cfg = cfg
        @usage_db = usage_db
        @clock = clock
        @id_generator = id_generator
        @project_slug = project_name.to_s.strip
        @project_slug = fallback_project_slug if @project_slug.empty?
        @project_id = project_id.to_s.strip
        @project_id = fallback_project_id if @project_id.empty?
        @engine = normalize_engine(engine) unless engine.nil?
        @charge_discovery = charge_discovery == true
        @ledger_root = File.expand_path(
          ledger_path || "#{@usage_db.path}.patrol-discovery-allowances"
        )
        @directory = Hive::ManagedDirectory.new(
          root: @ledger_root, label: "Patrol discovery allowance ledger"
        )
        @max_agent_spawns_per_day =
          MODE_LIMITS.fetch(
            cfg.dig("patrol", "mode").to_s,
            cfg.dig("patrol", "scheduled_discovery_launches_per_engine_per_day") ||
              DEFAULT_MAX_AGENT_SPAWNS_PER_DAY
          )
      end

      # Reserve the discovery slot immediately before the provider child is
      # started. Non-discovery Patrol stages only open a best-effort telemetry
      # session and never consult or mutate this ledger.
      def acquire(profile:, stage:, started_at:, reservation_id: nil)
        engine = @charge_discovery ? stage_engine(stage) : nil
        @active_telemetry_source = engine ? "patrol_discovery_launch" : "patrol_non_discovery_launch"
        if engine
          reserved = reserve_discovery!(
            engine: engine, started_at: started_at,
            reservation_id: reservation_id || @id_generator.call
          )
          return false unless reserved
        end

        reserve_telemetry!(profile: profile, stage: stage, started_at: started_at)
        true
      end

      def remaining_launches(engine: @engine || :ordinary)
        allowance_snapshot(engine: engine).fetch(:remaining)
      end

      def allowance_snapshot(engine: @engine || :ordinary)
        engine = normalize_engine(engine)
        lane, hold = capacity_snapshot(engine)
        used = lane.fetch("reservations").size
        status = "available"
        remaining = [ @max_agent_spawns_per_day - used, 0 ].max
        retry_at = nil
        if retry_active?(hold)
          @last_exhaustion = exhaustion(
            "provider_lane_backoff", used,
            engine: engine, retry_at: hold.fetch("retry_not_before")
          )
          status = "provider_backoff"
          remaining = 0
          retry_at = hold.fetch("retry_not_before")
        elsif lane.fetch("seed_state") == "parked"
          @last_exhaustion = exhaustion(
            "legacy_attribution_ambiguous", used,
            engine: engine
          )
          status = "legacy_attribution_ambiguous"
          remaining = 0
        elsif remaining.zero?
          @last_exhaustion = exhaustion("daily_agent_spawn_limit", used, engine: engine)
          status = "exhausted"
        else
          @last_exhaustion = nil
        end

        {
          engine: engine.to_s, utc_date: date_for(now),
          limit: @max_agent_spawns_per_day, used: used, remaining: remaining,
          status: status, retry_at: retry_at,
          seeded_launches: lane.fetch("seeded_launches"),
          ambiguous_legacy_rows: lane.fetch("ambiguous_rows")
        }
      rescue StandardError => e
        @ledger_error = e
        @last_exhaustion = exhaustion("allowance_store_unavailable", 1, engine: engine)
        {
          engine: engine.to_s, utc_date: date_for(now),
          limit: @max_agent_spawns_per_day, used: nil, remaining: 0,
          status: "unavailable", retry_at: nil,
          seeded_launches: nil, ambiguous_legacy_rows: nil
        }
      end

      def park!(engine: @engine || :ordinary, retry_at:, reason:)
        engine = normalize_engine(engine)
        instant = normalize_time(retry_at)
        normalized_reason = reason.to_s.strip
        raise ArgumentError, "provider retry reason is invalid" if
          normalized_reason.empty? || normalized_reason.bytesize > 128

        with_ledger_lock do
          state = load_holds
          project = (state.fetch("projects")[@project_id] ||= {})
          hold = project[engine.to_s]
          current = hold && normalize_time(hold.fetch("retry_not_before"))
          if !current || instant > current
            project[engine.to_s] = {
              "retry_not_before" => instant.iso8601(6),
              "reason" => normalized_reason
            }
          end
          persist_holds(state)
        end
        true
      rescue StandardError => e
        @ledger_error = e
        false
      end

      def clear_park!(engine: @engine || :ordinary)
        engine = normalize_engine(engine)
        with_ledger_lock do
          state = load_holds
          project = state.fetch("projects")[@project_id]
          project&.delete(engine.to_s)
          state.fetch("projects").delete(@project_id) if project&.empty?
          persist_holds(state)
        end
        true
      rescue StandardError => e
        @ledger_error = e
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
        detail = @last_exhaustion
        return nil unless detail

        detail.slice(:reason, :limit, :observed, :engine, :retry_at).compact
      end

      # Complete the independent telemetry session. Failure is observable but
      # cannot retroactively change the already-consumed discovery reservation.
      def record!(result:, profile:, stage:, started_at:)
        reservation = @active_telemetry
        usage = result.is_a?(Hash) && result[:usage].is_a?(Hash) ? result[:usage] : {}
        input = integer(usage[:input])
        output = integer(usage[:output])
        cached = integer(usage[:cached])
        metered = (input + output + cached).positive?
        recorded_stage = metered ? stage : "#{stage}-unmetered"
        identity = reservation || telemetry_identity

        model = usage[:model]
        model ||= result[:model] if result.is_a?(Hash)
        recorded = @usage_db.record!(
          agent: profile_name(profile, stage), model: model,
          project_slug: @project_slug, task_slug: stage, stage: recorded_stage,
          started_at: started_at, ended_at: now.iso8601,
          input: input, output: output, cached: cached,
          attempt_id: identity.fetch(:attempt_id),
          session_id: identity.fetch(:session_id), task_generation: 0,
          source: @active_telemetry_source || "patrol_non_discovery_launch"
        )
        warn "[hive] patrol usage record failed; discovery allowance is unchanged" unless recorded
        recorded
      rescue StandardError => e
        warn "[hive] patrol usage record failed: #{e.message}"
        false
      ensure
        @active_telemetry = nil
        @active_telemetry_source = nil
      end

      private

      def reserve_discovery!(engine:, started_at:, reservation_id:)
        with_ledger_lock do
          date = date_for(started_at)
          state = load_day(date)
          lane = ensure_lane!(state, engine, date)
          if @lane_created
            persist_day(state)
            @lane_created = false
          end
          hold = held_lane(load_holds, engine)
          if retry_active?(hold, at: started_at)
            @last_exhaustion = exhaustion(
              "provider_lane_backoff", lane.fetch("reservations").size,
              engine: engine, retry_at: hold.fetch("retry_not_before")
            )
            next false
          end
          if lane.fetch("seed_state") == "parked"
            @last_exhaustion = exhaustion(
              "legacy_attribution_ambiguous", lane.fetch("reservations").size,
              engine: engine
            )
            next false
          end
          id = reservation_id.to_s
          raise ArgumentError, "discovery reservation id is invalid" if id.empty? || id.bytesize > 256
          if lane.fetch("reservations").any? { |item| item.fetch("id") == id }
            @last_exhaustion = nil
            next true
          end
          if lane.fetch("reservations").size >= @max_agent_spawns_per_day
            @last_exhaustion = exhaustion(
              "daily_agent_spawn_limit", lane.fetch("reservations").size,
              engine: engine
            )
            next false
          end
          lane.fetch("reservations") << {
            "id" => id,
            "reserved_at" => normalize_time(started_at).iso8601(6)
          }
          persist_day(state)
          @last_exhaustion = nil
          true
        end
      rescue StandardError => e
        @ledger_error = e
        @last_exhaustion = exhaustion("allowance_store_unavailable", 1, engine: engine)
        false
      end

      def capacity_snapshot(engine)
        with_ledger_lock do
          date = date_for(now)
          state = load_day(date)
          lane = ensure_lane!(state, engine, date)
          persist_day(state) if @lane_created
          @lane_created = false
          hold = held_lane(load_holds, engine)
          [ Marshal.load(Marshal.dump(lane)), Marshal.load(Marshal.dump(hold)) ]
        end
      end

      def ensure_lane!(state, engine, date)
        project = (state.fetch("projects")[@project_id] ||= {})
        return project.fetch(engine.to_s) if project.key?(engine.to_s)

        seed = legacy_seed(date)
        raise SeedUnavailable, "legacy discovery seed is unavailable" unless seed

        lane_seed = seed.fetch(engine)
        lane = {
          "seed_state" => lane_seed.fetch(:ambiguous).positive? ? "parked" : "complete",
          "seeded_launches" => lane_seed.fetch(:count),
          "ambiguous_rows" => lane_seed.fetch(:ambiguous),
          "reservations" => Array.new(lane_seed.fetch(:count)) do |index|
            {
              "id" => "legacy:#{engine}:#{date}:#{index + 1}",
              "reserved_at" => "#{date}T00:00:00Z"
            }
          end
        }
        project[engine.to_s] = lane
        @lane_created = true
        lane
      end

      def legacy_seed(date)
        return empty_seed unless @usage_db.respond_to?(:patrol_discovery_seed)

        result = @usage_db.patrol_discovery_seed(
          scope: { project_slug: @project_slug }, date: date
        )
        return nil unless result.is_a?(Hash) && result[:available] != false

        ENGINES.to_h do |engine|
          value = result.fetch(engine, {})
          [ engine, { count: integer(value[:count]), ambiguous: integer(value[:ambiguous]) } ]
        end
      rescue StandardError
        nil
      end

      def empty_seed
        ENGINES.to_h { |engine| [ engine, { count: 0, ambiguous: 0 } ] }
      end

      def reserve_telemetry!(profile:, stage:, started_at:)
        identity = telemetry_identity
        recorded = @usage_db.record!(
          agent: profile_name(profile, stage), model: nil,
          project_slug: @project_slug, task_slug: stage,
          stage: "#{stage}-unmetered", started_at: started_at, ended_at: nil,
          input: 0, output: 0, cached: 0,
          attempt_id: identity.fetch(:attempt_id),
          session_id: identity.fetch(:session_id), task_generation: 0,
          source: @active_telemetry_source || "patrol_non_discovery_launch"
        )
        @active_telemetry = identity if recorded
        warn "[hive] patrol usage reservation failed; continuing without token telemetry" unless recorded
        recorded
      rescue StandardError => e
        warn "[hive] patrol usage reservation failed: #{e.message}; continuing without token telemetry"
        false
      end

      def telemetry_identity
        session_id = "patrol-launch-#{SecureRandom.uuid}"
        { attempt_id: session_id, session_id: session_id }
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

      def date_for(value)
        normalize_time(value).strftime("%Y-%m-%d")
      end

      def normalize_time(value)
        value.respond_to?(:utc) ? value.utc : Time.parse(value.to_s).utc
      end

      def with_ledger_lock
        @directory.prepare!
        @directory.with_lock(LOCK_FILE) do
          yield
        end
      end

      def load_day(date)
        bytes = @directory.read(day_path(date), max_bytes: MAX_DAY_BYTES, missing: true)
        return empty_day(date) unless bytes

        state = JSON.parse(bytes)
        validate_day!(state, date)
        state
      end

      def empty_day(date)
        {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "date" => date, "projects" => {}
        }
      end

      def persist_day(state)
        date = state.fetch("date")
        validate_day!(state, date)
        content = "#{JSON.pretty_generate(state)}\n"
        raise "discovery allowance day exceeds its size bound" if content.bytesize > MAX_DAY_BYTES

        @directory.ensure_directory(DAY_DIRECTORY)
        @directory.atomic_write(
          day_path(date), content, mode: 0o600,
          max_existing_bytes: MAX_DAY_BYTES
        )
      end

      def validate_day!(state, expected_date)
        valid = state.is_a?(Hash) &&
          state.keys.sort == %w[date projects schema schema_version] &&
          state["schema"] == SCHEMA && state["schema_version"] == SCHEMA_VERSION &&
          state["date"] == expected_date && state["projects"].is_a?(Hash) &&
          state["projects"].size <= MAX_PROJECTS_PER_DAY
        raise "discovery allowance day schema is invalid" unless valid

        validate_date!(state.fetch("date"))
        state.fetch("projects").each do |project_id, project|
          validate_project_identity!(project_id)
          unless project.is_a?(Hash) && !project.empty? &&
                 (project.keys - ENGINES.map(&:to_s)).empty?
            raise "discovery allowance project lanes are invalid"
          end
          project.each { |engine, lane| validate_lane!(engine, lane, expected_date) }
        end
        true
      end

      def load_holds
        bytes = @directory.read(HOLDS_FILE, max_bytes: MAX_HOLDS_BYTES, missing: true)
        return empty_holds unless bytes

        state = JSON.parse(bytes)
        validate_holds!(state)
        state
      end

      def empty_holds
        {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "kind" => "provider_holds", "projects" => {}
        }
      end

      def persist_holds(state)
        validate_holds!(state)
        content = "#{JSON.pretty_generate(state)}\n"
        raise "discovery allowance holds exceed their size bound" if content.bytesize > MAX_HOLDS_BYTES

        @directory.atomic_write(
          HOLDS_FILE, content, mode: 0o600,
          max_existing_bytes: MAX_HOLDS_BYTES
        )
      end

      def validate_holds!(state)
        valid = state.is_a?(Hash) &&
          state.keys.sort == %w[kind projects schema schema_version] &&
          state["schema"] == SCHEMA && state["schema_version"] == SCHEMA_VERSION &&
          state["kind"] == "provider_holds" && state["projects"].is_a?(Hash) &&
          state["projects"].size <= MAX_HELD_PROJECTS
        raise "discovery allowance provider holds schema is invalid" unless valid

        state.fetch("projects").each do |project_id, project|
          validate_project_identity!(project_id)
          unless project.is_a?(Hash) && !project.empty? &&
                 (project.keys - ENGINES.map(&:to_s)).empty?
            raise "discovery allowance provider hold lanes are invalid"
          end
          project.each do |engine, hold|
            unless ENGINES.map(&:to_s).include?(engine) && hold.is_a?(Hash) &&
                   hold.keys.sort == %w[reason retry_not_before] &&
                   hold["reason"].is_a?(String) && !hold["reason"].empty? &&
                   hold["reason"].bytesize <= 128 && hold["retry_not_before"].is_a?(String)
              raise "discovery allowance provider hold is invalid"
            end
            normalize_time(hold.fetch("retry_not_before"))
          end
        end
        true
      end

      def held_lane(state, engine)
        state.dig("projects", @project_id, engine.to_s)
      end

      def day_path(date)
        validate_date!(date)
        File.join(DAY_DIRECTORY, "#{date}.json")
      end

      def validate_date!(date)
        parsed = Date.iso8601(date.to_s)
        raise "discovery allowance date is invalid" unless parsed.iso8601 == date

        true
      rescue ArgumentError
        raise "discovery allowance date is invalid"
      end

      def validate_project_identity!(project_id)
        return true if project_id.is_a?(String) && !project_id.empty? && project_id.bytesize <= 256

        raise "discovery allowance project identity is invalid"
      end

      def validate_lane!(engine, lane, date)
        expected = %w[ambiguous_rows reservations seed_state seeded_launches]
        valid = ENGINES.map(&:to_s).include?(engine) && lane.is_a?(Hash) &&
          lane.keys.sort == expected && %w[complete parked].include?(lane["seed_state"]) &&
          lane["seeded_launches"].is_a?(Integer) && lane["seeded_launches"] >= 0 &&
          lane["ambiguous_rows"].is_a?(Integer) && lane["ambiguous_rows"] >= 0 &&
          lane["reservations"].is_a?(Array) &&
          lane["reservations"].size <= MAX_RESERVATIONS_PER_LANE &&
          lane["reservations"].size >= lane["seeded_launches"]
        raise "discovery allowance lane is invalid" unless valid
        if lane["seed_state"] == "parked" && lane["ambiguous_rows"].zero?
          raise "discovery allowance parked seed lacks ambiguity evidence"
        end
        ids = {}
        lane.fetch("reservations").each do |reservation|
          unless reservation.is_a?(Hash) && reservation.keys.sort == %w[id reserved_at] &&
                 reservation["id"].is_a?(String) && !reservation["id"].empty? &&
                 reservation["id"].bytesize <= 256 && reservation["reserved_at"].is_a?(String)
            raise "discovery allowance reservation is invalid"
          end
          raise "discovery allowance reservation is duplicated" if ids[reservation.fetch("id")]
          ids[reservation.fetch("id")] = true
          reserved_at = normalize_time(reservation.fetch("reserved_at"))
          raise "discovery allowance reservation date is invalid" unless reserved_at.strftime("%Y-%m-%d") == date
        end
      end

      def retry_active?(hold, at: now)
        return false unless hold

        value = hold["retry_not_before"]
        value && normalize_time(at) < normalize_time(value)
      end

      def fallback_project_slug
        "#{File.basename(@project_root)}-#{Digest::SHA256.hexdigest(@project_root)[0, 12]}"
      end

      def fallback_project_id
        "unregistered:#{Digest::SHA256.hexdigest(@project_root)}"
      end

      def exhaustion(reason, observed, engine:, retry_at: nil)
        {
          reason: reason,
          limit: reason == "daily_agent_spawn_limit" ? @max_agent_spawns_per_day : 1,
          observed: reason == "daily_agent_spawn_limit" ? observed : 1,
          engine: normalize_engine(engine).to_s,
          retry_at: retry_at
        }
      end

      def now
        normalize_time(@clock.call)
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
