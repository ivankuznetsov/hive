require "test_helper"
require "hive/refactor_patrol/installed_job_schema_migration"
require "hive/refactor_patrol/installed_users_job_schema_migration"

class HiveRefactorPatrolInstalledJobSchemaMigrationTest < Minitest::Test
  include HiveTestHelper

  Migration = Hive::RefactorPatrol::InstalledJobSchemaMigration
  AllUsersMigration =
    Hive::RefactorPatrol::InstalledUsersJobSchemaMigration
  MigrationStatus =
    Hive::RefactorPatrol::RegisteredProjectMigrationStatus

  class FakeStatusStore
    attr_accessor :payload

    def initialize(payload = nil)
      @payload = payload
    end

    def read
      payload
    end

    def write_daemon_restart_pending(value = nil, pending:, now:)
      @payload = (value || payload).merge(
        "daemon_restart_pending" => pending == true,
        "updated_at" => now.utc.iso8601(6)
      )
    end
  end

  class FakeCoordinator
    attr_reader :last_status_payload, :runs

    def initialize(status_store:, payload:, error: nil)
      @status_store = status_store
      @payload = payload
      @error = error
      @runs = []
    end

    def run(now:, entries:)
      @runs << { now: now, entries: entries }
      raise @error if @error

      @status_store.payload = @payload
      @last_status_payload = @payload
      []
    end
  end

  class FakeLifecycle
    attr_reader :calls

    def initialize(running: false, restart_errors: [])
      @running = running
      @restart_errors = Array(restart_errors)
      @calls = []
      @restart_acknowledger = nil
    end

    def acknowledge_restart_with(&block)
      @restart_acknowledger = block
    end

    def quiesce!
      @calls << :quiesce
      was_running = @running
      @running = false
      was_running
    end

    def restart!(ready: nil)
      @calls << :restart
      error = @restart_errors.shift
      raise error if error

      @running = true
      @restart_acknowledger&.call
      if ready && !ready.call
        raise Hive::Error,
              "candidate daemon did not acknowledge readiness after JobStore migration"
      end
      true
    end
  end

  class MutableRunningStatus
    attr_accessor :running

    def initialize(pid:)
      @pid = pid
      @running = true
    end

    def running_state
      { running: running, pid: running ? @pid : nil }
    end
  end

  def test_normal_cli_startup_has_no_schema_conversion_gate
    source = File.binread(
      File.expand_path("../../../bin/hive", __dir__)
    )

    refute_respond_to Migration, :eligible_argv?
    refute_respond_to Migration, :restart_daemon_after?
    refute_includes source, "InstalledJobSchemaMigration"
    refute_includes source, "migration held"
  end

  def test_current_registry_digest_skips_conversion_and_daemon_fence
    with_tmp_dir do |root|
      entries = [
        {
          "name" => "shared",
          "path" => "/srv/shared",
          "project_id" => "project-shared"
        }
      ]
      digest = MigrationStatus.registry_digest(entries)
      status_store = FakeStatusStore.new(
        status_payload(digest: digest, projects: [])
      )
      lifecycle = FakeLifecycle.new(running: true)
      factory_called = false
      migration = build_migration(
        root: root,
        entries: entries,
        status_store: status_store,
        lifecycle: lifecycle,
        coordinator_factory: lambda do |**|
          factory_called = true
        end
      )

      payload = migration.call(now: Time.utc(2026, 7, 29, 12))

      assert_equal status_store.payload, payload
      refute migration.last_ran
      refute factory_called
      assert_empty lifecycle.calls
    end
  end

  def test_due_sweep_passes_every_registered_row_and_restarts_prior_daemon
    with_tmp_dir do |root|
      entries = [
        {
          "name" => "mine",
          "path" => "/home/me/project",
          "project_id" => "project-mine"
        },
        {
          "name" => "shared-from-another-user",
          "path" => "/srv/team/project",
          "hive_state_path" => "/var/lib/team/hive-state",
          "project_id" => "project-shared",
          "registered_by" => "another-user"
        }
      ].freeze
      digest = MigrationStatus.registry_digest(entries)
      expected = status_payload(
        digest: digest,
        projects: [
          project_status("mine", "current"),
          project_status("shared-from-another-user", "migrated")
        ]
      )
      status_store = FakeStatusStore.new
      lifecycle = FakeLifecycle.new(running: true)
      coordinator = FakeCoordinator.new(
        status_store: status_store, payload: expected
      )
      ensured = 0
      migration = build_migration(
        root: root,
        entries: entries,
        status_store: status_store,
        lifecycle: lifecycle,
        identity_ensurer: -> { ensured += 1 },
        coordinator_factory: ->(**) { coordinator }
      )

      payload = migration.call(now: "2026-07-29T12:00:00Z")

      assert_equal expected, payload
      assert_equal entries, coordinator.runs.fetch(0).fetch(:entries)
      assert_equal digest, migration.last_registry_digest
      assert migration.last_ran
      assert migration.last_daemon_was_running
      assert migration.last_daemon_restarted
      assert_equal [ :quiesce, :restart ], lifecycle.calls
      assert_equal 1, ensured
    end
  end

  def test_retryable_row_runs_only_when_its_persisted_deadline_is_due
    with_tmp_dir do |root|
      entries = [ { "name" => "blocked", "path" => "/srv/blocked" } ]
      digest = MigrationStatus.registry_digest(entries)
      future = status_payload(
        digest: digest,
        projects: [
          project_status(
            "blocked", "failed", retryable: true,
            next_retry_at: "2026-07-29T13:00:00.000000Z"
          )
        ]
      )
      status_store = FakeStatusStore.new(future)
      lifecycle = FakeLifecycle.new
      coordinator = FakeCoordinator.new(
        status_store: status_store,
        payload: status_payload(digest: digest, projects: [])
      )
      migration = build_migration(
        root: root,
        entries: entries,
        status_store: status_store,
        lifecycle: lifecycle,
        coordinator_factory: ->(**) { coordinator }
      )

      migration.call(now: "2026-07-29T12:59:59Z")
      refute migration.last_ran

      migration.call(now: "2026-07-29T13:00:00Z")
      assert migration.last_ran
      assert_equal 1, coordinator.runs.length
      assert_equal [ :quiesce ], lifecycle.calls
    end
  end

  def test_failed_conversion_restarts_a_daemon_that_was_stopped
    with_tmp_dir do |root|
      entries = [ { "name" => "shared", "path" => "/srv/shared" } ]
      status_store = FakeStatusStore.new
      lifecycle = FakeLifecycle.new(running: true)
      coordinator = FakeCoordinator.new(
        status_store: status_store,
        payload: nil,
        error: Hive::ConfigError.new("status storage unavailable")
      )
      migration = build_migration(
        root: root,
        entries: entries,
        status_store: status_store,
        lifecycle: lifecycle,
        coordinator_factory: ->(**) { coordinator }
      )

      error = assert_raises(Hive::ConfigError) do
        migration.call(restart_daemon: false)
      end

      assert_match(/status storage unavailable/, error.message)
      assert_equal [ :quiesce, :restart ], lifecycle.calls
      assert migration.last_daemon_restarted
      refute migration.last_ran
    end
  end

  def test_candidate_daemon_start_owns_restart_after_successful_migration
    with_tmp_dir do |root|
      entries = [ { "name" => "shared", "path" => "/srv/shared" } ]
      digest = MigrationStatus.registry_digest(entries)
      status_store = FakeStatusStore.new
      lifecycle = FakeLifecycle.new(running: true)
      coordinator = FakeCoordinator.new(
        status_store: status_store,
        payload: status_payload(digest: digest, projects: [])
      )
      migration = build_migration(
        root: root,
        entries: entries,
        status_store: status_store,
        lifecycle: lifecycle,
        coordinator_factory: ->(**) { coordinator }
      )

      migration.call(restart_daemon: false)

      assert_equal [ :quiesce ], lifecycle.calls
      refute migration.last_daemon_restarted
      assert_equal true, status_store.payload.fetch("daemon_restart_pending")
    end
  end

  def test_failed_daemon_restart_stays_pending_and_retries_without_reconverting
    with_tmp_dir do |root|
      entries = [ { "name" => "shared", "path" => "/srv/shared" } ]
      digest = MigrationStatus.registry_digest(entries)
      status_store = FakeStatusStore.new
      lifecycle = FakeLifecycle.new(
        running: true,
        restart_errors: [ Hive::Error.new("temporary service failure") ]
      )
      coordinator = FakeCoordinator.new(
        status_store: status_store,
        payload: status_payload(digest: digest, projects: [])
      )
      factory_calls = 0
      migration = build_migration(
        root: root,
        entries: entries,
        status_store: status_store,
        lifecycle: lifecycle,
        coordinator_factory: lambda do |**|
          factory_calls += 1
          coordinator
        end
      )

      error = assert_raises(Hive::Error) do
        migration.call(now: "2026-07-29T12:00:00Z")
      end

      assert_match(/temporary service failure/, error.message)
      assert_equal true, status_store.payload.fetch("daemon_restart_pending")
      assert_equal 1, factory_calls
      assert_equal [ :quiesce, :restart ], lifecycle.calls

      payload = migration.call(now: "2026-07-29T12:01:00Z")

      assert_equal false, payload.fetch("daemon_restart_pending")
      assert_equal 1, factory_calls,
                   "restart recovery must not rerun a current catalog"
      assert_equal [ :quiesce, :restart, :quiesce, :restart ], lifecycle.calls
      assert migration.last_daemon_restarted
      refute migration.last_ran
    end
  end

  def test_visible_candidate_pid_does_not_clear_restart_before_daemon_ack
    with_tmp_dir do |root|
      entries = [ { "name" => "shared", "path" => "/srv/shared" } ]
      digest = MigrationStatus.registry_digest(entries)
      status_store = FakeStatusStore.new
      lifecycle = FakeLifecycle.new(running: true)
      coordinator = FakeCoordinator.new(
        status_store: status_store,
        payload: status_payload(digest: digest, projects: [])
      )
      migration = Migration.new(
        registry: -> { entries },
        identity_ensurer: -> { nil },
        status_store: status_store,
        coordinator_factory: ->(**) { coordinator },
        daemon_lifecycle: lifecycle,
        activation_directory: Hive::ManagedDirectory.new(
          root: File.join(root, "schema-migrations"),
          label: "test installation migration"
        )
      )

      error = assert_raises(Hive::Error) do
        migration.call(now: "2026-07-29T12:00:00Z")
      end

      assert_match(/did not acknowledge readiness/, error.message)
      assert_equal true,
                   status_store.payload.fetch("daemon_restart_pending")
      assert_equal [ :quiesce, :restart ], lifecycle.calls
      refute migration.last_daemon_restarted

      lifecycle.acknowledge_restart_with do
        status_store.write_daemon_restart_pending(
          status_store.read,
          pending: false,
          now: Time.utc(2026, 7, 29, 12, 1)
        )
      end
      payload = migration.call(now: "2026-07-29T12:01:00Z")

      assert_equal false, payload.fetch("daemon_restart_pending")
      assert_equal 1, coordinator.runs.length,
                   "readiness recovery must not reconvert current projects"
    end
  end

  def test_restart_must_leave_a_persisted_candidate_acknowledgement
    with_tmp_dir do |root|
      entries = [ { "name" => "shared", "path" => "/srv/shared" } ]
      digest = MigrationStatus.registry_digest(entries)
      status_store = FakeStatusStore.new
      coordinator = FakeCoordinator.new(
        status_store: status_store,
        payload: status_payload(digest: digest, projects: [])
      )
      lifecycle = Object.new
      ready_callbacks = []
      lifecycle.define_singleton_method(:quiesce!) { true }
      lifecycle.define_singleton_method(:restart!) do |ready: nil|
        ready_callbacks << ready
        true
      end
      migration = Migration.new(
        registry: -> { entries },
        identity_ensurer: -> { nil },
        status_store: status_store,
        coordinator_factory: ->(**) { coordinator },
        daemon_lifecycle: lifecycle,
        activation_directory: Hive::ManagedDirectory.new(
          root: File.join(root, "schema-migrations"),
          label: "test installation migration"
        )
      )

      error = assert_raises(Hive::ConfigError) do
        migration.call(now: "2026-07-29T12:00:00Z")
      end

      assert_match(/did not acknowledge JobStore migration readiness/,
                   error.message)
      assert migration.last_daemon_restarted
      assert_equal 1, ready_callbacks.length
      assert_respond_to ready_callbacks.first, :call
    end
  end

  def test_daemon_acknowledgement_probe_fails_closed_when_status_is_unreadable
    with_tmp_dir do |root|
      status_store = Object.new
      status_store.define_singleton_method(:read) do
        raise IOError, "status unavailable"
      end
      migration = Migration.new(
        registry: -> { [] },
        identity_ensurer: -> { nil },
        status_store: status_store,
        daemon_lifecycle: FakeLifecycle.new,
        activation_directory: Hive::ManagedDirectory.new(
          root: File.join(root, "schema-migrations"),
          label: "test installation migration"
        )
      )

      refute migration.send(:daemon_restart_acknowledged?)
    end
  end

  def test_daemon_lifecycle_fences_released_process_tree_and_restarts_candidate
    with_tmp_dir do |root|
      binary = File.join(root, "hive")
      File.binwrite(binary, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, binary)
      status = MutableRunningStatus.new(pid: 41_001)
      stopped = false
      restarted = []
      targets = [
        { pid: 41_002, ppid: 41_001, pgid: 41_002, start_time: "child", depth: 1 },
        { pid: 41_001, ppid: 1, pgid: 41_001, start_time: "daemon", depth: 0 }
      ]
      daemon = Object.new
      daemon.define_singleton_method(:call) do
        stopped = true
        status.running = false
      end
      lifecycle = Migration::DaemonLifecycle.new(
        hive_home: root,
        status_report: status,
        daemon_factory: ->(command) {
          assert_equal "stop", command
          daemon
        },
        tree_probe: ->(pid) {
          assert_equal 41_001, pid
          targets
        },
        tree_confirmer: ->(pid, initial) {
          assert_equal 41_001, pid
          assert_same targets, initial
          targets
        },
        captured_process_alive: ->(_target) { !stopped },
        process_group_alive: ->(_pgid) { false },
        binary_path: -> { binary },
        command_runner: lambda do |argv, environment|
          restarted << [ argv, environment ]
          status.running = true
          true
        end
      )

      assert lifecycle.quiesce!
      assert lifecycle.restart!
      assert_equal [
        [
          [ binary, "daemon", "start", "--detach" ],
          { Migration::INTERNAL_ENV => "1" }
        ]
      ], restarted
    end
  end

  def test_daemon_lifecycle_refuses_an_unbound_released_process
    status = MutableRunningStatus.new(pid: 41_010)
    daemon_called = false
    lifecycle = Migration::DaemonLifecycle.new(
      status_report: status,
      daemon_factory: ->(_command) {
        daemon_called = true
      },
      tree_probe: ->(_pid) {
        [
          {
            pid: 41_010, ppid: 1, pgid: 41_010,
            start_time: nil, depth: 0
          }
        ]
      },
      tree_confirmer: ->(_pid, targets) { targets }
    )

    error = assert_raises(Hive::ConcurrentRunError) do
      lifecycle.quiesce!
    end

    assert_match(/stable identities/, error.message)
    refute daemon_called
  end

  def test_one_all_user_sweep_migrates_every_users_real_registered_project
    with_tmp_dir do |root|
      installations = %w[user-a user-b].to_h do |user|
        home = File.join(root, "#{user}-hive-home")
        projects = %w[first second].map.with_index do |suffix, index|
          project_root = File.join(root, "#{user}-#{suffix}")
          state_root = File.join(
            root, "custom-state", user, suffix
          )
          FileUtils.mkdir_p([ project_root, state_root ])
          install_released_job(state_root)
          {
            "name" => "#{user}-#{suffix}",
            "path" => project_root,
            "real_path" => File.realpath(project_root),
            "hive_state_path" => state_root,
            "project_id" => format(
              "00000000-0000-4000-a000-%012d",
              (user == "user-a" ? 0 : 100) + index + 1
            )
          }
        end
        FileUtils.mkdir_p(home)
        File.write(
          File.join(home, "config.yml"),
          { "registered_projects" => projects }.to_yaml
        )
        [ user, { home: home, projects: projects } ]
      end

      profiles = installations.map.with_index do |(user, installation), index|
        AllUsersMigration::Profile.new(
          username: user,
          uid: 1_001 + index,
          gid: 2_001 + index,
          home: root,
          real_home: File.realpath(root),
          environment: { "HIVE_HOME" => installation.fetch(:home) },
          source: "root-inventory",
          supplementary_gids: [ 2_001 + index ],
          root_bindings:
            AllUsersMigration::ProfileRootBindings.new.bind(
              home: root,
              environment: { "HIVE_HOME" => installation.fetch(:home) },
              uid: Process.uid
            )
        )
      end
      executor = Object.new
      helper = self
      executor.define_singleton_method(:call) do |profile|
        helper.with_env(
          "HIVE_HOME" => profile.environment.fetch("HIVE_HOME")
        ) do
          Migration.new(
            daemon_lifecycle: FakeLifecycle.new
          ).call(force: true, now: Time.utc(2026, 7, 29, 17))
        end
      end
      catalog = Object.new
      catalog.define_singleton_method(:snapshot) do
        AllUsersMigration::Snapshot.new(
          profiles: profiles,
          issues: [],
          closed: true,
          inventory_path: "/var/lib/hive/installed-users.v1.json",
          inventory_digest: "a" * 64
        )
      end

      payload = AllUsersMigration.new(
        catalog: catalog,
        executor: executor,
        candidate: AllUsersMigration::CandidateIdentity.capture(
          File.expand_path("../../../bin/hive", __dir__)
        ),
        effective_uid: -> { 0 }
      ).call(now: Time.utc(2026, 7, 29, 17))

      assert_equal "complete", payload.fetch("status")
      assert_equal 2, payload.fetch("attempted_users")
      payload.fetch("profiles").each do |user|
        assert_equal(
          %w[migrated migrated],
          user.fetch("projects").map { |project| project.fetch("status") }
        )
      end
      installations.each_value do |installation|
        installation.fetch(:projects).each do |project|
          current = Hive::RefactorPatrol::JobStore.root_for(
            project.fetch("path"),
            hive_state_path: project.fetch("hive_state_path")
          )
          migrated = JSON.parse(File.binread(File.join(
            current, "jobs", "job-released.json"
          )))
          assert_equal 3, migrated.fetch("schema_version")
          assert_equal(
            :regular,
            Hive::ManagedDirectory.new(
              root: Hive::RefactorPatrol::JobStore.legacy_root_for(
                project.fetch("path"),
                hive_state_path: project.fetch("hive_state_path")
              ),
              anchor: project.fetch("hive_state_path"),
              label: "test released JobStore"
            ).entry_type("jobs")
          )
        end
      end
    end
  end

  def test_missing_or_unreadable_status_forces_a_fresh_sweep
    with_tmp_dir do |root|
      entries = [ { "name" => "shared", "path" => "/srv/shared" } ]
      status_store = FakeStatusStore.new
      reads = 0
      status_store.define_singleton_method(:read) do
        reads += 1
        raise Hive::ConfigError, "unreadable status" if reads == 1

        nil
      end
      coordinator = FakeCoordinator.new(
        status_store: status_store,
        payload: nil
      )
      migration = build_migration(
        root: root,
        entries: entries,
        status_store: status_store,
        lifecycle: FakeLifecycle.new,
        coordinator_factory: ->(**) { coordinator }
      )

      error = assert_raises(Hive::ConfigError) do
        migration.call(now: Time.utc(2026, 7, 29, 12))
      end

      assert_match(/did not persist status/, error.message)
      assert migration.last_ran == false
    end
  end

  def test_due_calculation_and_time_validation_fail_safe
    with_tmp_dir do |root|
      status = FakeStatusStore.new
      migration = build_migration(
        root: root,
        entries: [],
        status_store: status,
        lifecycle: FakeLifecycle.new,
        coordinator_factory: ->(**) { flunk("invalid time ran migration") }
      )
      payload = status_payload(
        digest: "a" * 64,
        projects: [
          project_status(
            "bad-time",
            "failed",
            retryable: true,
            next_retry_at: "not-a-time"
          )
        ]
      )

      assert migration.send(
        :migration_due?,
        payload,
        digest: "a" * 64,
        now: Time.utc(2026, 7, 29)
      )
      assert_raises(Hive::ConfigError) do
        migration.call(now: "not-a-time")
      end
    end
  end

  def test_default_coordinator_binds_the_exact_registry_snapshot
    with_tmp_dir do |root|
      entries = [ { "name" => "demo", "path" => "/srv/demo" } ]
      migration = Migration.new(
        registry: -> { entries },
        identity_ensurer: -> { nil },
        status_store: FakeStatusStore.new,
        daemon_lifecycle: FakeLifecycle.new,
        activation_directory: Hive::ManagedDirectory.new(
          root: File.join(root, "schema-migrations"),
          label: "test installation migration"
        )
      )

      coordinator = migration.send(
        :build_coordinator,
        entries: entries,
        status_store: nil
      )

      assert_equal entries,
                   coordinator.instance_variable_get(:@registry).call
    end
  end

  def test_daemon_lifecycle_default_factory_and_process_helpers
    require "hive/commands/daemon"
    built = nil
    with_replaced_singleton_method(
      Hive::Commands::Daemon,
      :new,
      lambda do |subcommand, hive_home:|
        built = [ subcommand, hive_home ]
        :daemon
      end
    ) do
      lifecycle = Migration::DaemonLifecycle.new(
        hive_home: "/tmp/hive-state",
        status_report: MutableRunningStatus.new(pid: 4_100),
        tree_probe: ->(*) { [] },
        tree_confirmer: ->(*) { [] },
        captured_process_alive: ->(*) { false },
        process_group_alive: ->(*) { false },
        binary_path: -> { "/bin/true" },
        command_runner: ->(*) { true }
      )

      assert_equal :daemon,
                   lifecycle.instance_variable_get(:@daemon_factory)
                   .call("stop")
      assert_equal [ "stop", "/tmp/hive-state" ], built
      lifecycle.instance_variable_get(:@sleeper).call(0)
      status = lifecycle.send(:run_command, [ "/bin/true" ], {})
      assert status.success?
    end

    lifecycle = Migration::DaemonLifecycle.new(
      status_report: MutableRunningStatus.new(pid: 4_100),
      tree_probe: ->(*) { [] },
      tree_confirmer: ->(*) { [] },
      captured_process_alive: ->(*) { false },
      binary_path: -> { "/bin/true" },
      command_runner: ->(*) { true }
    )
    with_replaced_singleton_method(
      Process,
      :kill,
      ->(*) { 1 }
    ) do
      assert lifecycle.send(:default_process_group_alive?, 4_101)
    end
    with_replaced_singleton_method(
      Process,
      :kill,
      ->(*) { raise Errno::ESRCH }
    ) do
      refute lifecycle.send(:default_process_group_alive?, 4_101)
    end
    with_replaced_singleton_method(
      Process,
      :kill,
      ->(*) { raise Errno::EPERM }
    ) do
      assert lifecycle.send(:default_process_group_alive?, 4_101)
    end
  end

  def test_daemon_lifecycle_reports_probe_and_process_survivor_failures
    malformed = Migration::DaemonLifecycle.new(
      status_report: Object.new.tap do |status|
        status.define_singleton_method(:running_state) do
          { running: true, pid: "not-a-pid" }
        end
      end
    )
    error = assert_raises(Hive::ConcurrentRunError) do
      malformed.quiesce!
    end
    assert_match(/cannot verify released daemon quiescence/, error.message)

    targets = [
      {
        pid: 4_200, ppid: 1, pgid: 4_200,
        start_time: "daemon", depth: 0
      }
    ]
    survivor = Migration::DaemonLifecycle.new(
      status_report: MutableRunningStatus.new(pid: 4_200),
      daemon_factory: ->(*) {
        Object.new.tap { |daemon| daemon.define_singleton_method(:call) { true } }
      },
      tree_probe: ->(*) { targets },
      tree_confirmer: ->(*) { targets },
      captured_process_alive: ->(*) { true },
      process_group_alive: ->(*) { false }
    )
    error = assert_raises(Hive::ConcurrentRunError) do
      survivor.quiesce!
    end
    assert_match(/captured daemon process remains live/, error.message)

    targets = [
      {
        pid: 4_300, ppid: 1, pgid: 4_300,
        start_time: "daemon", depth: 0
      },
      {
        pid: 4_301, ppid: 4_300, pgid: "bad",
        start_time: "bad-child", depth: 1
      },
      {
        pid: 4_302, ppid: 4_300, pgid: 4_302,
        start_time: "live-child", depth: 1
      }
    ]
    group_survivor = Migration::DaemonLifecycle.new(
      status_report: MutableRunningStatus.new(pid: 4_300),
      daemon_factory: ->(*) {
        Object.new.tap { |daemon| daemon.define_singleton_method(:call) { true } }
      },
      tree_probe: ->(*) { targets },
      tree_confirmer: ->(*) { targets },
      captured_process_alive: ->(*) { false },
      process_group_alive: ->(pgid) { pgid == 4_302 }
    )
    error = assert_raises(Hive::ConcurrentRunError) do
      group_survivor.quiesce!
    end
    assert_match(/child process group remains live/, error.message)
  end

  def test_daemon_restart_rejects_missing_failed_and_timed_out_candidates
    missing = Migration::DaemonLifecycle.new(
      status_report: MutableRunningStatus.new(pid: 4_400),
      binary_path: -> { "/missing/hive" }
    )
    assert_raises(Hive::UnavailableError) { missing.restart! }

    failed = Migration::DaemonLifecycle.new(
      status_report: MutableRunningStatus.new(pid: 4_401),
      binary_path: -> { "/bin/true" },
      command_runner: ->(*) { false }
    )
    assert_raises(Hive::Error) { failed.restart! }

    status = MutableRunningStatus.new(pid: 4_402)
    status.running = false
    times = [
      Time.at(0).utc,
      Time.at(0).utc,
      Time.at(2).utc
    ]
    sleeps = []
    timed_out = Migration::DaemonLifecycle.new(
      status_report: status,
      binary_path: -> { "/bin/true" },
      command_runner: ->(*) { true },
      clock: -> { times.shift || Time.at(2).utc },
      sleeper: ->(seconds) { sleeps << seconds },
      restart_timeout_sec: 1
    )
    error = assert_raises(Hive::Error) { timed_out.restart! }
    assert_match(/did not acknowledge readiness/, error.message)
    assert_equal [ 0.05 ], sleeps

    unavailable = Migration::DaemonLifecycle.new(
      status_report: status,
      binary_path: -> { "/bin/true" },
      command_runner: ->(*) { raise Errno::ENOENT, "missing runner" }
    )
    error = assert_raises(Hive::UnavailableError) do
      unavailable.restart!
    end
    assert_match(/cannot restart Hive daemon/, error.message)
  end

  private

  def install_released_job(state_root)
    path = File.join(
      state_root, "refactor_patrol", "v2", "jobs",
      "job-released.json"
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(
      path,
      File.binread(File.expand_path(
        "../../fixtures/refactor_patrol/released_v2_job.json",
        __dir__
      ))
    )
  end

  def build_migration(root:, entries:, status_store:, lifecycle:,
                      coordinator_factory:, identity_ensurer: -> { nil })
    lifecycle.acknowledge_restart_with do
      payload = status_store.read
      if payload
        status_store.write_daemon_restart_pending(
          payload, pending: false, now: Time.utc(2026, 7, 29, 12)
        )
      end
    end if lifecycle.respond_to?(:acknowledge_restart_with)
    Migration.new(
      registry: -> { entries },
      identity_ensurer: identity_ensurer,
      status_store: status_store,
      coordinator_factory: coordinator_factory,
      daemon_lifecycle: lifecycle,
      activation_directory: Hive::ManagedDirectory.new(
        root: File.join(root, "schema-migrations"),
        label: "test installation migration"
      )
    )
  end

  def status_payload(digest:, projects:)
    {
      "schema" => MigrationStatus::SCHEMA,
      "schema_version" => MigrationStatus::SCHEMA_VERSION,
      "target_schema_version" => 3,
      "registry_digest" => digest,
      "updated_at" => "2026-07-29T12:00:00.000000Z",
      "daemon_restart_pending" => false,
      "projects" => projects
    }
  end

  def project_status(name, status, retryable: false, next_retry_at: nil)
    {
      "project" => name,
      "project_id" => "project-#{name}",
      "path" => "/projects/#{name}",
      "real_path" => "/projects/#{name}",
      "hive_state_path" => "/projects/#{name}/.hive-state",
      "status" => status,
      "current_schema_version" => status == "current" ? 3 : nil,
      "target_schema_version" => 3,
      "snapshot_id" => nil,
      "retryable" => retryable,
      "next_retry_at" => next_retry_at,
      "remediation" => nil,
      "error" => nil
    }
  end
end
