require "test_helper"
require "hive/runtime_control_plane"

class RuntimeControlPlaneDatabaseTest < Minitest::Test
  include HiveTestHelper

  def teardown
    Hive::RuntimeControlPlane.disconnect
    super
  end

  def test_writer_measurements_separate_acquisition_from_hold_and_follow_release
    with_database do |database, path|
      measurements = []
      database.instance_variable_set(:@transaction_observer, lambda do |measurement|
        probe = SQLite3::Database.new(path)
        probe.execute("BEGIN IMMEDIATE")
        probe.execute("ROLLBACK")
        probe.close
        measurements << measurement
      end)
      database.transaction(operation: "test.commit", identifiers: { attempt_id: "a" * 200 }) { 42 }
      error = assert_raises(RuntimeError) do
        database.transaction(operation: "test.rollback") { raise "original" }
      end
      assert_equal "original", error.message
      assert_equal %w[committed rolled_back], measurements.map { |item| item.fetch(:result) }
      assert_equal "test.commit", measurements.first.fetch(:operation)
      assert_equal 128, measurements.first.fetch(:attempt_id).length
      measurements.each do |item|
        assert_operator item.fetch(:wait_sec), :>=, 0
        assert_operator item.fetch(:hold_sec), :>=, 0
      end
      database.instance_variable_set(:@transaction_observer, ->(*) { raise "logging unavailable" })
      assert_equal 42, database.transaction { 42 }
      assert_raises(RuntimeError) { database.transaction { raise "rollback" } }
    end
  end

  def test_busy_acquisition_is_not_reported_as_a_long_writer_hold
    with_database do |database, path|
      measurements = []
      database.instance_variable_set(:@transaction_observer, ->(item) { measurements << item })
      blocker = SQLite3::Database.new(path)
      blocker.execute("BEGIN IMMEDIATE")
      assert_raises(Sequel::DatabaseError) do
        database.transaction(operation: "test.busy", timeout_sec: 0.05) { flunk }
      end
      assert_equal "acquisition_failed", measurements.last.fetch(:result)
      assert_nil measurements.last.fetch(:hold_sec)
      assert_operator measurements.last.fetch(:wait_sec), :>=, 0.03
    ensure
      blocker&.execute("ROLLBACK")
      blocker&.close
    end
  end

  def test_explicit_migration_creates_exact_database_and_normal_open_is_lazy
    with_tmp_dir do |root|
      path = File.join(root, "state", "runtime-control-plane.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(path: path)

      refute_path_exists path
      assert_equal :missing, database.diagnostics.status
      refute_path_exists path, "validation-only calls must not create SQLite state"

      database.migrate!

      assert_path_exists path
      diagnosis = database.diagnostics
      assert_equal :ok, diagnosis.status
      assert_equal Hive::RuntimeControlPlane::SCHEMA_VERSION, diagnosis.schema_version
      assert_equal Hive::RuntimeControlPlane::APPLICATION_ID, diagnosis.application_id
      assert_equal 1, database.read { |connection| connection[:installations].count }
    end
  end

  def test_live_connections_use_the_required_sqlite_settings
    with_database do |database|
      settings = database.read do |connection|
        pragma = ->(name) { connection.fetch("PRAGMA #{name}").first.values.first }
        {
          journal_mode: pragma.call("journal_mode").to_s.downcase,
          foreign_keys: pragma.call("foreign_keys"),
          synchronous: pragma.call("synchronous"),
          wal_autocheckpoint: pragma.call("wal_autocheckpoint"),
          trusted_schema: pragma.call("trusted_schema"),
          busy_timeout_ms: pragma.call("busy_timeout")
        }
      end

      assert_equal "wal", settings.fetch(:journal_mode)
      assert_equal 1, settings.fetch(:foreign_keys)
      assert_equal 2, settings.fetch(:synchronous)
      assert_equal 4096, settings.fetch(:wal_autocheckpoint)
      assert_equal 0, settings.fetch(:trusted_schema)
      assert_equal Hive::RuntimeControlPlane::BUSY_TIMEOUT_MS,
                   settings.fetch(:busy_timeout_ms)
      assert_raises(Sequel::DatabaseError) do
        database.read { |connection| connection.get(Sequel.lit('"not_a_column"')) }
      end
    end
  end

  def test_checkpoint_role_applies_to_cached_reopened_and_forked_connections
    with_database do |database, path|
      %i[daemon_backed manual].each do |role|
        expected = role == :daemon_backed ? 0 : 4096
        database.configure_checkpoint_role!(role)
        assert_equal expected, database.read { |sql| sql.fetch("PRAGMA wal_autocheckpoint").get(:wal_autocheckpoint) }
        database.disconnect
        assert_equal expected, database.read { |sql| sql.fetch("PRAGMA wal_autocheckpoint").get(:wal_autocheckpoint) }
        database.read(&:disconnect)
        assert_equal expected, database.read { |sql| sql.fetch("PRAGMA wal_autocheckpoint").get(:wal_autocheckpoint) },
                     "a replacement physical connection in the pool must inherit its role"
        reader, writer = IO.pipe
        pid = Hive::RuntimeControlPlane::ProcessGuard.fork do
          reader.close
          writer.write(database.read { |sql| sql.fetch("PRAGMA wal_autocheckpoint").get(:wal_autocheckpoint) })
          writer.close
          database.disconnect
          exit! 0
        end
        writer.close
        assert_equal expected.to_s, reader.read
        reader.close
        Process.wait(pid)
        assert_predicate $?, :success?
      end
      assert_raises(ArgumentError) { database.configure_checkpoint_role!(:controller) }
      Hive::RuntimeControlPlane.disconnect
      cached = Hive::RuntimeControlPlane.database(path: path)
      assert_same cached, Hive::RuntimeControlPlane.database(path: path, checkpoint_role: :daemon_backed)
      assert_equal :daemon_backed, cached.checkpoint_role
      assert_equal 0, cached.read { |sql| sql.fetch("PRAGMA wal_autocheckpoint").get(:wal_autocheckpoint) }
    end
  end

  def test_daemon_writes_cross_the_old_checkpoint_threshold_without_checkpointing
    with_database do |database, path|
      database.configure_checkpoint_role!(:daemon_backed)
      database.checkpoint!
      original_bytes = File.size(path)
      publish_large_snapshot(database, 5 * 1024 * 1024)

      assert_operator database.wal_bytes, :>, 1000 * 4096
      assert_equal original_bytes, File.size(path), "daemon commits must leave checkpoint work to maintenance"
      result = database.passive_checkpoint!
      assert result.fetch(:complete)
      assert_operator result.fetch(:checkpointed_frames), :>, 1000
      assert_operator File.size(path), :>, original_bytes
      assert_equal Hive::RuntimeControlPlane::BUSY_TIMEOUT_MS,
                   database.read { |sql| sql.fetch("PRAGMA busy_timeout").get(:timeout) }
    end
  end

  def test_manual_only_writes_automatically_checkpoint_at_the_raised_threshold
    with_database do |database, path|
      database.checkpoint!
      original_bytes = File.size(path)
      3.times { |index| publish_large_snapshot(database, 5 * 1024 * 1024, index) }
      assert_equal original_bytes, File.size(path), "the raised threshold must exceed the old 1000-page policy"
      publish_large_snapshot(database, 5 * 1024 * 1024, 3)

      assert_operator File.size(path), :>, original_bytes,
                      "manual-only writes must make automatic progress without a daemon or command hook"
      assert_equal 4096, database.read { |sql| sql.fetch("PRAGMA wal_autocheckpoint").get(:wal_autocheckpoint) }
    end
  end

  def test_passive_checkpoint_defers_a_pinned_reader_then_drains_without_blocking_writes
    with_database do |database, path|
      database.configure_checkpoint_role!(:daemon_backed)
      publish_large_snapshot(database, 100)
      database.checkpoint!
      reader = SQLite3::Database.new(path)
      reader.execute("BEGIN")
      reader.execute("SELECT observation_json FROM daemon_runtime")
      publish_large_snapshot(database, 2 * 1024 * 1024)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deferred = database.passive_checkpoint!
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
      refute deferred.fetch(:complete)
      assert_operator deferred.fetch(:remaining_frames), :>, 0
      assert_equal 0, deferred.fetch(:busy), "PASSIVE can report incomplete progress without SQLITE_BUSY"
      publish_large_snapshot(database, 2 * 1024 * 1024, 1)
      reader.execute("ROLLBACK")
      assert database.passive_checkpoint!.fetch(:complete)
    ensure
      reader&.close
    end
  end

  def test_passive_checkpoint_cannot_overlap_transactions_or_closed_lifecycle_without_authority
    with_database do |database|
      database.transaction do
        assert_raises(ArgumentError) { database.passive_checkpoint! }
      end
      database.transaction { |sql| sql[:runtime_lifecycle].update(phase: "quiescing") }
      assert_raises(Hive::RuntimeControlPlane::AdmissionClosed) { database.passive_checkpoint! }
      database.with_exclusive_writer(role: :controller) do |authority|
        assert database.passive_checkpoint!(authority: authority).fetch(:complete)
      end
      database.with_exclusive_writer(role: :migrator) do
        assert_raises(Hive::ConcurrentRunError) { database.passive_checkpoint!(timeout_sec: 0.01) }
      end
    end
  end

  def test_read_callbacks_are_sqlite_enforced_read_only
    with_database do |database|
      assert_raises(Sequel::DatabaseError) do
        database.read { |connection| connection[:installations].update(activation_epoch: 3) }
      end
      assert_equal 0, database.read { |connection| connection[:installations].get(:activation_epoch) }
    end
  end

  def test_transaction_sqlite_wait_uses_only_time_remaining_after_open_and_writer_fence
    with_database do |database|
      ensure_open = database.method(:ensure_open!)
      database.disconnect
      database.define_singleton_method(:ensure_open!) do |**options|
        sleep 0.03 if @connection.nil?
        ensure_open.call(**options)
      end
      database.define_singleton_method(:with_writer_fence) do |**_options, &block|
        sleep 0.03
        block.call
      end
      observed = database.transaction(timeout_sec: 0.1) do |connection|
        connection.fetch("PRAGMA busy_timeout").first.values.first
      end

      assert_operator observed, :<, 60
      assert_operator observed, :>=, 0
    end
  end

  def test_open_uses_one_timeout_across_inspection_and_live_connection
    database = Hive::RuntimeControlPlane::Database.new(path: "/tmp/runtime-timeout.sqlite3")
    observed = nil
    diagnosis = Hive::RuntimeControlPlane::Diagnosis.new(
      status: :ok, path: database.path, application_id: nil, schema_version: nil,
      sqlite_version: nil, integrity: [], error: nil
    )
    database.define_singleton_method(:validate_migration_set!) { true }
    database.define_singleton_method(:verify_runtime_capabilities!) { true }
    database.define_singleton_method(:validate_connected_schema!) { true }
    database.define_singleton_method(:diagnostics_uncoordinated) do |timeout_sec:|
      sleep 0.03
      diagnosis
    end
    database.define_singleton_method(:connect!) do |timeout_sec:|
      observed = timeout_sec
      @connection = Struct.new(:disconnect).new(true)
    end

    database.open!(timeout_sec: 0.1)

    assert_operator observed, :<, 0.08
    assert_operator observed, :>=, 0.0
  ensure
    database&.disconnect
  end

  def test_capped_transactions_restore_the_default_timeout_after_fresh_open_and_busy
    with_database do |database, path|
      database.disconnect
      timeout = database.transaction(timeout_sec: 0.2) do |connection|
        connection.fetch("PRAGMA busy_timeout").get
      end
      assert_operator timeout, :>, 0
      assert_operator timeout, :<=, 200
      assert_equal Hive::RuntimeControlPlane::BUSY_TIMEOUT_MS,
                   database.read { |connection| connection.fetch("PRAGMA busy_timeout").get }
      database.disconnect
      blocker = SQLite3::Database.new(path)
      blocker.execute("BEGIN IMMEDIATE")
      assert_raises(Sequel::DatabaseError) do
        database.transaction(timeout_sec: 0.1) { flunk "contended SQL must not enter the body" }
      end
      assert_equal Hive::RuntimeControlPlane::BUSY_TIMEOUT_MS,
                   database.read { |connection| connection.fetch("PRAGMA busy_timeout").get }
    ensure
      blocker&.execute("ROLLBACK")
      blocker&.close
    end
  end

  def test_submillisecond_remaining_budget_cannot_issue_zero_timeout_sql
    with_database do |database|
      fake_now = 0.0
      calls = []
      original_clock = Process.method(:clock_gettime)
      clock = ->(kind, *options) { kind == Process::CLOCK_MONOTONIC ? fake_now : original_clock.call(kind, *options) }
      original_fence = database.method(:with_writer_fence)
      database.define_singleton_method(:with_writer_fence) do |**options, &block|
        original_fence.call(**options) do
          fake_now = 0.0099
          block.call
        end
      end
      connection = database.instance_variable_get(:@connection)
      original_transaction = connection.method(:transaction)
      connection.define_singleton_method(:transaction) do |**options, &block|
        calls << options
        original_transaction.call(**options, &block)
      end
      with_replaced_singleton_method(Process, :clock_gettime, clock) do
        assert_raises(Hive::RuntimeControlPlane::FileFence::Busy) do
          database.transaction(timeout_sec: 0.01) { flunk "budget must expire before SQL" }
        end
      end
      assert_empty calls
      assert_equal Hive::RuntimeControlPlane::BUSY_TIMEOUT_MS,
                   database.read { |db| db.fetch("PRAGMA busy_timeout").get }
    end
  end

  def test_zero_timeout_controller_cleanup_attempts_sql_without_waiting
    with_database do |database, path|
      database.with_exclusive_writer(role: :controller) do |authority|
        observed = database.transaction(authority: authority, timeout_sec: 0) do |db|
          db[:installations].update(activation_epoch: 1)
          db.fetch("PRAGMA busy_timeout").get
        end
        assert_equal 0, observed

        blocker = SQLite3::Database.new(path)
        blocker.execute("BEGIN IMMEDIATE")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(Sequel::DatabaseError) do
          database.transaction(authority: authority, timeout_sec: 0) { flunk "blocked cleanup must not run" }
        end
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
        assert_equal Hive::RuntimeControlPlane::BUSY_TIMEOUT_MS,
                     database.read { |db| db.fetch("PRAGMA busy_timeout").get }
      ensure
        blocker&.execute("ROLLBACK")
        blocker&.close
      end
    end
  end

  def test_failed_open_and_fence_acquisition_keep_their_phase_timings
    with_database do |database|
      measurements = []
      database.instance_variable_set(:@transaction_observer, ->(item) { measurements << item })
      database.with_exclusive_writer(role: :controller, timeout_sec: 1) do |_authority|
        assert_raises(Hive::RuntimeControlPlane::FileFence::Busy) do
          database.transaction(timeout_sec: 0.05) { flunk "held fence must exclude SQL" }
        end
      end
      fenced = measurements.last
      assert_equal "acquisition_failed", fenced.fetch(:result)
      assert_operator fenced.fetch(:fence_sec), :>=, 0.01
      assert_equal 0, fenced.fetch(:sqlite_wait_sec)
      assert_nil fenced.fetch(:hold_sec)

      database.define_singleton_method(:ensure_open!) do |**|
        sleep 0.02
        raise Hive::RuntimeControlPlane::FileFence::Busy, "injected opening contention"
      end
      assert_raises(Hive::RuntimeControlPlane::FileFence::Busy) do
        database.transaction(timeout_sec: 0.05) { flunk "failed open must exclude SQL" }
      end
      opening = measurements.last
      assert_operator opening.fetch(:open_sec), :>=, 0.01
      assert_equal 0, opening.fetch(:fence_sec)
      assert_equal 0, opening.fetch(:sqlite_wait_sec)
      assert_nil opening.fetch(:hold_sec)
    end
  end

  def test_bounded_reads_restore_timeout_and_query_only_after_success_error_and_tiny_budget
    with_database do |database|
      connection = database.instance_variable_get(:@connection)
      connection.run("PRAGMA busy_timeout = 3456")
      observed = database.read(timeout_sec: 0.2) do |db|
        db.fetch("PRAGMA busy_timeout").get
      end
      assert_operator observed, :>, 0
      assert_operator observed, :<=, 200
      assert_equal 3456, connection.fetch("PRAGMA busy_timeout").get
      assert_equal 0, connection.fetch("PRAGMA query_only").get

      error = assert_raises(RuntimeError) do
        database.read(timeout_sec: 0.1) { raise "original read failure" }
      end
      assert_equal "original read failure", error.message
      assert_equal 3456, connection.fetch("PRAGMA busy_timeout").get
      assert_equal 0, connection.fetch("PRAGMA query_only").get

      assert_raises(Hive::RuntimeControlPlane::FileFence::Busy) do
        database.read(timeout_sec: 0.0001) { flunk "submillisecond read must not yield SQL" }
      end
      assert_equal 3456, connection.fetch("PRAGMA busy_timeout").get
      assert_equal 0, connection.fetch("PRAGMA query_only").get
    end
  end

  def test_database_is_the_only_runtime_control_plane_connection_owner
    root = File.expand_path("../../../lib/hive/runtime_control_plane", __dir__)
    offenders = Dir.glob(File.join(root, "**/*.rb")).reject do |path|
      path == File.join(root, "database.rb")
    end.select do |path|
      File.binread(path).include?("Sequel.connect")
    end

    assert_empty offenders
  end

  def test_read_only_preview_refuses_an_unpaired_recovery_sidecar
    with_database do |database, path|
      database.disconnect
      File.binwrite("#{path}-wal", "recovering")
      File.chmod(0o600, "#{path}-wal")

      error = assert_raises(Hive::CommandCapacityError) do
        database.read_only { flunk "an unpaired WAL must not be opened" }
      end
      assert_equal "command_prune_preview_unavailable", error.reason
    end
  end

  def test_mountinfo_confirmation_uses_the_deepest_decoded_component_match
    with_tmp_dir do |root|
      state = File.join(root, "state root")
      nested = File.join(state, "nested")
      FileUtils.mkdir_p(nested)
      path = File.join(nested, "runtime.sqlite3")
      mountinfo = [
        mountinfo_row("/", options: "rw,relatime", super_options: "rw"),
        mountinfo_row(state, options: "rw,relatime", super_options: "rw"),
        mountinfo_row(nested, options: "ro,nosuid", super_options: "rw")
      ].join

      database = database_with_mountinfo(path, mountinfo: mountinfo)

      assert database.confirmed_read_only_storage?

      writable = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(nested, options: "rw,relatime", super_options: "rw")
      )
      refute writable.confirmed_read_only_storage?
    end
  end

  def test_mountinfo_confirmation_fails_closed_off_linux_or_without_unambiguous_metadata
    with_tmp_dir do |root|
      real = File.join(root, "real")
      linked = File.join(root, "linked")
      FileUtils.mkdir_p(real)
      File.symlink(real, linked)
      path = File.join(linked, "runtime.sqlite3")

      non_linux = database_with_mountinfo(
        path, mountinfo: mountinfo_row(real, options: "ro", super_options: "ro"),
        platform: "darwin"
      )
      refute non_linux.confirmed_read_only_storage?

      ambiguous = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(real, options: "ro", super_options: "ro") * 2
      )
      refute ambiguous.confirmed_read_only_storage?

      lexical_only = database_with_mountinfo(
        path, mountinfo: mountinfo_row(linked, options: "ro", super_options: "ro")
      )
      refute lexical_only.confirmed_read_only_storage?,
             "mount matching must use the resolved storage path"

      unreadable_mountinfo = Hive::RuntimeControlPlane::Database.new(
        path: File.join(real, "runtime.sqlite3")
      )
      unreadable_mountinfo.define_singleton_method(:storage_mount_status) do
        raise IOError, "mountinfo unreadable"
      end
      refute unreadable_mountinfo.confirmed_read_only_storage?
    end
  end

  def test_mountinfo_confirmation_fails_closed_on_any_malformed_row
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      database = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(root, options: "ro", super_options: "ro") +
          "36 25 0:32 / #{root} ro no-separator-row\n"
      )

      refute database.confirmed_read_only_storage?,
             "a matching read-only row must not confirm a partially unparseable table"
      assert_equal(
        { status: :unconfirmed, reason: :invalid_mountinfo },
        database.instance_variable_get(:@storage_mount_diagnostic)
      )
    end
  end

  def test_mount_confirmation_fails_closed_when_post_fork_reset_fails
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      database = database_with_mountinfo(
        path, mountinfo: mountinfo_row(root, options: "ro", super_options: "ro")
      )
      assert database.confirmed_read_only_storage?

      database.instance_variable_set(:@owner_pid, Process.pid + 1)
      database.define_singleton_method(:disconnect) { raise IOError, "inherited handle" }

      refute database.confirmed_read_only_storage?
    end
  end

  def test_mountinfo_parser_fails_closed_if_a_validated_field_disappears
    fields = Array.new(10, "field")
    fields[6] = "-"
    fields.define_singleton_method(:fetch) do |index|
      raise IndexError, "field disappeared" if index == 4

      super(index)
    end
    line = Object.new
    line.define_singleton_method(:split) { fields }
    database = Hive::RuntimeControlPlane::Database.new(path: "/tmp/runtime.sqlite3")

    assert_nil database.send(:parse_mountinfo_line, line)
  end

  def test_storage_errors_are_typed_from_direct_and_wrapped_causes
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      database = database_with_mountinfo(
        path, mountinfo: mountinfo_row(root, options: "ro", super_options: "ro")
      )
      readonly = SQLite3::ReadOnlyException.new("readonly")
      wrapped = begin
        raise Sequel::DatabaseError.new("wrapped"), cause: readonly
      rescue Sequel::DatabaseError => error
        error
      end

      [ Errno::EROFS.new(path), readonly, wrapped ].each do |source|
        error = database.storage_error_for(source)
        assert_instance_of Hive::RuntimeControlPlane::Unavailable, error
        assert_equal :state_storage_read_only, error.code
        assert_equal Hive::RuntimeControlPlane::Database::STORAGE_ACTION, error.action
        assert_match(/mounted read-only/, error.message)
      end

      inaccessible = database.storage_error_for(Errno::EACCES.new(path))
      assert_equal :state_storage_inaccessible, inaccessible.code
      assert_equal Hive::RuntimeControlPlane::Database::STORAGE_ACTION, inaccessible.action

      writable = database_with_mountinfo(
        path, mountinfo: mountinfo_row(root, options: "rw", super_options: "rw")
      )
      direct_readonly = writable.storage_error_for(Errno::EROFS.new(path))
      assert_match(/storage is read-only/, direct_readonly.message)
      refute_match(/mounted read-only/, direct_readonly.message)

      assert_nil database.storage_error_for(SQLite3::BusyException.new("busy"))
    end
  end

  def test_cantopen_is_read_only_only_with_independent_mount_confirmation
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      cantopen = SQLite3::CantOpenException.new("cannot open")
      read_only = database_with_mountinfo(
        path, mountinfo: mountinfo_row(root, options: "rw", super_options: "ro")
      ).storage_error_for(cantopen)
      assert_equal :state_storage_read_only, read_only.code

      writable = database_with_mountinfo(
        path, mountinfo: mountinfo_row(root, options: "rw", super_options: "rw")
      ).storage_error_for(cantopen)
      assert_equal :state_storage_inaccessible, writable.code
    end
  end

  def test_operational_read_uses_immutable_for_confirmed_read_only_clean_storage
    with_database do |database, path|
      database.checkpoint!
      database.disconnect
      refute_path_exists "#{path}-wal"
      refute_path_exists "#{path}-shm"
      database = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(File.dirname(path), options: "ro", super_options: "ro")
      )
      connections = []
      original = Sequel.method(:connect)
      replacement = lambda do |**options, &block|
        connections << options.dup
        original.call(**options, &block)
      end

      count = with_replaced_singleton_method(Sequel, :connect, replacement) do
        database.operational_read(timeout_sec: 1) do |connection|
          connection[:installations].count
        end
      end

      assert_equal 1, count
      assert_operator connections.length, :>=, 2
      assert connections.all? { |options| options[:readonly] }
      assert connections.all? { |options| options.fetch(:database).end_with?("?immutable=1") }
      refute connections.any? { |options| options.key?(:uri) },
             "Sequel's SQLite adapter uses the database URI itself, not a :uri option"
    end
  end

  def test_operational_read_uses_plain_readonly_for_paired_sidecars_and_sees_wal_rows
    writer = nil
    with_database do |database, path|
      database.disconnect
      writer = SQLite3::Database.new(path)
      writer.execute("PRAGMA journal_mode = WAL")
      writer.execute("PRAGMA wal_autocheckpoint = 0")
      writer.execute("UPDATE installations SET next_task_id = 41")
      [ "#{path}-wal", "#{path}-shm" ].each { |candidate| File.chmod(0o600, candidate) }
      database = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(File.dirname(path), options: "ro", super_options: "ro")
      )
      connections = []
      original = Sequel.method(:connect)
      replacement = lambda do |**options, &block|
        connections << options.dup
        original.call(**options, &block)
      end

      next_task_id = with_replaced_singleton_method(Sequel, :connect, replacement) do
        database.operational_read { |connection| connection[:installations].get(:next_task_id) }
      end

      assert_equal 41, next_task_id
      assert connections.all? { |options| options[:readonly] }
      refute connections.any? { |options| options.fetch(:database).include?("immutable") }
    ensure
      writer&.close
    end
  end

  def test_paired_sidecar_recovery_failure_preserves_underlying_sqlite_evidence
    with_database do |database, path|
      database.disconnect
      writer = SQLite3::Database.new(path)
      writer.execute("PRAGMA journal_mode = WAL")
      writer.execute("PRAGMA wal_autocheckpoint = 0")
      writer.execute("UPDATE installations SET next_task_id = 42")
      [ "#{path}-wal", "#{path}-shm" ].each { |candidate| File.chmod(0o600, candidate) }
      database = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(File.dirname(path), options: "ro", super_options: "ro")
      )
      original = Sequel.method(:connect)
      replacement = lambda do |**options, &block|
        if options[:readonly]
          raise SQLite3::CantOpenException, "unable to recover WAL index"
        end
        original.call(**options, &block)
      end

      error = with_replaced_singleton_method(Sequel, :connect, replacement) do
        assert_raises(Hive::RuntimeControlPlane::Unavailable) { database.operational_read { flunk } }
      end

      assert_equal :state_storage_read_only, error.code
      assert_equal Hive::RuntimeControlPlane::Database::STORAGE_ACTION, error.action
      assert error.details.fetch(:cause_chain).any? { |cause| cause[:error_class].include?("CantOpen") }
    ensure
      writer&.close
      database&.disconnect
    end
  end

  def test_non_linux_operational_read_uses_plain_readonly_inspection
    with_database do |database, path|
      database.checkpoint!
      database.disconnect
      database = database_with_mountinfo(
        path,
        platform: "darwin",
        mountinfo: mountinfo_row(File.dirname(path), options: "ro", super_options: "ro")
      )
      connections = []
      original = Sequel.method(:connect)
      replacement = lambda do |**options, &block|
        connections << options.dup
        original.call(**options, &block)
      end

      assert_equal 1, with_replaced_singleton_method(Sequel, :connect, replacement) {
        database.operational_read { |connection| connection[:installations].count }
      }
      assert connections.all? { |options| options[:readonly] }
      refute connections.any? { |options| options.fetch(:database).include?("immutable") }
    ensure
      database&.disconnect
    end
  end

  def test_operational_read_rejects_either_unpaired_sidecar_with_exact_guidance
    %w[wal shm].each do |sidecar|
      with_database do |database, path|
        database.checkpoint!
        database.disconnect
        File.binwrite("#{path}-#{sidecar}", "unpaired")
        File.chmod(0o600, "#{path}-#{sidecar}")
        database = database_with_mountinfo(
          path,
          mountinfo: mountinfo_row(File.dirname(path), options: "ro", super_options: "ro")
        )

        error = assert_raises(Hive::RuntimeControlPlane::Unavailable) do
          database.operational_read { flunk "unpaired storage must not be inspected" }
        end

        assert_equal :state_storage_read_only, error.code
        assert_equal Hive::RuntimeControlPlane::Database::UNPAIRED_STORAGE_ACTION, error.action
        refute_match(/backup/i, error.action)
        counterpart = sidecar == "wal" ? "shm" : "wal"
        refute_path_exists "#{path}-#{counterpart}"
      end
    end
  end

  def test_writable_operational_inspection_never_uses_immutable
    with_database do |database, path|
      database.checkpoint!
      database.disconnect
      database = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(File.dirname(path), options: "rw", super_options: "rw")
      )
      connections = []
      original = Sequel.method(:connect)
      replacement = lambda do |**options, &block|
        connections << options.dup
        original.call(**options, &block)
      end

      assert_equal 1, with_replaced_singleton_method(Sequel, :connect, replacement) {
        database.operational_read { |connection| connection[:installations].count }
      }
      refute connections.any? { |options| options.fetch(:database).include?("immutable") }
    end
  end

  def test_immutable_inspection_escapes_sqlite_uri_paths
    with_tmp_dir do |root|
      state = File.join(root, "state # question?")
      FileUtils.mkdir_p(state, mode: 0o700)
      path = File.join(state, "runtime #?.sqlite3")
      Hive::RuntimeControlPlane::Database.new(path: path).migrate!.tap do |database|
        database.checkpoint!
        database.disconnect
      end
      database = database_with_mountinfo(
        path, mountinfo: mountinfo_row(state, options: "ro", super_options: "ro")
      )

      assert_equal 1, database.operational_read { |connection| connection[:installations].count }
    ensure
      database&.disconnect
    end
  end

  def test_sidecar_appearing_during_immutable_open_discards_the_inspection
    with_database do |database, path|
      database.checkpoint!
      database.disconnect
      database = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(File.dirname(path), options: "ro", super_options: "ro")
      )
      original = Sequel.method(:connect)
      disconnects = 0
      replacement = lambda do |**options, &block|
        connection = original.call(**options, &block)
        original_disconnect = connection.method(:disconnect)
        connection.define_singleton_method(:disconnect) do
          disconnects += 1
          original_disconnect.call
        end
        File.binwrite("#{path}-wal", "appeared")
        File.chmod(0o600, "#{path}-wal")
        connection
      end
      yielded = false

      error = with_replaced_singleton_method(Sequel, :connect, replacement) do
        assert_raises(Hive::RuntimeControlPlane::Unavailable) do
          database.operational_read { yielded = true }
        end
      end

      assert_equal :state_storage_read_only, error.code
      assert_equal Hive::RuntimeControlPlane::Database::STORAGE_ACTION, error.action
      assert_match(/mounted read-only/, error.message)
      refute yielded
      assert_operator disconnects, :>=, 1
    end
  end

  def test_operational_read_does_not_retry_or_reclassify_a_user_read_error
    with_database do |database, path|
      database.checkpoint!
      database.disconnect
      database = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(File.dirname(path), options: "ro", super_options: "ro")
      )
      calls = 0

      error = assert_raises(SQLite3::ReadOnlyException) do
        database.operational_read do
          calls += 1
          raise SQLite3::ReadOnlyException, "user query failed"
        end
      end

      assert_equal "user query failed", error.message
      assert_equal 1, calls
    end
  end

  def test_writable_open_translates_a_wrapped_read_only_connection_failure
    with_database do |database, path|
      database.checkpoint!
      database.disconnect
      database = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(File.dirname(path), options: "ro", super_options: "ro")
      )
      database.define_singleton_method(:verify_runtime_capabilities!) { true }
      original = Sequel.method(:connect)
      replacement = lambda do |**options, &block|
        if options[:readonly] || options[:database] != path
          original.call(**options, &block)
        else
          cause = SQLite3::ReadOnlyException.new("readonly")
          raise Sequel::DatabaseError.new("wrapped"), cause: cause
        end
      end

      error = with_replaced_singleton_method(Sequel, :connect, replacement) do
        assert_raises(Hive::RuntimeControlPlane::Unavailable) { database.open! }
      end

      assert_equal :state_storage_read_only, error.code
      assert_equal Hive::RuntimeControlPlane::Database::STORAGE_ACTION, error.action
      assert database.disconnected?
    end
  end

  def test_non_storage_query_and_connection_errors_keep_their_existing_types
    with_database do |database|
      database.define_singleton_method(:inspect_database) do |**|
        raise SQLite3::BusyException, "busy status"
      end

      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        database.quiescence_status_snapshot
      end
      assert_equal :database_corrupt, error.code
      assert_match(/busy status/, error.message)
    end

    with_database do |database|
      database.disconnect
      database.define_singleton_method(:validate_database_custody!) { true }
      source = SQLite3::BusyException.new("busy connection")
      replacement = ->(**) { raise source }

      error = with_replaced_singleton_method(Sequel, :connect, replacement) do
        assert_raises(SQLite3::BusyException) { database.send(:connect!) }
      end
      assert_same source, error
      assert database.disconnected?
    end
  end

  def test_cleanup_errors_surface_without_an_active_error
    database = Hive::RuntimeControlPlane::Database.new(path: "/tmp/runtime.sqlite3")
    inspection_error = RuntimeError.new("inspection disconnect failed")
    inspection = Object.new
    inspection.define_singleton_method(:disconnect) { raise inspection_error }

    assert_same inspection_error, assert_raises(RuntimeError) {
      database.send(:disconnect_preserving_error, inspection)
    }

    connection_error = RuntimeError.new("connection disconnect failed")
    replacement = -> { raise connection_error }
    error = with_replaced_singleton_method(database, :disconnect, replacement) do
      assert_raises(RuntimeError) { database.send(:disconnect_preserving_error) }
    end
    assert_same connection_error, error
  end

  def test_storage_error_translation_does_not_capture_unrelated_io_failures
    database = Hive::RuntimeControlPlane::Database.new(path: "/tmp/runtime.sqlite3")

    [ Errno::ENOSPC.new, Errno::EIO.new, Errno::EMFILE.new, IOError.new("stream") ].each do |error|
      assert_nil database.storage_error_for(error), error.class.name
    end
  end

  def test_mount_confirmation_handles_non_ascii_paths_as_filesystem_bytes
    with_tmp_dir do |root|
      state = File.join(root, "caf\u00e9")
      FileUtils.mkdir_p(state)
      database = database_with_mountinfo(
        File.join(state, "runtime.sqlite3"),
        mountinfo: mountinfo_row(state, options: "ro", super_options: "ro")
      )

      assert database.confirmed_read_only_storage?
    end
  end

  def test_ambiguous_mount_confirmation_is_explained_in_storage_details
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      row = mountinfo_row(root, options: "ro", super_options: "ro")
      database = database_with_mountinfo(path, mountinfo: row * 2)

      error = database.storage_error_for(Errno::EACCES.new(path))

      assert_equal :state_storage_inaccessible, error.code
      assert_equal :ambiguous_mount, error.details.dig(:mount_confirmation, :reason)
    end
  end

  def test_operational_inspection_validates_integrity_once_per_owned_session
    with_database do |original, path|
      original.checkpoint!
      original.disconnect
      database = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(File.dirname(path), options: "ro", super_options: "ro")
      )
      failure = Hive::RuntimeControlPlane::Unavailable.new(
        "read only", code: :state_storage_read_only,
        action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
      )
      assert Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
        error: failure, argv: %w[status --operational],
        state_home: File.dirname(path), database: database
      )
      diagnoses = 0
      diagnose = database.method(:diagnostics_uncoordinated)
      database.define_singleton_method(:diagnostics_uncoordinated) do |**options|
        diagnoses += 1
        diagnose.call(**options)
      end

      2.times { assert_equal 1, database.read { |connection| connection[:installations].count } }
      assert_equal 1, diagnoses
    ensure
      Hive::RuntimeControlPlane::OperationalInspection.clear!
      database&.disconnect
    end
  end

  def test_operational_inspection_rejects_all_mutating_entrypoints
    with_tmp_dir do |root|
      path = Hive::Paths.runtime_control_plane_path(root)
      activation = Struct.new(:path) { def confirmed_read_only_storage? = true }.new(path)
      failure = Hive::RuntimeControlPlane::Unavailable.new(
        "read only", code: :state_storage_read_only,
        action: Hive::RuntimeControlPlane::Database::STORAGE_ACTION
      )
      assert Hive::RuntimeControlPlane::OperationalInspection.activate_from_failure(
        error: failure, argv: %w[status --operational], state_home: root, database: activation
      )
      database = Hive::RuntimeControlPlane::Database.new(path: path)

      [
        -> { database.migrate! },
        -> { database.checkpoint! },
        -> { database.with_exclusive_writer(role: :controller) { flunk } }
      ].each do |operation|
        error = assert_raises(Hive::RuntimeControlPlane::Unavailable, &operation)
        assert_equal :state_storage_read_only, error.code
      end
      refute_path_exists path
    ensure
      Hive::RuntimeControlPlane::OperationalInspection.clear!
    end
  end

  def test_migration_creates_owner_private_database_and_sidecars_under_permissive_umask
    with_tmp_dir do |root|
      path = File.join(root, "state", "runtime.sqlite3")
      previous = File.umask(0o022)
      database = Hive::RuntimeControlPlane::Database.new(path: path).migrate!
      database.transaction do |connection|
        connection[:installations].update(next_task_id: 1)
      end

      assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
      [ path, "#{path}-wal", "#{path}-shm" ].each do |candidate|
        next unless File.exist?(candidate)
        assert_equal 0o600, File.lstat(candidate).mode & 0o777, candidate
      end
    ensure
      File.umask(previous) if previous
      database&.disconnect
    end
  end

  def test_unsafe_database_custody_fails_closed_before_sqlite_open
    with_database do |database, path|
      database.disconnect
      File.chmod(0o644, path)

      diagnosis = database.diagnostics

      assert_equal :corrupt, diagnosis.status
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.open! }
      assert_equal :database_custody_invalid, error.code
    end

    with_database do |database, path|
      database.disconnect
      linked = "#{path}.linked"
      File.link(path, linked)

      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.open! }
      assert_equal :database_custody_invalid, error.code
    ensure
      FileUtils.rm_f(linked) if linked
    end
  end

  def test_custody_validation_allows_a_wal_sidecar_to_disappear_during_inspection
    with_database do |database, path|
      wal = "#{path}-wal"
      File.binwrite(wal, "transient sqlite sidecar")
      File.chmod(0o600, wal)
      original = File.method(:lstat)
      with_replaced_singleton_method(File, :lstat, lambda { |candidate|
        raise Errno::ENOENT, candidate if candidate == wal

        original.call(candidate)
      }) do
        assert database.send(:validate_database_custody!)
      end
    end
  end

  def test_exact_schema_rejects_column_constraint_and_unexpected_index_drift
    with_database do |database, path|
      database.disconnect
      raw_sqlite(path) do |raw|
        raw.execute("ALTER TABLE daemon_runtime RENAME COLUMN observation_json TO broken_json")
      end

      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.open! }
      assert_equal :partial_schema, error.code
    end

    with_database do |database, path|
      database.disconnect
      raw_sqlite(path) { |raw| raw.execute("CREATE INDEX unexpected_runtime_idx ON daemon_runtime(observation_json)") }

      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.open! }
      assert_equal :partial_schema, error.code
    end
  end

  def test_database_owner_is_reused_only_inside_the_current_process
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      first = Hive::RuntimeControlPlane.database(path: path)
      second = Hive::RuntimeControlPlane.database(path: path)

      assert_same first, second
      assert_equal Process.pid, first.owner_pid

      alternate = Hive::RuntimeControlPlane.database(path: File.join(root, "other.sqlite3"))
      refute_same first, alternate
      assert first.disconnected?
    end
  end

  def test_non_revalidating_open_reuses_validation_until_the_connection_is_lost
    with_database do |database|
      capability_checks = 0
      diagnoses = 0
      verify_capabilities = database.method(:verify_runtime_capabilities!)
      diagnose = database.method(:diagnostics_uncoordinated)
      database.define_singleton_method(:verify_runtime_capabilities!) do
        capability_checks += 1
        verify_capabilities.call
      end
      database.define_singleton_method(:diagnostics_uncoordinated) do
        diagnoses += 1
        diagnose.call
      end

      assert_same database, database.open!(revalidate: false)
      assert_same database, database.open!(revalidate: false)
      assert_equal 0, capability_checks
      assert_equal 0, diagnoses

      database.open!
      assert_equal 1, capability_checks
      assert_equal 1, diagnoses

      database.disconnect
      database.open!(revalidate: false)
      assert_equal 2, capability_checks
      assert_equal 2, diagnoses
    end
  end

  def test_old_new_missing_duplicate_and_partial_migrations_fail_closed
    with_database do |database, path|
      set_schema_version(path, 0)
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.open! }
      assert_equal :older_schema, error.code
      assert_match(/current-format-migration/, error.message)

      set_schema_version(path, Hive::RuntimeControlPlane::SCHEMA_VERSION + 1)
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.open! }
      assert_equal :newer_schema, error.code
    end

    with_database do |database, path|
      database.disconnect
      raw_sqlite(path) do |raw|
        raw.execute("CREATE TABLE provider_audit (event_id TEXT PRIMARY KEY)")
      end
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.open! }
      assert_equal :partial_schema, error.code
    end

    with_tmp_dir do |root|
      migrations = File.join(root, "migrations")
      FileUtils.mkdir_p(migrations)
      File.write(File.join(migrations, "002_gap.rb"), "Sequel.migration { up {} }\n")
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "missing.sqlite3"), migrations_dir: migrations
      )
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.migrate! }
      assert_equal :migration_set_invalid, error.code
      refute_path_exists database.path
    end

    with_tmp_dir do |root|
      migrations = File.join(root, "migrations")
      FileUtils.mkdir_p(migrations)
      File.write(File.join(migrations, "001_first.rb"), "Sequel.migration { up {} }\n")
      File.write(File.join(migrations, "001_duplicate.rb"), "Sequel.migration { up {} }\n")
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "duplicate.sqlite3"), migrations_dir: migrations
      )
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.migrate! }
      assert_equal :migration_set_invalid, error.code
      refute_path_exists database.path
    end
  end

  def test_unsupported_sqlite_or_missing_required_feature_fails_before_domain_query
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(
        path: path, sqlite_version: "3.34.9"
      )

      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) { database.migrate! }
      assert_equal :sqlite_version_unsupported, error.code
      refute_path_exists path
    end

    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(
        path: path, feature_probe: ->(_connection) { false }
      )

      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) { database.migrate! }
      assert_equal :sqlite_feature_missing, error.code
      refute_path_exists path
    end
  end

  def test_unrelated_and_corrupt_sqlite_files_have_typed_diagnostics
    with_tmp_dir do |root|
      path = File.join(root, "unrelated.sqlite3")
      raw_sqlite(path) { |raw| raw.execute("CREATE TABLE operator_data (value TEXT)") }
      database = Hive::RuntimeControlPlane::Database.new(path: path)

      diagnosis = database.diagnostics
      assert_equal :unrelated_database, diagnosis.status
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.open! }
      assert_equal :application_id_mismatch, error.code
    end

    with_tmp_dir do |root|
      path = File.join(root, "corrupt.sqlite3")
      File.binwrite(path, "this is not sqlite")
      database = Hive::RuntimeControlPlane::Database.new(path: path)

      diagnosis = database.diagnostics
      assert_equal :corrupt, diagnosis.status
      assert_kind_of Hive::RuntimeControlPlane::IntegrityError, diagnosis.error
      assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.open! }
    end
  end

  def test_transaction_rolls_back_and_disconnect_is_idempotent
    with_database do |database|
      assert_raises(RuntimeError) do
        database.transaction do |connection|
          connection[:installations].update(next_task_id: 1)
          raise "rollback"
        end
      end

      assert_nil database.read { |connection| connection[:installations].get(:next_task_id) }
      database.disconnect
      database.disconnect
      assert database.disconnected?
    end
  end

  def test_transaction_timeout_bounds_sqlite_writer_contention_and_restores_default
    with_database do |database, path|
      blocker = SQLite3::Database.new(path)
      blocker.execute("BEGIN IMMEDIATE")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raises(Sequel::DatabaseError) do
        database.transaction(timeout_sec: 0.05) do |connection|
          connection[:installations].update(next_task_id: 1)
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 0.5
      assert_equal Hive::RuntimeControlPlane::BUSY_TIMEOUT_MS,
                   database.read { |connection| connection.fetch("PRAGMA busy_timeout").get }
    ensure
      blocker&.execute("ROLLBACK")
      blocker&.close
    end
  end

  def test_quiescence_upgrade_refuses_to_replace_a_database_with_an_uncheckpointed_source_wal
    with_database do |database|
      source = Object.new
      source.define_singleton_method(:fetch) do |_sql|
        [ Struct.new(:values).new([ 1, 3, 2 ]) ]
      end
      source.define_singleton_method(:disconnect) { true }

      error = with_replaced_singleton_method(Sequel, :connect, ->(**) { source }) do
        assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
          database.send(:checkpoint_upgrade_source!)
        end
      end

      assert_equal :quiescence_upgrade_source_checkpoint_failed, error.code
      assert_equal({ busy: 1, log_frames: 3, checkpointed_frames: 2 }, error.details)
    end
  end

  def test_migration_and_feature_probe_failures_are_typed
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(root, "runtime.sqlite3"))
      migrator = Object.new
      migrator.define_singleton_method(:run) { raise Sequel::DatabaseError, "migration failed" }
      replacement = ->(*) { migrator }
      error = with_replaced_singleton_method(Sequel::IntegerMigrator, :new, replacement) do
        assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.migrate! }
      end
      assert_equal :migration_failed, error.code
      assert database.disconnected?
    end

    with_tmp_dir do |root|
      invalid = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "invalid.sqlite3"), sqlite_version: "not-a-version"
      )
      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) { invalid.migrate! }
      assert_equal :sqlite_version_unsupported, error.code

      broken = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "broken.sqlite3"),
        feature_probe: ->(*) { raise Sequel::DatabaseError, "probe failed" }
      )
      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) { broken.migrate! }
      assert_equal :sqlite_feature_missing, error.code
    end
  end

  def test_diagnostics_classify_missing_schema_and_failed_integrity
    with_tmp_dir do |root|
      path = File.join(root, "missing-schema.sqlite3")
      raw_sqlite(path) do |raw|
        raw.execute("PRAGMA application_id = #{Hive::RuntimeControlPlane::APPLICATION_ID}")
        raw.execute("CREATE TABLE placeholder (id INTEGER)")
      end
      assert_equal :missing_schema,
                   Hive::RuntimeControlPlane::Database.new(path: path).diagnostics.status
    end

    with_database do |database|
      original = database.method(:pragma_rows)
      database.define_singleton_method(:pragma_rows) do |connection, name|
        name == "quick_check" ? [ "bad" ] : original.call(connection, name)
      end
      diagnosis = database.diagnostics
      assert_equal :corrupt, diagnosis.status
      assert_equal :integrity_check_failed, diagnosis.error.code
    end
  end

  def test_wal_migration_set_and_schema_helpers_fail_closed
    with_database do |database|
      database.disconnect
      original = database.method(:pragma_rows)
      database.define_singleton_method(:pragma_rows) do |connection, name|
        name == "journal_mode = WAL" ? [ "delete" ] : original.call(connection, name)
      end
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.open! }
      assert_equal :wal_mode_unavailable, error.code
    end

    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "runtime.sqlite3"), migrations_dir: File.join(root, "missing")
      )
      error = assert_raises(Hive::RuntimeControlPlane::MigrationRequired) { database.migrate! }
      assert_equal :migration_set_invalid, error.code
    end

    with_database do |database|
      fake = Object.new
      fake.define_singleton_method(:[]) { |_| raise Sequel::DatabaseError, "schema unreadable" }
      refute database.send(:exact_schema?, fake)

      dataset = Struct.new(:value) { def get(*) = value }.new("bad")
      schema = Object.new
      schema.define_singleton_method(:table_exists?) { |_| true }
      schema.define_singleton_method(:[]) { |_| dataset }
      assert_nil database.send(:schema_version_for, schema)
    end
  end

  def test_storage_parent_and_custody_io_fail_closed
    with_tmp_dir do |root|
      real = File.join(root, "real")
      link = File.join(root, "linked")
      FileUtils.mkdir_p(real)
      File.symlink(real, link)
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(link, "runtime.sqlite3"))
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.migrate! }
      assert_equal :database_custody_invalid, error.code
    end

    with_tmp_dir do |root|
      parent = File.join(root, "not-directory")
      File.binwrite(parent, "file")
      database = Hive::RuntimeControlPlane::Database.new(path: File.join(parent, "runtime.sqlite3"))
      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        database.send(:prepare_storage!)
      end
      assert_equal :database_custody_invalid, error.code
    end

    with_database do |database, path|
      database.disconnect
      FileUtils.remove_entry(File.dirname(path))
      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) do
        database.send(:validate_database_custody!)
      end
      assert_equal :state_storage_inaccessible, error.code
      assert_equal Hive::RuntimeControlPlane::Database::STORAGE_ACTION, error.action
    end

    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: File.join(root, "missing", "runtime.sqlite3")
      )
      database.define_singleton_method(:storage_error_for) { |_| nil }

      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) do
        database.send(:validate_database_custody!)
      end
      assert_equal :database_custody_invalid, error.code
    end
  end

  def test_custody_metadata_treats_only_enoent_as_absence
    with_database do |database, path|
      database.disconnect
      candidate = "#{path}-wal"
      original = File.method(:lstat)

      [ Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR ].each do |error_class|
        replacement = lambda do |requested|
          raise error_class, requested if requested == candidate
          original.call(requested)
        end
        error = with_replaced_singleton_method(File, :lstat, replacement) do
          assert_raises(Hive::RuntimeControlPlane::Unavailable) do
            database.send(:validate_database_custody!)
          end
        end
        assert_equal :state_storage_inaccessible, error.code
      end

      replacement = lambda do |requested|
        raise Errno::ENOENT, requested if requested == candidate
        original.call(requested)
      end
      assert with_replaced_singleton_method(File, :lstat, replacement) {
        database.send(:validate_database_custody!)
      }
    end
  end

  def test_read_only_mount_does_not_downgrade_a_proven_custody_failure
    with_database do |original_database, path|
      original_database.disconnect
      database = database_with_mountinfo(
        path,
        mountinfo: mountinfo_row(File.dirname(path), options: "ro", super_options: "ro")
      )
      status = File.lstat(path)
      wrong_owner = Struct.new(:file?, :symlink?, :nlink, :uid, :mode)
        .new(true, false, 1, Process.euid + 1, status.mode)
      original = File.method(:lstat)
      replacement = ->(requested) { requested == path ? wrong_owner : original.call(requested) }

      error = with_replaced_singleton_method(File, :lstat, replacement) do
        assert_raises(Hive::RuntimeControlPlane::IntegrityError) {
          database.send(:validate_database_custody!)
        }
      end
      assert_equal :database_custody_invalid, error.code
      assert_equal Hive::RuntimeControlPlane::Database::BACKUP_ACTION, error.action
    end
  end

  def test_diagnostics_preserves_inaccessible_metadata_instead_of_reporting_missing
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(path: path)
      original = File.method(:lstat)
      replacement = ->(requested) { requested == path ? raise(Errno::EACCES, requested) : original.call(requested) }

      error = with_replaced_singleton_method(File, :lstat, replacement) do
        assert_raises(Hive::RuntimeControlPlane::Unavailable) { database.diagnostics }
      end
      assert_equal :state_storage_inaccessible, error.code
    end
  end

  def test_diagnostics_reraises_typed_internal_errors
    with_database do |database|
      database.define_singleton_method(:inspect_database) do |&block|
        fake = Object.new
        block.call(fake)
      end
      database.define_singleton_method(:integer_pragma) do |*, **|
        raise Hive::RuntimeControlPlane::IntegrityError.new("typed", code: :database_corrupt)
      end

      error = assert_raises(Hive::RuntimeControlPlane::IntegrityError) { database.diagnostics }
      assert_equal :database_corrupt, error.code
    end
  end

  private

  def publish_large_snapshot(database, bytes, sequence = 0)
    Hive::RuntimeControlPlane::OperationalRepository.new(database: database).publish(
      { "padding" => ("a".ord + sequence).chr * bytes, "sequence" => sequence }
    )
  end

  def database_with_mountinfo(path, mountinfo:, platform: "linux")
    proc_root = File.join(File.dirname(path), ".proc")
    FileUtils.mkdir_p(File.join(proc_root, "self"))
    File.binwrite(File.join(proc_root, "self", "mountinfo"), mountinfo)
    Hive::RuntimeControlPlane::Database.new(
      path: path, proc_root: proc_root, platform: platform
    )
  end

  def mountinfo_row(mount_point, options:, super_options:)
    escaped = mount_point.to_s.gsub("\\") { "\\134" }.gsub(" ") { "\\040" }
    "36 25 0:32 / #{escaped} #{options} - tmpfs tmpfs #{super_options}\n"
  end

  def with_database
    with_tmp_dir do |root|
      path = File.join(root, "runtime.sqlite3")
      database = Hive::RuntimeControlPlane::Database.new(path: path)
      database.migrate!
      yield database, path
    ensure
      database&.disconnect
    end
  end

  def raw_sqlite(path)
    require "sqlite3"
    database = SQLite3::Database.new(path)
    yield database
  ensure
    database&.close
    File.chmod(0o600, path) if File.file?(path)
  end

  def set_schema_version(path, version)
    raw_sqlite(path) { |raw| raw.execute("UPDATE schema_info SET version = ?", version) }
  end

  def installation_id(database)
    database.read { |connection| connection[:installations].get(:installation_id) }
  end
end
