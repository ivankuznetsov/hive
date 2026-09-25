require "fileutils"
require "digest"
require "rubygems"
require "securerandom"
require "sequel"
require "sequel/extensions/migration"
require "sqlite3"
require "hive/atomic_file"
require "hive/runtime_control_plane/file_fence"

module Hive
  module RuntimeControlPlane
    EXPECTED_SCHEMA_SHA256 = "484dfc25ef94ab9c06867351308121ba2ce904f1e7f1ef6dc004f45b8d65e479".freeze

    class Database
      MIGRATE_ACTION = "stop Hive, back up state, and follow https://github.com/ivankuznetsov/hive/blob/main/docs/guides/current-format-migration.md".freeze
      BACKUP_ACTION = "stop Hive and recover from an external backup".freeze
      MIGRATIONS = %w[001_create_runtime_control_plane.rb].freeze
      attr_reader :path, :owner_pid

      WriterAuthority = Data.define(:database_id, :owner_pid, :role) do
        def valid_for?(database, permitted_roles)
          database_id == database.object_id && owner_pid == Process.pid && permitted_roles.include?(role)
        end
      end

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
          diagnosis = diagnostics_uncoordinated
          if diagnosis.status != :missing
            raise_for_diagnosis!(diagnosis) unless diagnosis.ok?
            open_uncoordinated!
            next
          end
          FileUtils.mkdir_p(File.dirname(path))
          prepare_storage!
          connect!
          Sequel::IntegerMigrator.new(@connection, @migrations_dir, table: :schema_info,
                                      column: :version, use_transactions: true).run
          @connection[:schema_info].update(version: SCHEMA_VERSION)
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
                                 action: BACKUP_ACTION,
                                 details: { error_class: error.class.name })
      end

      def read
        ProcessGuard.checkout do
          ensure_open!
          @connection.run("PRAGMA query_only = ON")
          yield @connection
        ensure
          @connection&.run("PRAGMA query_only = OFF")
        end
      end

      def transaction(mode: :immediate, authority: nil, cleanup_attempt_id: nil)
        with_writer_fence(authority: authority) do
          ProcessGuard.checkout(transaction: true) do
            ensure_open!
            @connection.transaction(mode: mode, rollback: :reraise) do
              authorize_mutation!(@connection, authority: authority,
                                  cleanup_attempt_id: cleanup_attempt_id)
              increment_mutation_sequence!(@connection)
              yield @connection
            end
          end
        end
      end

      def controller_transaction(mode: :immediate, &block)
        transaction(mode: mode, authority: authority_for(:controller), &block)
      end

      def migrator_transaction(mode: :immediate, &block)
        transaction(mode: mode, authority: authority_for(:migrator), &block)
      end

      def with_exclusive_writer(role:, timeout_sec: BUSY_TIMEOUT_MS / 1000.0)
        unless %i[controller migrator].include?(role)
          raise ArgumentError, "exclusive writer role must be controller or migrator"
        end
        fence = writer_fence(timeout_sec: timeout_sec)
        fence.acquire_exclusive!
        yield authority_for(role)
      ensure
        fence&.release!
      end

      def checkpoint!(timeout_sec: BUSY_TIMEOUT_MS / 1000.0)
        timeout_ms = [(Float(timeout_sec) * 1000).floor, 0].max
        ProcessGuard.checkout do
          ensure_open!
          prior = integer_pragma(@connection, "busy_timeout")
          @connection.run("PRAGMA busy_timeout = #{timeout_ms}")
          row = @connection.fetch("PRAGMA wal_checkpoint(FULL)").first
          values = row.values.map { |value| Integer(value) }
          busy, log_frames, checkpointed_frames = values
          {
            complete: busy.zero?, busy: busy, log_frames: log_frames,
            checkpointed_frames: checkpointed_frames
          }
        ensure
          @connection&.run("PRAGMA busy_timeout = #{prior}") if prior
        end
      end

      def quiescence_upgrade_source
        ProcessGuard.checkout do
          ensure_process_owner!
          return { status: :missing } unless File.exist?(path)
          validate_database_custody!
          inspect_database do |database|
            {
              status: :present,
              application_id: integer_pragma(database, "application_id"),
              schema_version: schema_version_for(database),
              schema_fingerprint: schema_fingerprint(database)
            }
          end
        end
      end

      # Database-owned preserving conversion used only by QuiescenceUpgrade
      # while it holds operation ownership and the exclusive writer fence.
      def upgrade_quiescence_v1!(authority:, expected_fingerprint:, now: @clock.call)
        unless valid_authority?(authority) && authority.role == :migrator
          raise ArgumentError, "quiescence upgrade requires migrator authority"
        end

        source = quiescence_upgrade_source
        supported = source[:application_id] == APPLICATION_ID && source[:schema_version] == 1 &&
          source[:schema_fingerprint] == expected_fingerprint
        unless supported
          raise MigrationRequired.new(
            "runtime control-plane format is not a supported quiescence upgrade source",
            code: :unsupported_quiescence_upgrade_source, action: MIGRATE_ACTION,
            details: source
          )
        end

        disconnect
        temporary_path = File.join(
          File.dirname(path), ".runtime-quiescence-upgrade-#{@uuid_generator.call}.sqlite3"
        )
        target = self.class.new(
          path: temporary_path, migrations_dir: @migrations_dir,
          busy_timeout_ms: @busy_timeout_ms, sqlite_version: @sqlite_version,
          feature_probe: @feature_probe, clock: @clock, uuid_generator: @uuid_generator
        ).migrate!
        target.disconnect

        copy_quiescence_v1!(temporary_path, now: now)
        replace_with_upgraded_database!(temporary_path)
        open!
        self
      rescue Error
        raise
      rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => error
        raise IntegrityError.new(
          "runtime quiescence upgrade failed: #{error.message}", code: :quiescence_upgrade_failed,
          action: BACKUP_ACTION, details: { error_class: error.class.name }
        )
      ensure
        target&.disconnect
        remove_file_if_present(temporary_path) if temporary_path && temporary_path != path
        remove_file_if_present("#{temporary_path}-wal") if temporary_path
        remove_file_if_present("#{temporary_path}-shm") if temporary_path
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
        action += " and rerun hive setup" unless message.start_with?("SQLite version is unreadable")
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
                                    action: "reinstall Hive, then rerun hive setup")
      end

      def ensure_installation_identity!
        now = Codec.dump_time(@clock.call)
        if @connection[:installations].empty?
          identity = @uuid_generator.call
          @connection[:installations].insert(installation_id: identity,
                                             activation_epoch: 0,
                                             created_at: now)
        end
        identity = @connection[:installations].get(:installation_id)
        @connection[:runtime_lifecycle].insert_conflict.insert(
          installation_id: identity, phase: "running", generation: 0, revision: 0,
          mutation_sequence: 0, interrupted_attempt_ids_json: "[]", updated_at: now
        )
      end

      def with_writer_fence(authority:)
        if valid_authority?(authority)
          yield
        else
          fence = writer_fence(timeout_sec: @busy_timeout_ms / 1000.0)
          fence.synchronize(:shared) { yield }
        end
      end

      def writer_fence(timeout_sec:)
        FileFence.new(
          path: Hive::Paths.runtime_writer_fence_path(File.dirname(path)),
          timeout_sec: timeout_sec
        )
      end

      def authority_for(role) = WriterAuthority.new(object_id, Process.pid, role)

      def valid_authority?(authority)
        authority.is_a?(WriterAuthority) && authority.valid_for?(self, %i[controller migrator])
      end

      def authorize_mutation!(connection, authority:, cleanup_attempt_id:)
        lifecycle = connection[:runtime_lifecycle].first
        return unless lifecycle
        return if lifecycle.fetch(:phase) == "running"
        return if valid_authority?(authority)

        if cleanup_attempt_id && lifecycle.fetch(:phase) == "quiescing"
          inserted = connection[:quiescence_cleanup_writes].insert_conflict.insert(
            installation_id: lifecycle.fetch(:installation_id),
            generation: lifecycle.fetch(:generation), attempt_id: cleanup_attempt_id.to_s,
            created_at: Codec.dump_time(@clock.call)
          )
          return if inserted
        end

        raise AdmissionClosed.new(
          "runtime admission is closed while lifecycle is #{lifecycle.fetch(:phase)}",
          details: { phase: lifecycle.fetch(:phase), generation: lifecycle.fetch(:generation) }
        )
      end

      def increment_mutation_sequence!(connection)
        connection[:runtime_lifecycle].update(
          mutation_sequence: Sequel[:mutation_sequence] + 1,
          updated_at: Codec.dump_time(@clock.call)
        )
      end

      def validate_connected_schema!
        valid = integer_pragma(@connection, "application_id") == APPLICATION_ID &&
          schema_version_for(@connection) == SCHEMA_VERSION && exact_schema?(@connection)
        raise_for_diagnosis!(diagnostics_uncoordinated) unless valid
        true
      end

      def exact_schema?(database, expected: EXPECTED_SCHEMA_SHA256)
        schema_fingerprint(database) == expected
      rescue Sequel::Error
        false
      end


      def schema_fingerprint(database)
        rows = database[:sqlite_master].where(type: %w[table index])
          .exclude(name: "schema_info").exclude(Sequel.like(:name, "sqlite_%"))
          .order(:type, :name).select_map([ :type, :name, :tbl_name, :sql ])
        Digest::SHA256.hexdigest(Codec.dump_json(rows))
      end

      def copy_quiescence_v1!(temporary_path, now:)
        source = Sequel.connect(
          adapter: "sqlite", database: path, readonly: true, max_connections: 1,
          timeout: @busy_timeout_ms, disable_dqs: true
        )
        target = Sequel.connect(
          adapter: "sqlite", database: temporary_path, max_connections: 1,
          timeout: @busy_timeout_ms, disable_dqs: true
        )
        target.run("PRAGMA foreign_keys = OFF")
        retained = %i[
          installations projects task_subjects dispatch_requests attempts task_leases
          token_usage daemon_runtime payload_references
        ]
        target.transaction(mode: :immediate, rollback: :reraise) do
          target.tables.reject { |table| table == :schema_info }.reverse_each do |table|
            target[table].delete
          end
          retained.each do |table|
            source[table].each_slice(250) { |rows| target[table].multi_insert(rows) unless rows.empty? }
          end
          identity = target[:installations].get(:installation_id)
          target[:runtime_lifecycle].insert(
            installation_id: identity, phase: "quiescing", generation: 1, revision: 0,
            mutation_sequence: 1, interrupted_attempt_ids_json: "[]",
            quiesce_started_at: Codec.dump_time(now), updated_at: Codec.dump_time(now)
          )
          target[:schema_info].update(version: SCHEMA_VERSION)
        end
        violations = target.fetch("PRAGMA foreign_key_check").all
        unless violations.empty?
          raise IntegrityError.new(
            "runtime quiescence upgrade produced foreign-key violations",
            code: :quiescence_upgrade_foreign_key_failed, action: BACKUP_ACTION,
            details: { count: violations.length }
          )
        end
        target.run("PRAGMA foreign_keys = ON")
        target.fetch("PRAGMA wal_checkpoint(TRUNCATE)").all
      ensure
        source&.disconnect
        target&.disconnect
      end

      def replace_with_upgraded_database!(temporary_path)
        disconnect
        remove_file_if_present("#{path}-wal")
        remove_file_if_present("#{path}-shm")
        File.chmod(0o600, temporary_path)
        File.rename(temporary_path, path)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end

      def remove_file_if_present(candidate)
        return unless candidate && (File.exist?(candidate) || File.symlink?(candidate))
        File.delete(candidate)
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
          "runtime control-plane schema #{version || 'missing'} is unsupported; #{MIGRATE_ACTION}"
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
        raise MigrationRequired.new("runtime control-plane database is missing; run hive setup",
                                    code: :missing_database, action: "run hive setup")
      end
    end
  end
end
