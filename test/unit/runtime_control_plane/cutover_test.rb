require "test_helper"
require "hive/runtime_control_plane/cutover"
require "hive/runtime_control_plane/activation_gate"

class RuntimeControlPlaneCutoverTest < Minitest::Test
  include HiveTestHelper

  PROJECT_ID = "11111111-1111-4111-a111-111111111111"
  REGISTRATION_ID = "22222222-2222-4222-a222-222222222222"
  SimulatedCrash = Class.new(Exception)
  CommandStatus = Struct.new(:ok) { def success? = ok }

  FakeServices = Struct.new(:events) do
    attr_accessor :activated

    def stop!(**) = events << :stopped
    def activate!
      events << :active
      self.activated = true
    end
    def activated? = !!activated
  end

  class FlakyServices < FakeServices
    def activate!
      events << :active
      raise "activation failed" if events.count(:active) == 1
      self.activated = true
      true
    end
  end

  class GateCheckingServices < FakeServices
    def initialize(events, state_home)
      super(events)
      @state_home = state_home
    end

    def activate!
      raise "active published before services" if File.exist?(
        File.join(@state_home, ".runtime-cutover", "current", "active.json")
      )
      super
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

      cutover.run(confirm: true)
      assert_equal 2, services.events.count(:active)
    end
  end

  def test_active_manifest_is_published_after_managed_services_restart
    with_home do |state, data, projects|
      services = GateCheckingServices.new([], state)

      result = build_cutover(state, data, projects, services: services).bootstrap(confirm: true)

      assert_equal "active", result.phase
      assert services.activated?
    end
  end

  def test_failure_after_service_stop_resumes_from_preparing_with_original_journal
    with_home do |state, data, projects|
      running = true
      calls = []
      runner = lambda do |argv|
        calls << argv
        ok = if argv.include?("show-environment")
          true
        elsif argv.include?("is-active")
          argv.last == "hive-daemon" && running
        elsif argv.include?("stop")
          running = false
          true
        elsif argv.include?("start")
          running = true
          true
        else
          false
        end
        [ "", "", CommandStatus.new(ok) ]
      end
      services = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: state, host_os: "linux", runner: runner
      )
      crashing = build_cutover(state, data, projects, services: services, fault: lambda { |point|
        raise "refused after stop" if point == :services_stopped
      })

      assert_raises(RuntimeError) { crashing.run(confirm: true) }

      current = File.join(state, ".runtime-cutover", "current")
      assert_path_exists File.join(current, "preparing.json")
      assert_path_exists File.join(current, "services.json")
      resumed_services = Hive::RuntimeControlPlane::MaintenanceServices.new(
        state_home: state, host_os: "linux", runner: runner
      )
      assert_equal "active", build_cutover(state, data, projects, services: resumed_services).resume.phase
      assert running
      assert_equal 1, calls.count { |argv| argv == %w[systemctl --user start hive-daemon] }
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

  def test_reachable_project_cannot_be_hidden_by_cutover_exclusion
    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::ProjectError) do
        cutover.run(confirm: true, exclusions: [ "alpha" ])
      end

      assert_equal :reachable_project_exclusion, error.code
      assert_empty cutover.services.events
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
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

  def test_live_legacy_task_lock_refuses_cutover_without_flocking_the_lock_inode
    with_home do |state, data, projects|
      folder = File.dirname(task_path(projects, "idea.md"))
      File.binwrite(File.join(folder, ".lock"), {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "lock_id" => "legacy-owner"
      }.to_yaml)

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :live_runtime_owner, error.code
      assert File.file?(File.join(folder, ".lock"))
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_legacy_task_guard_remains_held_until_fences_are_installed
    with_home do |state, data, projects|
      folder = File.dirname(task_path(projects, "idea.md"))
      observed = nil
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        next unless point == :fleet_ready
        File.open(File.join(folder, ".lock.tmp.guard"), File::RDWR | File::CREAT, 0o600) do |guard|
          observed = guard.flock(File::LOCK_EX | File::LOCK_NB)
        end
      })

      assert_equal "active", cutover.run(confirm: true).phase
      refute observed
      assert File.directory?(File.join(folder, ".lock.tmp.guard"))
    end
  end

  def test_symlink_and_hardlink_fence_shapes_are_rejected
    with_home do |state, data, projects|
      target = File.join(state, "task-counter.yml")
      outside = File.join(File.dirname(state), "outside")
      FileUtils.mkdir_p(outside)
      File.binwrite(File.join(outside, "RETIRED"), Hive::RuntimeControlPlane::Cutover::FENCE_BYTES)
      File.symlink(outside, target)

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :legacy_runtime_invalid, error.code
    end

    with_home do |state, data, projects|
      target = File.join(state, "task-counter.yml")
      marker = File.join(File.dirname(state), "outside-marker")
      File.binwrite(marker, Hive::RuntimeControlPlane::Cutover::FENCE_BYTES)
      FileUtils.mkdir_p(target)
      File.link(marker, File.join(target, "RETIRED"))

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :legacy_runtime_invalid, error.code
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

  def test_unexpected_legacy_target_shape_refuses_before_any_target_is_changed
    with_home do |state, data, projects|
      earlier = File.join(state, "dispatch_requests")
      FileUtils.mkdir_p(earlier)
      File.binwrite(File.join(earlier, "request.json"), "{}\n")
      unexpected = File.join(state, "task-counter.yml")
      FileUtils.mkdir_p(unexpected)
      sentinel = File.join(unexpected, "do-not-delete")
      File.binwrite(sentinel, "operator data\n")

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end

      assert_equal :legacy_runtime_invalid, error.code
      assert_equal "{}\n", File.binread(File.join(earlier, "request.json"))
      assert_equal "operator data\n", File.binread(sentinel)
    end
  end

  def test_task_authority_change_after_ready_refuses_before_fencing
    with_home do |state, data, projects|
      task = task_path(projects, "idea.md")
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        File.binwrite(task, "changed after ready\n") if point == :fleet_ready
      })

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.run(confirm: true)
      end

      assert_equal :source_changed, error.code
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
      refute File.file?(File.join(state, "dispatch_requests")), "no absent-source fence may be installed"
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

  def test_candidate_database_is_complete_before_any_legacy_target_is_fenced
    with_home do |state, data, projects|
      counter = File.join(state, "task-counter.yml")
      File.binwrite(counter, "---\ngeneration: 99\n")
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        raise "candidate verified" if point == :database_built
      })

      error = assert_raises(RuntimeError) { cutover.run(confirm: true) }

      assert_equal "candidate verified", error.message
      assert File.file?(counter)
      assert_equal "---\ngeneration: 99\n", File.binread(counter)
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_usage_writer_cannot_commit_into_retained_history_after_snapshot
    with_home do |state, data, projects|
      source_path = File.join(data, "usage.db")
      write_usage(source_path)
      attempting = Queue.new
      completed = Queue.new
      writer = nil
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        next unless point == :usage_snapshotted

        writer = Thread.new do
          source = Sequel.sqlite(source_path, timeout: 2_000)
          attempting << true
          source[:token_usage].where(id: "usage-1").update(agent: "late-writer")
          completed << :committed
        rescue Sequel::Error, SystemCallError
          completed << :retired
        ensure
          source&.disconnect
        end
        attempting.pop
        sleep 0.02
        unless completed.empty?
          outcome = completed.pop
          assert_equal :retired, outcome, "the legacy writer must not commit after the snapshot"
          completed << outcome
        end
      })

      result = cutover.run(confirm: true)
      writer.join
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!

      assert_equal "codex", database.read { |db| db[:token_usage].get(:agent) }
      assert_includes %i[committed retired], completed.pop
      assert File.directory?(source_path), "the retired database path must be a directory fence"
    ensure
      writer&.join
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

  def test_missing_sealed_usage_snapshot_has_a_typed_cutover_error
    with_home do |state, data, projects|
      write_usage(File.join(data, "usage.db"))
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :sources_sealed
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
      FileUtils.rm_f(File.join(state, ".runtime-cutover", "current", "usage.snapshot.sqlite3"))

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).resume
      end

      assert_equal :sealed_source_corrupt, error.code
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

  def test_task_authority_rejects_unsafe_and_unavailable_entries
    with_home do |_state, _data, projects|
      root = projects.first.fetch("hive_state_path")
      task = task_path(projects, "idea.md")
      hardlink = File.join(File.dirname(task), "hardlink.md")
      File.link(task, hardlink)
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        Hive::RuntimeControlPlane::Cutover.task_authority(projects)
      end
      assert_equal :task_authority_unsafe, error.code
      File.unlink(hardlink)

      original = File.method(:lstat)
      failing = lambda do |path|
        raise Errno::EIO, path if path == task

        original.call(path)
      end
      error = with_replaced_singleton_method(File, :lstat, failing) do
        assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          Hive::RuntimeControlPlane::Cutover.task_authority(projects)
        end
      end
      assert_equal :task_authority_unavailable, error.code
    end
  end

  def test_bootstrap_rejects_legacy_material_and_invalid_project_identities
    with_home do |state, data, projects|
      File.binwrite(File.join(state, "task-counter.yml"), "legacy\n")
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).bootstrap(confirm: true)
      end
      assert_equal :legacy_state_present, error.code
    end

    with_home do |state, data, projects|
      projects.first["registration_id"] = "legacy:#{REGISTRATION_ID}"
      assert_equal "active", build_cutover(state, data, projects).run(confirm: true).phase
    end

    with_home do |state, data, projects|
      projects.first["project_id"] = "invalid"
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::ProjectError) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :invalid_project_identity, error.code
    end

    with_home do |state, data, projects|
      projects.first.delete("registration_id")
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::ProjectError) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :invalid_project_identity, error.code
    end
  end

  def test_invalid_task_metadata_and_pre_ready_source_changes_fail_closed
    with_home do |state, data, projects|
      File.binwrite(task_path(projects, "meta.yml"), "---\n[unterminated\n")
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::ProjectError) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :project_invalid, error.code
    end

    with_home do |state, data, projects|
      task = task_path(projects, "idea.md")
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        File.binwrite(task, "changed before ready\n") if point == :services_stopped
      })
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.run(confirm: true)
      end
      assert_equal :source_changed, error.code
    end
  end

  def test_candidate_import_and_database_custody_errors_are_typed
    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)
      cutover.define_singleton_method(:insert_tasks) do |*|
        raise Sequel::DatabaseError, "insert failed"
      end
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.run(confirm: true)
      end
      assert_equal :candidate_import_failed, error.code
    end

    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)
      cutover.instance_variable_set(:@cutover_id, "custody-test")
      Hive::RuntimeControlPlane::Database.new(path: cutover.send(:build_path)).migrate!.disconnect
      parent = File.dirname(Hive::Paths.runtime_control_plane_path(state))
      original = File.method(:lstat)
      unsafe = lambda do |path|
        status = original.call(path)
        path == parent ? Struct.new(:directory?, :symlink?, :uid).new(true, false, Process.euid + 1) : status
      end
      error = with_replaced_singleton_method(File, :lstat, unsafe) do
        assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          cutover.send(
            :install_database!, "activation_epoch" => 1,
            "activated_at" => Time.utc(2026, 8, 29, 12).iso8601(6)
          )
        end
      end
      assert_equal :database_custody_invalid, error.code
    end
  end

  def test_legacy_attempt_and_lock_corruption_are_typed
    with_home do |state, data, projects|
      records = File.join(state, "attempts", "v4", "records")
      FileUtils.mkdir_p(records)
      File.binwrite(File.join(records, "broken.json"), "{")
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :legacy_runtime_invalid, error.code
    end

    with_home do |state, data, projects|
      lock_path = File.join(File.dirname(task_path(projects, "idea.md")), ".lock")
      File.binwrite(lock_path, "---\n[broken\n")
      assert_equal "active", build_cutover(state, data, projects).run(confirm: true).phase
    end

    with_home do |state, data, projects|
      lock_path = File.join(File.dirname(task_path(projects, "idea.md")), ".lock")
      File.binwrite(lock_path, "---\npid: 1\n")
      original = File.method(:open)
      failing = lambda do |path, *arguments, &block|
        raise Errno::EACCES, path if path == lock_path

        original.call(path, *arguments, &block)
      end
      error = with_replaced_singleton_method(File, :open, failing) do
        assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          build_cutover(state, data, projects).run(confirm: true)
        end
      end
      assert_equal :legacy_runtime_invalid, error.code
    end
  end

  def test_legacy_guard_open_and_flock_errors_close_the_handle
    with_home do |state, data, projects|
      guard_path = File.join(state, ".task-counter.lock")
      File.binwrite(guard_path, "")
      original = File.method(:lstat)
      invalid = lambda do |path|
        status = original.call(path)
        path == guard_path ? Struct.new(:file?, :directory?, :symlink?, :nlink, :uid, :dev, :ino)
          .new(false, false, false, 1, Process.euid, status.dev, status.ino) : status
      end
      error = with_replaced_singleton_method(File, :lstat, invalid) do
        assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          build_cutover(state, data, projects).run(confirm: true)
        end
      end
      assert_equal :legacy_runtime_invalid, error.code
    end

    with_home do |state, data, projects|
      guard_path = File.join(state, ".task-counter.lock")
      File.binwrite(guard_path, "")
      original = File.method(:open)
      failing = lambda do |path, *arguments, &block|
        raise Errno::EACCES, path if path == guard_path

        original.call(path, *arguments, &block)
      end
      error = with_replaced_singleton_method(File, :open, failing) do
        assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          build_cutover(state, data, projects).run(confirm: true)
        end
      end
      assert_equal :legacy_runtime_invalid, error.code
    end
  end

  def test_usage_snapshot_source_change_and_validation_fail_closed
    with_home do |state, data, projects|
      source = File.join(data, "usage.db")
      write_usage(source)
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        FileUtils.rm_f(source) if point == :fleet_ready
      })
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.run(confirm: true)
      end
      assert_equal :sealed_source_corrupt, error.code
    end

    with_home do |state, data, projects|
      write_usage(File.join(data, "usage.db"))
      cutover = build_cutover(state, data, projects)
      counter = 0
      cutover.define_singleton_method(:usage_content_digest) do |_database|
        counter += 1
        "digest-#{counter}"
      end
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.run(confirm: true)
      end
      assert_equal :source_changed, error.code
    end
  end

  def test_sealed_usage_evidence_checks_shape_digest_rows_and_open_errors
    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)
      path = cutover.send(:usage_snapshot_path)
      FileUtils.mkdir_p(File.dirname(path))
      assert cutover.send(:validate_usage_snapshot!, nil)
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.send(:validate_usage_snapshot!, {})
      end
      assert_equal :sealed_source_corrupt, error.code

      write_usage(path)
      evidence = {
        "sha256" => Digest::SHA256.file(path).hexdigest,
        "bytes" => File.size(path), "rows" => 1
      }
      assert cutover.send(:validate_usage_snapshot!, evidence)
      wrong_rows = evidence.merge("rows" => 2)
      assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.send(:validate_usage_snapshot!, wrong_rows)
      end
      wrong_digest = evidence.merge("sha256" => "0" * 64)
      assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.send(:validate_usage_snapshot!, wrong_digest)
      end

      connect = ->(**) { raise Sequel::DatabaseError, "cannot open" }
      error = with_replaced_singleton_method(Sequel, :connect, connect) do
        assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          cutover.send(:validate_usage_snapshot!, evidence)
        end
      end
      assert_equal :sealed_source_corrupt, error.code
    end
  end

  def test_existing_database_manifest_identity_and_stale_run_fail_closed
    with_home do |state, data, projects|
      path = Hive::Paths.runtime_control_plane_path(state)
      Hive::RuntimeControlPlane::Database.new(path: path).migrate!.disconnect
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :database_already_present, error.code
    end

    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)
      result = cutover.bootstrap(confirm: true)
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!
      database.transaction { |db| db[:installations].update(activation_epoch: 999) }
      database.disconnect
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :candidate_invalid, error.code
    end

    with_home do |state, data, projects|
      current = File.join(state, ".runtime-cutover", "current")
      FileUtils.mkdir_p(current)
      File.binwrite(File.join(current, "stale"), "partial")
      assert_equal "active", build_cutover(state, data, projects).run(confirm: true).phase
    end
  end

  def test_incomplete_run_race_and_preflight_io_error_are_typed
    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)
      cutover.instance_variable_set(:@cutover_id, "race")
      FileUtils.mkdir_p(cutover.send(:current_root))
      cutover.define_singleton_method(:current_phase) { "ready" }
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.send(:reject_existing_run!)
      end
      assert_equal :cutover_incomplete, error.code
    end

    with_home do |state, data, projects|
      failure = ->(*) { raise Errno::EIO, "probe failed" }
      error = with_replaced_singleton_method(Hive::AtomicFile, :write, failure) do
        assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          build_cutover(state, data, projects).run(confirm: true)
        end
      end
      assert_equal :storage_preflight_failed, error.code
    end
  end

  def test_import_attempt_shape_and_target_io_errors_fail_closed
    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)
      failure = ->(**) { raise Sequel::DatabaseError, "usage unavailable" }
      error = with_replaced_singleton_method(Sequel, :connect, failure) do
        assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          cutover.send(:import_usage, Object.new)
        end
      end
      assert_equal :usage_snapshot_invalid, error.code
    end

    with_home do |state, data, projects|
      records = File.join(state, "attempts", "v4", "records")
      FileUtils.mkdir_p(records)
      record = File.join(records, "attempt.json")
      File.binwrite(record, JSON.generate("attempt_id" => "attempt", "state" => "terminal"))
      File.link(record, File.join(records, "attempt-copy.json"))
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :legacy_runtime_invalid, error.code
    end

    with_home do |state, data, projects|
      target = File.join(state, "task-counter.yml")
      File.binwrite(target, "legacy")
      original = File.method(:lstat)
      failure = lambda do |path|
        raise Errno::EIO, path if path == target

        original.call(path)
      end
      error = with_replaced_singleton_method(File, :lstat, failure) do
        assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          build_cutover(state, data, projects).run(confirm: true)
        end
      end
      assert_equal :legacy_runtime_invalid, error.code
    end
  end

  def test_guard_flock_race_is_reported_as_a_live_writer
    with_home do |state, data, projects|
      guard_path = File.join(state, ".task-counter.lock")
      File.binwrite(guard_path, "")
      original = File.method(:open)
      replacement = lambda do |path, *arguments, &block|
        handle = original.call(path, *arguments)
        handle.define_singleton_method(:flock) do |*|
          raise Errno::EWOULDBLOCK, path
        end if path == guard_path
        block ? block.call(handle) : handle
      ensure
        handle&.close if block && !handle.closed?
      end
      error = with_replaced_singleton_method(File, :open, replacement) do
        assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
          build_cutover(state, data, projects).run(confirm: true)
        end
      end
      assert_equal :live_runtime_owner, error.code
    end
  end

  def test_status_rejects_database_identity_drift
    with_home do |state, data, projects|
      result = build_cutover(state, data, projects).bootstrap(confirm: true)
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!
      database.transaction { |db| db[:installations].update(activation_epoch: 999) }

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        Hive::RuntimeControlPlane::Cutover.inspect_status(state_home: state, database: database)
      end
      assert_equal :activation_identity_mismatch, error.code
    ensure
      database&.disconnect
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
