require "test_helper"
require "digest"
require "fileutils"
require "tmpdir"
require "hive/daemon/recovery_coordinator"
require "hive/runtime_control_plane/dispatch_repository"
require "hive/attempts/finalization_maintenance"
require "hive/attempts/contracts"
require "hive/attempts/command_progress"
require "hive/patrol_fix/receipt_store"
require "hive/workflows/patrol_fix"
require "hive/provider_health/evidence"
require "hive/provider_routing/candidate"
require "hive/lock"
require "hive/markers"

class HiveDaemonRecoveryCoordinatorTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 25, 12, 0, 0)

  class SqlDispatchTestRepository
    class << self
      def repository(state_home)
        @repositories ||= {}
        @repositories[File.expand_path(state_home)] ||= begin
          database = Hive::RuntimeControlPlane::Database.new(
            path: Hive::Paths.runtime_control_plane_path(state_home)
          ).migrate!
          Hive::RuntimeControlPlane::DispatchRepository.new(database: database)
        end
      end

      def write_request!(project:, state_home:, **attributes)
        ensure_project(repository(state_home).database, project)
        repository(state_home).write_request!(project: project, **attributes)
      end

      def register_project(state_home, project)
        ensure_project(repository(state_home).database, project)
      end

      def method_missing(method, *args, **kwargs, &block)
        state_home = kwargs.delete(:state_home) || Hive::Paths.state_home
        target = repository(state_home)
        return super unless target.respond_to?(method)
        target.public_send(method, *args, **kwargs, &block)
      end

      def respond_to_missing?(method, include_private = false)
        Hive::RuntimeControlPlane::DispatchRepository.instance_methods.include?(method) || super
      end

      private

      def ensure_project(database, name)
        return if name == Hive::RuntimeControlPlane::DispatchRepository::GLOBAL_MAINTENANCE_PROJECT
        timestamp = Time.now.utc.iso8601(6)
        database.transaction do |db|
          installation = db[:installations].first.fetch(:installation_id)
          db[:projects].insert_conflict.insert(
            project_id: "recovery-#{Digest::SHA256.hexdigest(name)[0, 16]}",
            installation_id: installation, registration_id: name, name: name,
            observed_path: "/tmp/#{name}", state_root_path: "/tmp/#{name}/.hive-state",
            active: 1, registered_at: timestamp, last_observed_at: timestamp
          )
        end
      end
    end

    Request = Hive::RuntimeControlPlane::DispatchRepository::Request
    CLAIM_EXPIRY_SEC = Hive::RuntimeControlPlane::DispatchRepository::CLAIM_EXPIRY_SEC
    SCHEMA_VERSION = Hive::RuntimeControlPlane::DispatchRepository::SCHEMA_VERSION
  end

  Q = SqlDispatchTestRepository

  FakeTask = Data.define(:id, :slug, :folder, :state_file, :stage_index, :stage_name)
  FakeRow = Data.define(
    :project, :slug, :folder, :state_file, :stage, :workflow, :marker,
    :marker_attrs, :state_file_mtime, :live_task_lock, :attempt_id,
    :task_generation, :suggested_command
  )
  FakeGeneration = Data.define(:progress_token, :task_generation)

  def test_default_resolver_reuses_canonical_folder_for_historical_workflow_stage
    with_tmp_global_config do |home|
      project_root = File.join(home, "project-a")
      folder = File.join(
        project_root, ".hive-state", "stages", "4-execute", "historical-task"
      )
      FileUtils.mkdir_p(folder)
      File.write(
        File.join(home, "config.yml"),
        {
          "registered_projects" => [
            {
              "name" => "project-a", "path" => project_root,
              "hive_state_path" => File.join(project_root, ".hive-state")
            }
          ]
        }.to_yaml
      )
      coordinator = Hive::Daemon::RecoveryCoordinator.new(
        state_home: home, dispatch_repository: Object.new
      )

      resolved = coordinator.send(
        :resolve_task,
        project: "project-a", slug: "not-a-search-target",
        folder: folder, stage: "4-execute"
      )

      assert_equal File.realpath(folder), resolved.folder
      assert_equal "historical-task", resolved.slug
    end
  end

  def test_default_recovery_generation_matches_patrol_fix_dispatch_generation
    with_tmp_dir do |root|
      state_file = File.join(root, "patrol-fix-manifest.json")
      File.write(state_file, "{}\n")
      task_type = Data.define(
        :id, :slug, :folder, :state_file, :stage_index, :stage_name, :workflow
      )
      task = task_type.new(
        id: 42, slug: "durable-task", folder: root, state_file: state_file,
        stage_index: 1, stage_name: "inbox",
        workflow: Hive::Workflows::PatrolFix::DESCRIPTOR
      )
      Hive::PatrolFix::ReceiptStore.new(task_folder: root).append!(
        patrol_fix_decision_receipt(task.slug)
      )
      fallback = Hive::Attempts::Generation.artifact_token(task)
      dispatch_progress = Hive::Attempts::CommandProgress.token_for(
        argv: [ "hive", "run", task.slug ], task: task, fallback: fallback
      )
      dispatch_generation = Hive::Attempts::Generation.resolve(
        task: task, project: "demo", intended_stage: "1-inbox",
        progress_token: dispatch_progress
      )

      recovery_generation = Hive::Daemon::RecoveryCoordinator.allocate.send(
        :resolve_generation,
        task, project: "demo", intended_stage: "1-inbox",
        state_file_content: File.binread(state_file)
      )

      assert_equal dispatch_generation.progress_token, recovery_generation.progress_token
      assert_equal dispatch_generation.task_generation, recovery_generation.task_generation
    end
  end

  def test_shared_hourly_cooldown_ignores_later_provider_reset_hint
    with_fixture(marker_attrs: {
      "reason" => "limits_reached",
      "marker_id" => "marker-1",
      "retry_after" => (NOW + 3 * 3600).iso8601
    }, mtime: NOW - 3600) do |coordinator, row, state_home|
      write_terminal_recovery_history(
        row: row, state_home: state_home, retry_count: 25
      )
      receipt = coordinator.request(
        row: row, requestor: "healer", request_id: "auto-26",
        now: NOW
      )

      assert_equal "queued", receipt.status
      assert_equal 26, receipt.retry_count
      assert_equal NOW.iso8601(6), receipt.next_eligible_at
      request = Q.pending(state_home: state_home).fetch(0)
      assert_equal "admitted", request.recovery.fetch("phase")
      assert_equal (NOW + 3 * 3600).iso8601,
                   request.recovery.dig("provider_hint", "retry_after")
      assert_equal true, request.recovery.dig("provider_hint", "display_only")
    end
  end

  def test_recovery_backoff_resets_after_a_successful_stage_transition
    with_fixture(mtime: NOW - 6) do |coordinator, row, state_home|
      write_terminal_recovery_history(
        row: row.with(stage: "3-plan"), state_home: state_home, retry_count: 25
      )

      receipt = coordinator.request(
        row: row, requestor: "healer", request_id: "first-execute-retry", now: NOW
      )

      assert_equal "queued", receipt.status
      assert_equal 1, receipt.retry_count
      assert_equal 1, Q.pending(state_home: state_home).count do |request|
        request.request_id == "first-execute-retry"
      end
    end
  end

  def test_identical_failures_at_the_ladder_ceiling_park_without_dispatch
    attrs = {
      "reason" => "implementer_failed", "marker_id" => "marker-3",
      "provider" => "pi", "status" => "error", "message" => "same crash",
      "attempt_id" => "attempt-3"
    }
    with_fixture(marker_attrs: attrs, mtime: NOW - 3600) do |coordinator, row, state_home|
      fingerprint = coordinator.send(:failure_fingerprint, row, attrs)
      write_terminal_recovery_history(
        row: row, state_home: state_home,
        retry_count: Hive::Daemon::RecoveryCoordinator::RETRY_BACKOFF_SEC.length,
        failure_fingerprint: fingerprint, identical_failure_count: 2,
        failure_attempt_history: %w[attempt-1 attempt-2]
      )

      receipt = coordinator.request(
        row: row, requestor: "healer", request_id: "deterministic", now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "deterministic_failure", receipt.reason
      request = Q.fetch("deterministic", state_home: state_home)
      assert_equal 3, request.recovery.fetch("identical_failure_count")
      assert_equal %w[attempt-1 attempt-2 attempt-3],
                   request.recovery.fetch("failure_attempt_history")
      assert_equal "operator", request.recovery.fetch("owner")
      assert_equal "admitted", request.recovery.fetch("phase")

      persisted_revision = request.revision
      3.times do |tick|
        replay = coordinator.resume(request:, row:, now: NOW + tick + 1)

        assert_equal "blocked", replay.status
        assert_equal "deterministic_failure", replay.reason
        assert_equal "parked", replay.escalation_tier
        request = Q.fetch("deterministic", state_home: state_home)
        assert_equal persisted_revision, request.revision,
                     "daemon replay must not mutate or unpark the request"
      end
      assert_equal "error", Hive::Markers.current(row.state_file).name.to_s
    end
  end

  def test_explicit_retry_unparks_and_changed_failure_reenters_with_a_fresh_count
    attrs = {
      "reason" => "implementer_failed", "marker_id" => "marker-3",
      "provider" => "pi", "status" => "error", "message" => "same crash",
      "attempt_id" => "attempt-3"
    }
    with_fixture(marker_attrs: attrs, mtime: NOW - 3600) do |coordinator, row, state_home|
      fingerprint = coordinator.send(:failure_fingerprint, row, attrs)
      write_terminal_recovery_history(
        row:, state_home:,
        retry_count: Hive::Daemon::RecoveryCoordinator::RETRY_BACKOFF_SEC.length,
        failure_fingerprint: fingerprint, identical_failure_count: 2,
        failure_attempt_history: %w[attempt-1 attempt-2]
      )
      coordinator.request(
        row:, requestor: "healer", request_id: "deterministic", now: NOW
      )

      unparked = coordinator.request(
        row:, requestor: "action",
        observation_token: coordinator.observation_token_for(row),
        now: NOW + 1
      )

      assert_equal "queued", unparked.status
      assert_equal "admitted", unparked.phase
      assert_nil unparked.reason
      request = Q.fetch("deterministic", state_home: state_home)
      assert_nil request.recovery.fetch("blocked_reason")
      assert_equal "scheduler", request.recovery.fetch("owner")

      resumed = coordinator.resume(request:, row:, now: NOW + 1)
      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      request = Q.fetch("deterministic", state_home: state_home)
      coordinator.mark_dispatched(request, attempt_id: "attempt-4", now: NOW + 1)
      request = Q.fetch("deterministic", state_home: state_home)
      coordinator.mark_dispatched(
        request, attempt_id: "attempt-4", terminal: true,
        outcome: "failed", now: NOW + 2
      )

      changed_attrs = attrs.merge(
        "marker_id" => "marker-4", "attempt_id" => "attempt-4",
        "message" => "different crash"
      )
      changed_at = NOW + 2
      File.write(
        row.state_file,
        "# Task\n\n#{Hive::Markers.build_marker('ERROR', changed_attrs)}\n"
      )
      File.utime(changed_at, changed_at, row.state_file)
      changed_row = row.with(
        marker_attrs: changed_attrs, state_file_mtime: changed_at,
        attempt_id: "attempt-4"
      )

      retried = coordinator.request(
        row: changed_row, requestor: "healer", request_id: "changed-after-unpark",
        now: changed_at + 3600
      )

      assert_equal "queued", retried.status
      changed = Q.fetch("changed-after-unpark", state_home: state_home)
      assert_equal 1, changed.recovery.fetch("identical_failure_count")
      assert_equal [ "attempt-4" ], changed.recovery.fetch("failure_attempt_history")
    end
  end

  def test_explicit_retry_keeps_the_park_when_the_unpark_transition_is_lost
    attrs = {
      "reason" => "implementer_failed", "marker_id" => "marker-3",
      "provider" => "pi", "status" => "error", "message" => "same crash",
      "attempt_id" => "attempt-3"
    }
    with_fixture(marker_attrs: attrs, mtime: NOW - 3600) do |coordinator, row, state_home|
      fingerprint = coordinator.send(:failure_fingerprint, row, attrs)
      write_terminal_recovery_history(
        row:, state_home:,
        retry_count: Hive::Daemon::RecoveryCoordinator::RETRY_BACKOFF_SEC.length,
        failure_fingerprint: fingerprint, identical_failure_count: 2,
        failure_attempt_history: %w[attempt-1 attempt-2]
      )
      coordinator.request(
        row:, requestor: "healer", request_id: "deterministic", now: NOW
      )

      repository = coordinator.instance_variable_get(:@request_queue)
      result = with_replaced_singleton_method(
        repository, :update_recovery!, ->(*) { false }
      ) do
        coordinator.request(
          row:, requestor: "action",
          observation_token: coordinator.observation_token_for(row),
          now: NOW + 1
        )
      end

      assert_equal "blocked", result.status
      assert_equal "deterministic_failure", result.reason
      request = Q.fetch("deterministic", state_home: state_home)
      assert_equal "deterministic_failure", request.recovery.fetch("blocked_reason")
      assert_equal "operator", request.recovery.fetch("owner")
    end
  end

  def test_changed_failure_fingerprint_retries_freely_at_the_ladder_ceiling
    with_fixture(marker_attrs: {
      "reason" => "implementer_failed", "marker_id" => "marker-new",
      "provider" => "pi", "message" => "a different crash"
    }, mtime: NOW - 3600) do |coordinator, row, state_home|
      write_terminal_recovery_history(
        row: row, state_home: state_home,
        retry_count: Hive::Daemon::RecoveryCoordinator::RETRY_BACKOFF_SEC.length,
        failure_fingerprint: "f" * 64, identical_failure_count: 50,
        failure_attempt_history: %w[attempt-old]
      )

      receipt = coordinator.request(
        row: row, requestor: "healer", request_id: "changed", now: NOW
      )

      assert_equal "queued", receipt.status
      request = Q.fetch("changed", state_home: state_home)
      assert_equal 1, request.recovery.fetch("identical_failure_count")
      refute_equal "f" * 64, request.recovery.fetch("failure_fingerprint")
    end
  end

  # The cooldown paces Hive's own retry sweep. First failure waits the first
  # backoff step, not the provider-sized hour.
  def test_request_before_cooldown_returns_cooldown_without_writing
    with_fixture(mtime: NOW - 1) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "healer", request_id: "too-early", now: NOW
      )

      assert_equal "cooldown", receipt.status
      assert_equal (NOW + 4).iso8601(6), receipt.next_eligible_at
      assert_empty Q.pending(state_home: state_home)
    end
  end

  # A person asking for a retry is not the automatic sweep. Leaving a task
  # idle for a cooldown with an operator standing over it is the behaviour
  # this bypass exists to remove; the safety checks below it still apply.
  def test_an_operator_retry_is_not_held_by_the_cooldown
    %w[action cli bot web].each do |requestor|
      with_fixture(mtime: NOW - 1) do |coordinator, row, state_home|
        receipt = coordinator.request(
          row: row, requestor: requestor, request_id: "manual-#{requestor}", now: NOW
        )

        refute_equal "cooldown", receipt.status,
                     "#{requestor} must not be held by the automatic cooldown"
        refute_empty Q.pending(state_home: state_home), requestor
        persisted = Q.pending(state_home: state_home).fetch(0)
        assert_equal NOW.iso8601(6), persisted.recovery.fetch("next_eligible_at"),
                     "#{requestor} retry must be immediately due after persistence"
        assert_equal "queued", coordinator.receipt_for_request(persisted, now: NOW).status,
                     "#{requestor} retry must remain due when the daemon reloads it"
      end
    end
  end

  def test_an_operator_retry_makes_an_existing_admitted_recovery_due
    with_fixture(mtime: NOW - 6) do |coordinator, row, state_home|
      admitted = coordinator.request(
        row: row, requestor: "healer", request_id: "automatic", now: NOW
      )
      Q.update_recovery!(
        admitted.request_id, expected_phase: "admitted",
        changes: { "next_eligible_at" => (NOW + 60).iso8601(6) },
        state_home: state_home
      )

      retried = coordinator.request(
        row: row, requestor: "action", request_id: "manual", now: NOW
      )

      assert_equal admitted.request_id, retried.request_id
      assert_equal "queued", retried.status
      persisted = Q.fetch(admitted.request_id, state_home: state_home)
      assert_equal NOW.iso8601(6), persisted.recovery.fetch("next_eligible_at")
    end
  end

  # The ladder starts short and only reaches the provider-sized window after
  # repeated failure; it never exceeds it.
  def test_backoff_climbs_and_is_capped_at_the_provider_window
    with_fixture do |coordinator, _row, _state_home|
      steps = (0..6).map { |count| coordinator.retry_delay_sec(count) }

      assert_equal [ 5, 10, 60, 300, 900 ], steps.first(5)
      ceiling = Hive::AgentLimit.retry_cooldown_sec
      assert_equal [ ceiling, ceiling ], steps.last(2)
      assert steps.each_cons(2).all? { |a, b| b >= a }, "backoff must not decrease"
    end
  end

  def test_racing_callers_converge_on_one_caller_stable_request
    with_fixture do |coordinator, row, state_home|
      web = coordinator.request(
        row: row, requestor: "web", request_id: "web-action", now: NOW
      )
      bot = coordinator.request(
        row: row, requestor: "bot", request_id: "bot-action", now: NOW
      )
      healer = coordinator.request(
        row: row, requestor: "healer", request_id: "auto-action", now: NOW
      )

      assert_equal %w[queued queued queued], [ web.status, bot.status, healer.status ]
      assert_equal [ "web-action" ], [ web.request_id, bot.request_id, healer.request_id ].uniq
      assert_equal [ 1 ], [ web.retry_count, bot.retry_count, healer.retry_count ].uniq
      assert_equal 1, Q.pending(state_home: state_home).size
    end
  end

  def test_resume_clears_exact_marker_and_persists_post_clear_generation
    with_fixture do |coordinator, row, state_home|
      queued = coordinator.request(
        row: row, requestor: "web", request_id: "recover-1", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      observed_generation = request.recovery.fetch("observed_marker_generation")

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      assert Hive::Markers.current(row.state_file).none?
      updated = Q.pending(state_home: state_home).fetch(0)
      assert_equal "cleared", updated.recovery.fetch("phase")
      assert_equal updated.recovery.fetch("dispatch_generation"), updated.task_generation
      refute_equal observed_generation, updated.task_generation
      assert_equal queued.request_id, resumed.request_id
    end
  end

  def test_resume_reuses_the_scan_admission_context_for_every_generation_check
    observed_contexts = []
    resolver = lambda do |resolved_task, project:, intended_stage:, state_file_content:,
                          admission_context: nil|
      observed_contexts << admission_context
      progress = Digest::SHA256.hexdigest(
        [ resolved_task.state_file, state_file_content ].join("\0")
      )
      FakeGeneration.new(
        progress_token: progress,
        task_generation: Digest::SHA256.hexdigest(
          [ project, intended_stage, progress ].join("\0")
        )
      )
    end

    with_fixture(generation_resolver: resolver) do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "web", request_id: "recover-context", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      observed_contexts.clear
      admission_context = Object.new

      resumed = coordinator.resume(
        request: request, row: row, admission_context: admission_context
      )

      assert_equal "cleared", resumed.phase
      refute_empty observed_contexts
      assert observed_contexts.all? { |context| context.equal?(admission_context) }
    end
  end

  def test_resume_matches_unicode_marker_attrs_after_json_round_trip
    attrs = {
      "reason" => "implementer_failed",
      "message" => "Claude stopped — retry the review",
      "marker_id" => "marker-unicode"
    }
    with_fixture(marker_attrs: attrs) do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-unicode", now: NOW
      )
      request = Q.fetch("recover-unicode", state_home: state_home)
      current = Hive::Markers.current(row.state_file)

      assert_equal Encoding::UTF_8,
                   request.recovery.dig("expected_marker_attrs", "message").encoding
      assert_equal Encoding::BINARY, current.attrs.fetch("message").encoding
      assert_equal attrs.fetch("message").bytes,
                   current.attrs.fetch("message").bytes

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      assert Hive::Markers.current(row.state_file).none?
    end
  end

  def test_request_rejects_invalid_utf8_marker_attrs_without_clearing_marker
    message = "agent stopped \xFF".b
    attrs = {
      "reason" => "implementer_failed",
      "message" => message,
      "marker_id" => "marker-invalid-utf8"
    }
    with_fixture(marker_attrs: attrs) do |coordinator, row, state_home|
      assert_raises JSON::GeneratorError do
        coordinator.request(
          row: row, requestor: "healer", request_id: "recover-invalid", now: NOW
        )
      end

      assert_nil Q.fetch("recover-invalid", state_home: state_home)
      assert_equal message.bytes,
                   Hive::Markers.current(row.state_file).attrs.fetch("message").bytes
    end
  end

  def test_restart_after_marker_clear_recovers_from_expected_post_clear_fingerprint
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-crash", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      Hive::Markers.clear_current(
        row.state_file,
        expected_name: :error,
        match_attrs: { "marker_id" => "marker-1", "reason" => "timeout" },
        purge_history: true
      )

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      assert_equal "cleared",
                   Q.pending(state_home: state_home).fetch(0).recovery.fetch("phase")
    end
  end

  def test_resume_rechecks_safety_under_lock_before_clearing
    inspections = 0
    safety = lambda do |_row|
      inspections += 1
      inspections <= 2 ? [ true, "safe at admission" ] :
        [ false, "worktree ownership changed after admission" ]
    end

    with_fixture(safety: safety) do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "web", request_id: "recover-resume-safety", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)

      resumed = coordinator.resume(request: request, row: row)

      assert_equal 3, inspections
      assert_equal "blocked", resumed.status
      assert_equal "safety_blocked", resumed.reason
      assert_equal "operator", resumed.owner
      assert_includes resumed.remediation, "worktree ownership changed"
      assert_equal "marker-1", Hive::Markers.current(row.state_file).attrs.fetch("marker_id")
      persisted = Q.fetch(request.request_id, state_home: state_home).recovery
      assert_equal "admitted", persisted.fetch("phase")
      assert_equal "operator", persisted.fetch("owner")
      assert_includes persisted.fetch("blocked_remediation"), "worktree ownership changed"
    end
  end

  def test_resume_revalidates_task_id_stage_and_canonical_folder
    mutations = {
      task_id: ->(task, _dir) { task.with(id: 818) },
      stage: ->(task, _dir) { task.with(stage_index: 5, stage_name: "open-pr") },
      folder: lambda do |task, dir|
        folder = File.join(dir, "moved-task")
        FileUtils.mkdir_p(folder)
        state_file = File.join(folder, "task.md")
        FileUtils.cp(task.state_file, state_file)
        task.with(folder: folder, state_file: state_file)
      end
    }

    mutations.each do |dimension, mutate|
      resolutions = 0
      builder = lambda do |task, dir|
        changed = mutate.call(task, dir)
        lambda do |**_kwargs|
          resolutions += 1
          resolutions <= 2 ? task : changed
        end
      end

      with_fixture(task_resolver_builder: builder) do |coordinator, row, state_home|
        coordinator.request(
          row: row, requestor: "bot",
          request_id: "recover-resume-#{dimension}", now: NOW
        )
        request = Q.pending(state_home: state_home).fetch(0)

        resumed = coordinator.resume(request: request, row: row)

        assert_equal "blocked", resumed.status, dimension
        assert_equal "task_identity_conflict", resumed.reason, dimension
        assert_equal "operator", resumed.owner, dimension
        assert_equal "admitted",
                     Q.fetch(request.request_id, state_home: state_home)
                       .recovery.fetch("phase"),
                     dimension
        assert_equal "marker-1",
                     Hive::Markers.current(row.state_file).attrs.fetch("marker_id"),
                     dimension
        blocked_revision = Q.fetch(request.request_id, state_home: state_home).revision

        replayed = coordinator.resume(request: request, row: row)

        assert_equal "blocked", replayed.status, dimension
        assert_equal blocked_revision,
                     Q.fetch(request.request_id, state_home: state_home).revision,
                     "an unchanged block must not rewrite the recovery row"
      end
    end
  end

  def test_post_clear_restart_rechecks_secret_reason_from_persisted_marker
    attrs = { "reason" => "secret_in_pr_body", "marker_id" => "marker-1" }
    with_fixture(
      marker_attrs: attrs,
      safety: Hive::Daemon::AutoRetrySafety.method(:safe_to_retry?)
    ) do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-secret", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      assert Hive::Markers.clear_current(
        row.state_file, expected_name: :error, match_attrs: attrs,
        purge_history: true
      )
      File.open(row.state_file, "a") do |file|
        file.write("\napi_key=abcdefghijklmnopqrstuvwxyz123456\n")
      end

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "blocked", resumed.status
      assert_equal "safety_blocked", resumed.reason
      assert_includes resumed.remediation, "credential pattern remains"
      assert_equal "admitted",
                   Q.fetch(request.request_id, state_home: state_home)
                     .recovery.fetch("phase")

      # A safety block is not inert: the sweep must re-inspect the task
      # instead of parking it, because an operator cleaning the credential
      # out of the state file should free the retry without a manual nudge.
      # Re-inspecting must still be write-idempotent while the reason holds.
      blocked_revision = Q.fetch(request.request_id, state_home: state_home).revision

      replayed = coordinator.resume(request: request, row: row)

      assert_equal "blocked", replayed.status
      assert_equal "safety_blocked", replayed.reason
      assert_equal "operator", replayed.owner
      assert_equal blocked_revision,
                   Q.fetch(request.request_id, state_home: state_home).revision,
                   "an unchanged safety block must not rewrite the recovery row"
    end
  end

  def test_post_clear_restart_rechecks_persisted_tamper_attributes
    attrs = {
      "reason" => "execute_tampered",
      "restored" => "false",
      "marker_id" => "marker-1"
    }
    with_fixture(marker_attrs: attrs) do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-tamper", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      assert Hive::Markers.clear_current(
        row.state_file, expected_name: :error, match_attrs: attrs,
        purge_history: true
      )
      coordinator.instance_variable_set(
        :@safety,
        Hive::Daemon::AutoRetrySafety.method(:safe_to_retry?)
      )

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "blocked", resumed.status
      assert_equal "safety_blocked", resumed.reason
      assert_includes resumed.remediation, "tampered run were not restored"
      assert_equal "admitted",
                   Q.fetch(request.request_id, state_home: state_home)
                     .recovery.fetch("phase")
    end
  end

  def test_restart_with_unexpected_markerless_progress_blocks_without_fake_phase
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-conflict", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      Hive::Markers.clear_current(
        row.state_file,
        expected_name: :error,
        match_attrs: { "marker_id" => "marker-1", "reason" => "timeout" },
        purge_history: true
      )
      File.write(row.state_file, "# operator changed this after clear\n")

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "blocked", resumed.status
      assert_equal "generation_conflict", resumed.reason
      recovery = Q.pending(state_home: state_home).fetch(0).recovery
      assert_equal "admitted", recovery.fetch("phase")
      assert_equal "generation_conflict", recovery.fetch("blocked_reason")
    end
  end

  def test_newer_marker_generation_is_never_cleared
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "web", request_id: "recover-stale", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      Hive::Markers.set(row.state_file, :error, reason: "timeout", marker_id: "marker-2")

      resumed = coordinator.resume(request: request, row: row)

      assert_equal "blocked", resumed.status
      assert_equal "generation_conflict", resumed.reason
      assert_equal "marker-2", Hive::Markers.current(row.state_file).attrs.fetch("marker_id")
    end
  end

  def test_admission_rejects_a_newer_recoverable_marker_generation
    with_fixture do |coordinator, row, state_home|
      Hive::Markers.set(
        row.state_file, :error, reason: "timeout", marker_id: "marker-2"
      )

      receipt = coordinator.request(
        row: row, requestor: "web",
        request_id: "recover-replaced-before-admission", now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "generation_conflict", receipt.reason
      assert_empty Q.pending(state_home: state_home)
    end
  end

  def test_request_reports_resolution_failures_as_recovery_unavailable
    builder = lambda do |_task, _dir|
      ->(**_kwargs) { raise Hive::Error, "resolver offline" }
    end
    with_fixture(task_resolver_builder: builder) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "web", request_id: "resolver-failure", now: NOW
      )

      assert_equal "unavailable", receipt.status
      assert_equal "recovery_unavailable", receipt.reason
      assert_includes receipt.remediation, "resolver offline"
      assert_empty Q.pending(state_home: state_home)
    end
  end

  def test_live_task_owner_returns_running_and_safety_failure_returns_blocked
    with_fixture do |coordinator, row, state_home|
      lock = Hive::Lock.acquire_task_lock(row.folder, "attempt_id" => "attempt-live")
      begin
        running = coordinator.request(
          row: row, requestor: "bot", request_id: "recover-live", now: NOW
        )
        assert_equal "running", running.status
        assert_equal "attempt-live", running.attempt_id
        assert_empty Q.pending(state_home: state_home)
      ensure
        Hive::Lock.release_task_lock(row.folder, lock_id: lock.fetch("lock_id"))
      end
    end

    with_fixture(safety: ->(_row) { [ false, "worktree ownership mismatch" ] }) do |coordinator, row, state_home|
      blocked = coordinator.request(
        row: row, requestor: "web", request_id: "recover-unsafe", now: NOW
      )
      assert_equal "blocked", blocked.status
      assert_equal "safety_blocked", blocked.reason
      assert_includes blocked.remediation, "worktree ownership mismatch"
      assert_empty Q.pending(state_home: state_home)
    end
  end

  def test_safety_is_rechecked_under_the_task_lock_before_admission
    inspections = 0
    safety = lambda do |_row|
      inspections += 1
      inspections == 1 ? [ true, "initially safe" ] : [ false, "worktree changed before lock" ]
    end

    with_fixture(safety: safety) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "web", request_id: "recover-safety-race", now: NOW
      )

      assert_equal 2, inspections
      assert_equal "blocked", receipt.status
      assert_equal "safety_blocked", receipt.reason
      assert_includes receipt.remediation, "worktree changed before lock"
      assert_empty Q.pending(state_home: state_home)
      assert_equal "marker-1", Hive::Markers.current(row.state_file).attrs.fetch("marker_id")
    end
  end

  def test_canonical_task_is_reresolved_under_lock_and_folder_swap_blocks
    resolutions = 0
    builder = lambda do |task, dir|
      swapped_folder = File.join(dir, "swapped-task")
      FileUtils.mkdir_p(swapped_folder)
      swapped_state = File.join(swapped_folder, "task.md")
      FileUtils.cp(task.state_file, swapped_state)
      swapped = task.with(folder: swapped_folder, state_file: swapped_state)
      lambda do |**_kwargs|
        resolutions += 1
        resolutions == 1 ? task : swapped
      end
    end

    with_fixture(task_resolver_builder: builder) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "bot", request_id: "recover-folder-swap", now: NOW
      )

      assert_equal 2, resolutions
      assert_equal "blocked", receipt.status
      assert_equal "task_identity_conflict", receipt.reason
      assert_empty Q.pending(state_home: state_home)
      assert_equal "marker-1", Hive::Markers.current(row.state_file).attrs.fetch("marker_id")
    end
  end

  def test_observation_token_is_rechecked_against_locked_state_file_mtime
    with_fixture do |coordinator, row, state_home|
      token = Hive::Daemon::RecoveryCoordinator.observation_token(row)
      changed_at = row.state_file_mtime + 1
      File.utime(changed_at, changed_at, row.state_file)

      receipt = coordinator.request(
        row: row,
        requestor: "action",
        request_id: "recover-stale-token",
        observation_token: token,
        now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "stale_observation", receipt.reason
      assert_empty Q.pending(state_home: state_home)
      assert_equal "marker-1", Hive::Markers.current(row.state_file).attrs.fetch("marker_id")
    end
  end

  def test_resolved_safety_block_is_cleared_before_dispatch
    inspections = 0
    safety = lambda do |_row|
      inspections += 1
      inspections == 3 ? [ false, "temporary ownership mismatch" ] : [ true, "safe" ]
    end

    with_fixture(safety: safety) do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-resolved-block", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      blocked = coordinator.resume(request: request, row: row, now: NOW)
      assert_equal "blocked", blocked.status

      resumed = coordinator.resume(request: request, row: row, now: NOW + 1)

      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      persisted = Q.fetch(request.request_id, state_home: state_home).recovery
      assert_nil persisted.fetch("blocked_reason")
      assert_nil persisted.fetch("blocked_remediation")
      assert_equal "scheduler", persisted.fetch("owner")
    end
  end

  def test_resume_reports_a_live_lock_owner_and_resolution_failure
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-resume-errors",
        now: NOW
      )
      request = Q.fetch("recover-resume-errors", state_home: state_home)
      error = Hive::ConcurrentRunError.new(
        "busy", holder: { "attempt_id" => "attempt-live" }
      )

      running = with_replaced_singleton_method(
        Hive::Lock, :with_task_lock,
        ->(*_args, &_block) { raise error }
      ) do
        coordinator.resume(request: request, row: row, now: NOW)
      end

      assert_equal "running", running.status
      assert_equal "attempt-live", running.attempt_id
      assert_equal "existing_live", running.reason

      coordinator.instance_variable_set(
        :@task_resolver,
        ->(**_kwargs) { raise Hive::Error, "task disappeared" }
      )
      unavailable = coordinator.resume(request: request, row: row, now: NOW)

      assert_equal "unavailable", unavailable.status
      assert_includes unavailable.reason, "task disappeared"
    end
  end

  def test_dispatched_replay_is_idempotent_and_invalid_source_fails_closed
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-dispatch",
        now: NOW
      )
      admitted = Q.fetch("recover-dispatch", state_home: state_home)

      invalid = coordinator.mark_dispatched(
        admitted, attempt_id: "attempt-too-early", now: NOW
      )
      assert_equal "unavailable", invalid.status
      assert_equal "transition_conflict", invalid.reason

      coordinator.resume(request: admitted, row: row, now: NOW)
      cleared = Q.fetch("recover-dispatch", state_home: state_home)
      first = coordinator.mark_dispatched(
        cleared, attempt_id: "attempt-1", now: NOW
      )
      replay = coordinator.mark_dispatched(
        cleared, attempt_id: "attempt-1", now: NOW + 1
      )

      assert_equal "running", first.status
      assert_equal "running", replay.status
      assert_equal "attempt-1", replay.attempt_id
    end
  end

  def test_failed_terminal_recovery_repairs_unchanged_markerless_task_for_retry
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-markerless-failure",
        now: NOW
      )
      admitted = Q.fetch("recover-markerless-failure", state_home: state_home)
      coordinator.resume(request: admitted, row: row, now: NOW)
      cleared = Q.fetch("recover-markerless-failure", state_home: state_home)
      coordinator.mark_dispatched(cleared, attempt_id: "attempt-failed", now: NOW)
      dispatched = Q.fetch("recover-markerless-failure", state_home: state_home)
      coordinator.mark_dispatched(
        dispatched, attempt_id: "attempt-failed", terminal: true,
        outcome: "failed", now: NOW + 1
      )
      terminal = Q.fetch("recover-markerless-failure", state_home: state_home)

      assert coordinator.repair_failed_terminal_marker(terminal)

      marker = Hive::Markers.current(row.state_file)
      assert_equal :error, marker.name
      assert_equal "recovery_attempt_failed", marker.attrs.fetch("reason")
      assert_equal "attempt-failed", marker.attrs.fetch("attempt_id")
      assert_equal "failed", marker.attrs.fetch("outcome")
      assert_equal "recover-markerless-failure",
                   marker.attrs.fetch("recovery_request_id")
      refute coordinator.repair_failed_terminal_marker(terminal),
             "a durable error marker must not be replaced on replay"
    end
  end

  # Marker repair runs on every daemon tick against on-disk state that may be
  # mid-write or gone. A raise here would abort the whole delivery
  # reconciliation loop, so the repair fails closed and leaves the request for
  # the next tick instead.
  def test_failed_terminal_repair_fails_closed_when_marker_state_is_unreadable
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-unreadable-marker",
        now: NOW
      )
      admitted = Q.fetch("recover-unreadable-marker", state_home: state_home)
      coordinator.resume(request: admitted, row: row, now: NOW)
      cleared = Q.fetch("recover-unreadable-marker", state_home: state_home)
      coordinator.mark_dispatched(cleared, attempt_id: "attempt-failed", now: NOW)
      dispatched = Q.fetch("recover-unreadable-marker", state_home: state_home)
      coordinator.mark_dispatched(
        dispatched, attempt_id: "attempt-failed", terminal: true,
        outcome: "failed", now: NOW + 1
      )
      terminal = Q.fetch("recover-unreadable-marker", state_home: state_home)

      repaired = with_replaced_singleton_method(
        Hive::Markers, :current,
        ->(_state_file) { raise Hive::Error, "marker read failed" }
      ) do
        coordinator.repair_failed_terminal_marker(terminal)
      end

      refute repaired, "an unreadable marker must not report a repair"
      assert_predicate Hive::Markers.current(row.state_file), :none?,
                       "failing closed must leave the task markerless for the next tick"

      assert coordinator.repair_failed_terminal_marker(terminal),
             "a later tick must still be able to repair the marker"
    end
  end

  def test_receipt_helper_fails_closed_for_unknown_requests
    request = Q::Request.new(
      request_id: "unknown-phase",
      created_at: NOW, project: "hive", slug: "demo-task",
      argv: %w[hive run demo-task], requestor: "daemon",
      recovery: {
        "phase" => "mystery",
        "failure_origin" => "timeout",
        "next_eligible_at" => NOW.iso8601(6),
        "owner" => "scheduler"
      }
    )
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      state_home: "/tmp/hive-recovery-receipts", dispatch_repository: Object.new
    )

    assert_equal "unavailable", coordinator.receipt_for_request(request).status
  end

  def test_defensive_recovery_helpers_keep_the_closed_contract
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      state_home: "/tmp/hive-recovery-helpers", dispatch_repository: Object.new
    )
    indexable = Class.new do
      def [](key)
        "value-for-#{key}"
      end
    end.new

    assert_equal(
      Hive::Daemon::RecoveryCoordinator.observation_token(
        "state_file_mtime" => "not-a-time"
      ),
      Hive::Daemon::RecoveryCoordinator.observation_token(
        "state_file_mtime" => "still-not-a-time"
      )
    )
    assert_equal "value-for-slug", coordinator.send(:value, indexable, :slug)
    assert_nil coordinator.send(:value, Object.new, :slug)
    assert_raises(ArgumentError) do
      coordinator.send(
        :clear_recoverable_marker, "/tmp/task.md",
        expected_name: "complete", match_attrs: {}
      )
    end
    assert coordinator.send(
      :recovery_due?, { "next_eligible_at" => "not-a-time" }, now: NOW
    )
    assert_equal(
      "transition_conflict",
      coordinator.send(
        :unavailable_request, request_for_helpers, "transition_conflict"
      ).reason
    )
    assert_includes(
      coordinator.send(:remediation_for, "transition_conflict"),
      "another recovery owner"
    )
    assert_includes(
      coordinator.send(:remediation_for, "unexpected"),
      "inspect the recovery request"
    )

    malformed_command = FakeRow.new(
      project: "hive", slug: "demo-task", folder: "/tmp/demo-task",
      state_file: "/tmp/demo-task/task.md", stage: "4-execute",
      workflow: "coding", marker: "error", marker_attrs: {},
      state_file_mtime: NOW, live_task_lock: false, attempt_id: nil,
      task_generation: nil, suggested_command: "'unterminated"
    )
    error = assert_raises(Hive::Error) do
      coordinator.send(:retry_argv, malformed_command)
    end
    assert_includes error.message, "invalid retry command"
  end

  def test_assessment_and_resolved_block_updates_fail_closed
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      state_home: "/tmp/hive-recovery-assessment",
      dispatch_repository: Object.new,
      safety: ->(_row) { raise IOError, "inspection failed" }
    )
    assessment = coordinator.assessment(
      { "state_file_mtime" => NOW - 3600 }, now: NOW
    )
    assert_equal false, assessment.fetch(:due)
    assert_equal false, assessment.fetch(:safe)
    assert_includes assessment.fetch(:safety_reason), "inspection failed"

    request = request_for_helpers(
      recovery: {
        "phase" => "cleared",
        "failure_origin" => "timeout",
        "next_eligible_at" => NOW.iso8601(6),
        "owner" => "operator",
        "blocked_reason" => "safety_blocked",
        "blocked_remediation" => "worktree dirty"
      }
    )
    refreshed = request.with(recovery: request.recovery.merge(
      "owner" => "scheduler",
      "blocked_reason" => nil,
      "blocked_remediation" => nil
    ))
    queue = Object.new
    queue.define_singleton_method(:update_recovery!) { |*_args, **_kwargs| true }
    queue.define_singleton_method(:fetch) { |*_args, **_kwargs| refreshed }
    successful = Hive::Daemon::RecoveryCoordinator.new(
      state_home: "/tmp/hive-recovery-block", dispatch_repository: queue
    )

    assert_same(
      refreshed,
      successful.send(:clear_resolved_block, request)
    )

    queue.define_singleton_method(:update_recovery!) { |*_args, **_kwargs| false }
    queue.define_singleton_method(:fetch) { |*_args, **_kwargs| nil }
    assert_same(
      request,
      successful.send(:clear_resolved_block, request)
    )
  end

  def test_resume_replays_inert_blocks_without_reopening_the_task
    task_resolutions = 0
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      task_resolver: lambda do |**|
        task_resolutions += 1
        raise "inert recovery must not resolve its task"
      end,
      attempt_store: Object.new, dispatch_repository: Object.new
    )

    Hive::Daemon::RecoveryCoordinator::INERT_BLOCK_REASONS.each do |reason|
      request = request_for_helpers(
        recovery: {
          "phase" => "cleared",
          "failure_origin" => "timeout",
          "next_eligible_at" => (NOW - 60).iso8601(6),
          "owner" => "operator",
          "blocked_reason" => reason,
          "blocked_remediation" => "refresh status"
        }
      )

      receipt = coordinator.resume(request: request, row: Object.new, now: NOW)

      assert_equal "blocked", receipt.status
      assert_equal reason, receipt.reason
    end
    assert_equal 0, task_resolutions
  end

  def test_resume_replays_cooldown_without_reopening_the_task
    task_resolutions = 0
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      task_resolver: lambda do |**|
        task_resolutions += 1
        raise "cooldown recovery must not resolve its task"
      end,
      attempt_store: Object.new, dispatch_repository: Object.new
    )
    request = request_for_helpers(
      recovery: {
        "phase" => "cleared",
        "failure_origin" => "timeout",
        "next_eligible_at" => (NOW + 60).iso8601(6),
        "owner" => "scheduler",
        "blocked_reason" => nil,
        "blocked_remediation" => nil
      }
    )

    receipt = coordinator.resume(request: request, row: Object.new, now: NOW)

    assert_equal "cooldown", receipt.status
    assert_equal 0, task_resolutions
  end

  def test_post_clear_dispatch_failure_uses_the_shared_retry_ladder
    with_fixture do |coordinator, row, state_home|
      coordinator.request(
        row: row, requestor: "healer", request_id: "recover-spawn-failure", now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      coordinator.resume(request: request, row: row, now: NOW)
      cleared = Q.fetch(request.request_id, state_home: state_home)

      step = coordinator.retry_delay_sec(cleared.recovery["retry_count"].to_i)
      deferred = coordinator.defer_dispatch_failure(cleared, now: NOW + 5)
      early = coordinator.resume(request: cleared, row: row, now: NOW + 6)
      due = coordinator.resume(request: cleared, row: row, now: NOW + 5 + step + 1)

      assert_equal "cooldown", deferred.status
      assert_equal (NOW + 5 + step).iso8601(6), deferred.next_eligible_at
      assert_equal "cooldown", early.status
      assert_equal "queued", due.status
      assert_equal "cleared", due.phase
    end
  end

  def test_idless_task_is_not_persisted_as_an_unrecoverable_request
    with_fixture(task_id: nil) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "healer", request_id: "recover-idless", now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "missing_task_id", receipt.reason
      assert_equal "hive", receipt.owner
      assert_includes receipt.remediation, "hive migrate"
      assert_empty Q.pending(state_home: state_home)
      assert_equal :error, Hive::Markers.current(row.state_file).name
    end
  end

  def test_idless_recovery_marker_requires_one_off_migration
    attrs = { "reason" => "timeout" }
    with_fixture(marker_attrs: attrs) do |coordinator, row, state_home|
      receipt = coordinator.request(
        row: row, requestor: "healer", request_id: "old-marker", now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "recovery_migration_required", receipt.reason
      assert_equal "operator", receipt.owner
      assert_includes receipt.remediation, "hive migrate"
      assert_empty Q.pending(state_home: state_home)
    end
  end

  def test_markerless_admission_failure_is_one_idempotent_retry_charge
    with_fixture(marker_name: "WAITING", marker_attrs: {}) do |coordinator, row, state_home|
      decision = routing_decision(row, status: :no_route)
      request = admission_request(row)

      first = coordinator.request_admission_failure(
        request: request, decision: decision, now: NOW
      )
      replay = coordinator.request_admission_failure(
        request: request, decision: decision, now: NOW + 1
      )

      assert_equal "cooldown", first.status, first.to_h.inspect
      assert_equal first.request_id, replay.request_id
      assert_equal 1, first.retry_count
      assert_equal 1, replay.retry_count
      assert_equal 1, Q.pending(state_home: state_home).size
      persisted = Q.pending(state_home: state_home).fetch(0)
      assert_equal "admission_failure", persisted.recovery.fetch("variant")
      assert_nil persisted.expected_marker_name
      assert_empty persisted.recovery.fetch("expected_marker_attrs")
      assert_equal decision.policy_digest, persisted.recovery.fetch("policy_digest")
      assert_equal decision.to_h, persisted.recovery.fetch("admission_observation")
      assert_equal "waiting", Hive::Markers.current(row.state_file).name.to_s

      resumed = coordinator.resume(
        request: persisted, row: row, now: NOW + Hive::AgentLimit.retry_cooldown_sec
      )
      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      assert_equal "waiting", Hive::Markers.current(row.state_file).name.to_s
    end
  end

  def test_markerless_controller_failure_is_idempotent_and_never_mutates_state
    with_markerless_fixture do |coordinator, row, dir, original|
      first = coordinator.request_markerless_failure(
        row: row, requestor: "healer",
        reason: "agent_exited_without_terminal_marker", now: NOW
      )
      replay = coordinator.request_markerless_failure(
        row: row, requestor: "healer",
        reason: "agent_exited_without_terminal_marker", now: NOW + 1
      )

      assert_equal "cooldown", first.status, first.to_h.inspect
      assert_equal first.request_id, replay.request_id
      assert_equal 1, first.retry_count
      assert_equal 1, Q.pending(state_home: dir).size
      request = Q.fetch(first.request_id, state_home: dir)
      assert_equal "markerless_failure", request.recovery.fetch("variant")
      assert_nil request.expected_marker_name
      assert_empty request.recovery.fetch("expected_marker_attrs")
      assert_nil request.recovery.fetch("policy_digest")
      assert_equal original, File.binread(row.state_file)

      resumed = coordinator.resume(
        request: request, row: row, now: Time.iso8601(first.next_eligible_at)
      )
      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      assert_equal original, File.binread(row.state_file)
    end
  end

  def test_terminal_markerless_controller_failure_rearms_same_request
    with_markerless_fixture do |coordinator, row, dir, original|
      admitted = coordinator.request_markerless_failure(
        row: row, requestor: "healer",
        reason: "agent_exited_without_terminal_marker", now: NOW
      )
      request = Q.fetch(admitted.request_id, state_home: dir)
      coordinator.resume(
        request: request, row: row, now: Time.iso8601(admitted.next_eligible_at)
      )
      request = Q.fetch(admitted.request_id, state_home: dir)
      Q.claim(
        admitted.request_id, pid: Process.pid, attempt_id: "attempt-2",
        task_generation: request.task_generation, state_home: dir, now: NOW + 6
      )
      coordinator.mark_dispatched(request, attempt_id: "attempt-2", now: NOW + 6)
      request = Q.fetch(admitted.request_id, state_home: dir)
      coordinator.mark_dispatched(
        request, attempt_id: "attempt-2", terminal: true,
        outcome: "failed", now: NOW + 7
      )
      request = Q.fetch(admitted.request_id, state_home: dir)
      refute coordinator.repair_failed_terminal_marker(request)
      assert_equal original, File.binread(row.state_file)

      rearmed = coordinator.request_markerless_failure(
        row: row.with(attempt_id: "attempt-2"), requestor: "healer",
        reason: "agent_exited_without_terminal_marker", now: NOW + 8
      )

      assert_equal admitted.request_id, rearmed.request_id
      assert_equal "cooldown", rearmed.status
      assert_equal "admitted", rearmed.phase
      assert_equal 2, rearmed.retry_count
      assert_empty Q.claimed(state_home: dir)
      assert_equal [ admitted.request_id ], Q.pending(state_home: dir).map(&:request_id)
      persisted = Q.fetch(admitted.request_id, state_home: dir)
      assert_nil persisted.recovery.fetch("attempt_id")
      assert_nil persisted.recovery.fetch("terminal_outcome")
      assert_equal original, File.binread(row.state_file)
    end
  end

  def test_markerless_controller_failure_obeys_recovery_safety_without_writing
    safety = ->(_observation) { [ false, "repair controller worktree" ] }
    with_markerless_fixture(safety: safety) do |coordinator, row, dir, original|
      receipt = coordinator.request_markerless_failure(
        row: row, requestor: "healer",
        reason: "agent_exited_without_terminal_marker", now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "safety_blocked", receipt.reason
      assert_equal "repair controller worktree", receipt.remediation
      assert_empty Q.pending(state_home: dir)
      assert_equal original, File.binread(row.state_file)
    end
  end

  def test_markerless_controller_admission_rechecks_identity_marker_and_task_id
    changing_resolver = lambda do |task|
      calls = 0
      lambda do |**_kwargs|
        calls += 1
        calls == 1 ? task : task.with(id: 818)
      end
    end
    with_markerless_fixture(task_resolver_builder: changing_resolver) do |coordinator, row, dir|
      receipt = coordinator.request_markerless_failure(
        row: row, requestor: "healer",
        reason: "agent_exited_without_terminal_marker", now: NOW
      )
      assert_equal "task_identity_conflict", receipt.reason
      assert_empty Q.pending(state_home: dir)
    end

    with_markerless_fixture do |coordinator, row, dir|
      Hive::Markers.set(row.state_file, :waiting, reason: "operator_input")
      receipt = coordinator.request_markerless_failure(
        row: row, requestor: "healer",
        reason: "agent_exited_without_terminal_marker", now: NOW
      )
      assert_equal "generation_conflict", receipt.reason
      assert_empty Q.pending(state_home: dir)
    end

    with_markerless_fixture(task_id: nil) do |coordinator, row, dir|
      receipt = coordinator.request_markerless_failure(
        row: row, requestor: "healer",
        reason: "agent_exited_without_terminal_marker", now: NOW
      )
      assert_equal "missing_task_id", receipt.reason
      assert_includes receipt.remediation, "hive migrate"
      assert_empty Q.pending(state_home: dir)
    end
  end

  def test_markerless_controller_admission_failures_return_bounded_receipts
    with_markerless_fixture do |coordinator, row|
      repository = coordinator.instance_variable_get(:@request_queue)
      with_replaced_singleton_method(repository, :fetch, ->(*, **) { nil }) do
        receipt = coordinator.request_markerless_failure(
          row: row, requestor: "healer",
          reason: "agent_exited_without_terminal_marker", now: NOW
        )
        assert_equal "unavailable", receipt.status
        assert_equal "request_disappeared_after_admission", receipt.reason
      end
    end

    with_markerless_fixture do |coordinator, row|
      lock_error = Hive::ConcurrentRunError.new(
        "busy", holder: { "attempt_id" => "attempt-live" }
      )
      with_replaced_singleton_method(
        Hive::Lock, :with_task_lock, ->(*, **) { raise lock_error }
      ) do
        receipt = coordinator.request_markerless_failure(
          row: row, requestor: "healer",
          reason: "agent_exited_without_terminal_marker", now: NOW
        )
        assert_equal "running", receipt.status
        assert_equal "attempt-live", receipt.attempt_id
      end
    end

    [
      "hive markers clear demo-task --project hive --json",
      "hive run 'unterminated"
    ].each do |command|
      with_markerless_fixture(suggested_command: command) do |coordinator, row|
        receipt = coordinator.request_markerless_failure(
          row: row, requestor: "healer",
          reason: "agent_exited_without_terminal_marker", now: NOW
        )
        assert_equal "unavailable", receipt.status
        assert_equal "recovery_unavailable", receipt.reason
      end
    end
  end

  def test_repeated_markerless_controller_failures_park_deterministically
    with_markerless_fixture do |coordinator, row, dir|
      attrs = {
        "reason" => "agent_exited_without_terminal_marker",
        "attempt_id" => row.attempt_id
      }
      fingerprint = coordinator.send(:failure_fingerprint, row, attrs)
      write_terminal_recovery_history(
        row: row, state_home: dir,
        retry_count: Hive::Daemon::RecoveryCoordinator::RETRY_BACKOFF_SEC.length,
        failure_fingerprint: fingerprint, identical_failure_count: 2,
        failure_attempt_history: %w[attempt-old-1 attempt-old-2]
      )

      receipt = coordinator.request_markerless_failure(
        row: row, requestor: "healer",
        reason: attrs.fetch("reason"), now: NOW
      )

      assert_equal "blocked", receipt.status
      assert_equal "deterministic_failure", receipt.reason
      assert_includes receipt.remediation, "change the failing input"
    end

    with_markerless_fixture do |coordinator, row, dir|
      admitted = coordinator.request_markerless_failure(
        row: row, requestor: "healer",
        reason: "agent_exited_without_terminal_marker", now: NOW
      )
      request = Q.fetch(admitted.request_id, state_home: dir)
      Q.update_recovery!(
        request.request_id, expected_phase: "admitted",
        changes: {
          "phase" => "terminal",
          "next_eligible_at" => nil,
          "owner" => "none",
          "retry_count" => Hive::Daemon::RecoveryCoordinator::RETRY_BACKOFF_SEC.length,
          "identical_failure_count" => 2,
          "terminal_outcome" => "failed",
          "terminal_at" => NOW.iso8601(6)
        },
        state_home: dir
      )

      rearmed = coordinator.request_markerless_failure(
        row: row.with(attempt_id: "attempt-2"), requestor: "healer",
        reason: "agent_exited_without_terminal_marker", now: NOW + 1
      )

      assert_equal "blocked", rearmed.status
      assert_equal "deterministic_failure", rearmed.reason
      assert_includes rearmed.remediation, "change the failing input"
    end
  end

  def test_markerless_admission_persists_both_blockers_for_each_health_scope
    with_fixture(marker_name: "WAITING", marker_attrs: {}) do |coordinator, row, state_home|
      route = routing_route
      exclusions = [
        Hive::ProviderHealth::Scope.provider_account(account_id: route.account),
        Hive::ProviderHealth::Scope.model(account_id: route.account, model_id: route.model)
      ].flat_map do |scope|
        %w[circuit_open circuit_cooldown].map do |reason|
          Hive::ProviderRouting::Decision::Exclusion.new(
            route_id: route.id,
            reason: reason,
            scope: scope.to_h,
            observation: { "generation" => 2, "journal_epoch" => 0 }
          )
        end
      end
      candidate = Hive::ProviderRouting::Candidate.new(
        route: route,
        exclusions: exclusions,
        observed_concurrency: 0,
        max_concurrency: 1
      )
      request = Hive::ProviderRouting::Request.new(
        policy: routing_policy,
        task_generation: fixture_task_generation(row),
        health: {},
        capacity: {}
      )
      decision = Hive::ProviderRouting::Decision.no_route(
        request: request,
        considered: [ route ],
        exclusions: exclusions,
        candidates: [ candidate ],
        decided_at: NOW,
        reason: "no_eligible_provider_route"
      )

      receipt = coordinator.request_admission_failure(
        request: admission_request(row), decision: decision, now: NOW
      )
      persisted = Q.pending(state_home: state_home).fetch(0)

      assert_equal "cooldown", receipt.status
      assert_equal 4,
                   persisted.recovery.dig("admission_observation", "candidates", 0, "exclusions").length
      assert_equal 4,
                   persisted.recovery.dig("admission_observation", "exclusions").length
    end
  end

  def test_provider_and_marker_recovery_charge_once_with_the_same_due_time
    provider = nil
    with_fixture(marker_name: "WAITING", marker_attrs: {}) do |coordinator, row, state_home|
      coordinator.request_admission_failure(
        request: admission_request(row),
        decision: routing_decision(row, status: :no_route),
        now: NOW
      )
      request = Q.pending(state_home: state_home).fetch(0)
      provider = {
        count: Q.pending(state_home: state_home).size,
        retry_count: request.recovery.fetch("retry_count"),
        due_at: request.recovery.fetch("next_eligible_at")
      }
    end

    marker = nil
    with_fixture(mtime: NOW) do |coordinator, row, state_home|
      coordinator.request(
        row: row,
        requestor: "healer",
        request_id: "equivalent-marker-recovery",
        now: NOW + Hive::AgentLimit.retry_cooldown_sec
      )
      request = Q.pending(state_home: state_home).fetch(0)
      marker = {
        count: Q.pending(state_home: state_home).size,
        retry_count: request.recovery.fetch("retry_count"),
        due_at: request.recovery.fetch("next_eligible_at")
      }
    end

    assert_equal({ count: 1, retry_count: 1 }, provider.except(:due_at))
    assert_equal({ count: 1, retry_count: 1 }, marker.except(:due_at))

    # One ladder means one due time: a provider refusal and a marker
    # failure at the same charge are paced identically.
    assert_equal provider, marker
  end

  def test_existing_recovery_records_no_route_without_a_second_charge
    with_fixture(marker_name: "WAITING", marker_attrs: {}) do |coordinator, row, state_home|
      request = admission_request(row)
      initial = routing_decision(row, status: :no_route)
      coordinator.request_admission_failure(request: request, decision: initial, now: NOW)
      persisted = Q.pending(state_home: state_home).fetch(0)
      coordinator.resume(
        request: persisted, row: row, now: NOW + Hive::AgentLimit.retry_cooldown_sec
      )
      cleared = Q.fetch(persisted.request_id, state_home: state_home)
      later = routing_decision(
        row, status: :no_route,
        task_generation: cleared.task_generation,
        decided_at: NOW + Hive::AgentLimit.retry_cooldown_sec
      )
      result = Hive::Attempts::DispatchResult.new(
        status: :no_route, attempt: nil, receipt: nil,
        attach_descriptor: nil, reason: later.reason, decision: later
      )

      observed = coordinator.observe_admission_result(
        request: cleared, result: result,
        now: NOW + Hive::AgentLimit.retry_cooldown_sec
      )
      updated = Q.fetch(cleared.request_id, state_home: state_home)

      assert_equal "cooldown", observed.status
      assert_equal "no_eligible_provider_route", observed.reason
      assert_equal 1, observed.retry_count
      assert_equal 1, Q.pending(state_home: state_home).size
      assert_equal "cleared", updated.recovery.fetch("phase")
      assert_equal later.to_h, updated.recovery.fetch("admission_observation")
    end
  end

  def test_capacity_observation_is_neutral_for_an_active_recovery
    with_fixture(marker_name: "WAITING", marker_attrs: {}) do |coordinator, row, state_home|
      request = admission_request(row)
      decision = routing_decision(row, status: :no_route)
      coordinator.request_admission_failure(request: request, decision: decision, now: NOW)
      persisted = Q.pending(state_home: state_home).fetch(0)
      before = persisted.recovery.fetch("next_eligible_at")
      capacity = routing_decision(row, status: :capacity_saturated)
      result = Hive::Attempts::DispatchResult.new(
        status: :deferred, attempt: nil, receipt: nil,
        attach_descriptor: nil, reason: capacity.reason, decision: capacity
      )

      coordinator.observe_admission_result(
        request: persisted, result: result, now: NOW + 10
      )
      updated = Q.fetch(persisted.request_id, state_home: state_home)

      assert_equal before, updated.recovery.fetch("next_eligible_at")
      assert_equal 1, updated.recovery.fetch("retry_count")
      assert_equal "capacity_saturated",
                   updated.recovery.dig("admission_observation", "reason")
      assert_equal capacity.to_h, updated.recovery.fetch("admission_observation")
      assert_nil updated.recovery.fetch("blocked_reason")
    end
  end

  def test_provider_failure_waits_for_exact_health_consumer_acknowledgement
    Dir.mktmpdir("hive-provider-recovery") do |dir|
      folder = File.join(dir, "task")
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "task.md")
      task = FakeTask.new(
        id: 817, slug: "demo-task", folder: folder, state_file: state_file,
        stage_index: 4, stage_name: "execute"
      )
      attempts = Hive::Attempts::Repository.new(root: File.join(dir, "attempts"), migrate: true)
      terminal = terminal_provider_attempt(attempts)
      maintenance = Hive::Attempts::FinalizationMaintenance.new(store: attempts)
      assert maintenance.prepare(terminal)
      attrs = {
        "reason" => "provider_route_failed", "marker_id" => "provider-marker",
        "attempt_id" => terminal.attempt_id,
        "task_generation" => terminal.task_generation,
        "ownership_generation" => terminal.ownership_generation,
        "task_input_epoch" => terminal.task_input_epoch,
        "provider_account_id" => "account-a",
        "route_id" => "account-a/model-a"
      }
      File.write(state_file, "# Task\n\n#{Hive::Markers.build_marker("ERROR", attrs)}\n")
      File.utime(NOW - 3600, NOW - 3600, state_file)
      row = fixture_row(
        task, marker: "error", attrs: Hive::Markers.current(state_file).attrs,
        mtime: NOW - 3600
      )
      coordinator = fixture_coordinator(
        dir: dir, task: task, attempt_store: attempts
      )

      queued = coordinator.request(
        row: row, requestor: "healer", request_id: "ignored-provider-id", now: NOW
      )
      request = Q.fetch(queued.request_id, state_home: dir)
      refute_nil request, queued.inspect
      blocked = coordinator.resume(request: request, row: row, now: NOW)

      assert_equal "queued", blocked.status
      assert_equal "provider_health_pending", blocked.reason
      assert_equal "error", Hive::Markers.current(state_file).name.to_s
      assert_equal terminal.attempt_id,
                   request.recovery.dig("source_receipt", "attempt_id")

      attempts.acknowledge_publication(terminal.attempt_id, consumer: "provider_health")
      resumed = coordinator.resume(request: request, row: row, now: NOW + 1)

      assert_equal "queued", resumed.status
      assert_equal "cleared", resumed.phase
      assert Hive::Markers.current(state_file).none?
    end
  end

  def test_default_attempt_store_factory_is_host_state_scoped
    with_tmp_dir do |state_home|
      opened = Object.new
      expected_state_home = state_home
      test_case = self
      with_replaced_singleton_method(
        Hive::Attempts::Repository, :open_default,
        lambda { |state_home:|
          test_case.assert_equal expected_state_home, state_home
          opened
        }
      ) do
        coordinator = Hive::Daemon::RecoveryCoordinator.new(
          state_home: state_home, dispatch_repository: Object.new
        )
        assert_same opened, coordinator.send(:attempts_store)
      end
    end
  end

  def test_provider_marker_without_an_immutable_receipt_stays_blocked
    with_fixture(marker_attrs: {
      "reason" => "provider_route_failed", "marker_id" => "provider-marker"
    }) do |coordinator, row, _state_home|
      result = coordinator.request(
        row: row, requestor: "healer", request_id: "missing-provider-receipt", now: NOW
      )

      assert_equal "blocked", result.status
      assert_equal "provider_receipt_unavailable", result.reason
    end
  end

  def test_markerless_admission_rechecks_task_marker_id_and_generation_under_lock
    changing_resolver = lambda do |task, _dir|
      calls = 0
      lambda do |**_kwargs|
        calls += 1
        calls == 1 ? task : task.with(id: 818)
      end
    end
    with_fixture(
      marker_name: "WAITING", marker_attrs: {},
      task_resolver_builder: changing_resolver
    ) do |coordinator, row, _state_home|
      result = coordinator.request_admission_failure(
        request: admission_request(row),
        decision: routing_decision(row, status: :no_route), now: NOW
      )
      assert_equal "task_identity_conflict", result.reason
    end

    with_fixture do |coordinator, row, _state_home|
      result = coordinator.request_admission_failure(
        request: admission_request(row),
        decision: routing_decision(row, status: :no_route), now: NOW
      )
      assert_equal "generation_conflict", result.reason
    end

    with_fixture(marker_name: "WAITING", marker_attrs: {}, task_id: nil) do |coordinator, row, _state_home|
      request = admission_request(row).with(task_id: nil)
      result = coordinator.request_admission_failure(
        request: request, decision: routing_decision(row, status: :no_route), now: NOW
      )
      assert_equal "missing_task_id", result.reason
      assert_includes result.remediation, "hive migrate"
    end

    with_fixture(marker_name: "WAITING", marker_attrs: {}) do |coordinator, row, _state_home|
      result = coordinator.request_admission_failure(
        request: admission_request(row),
        decision: routing_decision(
          row, status: :no_route, task_generation: "stale-generation"
        ),
        now: NOW
      )
      assert_equal "generation_conflict", result.reason
    end
  end

  def test_unavailable_health_admission_is_operator_owned_and_explainable
    with_fixture(marker_name: "WAITING", marker_attrs: {}) do |coordinator, row, state_home|
      decision = routing_decision(
        row, status: :no_route, exclusion_reason: "health_state_unavailable"
      )
      result = coordinator.request_admission_failure(
        request: admission_request(row), decision: decision, now: NOW
      )
      persisted = Q.fetch(result.request_id, state_home: state_home)

      assert_equal "operator", persisted.recovery.fetch("owner")
      assert_equal "health_state_unavailable", persisted.recovery.fetch("blocked_reason")
      assert_includes persisted.recovery.fetch("blocked_remediation"), "repair"

      observation = Hive::Attempts::DispatchResult.new(
        status: :no_route, attempt: nil, receipt: nil,
        attach_descriptor: nil, reason: decision.reason, decision: decision
      )
      coordinator.observe_admission_result(
        request: persisted, result: observation, now: NOW + 1
      )
      updated = Q.fetch(result.request_id, state_home: state_home)
      assert_includes updated.recovery.fetch("blocked_remediation"), "repair"
    end
  end

  def test_admission_and_observation_storage_failures_return_bounded_receipts
    with_fixture(marker_name: "WAITING", marker_attrs: {}) do |coordinator, row, _state_home|
      decision = routing_decision(row, status: :no_route)
      repository = coordinator.instance_variable_get(:@request_queue)
      with_replaced_singleton_method(repository, :fetch, ->(*, **) { nil }) do
        result = coordinator.request_admission_failure(
          request: admission_request(row), decision: decision, now: NOW
        )
        assert_equal "unavailable", result.status
        assert_equal "request_disappeared_after_admission", result.reason
      end

      lock_error = Hive::ConcurrentRunError.new(
        "busy", holder: { "attempt_id" => "attempt-live" }
      )
      with_replaced_singleton_method(
        Hive::Lock, :with_task_lock, ->(*, **) { raise lock_error }
      ) do
        result = coordinator.request_admission_failure(
          request: admission_request(row), decision: decision, now: NOW
        )
        assert_equal "running", result.status
        assert_equal "attempt-live", result.attempt_id
      end

      invalid = routing_decision(row, status: :capacity_saturated)
      result = coordinator.request_admission_failure(
        request: admission_request(row), decision: invalid, now: NOW
      )
      assert_equal "unavailable", result.status
      assert_equal "recovery_unavailable", result.reason
    end

    queue = Object.new
    queue.define_singleton_method(:fetch) do |*, **|
      raise IOError, "queue unavailable"
    end
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      dispatch_repository: queue, attempt_store: Object.new
    )
    request = request_for_helpers
    decision = routing_decision(
      Struct.new(:project, :stage).new("hive", "4-execute"), status: :no_route,
      task_generation: "generation-1"
    )
    observation = Hive::Attempts::DispatchResult.new(
      status: :no_route, attempt: nil, receipt: nil,
      attach_descriptor: nil, reason: decision.reason, decision: decision
    )
    assert_equal "unavailable", coordinator.observe_admission_result(
      request: request, result: observation, now: NOW
    ).status
  end

  def test_terminal_admission_observation_replays_without_mutation
    request = request_for_helpers(
      recovery: {
        "phase" => "terminal", "failure_origin" => "no_eligible_provider_route",
        "next_eligible_at" => nil, "owner" => "none", "retry_count" => 1,
        "terminal_outcome" => "failed"
      }
    )
    queue = Object.new
    queue.define_singleton_method(:fetch) { |_id, **| request }
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      dispatch_repository: queue, attempt_store: Object.new
    )
    decision = routing_decision(
      Struct.new(:project, :stage).new("hive", "4-execute"), status: :no_route,
      task_generation: "generation-1"
    )
    observation = Hive::Attempts::DispatchResult.new(
      status: :no_route, attempt: nil, receipt: nil,
      attach_descriptor: nil, reason: decision.reason, decision: decision
    )

    assert_equal "terminal", coordinator.observe_admission_result(
      request: request, result: observation, now: NOW
    ).phase
  end

  def test_source_receipt_proof_fallback_and_storage_errors_are_fail_closed
    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: File.join(root, "attempts"), migrate: true)
      terminal = terminal_provider_attempt(store)
      maintenance = Hive::Attempts::FinalizationMaintenance.new(store: store)
      assert maintenance.prepare(terminal)
      store.publication(terminal.attempt_id).fetch("consumers").each_key do |consumer|
        store.acknowledge_publication(terminal.attempt_id, consumer: consumer)
      end
      assert maintenance.promote(terminal)
      identity = {
        "attempt_id" => terminal.attempt_id,
        "receipt_version" => terminal.receipt.fetch("receipt_version"),
        "terminal_lease_version" => terminal.receipt.fetch("terminal_lease_version")
      }
      assert_nil store.fetch_hot(terminal.attempt_id)
      coordinator = Hive::Daemon::RecoveryCoordinator.new(
        attempt_store: store, dispatch_repository: Object.new
      )
      assert coordinator.send(:source_health_acknowledged?, identity)

      failing = Object.new
      failing.define_singleton_method(:fetch_hot) do |_id|
        raise Hive::Attempts::RepositoryError, "unavailable"
      end
      coordinator = Hive::Daemon::RecoveryCoordinator.new(
        attempt_store: failing, dispatch_repository: Object.new
      )
      refute coordinator.send(:source_health_acknowledged?, identity)

      failing.define_singleton_method(:fetch) do |_id|
        raise Hive::Attempts::RepositoryError, "unavailable"
      end
      marker = Struct.new(:attrs).new({
        "reason" => "provider_route_failed", "attempt_id" => terminal.attempt_id
      })
      task = FakeTask.new(
        id: 817, slug: "demo-task", folder: root, state_file: File.join(root, "task.md"),
        stage_index: 4, stage_name: "execute"
      )
      assert_nil coordinator.send(
        :source_receipt_for, marker: marker, task: task, project: "hive"
      )
    end
  end

  def test_markerless_clear_validation_and_invalid_decisions_are_closed
    coordinator = Hive::Daemon::RecoveryCoordinator.new(
      attempt_store: Object.new, dispatch_repository: Object.new
    )
    marker = Struct.new(:name) do
      def none? = name == :none
    end.new(:waiting)
    recovery = { "variant" => "admission_failure" }
    assert coordinator.send(:cleared_marker_state_valid?, marker, recovery)
    marker.name = :error
    refute coordinator.send(:cleared_marker_state_valid?, marker, recovery)
    assert_raises(ArgumentError) do
      coordinator.send(:validate_admission_decision!, Object.new, expected_status: :no_route)
    end
  end

  private

  def request_for_helpers(recovery: nil)
    Q::Request.new(
      request_id: "helper-request",
      created_at: NOW,
      project: "hive",
      slug: "demo-task",
      argv: %w[hive run demo-task],
      requestor: "daemon",
      recovery: recovery || {
        "phase" => "cleared",
        "failure_origin" => "timeout",
        "next_eligible_at" => NOW.iso8601(6),
        "owner" => "scheduler"
      }
    )
  end

  def admission_request(row)
    Q::Request.new(
      request_id: "initial-route-admission", created_at: NOW,
      project: row.project, slug: row.slug,
      argv: %w[hive run demo-task --stage 4-execute --project hive --json],
      requestor: "daemon", chat_id: nil, update_id: nil,
      trigger: "auto_advance", task_generation: nil,
      predecessor_attempt_id: nil, inherited_outputs: [], task_id: 817,
      expected_stage: nil, expected_marker_name: nil, expected_marker_id: nil,
      recovery: nil, schema_version: Q::SCHEMA_VERSION
    )
  end

  def routing_decision(row, status:, task_generation: nil, decided_at: NOW,
                       exclusion_reason: nil)
    route = routing_route
    reason = exclusion_reason || (
      status == :capacity_saturated ? "provider_concurrency_saturated" : "manual_block"
    )
    observation = status == :capacity_saturated ?
      { "observed" => 1, "max" => 1 } : { "generation" => 2, "journal_epoch" => 0 }
    exclusion = Hive::ProviderRouting::Decision::Exclusion.new(
      route_id: route.id, reason: reason,
      scope: {
        "kind" => "provider_account", "provider_account_id" => route.account,
        "model" => nil
      },
      observation: observation
    )
    candidate = Hive::ProviderRouting::Candidate.new(
      route: route, exclusions: [ exclusion ],
      observed_concurrency: status == :capacity_saturated ? 1 : 0,
      max_concurrency: 1
    )
    generation = task_generation || fixture_task_generation(row)
    request = Hive::ProviderRouting::Request.new(
      policy: routing_policy, task_generation: generation,
      health: {}, capacity: {}
    )
    if status == :capacity_saturated
      Hive::ProviderRouting::Decision.capacity_saturated(
        request: request, considered: [ route ], exclusions: [ exclusion ],
        candidates: [ candidate ], decided_at: decided_at
      )
    else
      Hive::ProviderRouting::Decision.no_route(
        request: request, considered: [ route ], exclusions: [ exclusion ],
        candidates: [ candidate ], decided_at: decided_at,
        reason: exclusion_reason == "health_state_unavailable" ?
          "health_state_unavailable" : "no_eligible_provider_route"
      )
    end
  end

  def routing_policy
    @routing_policy ||= Hive::ProviderRouting::Policy.explicit(
      stage: "execute", routes: [ routing_route ],
      requirements: Hive::ProviderRouting::Requirements.empty, pin: nil,
      account_policy: {
        "account-a" => {
          "adapter" => "codex", "launch_binding" => "binding-a",
          "models" => [ "model-a" ], "max_concurrent" => 1,
          "cooldown_sec" => Hive::ProviderRouting::DEFAULT_COOLDOWN_SEC
        }
      }
    )
  end

  def routing_route
    @routing_route ||= Hive::ProviderRouting::Route.new(
      id: "account-a/model-a", account: "account-a", adapter: "codex",
      launch_binding: "binding-a", model: "model-a", effort: "high", order: 0,
      capabilities: {
        "context" => "large", "quality" => "high",
        "tools" => %w[shell], "permissions" => %w[read]
      }
    )
  end

  def fixture_task_generation(row)
    progress = Digest::SHA256.hexdigest(
      [ row.state_file, File.binread(row.state_file) ].join("\0")
    )
    Digest::SHA256.hexdigest([ row.project, row.stage, progress ].join("\0"))
  end

  def terminal_provider_attempt(store)
    capability = "c" * 64
    generation = "provider-generation"
    route = {
      "route_id" => "account-a/model-a", "provider_account_id" => "account-a",
      "adapter" => "codex", "launch_binding_id" => "binding-a",
      "model" => "model-a", "effort" => "high"
    }
    provider_scope = Hive::ProviderHealth::Scope.provider_account(account_id: "account-a")
    scope = Hive::ProviderHealth::Scope.model(
      account_id: "account-a", model_id: "model-a"
    )
    routing = {
      "mode" => "explicit", "policy_digest" => "a" * 64,
      "decision" => {
        "decision_id" => "provider-decision", "policy_digest" => "a" * 64,
        "decided_at" => NOW.iso8601(6), "exclusions" => []
      },
      "route" => route,
      "circuit_generations" => [
        { "scope" => provider_scope.to_h, "journal_epoch" => 0, "observed_generation" => 0 },
        { "scope" => scope.to_h, "journal_epoch" => 0, "observed_generation" => 0 }
      ],
      "probe_bindings" => []
    }
    launching = store.create_launching(
      attempt_id: "provider-attempt", request_id: "provider-request",
      predecessor_attempt_id: nil, task_id: "817", project: "hive",
      task_slug: "demo-task", intended_stage: "4-execute",
      task_generation: generation, ownership_generation: generation,
      task_input_epoch: 1, progress_token: "progress", provider: "codex",
      routing: routing, worker_argv: %w[hive run demo-task],
      claim_capability_digest: Hive::Attempts::Capability.digest(capability),
      starting_revision: nil, retry_charge: 0, inherited_outputs: [],
      launch_timeout_sec: 30, now: NOW - 30
    )
    claimed = store.claim(
      launching, owner: { "pid" => Process.pid }, claim_capability: capability,
      first_heartbeat_timeout_sec: 30, now: NOW - 29
    )
    running = store.first_heartbeat(claimed, stale_sec: 30, now: NOW - 28)
    writer = store.log_archive.open_writer(launching.attempt_id, clock: -> { NOW })
    writer.close
    reference = Hive::OutputReference.build(writer.path, root: store.root)
    identity = Hive::ProviderHealth::RouteIdentity.new(
      route_id: route.fetch("route_id"), account_id: route.fetch("provider_account_id"),
      adapter: route.fetch("adapter"), launch_binding_id: route.fetch("launch_binding_id"),
      model_id: route.fetch("model")
    )
    evidence = Hive::ProviderHealth::Evidence.new(
      scope: scope, failure_class: "model_capacity",
      provenance: "codex_jsonl_transport", route: identity,
      reset_hint_seconds: 30, source_reference: reference,
      attempt_id: launching.attempt_id
    )
    store.terminalize(
      running, outcome: "failed", exit_status: 70,
      final_checkpoint: running.checkpoint, output_references: [],
      log_reference: reference, provider_evidence: evidence.to_h,
      now: NOW - 27
    )
  end

  def fixture_row(task, marker:, attrs:, mtime:)
    FakeRow.new(
      project: "hive", slug: task.slug, folder: task.folder,
      state_file: task.state_file, stage: "4-execute", workflow: "coding",
      marker: marker, marker_attrs: attrs, state_file_mtime: mtime,
      live_task_lock: false, attempt_id: attrs["attempt_id"],
      task_generation: attrs["task_generation"],
      suggested_command: "hive run demo-task --stage 4-execute --project hive --json"
    )
  end

  def fixture_coordinator(dir:, task:, attempt_store: nil, safety: nil,
                          task_resolver: nil)
    Q.register_project(dir, "hive")
    Hive::Daemon::RecoveryCoordinator.new(
      state_home: dir, task_resolver: task_resolver || ->(**_kwargs) { task },
      safety: safety || ->(_row) { [ true, "safe" ] },
      attempt_store: attempt_store, dispatch_repository: Q.repository(dir),
      generation_resolver: lambda do |resolved_task, project:, intended_stage:, state_file_content:|
        progress = Digest::SHA256.hexdigest(
          [ resolved_task.state_file, state_file_content ].join("\0")
        )
        FakeGeneration.new(
          progress_token: progress,
          task_generation: Digest::SHA256.hexdigest(
            [ project, intended_stage, progress ].join("\0")
          )
        )
      end
    )
  end

  def with_markerless_fixture(task_id: 817, safety: nil,
                              suggested_command: "hive run demo-task --project hive --stage 2-fix --json",
                              task_resolver_builder: nil)
    Dir.mktmpdir("hive-markerless-recovery") do |dir|
      folder = File.join(dir, "task")
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "patrol-fix-manifest.json")
      File.write(state_file, "{\"schema\":\"controller-state\"}\n")
      original = File.binread(state_file)
      task = FakeTask.new(
        id: task_id, slug: "demo-task", folder: folder, state_file: state_file,
        stage_index: 2, stage_name: "fix"
      )
      row = FakeRow.new(
        project: "hive", slug: task.slug, folder: folder, state_file: state_file,
        stage: "2-fix", workflow: "patrol-fix", marker: "none",
        marker_attrs: {}, state_file_mtime: NOW - 60, live_task_lock: false,
        attempt_id: "attempt-1", task_generation: nil,
        suggested_command: suggested_command
      )
      task_resolver = task_resolver_builder&.call(task)
      coordinator = fixture_coordinator(
        dir: dir, task: task, safety: safety, task_resolver: task_resolver
      )
      yield coordinator, row, dir, original
    end
  end

  def write_terminal_recovery_history(row:, state_home:, retry_count:,
                                      failure_fingerprint: nil,
                                      identical_failure_count: nil,
                                      failure_attempt_history: nil)
    Q.write_request!(
      project: row.project,
      slug: row.slug,
      argv: [ "hive", "run", row.slug, "--stage", row.stage,
              "--project", row.project, "--json" ],
      requestor: "healer",
      trigger: "recovery",
      request_id: "previous-terminal",
      task_generation: "c" * 64,
      task_id: 817,
      expected_stage: row.stage,
      expected_marker_name: "error",
      expected_marker_id: "previous-marker",
      recovery: {
        "phase" => "terminal",
        "observed_marker_generation" => "d" * 64,
        "expected_marker_attrs" => {
          "marker_id" => "previous-marker", "reason" => "timeout"
        },
        "canonical_task_folder" => row.folder,
        "expected_post_clear_progress_fingerprint" => "e" * 64,
        "dispatch_generation" => "c" * 64,
        "failure_origin" => "timeout",
        "next_eligible_at" => NOW.iso8601(6),
        "owner" => "none",
        "blocked_reason" => nil,
        "blocked_remediation" => nil,
        "retry_count" => retry_count,
        "attempt_id" => "attempt-previous",
        "terminal_outcome" => "failed",
        "terminal_at" => (NOW - 60).iso8601(6)
      }.merge({
        "failure_fingerprint" => failure_fingerprint,
        "identical_failure_count" => identical_failure_count,
        "failure_attempt_history" => failure_attempt_history
      }.compact),
      state_home: state_home,
      now: NOW - 60
    )
  end

  def with_fixture(marker_attrs: nil, marker_name: "ERROR", mtime: NOW - 3600,
                   safety: nil, task_resolver_builder: nil, task_id: 817,
                   generation_resolver: nil)
    Dir.mktmpdir("hive-recovery-coordinator") do |dir|
      folder = File.join(dir, "task")
      FileUtils.mkdir_p(folder)
      state_file = File.join(folder, "task.md")
      attrs = marker_attrs || { "reason" => "timeout", "marker_id" => "marker-1" }
      File.write(state_file, "# Task\n\n#{Hive::Markers.build_marker(marker_name, attrs)}\n")
      File.utime(mtime, mtime, state_file)
      task = FakeTask.new(
        id: task_id, slug: "demo-task", folder: folder, state_file: state_file,
        stage_index: 4, stage_name: "execute"
      )
      row = FakeRow.new(
        project: "hive", slug: task.slug, folder: folder, state_file: state_file,
        stage: "4-execute", workflow: "coding", marker: marker_name.downcase,
        marker_attrs: attrs, state_file_mtime: mtime, live_task_lock: false,
        attempt_id: nil, task_generation: nil,
        suggested_command: "hive run demo-task --stage 4-execute --project hive --json"
      )
      task_resolver = if task_resolver_builder
        task_resolver_builder.call(task, dir)
      else
        ->(**_kwargs) { task }
      end
      Q.register_project(dir, "hive")
      coordinator = Hive::Daemon::RecoveryCoordinator.new(
        state_home: dir,
        dispatch_repository: Q.repository(dir),
        task_resolver: task_resolver,
        safety: safety || ->(_row) { [ true, "safe" ] },
        generation_resolver: generation_resolver || lambda do |resolved_task, project:, intended_stage:, state_file_content:|
          progress = Digest::SHA256.hexdigest(
            [ resolved_task.state_file, state_file_content ].join("\0")
          )
          FakeGeneration.new(
            progress_token: progress,
            task_generation: Digest::SHA256.hexdigest(
              [ project, intended_stage, progress ].join("\0")
            )
          )
        end
      )
      yield coordinator, row, dir
    end
  end

  def patrol_fix_decision_receipt(slug)
    {
      "schema" => "hive-patrol-fix-receipt", "schema_version" => 1,
      "receipt_id" => "decision-1", "kind" => "decision", "stage" => "inbox",
      "task" => { "slug" => slug, "generation" => 1 },
      "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
      "recorded_at" => "2026-08-20T12:00:00Z",
      "payload" => {
        "route" => "fix", "rationale" => "The finding requires a bounded fix.",
        "evidence" => [ "The focused reproduction still fails." ],
        "blocker_owner" => "inbox_gate", "head_revision" => "b" * 40
      }
    }
  end
end
