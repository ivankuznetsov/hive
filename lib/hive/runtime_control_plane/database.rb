require "fileutils"
require "digest"
require "rubygems"
require "securerandom"
require "sequel"
require "sequel/extensions/migration"
require "sqlite3"
require "hive/atomic_file"

module Hive
  module RuntimeControlPlane
    EXPECTED_SCHEMA_SHA256 = "5cfd5ef2b31a0ae59cf461ff33ae9bcce1740374043f4bda2364f8889d23064f".freeze

    class Database
      MIGRATE_ACTION = "stop Hive and run hive migrate --all".freeze
      BACKUP_ACTION = "stop Hive and recover from an external backup".freeze
      MIGRATIONS = %w[001_create_runtime_control_plane.rb].freeze
      attr_reader :path, :owner_pid

      def initialize(path: Hive::Paths.runtime_control_plane_path, migrations_dir: MIGRATIONS_DIR,
                     busy_timeout_ms: BUSY_TIMEOUT_MS, sqlite_version: SQLite3::SQLITE_VERSION,
                     feature_probe: nil, clock: -> { Time.now.utc },
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
      end

      def open!(revalidate: true)
        ProcessGuard.checkout { revalidate ? open_uncoordinated! : ensure_open! }
        self
      end

      def migrate!
        ProcessGuard.checkout do
          ensure_process_owner!
          validate_migration_set!
          verify_runtime_capabilities!
          diagnosis = diagnostics_uncoordinated if File.exist?(path)
          raise_for_diagnosis!(diagnosis) if diagnosis &&
            %i[unrelated_database corrupt newer_schema].include?(diagnosis.status)
          FileUtils.mkdir_p(File.dirname(path))
          prepare_storage!
          connect!
          Sequel::IntegerMigrator.new(@connection, @migrations_dir, table: :schema_info,
                                      column: :version, use_transactions: true).run
          ensure_installation_identity!
          validate_connected_schema!
          @validated = true
        end
        self
      rescue Error
        raise
      rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => error
        disconnect
        raise IntegrityError.new("runtime control-plane migration failed: #{error.message}",
                                 code: :migration_failed,
                                 action: "correct storage and resume the incomplete cutover; " \
                                         "active recovery requires an external backup",
                                 details: { error_class: error.class.name })
      end

      def read
        ProcessGuard.checkout { ensure_open!; yield @connection }
      end

      def transaction(mode: :immediate)
        ProcessGuard.checkout(transaction: true) do
          ensure_open!
          @connection.transaction(mode: mode, rollback: :reraise) { yield @connection }
        end
      end

      def installation_identity
        ProcessGuard.checkout do
          diagnosis = diagnostics_uncoordinated
          raise_for_diagnosis!(diagnosis) unless diagnosis.ok?
          inspect_database { |database| database[:installations].first }
        end
      end

      def diagnostics = ProcessGuard.checkout { diagnostics_uncoordinated }
      def disconnect
        connection = @connection
        @connection = nil
        @validated = false
        connection&.disconnect
        true
      ensure
        ProcessGuard.unregister(self)
      end
      def disconnected? = @connection.nil?

      private

      def diagnostics_uncoordinated
        ensure_process_owner!
        return diagnosis(:missing) unless File.exist?(path) || File.symlink?(path)
        begin
          validate_database_custody!
        rescue IntegrityError => error
          return diagnosis(:corrupt, error: error)
        end
        inspect_database do |database|
          application_id = integer_pragma(database, "application_id")
          version = schema_version_for(database)
          integrity = pragma_rows(database, "quick_check").map(&:to_s)
          if application_id != APPLICATION_ID
            return diagnosis(:unrelated_database, application_id: application_id,
                             schema_version: version, integrity: integrity,
                             error: IntegrityError.new(
                               "#{path} is not Hive's runtime control-plane database",
                               code: :application_id_mismatch,
                               action: "select the configured Hive state home; do not replace this file in place"
                             ))
          end
          unless integrity == [ "ok" ] && pragma_rows(database, "foreign_key_check").empty?
            return diagnosis(:corrupt, application_id: application_id, schema_version: version,
                             integrity: integrity, error: IntegrityError.new(
                               "runtime control-plane integrity check failed",
                               code: :integrity_check_failed, action: BACKUP_ACTION
                             ))
          end
          status = if version.nil?
            :missing_schema
          elsif version < SCHEMA_VERSION
            :older_schema
          elsif version > SCHEMA_VERSION
            :newer_schema
          elsif !exact_schema?(database)
            :partial_schema
          end
          return migration_diagnosis(status, application_id, version, integrity) if status
          diagnosis(:ok, application_id: application_id, schema_version: version, integrity: integrity)
        end
      rescue Error
        raise
      rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => error
        diagnosis(:corrupt, error: IntegrityError.new(
          "runtime control-plane database is unreadable: #{error.message}",
          code: :database_corrupt, action: BACKUP_ACTION,
          details: { error_class: error.class.name }
        ))
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
        return if owner_pid == Process.pid
        disconnect
        @owner_pid = Process.pid
      end

      def connect!
        return @connection if @connection
        validate_database_custody!
        @connection = Sequel.connect(adapter: "sqlite", database: path, max_connections: 1,
                                     timeout: @busy_timeout_ms, disable_dqs: true)
        ProcessGuard.register(self)
        journal_mode = pragma_rows(@connection, "journal_mode = WAL").first.to_s.downcase
        unless journal_mode == "wal"
          raise IntegrityError.new(
            "runtime control-plane storage does not support SQLite WAL mode",
            code: :wal_mode_unavailable, action: "move Hive state to a local WAL-capable filesystem"
          )
        end
        %w[foreign_keys\ =\ ON synchronous\ =\ FULL trusted_schema\ =\ OFF]
          .each { |setting| @connection.run("PRAGMA #{setting}") }
        validate_database_custody!
        @connection
      end

      def inspect_database
        database = Sequel.connect(adapter: "sqlite", database: path, readonly: true,
                                  max_connections: 1, timeout: @busy_timeout_ms, disable_dqs: true)
        yield database
      ensure
        database&.disconnect
      end

      def verify_runtime_capabilities!
        minimum = Gem::Version.new(MINIMUM_SQLITE_VERSION)
        actual = Gem::Version.new(@sqlite_version)
        unavailable!(:sqlite_version_unsupported,
                     "Hive requires SQLite #{minimum} or newer for partial indexes and RETURNING " \
                     "(found #{@sqlite_version})") if actual < minimum
        probe = Sequel.sqlite(max_connections: 1, disable_dqs: true)
        supported = @feature_probe ? @feature_probe.call(probe) : default_feature_probe(probe)
        unavailable!(:sqlite_feature_missing,
                     "SQLite is missing required partial-index or RETURNING support") unless supported
        true
      rescue Gem::Requirement::BadRequirementError, ArgumentError => error
        unavailable!(:sqlite_version_unsupported, "SQLite version is unreadable: #{error.message}")
      rescue Sequel::Error, SQLite3::Exception => error
        unavailable!(:sqlite_feature_missing, "SQLite required-feature probe failed: #{error.message}",
                     error: error)
      ensure
        probe&.disconnect
      end

      def unavailable!(code, message, error: nil)
        action = "install a supported sqlite3 gem build"
        action += " and rerun hive migrate --all" unless message.start_with?("SQLite version is unreadable")
        raise Unavailable.new(message, code: code, action: action,
                              details: error ? { error_class: error.class.name } : {})
      end

      def default_feature_probe(database)
        database.create_table(:hive_feature_probe) { primary_key :id; String :key }
        database.add_index(:hive_feature_probe, :key, unique: true,
                           where: Sequel.lit("key IS NOT NULL"), name: :hive_feature_probe_uidx)
        Array(database[:hive_feature_probe].returning(:id).insert(key: "supported")).first.fetch(:id) == 1
      end

      def validate_migration_set!
        files = Dir.children(@migrations_dir).grep(/\.rb\z/).sort
        raise_migration_set!("expected #{MIGRATIONS.inspect}, found #{files.inspect}") unless files == MIGRATIONS
        true
      rescue Errno::ENOENT, Errno::EACCES => error
        raise_migration_set!(error.message)
      end

      def raise_migration_set!(detail)
        raise MigrationRequired.new("runtime control-plane migration set is invalid: #{detail}",
                                    code: :migration_set_invalid,
                                    action: "reinstall Hive, then rerun hive migrate --all")
      end

      def ensure_installation_identity!
        return unless @connection[:installations].empty?
        identity = @uuid_generator.call
        @connection[:installations].insert(installation_id: identity,
                                           activation_epoch: 0,
                                           created_at: Codec.dump_time(@clock.call))
      end

      def validate_connected_schema!
        valid = integer_pragma(@connection, "application_id") == APPLICATION_ID &&
          schema_version_for(@connection) == SCHEMA_VERSION && exact_schema?(@connection)
        raise_for_diagnosis!(diagnostics_uncoordinated) unless valid
        true
      end

      def exact_schema?(database)
        rows = database[:sqlite_master].where(type: %w[table index])
          .exclude(name: "schema_info").exclude(Sequel.like(:name, "sqlite_%"))
          .order(:type, :name).select_map([ :type, :name, :tbl_name, :sql ])
        Digest::SHA256.hexdigest(Codec.dump_json(rows)) == EXPECTED_SCHEMA_SHA256
      rescue Sequel::Error
        false
      end

      def prepare_storage!
        parent = File.dirname(path)
        FileUtils.mkdir_p(parent, mode: 0o700)
        parent_status = File.lstat(parent)
        unless parent_status.directory? && !parent_status.symlink? && parent_status.uid == Process.euid
          custody_error!(parent)
        end
        File.chmod(0o700, parent)
        return validate_database_custody! if File.exist?(path) || File.symlink?(path)

        flags = File::WRONLY | File::CREAT | File::EXCL
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        File.open(path, flags, 0o600) { |file| file.fsync }
        Hive::AtomicFile.fsync_directory(parent)
        validate_database_custody!
      rescue Errno::ELOOP, Errno::EEXIST, SystemCallError, IOError => error
        raise IntegrityError.new(
          "runtime control-plane storage is unsafe: #{error.message}",
          code: :database_custody_invalid, action: BACKUP_ACTION
        )
      end

      def validate_database_custody!
        parent = File.lstat(File.dirname(path))
        custody_error!(File.dirname(path)) unless
          parent.directory? && !parent.symlink? && parent.uid == Process.euid && (parent.mode & 0o077).zero?
        [ path, "#{path}-wal", "#{path}-shm" ].each do |candidate|
          next unless File.exist?(candidate) || File.symlink?(candidate)
          status = File.lstat(candidate)
          custody_error!(candidate) unless status.file? && !status.symlink? && status.nlink == 1 &&
            status.uid == Process.euid && (status.mode & 0o077).zero?
        end
        true
      rescue SystemCallError => error
        raise IntegrityError.new(
          "runtime control-plane storage is unsafe: #{error.message}",
          code: :database_custody_invalid, action: BACKUP_ACTION
        )
      end

      def custody_error!(candidate)
        raise IntegrityError.new(
          "runtime control-plane storage has unsafe custody: #{candidate}",
          code: :database_custody_invalid, action: BACKUP_ACTION,
          details: { path: candidate }
        )
      end

      def schema_version_for(database)
        return unless database.table_exists?(:schema_info)
        value = database[:schema_info].get(:version)
        value.nil? ? nil : Integer(value)
      rescue ArgumentError, TypeError, Sequel::Error
        nil
      end

      def pragma_rows(database, name)
        database.fetch("PRAGMA #{name}").map do |row|
          values = row.values
          values.one? ? values.first : values
        end
      end
      def integer_pragma(database, name) = Integer(pragma_rows(database, name).first)

      def migration_diagnosis(status, application_id, version, integrity)
        message = case status
        when :newer_schema
          "runtime control-plane schema #{version} is newer than this Hive " \
            "(expected #{SCHEMA_VERSION}); install the matching Hive release"
        when :partial_schema
          "runtime control-plane schema is incomplete; #{MIGRATE_ACTION}"
        else
          "runtime control-plane schema #{version || 'missing'} requires hive migrate --all"
        end
        diagnosis(status, application_id: application_id, schema_version: version,
                  integrity: integrity,
                  error: MigrationRequired.new(message, code: status, action: MIGRATE_ACTION))
      end

      def diagnosis(status, application_id: nil, schema_version: nil, integrity: nil, error: nil)
        Diagnosis.new(status: status, path: path, application_id: application_id,
                      schema_version: schema_version, sqlite_version: @sqlite_version,
                      integrity: integrity, error: error)
      end

      def raise_for_diagnosis!(diagnosis)
        raise diagnosis.error if diagnosis&.error
        raise MigrationRequired.new("runtime control-plane database is missing; run hive migrate --all",
                                    code: :missing_database, action: "run hive migrate --all")
      end
    end
  end
end
