require "test_helper"
require "tmpdir"
require "time"
require "yaml"
require "hive/agent_limit"
require "hive/markers"
require "hive/daemon/recovery_coordinator"
require "hive/daemon/stale_agent_healer"
require "hive/daemon/status_consumer"
require "hive/patrol_fix/projection"

# StaleAgentHealer has two responsibilities:
# - turn stale working observations into durable ERROR / REVIEW_ERROR markers;
# - submit existing durable errors to the sole RecoveryCoordinator.
#
# It must not clear recoverable markers, construct retry commands, keep a
# second retry budget, or own a second request lifecycle.
class HiveDaemonStaleAgentHealerTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Daemon::StatusConsumer::Row
  NOW = Time.utc(2026, 5, 20, 12, 0, 0)

  class FakeController
    def initialize(running_pairs: [])
      @running_pairs = running_pairs
    end

    def running_task?(project:, slug:)
      @running_pairs.include?([ project, slug ])
    end
  end

  class FakeLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def event(name, **attributes)
      @events << [ name, attributes ]
    end
  end

  class FakeRecoveryCoordinator
    attr_reader :assessments, :requests, :markerless_requests, :retry_delay_counts
    attr_accessor :assessment_result, :request_status, :request_error

    def initialize
      @assessments = []
      @requests = []
      @markerless_requests = []
      @retry_delay_counts = []
      @assessment_result = {
        due: true,
        retry_at: NOW,
        safe: true,
        safety_reason: "safe"
      }
      @request_status = "queued"
      @request_error = nil
    end

    def assessment(row, now:)
      @assessments << { row: row, now: now }
      @assessment_result
    end

    def request(row:, requestor:, now:)
      raise request_error if request_error

      @requests << { row: row, requestor: requestor, now: now }
      Hive::Daemon::RecoveryCoordinator::Receipt.new(
        status: request_status,
        request_id: request_status == "queued" ? "coordinated-1" : nil,
        attempt_id: nil,
        phase: request_status == "queued" ? "admitted" : nil,
        failure_origin: row.marker_attrs["reason"],
        next_eligible_at: now.utc.iso8601(6),
        owner: request_status == "queued" ? "scheduler" : "operator",
        reason: request_status == "queued" ? nil : "safety_blocked",
        remediation: request_status == "queued" ? nil : "repair worktree",
        retry_count: 1,
        provider_hint: nil
      )
    end

    def retry_delay_sec(retry_count)
      @retry_delay_counts << retry_count
      120
    end

    def request_markerless_failure(row:, requestor:, reason:, now:)
      @markerless_requests << {
        row: row, requestor: requestor, reason: reason, now: now
      }
      Hive::Daemon::RecoveryCoordinator::Receipt.new(
        status: request_status,
        request_id: request_status == "queued" ? "markerless-1" : nil,
        attempt_id: nil,
        phase: request_status == "queued" ? "admitted" : nil,
        failure_origin: reason,
        next_eligible_at: now.utc.iso8601(6),
        owner: request_status == "queued" ? "scheduler" : "operator",
        reason: request_status == "queued" ? nil : "safety_blocked",
        remediation: request_status == "queued" ? nil : "repair worktree",
        retry_count: 1,
        provider_hint: nil
      )
    end
  end

  def setup
    @logger = FakeLogger.new
    @controller = FakeController.new
    @coordinator = FakeRecoveryCoordinator.new
    @healer = build_healer
    @task_lease_payloads = {}
    task_lease_payloads = @task_lease_payloads
    @healer.define_singleton_method(:task_lock_holder) do |row|
      task_lease_payloads[row.folder.to_s]
    end
    @healer.define_singleton_method(:with_heal_lock) do |row, create: true, **, &block|
      next false if !create && !File.directory?(row.folder.to_s)

      holder = task_lease_payloads[row.folder.to_s]
      if holder && holder["pid"] == Process.pid
        next false
      elsif holder
        task_lease_payloads.delete(row.folder.to_s)
      end
      block.call
    end
  end

  def test_recoverable_markers_delegate_to_one_coordinator_without_mutation
    [
      [ :error, "error", "4-execute", { "reason" => "implementer_failed" } ],
      [
        :review_error,
        "review_error",
        "6-review",
        { "phase" => "reviewers", "reason" => "all_failed", "pass" => "1" }
      ],
      [ :review_ci_stale, "review_ci_stale", "6-review", { "pass" => "1" } ]
    ].each do |marker_name, row_marker, stage, attrs|
      with_marker_file do |state_file|
        Hive::Markers.set(state_file, marker_name, attrs)
        row = make_row(
          state_file,
          pid_alive: nil,
          marker: row_marker,
          marker_attrs: Hive::Markers.current(state_file).attrs,
          stage: stage,
          live_task_lock: false
        )

        heal([ row ])

        assert_equal marker_name, Hive::Markers.current(state_file).name
      end
    end

    assert_equal 3, @coordinator.requests.size
    assert @coordinator.requests.all? { |request| request[:requestor] == "healer" }
    events = @logger.events.select { |name, _attributes| name == :recovery_requested }
    assert_equal 3, events.size
    assert events.all? { |_name, attributes| attributes[:request_id] == "coordinated-1" }
  end

  def test_outcome_evidence_implementation_rework_is_not_replayed_as_the_same_artifacts_run
    with_marker_file do |state_file|
      attrs = {
        "reason" => "outcome_evidence_implementation_rework",
        "generation" => "a" * 64,
        "recovery_digest" => "b" * 64
      }
      Hive::Markers.set(state_file, :error, attrs)
      row = make_row(
        state_file,
        pid_alive: nil,
        marker: "error",
        marker_attrs: Hive::Markers.current(state_file).attrs,
        stage: "7-artifacts",
        action: "outcome_evidence_rework",
        live_task_lock: false
      )

      heal([ row ])

      assert_empty @coordinator.requests
      assert_equal :error, Hive::Markers.current(state_file).name
    end
  end

  def test_resolved_review_stale_delegates_but_unresolved_review_stale_waits
    with_marker_file do |state_file|
      reviews = File.join(File.dirname(state_file), "reviews")
      FileUtils.mkdir_p(reviews)
      escalations = File.join(reviews, "escalations-02.md")
      fix_success = File.join(reviews, "fix-success-02.md")
      File.write(escalations, "# resolved\n")
      File.write(fix_success, "complete\n")
      File.utime(NOW - 20, NOW - 20, escalations)
      File.utime(NOW - 10, NOW - 10, fix_success)
      Hive::Markers.set(state_file, :review_stale, pass: 2)
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_stale",
        marker_attrs: Hive::Markers.current(state_file).attrs,
        action: "recover_review",
        live_task_lock: false
      )

      heal([ row ])
      assert_equal 1, @coordinator.requests.size

      File.utime(NOW, NOW, escalations)
      heal([ row ])
      assert_equal 1, @coordinator.requests.size
    end
  end

  def test_task_history_invalid_row_never_enters_error_recovery
    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        marker: "error",
        marker_attrs: { "reason" => Hive::TaskProjection::INVALID_HISTORY_REASON },
        live_task_lock: false,
        task_history_invalid: true
      )

      heal([ row ])

      assert_empty @coordinator.requests
      assert_empty @logger.events
      assert_equal :agent_working, Hive::Markers.current(state_file).name
    end
  end

  def test_legacy_dirty_execute_wait_is_not_runtime_healer_vocabulary
    with_marker_file do |state_file|
      attrs = {
        "reason" => "dirty_worktree",
        "attempt_id" => "attempt-pi-1",
        "task_generation" => "generation-1",
        "ownership_generation" => "generation-1"
      }
      Hive::Markers.set(state_file, :execute_waiting, attrs)
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "4-execute",
        workflow: "coding",
        marker: "execute_waiting",
        marker_attrs: attrs,
        action: "needs_input",
        live_task_lock: false
      )

      heal([ row ])

      assert_equal :execute_waiting, Hive::Markers.current(state_file).name
      assert_empty @coordinator.requests
      assert_empty @logger.events
    end
  end

  def test_controller_markerless_stall_queues_recovery_without_corrupting_manifest
    Dir.mktmpdir do |dir|
      state_file = File.join(dir, "patrol-fix-manifest.json")
      File.write(state_file, JSON.generate(
        "schema" => "hive-patrol-fix-task-manifest",
        "schema_version" => 1,
        "task" => { "slug" => "sample", "generation" => 1 },
        "evidence_revision" => { "generation" => 1, "digest" => "a" * 64 },
        "target_revision" => "1" * 40,
        "sources" => [ {
          "engine" => "architecture_patrol",
          "identity" => "run-1:finding-1",
          "target_revision" => "1" * 40,
          "evidence" => [ "controller recovery evidence" ],
          "affected_code" => [ "lib/demo.rb" ],
          "reproduction_guidance" => "run the focused test",
          "discovery_run" => "run-1",
          "semantic_lineage" => [ "lineage-1" ]
        } ],
        "aliases" => [],
        "relations" => { "successor" => nil, "issues" => [] }
      ) << "\n")
      original = File.binread(state_file)
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "2-fix",
        workflow: "patrol-fix",
        marker: "none",
        action: "ready_to_run",
        live_task_lock: false
      )

      assert @healer.heal_markerless_stall(row)
      assert_equal original, File.binread(state_file)
      projection = Hive::PatrolFix::Projection.new(
        task_folder: dir, stage: "2-fix"
      ).to_h
      assert_equal "current", projection.fetch("state"), projection.inspect
      assert_empty @coordinator.requests
      request = @coordinator.markerless_requests.fetch(0)
      assert_equal "healer", request.fetch(:requestor)
      assert_equal "agent_exited_without_terminal_marker", request.fetch(:reason)
      event = @logger.events.find { |name, _attributes| name == :recovery_requested }
      assert_equal "markerless-1", event.last.fetch(:request_id)
    end
  end

  def test_markerless_stall_enters_existing_recovery_on_next_heal_pass
    with_marker_file do |state_file|
      File.write(state_file, "# task\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "2-fix",
        workflow: nil,
        marker: "none",
        action: "ready_to_run",
        live_task_lock: false
      )

      assert @healer.heal_markerless_stall(row)

      marker = Hive::Markers.current(state_file)
      error_row = make_row(
        state_file,
        pid_alive: nil,
        stage: "2-fix",
        workflow: "patrol-fix",
        marker: "error",
        marker_attrs: marker.attrs,
        action: "error",
        live_task_lock: false
      )
      heal([ error_row ])

      assert_equal 1, @coordinator.requests.size
      assert_equal "agent_exited_without_terminal_marker",
                   @coordinator.requests.first.fetch(:row).marker_attrs.fetch("reason")
    end
  end

  def test_markerless_stall_is_not_healed_when_admission_is_closed
    with_marker_file do |state_file|
      File.write(state_file, "# task\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        marker: "none",
        action: "ready_to_run",
        live_task_lock: false
      )
      healer = build_healer(admission_open: -> { false })

      refute healer.heal_markerless_stall(row)
      assert_equal :none, Hive::Markers.current(state_file).name
      assert_empty @logger.events
    end
  end

  def test_markerless_stall_is_not_healed_while_controller_is_running_task
    with_marker_file do |state_file|
      File.write(state_file, "# task\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        marker: "none",
        action: "ready_to_run",
        live_task_lock: false
      )
      healer = build_healer(
        controller: FakeController.new(running_pairs: [ [ "p", "s" ] ])
      )

      refute healer.heal_markerless_stall(row)
      assert_equal :none, Hive::Markers.current(state_file).name
      assert_empty @logger.events
    end
  end

  def test_markerless_stall_heal_loses_to_live_or_newer_task_state
    with_marker_file do |state_file|
      File.write(state_file, "# task\n")
      live_row = make_row(
        state_file,
        pid_alive: nil,
        marker: "none",
        action: "ready_to_run",
        live_task_lock: true
      )

      refute @healer.heal_markerless_stall(live_row)
      assert_equal :none, Hive::Markers.current(state_file).name

      Hive::Markers.set(state_file, :waiting, reason: "operator_input")
      stale_row = make_row(
        state_file,
        pid_alive: nil,
        marker: "none",
        action: "ready_to_run",
        live_task_lock: false
      )

      refute @healer.heal_markerless_stall(stale_row)
      assert_equal :waiting, Hive::Markers.current(state_file).name
    end
  end

  def test_markerless_stall_heal_does_not_recreate_a_moved_task_folder
    Dir.mktmpdir do |dir|
      folder = File.join(dir, "moved-task")
      row = make_row(
        File.join(folder, "fix.md"),
        pid_alive: nil,
        marker: "none",
        action: "ready_to_run",
        live_task_lock: false
      )

      refute @healer.heal_markerless_stall(row)
      refute_path_exists folder
    end
  end

  def test_markerless_stall_disk_failure_is_logged_without_crashing_the_tick
    with_marker_file do |state_file|
      File.write(state_file, "# task\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        marker: "none",
        action: "ready_to_run",
        live_task_lock: false
      )

      with_markers_set_if_current_failure(state_file) do
        refute @healer.heal_markerless_stall(row)
      end

      assert_equal :none, Hive::Markers.current(state_file).name
      failure = @logger.events.find { |name, _attributes| name == :marker_heal_failed }
      assert_equal "agent_exited_without_terminal_marker", failure.last.fetch(:reason)
      assert_match(/ENOSPC/, failure.last.fetch(:error))
    end
  end

  def test_unattributed_execute_dirty_wait_remains_a_human_pause
    with_marker_file do |state_file|
      attrs = { "reason" => "dirty_worktree" }
      Hive::Markers.set(state_file, :execute_waiting, attrs)
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "4-execute",
        workflow: "coding",
        marker: "execute_waiting",
        marker_attrs: attrs,
        action: "needs_input",
        live_task_lock: false
      )

      heal([ row ])

      assert_equal :execute_waiting, Hive::Markers.current(state_file).name
      assert_empty @coordinator.requests
    end
  end

  def test_blocked_receipt_uses_the_same_coordinator_projection
    @coordinator.request_status = "blocked"

    with_error_marker do |row, state_file|
      heal([ row ])

      assert_equal :error, Hive::Markers.current(state_file).name
      event = @logger.events.find { |name, _attributes| name == :recovery_blocked }
      assert_equal "safety_blocked", event.last.fetch(:reason)
      assert_equal "repair worktree", event.last.fetch(:remediation)
    end
  end

  def test_retry_assessment_is_unavailable_without_coordinator
    healer = build_healer(recovery_coordinator: nil)

    assessment = healer.retry_assessment(
      make_row("/tmp/missing", pid_alive: nil),
      now: NOW
    )

    assert_equal false, assessment.fetch(:due)
    assert_equal false, assessment.fetch(:safe)
    assert_equal "recovery_coordinator_unavailable",
                 assessment.fetch(:safety_reason)
  end

  def test_attempt_loss_retry_uses_the_shared_recovery_ladder
    limited_at = NOW - 120
    attempt = {
      "retry_charge" => 3,
      "loss" => { "at" => limited_at.iso8601(6) }
    }
    outcome = {}

    refute @healer.send(
      :attempt_loss_retry_due?, attempt, outcome, now: NOW - 1
    )
    assert @healer.send(
      :attempt_loss_retry_due?, attempt, outcome, now: NOW
    )
    assert_equal [ 3, 3 ], @coordinator.retry_delay_counts
  end

  def test_cooldown_and_safety_are_decided_only_by_coordinator
    with_error_marker do |row, state_file|
      @coordinator.assessment_result = {
        due: false,
        retry_at: NOW + 60,
        safe: true,
        safety_reason: "safe"
      }
      heal([ row ])
      assert_empty @coordinator.requests
      assert_equal :error, Hive::Markers.current(state_file).name

      @coordinator.assessment_result = {
        due: true,
        retry_at: NOW,
        safe: false,
        safety_reason: "worktree dirty"
      }
      heal([ row ])
      assert_empty @coordinator.requests
      assert_equal 2, @coordinator.assessments.size
    end
  end

  def test_live_owner_and_project_switch_block_submission
    with_error_marker do |row, _state_file|
      row.live_task_lock = true
      heal([ row ])
      assert_empty @coordinator.requests
    end

    with_error_marker(project: "held") do |row, _state_file|
      build_healer(
        project_daemon_enabled: ->(project) { project != "held" }
      ).heal([ row ], now: NOW, daemon_enabled_projects: { "other" => true })
      assert_empty @coordinator.requests
    end
  end

  def test_default_project_retry_policy_allows_coordinator_submission
    healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      recovery_coordinator: @coordinator
    )
    assert healer.instance_variable_get(
      :@project_daemon_enabled
    ).call("any-project")

    with_error_marker do |row, _state_file|
      healer.heal([ row ], now: NOW)
    end

    assert_equal 1, @coordinator.requests.size
  end

  def test_terminal_outcome_errors_are_assessed_like_any_other_error
    %w[terminal_outcome_blocked terminal_outcome_invalid].each do |reason|
      with_error_marker(reason: reason, extra_attrs: { "outcome" => "blocked" }) do |row, state_file|
        heal([ row ])

        refute_empty @coordinator.assessments, reason
        marker = Hive::Markers.current(state_file)
        assert_equal :error, marker.name
        assert_equal reason, marker.attrs.fetch("reason")
      end
    end
  end

  def test_recovery_event_logging_is_best_effort
    logger = Object.new
    logger.define_singleton_method(:event) do |*_args, **_kwargs|
      raise IOError, "log unavailable"
    end
    healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: logger,
      recovery_coordinator: @coordinator
    )
    row = make_row("/tmp/task.md", pid_alive: nil)
    receipt = @coordinator.request(row: row, requestor: "healer", now: NOW)

    assert_nil healer.send(:log_coordinated_recovery, row, receipt)
  end

  def test_coordinator_failure_is_logged_without_clearing_the_marker
    @coordinator.request_error = Errno::ENOSPC.new("queue full")

    with_error_marker(reason: "timeout") do |row, state_file|
      heal([ row ])

      assert_equal :error, Hive::Markers.current(state_file).name
      failure = @logger.events.find { |name, _attributes| name == :marker_heal_failed }
      assert_equal "stage_timeout", failure.last.fetch(:reason)
      assert_match(/ENOSPC/, failure.last.fetch(:error))
    end
  end

  def test_all_error_reason_labels_still_share_the_same_submission_path
    labels = {
      "unpushed_commits" => "finalize_unpushed_commits",
      "limits_reached" => "limits_reached",
      "timeout" => "stage_timeout",
      "ensure_clean_on_exit_failed" => "clean_exit_residue",
      "tmux_session_terminated" => "agent_loss_retry",
      "unknown_failure" => "error_retry"
    }

    labels.each_with_index do |(reason, expected_label), index|
      @coordinator.request_error = RuntimeError.new("failure #{index}")
      with_error_marker(
        reason: reason,
        stage: reason == "unpushed_commits" ? "8-finalize" : "4-execute",
        workflow: "coding",
        marker_id: "error-#{index}"
      ) do |row, _state_file|
        heal([ row ])
      end
      failure = @logger.events.reverse.find do |name, attributes|
        name == :marker_heal_failed && attributes[:error].include?("failure #{index}")
      end
      assert_equal expected_label, failure.last.fetch(:reason)
    end
  end

  def test_all_review_reason_labels_still_share_the_same_submission_path
    labels = {
      "review_agent_died" => "review_agent_died",
      "limits_reached" => "reviewer_limits_reached",
      "all_failed" => "reviewer_all_failed",
      "fix_failed" => "fix_claude_stop_hook",
      "fix_auto_commit_scope_failed" => "fix_auto_commit_retry",
      "reviewer_partial_failure" => "reviewer_tmux_session_terminated",
      "unknown_failure" => "review_error_retry"
    }

    labels.each_with_index do |(reason, expected_label), index|
      @coordinator.request_error = RuntimeError.new("review failure #{index}")
      with_marker_file do |state_file|
        Hive::Markers.set(
          state_file,
          :review_error,
          phase: "reviewers",
          reason: reason,
          pass: "1",
          marker_id: "review-#{index}"
        )
        row = make_row(
          state_file,
          pid_alive: nil,
          stage: "6-review",
          marker: "review_error",
          marker_attrs: Hive::Markers.current(state_file).attrs,
          live_task_lock: false
        )
        heal([ row ])
      end
      failure = @logger.events.reverse.find do |name, attributes|
        name == :marker_heal_failed &&
          attributes[:error].include?("review failure #{index}")
      end
      assert_equal expected_label, failure.last.fetch(:reason)
    end
  end

  def test_repeated_fresh_errors_never_create_a_healer_budget
    30.times do |index|
      with_error_marker(marker_id: "fresh-#{index}") do |row, _state_file|
        heal([ row ])
      end
    end

    assert_equal 30, @coordinator.requests.size
    refute @healer.instance_variable_defined?(:@error_auto_recoveries)
    refute @healer.instance_variable_defined?(:@review_error_auto_recoveries)
    refute_respond_to @healer, :operational_snapshot
  end

  def test_dead_and_orphaned_agent_working_markers_become_durable_errors
    [
      [ false, NOW - 10, "agent_died" ],
      [ nil, NOW - 600, "agent_orphaned" ]
    ].each do |pid_alive, mtime, reason|
      with_marker_file do |state_file|
        heal([ make_row(state_file, pid_alive: pid_alive, mtime: mtime) ])

        marker = Hive::Markers.current(state_file)
        assert_equal :error, marker.name
        assert_equal reason, marker.attrs.fetch("reason")
      end
    end
  end

  def test_live_or_fresh_agent_working_markers_are_not_rewritten
    [
      make_row("/tmp/live", pid_alive: true),
      make_row("/tmp/fresh", pid_alive: nil, mtime: NOW - 60),
      make_row("/tmp/locked", pid_alive: nil, mtime: NOW - 600, live_task_lock: true)
    ].each do |template|
      with_marker_file do |state_file|
        template.state_file = state_file
        template.folder = File.dirname(state_file)
        heal([ template ])
        assert_equal :agent_working, Hive::Markers.current(state_file).name
      end
    end
  end

  def test_running_half_migrated_and_nonworking_rows_are_skipped
    with_marker_file do |state_file|
      @healer = build_healer(
        controller: FakeController.new(running_pairs: [ [ "p", "s" ] ])
      )
      heal([ make_row(state_file, pid_alive: false) ])
      assert_equal :agent_working, Hive::Markers.current(state_file).name
    end

    with_marker_file do |state_file|
      heal(
        [ make_row(state_file, pid_alive: false) ],
        legacy_layout_projects: { "p" => true }
      )
      assert_equal :agent_working, Hive::Markers.current(state_file).name
    end

    with_marker_file do |state_file|
      heal([
        make_row(
          state_file,
          pid_alive: false,
          marker: "complete",
          action: "waiting"
        )
      ])
      assert_equal :agent_working, Hive::Markers.current(state_file).name
    end
  end

  def test_agent_working_disk_failure_does_not_crash_the_tick
    with_marker_file do |state_file|
      with_markers_set_failure(state_file) do
        heal([ make_row(state_file, pid_alive: false) ])
      end

      assert_equal :agent_working, Hive::Markers.current(state_file).name
      failure = @logger.events.find { |name, _attributes| name == :marker_heal_failed }
      assert_equal "agent_died", failure.last.fetch(:reason)
      assert_match(/ENOSPC/, failure.last.fetch(:error))
    end
  end

  def test_wedged_review_working_becomes_review_error
    with_marker_file do |state_file|
      holder = prepare_review_working(
        state_file,
        phase: "reviewers",
        pass: "1",
        holder: {
          "pid" => Process.pid,
          "process_start_time" => Hive::Lock.process_start_time(Process.pid),
          "claude_pid" => 999_999,
          "lock_id" => "review-lock"
        }
      )
      row = review_working_row(
        state_file,
        pid_alive: false,
        live_task_lock: true,
        **lock_identity(holder)
      )

      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [] }) do
        task_lease_payloads = @task_lease_payloads
        task_folder = File.dirname(state_file)
        with_replaced_singleton_method(
          @healer,
          :terminate_lock_holder,
          ->(_holder) { task_lease_payloads.delete(task_folder) }
        ) do
          heal([ row ])
        end
      end

      marker = Hive::Markers.current(state_file)
      assert_equal :review_error, marker.name
      assert_equal "review_agent_died", marker.attrs.fetch("reason")
      assert_equal "reviewers", marker.attrs.fetch("phase")
      assert_equal "1", marker.attrs.fetch("pass")
      event = @logger.events.find { |name, _attributes| name == :marker_healed }
      assert_equal "review_agent_died", event.last.fetch(:reason)
    end
  end

  def test_wedged_review_with_live_children_or_replacement_generation_is_left_alone
    with_marker_file do |state_file|
      holder = prepare_review_working(
        state_file,
        holder: {
          "pid" => Process.pid,
          "process_start_time" => Hive::Lock.process_start_time(Process.pid),
          "claude_pid" => 999_999,
          "lock_id" => "review-lock"
        }
      )
      row = review_working_row(
        state_file,
        pid_alive: false,
        live_task_lock: true,
        **lock_identity(holder)
      )
      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [ 123 ] }) do
        heal([ row ])
      end
      assert_equal :review_working, Hive::Markers.current(state_file).name
    end

    with_marker_file do |state_file|
      holder = prepare_review_working(
        state_file,
        marker_id: "current",
        holder: {
          "pid" => Process.pid,
          "process_start_time" => Hive::Lock.process_start_time(Process.pid),
          "lock_id" => "replacement"
        }
      )
      row = review_working_row(
        state_file,
        pid_alive: false,
        live_task_lock: true,
        marker_id: "observed",
        task_lock_pid: Process.pid,
        task_lock_process_start_time: Hive::Lock.process_start_time(Process.pid),
        task_lock_id: "observed"
      )
      with_replaced_singleton_method(
        @healer,
        :terminate_lock_holder,
        ->(_holder) { flunk "replacement holder must not be terminated" }
      ) do
        heal([ row ])
      end
      assert_equal :review_working, Hive::Markers.current(state_file).name
      assert_same holder, @task_lease_payloads.fetch(File.dirname(state_file))
    end
  end

  def test_wedged_review_marker_generation_race_and_lock_claim_race_fail_closed
    with_marker_file do |state_file|
      holder = prepare_review_working(
        state_file,
        marker_id: "newer",
        holder: {
          "pid" => Process.pid,
          "process_start_time" => Hive::Lock.process_start_time(Process.pid),
          "claude_pid" => 999_999,
          "lock_id" => "review-lock"
        }
      )
      row = review_working_row(
        state_file,
        pid_alive: false,
        live_task_lock: true,
        marker_id: "older",
        **lock_identity(holder)
      )
      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [] }) do
        heal([ row ])
      end
      assert_equal :review_working, Hive::Markers.current(state_file).name
    end

    with_marker_file do |state_file|
      holder = prepare_review_working(
        state_file,
        marker_id: "observed",
        holder: {
          "pid" => Process.pid,
          "process_start_time" => Hive::Lock.process_start_time(Process.pid),
          "claude_pid" => 999_999,
          "lock_id" => "review-lock"
        }
      )
      row = review_working_row(
        state_file,
        pid_alive: false,
        live_task_lock: true,
        marker_id: "observed",
        **lock_identity(holder)
      )
      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [] }) do
        with_replaced_singleton_method(
          @healer,
          :terminate_lock_holder,
          ->(_holder) { nil }
        ) do
          heal([ row ])
        end
      end
      assert_equal :review_working, Hive::Markers.current(state_file).name
      assert_same holder, @task_lease_payloads.fetch(File.dirname(state_file))
    end
  end

  def test_orphaned_review_working_becomes_review_error_after_grace
    with_marker_file do |state_file|
      holder = prepare_review_working(
        state_file,
        phase: "triage",
        pass: "2",
        holder: { "pid" => 999_999, "claude_pid" => 999_998 }
      )
      row = review_working_row(
        state_file,
        pid_alive: false,
        live_task_lock: false,
        mtime: NOW - 1000,
        phase: "triage",
        pass: "2"
      )

      heal([ row ])

      marker = Hive::Markers.current(state_file)
      assert_equal :review_error, marker.name
      assert_equal "review_orphaned", marker.attrs.fetch("reason")
      refute @task_lease_payloads.key?(File.dirname(state_file))
    end
  end

  def test_orphaned_review_without_lock_is_repaired_but_fresh_review_is_not
    with_marker_file do |state_file|
      prepare_review_working(state_file, holder: nil)
      heal([
        review_working_row(
          state_file,
          pid_alive: nil,
          live_task_lock: nil,
          mtime: NOW - 1000
        )
      ])
      assert_equal :review_error, Hive::Markers.current(state_file).name
    end

    with_marker_file do |state_file|
      prepare_review_working(state_file, holder: nil)
      heal([
        review_working_row(
          state_file,
          pid_alive: nil,
          live_task_lock: false,
          mtime: NOW - 60
        )
      ])
      assert_equal :review_working, Hive::Markers.current(state_file).name
    end
  end

  def test_orphaned_review_generation_and_new_lock_races_fail_closed
    with_marker_file do |state_file|
      holder = prepare_review_working(
        state_file,
        marker_id: "newer",
        holder: {
          "pid" => Process.pid,
          "process_start_time" => Hive::Lock.process_start_time(Process.pid),
          "owner" => "new-runner"
        }
      )
      row = review_working_row(
        state_file,
        pid_alive: false,
        live_task_lock: false,
        mtime: NOW - 1000,
        marker_id: "older"
      )
      heal([ row ])

      assert_equal :review_working, Hive::Markers.current(state_file).name
      assert_equal "new-runner", holder.fetch("owner")
      assert_same holder, @task_lease_payloads.fetch(File.dirname(state_file))
    end
  end

  def test_review_working_transition_failure_is_logged
    with_marker_file do |state_file|
      prepare_review_working(state_file, holder: nil)
      row = review_working_row(
        state_file,
        pid_alive: nil,
        live_task_lock: false,
        mtime: NOW - 1000
      )

      with_markers_set_failure(state_file) { heal([ row ]) }

      assert_equal :review_working, Hive::Markers.current(state_file).name
      failure = @logger.events.find { |name, _attributes| name == :marker_heal_failed }
      assert_equal "review_orphaned", failure.last.fetch(:reason)
    end
  end

  def test_wedged_review_inspection_failure_is_logged
    with_marker_file do |state_file|
      row = review_working_row(
        state_file, pid_alive: false, live_task_lock: true
      )
      with_replaced_singleton_method(
        @healer, :task_lock_holder, ->(_row) { raise IOError, "lock unreadable" }
      ) do
        @healer.send(:heal_wedged_review_row, row)
      end

      failure = @logger.events.find do |name, attributes|
        name == :marker_heal_failed &&
          attributes[:reason] == "review_agent_died"
      end
      assert_includes failure.last.fetch(:error), "lock unreadable"
    end
  end

  def test_task_lock_and_marker_attribute_helpers_fail_closed
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: nil)
      implementation = Hive::Daemon::StaleAgentHealer.instance_method(:task_lock_holder)

      with_replaced_singleton_method(
        Hive::Lock, :read_task_lock, ->(_folder) { raise Hive::RuntimeControlPlane::CodecError.new(
          "invalid lease JSON", code: :json_invalid
        ) }
      ) do
        assert_nil implementation.bind_call(@healer, row)
      end
      assert_equal({}, @healer.send(:marker_attrs_for, Object.new))
    end
  end

  def test_with_heal_lock_treats_task_lease_contention_as_a_lost_race
    row = make_row("/tmp/missing-task/task.md", pid_alive: nil)
    implementation = Hive::Daemon::StaleAgentHealer.instance_method(:with_heal_lock)
    attempted = false
    replacement = lambda do |*_args, **_kwargs|
      raise Hive::ConcurrentRunError.new(
        "another runner won", lock_path: "runtime-control-plane:task:42"
      )
    end

    result = with_replaced_singleton_method(Hive::Lock, :with_task_lock, replacement) do
      implementation.bind_call(@healer, row, reason: "test") { attempted = true }
    end

    assert_equal false, result
    assert_equal false, attempted
  end

  def test_with_heal_lock_handles_a_task_removed_after_the_snapshot
    row = make_row("/tmp/missing-task/task.md", pid_alive: nil)
    implementation = Hive::Daemon::StaleAgentHealer.instance_method(:with_heal_lock)
    missing = ->(*_args, **_kwargs) { raise Errno::ENOENT, row.folder.to_s }

    result = with_replaced_singleton_method(Hive::Lock, :with_task_lock, missing) do
      implementation.bind_call(@healer, row, reason: "test", create: false) { flunk }
    end
    assert_equal false, result

    assert_raises(Errno::ENOENT) do
      with_replaced_singleton_method(Hive::Lock, :with_task_lock, missing) do
        implementation.bind_call(@healer, row, reason: "test", create: true) { flunk }
      end
    end
  end

  def test_child_process_lookup_handles_each_pgrep_outcome
    status = Struct.new(:exitstatus, :successful) do
      def success?
        successful
      end
    end

    with_replaced_singleton_method(
      Open3, :capture3, ->(*_args) { [ "", "", status.new(1, false) ] }
    ) do
      assert_equal [], @healer.send(:child_pids, 123)
    end
    with_replaced_singleton_method(
      Open3, :capture3, ->(*_args) { [ "", "", status.new(2, false) ] }
    ) do
      assert_nil @healer.send(:child_pids, 123)
    end
    with_replaced_singleton_method(
      Open3, :capture3,
      ->(*_args) { [ "12\nnot-a-pid\n13\n", "", status.new(0, true) ] }
    ) do
      assert_equal [ 12, 13 ], @healer.send(:child_pids, 123)
    end
    with_replaced_singleton_method(
      Open3, :capture3, ->(*_args) { raise Errno::ENOENT, "pgrep missing" }
    ) do
      assert_nil @healer.send(:child_pids, 123)
    end
  end

  def test_terminate_lock_holder_escalates_and_tolerates_a_disappearing_process
    holder = { "pid" => 12_345 }
    signals = []
    times = [ NOW, NOW + 2 ]

    with_replaced_singleton_method(
      @healer, :lock_holder_process_alive?, ->(_holder) { true }
    ) do
      with_replaced_singleton_method(@healer, :sleep, ->(_seconds) { }) do
        with_replaced_singleton_method(Time, :now, -> { times.shift || NOW + 2 }) do
          with_replaced_singleton_method(Process, :kill, lambda { |signal, pid|
            signals << [ signal, pid ]
            1
          }) do
            @healer.send(:terminate_lock_holder, holder)
          end
        end
      end
    end

    assert_equal [ [ "TERM", 12_345 ], [ "KILL", 12_345 ] ], signals

    with_replaced_singleton_method(
      @healer, :lock_holder_process_alive?, ->(_holder) { true }
    ) do
      with_replaced_singleton_method(
        Process, :kill, ->(*_args) { raise Errno::ESRCH, "gone" }
      ) do
        assert_nil @healer.send(:terminate_lock_holder, holder)
      end
    end
  end

  def test_terminate_lock_holder_does_not_kill_reused_pid
    signals = []
    starts = [ "observed", "observed", "replacement" ]
    holder = { "pid" => 12_345, "process_start_time" => "observed" }

    with_replaced_singleton_method(
      Process,
      :kill,
      lambda { |signal, pid|
        signals << [ signal, pid ]
        1
      }
    ) do
      with_replaced_singleton_method(
        Hive::Lock,
        :process_start_time,
        ->(_pid) { starts.shift }
      ) do
        @healer.send(:terminate_lock_holder, holder)
      end
    end

    assert_includes signals, [ "TERM", 12_345 ]
    refute_includes signals, [ "KILL", 12_345 ]
  end

  private

  def build_healer(controller: @controller,
                   recovery_coordinator: @coordinator,
                   project_daemon_enabled: ->(_project) { true },
                   admission_open: -> { true })
    Hive::Daemon::StaleAgentHealer.new(
      controller: controller,
      logger: @logger,
      grace_sec: 300,
      project_daemon_enabled: project_daemon_enabled,
      recovery_coordinator: recovery_coordinator,
      admission_open: admission_open
    )
  end

  def heal(rows, **options)
    @healer.heal(rows, now: NOW, **options)
  end

  def with_marker_file
    Dir.mktmpdir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "# task\n\n<!-- AGENT_WORKING -->\n")
      yield state_file
    end
  end

  def with_error_marker(reason: "implementer_failed", stage: "4-execute",
                        workflow: nil, marker_id: "marker-1", project: "p",
                        extra_attrs: {})
    with_marker_file do |state_file|
      attrs = {
        "reason" => reason,
        "marker_id" => marker_id
      }.merge(extra_attrs)
      Hive::Markers.set(state_file, :error, attrs)
      row = make_row(
        state_file,
        pid_alive: nil,
        project: project,
        stage: stage,
        workflow: workflow,
        marker: "error",
        marker_attrs: Hive::Markers.current(state_file).attrs,
        action: "error",
        live_task_lock: false
      )
      yield row, state_file
    end
  end

  def make_row(state_file, pid_alive:,
               mtime: NOW - Hive::AgentLimit.retry_cooldown_sec - 1,
               project: "p", slug: "s", stage: "4-execute",
               marker: "agent_working", marker_attrs: {}, action: "error",
               live_task_lock: nil, workflow: nil, task_lock_pid: nil,
               task_lock_process_start_time: nil, task_lock_id: nil,
               task_history_invalid: false)
    Row.new(
      project: project,
      slug: slug,
      id: 42,
      stage: stage,
      workflow: workflow,
      marker: marker,
      marker_attrs: marker_attrs,
      task_history_invalid: task_history_invalid,
      folder: File.dirname(state_file),
      state_file: state_file,
      state_file_mtime: mtime,
      action: action,
      suggested_command: nil,
      claude_pid_alive: pid_alive,
      live_task_lock: live_task_lock,
      task_lock_pid: task_lock_pid,
      task_lock_process_start_time: task_lock_process_start_time,
      task_lock_id: task_lock_id,
      diagnostic: nil
    )
  end

  def prepare_review_working(state_file, phase: "reviewers", pass: "1",
                             marker_id: nil, holder:)
    attrs = { "phase" => phase, "pass" => pass }
    attrs["marker_id"] = marker_id if marker_id
    Hive::Markers.set(state_file, :review_working, attrs)
    return nil unless holder

    @task_lease_payloads[File.dirname(state_file)] = holder
    holder
  end

  def review_working_row(state_file, pid_alive:, live_task_lock:,
                         mtime: NOW - 1000, phase: "reviewers", pass: "1",
                         marker_id: nil, **lock_attributes)
    attrs = Hive::Markers.current(state_file).attrs.dup
    attrs["phase"] = phase
    attrs["pass"] = pass
    attrs["marker_id"] = marker_id if marker_id
    make_row(
      state_file,
      pid_alive: pid_alive,
      mtime: mtime,
      stage: "6-review",
      marker: "review_working",
      marker_attrs: attrs,
      action: "agent_running",
      live_task_lock: live_task_lock,
      **lock_attributes
    )
  end

  def lock_identity(holder)
    {
      task_lock_pid: holder["pid"],
      task_lock_process_start_time: holder["process_start_time"],
      task_lock_id: holder["lock_id"]
    }
  end

  def with_markers_set_failure(state_file)
    original = Hive::Markers.method(:set)
    Hive::Markers.define_singleton_method(:set) do |path, *args, **kwargs|
      raise Errno::ENOSPC, "no space left" if path == state_file

      original.call(path, *args, **kwargs)
    end
    yield
  ensure
    Hive::Markers.define_singleton_method(:set, &original)
  end

  def with_markers_set_if_current_failure(state_file)
    original = Hive::Markers.method(:set_if_current)
    Hive::Markers.define_singleton_method(:set_if_current) do |path, *args, **kwargs|
      raise Errno::ENOSPC, "no space left" if path == state_file

      original.call(path, *args, **kwargs)
    end
    yield
  ensure
    Hive::Markers.define_singleton_method(:set_if_current, &original)
  end
end
