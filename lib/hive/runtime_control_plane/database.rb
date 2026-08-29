require "fileutils"
require "rubygems"
require "securerandom"
require "sequel"
require "sequel/extensions/migration"
require "sqlite3"

module Hive
  module RuntimeControlPlane
    EXPECTED_TABLES = %i[
      attempt_accounting attempt_failure_cohorts attempt_failure_events
      attempt_lost_outcomes
      attempt_relationships attempts capacity_reservations
      daemon_runtime dispatch_outbox dispatch_requests installations
      maintenance_checkpoints patrol_allowances payload_references
      pr_merge_project_state pr_merge_reconciliations projections projects provider_audit
      provider_circuits routing_policies task_counters task_leases task_subjects
      terminal_pending_publications token_usage attempt_routing_decisions
    ].freeze

    EXPECTED_INDEXES = %i[
      attempts_active_subject_generation_uidx attempts_request_uidx
      capacity_reservations_active_uidx dispatch_requests_active_subject_uidx
      dispatch_requests_idempotency_uidx provider_circuits_probe_idx
      token_usage_session_uidx
    ].freeze

    class Database
      attr_reader :path, :owner_pid

      def initialize(path: Hive::Paths.runtime_control_plane_path,
                     migrations_dir: MIGRATIONS_DIR,
                     busy_timeout_ms: BUSY_TIMEOUT_MS,
                     sqlite_version: SQLite3::SQLITE_VERSION,
                     feature_probe: nil,
                     clock: -> { Time.now.utc },
                     uuid_generator: -> { SecureRandom.uuid })
        @path = File.expand_path(path)
        @migrations_dir = File.expand_path(migrations_dir)
        @busy_timeout_ms = Integer(busy_timeout_ms)
        @sqlite_version = sqlite_version.to_s
        @feature_probe = feature_probe
        @clock = clock
        @uuid_generator = uuid_generator
        @owner_pid = Process.pid
        @connection = nil
        @validated = false
        ProcessGuard.register(self)
      end

      def open!
        ProcessGuard.checkout { open_uncoordinated! }
        self
      end

      def migrate!
        ProcessGuard.checkout do
          ensure_process_owner!
          validate_migration_set!
          verify_runtime_capabilities!

          if File.exist?(path)
            diagnosis = diagnostics_uncoordinated
            if %i[unrelated_database corrupt newer_schema].include?(diagnosis.status)
              raise_for_diagnosis!(diagnosis)
            end
          end

          FileUtils.mkdir_p(File.dirname(path))
          connect!
          Sequel::IntegerMigrator.new(
            @connection, @migrations_dir,
            table: :schema_info, column: :version, use_transactions: true
          ).run
          ensure_installation_identity!
          validate_connected_schema!
          @validated = true
        end
        self
      rescue Error
        raise
      rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => error
        disconnect
        raise IntegrityError.new(
          "runtime control-plane migration failed: #{error.message}",
          code: :migration_failed,
          action: "restore the recovery set or rerun hive migrate --all after correcting storage",
          details: { error_class: error.class.name }
        )
      end

      def read
        ProcessGuard.checkout do
          ensure_open!
          yield @connection
        end
      end

      def transaction(mode: :immediate)
        ProcessGuard.checkout(transaction: true) do
          ensure_open!
          @connection.transaction(mode: mode, rollback: :reraise) do
            yield @connection
          end
        end
      end

      def migration_current?
        diagnostics.ok?
      end

      def schema_version
        diagnostics.schema_version
      end

      def application_id
        diagnostics.application_id
      end

      def settings
        read do |database|
          {
            journal_mode: pragma(database, "journal_mode").to_s.downcase,
            foreign_keys: Integer(pragma(database, "foreign_keys")),
            synchronous: Integer(pragma(database, "synchronous")),
            trusted_schema: Integer(pragma(database, "trusted_schema")),
            busy_timeout_ms: Integer(pragma(database, "busy_timeout"))
          }
        end
      end

      def diagnostics
        ProcessGuard.checkout { diagnostics_uncoordinated }
      end

      def disconnect
        @connection&.disconnect
        @connection = nil
        @validated = false
        true
      end

      def disconnected?
        @connection.nil?
      end

      private

      def diagnostics_uncoordinated
        ensure_process_owner!
        return diagnosis(:missing) unless File.file?(path)

        inspect_database do |database|
          application_id = integer_pragma(database, "application_id")
          version = schema_version_for(database)
          integrity = pragma_rows(database, "quick_check").map(&:to_s)
          foreign_key_errors = pragma_rows(database, "foreign_key_check")

          if application_id != APPLICATION_ID
            error = IntegrityError.new(
              "#{path} is not Hive's runtime control-plane database",
              code: :application_id_mismatch,
              action: "select the configured Hive state home; do not replace this file in place"
            )
            return diagnosis(
              :unrelated_database, application_id: application_id,
              schema_version: version, integrity: integrity, error: error
            )
          end
          unless integrity == [ "ok" ] && foreign_key_errors.empty?
            error = IntegrityError.new(
              "runtime control-plane integrity check failed",
              code: :integrity_check_failed,
              action: "stop Hive and restore a verified recovery set"
            )
            return diagnosis(
              :corrupt, application_id: application_id,
              schema_version: version, integrity: integrity, error: error
            )
          end
          if version.nil?
            return migration_diagnosis(:missing_schema, application_id, version, integrity)
          end
          if version < SCHEMA_VERSION
            return migration_diagnosis(:older_schema, application_id, version, integrity)
          end
          if version > SCHEMA_VERSION
            return migration_diagnosis(:newer_schema, application_id, version, integrity)
          end
          unless exact_schema?(database)
            return migration_diagnosis(:partial_schema, application_id, version, integrity)
          end

          diagnosis(
            :ok, application_id: application_id, schema_version: version,
            integrity: integrity
          )
        end
      rescue Error
        raise
      rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => error
        failure = IntegrityError.new(
          "runtime control-plane database is unreadable: #{error.message}",
          code: :database_corrupt,
          action: "stop Hive and restore a verified recovery set",
          details: { error_class: error.class.name }
        )
        diagnosis(:corrupt, error: failure)
      end

      def ensure_open!
        ensure_process_owner!
        open_uncoordinated! unless @connection && @validated
      end

      def open_uncoordinated!
        ensure_process_owner!
        validate_migration_set!
        verify_runtime_capabilities!
        diagnosis = diagnostics_uncoordinated
        raise_for_diagnosis!(diagnosis) unless diagnosis.ok?

        connect!
        validate_connected_schema!
        @validated = true
      end

      def ensure_process_owner!
        pid = Process.pid
        return if owner_pid == pid

        disconnect
        @owner_pid = pid
      end

      def connect!
        return @connection if @connection

        @connection = Sequel.connect(
          adapter: "sqlite", database: path, max_connections: 1,
          timeout: @busy_timeout_ms, disable_dqs: true
        )
        @connection.run("PRAGMA journal_mode = WAL")
        @connection.run("PRAGMA foreign_keys = ON")
        @connection.run("PRAGMA synchronous = FULL")
        @connection.run("PRAGMA trusted_schema = OFF")
        @connection
      end

      def inspect_database
        database = Sequel.connect(
          adapter: "sqlite", database: path, readonly: true,
          max_connections: 1, timeout: @busy_timeout_ms, disable_dqs: true
        )
        yield database
      ensure
        database&.disconnect
      end

      def verify_runtime_capabilities!
        minimum = Gem::Version.new(MINIMUM_SQLITE_VERSION)
        actual = Gem::Version.new(@sqlite_version)
        if actual < minimum
          raise Unavailable.new(
            "Hive requires SQLite #{minimum} or newer for partial indexes and RETURNING " \
            "(found #{@sqlite_version})",
            code: :sqlite_version_unsupported,
            action: "install a supported sqlite3 gem build and rerun hive migrate --all"
          )
        end

        probe = Sequel.sqlite(max_connections: 1, disable_dqs: true)
        supported = @feature_probe ? @feature_probe.call(probe) : default_feature_probe(probe)
        return true if supported

        raise Unavailable.new(
          "SQLite is missing required partial-index or RETURNING support",
          code: :sqlite_feature_missing,
          action: "install a supported sqlite3 gem build and rerun hive migrate --all"
        )
      rescue Gem::Requirement::BadRequirementError, ArgumentError => error
        raise Unavailable.new(
          "SQLite version is unreadable: #{error.message}",
          code: :sqlite_version_unsupported,
          action: "install a supported sqlite3 gem build"
        )
      rescue Sequel::Error, SQLite3::Exception => error
        raise Unavailable.new(
          "SQLite required-feature probe failed: #{error.message}",
          code: :sqlite_feature_missing,
          action: "install a supported sqlite3 gem build",
          details: { error_class: error.class.name }
        )
      ensure
        probe&.disconnect
      end

      def default_feature_probe(database)
        database.create_table(:hive_feature_probe) do
          Integer :id, primary_key: true
          String :key
        end
        database.add_index(
          :hive_feature_probe, :key, unique: true,
          where: Sequel.lit("key IS NOT NULL"), name: :hive_feature_probe_uidx
        )
        row = database[:hive_feature_probe]
              .returning(:id)
              .insert(key: "supported")
        Array(row).first.fetch(:id) == 1
      end

      def validate_migration_set!
        files = Dir.children(@migrations_dir).grep(/\.rb\z/).sort
        versions = files.map do |name|
          match = /\A(\d{3})_[a-z0-9_]+\.rb\z/.match(name)
          unless match
            raise_migration_set!("invalid migration filename #{name.inspect}")
          end
          Integer(match[1], 10)
        end
        expected = (1..SCHEMA_VERSION).to_a
        unless versions == expected
          raise_migration_set!(
            "expected consecutive migrations #{expected.inspect}, found #{versions.inspect}"
          )
        end
        true
      rescue Errno::ENOENT, Errno::EACCES => error
        raise_migration_set!(error.message)
      end

      def raise_migration_set!(detail)
        raise MigrationRequired.new(
          "runtime control-plane migration set is invalid: #{detail}",
          code: :migration_set_invalid,
          action: "reinstall Hive, then rerun hive migrate --all"
        )
      end

      def ensure_installation_identity!
        return unless @connection[:installations].empty?

        identity = @uuid_generator.call
        @connection[:installations].insert(
          installation_id: identity,
          lineage_id: identity,
          activation_epoch: 0,
          created_at: Codec.dump_time(@clock.call)
        )
      end

      def validate_connected_schema!
        application = integer_pragma(@connection, "application_id")
        version = schema_version_for(@connection)
        unless application == APPLICATION_ID && version == SCHEMA_VERSION && exact_schema?(@connection)
          diagnosis = diagnostics_uncoordinated
          raise_for_diagnosis!(diagnosis)
        end
        true
      end

      def exact_schema?(database)
        tables = database.tables.map(&:to_sym)
        return false unless (tables - [ :schema_info ]).sort == EXPECTED_TABLES.sort

        indexes = database[:sqlite_master]
                  .where(type: "index")
                  .exclude(name: nil)
                  .select_map(:name)
                  .map(&:to_sym)
        EXPECTED_INDEXES.all? { |index| indexes.include?(index) }
      rescue Sequel::Error
        false
      end

      def schema_version_for(database)
        return nil unless database.table_exists?(:schema_info)

        value = database[:schema_info].get(:version)
        value.nil? ? nil : Integer(value)
      rescue ArgumentError, TypeError, Sequel::Error
        nil
      end

      def pragma(database, name)
        row = database.fetch("PRAGMA #{name}").first
        row&.values&.first
      end

      def integer_pragma(database, name)
        Integer(pragma(database, name))
      end

      def pragma_rows(database, name)
        database.fetch("PRAGMA #{name}").map do |row|
          values = row.values
          values.length == 1 ? values.first : values
        end
      end

      def migration_diagnosis(code, application_id, version, integrity)
        error = MigrationRequired.new(
          migration_message(code, version),
          code: code,
          action: "stop Hive and run hive migrate --all"
        )
        diagnosis(
          code, application_id: application_id, schema_version: version,
          integrity: integrity, error: error
        )
      end

      def migration_message(code, version)
        case code
        when :newer_schema
          "runtime control-plane schema #{version} is newer than this Hive " \
            "(expected #{SCHEMA_VERSION}); install the matching Hive release"
        when :partial_schema
          "runtime control-plane schema is incomplete; stop Hive and run hive migrate --all"
        else
          "runtime control-plane schema #{version || 'missing'} requires hive migrate --all"
        end
      end

      def diagnosis(status, application_id: nil, schema_version: nil,
                    integrity: nil, error: nil)
        Diagnosis.new(
          status: status, path: path, application_id: application_id,
          schema_version: schema_version, sqlite_version: @sqlite_version,
          integrity: integrity, error: error
        )
      end

      def raise_for_diagnosis!(diagnosis)
        raise diagnosis.error if diagnosis.error

        error = MigrationRequired.new(
          "runtime control-plane database is missing; run hive migrate --all",
          code: :missing_database,
          action: "run hive migrate --all"
        )
        raise error
      end
    end
  end
end
