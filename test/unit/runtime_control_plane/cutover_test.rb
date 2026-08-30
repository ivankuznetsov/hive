require "test_helper"
require "hive/runtime_control_plane/cutover"

class RuntimeControlPlaneCutoverTest < Minitest::Test
  include HiveTestHelper

  PROJECT_ID = "11111111-1111-4111-a111-111111111111"
  REGISTRATION_ID = "22222222-2222-4222-a222-222222222222"
  SimulatedCrash = Class.new(Exception)

  FakeServices = Struct.new(:events) do
    def stop!(**) = events << :stopped
    def activate! = events << :active
  end

  class FlakyServices < FakeServices
    def activate!
      events << :active
      raise "activation failed" if events.count(:active) == 1
      true
    end
  end

  def test_fresh_bootstrap_requires_confirmation_and_creates_only_current_authorities
    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::ConfirmationRequired) do
        cutover.bootstrap(confirm: false)
      end
      assert_equal :confirmation_required, error.code

      result = cutover.bootstrap(confirm: true)

      assert_equal "active", result.phase
      assert_path_exists result.database_path
      assert_path_exists Hive::Paths.runtime_payload_root(state)
      assert_equal %i[stopped active], cutover.services.events
      Hive::RuntimeControlPlane::Cutover::TARGETS.each do |target|
        home = target.home == :state ? state : data
        refute_path_exists File.join(home, target.relative_path)
      end
    end
  end

  def test_filesystem_preflight_finishes_before_services_are_changed
    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        raise "stop after preflight" if point == :filesystem_preflighted
      })

      error = assert_raises(RuntimeError) { cutover.run(confirm: true) }

      assert_equal "stop after preflight", error.message
      assert_empty cutover.services.events
      assert_empty Dir.glob(File.join(File.dirname(state), "**", ".hive-cutover-probe-*"))
      refute_path_exists File.join(state, ".runtime-cutover", "current", "preparing.json")
    end
  end

  def test_failure_after_fencing_resumes_forward_from_sealed_evidence
    with_home do |state, data, projects|
      counter = File.join(state, "task-counter.yml")
      File.binwrite(counter, "---\ngeneration: 99\n")
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        raise "injected" if point == :sources_sealed
      })

      assert_raises(RuntimeError) { cutover.run(confirm: true) }

      assert File.directory?(counter)
      ready = File.join(state, ".runtime-cutover", "current", "ready.json")
      assert_path_exists ready
      refute_path_exists File.join(state, ".runtime-cutover", "current", "sealed")
      assert_equal "active", build_cutover(state, data, projects).resume.phase
    end
  end

  def test_resume_completes_fences_after_a_mid_fence_crash
    with_home do |state, data, projects|
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :fence_installed
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }

      result = build_cutover(state, data, projects).run(confirm: true)

      assert_equal "active", result.phase
      assert Hive::RuntimeControlPlane::Database.new(path: result.database_path).diagnostics.ok?
    end
  end

  def test_intended_resume_uses_installed_all_in_database
    with_home do |state, data, projects|
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :activation_intent
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
      live = Hive::Paths.runtime_control_plane_path(state)
      assert_path_exists live

      result = build_cutover(state, data, projects).resume

      assert_equal "active", result.phase
      assert_path_exists live
    end
  end

  def test_intended_resume_rejects_a_tampered_live_database_without_restore
    with_home do |state, data, projects|
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :activation_intent
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
      live = Hive::Paths.runtime_control_plane_path(state)
      File.binwrite(live, "tampered")

      error = assert_raises(Hive::RuntimeControlPlane::Error) do
        build_cutover(state, data, projects).resume
      end

      assert_equal :database_corrupt, error.code
      refute_path_exists File.join(state, ".runtime-cutover", "current", "active.json")
    end
  end

  def test_service_activation_failure_retries_without_publishing_active
    with_home do |state, data, projects|
      services = FlakyServices.new([])
      cutover = build_cutover(state, data, projects, services: services)
      assert_raises(RuntimeError) { cutover.bootstrap(confirm: true) }
      refute_path_exists File.join(state, ".runtime-cutover", "current", "active.json")

      assert_equal "active", cutover.resume.phase
      assert_equal 2, services.events.count(:active)
    end
  end

  def test_active_cutover_is_idempotent
    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)
      original = cutover.bootstrap(confirm: true)
      cutover.services.events.clear

      repeated = cutover.run(confirm: true)

      assert_equal original.cutover_id, repeated.cutover_id
      assert_empty cutover.services.events
    end
  end

  def test_missing_project_requires_an_explicit_recorded_exclusion
    with_home(create_project: false) do |state, data, projects|
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::ProjectError) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :project_missing, error.code

      result = build_cutover(state, data, projects).run(confirm: true, exclusions: [ "alpha" ])
      assert_equal [ "alpha" ], result.exclusions.map { |entry| entry.fetch("name") }
    end
  end

  def test_missing_task_identity_fails_without_mutating_task_files
    with_home do |state, data, projects|
      metadata = task_path(projects, "meta.yml")
      File.binwrite(metadata, "---\nworkflow: coding\n")
      before = tree_digest(projects.first.fetch("hive_state_path"))

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::ProjectError) do
        build_cutover(state, data, projects).run(confirm: true)
      end

      assert_equal :task_identity_missing, error.code
      assert_equal before, tree_digest(projects.first.fetch("hive_state_path"))
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_active_legacy_attempt_refuses_cutover_before_any_fence
    with_home do |state, data, projects|
      records = File.join(state, "attempts", "v4", "records")
      FileUtils.mkdir_p(records)
      File.binwrite(File.join(records, "attempt-1.json"), JSON.generate(
        "attempt_id" => "attempt-1", "state" => "running"
      ))

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end

      assert_equal :live_runtime_owner, error.code
      assert_equal "attempt-1", error.details.fetch(:attempt_id)
      assert File.file?(File.join(records, "attempt-1.json"))
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_disposable_pending_dispatch_request_is_reset_after_services_stop
    with_home do |state, data, projects|
      requests = File.join(state, "dispatch_requests")
      FileUtils.mkdir_p(requests)
      File.binwrite(File.join(requests, "request-1.json"), JSON.generate(
        "request_id" => "request-1", "project" => "alpha"
      ))

      result = build_cutover(state, data, projects).run(confirm: true)
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!

      assert_equal 0, database.read { |db| db[:dispatch_requests].count }
      assert File.file?(requests), "legacy directory must be replaced by a fence"
    ensure
      database&.disconnect
    end
  end

  def test_held_legacy_writer_lock_refuses_cutover
    with_home do |state, data, projects|
      lock_path = File.join(state, ".task-counter.lock")
      File.binwrite(lock_path, "")
      File.open(lock_path, "r+") do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          build_cutover(state, data, projects).run(confirm: true)
        end

        assert_equal :live_runtime_owner, error.code
      end
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_quiescent_disposable_runtime_is_not_imported
    with_home do |state, data, projects|
      write_quiescent_legacy_runtime(state, data, projects)

      result = build_cutover(state, data, projects).run(confirm: true)
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!

      %i[
        attempts dispatch_requests dispatch_outbox provider_circuits provider_audit
        routing_policies patrol_allowances pr_merge_reconciliations daemon_runtime
      ].each { |table| assert_equal 0, database.read { |db| db[table].count }, table }
      assert_equal 0, database.read { |db| db[:task_counters].count }
      assert_equal [ "7" ], database.read { |db| db[:task_subjects].select_map(:task_id) }
    ensure
      database&.disconnect
    end
  end

  def test_usage_history_is_imported_exactly_once_with_availability_semantics
    with_home do |state, data, projects|
      write_usage(File.join(data, "usage.db"), input: 4, input_available: 0,
                  cache_read: 9, cache_read_available: 1, cost: 0.25, cost_available: 1)
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :database_built
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }

      result = build_cutover(state, data, projects).run(confirm: true)
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!
      row = database.read { |db| db[:token_usage].where(id: "usage-1").first }

      assert_equal 1, database.read { |db| db[:token_usage].count }
      assert_equal "attempt-history-1", row.fetch(:attempt_id)
      assert_equal "7", row.fetch(:task_id)
      assert_equal 4, row.fetch(:input)
      assert_equal 0, row.fetch(:input_available)
      assert_equal 9, row.fetch(:cache_read)
      assert_equal 1, row.fetch(:cache_read_available)
      assert_in_delta 0.25, row.fetch(:cost)
      assert_equal 1, row.fetch(:cost_available)
    ensure
      database&.disconnect
    end
  end

  def test_wal_usage_is_snapshotted_consistently
    with_home do |state, data, projects|
      source = File.join(state, "usage-source.sqlite3")
      usage = write_usage(source, keep_open: true)
      usage.run("PRAGMA journal_mode=WAL")
      usage.run("PRAGMA wal_autocheckpoint=0")
      usage[:token_usage].where(id: "usage-1").update(agent: "pi")
      %w[ usage-source.sqlite3 usage-source.sqlite3-wal usage-source.sqlite3-shm ].each do |name|
        suffix = name.delete_prefix("usage-source.sqlite3")
        FileUtils.cp(File.join(state, name), File.join(data, "usage.db#{suffix}"))
      end

      result = build_cutover(state, data, projects).run(confirm: true)
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!

      assert_equal "pi", database.read { |db| db[:token_usage].get(:agent) }
    ensure
      usage&.disconnect
      database&.disconnect
    end
  end

  def test_malformed_usage_schema_refuses_cutover
    with_home do |state, data, projects|
      usage = Sequel.sqlite(File.join(data, "usage.db"))
      usage.create_table(:token_usage) { String :id, primary_key: true }
      usage.disconnect

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end

      assert_equal :usage_snapshot_invalid, error.code
      assert File.file?(File.join(data, "usage.db"))
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_corrupt_usage_database_refuses_cutover
    with_home do |state, data, projects|
      File.binwrite(File.join(data, "usage.db"), "not sqlite")

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end

      assert_equal :usage_snapshot_invalid, error.code
      assert_equal "not sqlite", File.binread(File.join(data, "usage.db"))
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_task_projection_artifacts_and_referenced_payloads_remain_untouched
    with_home do |state, data, projects|
      File.binwrite(task_path(projects, "task-journal.jsonl"), "{\"event\":\"existing\"}\n")
      File.binwrite(task_path(projects, "task-projection.json"), "{\"state\":\"existing\"}\n")
      artifacts = task_path(projects, "artifacts")
      FileUtils.mkdir_p(artifacts)
      File.binwrite(File.join(artifacts, "review.md"), "evidence\n")
      payloads = File.join(state, "attempts", "v4", "logs")
      FileUtils.mkdir_p(payloads)
      File.binwrite(File.join(payloads, "attempt-1.frames"), "retained log\n")
      retained = [
        task_path(projects, "meta.yml"), task_path(projects, "idea.md"),
        task_path(projects, "task-journal.jsonl"), task_path(projects, "task-projection.json"),
        File.join(artifacts, "review.md")
      ]
      task_before = retained.to_h { |path| [ path, File.binread(path) ] }
      payload_before = tree_digest(payloads)

      build_cutover(state, data, projects).run(confirm: true)

      assert_equal task_before, retained.to_h { |path| [ path, File.binread(path) ] }
      assert_equal payload_before, tree_digest(payloads)
    end
  end

  def test_project_runtime_fences_follow_the_registered_custom_state_root
    with_home do |state, data, projects|
      project = projects.fetch(0)
      default_state = project.fetch("hive_state_path")
      custom_state = File.join(project.fetch("path"), ".custom-state")
      FileUtils.mv(default_state, custom_state)
      project["hive_state_path"] = custom_state
      legacy = File.join(custom_state, "daemon", "pr-merge-reconciliation.json")
      FileUtils.mkdir_p(File.dirname(legacy))
      File.binwrite(legacy, "{}\n")

      build_cutover(state, data, projects).run(confirm: true)

      assert File.directory?(legacy), "retired file must be replaced by a directory fence"
      assert_equal Hive::RuntimeControlPlane::Cutover::FENCE_BYTES,
                   File.binread(File.join(legacy, "RETIRED"))
      refute_path_exists File.join(default_state, "daemon", "pr-merge-reconciliation.json")
    end
  end

  private

  def with_home(create_project: true)
    with_tmp_dir do |root|
      state = File.join(root, "state")
      data = File.join(root, "data")
      project = File.join(root, "alpha")
      FileUtils.mkdir_p([ state, data ])
      prepare_project(project) if create_project
      projects = [ {
        "name" => "alpha", "path" => project,
        "hive_state_path" => File.join(project, ".hive-state"),
        "project_id" => PROJECT_ID, "registration_id" => REGISTRATION_ID,
        "registered_at" => "2026-08-29T12:00:00.000000Z"
      } ]
      yield state, data, projects
    end
  end

  def prepare_project(project)
    task = File.join(project, ".hive-state", "stages", "1-inbox", "first-task")
    FileUtils.mkdir_p(task)
    File.binwrite(File.join(task, "meta.yml"), "---\nid: 7\nworkflow: coding\n")
    File.binwrite(File.join(task, "idea.md"), "# First task\n")
  end

  def task_path(projects, name)
    File.join(projects.first.fetch("hive_state_path"), "stages", "1-inbox", "first-task", name)
  end

  def build_cutover(state, data, projects, fault: nil, services: FakeServices.new([]))
    Hive::RuntimeControlPlane::Cutover.new(
      state_home: state, data_home: data, projects: projects,
      source_release: "0.7.2", target_release: "next", services: services, fault: fault
    )
  end

  def write_usage(path, keep_open: false, **values)
    usage = Sequel.sqlite(path)
    usage.create_table(:token_usage) do
      String :id, primary_key: true
      String :task_id
      String :attempt_id
      String :agent, null: false
      String :session_id
      String :started_at, null: false
      Integer :input, default: 0
      Integer :output, default: 0
      Integer :cached, default: 0
      Integer :cache_read
      Float :cost
      Integer :input_available, default: 1
      Integer :output_available, default: 1
      Integer :cached_available, default: 1
      Integer :cache_read_available, default: 0
      Integer :cost_available, default: 0
    end
    usage[:token_usage].insert({
      id: "usage-1", task_id: "7", attempt_id: "attempt-history-1", agent: "codex",
      session_id: "session-1", started_at: "2026-08-29T12:00:00.000000Z"
    }.merge(values))
    usage.disconnect unless keep_open
    usage
  end

  def write_quiescent_legacy_runtime(state, data, projects)
    records = File.join(state, "attempts", "v4", "records")
    FileUtils.mkdir_p(records)
    File.binwrite(File.join(records, "attempt-1.json"), JSON.generate(
      "attempt_id" => "attempt-1", "state" => "terminal"
    ))
    requests = File.join(state, "dispatch_requests")
    results = File.join(state, "dispatch_results")
    FileUtils.mkdir_p([ requests, results, File.join(state, "operational") ])
    File.binwrite(File.join(requests, "request-1.json"), JSON.generate("request_id" => "request-1"))
    File.binwrite(File.join(results, "result-1.json"), JSON.generate("request_id" => "request-1"))
    File.binwrite(File.join(state, "operational", "snapshot.json"), "{}")
    File.binwrite(File.join(state, "task-counter.yml"), "---\ngeneration: 99\n")
    allowance = File.join(data, "usage.db.patrol-discovery-allowances")
    FileUtils.mkdir_p(allowance)
    File.binwrite(File.join(allowance, "allowance.json"), "{}")
    daemon = File.join(projects.first.fetch("hive_state_path"), "daemon")
    FileUtils.mkdir_p(daemon)
    File.binwrite(File.join(daemon, "pr-merge-reconciliation.json"), JSON.generate(
      "candidates" => {}, "backlog" => { "complete" => true }
    ))
  end

  def tree_digest(root)
    Digest::SHA256.hexdigest(
      Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.filter_map do |path|
        next if %w[. ..].include?(File.basename(path))
        relative = path.delete_prefix("#{root}/")
        File.file?(path) ? "#{relative}\0#{File.binread(path)}" : "#{relative}/"
      end.join("\0")
    )
  end
end
