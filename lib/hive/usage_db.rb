require "securerandom"
require "time"
require "hive/billing_evidence"
require "hive/runtime_control_plane"

module Hive
  # Token telemetry facade backed by the shared runtime control plane. The
  # public hashes intentionally retain their historical shape; only the
  # storage authority changed.
  module UsageDb
    AGENTS = %i[claude codex pi grok opencode].freeze
    BUCKETS = %i[today 7d 30d all].freeze
    BILLING_ROUTES = Hive::BillingEvidence::ROUTES
    BILLING_EVIDENCE_SOURCES = Hive::BillingEvidence::SOURCES
    CORE_METRICS = %i[input output cached].freeze
    OPTIONAL_METRICS = %i[cache_read cache_write reasoning cost].freeze
    METRICS = (CORE_METRICS + OPTIONAL_METRICS).freeze
    INCLUSION_FLAGS = %i[input_includes_cache_read input_includes_cache_write output_includes_reasoning].freeze
    EXACT_COLUMNS = %i[
      session_id agent model project_slug task_slug stage started_at ended_at
      input output cached attempt_id task_generation source requested_backend
      requested_model actual_backend actual_model cache_read cache_write reasoning
      cost input_available output_available cached_available cache_read_available
      cache_write_available reasoning_available cost_available billing_route
      billing_evidence_source input_includes_cache_read input_includes_cache_write
      output_includes_reasoning
    ].freeze

    module_function

    def database=(value)
      @database = value
    end

    def record!(agent:, model:, project_slug:, task_slug:, stage:, started_at:, ended_at:,
                input:, output:, cached:, requested_route: nil, actual_route: nil,
                actual_provider: nil, actual_model: nil,
                cache_read: nil, cache_write: nil, reasoning: nil, cost: nil,
                provider_reported_cost: nil, harness: nil,
                billing_route: "unknown", billing_evidence_source: "unavailable",
                input_includes_cache_read: nil, input_includes_cache_write: nil,
                output_includes_reasoning: nil,
                attempt_id: nil, session_id: nil, task_generation: nil, source: nil)
      requested_backend, requested_model = split_route(requested_route)
      actual_backend, routed_actual_model = split_route(actual_route)
      actual_backend ||= blank_to_nil(actual_provider)
      actual_model = routed_actual_model || blank_to_nil(actual_model)
      normalized_billing_route = billing_value(billing_route, BILLING_ROUTES, "billing route")
      normalized_billing_source = billing_value(
        billing_evidence_source, BILLING_EVIDENCE_SOURCES, "billing evidence source"
      )
      raise ArgumentError, "harness must match the usage agent" if
        !harness.nil? && harness.to_s != agent.to_s

      attributes = {
        id: SecureRandom.uuid,
        agent: agent.to_s,
        model: blank_to_nil(model),
        requested_backend: requested_backend,
        requested_model: requested_model,
        actual_backend: actual_backend,
        actual_model: actual_model,
        project_slug: blank_to_nil(project_slug),
        task_slug: blank_to_nil(task_slug),
        stage: blank_to_nil(stage),
        started_at: iso8601(started_at),
        ended_at: ended_at.nil? ? nil : iso8601(ended_at),
        input: integer(input), output: integer(output), cached: integer(cached),
        cache_read: nullable_number(cache_read),
        cache_write: nullable_number(cache_write),
        reasoning: nullable_number(reasoning),
        cost: nullable_number(provider_reported_cost.nil? ? cost : provider_reported_cost),
        input_available: availability(input),
        output_available: availability(output),
        cached_available: availability(cached),
        cache_read_available: availability(cache_read),
        cache_write_available: availability(cache_write),
        reasoning_available: availability(reasoning),
        cost_available: availability(provider_reported_cost.nil? ? cost : provider_reported_cost),
        attempt_id: blank_to_nil(attempt_id),
        session_id: blank_to_nil(session_id),
        task_generation: task_generation.nil? ? nil : Integer(task_generation),
        source: blank_to_nil(source),
        billing_route: normalized_billing_route,
        billing_evidence_source: normalized_billing_source,
        input_includes_cache_read: nullable_boolean(input_includes_cache_read),
        input_includes_cache_write: nullable_boolean(input_includes_cache_write),
        output_includes_reasoning: nullable_boolean(output_includes_reasoning)
      }

      database.transaction do |db|
        usage = db[:token_usage]
        existing = attributes[:session_id] && usage.where(session_id: attributes[:session_id]).first
        if existing
          validate_session_identity!(existing, attributes)
          usage.where(id: existing.fetch(:id)).update(merge_session(existing, attributes))
        else
          usage.insert(attributes)
        end
      end
      true
    rescue ArgumentError, TypeError, Hive::RuntimeControlPlane::IntegrityError
      raise
    rescue StandardError => error
      raise Hive::RuntimeControlPlane::Unavailable.new(
        "usage persistence failed: #{error.message}",
        code: :usage_persistence_failed,
        action: "repair the runtime control plane before acknowledging terminal accounting",
        details: { error_class: error.class.name }
      )
    end

    def exact_attempt(attempt_id:, task_generation: nil, project_slug: nil,
                      task_slug: nil, legacy_limit: 100, session_limit: 100,
                      deadline: nil,
                      monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      session_limit = positive_limit(session_limit, "session_limit")
      legacy_limit = positive_limit(legacy_limit, "legacy_limit")
      return unavailable_exact("deadline_exhausted") if deadline_exhausted?(deadline, monotonic_clock)
      return unavailable_exact("store_missing") unless File.file?(database.path)

      database.read do |db|
        raise IOError, "usage read deadline exhausted" if deadline_exhausted?(deadline, monotonic_clock)

        usage = db[:token_usage]
        exact = usage.where(attempt_id: attempt_id.to_s)
        exact = exact.where(task_generation: Integer(task_generation)) unless task_generation.nil?
        rows = exact.select(*EXACT_COLUMNS).order(:session_id, :started_at).limit(session_limit + 1).all
        sessions = rows.first(session_limit).map { |row| exact_row(row) }

        unattributed = usage.where(attempt_id: nil)
        unattributed = unattributed.where(project_slug: project_slug.to_s) unless blank?(project_slug)
        unattributed = unattributed.where(task_slug: task_slug.to_s) unless blank?(task_slug)
        legacy_rows = unattributed.select(*EXACT_COLUMNS).reverse_order(:started_at)
                                  .limit(legacy_limit + 1).all
        {
          available: true,
          sessions: sessions,
          totals: sum_usage(sessions),
          unattributed: legacy_rows.first(legacy_limit).map { |row| exact_row(row) },
          unattributed_count: [ legacy_rows.length, legacy_limit ].min,
          unattributed_truncated: legacy_rows.length > legacy_limit,
          truncated: rows.length > session_limit
        }
      end
    rescue StandardError => error
      return unavailable_exact("deadline_exhausted") if deadline_exhausted?(deadline, monotonic_clock)

      warn "[hive] exact attempt usage failed: #{error.class}: #{error.message}"
      unavailable_exact("read_failed")
    end

    def aggregate(scope:, now: Time.now.utc)
      return zero_aggregate unless File.file?(database.path)

      database.read do |db|
        result = zero_aggregate
        bucket_starts(now).each do |bucket, since|
          rows = scoped_usage(db[:token_usage], scope || {}, since)
                 .select_group(:agent).select_append(*aggregate_columns).all
          rows.each do |row|
            values = (result[:agents][row[:agent].to_s.to_sym] ||= zero_buckets).fetch(bucket)
            apply_aggregate!(values, row)
          end
          result[:agents].each_value do |buckets|
            values = buckets.fetch(bucket)
            CORE_METRICS.each { |metric| result[:total][bucket][metric] += values[metric] }
            propagate_unavailable!(result[:total][bucket], values)
          end

          patrol = patrol_dataset(scoped_usage(db[:token_usage], scope || {}, since))
                   .select(*(aggregate_columns + [ Sequel.function(:count, :id).as(:count) ])).first || {}
          apply_aggregate!(result[:patrol][bucket], patrol) if integer(patrol[:count]).positive?
        end
        result
      end
    rescue StandardError => error
      warn "[hive] usage aggregate failed: #{error.class}: #{error.message}"
      zero_aggregate
    end

    def patrol_activity(scope:, now: Time.now.utc)
      database.read do |db|
        dataset = patrol_dataset(scoped_usage(
          db[:token_usage], scope || {}, bucket_starts(now).fetch(:today)
        ))
        unmetered = Sequel.like(:stage, "%-unmetered")
        ordinary = Sequel.like(:stage, "patrol%")
        architecture = Sequel.like(:stage, "refactor-patrol%")
        architecture_review = Sequel.like(:stage, "refactor-patrol-review%")
        row = dataset.select do
          [ sum(input).as(:input), sum(output).as(:output), sum(cached).as(:cached),
           count(id).as(:agent_spawns),
           sum(Sequel.case({ unmetered => 1 }, 0)).as(:unmetered_spawns),
           sum(Sequel.case({ ordinary => 1 }, 0)).as(:ordinary_agent_spawns),
           sum(Sequel.case({ architecture => 1 }, 0)).as(:architecture_agent_spawns),
           sum(Sequel.case({ architecture_review => 1 }, 0)).as(:architecture_review_spawns),
           sum(Sequel.case({ ordinary & unmetered => 1 }, 0)).as(:ordinary_unmetered_spawns),
           sum(Sequel.case({ architecture & unmetered => 1 }, 0)).as(:architecture_unmetered_spawns) ]
        end.first || {}
        usage = CORE_METRICS.to_h { |metric| [ metric, integer(row[metric]) ] }
        usage.merge(
          available: true, tokens: usage.values_at(:input, :output).sum,
          agent_spawns: integer(row[:agent_spawns]),
          unmetered_spawns: integer(row[:unmetered_spawns]),
          ordinary_agent_spawns: integer(row[:ordinary_agent_spawns]),
          architecture_agent_spawns: integer(row[:architecture_agent_spawns]),
          architecture_review_spawns: integer(row[:architecture_review_spawns]),
          ordinary_unmetered_spawns: integer(row[:ordinary_unmetered_spawns]),
          architecture_unmetered_spawns: integer(row[:architecture_unmetered_spawns])
        )
      end
    rescue StandardError => error
      warn "[hive] patrol usage aggregate failed: #{error.class}: #{error.message}"
      zero_patrol_activity(available: false)
    end

    def database
      @database || Hive::RuntimeControlPlane.database
    end

    def validate_session_identity!(existing, incoming)
      identity = %i[attempt_id task_generation]
      compatible = identity.all? { |key| existing[key] == incoming[key] }
      compatible &&= billing_compatible?(existing[:billing_route], incoming[:billing_route])
      INCLUSION_FLAGS.each do |key|
        compatible &&= existing[key].nil? || incoming[key].nil? || existing[key] == incoming[key]
      end
      raise Hive::RuntimeControlPlane::IntegrityError.new(
        "session usage identity conflict", code: :usage_session_conflict
      ) unless compatible
    end

    def billing_compatible?(left, right)
      left.nil? || left == "unknown" || right == "unknown" || left == right
    end

    def merge_session(existing, incoming)
      merged = incoming.dup
      merged.delete(:id)
      %i[model requested_backend requested_model actual_backend actual_model project_slug task_slug stage].each do |key|
        merged[key] ||= existing[key]
      end
      merged[:started_at] = [ existing[:started_at], incoming[:started_at] ].compact.min
      merged[:ended_at] ||= existing[:ended_at]
      CORE_METRICS.each { |key| merged[key] = [ existing[key], incoming[key] ].compact.max }
      OPTIONAL_METRICS.each do |key|
        availability_key = :"#{key}_available"
        use_incoming = incoming[availability_key] > existing[availability_key] ||
          (incoming[availability_key] == 1 && incoming[key].to_f > existing[key].to_f)
        merged[key] = use_incoming ? incoming[key] : existing[key]
        merged[availability_key] = [ existing[availability_key], incoming[availability_key] ].max
      end
      %i[input_available output_available cached_available].each do |key|
        merged[key] = [ existing[key], incoming[key] ].max
      end
      if existing[:billing_route] && existing[:billing_route] != "unknown"
        merged[:billing_route] = existing[:billing_route]
        merged[:billing_evidence_source] = existing[:billing_evidence_source]
      end
      INCLUSION_FLAGS.each do |key|
        merged[key] = existing[key] unless existing[key].nil?
      end
      merged[:source] ||= existing[:source]
      merged
    end

    def scoped_usage(dataset, scope, since)
      dataset = dataset.where(project_slug: scope[:project_slug].to_s) unless blank?(scope[:project_slug])
      dataset = dataset.where(task_slug: scope[:task_slug].to_s) unless blank?(scope[:task_slug])
      dataset = dataset.where { started_at >= since } if since
      dataset
    end

    def patrol_dataset(dataset)
      dataset.where(Sequel.like(:stage, "patrol%") | Sequel.like(:stage, "refactor-patrol%"))
    end

    def apply_aggregate!(target, row)
      CORE_METRICS.each do |metric|
        target[metric] = integer(row[metric])
        mark_unavailable!(target, metric, row[:"#{metric}_available"])
      end
    end

    def exact_row(row)
      result = row.slice(*EXACT_COLUMNS).transform_keys(&:to_sym)
      availability = METRICS.to_h do |metric|
        [ metric, result.delete(:"#{metric}_available") ]
      end
      result[:provider_reported_cost] = result[:cost]
      result[:harness] = result[:agent]
      result[:billing_route] ||= "unknown"
      result[:billing_evidence_source] ||= "unavailable"
      (METRICS - [ :cost ]).each { |key| result[key] = integer(result[key]) }
      INCLUSION_FLAGS.each do |key|
        result[key] = nullable_boolean_value(result[key])
      end
      METRICS.each do |metric|
        mark_unavailable!(result, metric, availability.fetch(metric))
      end
      result
    end

    def zero_aggregate
      {
        agents: AGENTS.to_h { |agent| [ agent, zero_buckets ] },
        patrol: zero_buckets,
        total: zero_buckets
      }
    end

    def zero_buckets = BUCKETS.to_h { |bucket| [ bucket, zero_usage ] }
    def zero_usage = { input: 0, output: 0, cached: 0 }

    def zero_patrol_activity(available: true)
      zero_usage.merge(
        available: available, tokens: 0, agent_spawns: 0, unmetered_spawns: 0,
        ordinary_agent_spawns: 0, architecture_agent_spawns: 0,
        architecture_review_spawns: 0, ordinary_unmetered_spawns: 0,
        architecture_unmetered_spawns: 0
      )
    end

    def sum_usage(rows)
      rows.each_with_object(zero_usage) do |row, total|
        CORE_METRICS.each { |key| total[key] += integer(row[key]) }
        propagate_unavailable!(total, row)
      end
    end

    def bucket_starts(now)
      utc_now = now.utc
      today = Time.utc(utc_now.year, utc_now.month, utc_now.day)
      {
        today: today.iso8601,
        "7d": (utc_now - (7 * 86_400)).iso8601,
        "30d": (utc_now - (30 * 86_400)).iso8601,
        all: nil
      }
    end

    def positive_limit(value, name)
      limit = Integer(value)
      raise ArgumentError, "#{name} must be positive" unless limit.positive?

      limit
    end

    def deadline_exhausted?(deadline, monotonic_clock)
      !deadline.nil? && monotonic_clock.call >= Float(deadline)
    rescue ArgumentError, TypeError
      true
    end

    def mark_unavailable!(usage, metric, available)
      usage[:"#{metric}_available"] = false unless integer(available) == 1
    end

    def propagate_unavailable!(target, source)
      CORE_METRICS.each do |metric|
        target[:"#{metric}_available"] = false if source[:"#{metric}_available"] == false
      end
    end

    def unavailable_exact(reason)
      {
        available: false, sessions: [], totals: nil, unattributed: [],
        unattributed_count: nil, reason: reason
      }
    end

    def aggregate_columns
      CORE_METRICS.flat_map do |metric|
        [ Sequel.function(:sum, metric).as(metric),
          Sequel.function(:min, :"#{metric}_available").as(:"#{metric}_available") ]
      end
    end

    def iso8601(value)
      return value.utc.iso8601 if value.respond_to?(:utc)

      Time.parse(value.to_s).utc.iso8601
    rescue ArgumentError
      value.to_s
    end

    def integer(value) = value.to_i
    def nullable_number(value) = value
    def availability(value) = value.nil? ? 0 : 1

    def nullable_boolean(value)
      return nil if value.nil?
      return value ? 1 : 0 if value == true || value == false

      raise ArgumentError, "usage inclusion evidence must be true, false, or nil"
    end

    def nullable_boolean_value(value)
      value.nil? ? nil : integer(value) == 1
    end

    def billing_value(value, allowed, label)
      normalized = value.to_s
      raise ArgumentError, "#{label} is invalid" unless allowed.include?(normalized)

      normalized
    end

    def split_route(route)
      return [ nil, nil ] if blank?(route)
      return [ route.provider.to_s, route.model.to_s ] if
        route.respond_to?(:provider) && route.respond_to?(:model)

      provider, model = route.to_s.split("/", 2)
      return [ nil, nil ] if blank?(provider) || blank?(model)

      [ provider, model ]
    end

    def blank_to_nil(value)
      value = value.to_s if value.is_a?(Symbol)
      blank?(value) ? nil : value
    end

    def blank?(value) = value.nil? || value.to_s.empty?
  end
end
