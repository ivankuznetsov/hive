require "fileutils"
require "digest"
require "rubygems"
require "securerandom"
require "sequel"
require "sequel/extensions/migration"
require "sqlite3"
require "hive/atomic_file"
require "hive/runtime_control_plane/file_fence"
require "hive/runtime_control_plane/command_schema"

module Hive
  module RuntimeControlPlane
    EXPECTED_SCHEMA_SHA256 = "92cbd2aaa9f77ff9c294280d18116928d23f727430466a6306baf6ad08385cf0".freeze

    class Database
      MIGRATE_ACTION = "stop Hive writers and follow https://github.com/ivankuznetsov/hive/blob/main/docs/guides/current-format-migration.md; command receipts require explicit `hive setup --install-command-receipts`".freeze
      BACKUP_ACTION = "stop Hive and recover from an external backup".freeze
      STORAGE_ACTION = "Use a writable, accessible state root (HIVE_HOME).".freeze
      UNPAIRED_STORAGE_ACTION = "Use a writable state root (HIVE_HOME), or safely restore a matching WAL/SHM pair or remove the stray sidecar after verifying no committed data will be lost.".freeze
      MIGRATIONS = %w[001_create_runtime_control_plane.rb].freeze
      attr_reader :path, :owner_pid

      WriterAuthority = Data.define(:database_id, :owner_pid, :role) do
        def valid_for?(database, permitted_roles)
          database_id == database.object_id && owner_pid == Process.pid && permitted_roles.include?(role)
        end
      end
      private_constant :WriterAuthority

      def initialize(path: Hive::Paths.runtime_control_plane_path, migrations_dir: MIGRATIONS_DIR,
                     busy_timeout_ms: BUSY_TIMEOUT_MS, sqlite_version: SQLite3::SQLITE_VERSION,
                     feature_probe: nil, clock: -> { Time.now.utc },
                     uuid_generator: -> { SecureRandom.uuid }, proc_root: "/proc",
                     platform: RUBY_PLATFORM)
        @path = File.expand_path(path)
        @migrations_dir = File.expand_path(migrations_dir)
        @busy_timeout_ms = Integer(busy_timeout_ms)
        @sqlite_version = sqlite_version.to_s
        @feature_probe = feature_probe
        @clock = clock
        @uuid_generator = uuid_generator
        @proc_root = File.expand_path(proc_root)
        @platform = platform.to_s
        @owner_pid = Process.pid
        @connection = nil
        @validated = false
        @active_writer_authorities = {}
      end

      def open!(revalidate: true, timeout_sec: nil)
        if operational_inspection_active?
          operational_read(timeout_sec: timeout_sec) { true }
          return self
        end

        ProcessGuard.checkout do
          revalidate ? open_uncoordinated!(timeout_sec: timeout_sec) :
            ensure_open!(timeout_sec: timeout_sec)
        end
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
        return operational_read { |database| yield database } if operational_inspection_active?

        ProcessGuard.checkout do
          ensure_open!
          @connection.run("PRAGMA query_only = ON")
          yield @connection
        ensure
          @connection&.run("PRAGMA query_only = OFF")
        end
      end

      # Inspection path for receipt dry-runs. It deliberately avoids
      # ensure_open!/connect!, which set WAL and connection pragmas. Refuse a
      # recovering WAL shape instead of letting a preview create sidecars.
      def read_only
        ProcessGuard.checkout do
          ensure_process_owner!
          validate_database_custody!
          wal = File.exist?("#{path}-wal")
          shm = File.exist?("#{path}-shm")
          unless wal && shm
            raise Hive::CommandCapacityError.new(
              "command prune preview requires the existing SQLite WAL and SHM sidecars; " \
              "open the runtime normally before retrying the zero-write preview",
              reason: :command_prune_preview_unavailable, scope: :installation
            )
          end
          inspect_database(sidecar_policy: false) { |connection| yield connection }
        end
      end

      # Validated reader for operational observation. The caller decides
      # whether an invocation is eligible to use this path; Database owns the
      # connection and preserves custody, identity, schema, and integrity
      # validation before yielding it.
      def operational_read(timeout_sec: nil)
        ProcessGuard.checkout do
          ensure_process_owner!
          deadline = timeout_sec.nil? ? nil :
            Process.clock_gettime(Process::CLOCK_MONOTONIC) + [ Float(timeout_sec), 0.0 ].max
          diagnosis = deadline ? diagnostics_uncoordinated(timeout_sec: remaining_timeout(deadline)) :
            diagnostics_uncoordinated
          raise_for_diagnosis!(diagnosis) unless diagnosis.ok?
          deadline ? inspect_database(timeout_sec: remaining_timeout(deadline)) { |database| yield database } :
            inspect_database { |database| yield database }
        end
      end

      # Linux procfs mount metadata is the only confirmation mechanism for the
      # operational fallback. Permission bits and write probes are deliberately
      # not evidence that the backing mount itself is read-only.
      def confirmed_read_only_storage?
        ProcessGuard.checkout do
          ensure_process_owner!
          storage_mount_status == :read_only
        end
      rescue SystemCallError, IOError, ArgumentError
        false
      end

      # Translate only storage-access failures, following wrapped causes. A
      # nil result means the caller must preserve the original error and its
      # existing corruption/schema/contention handling.
      def storage_error_for(error, unpaired_sidecar: false)
        chain = error_chain(error)
        read_only = chain.any? { |candidate| read_only_storage_error?(candidate) }
        cant_open = chain.any? { |candidate| cant_open_storage_error?(candidate) }
        inaccessible = chain.any? { |candidate| inaccessible_storage_error?(candidate) }
        confirmed_read_only = confirmed_read_only_storage?
        return unless read_only || cant_open || inaccessible

        if read_only || (cant_open && confirmed_read_only) || unpaired_sidecar
          action = unpaired_sidecar ? UNPAIRED_STORAGE_ACTION : STORAGE_ACTION
          message = if confirmed_read_only
            "Hive state is mounted read-only at #{File.dirname(path)}"
          else
            "Hive state storage is read-only at #{File.dirname(path)}"
          end
          return Unavailable.new(
            message, code: :state_storage_read_only, action: action,
            details: storage_error_details(error, chain, confirmed_read_only: confirmed_read_only)
          )
        end

        Unavailable.new(
          "Hive state storage is inaccessible at #{File.dirname(path)}",
          code: :state_storage_inaccessible, action: STORAGE_ACTION,
          details: storage_error_details(error, chain, confirmed_read_only: confirmed_read_only)
        )
      end

      def transaction(mode: :immediate, authority: nil, cleanup_attempt_id: nil,
                      timeout_sec: nil, track_mutation: true)
        if operational_inspection_active?
          raise Unavailable.new(
            "Hive state is mounted read-only at #{File.dirname(path)}",
            code: :state_storage_read_only, action: STORAGE_ACTION,
            details: { path: path, confirmed_read_only: true }
          )
        end

        fence_timeout = timeout_sec.nil? ? @busy_timeout_ms / 1000.0 :
          [ Float(timeout_sec), 0.0 ].max
        wait_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        ProcessGuard.checkout { ensure_open!(timeout_sec: fence_timeout) }
        writer_timeout = if timeout_sec.nil?
          fence_timeout
        else
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - wait_started
          [ fence_timeout - elapsed, 0.0 ].max
        end
        with_writer_fence(authority: authority, timeout_sec: writer_timeout) do
          ProcessGuard.checkout(transaction: true) do
            sqlite_timeout = if timeout_sec.nil?
              fence_timeout
            else
              elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - wait_started
              [ fence_timeout - elapsed, 0.0 ].max
            end
            ensure_open!(timeout_sec: sqlite_timeout) if @connection.nil?
            prior = integer_pragma(@connection, "busy_timeout") unless timeout_sec.nil?
            @connection.run("PRAGMA busy_timeout = #{(sqlite_timeout * 1000).floor}") if prior
            begin
              @connection.transaction(mode: mode, rollback: :reraise) do
                authorize_mutation!(@connection, authority: authority,
                                    cleanup_attempt_id: cleanup_attempt_id)
                increment_mutation_sequence!(@connection) if track_mutation
                yield @connection
              end
            ensure
              @connection&.run("PRAGMA busy_timeout = #{prior}") if prior
            end
          end
        end
      end

      def with_exclusive_writer(role:, timeout_sec: BUSY_TIMEOUT_MS / 1000.0)
        unless %i[controller migrator].include?(role)
          raise ArgumentError, "exclusive writer role must be controller or migrator"
        end
        fence = writer_fence(timeout_sec: timeout_sec)
        fence.acquire_exclusive!
        authority = authority_for(role)
        @active_writer_authorities[authority.object_id] = authority
        yield authority
      ensure
        @active_writer_authorities&.delete(authority&.object_id)
        fence&.release!
      end

      def checkpoint!(timeout_sec: BUSY_TIMEOUT_MS / 1000.0)
        timeout_ms = [ (Float(timeout_sec) * 1000).floor, 0 ].max
        ProcessGuard.checkout do
          ensure_open!(timeout_sec: timeout_sec)
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
              schema_fingerprint: schema_fingerprint(database),
              lifecycle: first_row(database, :runtime_lifecycle)
            }
          end
        end
      end

      # Read-only view of `running` attempts for QuiescenceUpgrade's live-owner
      # refusal. Works on the pinned v1 layout and the quiescence revisions.
      def quiescence_upgrade_running_attempts
        ProcessGuard.checkout do
          ensure_process_owner!
          return [] unless File.exist?(path)

          validate_database_custody!
          inspect_database do |database|
            next [] unless table_has_columns?(database, :attempts, :state, :heartbeat_at, :started_at)

            database[:attempts].where(state: "running")
              .select(:attempt_id, :task_slug, :started_at, :heartbeat_at).all
          end
        end
      end

      # Database-owned preserving conversion used only by QuiescenceUpgrade
      # while it holds operation ownership and the exclusive writer fence.
      def upgrade_quiescence!(authority:, expected_schema_version:, expected_fingerprint:,
                              preserve_lifecycle:, now: @clock.call)
        unless valid_authority?(authority) && authority.role == :migrator
          raise ArgumentError, "quiescence upgrade requires migrator authority"
        end

        source = quiescence_upgrade_source
        supported = source[:application_id] == APPLICATION_ID &&
          source[:schema_version] == Integer(expected_schema_version) &&
          source[:schema_fingerprint] == expected_fingerprint
        if preserve_lifecycle
          supported &&= %w[quiescing paused].include?(source.dig(:lifecycle, :phase))
        end
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

        copy_quiescence_source!(
          temporary_path, now: now, preserve_lifecycle: preserve_lifecycle
        )
        checkpoint_upgrade_source!
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

      # Bounded status-only view of the lifecycle and ownership rows. Unlike
      # #open!/#read this always uses SQLite's readonly mode, does not request
      # WAL, run migrations, perform housekeeping, or require the source
      # schema to match this binary. That makes daemon status useful during a
      # paused version-skew recovery without letting observation mutate the
      # storage it is meant to diagnose.
      def quiescence_status_snapshot
        ProcessGuard.checkout do
          ensure_process_owner!
          diagnosis = diagnostics_uncoordinated
          return empty_quiescence_snapshot(diagnosis) if diagnosis.status == :missing

          validate_database_custody!
          inspect_database do |database|
            {
              diagnosis: diagnosis,
              installation_id: first_value(database, :installations, :installation_id),
              lifecycle: first_row(database, :runtime_lifecycle),
              reservations: rows_with_states(database, :launch_reservations, %w[reserved]),
              processes: rows_except_state(database, :owned_processes, "stopped"),
              attempts: rows_with_states(database, :attempts, %w[launching running])
            }
          end
        end
      rescue Error
        raise
      rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => error
        storage_error = storage_error_for(error)
        raise storage_error if storage_error

        raise IntegrityError.new(
          "runtime lifecycle status is unreadable: #{error.message}",
          code: :database_corrupt, action: BACKUP_ACTION,
          details: { error_class: error.class.name }
        )
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

      def operational_inspection_active?
        defined?(RuntimeControlPlane::OperationalInspection) &&
          RuntimeControlPlane::OperationalInspection.active_for?(path)
      end

      def empty_quiescence_snapshot(diagnosis)
        {
          diagnosis: diagnosis, installation_id: nil, lifecycle: nil,
          reservations: [], processes: [], attempts: []
        }
      end

      def table_has_columns?(database, table, *columns)
        database.table_exists?(table) &&
          columns.all? { |column| database.schema(table).any? { |entry| entry.first == column } }
      rescue Sequel::Error
        false
      end

      def first_value(database, table, column)
        return unless table_has_columns?(database, table, column)

        database[table].get(column)
      end

      def first_row(database, table)
        return unless database.table_exists?(table)

        database[table].first
      rescue Sequel::Error
        nil
      end

      def rows_with_states(database, table, states)
        return [] unless table_has_columns?(database, table, :state)

        database[table].where(state: states).all
      rescue Sequel::Error
        []
      end

      def rows_except_state(database, table, state)
        return [] unless table_has_columns?(database, table, :state)

        database[table].exclude(state: state).all
      rescue Sequel::Error
        []
      end

      def diagnostics_uncoordinated(timeout_sec: nil)
        ensure_process_owner!
        return diagnosis(:missing) unless File.exist?(path) || File.symlink?(path)
        begin
          validate_database_custody!
        rescue IntegrityError => error
          return diagnosis(:corrupt, error: error)
        end
        inspect = lambda do |&block|
          timeout_sec.nil? ? inspect_database(&block) :
            inspect_database(timeout_sec: timeout_sec, &block)
        end
        inspect.call do |database|
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
        storage_error = storage_error_for(error)
        raise storage_error if storage_error

        diagnosis(:corrupt, error: IntegrityError.new(
          "runtime control-plane database is unreadable: #{error.message}",
          code: :database_corrupt, action: BACKUP_ACTION,
          details: { error_class: error.class.name }
        ))
      end

      def ensure_open!(timeout_sec: nil)
        ensure_process_owner!
        open_uncoordinated!(timeout_sec: timeout_sec) unless @connection && @validated
      end

      def open_uncoordinated!(timeout_sec: nil)
        ensure_process_owner!
        deadline = if timeout_sec.nil?
          nil
        else
          Process.clock_gettime(Process::CLOCK_MONOTONIC) + [ Float(timeout_sec), 0.0 ].max
        end
        validate_migration_set!
        verify_runtime_capabilities!
        diagnosis = deadline ? diagnostics_uncoordinated(timeout_sec: remaining_timeout(deadline)) :
          diagnostics_uncoordinated
        raise_for_diagnosis!(diagnosis) unless diagnosis.ok?
        deadline ? connect!(timeout_sec: remaining_timeout(deadline)) : connect!
        validate_connected_schema!
        @validated = true
      end

      def ensure_process_owner!
        return if owner_pid == Process.pid
        disconnect
        @owner_pid = Process.pid
      end

      def connect!(timeout_sec: nil)
        return @connection if @connection
        validate_database_custody!
        timeout_ms = timeout_sec.nil? ? @busy_timeout_ms :
          [ (Float(timeout_sec) * 1000).floor, 0 ].max
        @connection = Sequel.connect(adapter: "sqlite", database: path, max_connections: 1,
                                     timeout: timeout_ms, disable_dqs: true)
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
      rescue Error
        disconnect_preserving_error
        raise
      rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => error
        storage_error = storage_error_for(error)
        disconnect_preserving_error
        raise storage_error if storage_error

        raise
      end

      def inspect_database(timeout_sec: nil, sidecar_policy: true)
        timeout_ms = timeout_sec.nil? ? @busy_timeout_ms :
          [ (Float(timeout_sec) * 1000).floor, 0 ].max
        unless sidecar_policy
          database = Sequel.connect(adapter: "sqlite", database: path, readonly: true,
                                    max_connections: 1, timeout: timeout_ms, disable_dqs: true)
          return yield database
        end

        validate_database_custody!
        immutable = false
        options = {
          adapter: "sqlite", database: path, readonly: true,
          max_connections: 1, timeout: timeout_ms, disable_dqs: true
        }
        if confirmed_read_only_storage?
          sidecars = inspection_sidecars
          present = sidecars.filter_map { |candidate, status| candidate if status }
          if present.one?
            raise unpaired_sidecar_error(present.first)
          elsif present.empty?
            immutable = true
            options[:database] = sqlite_immutable_uri(path)
            options[:uri] = true
          end
        end

        begin
          database = Sequel.connect(**options)
          if immutable && inspection_sidecars.any? { |_candidate, status| status }
            raise Unavailable.new(
              "Hive state sidecars appeared while immutable inspection was opening",
              code: :state_storage_read_only, action: STORAGE_ACTION,
              details: { path: path, confirmed_read_only: true }
            )
          end
          # Force SQLite to initialize and read the database before a caller's
          # block begins. Storage failures here are opening failures; errors
          # from the caller's own SQL below are deliberately not reclassified.
          database.fetch("PRAGMA schema_version").first
        rescue Error
          disconnect_inspection(database)
          raise
        rescue Sequel::Error, SQLite3::Exception, SystemCallError, IOError => error
          storage_error = storage_error_for(error)
          disconnect_inspection(database)
          raise storage_error if storage_error

          raise
        end

        yield database
      ensure
        disconnect_inspection(database)
      end

      def inspection_sidecars
        [ "#{path}-wal", "#{path}-shm" ].map do |candidate|
          status = lstat_if_present(candidate)
          validate_file_custody!(candidate, status) if status
          [ candidate, status ]
        end
      end

      def unpaired_sidecar_error(candidate)
        Unavailable.new(
          "Hive state is mounted read-only with an unpaired SQLite sidecar: #{candidate}",
          code: :state_storage_read_only, action: UNPAIRED_STORAGE_ACTION,
          details: { path: path, sidecar: candidate, confirmed_read_only: true }
        )
      end

      def disconnect_inspection(database)
        active_error = $!
        database&.disconnect
      rescue StandardError => cleanup_error
        raise cleanup_error unless active_error
      end

      def disconnect_preserving_error
        active_error = $!
        disconnect
      rescue StandardError => cleanup_error
        raise cleanup_error unless active_error
      end

      def remaining_timeout(deadline)
        [ deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.0 ].max
      end

      def storage_mount_status
        return :unconfirmed unless @platform.include?("linux")

        target = File.realpath(File.dirname(path))
        rows = File.binread(File.join(@proc_root, "self", "mountinfo")).lines
        parsed = rows.map { |line| parse_mountinfo_line(line) }
        return :unconfirmed if parsed.any?(&:nil?)

        matches = parsed.select do |row|
          mount_point = row.fetch(:mount_point)
          mount_point == "/" || target == mount_point || target.start_with?("#{mount_point}/")
        end
        return :unconfirmed if matches.empty?

        deepest_length = matches.map { |row| row.fetch(:mount_point).length }.max
        deepest = matches.select { |row| row.fetch(:mount_point).length == deepest_length }
        return :unconfirmed unless deepest.one?

        row = deepest.first
        (row.fetch(:mount_options) + row.fetch(:super_options)).include?("ro") ?
          :read_only : :writable
      rescue SystemCallError, IOError, ArgumentError
        :unconfirmed
      end

      def parse_mountinfo_line(line)
        fields = line.split
        separator = fields.index("-")
        return unless separator && separator >= 6 && fields.length > separator + 3

        mount_point = decode_mountinfo_path(fields.fetch(4))
        return unless mount_point&.start_with?("/")

        {
          mount_point: mount_point,
          mount_options: fields.fetch(5).split(","),
          super_options: fields.fetch(separator + 3).split(",")
        }
      rescue IndexError
        nil
      end

      def decode_mountinfo_path(value)
        value.gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }
      end

      def sqlite_immutable_uri(database_path)
        encoded = database_path.b.each_byte.map do |byte|
          character = byte.chr
          if character.match?(/[A-Za-z0-9\-._~\/]/)
            character
          else
            format("%%%02X", byte)
          end
        end.join
        "file:#{encoded}?immutable=1"
      end

      def error_chain(error)
        seen = {}
        chain = []
        current = error
        while current && !seen[current.object_id]
          seen[current.object_id] = true
          chain << current
          current = current.cause
        end
        chain
      end

      def read_only_storage_error?(error)
        error.is_a?(Errno::EROFS) || error.is_a?(SQLite3::ReadOnlyException) ||
          sqlite_primary_result_code(error) == SQLite3::Constants::ErrorCode::READONLY
      end

      def cant_open_storage_error?(error)
        error.is_a?(SQLite3::CantOpenException) ||
          sqlite_primary_result_code(error) == SQLite3::Constants::ErrorCode::CANTOPEN
      end

      def inaccessible_storage_error?(error)
        error.is_a?(SystemCallError) || error.is_a?(IOError) || cant_open_storage_error?(error)
      end

      def sqlite_primary_result_code(error)
        return unless error.respond_to?(:code)

        code = error.code
        Integer(code) & 0xff if code
      rescue ArgumentError, TypeError
        nil
      end

      def storage_error_details(error, chain, confirmed_read_only:)
        {
          error_class: error.class.name,
          cause_chain: chain.map do |candidate|
            detail = { error_class: candidate.class.name }
            code = candidate.respond_to?(:code) ? candidate.code : nil
            detail[:sqlite_code] = code if code
            detail
          end,
          confirmed_read_only: confirmed_read_only,
          state_path: File.dirname(path)
        }
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

      def with_writer_fence(authority:, timeout_sec:)
        if valid_authority?(authority)
          yield
        else
          fence = writer_fence(timeout_sec: timeout_sec)
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
        authority.is_a?(WriterAuthority) &&
          @active_writer_authorities[authority.object_id].equal?(authority) &&
          authority.valid_for?(self, %i[controller migrator])
      end

      def authorize_mutation!(connection, authority:, cleanup_attempt_id:)
        lifecycle = connection[:runtime_lifecycle].first
        return unless lifecycle
        return if lifecycle.fetch(:phase) == "running"
        return if valid_authority?(authority)

        if cleanup_attempt_id && lifecycle.fetch(:phase) == "quiescing"
          inserted = connection[:quiescence_cleanup_writes].insert_conflict
            .returning(:attempt_id).insert(
            installation_id: lifecycle.fetch(:installation_id),
            generation: lifecycle.fetch(:generation), attempt_id: cleanup_attempt_id.to_s,
            created_at: Codec.dump_time(@clock.call)
          )
          return unless Array(inserted).empty?
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
        extension_rows, base_rows = schema_rows(database).partition do |row|
          CommandSchema.extension_object?(row[1])
        end
        base_valid = Digest::SHA256.hexdigest(Codec.dump_json(base_rows)) == expected
        extension_valid = extension_rows.empty? ||
          (extension_rows.map { |row| row[1].to_s }.sort == CommandSchema::OBJECT_NAMES.sort &&
           Digest::SHA256.hexdigest(Codec.dump_json(extension_rows)) ==
             CommandSchema::EXPECTED_SCHEMA_SHA256 &&
           CommandSchema.version_ledger_exact?(database))
        base_valid && extension_valid
      rescue Sequel::Error
        false
      end

      def schema_fingerprint(database)
        Digest::SHA256.hexdigest(Codec.dump_json(schema_rows(database)))
      end

      def schema_rows(database)
        database[:sqlite_master].where(type: %w[table index trigger])
          .exclude(name: "schema_info").exclude(Sequel.like(:name, "sqlite_%"))
          .order(:type, :name).select_map([ :type, :name, :tbl_name, :sql ])
      end

      def copy_quiescence_source!(temporary_path, now:, preserve_lifecycle:)
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
          installations runtime_lifecycle launch_reservations owned_processes
          quiescence_cleanup_writes projects task_subjects dispatch_requests attempts
          task_leases token_usage daemon_runtime payload_references
        ]
        target.transaction(mode: :immediate, rollback: :reraise) do
          target.tables.reject { |table| table == :schema_info }.reverse_each do |table|
            target[table].delete
          end
          retained.each do |table|
            next unless source.table_exists?(table)

            source_columns = source.schema(table).map(&:first)
            target_columns = target.schema(table).map(&:first)
            columns = source_columns & target_columns
            source[table].select(*columns).each_slice(250) do |rows|
              target[table].multi_insert(rows) unless rows.empty?
            end
          end
          preserve_lifecycle ? preserve_closed_lifecycle!(target, now: now) :
            establish_closed_lifecycle!(target, now: now)
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
        unless integer_pragma(target, "foreign_keys") == 1
          raise IntegrityError.new(
            "runtime quiescence upgrade could not restore foreign-key enforcement",
            code: :quiescence_upgrade_foreign_keys_disabled, action: BACKUP_ACTION
          )
        end
        unless schema_fingerprint(target) == EXPECTED_SCHEMA_SHA256
          raise IntegrityError.new(
            "runtime quiescence upgrade did not render the current schema",
            code: :quiescence_upgrade_schema_mismatch, action: BACKUP_ACTION
          )
        end
        target.fetch("PRAGMA wal_checkpoint(TRUNCATE)").all
      ensure
        source&.disconnect
        target&.disconnect
      end

      def establish_closed_lifecycle!(target, now:)
        identity = target[:installations].get(:installation_id)
        target[:runtime_lifecycle].insert(
          installation_id: identity, phase: "quiescing", generation: 1, revision: 0,
          mutation_sequence: 1, interrupted_attempt_ids_json: "[]",
          quiesce_started_at: Codec.dump_time(now), updated_at: Codec.dump_time(now)
        )
      end

      def preserve_closed_lifecycle!(target, now:)
        lifecycle = target[:runtime_lifecycle].first
        unless lifecycle && %w[quiescing paused].include?(lifecycle.fetch(:phase))
          raise IntegrityError.new(
            "quiescence upgrade source no longer has closed admission",
            code: :quiescence_upgrade_requires_closed_lifecycle, action: MIGRATE_ACTION
          )
        end

        changed = target[:runtime_lifecycle].where(
          installation_id: lifecycle.fetch(:installation_id)
        ).update(
          phase: "quiescing", revision: lifecycle.fetch(:revision) + 1,
          mutation_sequence: lifecycle.fetch(:mutation_sequence) + 1,
          paused_at: nil, updated_at: Codec.dump_time(now)
        )
        unless changed == 1
          raise IntegrityError.new(
            "quiescence upgrade could not preserve the lifecycle row",
            code: :quiescence_upgrade_lifecycle_failed, action: BACKUP_ACTION
          )
        end
      end

      def replace_with_upgraded_database!(temporary_path)
        disconnect
        remove_file_if_present("#{path}-wal")
        remove_file_if_present("#{path}-shm")
        File.chmod(0o600, temporary_path)
        File.rename(temporary_path, path)
        Hive::AtomicFile.fsync_directory(File.dirname(path))
      end

      def checkpoint_upgrade_source!
        source = Sequel.connect(
          adapter: "sqlite", database: path, max_connections: 1,
          timeout: @busy_timeout_ms, disable_dqs: true
        )
        values = source.fetch("PRAGMA wal_checkpoint(TRUNCATE)").first.values.map do |value|
          Integer(value)
        end
        busy, log_frames, checkpointed_frames = values
        unless busy.zero? && checkpointed_frames >= log_frames
          raise IntegrityError.new(
            "runtime quiescence upgrade could not preserve the source WAL",
            code: :quiescence_upgrade_source_checkpoint_failed, action: BACKUP_ACTION,
            details: { busy: busy, log_frames: log_frames,
                       checkpointed_frames: checkpointed_frames }
          )
        end
        Hive::AtomicFile.fsync_directory(File.dirname(path))
        true
      ensure
        source&.disconnect
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
          status = lstat_if_present(candidate)
          validate_file_custody!(candidate, status) if status
        end
        true
      rescue SystemCallError => error
        storage_error = storage_error_for(error)
        raise storage_error if storage_error

        raise IntegrityError.new(
          "runtime control-plane storage is unsafe: #{error.message}",
          code: :database_custody_invalid, action: BACKUP_ACTION
        )
      end

      def lstat_if_present(candidate)
        File.lstat(candidate)
      rescue Errno::ENOENT
        nil
      end

      def validate_file_custody!(candidate, status)
        custody_error!(candidate) unless status.file? && !status.symlink? && status.nlink == 1 &&
          status.uid == Process.euid && (status.mode & 0o077).zero?
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
