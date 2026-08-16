require "fileutils"
require "securerandom"
require "time"
require "hive/billing_evidence"
require "hive/paths"

module Hive
  # Small SQLite store for hive-driven agent token usage.
  #
  # Rows are intentionally written at the stage-spawn boundary, not by scanning
  # agent log directories. Project slug is the configured project name / folder
  # basename, by design, so multiple checkouts of the same project collapse into
  # the same aggregate bucket.
  module UsageDb
    AGENTS = %i[claude codex pi grok opencode].freeze
    BUCKETS = %i[today 7d 30d all].freeze
    SCHEMA_VERSION = 4
    BILLING_ROUTES = Hive::BillingEvidence::ROUTES
    BILLING_EVIDENCE_SOURCES = Hive::BillingEvidence::SOURCES
    BUSY_TIMEOUT_MS = 5_000
    LEGACY_SCHEMA_SQL = <<~SQL.freeze
      CREATE TABLE IF NOT EXISTS token_usage (
        id           TEXT PRIMARY KEY,
        agent        TEXT NOT NULL,
        model        TEXT,
        project_slug TEXT,
        task_slug    TEXT,
        stage        TEXT,
        started_at   TEXT NOT NULL,
        ended_at     TEXT,
        input        INTEGER NOT NULL DEFAULT 0,
        output       INTEGER NOT NULL DEFAULT 0,
        cached       INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_token_usage_started_at ON token_usage(started_at);
      CREATE INDEX IF NOT EXISTS idx_token_usage_project ON token_usage(project_slug, started_at);
      CREATE INDEX IF NOT EXISTS idx_token_usage_task ON token_usage(task_slug, started_at);
    SQL
    SCHEMA_SQL = <<~SQL.freeze
      CREATE TABLE IF NOT EXISTS token_usage (
        id              TEXT PRIMARY KEY,
        agent           TEXT NOT NULL,
        model           TEXT,
        requested_backend TEXT,
        requested_model   TEXT,
        actual_backend    TEXT,
        actual_model      TEXT,
        project_slug    TEXT,
        task_slug       TEXT,
        stage           TEXT,
        started_at      TEXT NOT NULL,
        ended_at        TEXT,
        input           INTEGER NOT NULL DEFAULT 0,
        output          INTEGER NOT NULL DEFAULT 0,
        cached          INTEGER NOT NULL DEFAULT 0,
        cache_read      INTEGER,
        cache_write     INTEGER,
        reasoning       INTEGER,
        cost            REAL,
        input_available       INTEGER NOT NULL DEFAULT 1,
        output_available      INTEGER NOT NULL DEFAULT 1,
        cached_available      INTEGER NOT NULL DEFAULT 1,
        cache_read_available  INTEGER NOT NULL DEFAULT 0,
        cache_write_available INTEGER NOT NULL DEFAULT 0,
        reasoning_available   INTEGER NOT NULL DEFAULT 0,
        cost_available        INTEGER NOT NULL DEFAULT 0,
        attempt_id      TEXT,
        session_id      TEXT,
        task_generation INTEGER,
        source          TEXT,
        billing_route   TEXT,
        billing_evidence_source TEXT,
        input_includes_cache_read INTEGER,
        input_includes_cache_write INTEGER,
        output_includes_reasoning INTEGER
      );
      CREATE INDEX IF NOT EXISTS idx_token_usage_started_at ON token_usage(started_at);
      CREATE INDEX IF NOT EXISTS idx_token_usage_project ON token_usage(project_slug, started_at);
      CREATE INDEX IF NOT EXISTS idx_token_usage_task ON token_usage(task_slug, started_at);
      CREATE INDEX IF NOT EXISTS idx_token_usage_attempt ON token_usage(attempt_id, task_generation);
      CREATE UNIQUE INDEX IF NOT EXISTS idx_token_usage_session_unique
        ON token_usage(session_id) WHERE session_id IS NOT NULL;
    SQL
    ADDITIVE_COLUMNS = {
      "requested_backend" => "TEXT",
      "requested_model" => "TEXT",
      "actual_backend" => "TEXT",
      "actual_model" => "TEXT",
      "cache_read" => "INTEGER",
      "cache_write" => "INTEGER",
      "reasoning" => "INTEGER",
      "cost" => "REAL",
      "input_available" => "INTEGER NOT NULL DEFAULT 1",
      "output_available" => "INTEGER NOT NULL DEFAULT 1",
      "cached_available" => "INTEGER NOT NULL DEFAULT 1",
      "cache_read_available" => "INTEGER NOT NULL DEFAULT 0",
      "cache_write_available" => "INTEGER NOT NULL DEFAULT 0",
      "reasoning_available" => "INTEGER NOT NULL DEFAULT 0",
      "cost_available" => "INTEGER NOT NULL DEFAULT 0",
      "attempt_id" => "TEXT",
      "session_id" => "TEXT",
      "task_generation" => "INTEGER",
      "source" => "TEXT",
      "billing_route" => "TEXT",
      "billing_evidence_source" => "TEXT",
      "input_includes_cache_read" => "INTEGER",
      "input_includes_cache_write" => "INTEGER",
      "output_includes_reasoning" => "INTEGER"
    }.freeze

    module_function

    def path
      @path || env_path || File.join(Hive::Paths.data_home, "usage.db")
    end

    def path=(value)
      @path = value
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
      normalized_billing_route = billing_value(
        billing_route, BILLING_ROUTES, "billing route"
      )
      normalized_billing_source = billing_value(
        billing_evidence_source, BILLING_EVIDENCE_SOURCES,
        "billing evidence source"
      )
      reported_cost = provider_reported_cost.nil? ? cost : provider_reported_cost
      if !harness.nil? && harness.to_s != agent.to_s
        raise ArgumentError, "harness must match the usage agent"
      end
      with_database(create: true) do |db|
        ensure_schema!(db)
        normalized_session_id = blank_to_nil(session_id)
        attributes = [
          SecureRandom.uuid, agent.to_s, blank_to_nil(model),
          requested_backend, requested_model, actual_backend, actual_model,
          blank_to_nil(project_slug), blank_to_nil(task_slug), blank_to_nil(stage),
          iso8601(started_at), ended_at.nil? ? nil : iso8601(ended_at),
          integer(input), integer(output), integer(cached),
          nullable_number(cache_read), nullable_number(cache_write),
          nullable_number(reasoning), nullable_number(reported_cost),
          availability(input), availability(output), availability(cached),
          availability(cache_read), availability(cache_write),
          availability(reasoning), availability(reported_cost),
          blank_to_nil(attempt_id), normalized_session_id,
          task_generation.nil? ? nil : Integer(task_generation), blank_to_nil(source),
          normalized_billing_route, normalized_billing_source,
          nullable_boolean(input_includes_cache_read),
          nullable_boolean(input_includes_cache_write),
          nullable_boolean(output_includes_reasoning)
        ]
        if normalized_session_id
          db.execute(SESSION_UPSERT_SQL, attributes)
          raise "session usage identity conflict" if db.changes.zero?
        else
          db.execute(INSERT_SQL, attributes)
        end
      end
      true
    rescue StandardError => e
      warn "[hive] usage record failed: #{e.class}: #{e.message}"
      false
    end

    INSERT_SQL = <<~SQL.freeze
      INSERT INTO token_usage (
        id, agent, model,
        requested_backend, requested_model, actual_backend, actual_model,
        project_slug, task_slug, stage, started_at, ended_at,
        input, output, cached, cache_read, cache_write, reasoning, cost,
        input_available, output_available, cached_available,
        cache_read_available, cache_write_available, reasoning_available, cost_available,
        attempt_id, session_id, task_generation, source,
        billing_route, billing_evidence_source,
        input_includes_cache_read, input_includes_cache_write, output_includes_reasoning
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    SESSION_UPSERT_SQL = <<~SQL.freeze
      #{INSERT_SQL.strip}
      ON CONFLICT(session_id) WHERE session_id IS NOT NULL DO UPDATE SET
        agent = excluded.agent,
        model = COALESCE(excluded.model, token_usage.model),
        requested_backend = COALESCE(excluded.requested_backend, token_usage.requested_backend),
        requested_model = COALESCE(excluded.requested_model, token_usage.requested_model),
        actual_backend = COALESCE(excluded.actual_backend, token_usage.actual_backend),
        actual_model = COALESCE(excluded.actual_model, token_usage.actual_model),
        project_slug = COALESCE(excluded.project_slug, token_usage.project_slug),
        task_slug = COALESCE(excluded.task_slug, token_usage.task_slug),
        stage = COALESCE(excluded.stage, token_usage.stage),
        started_at = MIN(token_usage.started_at, excluded.started_at),
        ended_at = COALESCE(excluded.ended_at, token_usage.ended_at),
        input = MAX(token_usage.input, excluded.input),
        output = MAX(token_usage.output, excluded.output),
        cached = MAX(token_usage.cached, excluded.cached),
        cache_read = CASE
          WHEN excluded.cache_read_available > token_usage.cache_read_available OR
               (excluded.cache_read_available = 1 AND excluded.cache_read > token_usage.cache_read)
          THEN excluded.cache_read ELSE token_usage.cache_read END,
        cache_write = CASE
          WHEN excluded.cache_write_available > token_usage.cache_write_available OR
               (excluded.cache_write_available = 1 AND excluded.cache_write > token_usage.cache_write)
          THEN excluded.cache_write ELSE token_usage.cache_write END,
        reasoning = CASE
          WHEN excluded.reasoning_available > token_usage.reasoning_available OR
               (excluded.reasoning_available = 1 AND excluded.reasoning > token_usage.reasoning)
          THEN excluded.reasoning ELSE token_usage.reasoning END,
        cost = CASE
          WHEN excluded.cost_available > token_usage.cost_available OR
               (excluded.cost_available = 1 AND excluded.cost > token_usage.cost)
          THEN excluded.cost ELSE token_usage.cost END,
        input_available = MAX(token_usage.input_available, excluded.input_available),
        output_available = MAX(token_usage.output_available, excluded.output_available),
        cached_available = MAX(token_usage.cached_available, excluded.cached_available),
        cache_read_available = MAX(token_usage.cache_read_available, excluded.cache_read_available),
        cache_write_available = MAX(token_usage.cache_write_available, excluded.cache_write_available),
        reasoning_available = MAX(token_usage.reasoning_available, excluded.reasoning_available),
        cost_available = MAX(token_usage.cost_available, excluded.cost_available),
        billing_route = CASE
          WHEN token_usage.billing_route IS NULL OR token_usage.billing_route = 'unknown'
          THEN excluded.billing_route ELSE token_usage.billing_route END,
        billing_evidence_source = CASE
          WHEN token_usage.billing_route IS NULL OR token_usage.billing_route = 'unknown'
          THEN excluded.billing_evidence_source ELSE token_usage.billing_evidence_source END,
        input_includes_cache_read = COALESCE(
          token_usage.input_includes_cache_read, excluded.input_includes_cache_read
        ),
        input_includes_cache_write = COALESCE(
          token_usage.input_includes_cache_write, excluded.input_includes_cache_write
        ),
        output_includes_reasoning = COALESCE(
          token_usage.output_includes_reasoning, excluded.output_includes_reasoning
        ),
        source = COALESCE(excluded.source, token_usage.source)
      WHERE token_usage.attempt_id = excluded.attempt_id
        AND token_usage.task_generation = excluded.task_generation
        AND (token_usage.billing_route IS NULL OR token_usage.billing_route = 'unknown' OR
             excluded.billing_route = 'unknown' OR token_usage.billing_route = excluded.billing_route)
        AND (token_usage.input_includes_cache_read IS NULL OR
             excluded.input_includes_cache_read IS NULL OR
             token_usage.input_includes_cache_read = excluded.input_includes_cache_read)
        AND (token_usage.input_includes_cache_write IS NULL OR
             excluded.input_includes_cache_write IS NULL OR
             token_usage.input_includes_cache_write = excluded.input_includes_cache_write)
        AND (token_usage.output_includes_reasoning IS NULL OR
             excluded.output_includes_reasoning IS NULL OR
             token_usage.output_includes_reasoning = excluded.output_includes_reasoning)
    SQL

    def exact_attempt(attempt_id:, task_generation: nil, project_slug: nil,
                      task_slug: nil, legacy_limit: 100)
      db_path = path
      return unavailable_exact("store_missing") unless File.file?(db_path)

      with_database(create: false) do |db|
        ensure_schema!(db)
        clauses = [ "attempt_id = ?" ]
        binds = [ attempt_id.to_s ]
        unless task_generation.nil?
          clauses << "task_generation = ?"
          binds << Integer(task_generation)
        end
        rows = db.execute(
          "SELECT session_id, agent, model, project_slug, task_slug, stage, " \
          "started_at, ended_at, input, output, cached, attempt_id, task_generation, source, " \
          "requested_backend, requested_model, actual_backend, actual_model, " \
          "cache_read, cache_write, reasoning, cost, input_available, output_available, " \
          "cached_available, cache_read_available, cache_write_available, " \
          "reasoning_available, cost_available, billing_route, billing_evidence_source, " \
          "input_includes_cache_read, input_includes_cache_write, output_includes_reasoning " \
          "FROM token_usage WHERE #{clauses.join(' AND ')} ORDER BY session_id, started_at",
          binds
        )
        sessions = rows.map { |row| exact_row(row) }
        legacy_clauses = [ "attempt_id IS NULL" ]
        legacy_binds = []
        unless blank?(project_slug)
          legacy_clauses << "project_slug = ?"
          legacy_binds << project_slug.to_s
        end
        unless blank?(task_slug)
          legacy_clauses << "task_slug = ?"
          legacy_binds << task_slug.to_s
        end
        unattributed_rows = db.execute(
          "SELECT session_id, agent, model, project_slug, task_slug, stage, " \
          "started_at, ended_at, input, output, cached, attempt_id, task_generation, source, " \
          "requested_backend, requested_model, actual_backend, actual_model, " \
          "cache_read, cache_write, reasoning, cost, input_available, output_available, " \
          "cached_available, cache_read_available, cache_write_available, " \
          "reasoning_available, cost_available, billing_route, billing_evidence_source, " \
          "input_includes_cache_read, input_includes_cache_write, output_includes_reasoning " \
          "FROM token_usage WHERE #{legacy_clauses.join(' AND ')} " \
          "ORDER BY started_at DESC LIMIT ?",
          legacy_binds + [ Integer(legacy_limit) ]
        ).map { |row| exact_row(row) }
        {
          available: true,
          sessions: sessions,
          totals: sum_usage(sessions),
          unattributed: unattributed_rows,
          unattributed_count: db.get_first_value(
            "SELECT COUNT(*) FROM token_usage WHERE #{legacy_clauses.join(' AND ')}",
            legacy_binds
          ).to_i
        }
      end
    rescue StandardError => e
      warn "[hive] exact attempt usage failed: #{e.class}: #{e.message}"
      unavailable_exact("read_failed")
    end

    def aggregate(scope:, now: Time.now.utc)
      db_path = path
      return zero_aggregate unless File.exist?(db_path)

      result = zero_aggregate
      with_database(create: false) do |db|
        ensure_schema!(db)
        bucket_starts(now).each do |bucket, since|
          rows = aggregate_rows(db, scope || {}, since)
          rows.each do |agent, input, output, cached, input_available, output_available, cached_available|
            key = agent.to_s.to_sym
            result[:agents][key] ||= zero_buckets
            values = result[:agents][key][bucket]
            values[:input] = integer(input)
            values[:output] = integer(output)
            values[:cached] = integer(cached)
            mark_unavailable!(values, :input, input_available)
            mark_unavailable!(values, :output, output_available)
            mark_unavailable!(values, :cached, cached_available)
          end
          result[:agents].each_value do |buckets|
            result[:total][bucket][:input] += buckets[bucket][:input]
            result[:total][bucket][:output] += buckets[bucket][:output]
            result[:total][bucket][:cached] += buckets[bucket][:cached]
            propagate_unavailable!(result[:total][bucket], buckets[bucket])
          end
          input, output, cached, count, input_available, output_available, cached_available =
            aggregate_patrol_row(db, scope || {}, since)
          result[:patrol][bucket][:input] = integer(input)
          result[:patrol][bucket][:output] = integer(output)
          result[:patrol][bucket][:cached] = integer(cached)
          if integer(count).positive?
            mark_unavailable!(result[:patrol][bucket], :input, input_available)
            mark_unavailable!(result[:patrol][bucket], :output, output_available)
            mark_unavailable!(result[:patrol][bucket], :cached, cached_available)
          end
        end
      end
      result
    rescue StandardError => e
      warn "[hive] usage aggregate failed: #{e.class}: #{e.message}"
      zero_aggregate
    end

    # Current-day patrol consumption used by the runtime budget gate. Both
    # ordinary and architecture patrol stages share the same project token
    # budget, while their durable launch counts remain separate. An
    # "-unmetered" row represents a real agent launch whose CLI returned no
    # trustworthy positive token totals.
    def patrol_activity(scope:, now: Time.now.utc)
      # Unlike the read-only TUI aggregate, enforcement deliberately creates
      # the empty store before the first spawn. That distinguishes a genuine
      # zero-usage day from an unavailable store, which must fail closed.
      with_database(create: true) do |db|
        ensure_schema!(db)
        since = bucket_starts(now).fetch(:today)
        sql = +"SELECT SUM(input), SUM(output), SUM(cached), COUNT(*), " \
               "SUM(CASE WHEN stage LIKE '%-unmetered' THEN 1 ELSE 0 END), " \
               "SUM(CASE WHEN stage LIKE 'patrol%' THEN 1 ELSE 0 END), " \
               "SUM(CASE WHEN stage LIKE 'refactor-patrol%' THEN 1 ELSE 0 END), " \
               "SUM(CASE WHEN stage LIKE 'refactor-patrol-review%' THEN 1 ELSE 0 END), " \
               "SUM(CASE WHEN stage LIKE 'patrol%-unmetered' THEN 1 ELSE 0 END), " \
               "SUM(CASE WHEN stage LIKE 'refactor-patrol%-unmetered' THEN 1 ELSE 0 END) " \
               "FROM token_usage"
        clauses, binds = aggregate_clauses(scope || {}, since)
        append_patrol_clause!(clauses, binds)
        sql << " WHERE #{clauses.join(' AND ')}"
        input, output, cached, spawns, unmetered, ordinary_spawns, architecture_spawns,
          architecture_review_spawns,
          ordinary_unmetered, architecture_unmetered = db.execute(sql, binds).first
        usage = { input: integer(input), output: integer(output), cached: integer(cached) }
        usage.merge(
          available: true,
          tokens: usage.values_at(:input, :output).sum,
          agent_spawns: integer(spawns),
          unmetered_spawns: integer(unmetered),
          ordinary_agent_spawns: integer(ordinary_spawns),
          architecture_agent_spawns: integer(architecture_spawns),
          architecture_review_spawns: integer(architecture_review_spawns),
          ordinary_unmetered_spawns: integer(ordinary_unmetered),
          architecture_unmetered_spawns: integer(architecture_unmetered)
        )
      end
    rescue StandardError => e
      warn "[hive] patrol usage aggregate failed: #{e.class}: #{e.message}"
      zero_patrol_activity(available: false)
    end

    def ensure_schema!(db)
      version = db.get_first_value("PRAGMA user_version").to_i
      raise "usage database schema #{version} is newer than supported #{SCHEMA_VERSION}" if
        version > SCHEMA_VERSION
      columns = schema_columns(db)
      return if version == SCHEMA_VERSION &&
        columns.include?("session_id") && columns.include?("input_available") &&
        columns.include?("billing_route")

      db.transaction(:immediate) do
        db.execute_batch(LEGACY_SCHEMA_SQL)
        columns = schema_columns(db)
        ADDITIVE_COLUMNS.each do |name, type|
          db.execute("ALTER TABLE token_usage ADD COLUMN #{name} #{type}") unless columns.include?(name)
        end
        db.execute_batch(SCHEMA_SQL)
        db.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
      end
    end

    def zero_aggregate
      {
        agents: AGENTS.to_h { |agent| [ agent, zero_buckets ] },
        patrol: zero_buckets,
        total: zero_buckets
      }
    end

    def zero_buckets
      BUCKETS.to_h { |bucket| [ bucket, zero_usage ] }
    end

    def zero_usage
      { input: 0, output: 0, cached: 0 }
    end

    def zero_patrol_activity(available: true)
      zero_usage.merge(
        available: available, tokens: 0, agent_spawns: 0, unmetered_spawns: 0,
        ordinary_agent_spawns: 0, architecture_agent_spawns: 0,
        architecture_review_spawns: 0,
        ordinary_unmetered_spawns: 0, architecture_unmetered_spawns: 0
      )
    end

    def aggregate_rows(db, scope, since)
      sql = +"SELECT agent, SUM(input), SUM(output), SUM(cached), " \
             "MIN(input_available), MIN(output_available), MIN(cached_available) FROM token_usage"
      clauses, binds = aggregate_clauses(scope, since)
      sql << " WHERE #{clauses.join(' AND ')}" unless clauses.empty?
      sql << " GROUP BY agent"
      db.execute(sql, binds)
    end

    def aggregate_patrol_row(db, scope, since)
      sql = +"SELECT SUM(input), SUM(output), SUM(cached), COUNT(*), " \
             "MIN(input_available), MIN(output_available), MIN(cached_available) FROM token_usage"
      clauses, binds = aggregate_clauses(scope, since)
      append_patrol_clause!(clauses, binds)
      sql << " WHERE #{clauses.join(' AND ')}"
      db.execute(sql, binds).first || [ 0, 0, 0, 0, nil, nil, nil ]
    end

    def append_patrol_clause!(clauses, binds)
      clauses << "(stage LIKE ? OR stage LIKE ?)"
      binds.concat([ "patrol%", "refactor-patrol%" ])
    end

    def aggregate_clauses(scope, since)
      clauses = []
      binds = []
      unless blank?(scope[:project_slug])
        clauses << "project_slug = ?"
        binds << scope[:project_slug].to_s
      end
      unless blank?(scope[:task_slug])
        clauses << "task_slug = ?"
        binds << scope[:task_slug].to_s
      end
      unless since.nil?
        clauses << "started_at >= ?"
        binds << since
      end
      [ clauses, binds ]
    end

    def bucket_starts(now)
      utc_now = now.utc
      today = Time.utc(utc_now.year, utc_now.month, utc_now.day)
      {
        today: today.iso8601,
        "7d": (utc_now - (7 * 24 * 60 * 60)).iso8601,
        "30d": (utc_now - (30 * 24 * 60 * 60)).iso8601,
        all: nil
      }
    end

    def with_database(create:)
      require "sqlite3"

      db_path = path
      FileUtils.mkdir_p(File.dirname(db_path)) if create
      db = SQLite3::Database.new(db_path)
      db.busy_timeout(BUSY_TIMEOUT_MS)
      yield db
    ensure
      db&.close
    end

    def schema_columns(db)
      db.table_info("token_usage").map { |row| (row["name"] || row[1]).to_s }
    end

    def exact_row(row)
      result = {
        session_id: row[0], agent: row[1], model: row[2], project_slug: row[3],
        task_slug: row[4], stage: row[5], started_at: row[6], ended_at: row[7],
        input: integer(row[8]), output: integer(row[9]), cached: integer(row[10]),
        attempt_id: row[11], task_generation: row[12], source: row[13],
        requested_backend: row[14], requested_model: row[15],
        actual_backend: row[16], actual_model: row[17],
        cache_read: row[18], cache_write: row[19], reasoning: row[20], cost: row[21],
        provider_reported_cost: row[21], harness: row[1],
        billing_route: row[29] || "unknown",
        billing_evidence_source: row[30] || "unavailable",
        input_includes_cache_read: nullable_boolean_value(row[31]),
        input_includes_cache_write: nullable_boolean_value(row[32]),
        output_includes_reasoning: nullable_boolean_value(row[33])
      }
      mark_unavailable!(result, :input, row[22])
      mark_unavailable!(result, :output, row[23])
      mark_unavailable!(result, :cached, row[24])
      mark_unavailable!(result, :cache_read, row[25])
      mark_unavailable!(result, :cache_write, row[26])
      mark_unavailable!(result, :reasoning, row[27])
      mark_unavailable!(result, :cost, row[28])
      result
    end

    def sum_usage(rows)
      rows.each_with_object({ input: 0, output: 0, cached: 0 }) do |row, total|
        %i[input output cached].each { |key| total[key] += integer(row[key]) }
        propagate_unavailable!(total, row)
      end
    end

    def mark_unavailable!(usage, metric, available)
      usage[:"#{metric}_available"] = false unless integer(available) == 1
    end

    def propagate_unavailable!(target, source)
      %i[input output cached].each do |metric|
        target[:"#{metric}_available"] = false if source[:"#{metric}_available"] == false
      end
    end

    def unavailable_exact(reason)
      {
        available: false, sessions: [], totals: nil, unattributed: [],
        unattributed_count: nil, reason: reason
      }
    end

    def env_path
      value = ENV["HIVE_USAGE_DB_PATH"]
      return nil if value.nil? || value.empty?

      File.expand_path(value)
    end

    def iso8601(value)
      return value.utc.iso8601 if value.respond_to?(:utc)

      Time.parse(value.to_s).utc.iso8601
    rescue ArgumentError
      value.to_s
    end

    def integer(value)
      value.to_i
    end

    def nullable_number(value)
      return nil if value.nil?

      value
    end

    def availability(value)
      value.nil? ? 0 : 1
    end

    def nullable_boolean(value)
      return nil if value.nil?
      return value ? 1 : 0 if value == true || value == false

      raise ArgumentError, "usage inclusion evidence must be true, false, or nil"
    end

    def nullable_boolean_value(value)
      return nil if value.nil?

      integer(value) == 1
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

    def blank?(value)
      value.nil? || value.to_s.empty?
    end
  end
end
