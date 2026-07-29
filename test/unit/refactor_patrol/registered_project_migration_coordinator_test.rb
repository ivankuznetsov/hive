require "test_helper"
require "hive/daemon/status_report"
require "hive/refactor_patrol/registered_project_migration_coordinator"
require "hive/refactor_patrol/registered_project_migration_status"

class RefactorPatrolRegisteredProjectMigrationCoordinatorTest <
      Minitest::Test
  include HiveTestHelper

  Coordinator =
    Hive::RefactorPatrol::RegisteredProjectMigrationCoordinator

  def setup
    @root = Dir.mktmpdir("registered-project-schema-migration")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_reports_migrated_current_and_absent_projects
    migrated_path = project_path("migrated")
    current_path = project_path("current")
    absent_path = project_path("absent")
    calls = []
    migrator = lambda do |identity, ownership:|
      assert_equal "legacy", ownership.fetch("owner")
      path = identity.fetch(:real_path)
      calls << path
      path == migrated_path
    end
    state_present = ->(path) { path == current_path }

    results = coordinator(
      entries(migrated_path, current_path, absent_path),
      project_migrator: migrator,
      state_present: state_present
    ).run

    assert_equal %i[migrated current absent], results.map(&:status)
    assert_equal [ migrated_path, absent_path ], calls
    assert results.all? { |result| result.error.nil? }
  end

  def test_failure_is_isolated_and_later_projects_still_migrate
    bad_path = project_path("bad")
    good_path = project_path("good")
    migrator = lambda do |identity, ownership:|
      assert_equal 1, ownership.fetch("epoch")
      path = identity.fetch(:real_path)
      if path == bad_path
        raise Hive::RefactorPatrol::JobStore::CorruptRecord.new(
          "broken legacy state", path: path
        )
      end

      true
    end

    results = coordinator(
      entries(bad_path, good_path),
      project_migrator: migrator
    ).run

    assert_equal %i[failed migrated], results.map(&:status)
    assert_match(/CorruptRecord: broken legacy state/, results.first.error)
    assert_equal good_path, results.last.path
  end

  def test_partial_failure_exposes_the_verified_snapshot_identity
    path = project_path("partial")
    snapshot_id = "snapshot-#{"b" * 64}"
    result = Coordinator.new(
      registry: -> { entries(path) },
      project_migrator: lambda do |*, **|
        raise Hive::ConfigError, "replacement interrupted"
      end,
      schema_status: ->(*) do
        raise Hive::RefactorPatrol::JobStore::CorruptRecord,
              "partial aggregate is unreadable"
      end,
      schema_snapshot_id: lambda do |identity|
        assert_equal path, identity.fetch(:real_path)
        snapshot_id
      end,
      status_store: nil
    ).run.fetch(0)

    assert_equal :failed, result.status
    assert_equal snapshot_id, result.snapshot_id
    assert result.retryable
  end

  def test_a_malformed_released_v2_aggregate_does_not_block_a_later_project_conversion
    bad_path = project_path("bad-released")
    good_path = project_path("good-released")
    write_released_v2_job(
      bad_path,
      released_v2_job(job_id: "job-bad").tap { |job| job.delete("source") }
    )
    write_released_v2_job(
      good_path, released_v2_job(job_id: "job-good")
    )

    results = Coordinator.new(
      registry: -> { entries(bad_path, good_path) },
      status_store: nil
    ).run

    assert_equal %i[failed migrated], results.map(&:status)
    assert_match(/released refactor patrol v2 job/, results.first.error)
    target_root = Hive::RefactorPatrol::JobStore.root_for(good_path)
    migrated = JSON.parse(File.binread(File.join(
      target_root, "jobs", "job-good.json"
    )))
    assert_equal 3, migrated.fetch("schema_version")
    assert File.file?(File.join(
      target_root, "job-schema-v3-migration.json"
    ))
  end

  def test_realpath_alias_is_converted_once
    real_path = project_path("real")
    alias_path = File.join(@root, "alias")
    File.symlink(real_path, alias_path)
    calls = []

    migration = coordinator(
      [
        registry_entry("real", real_path),
        registry_entry("alias", alias_path, real_path: real_path)
      ],
      project_migrator: lambda do |identity, ownership:|
        assert_equal "legacy", ownership.fetch("owner")
        path = identity.fetch(:real_path)
        calls << path
        false
      end
    )
    results = migration.run

    assert_equal %i[absent duplicate], results.map(&:status)
    assert_equal [ real_path ], calls
    assert_equal real_path, Coordinator.path_key(alias_path)
    assert_equal [ "real" ], migration.eligible_projects.map {
      |entry| entry.fetch("name")
    }
  end

  def test_same_repository_with_distinct_custom_state_roots_migrates_both
    real_path = project_path("shared-repository")
    first_state = File.join(real_path, ".first-hive-state")
    second_state = File.join(real_path, ".second-hive-state")
    registry = [
      registry_entry("first", real_path).merge(
        "hive_state_path" => first_state
      ),
      registry_entry("second", real_path).merge(
        "hive_state_path" => second_state
      )
    ]
    migrated = []
    migration = Coordinator.new(
      registry: -> { registry },
      project_migrator: lambda do |identity, ownership:|
        assert_equal "legacy", ownership.fetch("owner")
        migrated << identity.fetch(:hive_state_path)
        true
      end,
      schema_status: lambda do |identity|
        status =
          migrated.include?(identity.fetch(:hive_state_path)) ?
            "current" : "migration_required"
        { "status" => status, "snapshot_id" => nil }
      end,
      status_store: nil
    )

    results = migration.run

    assert_equal %i[migrated migrated], results.map(&:status)
    assert_equal [ first_state, second_state ], migrated
    assert_equal(
      %w[first second],
      migration.eligible_projects.map { |entry| entry.fetch("name") }
    )
  end

  def test_dry_run_never_invokes_mutating_or_state_probes
    path = project_path("dry-run")
    result = coordinator(
      entries(path),
      project_migrator:
        ->(*, **) { flunk "dry run invoked the converter" },
      state_present: ->(*) { flunk "dry run inspected mutable state" },
      dry_run: true
    ).run.fetch(0)

    assert_equal :dry_run, result.status
    assert_nil result.error
  end

  def test_malformed_registry_entry_is_a_failed_result
    results = coordinator(
      [
        { "name" => "missing-path" },
        { "path" => File.join(@root, "missing-name") }
      ]
    ).run

    assert_equal %i[failed failed], results.map(&:status)
    assert_equal "missing-path", results.fetch(0).project
    assert_nil results.fetch(0).path
    assert_nil results.fetch(1).project
    assert_equal File.join(@root, "missing-name"),
                 results.fetch(1).path
    assert results.all? { |result| result.error.match?(/KeyError/) }
    missing = File.join(@root, "not-present")
    assert_equal File.expand_path(missing), Coordinator.path_key(missing)
  end

  def test_default_registry_enumerates_every_registered_project_with_its_custom_state_path
    home = File.join(@root, "installation-owner")
    owner_a_root = project_path("owner-a-root")
    owner_b_root = project_path("owner-b-root")
    owner_a_state = File.join(owner_a_root, ".owner-a-hive-state")
    owner_b_state = File.join(owner_b_root, ".owner-b-hive-state")
    FileUtils.mkdir_p([ home, owner_a_state, owner_b_state ])
    File.write(
      File.join(home, "config.yml"),
      {
        "registered_projects" => [
          registry_entry("owner-a", owner_a_root).merge(
            "hive_state_path" => owner_a_state
          ),
          registry_entry("owner-b", owner_b_root).merge(
            "hive_state_path" => owner_b_state
          ),
          { "name" => "malformed-registration" }
        ]
      }.to_yaml
    )

    seen = []
    coordinator = Coordinator.new(
      project_migrator: lambda do |identity, ownership:|
        assert_equal "legacy", ownership.fetch("owner")
        seen << [ identity.fetch(:project), identity.fetch(:real_path),
                  identity.fetch(:hive_state_path) ]
        true
      end,
      schema_status: lambda do |identity|
        status =
          seen.any? do |_project, _path, state_path|
            state_path == identity.fetch(:hive_state_path)
          end ? "current" : "migration_required"
        {
          "status" => status,
          "snapshot_id" => status == "current" ? "snapshot-test" : nil
        }
      end,
      status_store: nil
    )

    results = with_env("HIVE_HOME" => home) { coordinator.run }

    assert_equal %i[migrated migrated failed], results.map(&:status)
    assert_match(/KeyError/, results.last.error)
    assert_equal(
      [
        [ "owner-a", owner_a_root, owner_a_state ],
        [ "owner-b", owner_b_root, owner_b_state ]
      ],
      seen
    )
  end

  def test_each_hive_installation_sweeps_its_own_complete_registry
    installations = %w[user-a user-b].to_h do |user|
      home = File.join(@root, "#{user}-hive-home")
      projects = %w[first second].map do |suffix|
        path = project_path("#{user}-#{suffix}")
        registry_entry("#{user}-#{suffix}", path).merge(
          "hive_state_path" =>
            File.join(path, ".#{user}-#{suffix}-state")
        )
      end
      FileUtils.mkdir_p(home)
      File.write(
        File.join(home, "config.yml"),
        { "registered_projects" => projects }.to_yaml
      )
      [ user, { home: home, projects: projects } ]
    end

    seen = {}
    installations.each do |user, installation|
      migrated = []
      coordinator = Coordinator.new(
        project_migrator: lambda do |identity, ownership:|
          assert_equal "legacy", ownership.fetch("owner")
          migrated << identity.fetch(:project)
          true
        end,
        schema_status: lambda do |identity|
          status =
            migrated.include?(identity.fetch(:project)) ?
              "current" : "migration_required"
          { "status" => status, "snapshot_id" => nil }
        end,
        status_store: nil
      )
      with_env("HIVE_HOME" => installation.fetch(:home)) do
        coordinator.run
      end
      seen[user] = migrated
    end

    assert_equal %w[user-a-first user-a-second], seen.fetch("user-a")
    assert_equal %w[user-b-first user-b-second], seen.fetch("user-b")
  end

  def test_identity_drift_is_persisted_as_retryable_failure_without_blocking_later_projects
    drifted_path = project_path("drifted-path")
    good_path = project_path("later-good")
    drifted_state = File.join(drifted_path, ".custom-state")
    good_state = File.join(good_path, ".other-custom-state")
    status_root = File.join(@root, "installation-status")
    status_store = Hive::RefactorPatrol::RegisteredProjectMigrationStatus.new(
      root: status_root
    )
    now = Time.utc(2026, 7, 29, 16, 0, 0)
    migrated = []
    drifted_entry = registry_entry("drifted", drifted_path).merge(
      "real_path" => File.join(@root, "old-registration-path"),
      "hive_state_path" => drifted_state
    )
    good_entry = registry_entry("good", good_path).merge(
      "hive_state_path" => good_state
    )

    results = Coordinator.new(
      registry: -> { [ drifted_entry, good_entry ] },
      project_migrator: lambda do |identity, ownership:|
        assert_equal "legacy", ownership.fetch("owner")
        migrated << identity.fetch(:project)
        true
      end,
      schema_status: lambda do |identity|
        current = migrated.include?(identity.fetch(:project))
        {
          "status" => current ? "current" : "migration_required",
          "snapshot_id" =>
            current ? "snapshot-#{"a" * 64}" : nil
        }
      end,
      status_store: status_store
    ).run(now: now)

    assert_equal %i[failed migrated], results.map(&:status)
    failed = results.fetch(0)
    assert failed.retryable
    assert_equal "2026-07-29T17:00:00.000000Z", failed.next_retry_at
    assert_match(/canonical path/, failed.error)
    assert_equal [ "good" ], migrated

    persisted = status_store.read.fetch("projects")
    assert_equal %w[failed migrated], persisted.map { |project| project.fetch("status") }
    assert_equal true, persisted.fetch(0).fetch("retryable")
    assert_equal good_state, persisted.fetch(1).fetch("hive_state_path")
  end

  def test_status_reads_persisted_migration_results_without_rewriting_them
    status_root = File.join(@root, "installation-status")
    status_store = Hive::RefactorPatrol::RegisteredProjectMigrationStatus.new(
      root: status_root
    )
    result = Coordinator::Result.new(
      project: "drifted", project_id: "project-drifted", path: "/projects/drifted",
      real_path: "/projects/drifted", hive_state_path: "/projects/drifted/.custom-state",
      status: :failed, current_schema_version: nil, target_schema_version: 3,
      snapshot_id: nil, retryable: true,
      next_retry_at: "2026-07-29T17:00:00.000000Z",
      remediation: "repair the project state", error: "Hive::ConfigError: path drift"
    )
    status_store.write(
      [ result ],
      registry_digest: "a" * 64,
      now: Time.utc(2026, 7, 29, 16, 0, 0)
    )
    path = File.join(status_root, status_store.class::FILE_NAME)
    before = File.binread(path)

    payload = Hive::Daemon::StatusReport.new(
      hive_home: @root, migration_status: status_store
    ).send(:schema_migration_payload)

    assert_equal before, File.binread(path)
    assert_equal true, payload.fetch("ok")
    assert_equal "failed", payload.fetch("projects").fetch(0).fetch("status")
  end

  def test_status_rejects_a_canonical_but_untyped_project_row
    status_root = File.join(@root, "installation-status")
    status_store = Hive::RefactorPatrol::RegisteredProjectMigrationStatus.new(
      root: status_root
    )
    path = File.join(status_root, status_store.class::FILE_NAME)
    FileUtils.mkdir_p(status_root)
    File.binwrite(
      path,
      Hive::WorkflowPackage::CanonicalJSON.generate(
        "schema" => status_store.class::SCHEMA,
        "schema_version" => 2,
        "target_schema_version" => 3,
        "registry_digest" => "a" * 64,
        "updated_at" => "2026-07-29T16:00:00.000000Z",
        "projects" => [ { "status" => "current" } ]
      )
    )

    error = assert_raises(Hive::ConfigError) { status_store.read }
    assert_match(/migration status is malformed/, error.message)
  end

  def test_hourly_tick_retries_a_previously_failed_project
    path = project_path("retryable")
    calls = 0
    coordinator = coordinator(
      entries(path),
      project_migrator: lambda do |*, **|
        calls += 1
        raise Hive::ConfigError, "temporarily inaccessible" if calls == 1

        true
      end
    )
    started_at = Time.utc(2026, 7, 29, 16, 0, 0)

    first = coordinator.tick(now: started_at)
    assert_equal [ :failed ], first.map(&:status)
    assert_nil coordinator.tick(now: started_at + 3_599)

    retried = coordinator.tick(now: started_at + Coordinator::RETRY_INTERVAL)
    assert_equal [ :migrated ], retried.map(&:status)
    assert_equal 2, calls
  end

  def test_current_project_uses_compact_probe_without_reinvoking_migrator
    path = project_path("already-current")
    probes = 0
    coordinator = Coordinator.new(
      registry: -> { entries(path) },
      project_migrator:
        ->(*, **) { flunk("current project invoked the converter") },
      schema_status: lambda do |_identity|
        probes += 1
        { "status" => "current", "snapshot_id" => nil }
      end,
      status_store: nil
    )
    started_at = Time.utc(2026, 7, 29, 16, 0, 0)

    assert_equal [ :current ],
                 coordinator.tick(now: started_at).map(&:status)
    assert_equal [ :current ],
                 coordinator.tick(
                   now: started_at + Coordinator::RETRY_INTERVAL
                 ).map(&:status)
    assert_equal 2, probes
  end

  def test_empty_interrupted_native_target_is_repaired_and_admitted
    path = project_path("interrupted-native")
    target = Hive::RefactorPatrol::JobStore.root_for(path)
    FileUtils.mkdir_p(target)

    coordinator = Coordinator.new(
      registry: -> { entries(path) },
      status_store: nil
    )
    result = coordinator.run.fetch(0)

    assert_equal :current, result.status
    assert_nil result.snapshot_id
    assert_equal [ "interrupted-native" ],
                 coordinator.eligible_projects.map {
                   |entry| entry.fetch("name")
                 }
    legacy = Hive::RefactorPatrol::JobStore.legacy_root_for(path)
    tombstone = JSON.parse(File.binread(File.join(legacy, "jobs")))
    assert_equal "native", tombstone.fetch("origin")
    assert_equal "complete", tombstone.fetch("status")
  end

  def test_registry_change_bypasses_the_hourly_retry_delay
    first_path = project_path("first-registration")
    later_path = project_path("later-registration")
    registry = entries(first_path)
    migrated = []
    coordinator = Coordinator.new(
      registry: -> { registry },
      project_migrator: lambda do |identity, **|
        migrated << identity.fetch(:project)
        true
      end,
      schema_status: lambda do |identity|
        status =
          migrated.include?(identity.fetch(:project)) ?
            "current" : "migration_required"
        { "status" => status, "snapshot_id" => nil }
      end,
      status_store: nil
    )
    started_at = Time.utc(2026, 7, 29, 16, 0, 0)

    coordinator.tick(now: started_at)
    registry << registry_entry("later-registration", later_path)
    refreshed = coordinator.tick(now: started_at + 1)

    assert_equal(
      %w[first-registration later-registration],
      refreshed.map(&:project)
    )
    assert_equal(
      %w[first-registration later-registration],
      migrated
    )
    assert_equal(
      %w[first-registration later-registration],
      coordinator.eligible_projects.map { |entry| entry.fetch("name") }
    )
  end

  def test_migration_required_status_reports_v2_as_the_current_schema
    path = project_path("requires-migration")
    result = Coordinator.new(
      registry: -> { entries(path) },
      project_migrator: ->(*, **) { false },
      schema_status: ->(*) do
        { "status" => "migration_required", "snapshot_id" => nil }
      end,
      status_store: nil
    ).run.fetch(0)

    assert_equal :migration_required, result.status
    assert_equal 2, result.current_schema_version
    assert_equal 3, result.target_schema_version
  end

  def test_runtime_admission_is_an_allowlist_from_the_latest_complete_sweep
    good_path = project_path("admitted")
    failed_path = project_path("missing-anchor")
    later_path = project_path("registered-later")
    good = registry_entry("admitted", good_path)
    missing_anchor =
      registry_entry("missing-anchor", failed_path)
      .reject { |key, _value| key == "real_path" }
    registry = [ good, missing_anchor ]
    coordinator = Coordinator.new(
      registry: -> { registry },
      project_migrator: ->(*, **) { false },
      schema_status: ->(*) do
        { "status" => "current", "snapshot_id" => nil }
      end,
      status_store: nil
    )

    assert_equal %i[current failed], coordinator.run.map(&:status)
    registry << registry_entry("registered-later", later_path)

    assert_equal [ "admitted" ],
                 coordinator.eligible_projects.map {
                   |entry| entry.fetch("name")
                 }
  end

  private

  def coordinator(registry,
                  project_migrator: ->(*, **) { false },
                  state_present: ->(*) { false }, dry_run: false)
    migrated_paths = {}
    wrapped_migrator = lambda do |identity, **options|
      result = project_migrator.call(identity, **options)
      migrated_paths[identity.fetch(:real_path)] = true if result
      result
    end
    Coordinator.new(
      registry: -> { registry },
      project_migrator: wrapped_migrator,
      state_present: lambda do |path|
        migrated_paths.key?(path) || state_present.call(path)
      end,
      status_store: nil,
      dry_run: dry_run
    )
  end

  def entries(*paths)
    paths.map do |path|
      registry_entry(File.basename(path), path)
    end
  end

  def registry_entry(name, path, real_path: File.realpath(path))
    {
      "name" => name,
      "path" => path,
      "real_path" => real_path,
      "hive_state_path" => File.join(path, ".hive-state"),
      "project_id" => "project-#{name}"
    }
  end

  def project_path(name)
    path = File.join(@root, name)
    FileUtils.mkdir_p(path)
    File.expand_path(path)
  end

  def released_v2_job(job_id:)
    {
      "schema" => "hive-refactor-patrol-job",
      "schema_version" => 2,
      "job_id" => job_id,
      "source" => {
        "url" => "https://github.com/acme/demo/pull/7",
        "number" => 7,
        "repository" => "acme/demo",
        "registration" => "demo",
        "base_branch" => "main",
        "base_sha" => "a" * 40,
        "merge_sha" => "b" * 40,
        "merged_at" => "2026-07-10T12:00:00Z",
        "changed_paths" => [ "lib/checkout.rb" ],
        "manifest_checksum" => "c" * 64
      },
      "analysis_sha" => nil,
      "policy" => {
        "discovery" => true,
        "auto_fix" => false,
        "issue_filing" => false
      },
      "state" => "complete",
      "complete" => true,
      "dispositions" => {
        "accepted" => [], "flagged" => [], "suppressed" => []
      },
      "feature_results" => [],
      "review_errors" => [],
      "zero_reason" => "no_mapped_slice",
      "attempts" => [],
      "actions" => [],
      "created_at" => "2026-07-10T10:00:00Z",
      "updated_at" => "2026-07-10T10:01:00Z"
    }
  end

  def write_released_v2_job(project_path, job)
    path = File.join(
      project_path, ".hive-state", "refactor_patrol", "v2", "jobs",
      "#{job.fetch('job_id')}.json"
    )
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "#{JSON.pretty_generate(job)}\n")
  end
end
