require "hive/canonical_json"

module Hive
  module UsageDb
    DETAIL_RETENTION_DAYS = 7
    COMPACTION_BATCH_SIZE = 500
    SUMMARY_DIMENSIONS = %i[
      project_slug task_slug stage agent actual_backend actual_model model
      billing_route billing_evidence_source input_includes_cache_read
      input_includes_cache_write output_includes_reasoning
    ].freeze

    module_function

    # A rollup replaces its source rows in the same writer transaction. The
    # latest rolled-up day also closes new, unreserved historical writes: no
    # per-session tombstones or separate compaction progress ledger are needed.
    def compact!(now: Time.now.utc, limit: COMPACTION_BATCH_SIZE, database: self.database)
      limit = positive_limit(limit, "limit")
      cutoff = (normalized_time(now) - DETAIL_RETENTION_DAYS * 86_400).strftime("%Y-%m-%dT00:00:00Z")
      database.transaction do |db|
        settled = db[:attempts].where(publication_accounting_acknowledged: 1)
          .select(:attempt_id)
        rows = db[:token_usage].exclude(ended_at: nil)
          .where { (started_at < cutoff) & (ended_at < cutoff) }
          .exclude(Sequel.function(:date, :started_at) => nil)
          .exclude(Sequel.function(:date, :ended_at) => nil)
          .where(Sequel.|({ attempt_id: nil }, { attempt_id: settled }))
          .order(:started_at, :id).limit(limit).all
        rows.group_by { |row| summary_identity(row) }.each do |identity, members|
          id = Hive::CanonicalJSON.digest(identity)
          values = identity.merge(id: id, sessions_count: members.length)
          values[:metered_sessions_count] = members.count do |row|
            row[:input_available] == 1 && row[:output_available] == 1
          end
          METRICS.each do |metric|
            values[metric] = members.sum { |row| row[metric] || 0 }
            values[:"#{metric}_available"] = members.map { |row| row.fetch(:"#{metric}_available") }.min
          end
          additions = (METRICS + [ :sessions_count, :metered_sessions_count ]).to_h do |column|
            [ column, Sequel[column] + values.fetch(column) ]
          end
          METRICS.each do |metric|
            column = :"#{metric}_available"
            additions[column] = Sequel.function(:min, Sequel[column], values.fetch(column))
          end
          db[:token_usage_daily].insert_conflict(target: :id, update: additions).insert(values)
        end
        db[:token_usage].where(id: rows.map { |row| row.fetch(:id) }).delete unless rows.empty?
        rows.length
      end
    end

    def task_usage(project_slug:, task_slug:, session_limit: 100, deadline: nil,
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      scope = { project_slug: required_text(project_slug, "project"),
                task_slug: required_text(task_slug, "task") }
      session_limit = positive_limit(session_limit, "session_limit")
      return unavailable_exact("deadline_exhausted") if deadline_exhausted?(deadline, monotonic_clock)
      database.transaction(mode: :deferred) do |db|
        rows = scoped_usage(reporting_rows(db), scope, nil)
        groups = rows.select_group(*SUMMARY_DIMENSIONS).select_append(
          *summary_columns,
          Sequel.function(:sum, :sessions_count).as(:sessions_count),
          Sequel.function(:sum, :metered_sessions_count).as(:metered_sessions_count),
          Sequel.function(:sum, :compacted_sessions_count).as(:compacted_sessions_count),
          Sequel.function(:sum, :live_sessions_count).as(:live_sessions_count)
        ).all
        next unavailable_exact("deadline_exhausted") if deadline_exhausted?(deadline, monotonic_clock)
        sessions = db[:token_usage].where(scope).reverse_order(:started_at, :id)
          .limit(session_limit + 1).all
        next unavailable_exact("deadline_exhausted") if deadline_exhausted?(deadline, monotonic_clock)
        {
          available: true, groups: groups,
          sessions: sessions.first(session_limit).map { |row| exact_row(row).merge(id: row[:id]) },
          compacted_sessions_count: groups.sum { |row| row[:compacted_sessions_count] },
          truncated: sessions.length > session_limit
        }
      end
    rescue StandardError => error
      warn "[hive] task usage failed: #{error.class}: #{error.message}"
      unavailable_exact("read_failed")
    end

    def summary_identity(row)
      { day: row.fetch(:started_at)[0, 10] }.merge(row.slice(*SUMMARY_DIMENSIONS))
    end

    def summary_columns
      METRICS.flat_map do |metric|
        [ Sequel.function(:sum, metric).as(metric),
          Sequel.function(:min, :"#{metric}_available").as(:"#{metric}_available") ]
      end
    end

    def reporting_rows(db)
      columns = [ :id, *SUMMARY_DIMENSIONS, *METRICS,
                  *METRICS.map { |metric| :"#{metric}_available" } ]
      raw = db[:token_usage].select(*columns, :started_at,
        Sequel.as(1, :sessions_count), Sequel.as(0, :compacted_sessions_count),
        Sequel.case({ { ended_at: nil } => 1 }, 0).as(:live_sessions_count),
        Sequel.case({ { input_available: 1, output_available: 1 } => 1 }, 0).as(:metered_sessions_count))
      daily = db[:token_usage_daily].select(*columns,
        Sequel.join([ :day, "T00:00:00Z" ]).as(:started_at), :sessions_count,
        Sequel.as(:sessions_count, :compacted_sessions_count), Sequel.as(0, :live_sessions_count),
        :metered_sessions_count)
      raw.union(daily, all: true)
    end

    def reject_expired_detail!(db, attributes)
      day = db[:token_usage_daily].max(:day)
      return unless day && attributes.fetch(:started_at)[0, 10] <= day

      # A delayed first receipt from an unresolved attempt is still owed.
      pending = attributes[:attempt_id] && db[:attempts].where(
        attempt_id: attributes[:attempt_id], publication_accounting_acknowledged: 0
      ).first
      # Usage's integer generation is the input epoch, not the attempt's
      # opaque ownership-generation string.
      return if pending && RuntimeControlPlane::Codec.load_json(
        pending.fetch(:details_json)
      )["task_input_epoch"] == attributes[:task_generation]

      raise Hive::RuntimeControlPlane::IntegrityError.new(
        "usage detail has expired; historical session writes are closed",
        code: :usage_detail_expired,
        action: "do not replay compacted telemetry; task and model totals are retained"
      )
    end

    def expired_attempt_detail?(db, attempt_id)
      attempt = db[:attempts].where(attempt_id: attempt_id.to_s,
        publication_accounting_acknowledged: 1).first
      day = db[:token_usage_daily].max(:day)
      attempt && day && !attempt[:ended_at].nil? && attempt[:ended_at][0, 10] <= day
    end
  end
end
