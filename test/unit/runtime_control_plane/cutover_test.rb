require "test_helper"
require "hive/attempts/repository"
require "hive/commands/runtime"
require "hive/runtime_control_plane/cutover"
require "hive/runtime_control_plane/legacy_import"
require "hive/runtime_control_plane/maintenance"
require "hive/task_journal"
require "hive/task_projection/store"

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

  def test_fresh_bootstrap_requires_confirmation_and_activates_verified_database
    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::ConfirmationRequired) do
        cutover.bootstrap(confirm: false)
      end
      assert_equal :confirmation_required, error.code
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)

      result = cutover.bootstrap(confirm: true)

      assert_equal "active", result.phase
      assert Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(state)
      ).diagnostics.ok?
      assert_equal %i[stopped active], cutover.services.events
    end
  end

  def test_failure_after_sealing_keeps_fences_and_resumes_forward
    with_home do |state, data, projects|
      legacy = File.join(state, "task-counter.yml")
      File.binwrite(legacy, "---\ngeneration: 4\n")
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        raise "injected" if point == :candidate_validated
      })

      assert_raises(RuntimeError) { cutover.run(confirm: true) }

      assert File.directory?(legacy)
      assert_path_exists File.join(state, ".runtime-cutover", "current", "sealed", "state", "task-counter.yml")
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
      assert_equal "active", build_cutover(state, data, projects).resume.phase
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
      assert_path_exists File.join(state, ".runtime-cutover", "current")
      refute_path_exists File.join(state, ".runtime-cutover", "current", "sealed")
    end
  end

  def test_post_intent_failure_resumes_forward_without_reading_mutable_legacy_source
    with_home do |state, data, projects|
      legacy = File.join(state, "operational")
      FileUtils.mkdir_p(legacy)
      attempts = 0
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        next unless point == :activation_intent

        attempts += 1
        raise "power loss" if attempts == 1
      })

      assert_raises(RuntimeError) { cutover.run(confirm: true) }
      assert File.file?(legacy), "retired directory must remain fenced after intent"
      File.binwrite(legacy, "tampered tombstone")

      result = cutover.resume

      assert_equal "active", result.phase
      assert Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(state)
      ).diagnostics.ok?
      assert_equal 1, attempts
    end
  end

  def test_intended_resume_rejects_a_tampered_closed_candidate
    with_home do |state, data, projects|
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :activation_intent
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
      candidate = File.join(state, ".runtime-cutover", "current", "candidate.sqlite3")
      File.open(candidate, "ab") { |file| file << "tampered" }

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).resume
      end

      assert_equal :candidate_invalid, error.code
      refute_path_exists File.join(state, ".runtime-cutover", "current", "active.json")
    end
  end

  def test_unsafe_intended_manifest_never_downgrades_to_pre_intent_rollback
    with_home do |state, data, projects|
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :activation_intent
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
      current = File.join(state, ".runtime-cutover", "current")
      intended = File.join(current, "intended.json")
      File.unlink(intended)
      File.symlink("missing-intended.json", intended)

      error = assert_raises(Hive::RuntimeControlPlane::CutoverManifest::IntegrityError) do
        build_cutover(state, data, projects).resume
      end

      assert_equal :manifest_unsafe, error.code
      assert_path_exists current
      assert_path_exists File.join(current, "candidate.sqlite3")
    end
  end

  def test_each_candidate_install_boundary_resumes_from_the_retained_bundle
    %i[candidate_payloads_installed candidate_database_installed candidate_identity_published].each do |boundary|
      with_home do |state, data, projects|
        crashing = build_cutover(state, data, projects, fault: lambda { |point|
          raise SimulatedCrash if point == boundary
        })
        assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
        candidate = File.join(state, ".runtime-cutover", "current", "candidate.sqlite3")
        assert_path_exists candidate

        result = build_cutover(state, data, projects).resume

        assert_equal "active", result.phase, boundary
        assert Hive::RuntimeControlPlane::Database.new(path: result.database_path).diagnostics.ok?
        assert_path_exists candidate
      end
    end
  end

  def test_intended_resume_replaces_corrupt_live_database_and_payloads_from_candidate
    with_home do |state, data, projects|
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :candidate_database_installed
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
      live = Hive::Paths.runtime_control_plane_path(state)
      File.binwrite(live, "corrupt")
      payloads = Hive::Paths.runtime_payload_root(state)
      File.binwrite(File.join(payloads, "unexpected"), "corrupt")

      result = build_cutover(state, data, projects).resume

      assert_equal "active", result.phase
      assert Hive::RuntimeControlPlane::Database.new(path: live).diagnostics.ok?
      refute_path_exists File.join(payloads, "unexpected")
    end
  end

  def test_missing_project_requires_an_explicit_recorded_exclusion
    with_home(create_project: false) do |state, data, projects|
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::ProjectError) do
        build_cutover(state, data, projects).run(confirm: true)
      end
      assert_equal :project_missing, error.code
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)

      result = build_cutover(state, data, projects).run(
        confirm: true, exclusions: [ "alpha" ]
      )
      assert_equal [ "alpha" ], result.exclusions.map { |entry| entry.fetch("name") }
    end
  end

  def test_terminal_attempt_receipt_and_payload_are_preserved_once
    with_home do |state, data, projects|
      record = terminal_attempt(File.join(state, "record-builder"))
      attempt_root = File.join(state, "attempts", "v4")
      FileUtils.mkdir_p(File.join(attempt_root, "records"))
      FileUtils.mkdir_p(File.join(attempt_root, "proof"))
      FileUtils.mkdir_p(File.join(attempt_root, "logs"))
      File.binwrite(File.join(attempt_root, "records", "attempt-1.json"), JSON.generate(record.to_h))
      receipt_digest = Digest::SHA256.hexdigest(
        Hive::RuntimeControlPlane::Codec.dump_json(record.receipt)
      )
      File.binwrite(
        File.join(attempt_root, "proof", "attempt-1.json"),
        JSON.generate("attempt_id" => "attempt-1", "receipt_digest" => receipt_digest)
      )
      File.binwrite(File.join(attempt_root, "logs", "attempt-1.frames"), "terminal log\n")
      usage = Sequel.sqlite(File.join(data, "usage.db"))
      usage.create_table(:token_usage) do
        String :id, primary_key: true
        String :agent, null: false
        String :started_at, null: false
        String :task_id
        String :attempt_id
      end
      usage[:token_usage].insert(
        id: "usage-1", agent: "codex", started_at: "2026-08-29T12:00:00.000000Z",
        task_id: "7", attempt_id: "attempt-1"
      )
      usage.disconnect

      result = build_cutover(state, data, projects).run(confirm: true)
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!
      attempt = database.read { |db| db[:attempts].where(attempt_id: "attempt-1").first }
      payload = database.read { |db| db[:payload_references].first }

      assert_equal "terminal", attempt.fetch(:state)
      assert_equal receipt_digest, attempt.fetch(:terminal_receipt_digest)
      assert_equal 1, database.read { |db| db[:attempts].where(attempt_id: "attempt-1").count }
      assert_equal 0, database.read { |db| db[:terminal_pending_publications].count }
      assert_equal "attempt-1", database.read { |db| db[:token_usage].get(:attempt_id) }
      assert_equal "terminal log\n", File.binread(
        File.join(Hive::Paths.runtime_payload_root(state), payload.fetch(:relative_path))
      )
    ensure
      usage&.disconnect
      database&.disconnect
    end
  end

  def test_dispatch_sequence_and_pending_result_survive_cutover
    with_home do |state, data, projects|
      requests = File.join(state, "dispatch_requests")
      results = File.join(state, "dispatch_results")
      FileUtils.mkdir_p([ requests, results ])
      File.binwrite(File.join(requests, "request-1.json"), JSON.generate(
        "schema" => "hive-dispatch-request", "schema_version" => 5,
        "request_id" => "request-1", "project" => "alpha", "slug" => "first-task",
        "argv" => %w[run first-task], "requestor" => "bot",
        "created_at" => "2026-08-29T12:00:00.000000Z"
      ))
      File.binwrite(File.join(requests, "request-1.sequence"), JSON.generate(
        "request_id" => "request-1", "remaining_argvs" => [ %w[status alpha] ]
      ))
      File.binwrite(File.join(results, "result-1.json"), JSON.generate(
        "schema" => "hive-dispatch-result", "schema_version" => 2,
        "result_id" => "result-1", "request_id" => "request-1", "project" => "alpha",
        "slug" => "first-task", "chat_id" => "chat-1", "exit_code" => 0,
        "command" => "run", "created_at" => "2026-08-29T12:00:01.000000Z"
      ))

      result = build_cutover(state, data, projects).run(confirm: true)
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!
      request = database.read { |db| db[:dispatch_requests].where(request_id: "request-1").first }
      outbox = database.read { |db| db[:dispatch_outbox].where(delivery_id: "result-1").first }

      assert_equal [ %w[status alpha] ], JSON.parse(request.fetch(:payload_json)).fetch("remaining_argvs")
      assert_equal "completed", request.fetch(:state)
      assert_equal "pending", outbox.fetch(:state)
      assert_equal "legacy-result:result-1", outbox.fetch(:idempotency_key)
    ensure
      database&.disconnect
    end
  end

  def test_unsupported_nonempty_legacy_domain_fails_without_activation
    with_home do |state, data, projects|
      runtime = File.join(projects.first.fetch("hive_state_path"), "daemon")
      FileUtils.mkdir_p(runtime)
      source = File.join(runtime, "pr-merge-reconciliation.json")
      File.binwrite(source, JSON.generate("project" => "alpha"))

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).run(confirm: true)
      end

      assert_equal :unsupported_legacy_state, error.code
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
      assert File.directory?(source)
      assert_path_exists File.join(
        state, ".runtime-cutover", "current", "sealed",
        "project-#{PROJECT_ID}", ".hive-state", "daemon", "pr-merge-reconciliation.json"
      )
    end
  end

  def test_real_pr_reconciliation_and_provider_journal_survive_cutover
    with_home do |state, data, projects|
      project = projects.first
      daemon = File.join(project.fetch("hive_state_path"), "daemon")
      FileUtils.mkdir_p(daemon)
      key = "a" * 64
      timestamp = "2026-08-29T12:00:00.000000Z"
      candidate = {
        "key" => key,
        "task" => { "project" => "alpha", "slug" => "first-task", "id" => 7,
                    "workflow" => "coding", "folder" => "stages/1-inbox/first-task" },
        "observation" => { "stage" => "5-open-pr", "marker" => "complete",
                           "marker_generation" => "b" * 64,
                           "task_generation" => "c" * 64, "state_file_mtime" => timestamp,
                           "held" => false, "hold_reason" => nil },
        "pull_request" => { "url" => "https://github.com/acme/alpha/pull/42",
                            "host" => "github.com", "repository" => "acme/alpha",
                            "number" => 42, "observed_head" => "d" * 40 },
        "remote" => { "state" => "unknown", "merge_oid" => nil,
                      "merged_at" => nil, "observed_at" => nil },
        "architecture" => { "status" => "pending", "request_id" => nil,
                            "receipt" => nil, "last_error" => nil },
        "archive" => { "status" => "pending", "receipt_digest" => nil,
                       "archived_at" => nil, "last_error" => nil },
        "retry" => { "failures" => 0, "not_before" => nil }, "updated_at" => timestamp
      }
      File.binwrite(File.join(daemon, "pr-merge-reconciliation.json"), JSON.generate(
        "schema" => "hive-pr-merge-reconciliation", "schema_version" => 1,
        "registration" => REGISTRATION_ID, "project_path" => project.fetch("path"),
        "hive_state_path" => project.fetch("hive_state_path"), "host" => "github.com",
        "repository" => "acme/alpha", "default_branch" => "main", "cursor" => key,
        "backlog" => { "watermark" => timestamp, "scanned_at" => timestamp,
                       "complete" => true, "outcomes" => {} },
        "updated_at" => timestamp, "candidates" => { key => candidate }
      ))
      provider_root = File.join(
        state, "provider-health", "v1", "scopes", "provider-account",
        "ad9163f4d87c3214735bcd893bbe1891fa7b9db4f44a14d3c6490b9bdd33aa2a"
      )
      FileUtils.mkdir_p(provider_root)
      File.binwrite(File.join(provider_root, "journal.jsonl"), provider_snapshot_event)

      result = build_cutover(state, data, projects).run(confirm: true)
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!

      assert_equal key, database.read { |db| db[:pr_merge_reconciliations].get(:reconciliation_id) }
      assert_equal key, database.read { |db| db[:pr_merge_project_state].get(:cursor) }
      assert_equal "closed", database.read { |db| db[:provider_circuits].get(:automatic_state) }
      assert_equal "event-1", database.read { |db| db[:provider_audit].get(:event_id) }
    ensure
      database&.disconnect
    end
  end

  def test_retry_restarts_forward_after_a_crash_before_the_first_manifest
    with_home do |state, data, projects|
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :run_prepared
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
      assert_path_exists File.join(state, ".runtime-cutover", "current")

      resumed = build_cutover(state, data, projects).run(confirm: true)

      assert_equal "active", resumed.phase
      assert_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_resume_completes_an_absent_source_fence_after_a_mid_fence_crash
    with_home do |state, data, projects|
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :fence_installed
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
      tombstone = File.join(state, "dispatch_requests")
      assert File.file?(tombstone)

      result = build_cutover(state, data, projects).resume

      assert_equal "active", result.phase
      assert File.file?(tombstone)
      assert_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_sealed_source_mutation_fails_closed_without_restoration
    with_home do |state, data, projects|
      live = File.join(state, "task-counter.yml")
      File.binwrite(live, "---\ngeneration: 4\n")
      cutover = build_cutover(state, data, projects, fault: lambda { |point|
        File.binwrite(
          File.join(state, ".runtime-cutover", "current", "sealed", "state", "task-counter.yml"),
          "---\ngeneration: 999\n"
        ) if point == :sources_sealed
      })

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.run(confirm: true)
      end

      assert_equal :sealed_source_corrupt, error.code
      assert File.directory?(live)
      assert_equal "---\ngeneration: 999\n", File.binread(
        File.join(state, ".runtime-cutover", "current", "sealed", "state", "task-counter.yml")
      )
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_sealed_inventory_rejects_traversal_wrong_mode_and_wrong_type
    with_home do |state, data, projects|
      source = File.join(state, "task-counter.yml")
      File.binwrite(source, "---\ngeneration: 4\n")
      cutover = build_cutover(state, data, projects)
      cutover.run(confirm: true)
      sealed = File.join(state, ".runtime-cutover", "current", "sealed")
      manifest_path = File.join(sealed, "manifest.json")
      original = JSON.parse(File.binread(manifest_path))
      entry = original.fetch("legacy_paths").find { |item| item["relative_path"] == "task-counter.yml" }

      entry["relative_path"] = "../outside"
      File.binwrite(manifest_path, JSON.generate(original))
      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.send(:validate_sealed_set!, sealed)
      end
      assert_equal :sealed_source_corrupt, error.code

      File.binwrite(manifest_path, JSON.generate(original.tap { entry["relative_path"] = "task-counter.yml" }))
      copy = File.join(sealed, "state", "task-counter.yml")
      File.chmod(0o777, copy)
      assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.send(:validate_sealed_set!, sealed)
      end
      File.chmod(entry.fetch("mode"), copy)
      File.unlink(copy)
      FileUtils.mkdir_p(copy)
      assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        cutover.send(:validate_sealed_set!, sealed)
      end
    end
  end

  def test_corrupt_fence_journal_preserves_recovery_evidence_and_mixed_state
    with_home do |state, data, projects|
      source = File.join(state, "task-counter.yml")
      File.binwrite(source, "---\ngeneration: 4\n")
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :sources_sealed
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
      current = File.join(state, ".runtime-cutover", "current")
      File.binwrite(File.join(current, "fences.json"), "{")

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).resume
      end

      assert_equal :recovery_metadata_corrupt, error.code
      assert_path_exists current
      assert_path_exists File.join(current, "sealed", "state", "task-counter.yml")
      assert File.directory?(source)
    end
  end

  def test_unsafe_fence_journal_preserves_recovery_evidence_and_mixed_state
    with_home do |state, data, projects|
      source = File.join(state, "task-counter.yml")
      File.binwrite(source, "---\ngeneration: 4\n")
      crashing = build_cutover(state, data, projects, fault: lambda { |point|
        raise SimulatedCrash if point == :sources_sealed
      })
      assert_raises(SimulatedCrash) { crashing.run(confirm: true) }
      current = File.join(state, ".runtime-cutover", "current")
      journal = File.join(current, "fences.json")
      File.unlink(journal)
      File.symlink("missing-fences.json", journal)

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::Error) do
        build_cutover(state, data, projects).resume
      end

      assert_equal :recovery_metadata_corrupt, error.code
      assert_path_exists current
      assert_path_exists File.join(current, "sealed", "state", "task-counter.yml")
      assert File.directory?(source)
    end
  end

  def test_missing_task_identity_fails_without_mutating_task_authority
    with_home do |state, data, projects|
      metadata = File.join(
        projects.first.fetch("hive_state_path"), "stages", "1-inbox", "first-task", "meta.yml"
      )
      File.binwrite(metadata, "---\nworkflow: coding\n")
      original = File.binread(metadata)

      error = assert_raises(Hive::RuntimeControlPlane::Cutover::ProjectError) do
        build_cutover(state, data, projects).run(confirm: true)
      end

      assert_equal :task_identity_missing, error.code
      assert_equal original, File.binread(metadata)
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_active_phase_is_published_only_after_service_activation_and_retries
    with_home do |state, data, projects|
      services = FlakyServices.new([])
      cutover = build_cutover(state, data, projects, services: services)

      assert_raises(RuntimeError) { cutover.bootstrap(confirm: true) }
      refute_path_exists File.join(state, ".runtime-cutover", "current", "active.json")
      assert_path_exists File.join(state, ".runtime-cutover", "current", "intended.json")

      result = cutover.resume

      assert_equal "active", result.phase
      assert_equal 2, services.events.count(:active)
    end
  end

  def test_existing_active_cutover_is_idempotent_without_lifecycle_side_effects
    with_home do |state, data, projects|
      cutover = build_cutover(state, data, projects)
      original = cutover.bootstrap(confirm: true)
      cutover.services.events.clear

      repeated = cutover.run(confirm: true)

      assert_equal original.cutover_id, repeated.cutover_id
      assert_empty cutover.services.events
    end
  end

  def test_live_attempt_refuses_cutover_with_owner_before_activation
    with_home do |state, data, projects|
      record = launching_attempt(File.join(state, "record-builder"))
      records = File.join(state, "attempts", "v4", "records")
      FileUtils.mkdir_p(records)
      File.binwrite(File.join(records, "attempt-1.json"), JSON.generate(record.to_h))

      error = assert_raises(Hive::RuntimeControlPlane::LegacyImport::QuiescenceError) do
        build_cutover(state, data, projects).run(confirm: true)
      end

      assert_equal :live_attempt, error.code
      assert_equal "attempt-1", error.details.fetch(:attempt_id)
      refute_path_exists Hive::Paths.runtime_control_plane_path(state)
    end
  end

  def test_live_wal_and_shm_are_backed_up_and_usage_imports_from_a_consistent_snapshot
    with_home do |state, data, projects|
      source = File.join(state, "usage-source.sqlite3")
      legacy = Sequel.sqlite(source)
      legacy.run("PRAGMA journal_mode=WAL")
      legacy.run("PRAGMA wal_autocheckpoint=0")
      legacy.create_table(:token_usage) do
        String :id, primary_key: true
        String :agent, null: false
        String :started_at, null: false
      end
      legacy[:token_usage].insert(
        id: "usage-1", agent: "codex", started_at: "2026-08-29T12:00:00.000000Z"
      )
      %w[ usage-source.sqlite3 usage-source.sqlite3-wal usage-source.sqlite3-shm ].each do |name|
        suffix = name.delete_prefix("usage-source.sqlite3")
        FileUtils.cp(File.join(state, name), File.join(data, "usage.db#{suffix}"))
      end
      legacy.disconnect

      result = build_cutover(state, data, projects).run(confirm: true)
      sealed = JSON.parse(File.binread(
        File.join(state, ".runtime-cutover", "current", "sealed", "manifest.json")
      ))
      paths = sealed.fetch("legacy_paths").map { |entry| entry.fetch("relative_path") }
      database = Hive::RuntimeControlPlane::Database.new(path: result.database_path).open!

      assert_includes paths, "usage.db-wal"
      assert_includes paths, "usage.db-shm"
      assert_equal "codex", database.read { |db| db[:token_usage].where(id: "usage-1").get(:agent) }
    ensure
      legacy&.disconnect
      database&.disconnect
    end
  end

  def test_cutover_fences_every_retired_project_writer_path_without_changing_task_authority
    with_home do |state, data, projects|
      before = Hive::RuntimeControlPlane::Cutover.task_authority(projects)

      build_cutover(state, data, projects).run(confirm: true)

      task = File.join(projects.first.fetch("hive_state_path"), "stages", "1-inbox", "first-task")
      paths = [
        File.join(projects.first.fetch("hive_state_path"), "daemon", "pr-merge-reconciliation.json"),
        *Hive::RuntimeControlPlane::Cutover::TASK_RUNTIME_FILES.map { |name| File.join(task, name) }
      ]
      assert paths.all? { |path| File.directory?(path) }
      assert_equal before, Hive::RuntimeControlPlane::Cutover.task_authority(projects)
    end
  end

  def test_current_task_journal_and_projection_remain_writable_after_cutover
    with_home do |state, data, projects|
      build_cutover(state, data, projects).run(confirm: true)
      task = File.join(projects.first.fetch("hive_state_path"), "stages", "1-inbox", "first-task")
      before = Hive::RuntimeControlPlane::Cutover.task_authority(projects)
      writer = Hive::TaskJournal::Writer.new(task_folder: task)
      writer.append(
        event_type: "legacy_baseline", task: { "id" => "7", "slug" => "first-task" },
        workflow: "coding", stage: "1-inbox", attempt_id: "legacy", task_generation: 0,
        reason: "marker_import", evidence: [], provenance: { "source" => "cutover-test" }
      )
      journal = File.join(task, "task-journal.jsonl")
      projection = Hive::TaskProjection.project(
        records: Hive::TaskProjection.read_journal(journal), cursor: File.size(journal),
        journal_hash: Digest::SHA256.file(journal).hexdigest
      )
      Hive::TaskProjection::Store.new(task_folder: task, attempt_store: nil).publish(projection)

      assert File.file?(journal)
      assert File.file?(File.join(task, "task-projection.json"))
      refute_equal before, Hive::RuntimeControlPlane::Cutover.task_authority(projects)
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

  def build_cutover(state, data, projects, fault: nil, services: FakeServices.new([]))
    Hive::RuntimeControlPlane::Cutover.new(
      state_home: state, data_home: data, projects: projects,
      source_release: "0.7.2", target_release: "next",
      services: services, fault: fault
    )
  end

  def provider_snapshot_event
    <<~JSON
      {"schema":"hive-provider-health-event","schema_version":1,"event_id":"event-1","sequence":1,"scope":{"kind":"provider_account","provider_account_id":"codex","model":null},"journal_epoch":0,"kind":"snapshot","occurred_at":"2026-08-29T12:00:00.000000Z","idempotency_key":"16a0eeb0791b6c92451fd284dd9f599e0a7dbe7f6ebea6e2d2d06c7f74aec112","expected_generation":2,"previous_generation":2,"resulting_generation":2,"payload":{"state":{"automatic_state":"closed","eligible_at":null,"evidence":null,"last_event_id":null,"manual_block":null,"probe":null}}}
    JSON
  end

  def terminal_attempt(root)
    repository = Hive::Attempts::Repository.new(root: root, migrate: true)
    now = Time.utc(2026, 8, 29, 12)
    launching = build_launching(repository, now)
    claimed = repository.claim(
      launching,
      owner: { "pid" => Process.pid, "start_fingerprint" => "start", "session_id" => Process.getsid(0),
               "process_group_id" => Process.getpgrp },
      claim_capability: "c" * 64, first_heartbeat_timeout_sec: 30, now: now + 1
    )
    running = repository.first_heartbeat(claimed, stale_sec: 30, now: now + 2)
    repository.terminalize(
      running, outcome: "succeeded", exit_status: 0,
      final_checkpoint: { "revision" => "b" * 40, "progress_token" => "progress-1" },
      output_references: [],
      log_reference: { "path" => "open/attempt-1.frames", "size" => 0,
                       "sha256" => Digest::SHA256.hexdigest("") },
      now: now + 3
    )
  ensure
    repository&.database&.disconnect
  end

  def launching_attempt(root)
    repository = Hive::Attempts::Repository.new(root: root, migrate: true)
    build_launching(repository, Time.utc(2026, 8, 29, 12))
  ensure
    repository&.database&.disconnect
  end

  def build_launching(repository, now)
    repository.create_launching(
      attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
      task_id: "7", project: "alpha", task_slug: "first-task", intended_stage: "4-execute",
      task_generation: "generation-1", ownership_generation: "owner-1", task_input_epoch: 1,
      progress_token: "progress-1", provider: "codex", worker_argv: %w[hive run first-task],
      claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64),
      starting_revision: "a" * 40, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: now
    )
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
