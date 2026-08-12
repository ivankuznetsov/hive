require "fileutils"
require "securerandom"
require "time"
require "hive/paths"

module Hive
  # Small SQLite store for hive-driven agent token usage.
  #
  # Rows are intentionally written at the stage-spawn boundary, not by scanning
  # agent log directories. Project slug is the configured project name / folder
  # basename, by design, so multiple checkouts of the same project collapse into
  # the same aggregate bucket.
  module UsageDb
    AGENTS = %i[claude codex pi grok].freeze
    BUCKETS = %i[today 7d 30d all].freeze
    SCHEMA_VERSION = 2
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
        project_slug    TEXT,
        task_slug       TEXT,
        stage           TEXT,
        started_at      TEXT NOT NULL,
        ended_at        TEXT,
        input           INTEGER NOT NULL DEFAULT 0,
        output          INTEGER NOT NULL DEFAULT 0,
        cached          INTEGER NOT NULL DEFAULT 0,
        attempt_id      TEXT,
        session_id      TEXT,
        task_generation INTEGER,
        source          TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_token_usage_started_at ON token_usage(started_at);
      CREATE INDEX IF NOT EXISTS idx_token_usage_project ON token_usage(project_slug, started_at);
      CREATE INDEX IF NOT EXISTS idx_token_usage_task ON token_usage(task_slug, started_at);
      CREATE INDEX IF NOT EXISTS idx_token_usage_attempt ON token_usage(attempt_id, task_generation);
      CREATE UNIQUE INDEX IF NOT EXISTS idx_token_usage_session_unique
        ON token_usage(session_id) WHERE session_id IS NOT NULL;
    SQL

    module_function

    def path
      @path || env_path || File.join(Hive::Paths.data_home, "usage.db")
    end

    def path=(value)
      @path = value
    end

    def record!(agent:, model:, project_slug:, task_slug:, stage:, started_at:, ended_at:,
                input:, output:, cached:, attempt_id: nil, session_id: nil,
                task_generation: nil, source: nil)
      with_database(create: true) do |db|
        ensure_schema!(db)
        attributes = [
          SecureRandom.uuid, agent.to_s, blank_to_nil(model), blank_to_nil(project_slug),
          blank_to_nil(task_slug), blank_to_nil(stage), iso8601(started_at),
          ended_at.nil? ? nil : iso8601(ended_at), integer(input), integer(output),
          integer(cached), blank_to_nil(attempt_id), blank_to_nil(session_id),
          task_generation.nil? ? nil : Integer(task_generation), blank_to_nil(source)
        ]
        if attributes[12]
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
        id, agent, model, project_slug, task_slug, stage, started_at, ended_at,
        input, output, cached, attempt_id, session_id, task_generation, source
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL
    SESSION_UPSERT_SQL = <<~SQL.freeze
      #{INSERT_SQL.strip}
      ON CONFLICT(session_id) WHERE session_id IS NOT NULL DO UPDATE SET
        agent = excluded.agent,
        model = COALESCE(excluded.model, token_usage.model),
        project_slug = COALESCE(excluded.project_slug, token_usage.project_slug),
        task_slug = COALESCE(excluded.task_slug, token_usage.task_slug),
        stage = COALESCE(excluded.stage, token_usage.stage),
        started_at = MIN(token_usage.started_at, excluded.started_at),
        ended_at = COALESCE(excluded.ended_at, token_usage.ended_at),
        input = MAX(token_usage.input, excluded.input),
        output = MAX(token_usage.output, excluded.output),
        cached = MAX(token_usage.cached, excluded.cached),
        source = COALESCE(excluded.source, token_usage.source)
      WHERE token_usage.attempt_id = excluded.attempt_id
        AND token_usage.task_generation = excluded.task_generation
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
          "started_at, ended_at, input, output, cached, attempt_id, task_generation, source " \
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
          "started_at, ended_at, input, output, cached, attempt_id, task_generation, source " \
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
          rows.each do |agent, input, output, cached|
            key = agent.to_s.to_sym
            result[:agents][key] ||= zero_buckets
            values = result[:agents][key][bucket]
            values[:input] = integer(input)
            values[:output] = integer(output)
            values[:cached] = integer(cached)
          end
          result[:agents].each_value do |buckets|
            result[:total][bucket][:input] += buckets[bucket][:input]
            result[:total][bucket][:output] += buckets[bucket][:output]
            result[:total][bucket][:cached] += buckets[bucket][:cached]
          end
          input, output, cached = aggregate_patrol_row(db, scope || {}, since)
          result[:patrol][bucket][:input] = integer(input)
          result[:patrol][bucket][:output] = integer(output)
          result[:patrol][bucket][:cached] = integer(cached)
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
      return if version == SCHEMA_VERSION && schema_columns(db).include?("session_id")

      db.transaction(:immediate) do
        db.execute_batch(LEGACY_SCHEMA_SQL)
        columns = schema_columns(db)
        {
          "attempt_id" => "TEXT",
          "session_id" => "TEXT",
          "task_generation" => "INTEGER",
          "source" => "TEXT"
        }.each do |name, type|
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
      sql = +"SELECT agent, SUM(input), SUM(output), SUM(cached) FROM token_usage"
      clauses, binds = aggregate_clauses(scope, since)
      sql << " WHERE #{clauses.join(' AND ')}" unless clauses.empty?
      sql << " GROUP BY agent"
      db.execute(sql, binds)
    end

    def aggregate_patrol_row(db, scope, since)
      sql = +"SELECT SUM(input), SUM(output), SUM(cached) FROM token_usage"
      clauses, binds = aggregate_clauses(scope, since)
      append_patrol_clause!(clauses, binds)
      sql << " WHERE #{clauses.join(' AND ')}"
      db.execute(sql, binds).first || [ 0, 0, 0 ]
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
      {
        session_id: row[0], agent: row[1], model: row[2], project_slug: row[3],
        task_slug: row[4], stage: row[5], started_at: row[6], ended_at: row[7],
        input: integer(row[8]), output: integer(row[9]), cached: integer(row[10]),
        attempt_id: row[11], task_generation: row[12], source: row[13]
      }
    end

    def sum_usage(rows)
      rows.each_with_object({ input: 0, output: 0, cached: 0 }) do |row, total|
        %i[input output cached].each { |key| total[key] += integer(row[key]) }
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

    def blank_to_nil(value)
      value = value.to_s if value.is_a?(Symbol)
      blank?(value) ? nil : value
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end
  end
end
