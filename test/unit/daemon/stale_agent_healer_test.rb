require "test_helper"
require "tmpdir"
require "time"
require "hive/agent_limit"
require "hive/markers"
require "hive/daemon/stale_agent_healer"
require "hive/daemon/status_consumer"
require "hive/review_error_reason"
require "hive/stages/review"

# Healer's job: rewrite AGENT_WORKING markers whose backing agent isn't
# alive to ERROR reason=agent_{died,orphaned}. Anything else (live
# agent, in-grace placeholder, in-flight controller slot) it leaves
# alone. These tests pin those branches without bringing up the full
# dispatcher.
class HiveDaemonStaleAgentHealerTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Daemon::StatusConsumer::Row

  class FakeController
    attr_reader :observed_mtimes

    def initialize(running_pairs: [])
      @running = running_pairs
      @observed_mtimes = []
    end

    def running_task?(project:, slug:)
      @running.include?([ project, slug ])
    end

    def observe_state_file_mtime(project:, slug:, mtime:)
      @observed_mtimes << { project: project, slug: slug, mtime: mtime }
    end
  end

  class FakeLogger
    attr_reader :events
    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end
  end

  NOW = Time.utc(2026, 5, 20, 12, 0, 0)

  # Records write_request! calls instead of touching the real queue dir.
  class FakeRequestQueue
    attr_reader :requests

    def initialize
      @requests = []
    end

    def write_request!(**kwargs)
      @requests << kwargs
      "fake-req-#{@requests.size}"
    end
  end

  class FakeRecoveryCoordinator
    attr_reader :requests

    def initialize
      @requests = []
    end

    def assessment(row, now:)
      {
        due: true,
        retry_at: row.state_file_mtime + Hive::AgentLimit.retry_cooldown_sec,
        safe: true,
        safety_reason: "safe"
      }
    end

    def request(row:, requestor:, now:, retry_count:)
      @requests << {
        row: row, requestor: requestor, now: now, retry_count: retry_count
      }
      Hive::Daemon::RecoveryCoordinator::Receipt.new(
        status: "queued", request_id: "coordinated-1", attempt_id: nil,
        phase: "admitted", failure_origin: row.marker_attrs["reason"],
        next_eligible_at: now.utc.iso8601(6), owner: "scheduler",
        reason: nil, remediation: nil, retry_count: retry_count + 1,
        provider_hint: nil
      )
    end
  end

  AttemptRecord = Data.define(
    :attempt_id, :state, :outcome, :predecessor_attempt_id,
    :project, :task_slug, :task_generation
  ) do
    def [](key)
      public_send(key)
    end

    def live?
      %w[launching running].include?(state)
    end
  end

  class FakeAttemptStore
    def initialize(records)
      @records = records
    end

    def fetch(attempt_id)
      @records.find { |record| record.attempt_id == attempt_id }
    end
  end

  class FakeLostOutcomeStore
    def initialize(outcomes)
      @outcomes = outcomes
    end

    def fetch(attempt_id) = @outcomes[attempt_id]
  end

  def setup
    @logger = FakeLogger.new
    @controller = FakeController.new
    @request_queue = FakeRequestQueue.new
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller, logger: @logger, grace_sec: 300,
      request_queue: @request_queue
    )
  end

  def test_operational_snapshot_starts_with_unbounded_empty_recovery_state
    snapshot = @healer.operational_snapshot

    assert_nil snapshot.dig("limits", "error")
    assert_nil snapshot.dig("limits", "review")
    assert_nil snapshot.dig("limits", "attempt_loss")
    assert_empty snapshot.fetch("error_retries")
    assert_empty snapshot.fetch("review_exhausted")
  end

  def test_universal_error_healer_delegates_to_recovery_coordinator_without_clearing
    coordinator = FakeRecoveryCoordinator.new
    healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      request_queue: @request_queue,
      recovery_coordinator: coordinator
    )

    with_marker_file do |state_file|
      Hive::Markers.set(state_file, :error, reason: "timeout", marker_id: "marker-1")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "4-execute",
        marker: "error",
        marker_attrs: Hive::Markers.current(state_file).attrs,
        action: "error",
        live_task_lock: false
      )

      healer.heal([ row ], now: NOW)

      assert_equal :error, Hive::Markers.current(state_file).name
      request = coordinator.requests.fetch(0)
      assert_equal "healer", request.fetch(:requestor)
      assert_equal 0, request.fetch(:retry_count)
      event = @logger.events.find { |name, _attrs| name == :recovery_requested }
      assert_equal "coordinated-1", event.last.fetch(:request_id)
    end
  end

  def test_default_project_retry_gate_is_enabled
    gate = @healer.instance_variable_get(:@project_auto_retry_enabled)

    assert_equal true, gate.call("any-project")
  end

  def test_agent_preflight_error_retries_after_cooldown_beyond_legacy_budget
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1,
      request_queue: @request_queue
    )

    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: NOW - Hive::AgentLimit.retry_cooldown_sec - 1,
        stage: "3-generate",
        marker: "error",
        marker_attrs: {
          "reason" => "agent_preflight_failed",
          "message" => "codex binary not runnable"
        },
        action: "error",
        live_task_lock: false,
        workflow: "bench"
      )

      2.times do
        Hive::Markers.set(
          state_file,
          :error,
          reason: "agent_preflight_failed",
          message: "codex binary not runnable"
        )
        row.marker_attrs = Hive::Markers.current(state_file).attrs
        row.state_file_mtime = NOW - Hive::AgentLimit.retry_cooldown_sec - 1

        heal([ row ])

        assert Hive::Markers.current(state_file).none?,
               "every cooled-down preflight error must remain retryable"
      end

      heals = @logger.events.select { |name, _attrs| name == :marker_healed }
      assert_equal 2, heals.size
      assert_empty @logger.events.select { |name, _attrs| name == :marker_heal_exhausted }
    end
  end

  def test_review_integrity_error_retries_after_cooldown_beyond_legacy_budget
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      review_error_auto_recovery_limit: 1,
      request_queue: @request_queue
    )

    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: NOW - Hive::AgentLimit.retry_cooldown_sec - 1,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "fix",
          "reason" => "fix_tampered",
          "pass" => "1",
          "restored" => "true"
        },
        action: "recover_review",
        live_task_lock: false
      )

      2.times do
        Hive::Markers.set(
          state_file,
          :review_error,
          phase: "fix",
          reason: "fix_tampered",
          pass: "1",
          restored: true
        )
        row.marker_attrs = Hive::Markers.current(state_file).attrs
        row.state_file_mtime = NOW - Hive::AgentLimit.retry_cooldown_sec - 1

        heal([ row ])

        assert Hive::Markers.current(state_file).none?,
               "every cooled-down review error must remain retryable"
      end

      heals = @logger.events.select { |name, _attrs| name == :marker_healed }
      assert_equal 2, heals.size
      assert_empty @logger.events.select { |name, _attrs| name == :marker_heal_exhausted }
    end
  end

  def test_error_and_review_error_share_the_same_cooldown_boundary
    [
      [ :error, "error", { "reason" => "git_status_failed" }, "4-execute" ],
      [ :review_error, "review_error",
        { "phase" => "fix", "reason" => "fix_tampered", "pass" => "1" },
        "6-review" ]
    ].each do |marker_name, row_marker, attrs, stage|
      with_marker_file do |state_file|
        Hive::Markers.set(state_file, marker_name, attrs)
        row = make_row(
          state_file,
          pid_alive: nil,
          mtime: NOW - Hive::AgentLimit.retry_cooldown_sec + 1,
          stage: stage,
          marker: row_marker,
          marker_attrs: Hive::Markers.current(state_file).attrs,
          action: row_marker == "error" ? "error" : "recover_review",
          live_task_lock: false
        )

        heal([ row ])

        assert_equal marker_name, Hive::Markers.current(state_file).name,
                     "#{row_marker} must remain parked before the shared cooldown"
        refute @logger.events.any? { |name, _| name == :marker_healed }
      end
    end
  end

  def test_operational_snapshot_serializes_retry_ownership_without_exhaustion
    error_key = [ "project-a", "task-a", "7-artifacts", "agent_died" ]
    review_key = [ "project-b", "task-b", "review_agent_died", "reviewers", "1" ]
    @healer.instance_variable_get(:@error_auto_recoveries)[error_key] = 2
    @healer.instance_variable_get(:@error_auto_recoveries)[[ "ignored", "zero" ]] = 0
    @healer.instance_variable_get(:@review_error_auto_recoveries)[review_key] = 1
    snapshot = @healer.operational_snapshot

    assert_equal [ {
      "project" => "project-a", "slug" => "task-a", "stage" => "7-artifacts",
      "reason" => "agent_died", "kind" => "error", "attempts" => 2
    } ], snapshot.fetch("error_retries")
    assert_equal [ {
      "project" => "project-b", "slug" => "task-b", "stage" => "6-review",
      "reason" => "review_agent_died", "kind" => "review", "attempts" => 1
    } ], snapshot.fetch("review_retries")
    assert_empty snapshot.fetch("error_exhausted")
    assert_empty snapshot.fetch("review_exhausted")
  end

  def test_retry_counters_are_pruned_after_error_rows_disappear
    @healer.instance_variable_get(:@error_auto_recoveries)[
      [ "project-a", "task-a", "4-execute", "failed" ]
    ] = 2
    @healer.instance_variable_get(:@review_error_auto_recoveries)[
      [ "project-b", "task-b", "fix_failed", "fix", "1" ]
    ] = 3

    heal([])

    snapshot = @healer.operational_snapshot
    assert_empty snapshot.fetch("error_retries")
    assert_empty snapshot.fetch("review_retries")
  end

  def heal(rows, **opts)
    @healer.heal(rows, now: NOW, **opts)
  end

  def with_marker_file
    Dir.mktmpdir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "# task\n\n<!-- AGENT_WORKING -->\n")
      yield state_file
    end
  end

  # Realistic default: post-U4, status.rb classifies stale agent_working
  # rows with action="error". The healer keys off row.marker (the
  # on-disk marker name), not row.action, so we use the production-
  # accurate combo by default. Tests can override via the action: kwarg.
  def make_row(state_file, pid_alive:, mtime: NOW - Hive::AgentLimit.retry_cooldown_sec - 1,
               project: "p", slug: "s", stage: "4-execute",
               marker: "agent_working", marker_attrs: {}, action: "error", live_task_lock: nil, workflow: nil,
               task_lock_pid: nil, task_lock_process_start_time: nil, task_lock_id: nil)
    Row.new(
      project: project, slug: slug, id: 42, stage: stage, workflow: workflow,
      marker: marker, marker_attrs: marker_attrs, folder: File.dirname(state_file), state_file: state_file,
      state_file_mtime: mtime,
      action: action, suggested_command: nil,
      claude_pid_alive: pid_alive, live_task_lock: live_task_lock,
      task_lock_pid: task_lock_pid,
      task_lock_process_start_time: task_lock_process_start_time,
      task_lock_id: task_lock_id,
      diagnostic: nil
    )
  end

  def lock_identity(lock_path)
    holder = YAML.safe_load(File.read(lock_path))
    {
      task_lock_pid: holder["pid"],
      task_lock_process_start_time: holder["process_start_time"],
      task_lock_id: holder["lock_id"]
    }
  end

  def test_heals_dead_pid_to_agent_died
    with_marker_file do |state_file|
      # Marker had a pid (we don't model it in the row directly; the
      # healer keys off claude_pid_alive, which the status command
      # computes from the .lock file).
      row = make_row(state_file, pid_alive: false)
      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected a marker_healed event, got: #{@logger.events.inspect}"
      assert_equal "agent_died", heal_event[1][:reason]
      assert_match(/ERROR\s+reason=agent_died/, File.read(state_file))
    end
  end

  def test_heals_pidless_placeholder_when_older_than_grace
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: nil, mtime: NOW - 600)
      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected agent_orphaned heal, got: #{@logger.events.inspect}"
      assert_equal "agent_orphaned", heal_event[1][:reason]
      assert_match(/ERROR\s+reason=agent_orphaned/, File.read(state_file))
    end
  end

  def test_leaves_pidless_placeholder_within_grace
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: nil, mtime: NOW - 60)
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "row inside grace window must not be healed; events: #{@logger.events.inspect}"
      assert_match(/AGENT_WORKING/, File.read(state_file))
    end
  end

  def test_leaves_live_pid_untouched
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: true)
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/AGENT_WORKING/, File.read(state_file))
    end
  end

  # Issue #144: an externally-spawned `hive run` may hold the per-task
  # .lock with a verified PID + process_start_time match while it does
  # pre-stage work (e.g. auto-rebase) — the marker is still AGENT_WORKING
  # and claude_pid_alive is still nil because the runner has not written
  # its claude_pid yet. Without the live_task_lock skip, the healer
  # races the live runner once mtime exceeds grace.
  def test_skips_row_with_live_task_lock_even_when_grace_exceeded
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: nil, mtime: NOW - 600, live_task_lock: true)
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "live_task_lock=true must pre-empt grace-exceeded heal so the healer does not race the live runner; events: #{@logger.events.inspect}"
      assert_match(/AGENT_WORKING/, File.read(state_file))
    end
  end

  def test_skips_row_with_live_controller_slot
    with_marker_file do |state_file|
      # Even with pid_alive=false, if the controller has a slot for
      # this task, the daemon believes a dispatch is in flight and
      # the healer must defer (the dispatch will rewrite the marker
      # itself when it completes).
      @controller = FakeController.new(running_pairs: [ [ "p", "s" ] ])
      @healer = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300
      )
      row = make_row(state_file, pid_alive: false)
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "controller-managed dispatches must not be healed mid-flight"
      assert_match(/AGENT_WORKING/, File.read(state_file))
    end
  end

  def test_skips_rows_in_half_migrated_projects
    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: false)
      heal([ row ], legacy_layout_projects: { "p" => true })

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "half-migrated projects must be left alone — advancing on top of a renamed stage dir would silently lose work"
    end
  end

  def test_skips_rows_whose_marker_is_not_agent_working
    with_marker_file do |state_file|
      # Healer keys off the on-disk marker name. A row whose marker is
      # already something else (review_error, complete, error, etc.)
      # is out of scope — the marker has already moved past
      # AGENT_WORKING and a different recovery affordance applies.
      row = make_row(state_file, pid_alive: false, marker: "review_error", action: "error")
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
    end
  end

  def test_heals_wedged_review_working_lock_when_agent_child_is_dead
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      File.write(lock_path, {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "claude_pid" => 999_999
      }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1" },
        action: "agent_running",
        live_task_lock: true,
        **lock_identity(lock_path)
      )

      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [] }) do
        with_replaced_singleton_method(@healer, :terminate_lock_holder, ->(_holder) { File.delete(lock_path) }) do
          heal([ row ])
        end
      end

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected review marker_healed event, got: #{@logger.events.inspect}"
      assert_equal "review_agent_died", heal_event[1][:reason]
      assert_equal "reviewers", heal_event[1][:phase]
      assert_equal "1", heal_event[1][:pass]
      refute File.exist?(lock_path), "stale review lock should be removed so recovery can run"
      refute_match(/REVIEW_WORKING|REVIEW_ERROR/, File.read(state_file),
                   "auto-recoverable stale review markers should clear so daemon can retry review")
    end
  end

  def test_review_working_live_lock_with_children_is_left_alone
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=fix pass=2 -->\n")
      File.write(File.join(File.dirname(state_file), ".lock"), {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "claude_pid" => 999_999
      }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "fix", "pass" => "2" },
        action: "agent_running",
        live_task_lock: true,
        **lock_identity(File.join(File.dirname(state_file), ".lock"))
      )

      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [ 12_345 ] }) do
        heal([ row ])
      end

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/REVIEW_WORKING/, File.read(state_file))
    end
  end

  def test_wedged_review_working_does_not_clear_newer_marker_generation
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 marker_id=newer -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      File.write(lock_path, {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "claude_pid" => 999_999
      }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1", "marker_id" => "older" },
        action: "agent_running",
        live_task_lock: true,
        **lock_identity(lock_path)
      )

      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [] }) do
        heal([ row ])
      end

      assert_match(/REVIEW_WORKING.*marker_id=newer/, File.read(state_file))
      assert File.exist?(lock_path), "a stale row must not release the newer review run's lock"
      refute @logger.events.any? { |name, _| name == :marker_healed }
    end
  end

  def test_wedged_review_working_does_not_terminate_replacement_lock_holder
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 marker_id=observed -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      File.write(lock_path, {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "lock_id" => "replacement-generation",
        "owner" => "replacement"
      }.to_yaml)
      row = make_row(
        state_file, pid_alive: false, stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1", "marker_id" => "observed" },
        action: "agent_running", live_task_lock: true,
        task_lock_pid: Process.pid,
        task_lock_process_start_time: Hive::Lock.process_start_time(Process.pid),
        task_lock_id: "observed-generation"
      )

      with_replaced_singleton_method(@healer, :terminate_lock_holder, ->(_holder) { flunk "replacement holder must not be terminated" }) do
        heal([ row ])
      end

      assert_match(/REVIEW_WORKING/, File.read(state_file))
      assert_equal "replacement", YAML.safe_load(File.read(lock_path)).fetch("owner")
      refute @logger.events.any? { |name, _| name == :marker_healed }
    end
  end

  def test_termination_does_not_kill_a_pid_reused_after_term
    signals = []
    starts = [ "observed-start", "observed-start", "replacement-start" ]
    holder = { "pid" => 12_345, "process_start_time" => "observed-start" }

    with_replaced_singleton_method(Process, :kill, lambda { |signal, pid|
      signals << [ signal, pid ]
      1
    }) do
      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { starts.shift }) do
        @healer.send(:terminate_lock_holder, holder)
      end
    end

    assert_includes signals, [ "TERM", 12_345 ]
    refute_includes signals, [ "KILL", 12_345 ],
                    "a replacement process reusing the pid must not receive KILL"
  end

  def test_wedged_review_working_keeps_marker_when_healer_cannot_claim_lock
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 marker_id=observed -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      File.write(lock_path, {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "claude_pid" => 999_999
      }.to_yaml)
      row = make_row(
        state_file, pid_alive: false, stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1", "marker_id" => "observed" },
        action: "agent_running", live_task_lock: true,
        **lock_identity(lock_path)
      )

      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [] }) do
        with_replaced_singleton_method(@healer, :terminate_lock_holder, ->(_holder) { nil }) do
          heal([ row ])
        end
      end

      assert_match(/REVIEW_WORKING.*marker_id=observed/, File.read(state_file))
      assert File.exist?(lock_path)
      refute @logger.events.any? { |name, _| name == :marker_healed }
    end
  end

  def test_review_working_heal_logs_failure_when_marker_clear_raises
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")
      File.write(File.join(File.dirname(state_file), ".lock"), {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "claude_pid" => 999_999
      }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1" },
        action: "agent_running",
        live_task_lock: true,
        **lock_identity(File.join(File.dirname(state_file), ".lock"))
      )

      original = Hive::Markers.method(:clear_current)
      Hive::Markers.define_singleton_method(:clear_current) do |path, **kwargs|
        raise Errno::ENOSPC, "no space left" if path == state_file

        original.call(path, **kwargs)
      end

      begin
        with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { [] }) do
          with_replaced_singleton_method(
            @healer, :terminate_lock_holder, ->(_holder) { File.delete(File.join(File.dirname(state_file), ".lock")) }
          ) do
            heal([ row ])
          end
        end
      ensure
        Hive::Markers.define_singleton_method(:clear_current, &original)
      end

      failure = @logger.events.find { |name, _| name == :marker_heal_failed }
      assert failure, "expected marker_heal_failed, got: #{@logger.events.inspect}"
      assert_equal "review_agent_died", failure[1][:reason]
      assert_match(/ENOSPC/, failure[1][:error])
    end
  end

  def test_review_working_skips_when_child_inspection_fails
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")
      File.write(File.join(File.dirname(state_file), ".lock"), {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "claude_pid" => 999_999
      }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1" },
        action: "agent_running",
        live_task_lock: true
      )

      with_replaced_singleton_method(@healer, :child_pids, ->(_pid) { nil }) do
        heal([ row ])
      end

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/REVIEW_WORKING/, File.read(state_file))
    end
  end

  # Case B: a signal kill (e.g. daemon restart SIGTERM/SIGKILL) tore down
  # the whole review tree, leaving REVIEW_WORKING with a stale .lock whose
  # holder is gone. live_task_lock is false. Past grace, the marker clears
  # and the stale lock is removed so the daemon re-dispatches review.
  def test_heals_orphaned_review_working_when_holder_is_gone_past_grace
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=triage pass=2 -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      File.write(lock_path, { "pid" => 999_999, "claude_pid" => 999_998 }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        mtime: NOW - 1000,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "triage", "pass" => "2" },
        action: "agent_running",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected orphaned review heal, got: #{@logger.events.inspect}"
      assert_equal "review_orphaned", heal_event[1][:reason]
      assert_equal "triage", heal_event[1][:phase]
      assert_equal "2", heal_event[1][:pass]
      refute File.exist?(lock_path), "stale review lock should be removed so the daemon re-dispatches"
      refute_match(/REVIEW_WORKING|REVIEW_ERROR/, File.read(state_file),
                   "orphaned REVIEW_WORKING should clear so review re-dispatches under the cap")
    end
  end

  def test_orphaned_review_working_does_not_clear_newer_marker_generation
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=triage pass=2 marker_id=newer -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      File.write(lock_path, {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid)
      }.to_yaml)
      row = make_row(
        state_file,
        pid_alive: false,
        mtime: NOW - 1000,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "triage", "pass" => "2", "marker_id" => "older" },
        action: "agent_running",
        live_task_lock: false
      )

      heal([ row ])

      assert_match(/REVIEW_WORKING.*marker_id=newer/, File.read(state_file))
      assert File.exist?(lock_path), "a stale row must not release the newer review run's lock"
      refute @logger.events.any? { |name, _| name == :marker_healed }
    end
  end

  def test_orphaned_review_working_does_not_delete_lock_acquired_after_status_snapshot
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=triage pass=2 marker_id=observed -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      row = make_row(
        state_file,
        pid_alive: false,
        mtime: NOW - 1000,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "triage", "pass" => "2", "marker_id" => "observed" },
        action: "agent_running",
        live_task_lock: false
      )
      File.write(lock_path, {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid),
        "owner" => "new_runner"
      }.to_yaml)

      heal([ row ])

      assert_match(/REVIEW_WORKING.*marker_id=observed/, File.read(state_file))
      assert_equal "new_runner", YAML.safe_load(File.read(lock_path)).fetch("owner")
      refute @logger.events.any? { |name, _| name == :marker_healed }
    end
  end

  def test_terminal_error_retries_do_not_clear_a_lock_acquired_after_status_snapshot
    [
      [ :error, "error", "git_status_failed", "4-execute", {} ],
      [ :review_error, "review_error", "review_agent_died", "6-review",
        { "phase" => "reviewers", "pass" => "1" } ]
    ].each do |marker_name, row_marker, reason, stage, extra_attrs|
      with_marker_file do |state_file|
        attrs = extra_attrs.merge("reason" => reason, "marker_id" => "observed")
        Hive::Markers.set(state_file, marker_name, attrs)
        lock_path = File.join(File.dirname(state_file), ".lock")
        File.write(lock_path, {
          "pid" => Process.pid,
          "process_start_time" => Hive::Lock.process_start_time(Process.pid),
          "owner" => "new_runner"
        }.to_yaml)
        row = make_row(
          state_file,
          pid_alive: nil,
          stage: stage,
          marker: row_marker,
          marker_attrs: Hive::Markers.current(state_file).attrs,
          action: row_marker == "error" ? "error" : "recover_review",
          live_task_lock: false
        )

        heal([ row ])

        assert_equal marker_name, Hive::Markers.current(state_file).name,
                     "#{row_marker} must survive a post-snapshot lock acquisition"
        assert_equal "new_runner", YAML.safe_load(File.read(lock_path)).fetch("owner")
        refute @logger.events.any? { |name, _| name == :marker_healed }
      end
    end
  end

  def test_orphaned_review_working_fails_closed_when_stale_lock_cannot_be_replaced
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=triage pass=2 -->\n")
      lock_path = File.join(File.dirname(state_file), ".lock")
      FileUtils.mkdir_p(lock_path)
      row = make_row(
        state_file,
        pid_alive: false,
        mtime: NOW - 1000,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "triage", "pass" => "2" },
        action: "agent_running",
        live_task_lock: false
      )

      heal([ row ])

      assert File.directory?(lock_path), "undeletable lock residue should be left for a later tick"
      assert_match(/REVIEW_WORKING/, File.read(state_file))
      failure = @logger.events.find { |name, _| name == :marker_heal_failed }
      assert failure, "expected fail-closed marker_heal_failed, got: #{@logger.events.inspect}"
      assert_equal "review_orphaned", failure[1][:reason]
    end
  end

  # Case B with no .lock at all (the holder died before/without recording
  # one, or a restart removed it): claude_pid_alive and live_task_lock are
  # both nil. Past grace, still healed; release_task_lock tolerates ENOENT.
  def test_heals_orphaned_review_working_with_no_lock_file
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: NOW - 1000,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1" },
        action: "agent_running",
        live_task_lock: nil
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected orphaned review heal with no lock, got: #{@logger.events.inspect}"
      assert_equal "review_orphaned", heal_event[1][:reason]
      refute_match(/REVIEW_WORKING/, File.read(state_file))
    end
  end

  # Guard against racing a runner that just set REVIEW_WORKING but hasn't
  # recorded its lock yet: within the grace window, leave it alone.
  def test_leaves_orphaned_review_working_within_grace
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=reviewers pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: NOW - 100,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "reviewers", "pass" => "1" },
        action: "agent_running",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "a freshly-set REVIEW_WORKING without a recorded lock yet must not be healed within grace"
      assert_match(/REVIEW_WORKING/, File.read(state_file))
    end
  end

  # Mirror of the Case A failure test for the orphaned (Case B) path: a
  # disk error while clearing the marker must log marker_heal_failed with
  # reason "review_orphaned" and never crash the tick.
  def test_orphaned_review_working_heal_logs_failure_when_marker_clear_raises
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_WORKING phase=triage pass=2 -->\n")
      row = make_row(
        state_file,
        pid_alive: false,
        mtime: NOW - 1000,
        stage: "6-review",
        marker: "review_working",
        marker_attrs: { "phase" => "triage", "pass" => "2" },
        action: "agent_running",
        live_task_lock: false
      )

      original = Hive::Markers.method(:clear_current)
      Hive::Markers.define_singleton_method(:clear_current) do |path, **kwargs|
        raise Errno::ENOSPC, "no space left" if path == state_file

        original.call(path, **kwargs)
      end

      begin
        heal([ row ])
      ensure
        Hive::Markers.define_singleton_method(:clear_current, &original)
      end

      failure = @logger.events.find { |name, _| name == :marker_heal_failed }
      assert failure, "expected marker_heal_failed, got: #{@logger.events.inspect}"
      assert_equal "review_orphaned", failure[1][:reason]
      assert_match(/ENOSPC/, failure[1][:error])
    end
  end

  def test_auto_recovers_reviewer_partial_failure_when_errors_are_tmux_session_terminated
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure pass=1 -->\n")
      reviews_dir = File.join(File.dirname(state_file), "reviews")
      FileUtils.mkdir_p(reviews_dir)
      File.write(
        File.join(reviews_dir, "errors-01.md"),
        "# Reviewer infra errors for pass 01\n\n" \
        "- [claude-ce-code-review] reviewer \"claude-ce-code-review\" failed: " \
        "tmux_session_terminated before writing expected output file: " \
        "#{File.join(reviews_dir, 'claude-ce-code-review-01.md')} after 2 attempt(s)\n"
      )
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "reviewer_partial_failure",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected auto-recovery event, got: #{@logger.events.inspect}"
      assert_equal "reviewer_tmux_session_terminated", heal_event[1][:reason]
      refute_match(/REVIEW_ERROR/, File.read(state_file),
                   "auto-recoverable reviewer tmux death should clear the marker so daemon can retry")
    end
  end

  def test_retries_reviewer_partial_failure_with_mixed_error_causes_after_cooldown
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure pass=1 -->\n")
      reviews_dir = File.join(File.dirname(state_file), "reviews")
      FileUtils.mkdir_p(reviews_dir)
      File.write(
        File.join(reviews_dir, "errors-01.md"),
        "# Reviewer infra errors for pass 01\n\n" \
        "- [claude-ce-code-review] reviewer \"claude-ce-code-review\" failed: " \
        "tmux_session_terminated before writing expected output file: #{File.join(reviews_dir, 'claude.md')}\n" \
        "- [codex-ce-code-review] reviewer \"codex-ce-code-review\" failed: quota exhausted\n"
      )
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "reviewer_partial_failure",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed }
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_retries_reviewer_partial_failure_when_errors_file_is_missing_after_cooldown
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "reviewer_partial_failure",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed }
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_reviewer_partial_failure_retry_does_not_depend_on_errors_file
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=reviewer_partial_failure pass=1 -->\n")
      reviews_dir = File.join(File.dirname(state_file), "reviews")
      FileUtils.mkdir_p(reviews_dir)
      errors_path = File.join(reviews_dir, "errors-01.md")
      File.write(
        errors_path,
        "- [claude-ce-code-review] reviewer \"claude-ce-code-review\" failed: " \
        "tmux_session_terminated before writing expected output file: #{File.join(reviews_dir, 'claude.md')}\n"
      )
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "reviewer_partial_failure",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      original = File.method(:read)
      File.define_singleton_method(:read) do |path, *args, **kwargs|
        raise Errno::ENOENT, path if path == errors_path

        original.call(path, *args, **kwargs)
      end

      begin
        heal([ row ])
      ensure
        File.define_singleton_method(:read, &original)
      end

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected auto-recovery event, got: #{@logger.events.inspect}"
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_auto_recovers_review_error_review_agent_died
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "review_agent_died",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected review_agent_died auto-recovery event, got: #{@logger.events.inspect}"
      assert_equal "review_agent_died", heal_event[1][:reason]
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_every_classified_review_reason_retries_after_cooldown
    reasons = Hive::ReviewErrorReason::CLASSIFIED + [ "unknown" ]

    reasons.product(%w[triage fix reviewers]).each do |reason, phase|
      with_marker_file do |state_file|
        File.write(state_file,
                   "# task\n\n<!-- REVIEW_ERROR phase=#{phase} reason=#{reason} pass=1 -->\n")
        row = make_row(
          state_file,
          pid_alive: nil,
          stage: "6-review",
          marker: "review_error",
          marker_attrs: { "phase" => phase, "reason" => reason, "pass" => "1" },
          action: "recover_review",
          live_task_lock: false
        )

        healed_before = @logger.events.count { |name, _| name == :marker_healed }
        heal([ row ])

        refute_match(/REVIEW_ERROR/, File.read(state_file),
                     "classified reason #{reason.inspect} on phase #{phase.inspect} must retry after cooldown")
        assert_equal healed_before + 1,
                     @logger.events.count { |name, _| name == :marker_healed },
                     "expected a heal for #{reason.inspect}/#{phase.inspect}; events: #{@logger.events.inspect}"
      end
    end
  end

  # --- limits_reached cooldown auto-retry (review path) ----------------

  def make_review_limit_row(state_file, retry_after:, pass: "1", mtime: NOW - 1000)
    marker_attrs = { "phase" => "reviewers", "reason" => "limits_reached", "pass" => pass }
    marker_attrs["retry_after"] = retry_after unless retry_after.nil?
    make_row(
      state_file,
      pid_alive: nil,
      mtime: mtime,
      stage: "6-review",
      marker: "review_error",
      marker_attrs: marker_attrs,
      action: "recover_review",
      live_task_lock: false
    )
  end

  def write_review_limit_marker(state_file, retry_after:)
    attrs = retry_after ? " retry_after=#{retry_after}" : ""
    File.write(state_file,
               "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=limits_reached pass=1#{attrs} -->\n")
  end

  def test_agent_limit_wire_message_marks_review_hold_and_respects_cooldown_boundary
    with_marker_file do |state_file|
      File.write(state_file, "# task\n")
      message = "limits reached for claude: Claude Code v2.1.170"
      task = Struct.new(:state_file).new(state_file)

      assert Hive::AgentLimit.from_limit?(message)
      limited = Hive::Stages::Review.send(
        :mark_review_phase_failure,
        task,
        phase: :triage,
        pass: 1,
        error_message: message
      )

      marker = Hive::Markers.current(state_file)
      attrs = marker.attrs
      assert limited
      assert_equal :review_error, marker.name
      assert_equal "limits_reached", attrs.fetch("reason")
      assert Time.parse(attrs.fetch("retry_after")) > Time.now.utc - 5
      assert Hive::AgentLimit.held?(:review_error, attrs)

      retry_after = Time.parse(attrs.fetch("retry_after"))
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: retry_after - Hive::AgentLimit.retry_cooldown_sec,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: attrs,
        action: "recover_review",
        live_task_lock: false
      )
      refute @healer.send(:limit_retry_due?, row, now: retry_after - 1),
             "cooldown must not be elapsed before retry_after"
      assert @healer.send(:limit_retry_due?, row, now: retry_after),
             "cooldown must be elapsed at retry_after"
    end
  end

  def test_does_not_auto_recover_review_limits_reached_before_cooldown
    with_marker_file do |state_file|
      future = (NOW + 600).iso8601
      write_review_limit_marker(state_file, retry_after: future)
      row = make_review_limit_row(state_file, retry_after: future)

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "limits_reached must stay red until the cooldown elapses"
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      assert_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_auto_recovers_review_limits_reached_once_cooldown_has_elapsed
    with_marker_file do |state_file|
      past = (NOW - 60).iso8601
      write_review_limit_marker(state_file, retry_after: past)
      row = make_review_limit_row(
        state_file,
        retry_after: past,
        mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected limits_reached auto-recovery, got: #{@logger.events.inspect}"
      assert_equal "reviewer_limits_reached", heal_event[1][:reason]
      assert_equal 1, heal_event[1][:attempts]
      refute_match(/REVIEW_ERROR/, File.read(state_file),
                   "elapsed-cooldown limits_reached must clear so review re-dispatches")
    end
  end

  def test_auto_recovers_review_limits_reached_hourly_before_provider_reset
    with_marker_file do |state_file|
      future = (NOW + 5 * 86_400).iso8601
      write_review_limit_marker(state_file, retry_after: future)
      row = make_review_limit_row(
        state_file,
        retry_after: future,
        mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed },
             "a distant provider reset must still allow an hourly readiness attempt"
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_auto_recovers_review_limits_reached_exactly_at_hourly_boundary
    with_marker_file do |state_file|
      now_stamp = NOW.iso8601
      write_review_limit_marker(state_file, retry_after: now_stamp)
      row = make_review_limit_row(
        state_file,
        retry_after: now_stamp,
        mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed },
             "marker age equal to the retry interval must be treated as elapsed (>=)"
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_auto_recovers_review_limits_reached_without_retry_after_after_hour
    with_marker_file do |state_file|
      write_review_limit_marker(state_file, retry_after: nil)
      row = make_review_limit_row(
        state_file,
        retry_after: nil,
        mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed },
             "the hourly readiness schedule must not depend on a reset hint"
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_auto_recovers_review_limits_reached_with_unparseable_retry_after_after_hour
    with_marker_file do |state_file|
      write_review_limit_marker(state_file, retry_after: "not-a-timestamp")
      row = make_review_limit_row(
        state_file,
        retry_after: "not-a-timestamp",
        mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed },
             "a malformed display hint must not disable the hourly readiness schedule"
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_review_limits_reached_retries_do_not_exhaust_recovery_budget
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      review_error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      past = (NOW - 60).iso8601

      3.times do
        write_review_limit_marker(state_file, retry_after: past)
        heal([ make_review_limit_row(
          state_file,
          retry_after: past,
          mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
        ) ])
        refute_match(/REVIEW_ERROR/, File.read(state_file),
                     "quota readiness attempts must remain available after ordinary recovery is exhausted")
      end

      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 3, heals.size
      assert_equal [ 1, 2, 3 ], heals.map { |_, attrs| attrs[:attempts] }
      assert heals.all? { |_, attrs| attrs[:reason] == "reviewer_limits_reached" }

      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_empty exhausted
    end
  end

  # --- limits_reached cooldown auto-retry (ERROR path) -----------------

  def make_error_limit_row(state_file, retry_after:, stage: "4-execute", mtime: NOW - 1000)
    marker_attrs = { "reason" => "limits_reached" }
    marker_attrs["retry_after"] = retry_after unless retry_after.nil?
    make_row(
      state_file,
      pid_alive: nil,
      mtime: mtime,
      stage: stage,
      marker: "error",
      marker_attrs: marker_attrs,
      action: "error",
      live_task_lock: false
    )
  end

  def write_error_limit_marker(state_file, retry_after:)
    attrs = retry_after ? " retry_after=#{retry_after}" : ""
    File.write(state_file, "# task\n\n<!-- ERROR reason=limits_reached#{attrs} -->\n")
  end

  def test_does_not_auto_recover_error_limits_reached_before_cooldown
    with_marker_file do |state_file|
      future = (NOW + 600).iso8601
      write_error_limit_marker(state_file, retry_after: future)
      row = make_error_limit_row(state_file, retry_after: future)

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed },
             "terminal limits_reached must stay red until the cooldown elapses"
      assert_match(/ERROR reason=limits_reached/, File.read(state_file))
    end
  end

  def test_auto_recovers_error_limits_reached_once_cooldown_has_elapsed_any_stage
    %w[1-brainstorm 4-execute 8-finalize].each do |stage|
      with_marker_file do |state_file|
        past = (NOW - 60).iso8601
        write_error_limit_marker(state_file, retry_after: past)
        row = make_error_limit_row(
          state_file,
          retry_after: past,
          stage: stage,
          mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
        )

        heal([ row ])

        heal_event = @logger.events.last
        assert_equal :marker_healed, heal_event[0],
                     "#{stage} limits_reached should clear after cooldown"
        assert_equal "limits_reached", heal_event[1][:reason]
        assert_equal "limits_reached", heal_event[1][:marker_reason]
        assert_equal stage, heal_event[1][:stage]
        assert Hive::Markers.current(state_file).none?,
               "#{stage} limits_reached must clear so the daemon re-dispatches"
      end
    end
  end

  def test_auto_recovers_error_limits_reached_hourly_before_provider_reset
    with_marker_file do |state_file|
      future = (NOW + 5 * 86_400).iso8601
      write_error_limit_marker(state_file, retry_after: future)
      row = make_error_limit_row(
        state_file,
        retry_after: future,
        mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed },
             "a distant provider reset must still allow an hourly readiness attempt"
      assert Hive::Markers.current(state_file).none?
    end
  end

  def test_error_cooldown_recovery_purges_shadowed_working_and_error_markers
    with_marker_file do |state_file|
      past = (NOW - 60).iso8601
      File.write(state_file, <<~MD)
        # task

        <!-- AGENT_WORKING pid=100 started=2026-05-20T10:00:00Z -->
        <!-- ERROR reason=limits_reached retry_after=2026-05-20T10:30:00Z -->
        <!-- AGENT_WORKING pid=200 started=2026-05-20T11:00:00Z -->
        <!-- ERROR reason=limits_reached retry_after=#{past} -->
      MD
      row = make_error_limit_row(
        state_file,
        retry_after: past,
        stage: "2-generate",
        mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
      )

      heal([ row ])

      assert Hive::Markers.current(state_file).none?,
             "a successful retry clear must not expose a stale working/error marker"
      refute_match Hive::Markers::MARKER_RE, File.read(state_file)
      assert @logger.events.any? { |name, attrs| name == :marker_healed && attrs[:reason] == "limits_reached" }
    end
  end

  def test_auto_recovers_error_limits_reached_without_retry_after_after_hour
    with_marker_file do |state_file|
      write_error_limit_marker(state_file, retry_after: nil)
      row = make_error_limit_row(
        state_file,
        retry_after: nil,
        mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed },
             "the hourly readiness schedule must not depend on a reset hint"
      assert Hive::Markers.current(state_file).none?
    end
  end

  def test_auto_recovers_error_limits_reached_with_unparseable_retry_after_after_hour
    with_marker_file do |state_file|
      write_error_limit_marker(state_file, retry_after: "garbled")
      row = make_error_limit_row(
        state_file,
        retry_after: "garbled",
        mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed },
             "a malformed display hint must not disable the hourly readiness schedule"
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      assert Hive::Markers.current(state_file).none?
    end
  end

  def test_error_limits_reached_retries_do_not_exhaust_recovery_budget
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      past = (NOW - 60).iso8601

      3.times do
        write_error_limit_marker(state_file, retry_after: past)
        heal([ make_error_limit_row(
          state_file,
          retry_after: past,
          mtime: NOW - Hive::AgentLimit::RETRY_COOLDOWN_SEC
        ) ])
        assert Hive::Markers.current(state_file).none?,
               "quota readiness attempts must remain available after ordinary recovery is exhausted"
      end

      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 3, heals.size
      assert_equal [ 1, 2, 3 ], heals.map { |_, attrs| attrs[:attempts] }
      assert heals.all? { |_, attrs| attrs[:reason] == "limits_reached" }

      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_empty exhausted
    end
  end

  def test_auto_recovers_finalize_unpushed_commits_error
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits detail=\"push failed\" marker_id=err-a -->\n")
      # Explicit non-default mtime so the observed_mtimes assertion below
      # actually pins that observe_pre_clear_mtime forwards the row's own
      # state_file_mtime — not the make_row default, which would pass even
      # if the pass-through were hard-coded.
      pre_clear_mtime = NOW - 4242
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: pre_clear_mtime,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: {
          "reason" => "unpushed_commits",
          "detail" => "push failed",
          "marker_id" => "err-a"
        },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected finalize unpushed auto-recovery event, got: #{@logger.events.inspect}"
      assert_equal "finalize_unpushed_commits", heal_event[1][:reason]
      assert_equal "unpushed_commits", heal_event[1][:marker_reason]
      assert_equal 1, heal_event[1][:attempts]
      assert_equal [ { project: "p", slug: "s", mtime: pre_clear_mtime } ], @controller.observed_mtimes
      assert Hive::Markers.current(state_file).none?,
             "auto-recoverable unpushed finalize marker should clear to :none so daemon can rerun finalize"
    end
  end

  # ── Generic-workflow heal paths (cover the coding-id gates) ────────────────

  def test_generic_finalize_unpushed_commits_retries_after_cooldown
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=err-g -->\n")
      row = make_row(
        state_file, pid_alive: nil,
        mtime: NOW - Hive::AgentLimit.retry_cooldown_sec - 1,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "err-g" },
        action: "error", live_task_lock: false, workflow: "research"
      )

      heal([ row ])

      assert(@logger.events.any? { |name, _| name == :marker_healed },
             "a generic 8-finalize error must retry after the shared cooldown")
      assert Hive::Markers.current(state_file).none?
    end
  end

  def test_generic_review_agent_loss_auto_recovers_unlike_coding
    # Coding EXCLUDES 6-review from generic agent-loss recovery (it has its own
    # REVIEW_ERROR heal paths). A generic workflow reusing 6-review has no such
    # specialized path, so an agent-loss error DOES heal there.
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated marker_id=err-r -->\n")
      row = make_row(
        state_file, pid_alive: nil,
        mtime: NOW - Hive::AgentLimit.retry_cooldown_sec - 1,
        stage: "6-review",
        marker: "error",
        marker_attrs: { "reason" => "tmux_session_terminated", "marker_id" => "err-r" },
        action: "error", live_task_lock: false, workflow: "research"
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "a generic 6-review agent-loss error should heal (no coding review exclusion)"
      assert_equal "agent_loss_retry", heal_event[1][:reason]
      assert Hive::Markers.current(state_file).none?,
             "generic 6-review agent-loss marker clears so the daemon can rerun the stage"
    end
  end

  def test_generic_plan_stage_error_heals_without_requeue
    # The 3-plan post-clear requeue is a coding-only fixup (an empty coding
    # plan.md re-classifies straight back to error). A generic 3-plan agent-loss
    # error still heals, but must NOT enqueue the coding `hive plan` rerun.
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=agent_orphaned marker_id=err-p -->\n")
      row = make_row(
        state_file, pid_alive: nil,
        mtime: NOW - Hive::AgentLimit.retry_cooldown_sec - 1,
        stage: "3-plan",
        marker: "error",
        marker_attrs: { "reason" => "agent_orphaned", "marker_id" => "err-p" },
        action: "error", live_task_lock: false, workflow: "research"
      )

      heal([ row ])

      assert(@logger.events.any? { |name, _| name == :marker_healed },
             "a generic 3-plan agent-loss error should still heal")
      assert_empty @request_queue.requests,
                   "the coding plan rerun requeue must not fire for a generic workflow"
    end
  end

  def test_limits_cooldown_heal_on_plan_stage_also_requeues
    with_marker_file do |state_file|
      retry_at = (NOW - 60).utc.iso8601
      File.write(state_file,
                 "# t\n\n<!-- ERROR reason=limits_reached retry_after=#{retry_at} marker_id=lm1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil, mtime: NOW - 5151, stage: "3-plan", marker: "error",
        marker_attrs: { "reason" => "limits_reached", "retry_after" => retry_at, "marker_id" => "lm1" },
        action: "error", live_task_lock: false
      )

      heal([ row ])

      assert(@logger.events.any? { |name, _| name == :marker_healed })
      refute_empty @request_queue.requests,
                   "a limits cooldown heal leaves the same markerless empty plan.md as "                    "agent loss — without the requeue the task strands identically"
    end
  end

  def test_requeue_failure_leaves_original_error_intact
    failing_queue = Class.new do
      def write_request!(**)
        raise Errno::ENOSPC, "no space left on device"
      end
    end.new
    healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller, logger: @logger, grace_sec: 300,
      request_queue: failing_queue
    )

    with_marker_file do |state_file|
      File.write(state_file, "# t\n\n<!-- ERROR reason=tmux_session_terminated marker_id=rq1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil, mtime: NOW - 5151, stage: "3-plan", marker: "error",
        marker_attrs: { "reason" => "tmux_session_terminated", "marker_id" => "rq1" },
        action: "error", live_task_lock: false
      )

      healer.heal([ row ], now: NOW)

      names = @logger.events.map(&:first)
      refute_includes names, :marker_healed,
                      "the marker must not clear before its continuation is durable"
      assert_includes names, :heal_requeue_failed,
                      "the durable enqueue failure needs its own truthful event"
      refute_includes names, :marker_heal_failed,
                      "the queue event owns the enqueue failure"
      requeue_event = @logger.events.find { |name, _| name == :heal_requeue_failed }[1]
      assert_match(/hive plan/, requeue_event[:remediation],
                   "the operator needs the manual re-entry command")
      current = Hive::Markers.current(state_file)
      assert_equal :error, current.name
      assert_equal "tmux_session_terminated", current.attrs.fetch("reason")
      assert_equal "rq1", current.attrs.fetch("marker_id"),
                   "enqueue failure must leave the original marker generation untouched"
    end
  end

  def test_plan_requeue_survives_success_audit_failures
    logger = Class.new do
      def event(name, **)
        raise "logger unavailable" if %i[marker_healed heal_requeued].include?(name)
      end
    end.new
    healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller, logger: logger, grace_sec: 300,
      request_queue: @request_queue
    )

    with_marker_file do |state_file|
      File.write(
        state_file,
        "# plan\n\n<!-- ERROR reason=agent_orphaned marker_id=audit-failure -->\n"
      )
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "3-plan",
        marker: "error",
        marker_attrs: {
          "reason" => "agent_orphaned",
          "marker_id" => "audit-failure"
        },
        action: "error",
        live_task_lock: false
      )

      healer.heal([ row ], now: NOW)

      assert Hive::Markers.current(state_file).none?
      assert_equal 1, @request_queue.requests.size
    end
  end

  def test_plan_requeue_survives_failure_audit_failure
    failing_queue = Class.new do
      def write_request!(**)
        raise Errno::ENOSPC, "no space left on device"
      end
    end.new
    logger = Class.new do
      def event(name, **)
        raise "logger unavailable" if name == :heal_requeue_failed
      end
    end.new
    healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller, logger: logger, grace_sec: 300,
      request_queue: failing_queue
    )

    with_marker_file do |state_file|
      row = make_row(state_file, pid_alive: nil, stage: "3-plan")

      refute healer.send(:requeue_plan_rerun, row, trigger: "error_retry")
    end
  end

  def test_plan_retry_cancel_failure_is_audited
    queue = Object.new
    queue.define_singleton_method(:remove_if_unclaimed) do |_request_id|
      raise Errno::ENOSPC, "no space left on device"
    end
    healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller, logger: @logger, grace_sec: 300,
      request_queue: queue
    )

    healer.send(:remove_plan_retry_if_unclaimed, "request-1")

    event = @logger.events.find { |name, _| name == :marker_heal_failed }
    refute_nil event
    assert_equal "plan_retry_cancel_failed", event[1].fetch(:reason)
    assert_match(/ENOSPC/, event[1].fetch(:error))
  end

  def test_auto_recovers_terminal_agent_loss_error_matrix
    # Every stage except 6-review: the sweep-kills-the-server incident took
    # out parallel BRAINSTORMS, and a rerun resumes from on-disk artifacts.
    %w[2-brainstorm 3-plan 4-execute 7-artifacts 8-finalize].product(%w[tmux_session_terminated agent_orphaned]).each_with_index do |(stage, reason), index|
      with_marker_file do |state_file|
        marker_id = "terminal-#{index}"
        File.write(state_file, "# task\n\n<!-- ERROR reason=#{reason} marker_id=#{marker_id} -->\n")
        pre_clear_mtime = NOW - 5151 - index
        row = make_row(
          state_file,
          pid_alive: nil,
          mtime: pre_clear_mtime,
          stage: stage,
          marker: "error",
          marker_attrs: { "reason" => reason, "marker_id" => marker_id },
          action: "error",
          live_task_lock: false
        )

        heal([ row ])

        heal_event = @logger.events.reverse.find { |e| e[0] == :marker_healed }
        refute_nil heal_event, "#{stage}/#{reason} must log marker_healed"
        assert_equal "agent_loss_retry", heal_event[1][:reason]
        assert_equal reason, heal_event[1][:marker_reason]
        assert_equal stage, heal_event[1][:stage]
        assert_equal 1, heal_event[1][:attempts]
        assert_equal({ project: "p", slug: "s", mtime: pre_clear_mtime }, @controller.observed_mtimes.last)
        assert Hive::Markers.current(state_file).none?,
               "#{stage}/#{reason} ERROR should clear so the daemon can rerun the stage"

        if stage == "3-plan"
          req = @request_queue.requests.last
          refute_nil req, "3-plan heal must enqueue a plan rerun - a markerless empty plan.md "                           "classifies straight back to :error and nothing else can re-enter the stage"
          assert_equal [ "hive", "plan", "s", "--project", "p", "--from", "3-plan" ], req[:argv]
          assert_equal "healer", req[:requestor]
          assert_equal 42, req[:task_id]
          assert_equal "3-plan", req[:expected_stage]
          assert_equal "error", req[:expected_marker_name]
          assert_equal marker_id, req[:expected_marker_id]
          refute_empty req[:task_generation].to_s,
                       "the queued continuation must be bound to the predicted post-clear artifact"
          assert_equal :heal_requeued, @logger.events.last[0],
                       "the requeue must be logged so operators can trace the rerun to its heal"
        end
      end
    end
    plan_requeues = @request_queue.requests.size
    assert_equal 2, plan_requeues,
                 "ONLY the two 3-plan heals may requeue (other stages re-enter via the edit-resume path)"
  end

  def test_error_agent_loss_recovery_includes_review_stage
    %w[tmux_session_terminated agent_orphaned].each do |reason|
      with_marker_file do |state_file|
        File.write(state_file, "# task\n\n<!-- ERROR reason=#{reason} -->\n")
        row = make_row(
          state_file,
          pid_alive: nil,
          stage: "6-review",
          marker: "error",
          marker_attrs: { "reason" => reason },
          action: "error",
          live_task_lock: false
        )

        heal([ row ])

        assert @logger.events.any? { |name, _| name == :marker_healed },
               "6-review/#{reason} must retry after the shared cooldown"
        refute @logger.events.any? { |name, _| name == :marker_heal_failed }
        refute_match(/ERROR reason=#{reason}/, File.read(state_file))
      end
    end
  end

  def test_terminal_agent_loss_recovery_uses_marker_id_guard_when_present
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated marker_id=newer -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "tmux_session_terminated", "marker_id" => "older" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/ERROR reason=tmux_session_terminated marker_id=newer/, File.read(state_file),
                   "a stale status row must not clear a newer same-reason ERROR marker")
    end
  end

  def test_terminal_agent_loss_recovery_skips_live_lock
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=agent_orphaned -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "agent_orphaned" },
        action: "error",
        live_task_lock: true
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a live-lock skip must be a clean no-op, not a logged failure"
      assert_match(/ERROR reason=agent_orphaned/, File.read(state_file))
    end
  end

  def test_git_status_failed_retries_after_cooldown
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=git_status_failed -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "git_status_failed" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a repository-state retry should clear cleanly"
      refute_match(/ERROR reason=git_status_failed/, File.read(state_file))
    end
  end

  def test_agent_loss_retries_beyond_legacy_budget
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "tmux_session_terminated" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated -->\n")
      heal([ row ])
      refute_match(/ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated -->\n")
      heal([ row ])

      refute_match(/ERROR reason=tmux_session_terminated/, File.read(state_file),
                   "agent loss must remain retryable beyond the old budget")
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 2, heals.size
      assert heals.all? { |_name, attrs| attrs[:reason] == "agent_loss_retry" }
      assert heals.all? { |_name, attrs| attrs[:max_attempts].nil? }
      assert_empty @logger.events.select { |name, _| name == :marker_heal_exhausted }
    end
  end

  def test_agent_loss_fresh_marker_ids_remain_retryable
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      first = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "tmux_session_terminated", "marker_id" => "err-a" },
        action: "error",
        live_task_lock: false
      )
      second = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "tmux_session_terminated", "marker_id" => "err-b" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated marker_id=err-a -->\n")
      heal([ first ])
      refute_match(/ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- ERROR reason=tmux_session_terminated marker_id=err-b -->\n")
      heal([ second ])

      refute_match(/ERROR reason=tmux_session_terminated marker_id=err-b/, File.read(state_file),
                   "a fresh marker id must remain retryable")
      heals = @logger.events.select { |name, _| name == :marker_healed }
      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_equal 2, heals.size
      assert_empty exhausted
    end
  end

  def test_finalize_unpushed_recovery_uses_marker_id_guard_when_present
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=newer -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: {
          "reason" => "unpushed_commits",
          "marker_id" => "older"
        },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/ERROR reason=unpushed_commits marker_id=newer/, File.read(state_file),
                   "a stale status row must not clear a newer same-reason ERROR marker")
    end
  end

  def test_finalize_unpushed_recovery_clears_legacy_marker_without_marker_id
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected legacy finalize marker to clear, got: #{@logger.events.inspect}"
      assert Hive::Markers.current(state_file).none?,
             "legacy no-marker_id finalize marker should clear to :none"
    end
  end

  def test_finalize_unpushed_recovery_does_not_clear_modern_marker_when_row_lacks_marker_id
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=modern -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/ERROR reason=unpushed_commits marker_id=modern/, File.read(state_file),
                   "a row without marker_id must not clear a current marker that has one")
    end
  end

  def test_finalize_unpushed_recovery_does_not_clear_marker_that_gains_id_after_snapshot
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=fresh -->\n")
      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      assert_match(/ERROR reason=unpushed_commits marker_id=fresh/, File.read(state_file),
                   "a legacy row snapshot must not clear a modern marker written before heal")
    end
  end

  def test_error_with_missing_marker_attrs_retries_after_cooldown
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: nil,
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      refute_match(/ERROR/, File.read(state_file))
    end
  end

  def test_finalize_unpushed_recovery_skips_when_state_file_mtime_is_missing
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        mtime: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      assert_match(/ERROR reason=unpushed_commits/, File.read(state_file),
                   "without a pre-clear mtime the healer cannot seed redispatch safely")
    end
  end

  def test_does_not_auto_recover_finalize_unpushed_commits_with_live_lock
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: true
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a live-lock skip must be a clean no-op, not a logged failure"
      assert_match(/ERROR reason=unpushed_commits/, File.read(state_file))
    end
  end

  def test_unpushed_commits_outside_finalize_retries_after_cooldown
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a wrong-stage error retry should clear cleanly"
      refute_match(/ERROR reason=unpushed_commits/, File.read(state_file))
    end
  end

  def test_dirty_worktree_retries_after_cooldown
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=dirty_worktree -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "dirty_worktree" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a dirty-worktree retry should clear cleanly"
      refute_match(/ERROR reason=dirty_worktree/, File.read(state_file))
    end
  end

  def test_finalize_unpushed_commits_retries_beyond_legacy_budget
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      heal([ row ])
      refute_match(/ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      heal([ row ])

      refute_match(/ERROR reason=unpushed_commits/, File.read(state_file),
                   "finalize push failure must remain retryable beyond the old budget")
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 2, heals.size
      assert_equal 1, heals.first[1][:attempts]
      assert_nil heals.first[1][:max_attempts]
      assert_empty @logger.events.select { |name, _| name == :marker_heal_exhausted }
    end
  end

  def test_finalize_unpushed_fresh_marker_ids_remain_retryable
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=err-a -->\n")
      first = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "err-a" },
        action: "error",
        live_task_lock: false
      )
      heal([ first ])
      refute_match(/ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=err-b -->\n")
      second = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "err-b" },
        action: "error",
        live_task_lock: false
      )
      heal([ second ])

      refute_match(/ERROR reason=unpushed_commits marker_id=err-b/, File.read(state_file),
                   "fresh marker ids from repeated finalize failures remain retryable")
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 2, heals.size
      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_empty exhausted
    end
  end

  def test_finalize_unpushed_recovery_budget_is_isolated_per_task
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    Dir.mktmpdir do |dir|
      first_file = File.join(dir, "first.md")
      second_file = File.join(dir, "second.md")
      File.write(first_file, "# first\n\n<!-- ERROR reason=unpushed_commits -->\n")
      File.write(second_file, "# second\n\n<!-- ERROR reason=unpushed_commits -->\n")

      first = make_row(
        first_file,
        pid_alive: nil,
        project: "p",
        slug: "first",
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )
      second = make_row(
        second_file,
        pid_alive: nil,
        project: "p",
        slug: "second",
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ first, second ])

      refute_match(/ERROR/, File.read(first_file))
      refute_match(/ERROR/, File.read(second_file))
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 2, heals.size
      assert_equal %w[first second], heals.map { |_, attrs| attrs[:slug] }.sort
    end
  end

  def test_finalize_unpushed_clear_false_consumes_no_budget_and_emits_no_event
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      # On-disk marker is NEWER than the stale status row's marker_id, so
      # the reason matches but the marker_id guard makes clear_current
      # return false. That branch must be a pure no-op: no event of any
      # kind, and crucially no retry budget consumed.
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=newer -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "older" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      assert_empty @logger.events,
                   "a clear_current=false skip must emit no event at all, got: #{@logger.events.inspect}"
      assert_empty @controller.observed_mtimes,
                   "no mtime baseline should be seeded when nothing was cleared"

      # The single retry budget must be intact: once the on-disk marker
      # matches the row again, the same task still heals on the first try.
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=older -->\n")
      matching = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "older" },
        action: "error",
        live_task_lock: false
      )
      heal([ matching ])

      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 1, heals.size,
                   "the earlier clear_current=false must not have consumed the single retry budget"
      assert Hive::Markers.current(state_file).none?
    end
  end

  def test_finalize_unpushed_duplicate_rows_in_same_heal_pass_consume_one_budget_slot
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits marker_id=err-a -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits", "marker_id" => "err-a" },
        action: "error",
        live_task_lock: false
      )

      heal([ row, row ])

      assert Hive::Markers.current(state_file).none?
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 1, heals.size
      assert_equal 1, heals.first[1][:attempts]
      refute @logger.events.any? { |name, _| name == :marker_heal_failed }
      refute @logger.events.any? { |name, _| name == :marker_heal_exhausted }
    end
  end

  def test_finalize_unpushed_remains_retryable_across_healer_instances
    row_attrs = {
      pid_alive: nil,
      stage: "8-finalize",
      marker: "error",
      marker_attrs: { "reason" => "unpushed_commits" },
      action: "error",
      live_task_lock: false
    }

    with_marker_file do |state_file|
      first = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300,
        error_auto_recovery_limit: 1
      )
      row = make_row(state_file, **row_attrs)

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      first.heal([ row ], now: NOW)
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      first.heal([ row ], now: NOW)
      assert Hive::Markers.current(state_file).none?,
             "the existing healer must never exhaust retries"

      fresh = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300,
        error_auto_recovery_limit: 1
      )
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      fresh.heal([ row ], now: NOW)

      assert Hive::Markers.current(state_file).none?,
             "a fresh healer instance must preserve the same unbounded policy"
    end
  end

  def test_finalize_unpushed_auto_recovery_logs_failure_when_marker_clear_raises
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      original = Hive::Markers.method(:clear_current)
      Hive::Markers.define_singleton_method(:clear_current) do |path, **kwargs|
        raise Errno::ENOSPC, "no space left" if path == state_file

        original.call(path, **kwargs)
      end

      begin
        heal([ row ])
      ensure
        Hive::Markers.define_singleton_method(:clear_current, &original)
      end

      failure = @logger.events.find { |name, _| name == :marker_heal_failed }
      assert failure, "expected marker_heal_failed, got: #{@logger.events.inspect}"
      assert_equal "finalize_unpushed_commits", failure[1][:reason]
      assert_match(/ENOSPC/, failure[1][:error])
    end
  end

  def test_review_error_recovery_does_not_clear_newer_marker_generation
    with_marker_file do |state_file|
      File.write(
        state_file,
        "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 marker_id=newer -->\n"
      )
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "review_agent_died",
          "pass" => "1",
          "marker_id" => "older"
        },
        action: "recover_review",
        live_task_lock: false
      )

      heal([ row ])

      assert_match(/REVIEW_ERROR.*marker_id=newer/, File.read(state_file))
      refute @logger.events.any? { |name, _| name == :marker_healed }
    end
  end

  def test_does_not_auto_recover_review_error_review_agent_died_with_live_lock
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "review_agent_died",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: true
      )

      heal([ row ])

      refute @logger.events.any? { |name, _| name == :marker_healed }
      refute @logger.events.any? { |name, _| name == :marker_heal_failed },
             "a review live-lock skip must be a clean no-op, not a logged failure"
      assert_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_review_error_retries_beyond_legacy_budget
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      review_error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "review_agent_died",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 -->\n")
      heal([ row ])
      refute_match(/REVIEW_ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 -->\n")
      heal([ row ])

      refute_match(/REVIEW_ERROR/, File.read(state_file),
                   "review errors must remain retryable beyond the old budget")
      heals = @logger.events.select { |name, _| name == :marker_healed }
      assert_equal 2, heals.size
      assert_equal 1, heals.first[1][:attempts]
      assert_nil heals.first[1][:max_attempts]
      assert_empty @logger.events.select { |name, _| name == :marker_heal_exhausted }
    end
  end

  def test_review_error_auto_recovery_logs_failure_when_marker_clear_raises
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=review_agent_died pass=1 -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "6-review",
        marker: "review_error",
        marker_attrs: {
          "phase" => "reviewers",
          "reason" => "review_agent_died",
          "pass" => "1"
        },
        action: "recover_review",
        live_task_lock: false
      )

      original = Hive::Markers.method(:clear_current)
      Hive::Markers.define_singleton_method(:clear_current) do |path, **kwargs|
        raise Errno::ENOSPC, "no space left" if path == state_file

        original.call(path, **kwargs)
      end

      begin
        heal([ row ])
      ensure
        Hive::Markers.define_singleton_method(:clear_current, &original)
      end

      failure = @logger.events.find { |name, _| name == :marker_heal_failed }
      assert failure, "expected marker_heal_failed, got: #{@logger.events.inspect}"
      assert_equal "review_agent_died", failure[1][:reason],
                   "a heal failure on a review_agent_died marker must keep its own " \
                   "label, not be mislabeled as the tmux-death channel"
      assert_match(/ENOSPC/, failure[1][:error])
    end
  end

  def test_finalize_unpushed_logs_when_controller_cannot_seed_pre_clear_mtime
    controller = Object.new
    def controller.running_task?(project:, slug:) = false
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: controller,
      logger: @logger,
      grace_sec: 300
    )

    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      heal([ row ])

      missing = @logger.events.find { |name, _| name == :marker_heal_observer_missing }
      assert missing, "expected observer-missing event, got: #{@logger.events.inspect}"
      assert_equal "p", missing[1][:project]
      assert_equal "s", missing[1][:slug]
      assert_equal state_file, missing[1][:state_file]
      assert Hive::Markers.current(state_file).none?,
             "missing observer logging must not roll back a successful clear"
    end
  end

  def test_finalize_unpushed_never_logs_retry_exhaustion
    @healer = Hive::Daemon::StaleAgentHealer.new(
      controller: @controller,
      logger: @logger,
      grace_sec: 300,
      error_auto_recovery_limit: 1
    )

    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "8-finalize",
        marker: "error",
        marker_attrs: { "reason" => "unpushed_commits" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
      heal([ row ])
      3.times do
        File.write(state_file, "# task\n\n<!-- ERROR reason=unpushed_commits -->\n")
        heal([ row ])
      end

      exhausted = @logger.events.select { |name, _| name == :marker_heal_exhausted }
      assert_empty exhausted
      assert_equal 4, @logger.events.count { |name, _| name == :marker_healed }
    end
  end

  def test_private_stale_review_helpers_cover_process_and_lock_edges
    row = make_row("/tmp/missing-task.md", pid_alive: false, live_task_lock: true)
    assert_nil @healer.send(:task_lock_holder, row)

    with_replaced_singleton_method(Open3, :capture3, lambda { |*_args|
      [ "", "", Struct.new(:exitstatus) { def success? = false }.new(1) ]
    }) do
      assert_equal [], @healer.send(:child_pids, 12_345)
    end

    with_replaced_singleton_method(Open3, :capture3, lambda { |*_args|
      [ "101\nbad\n202\n", "", Struct.new(:exitstatus) { def success? = true }.new(0) ]
    }) do
      assert_equal [ 101, 202 ], @healer.send(:child_pids, 12_345)
    end

    with_replaced_singleton_method(Open3, :capture3, lambda { |*_args|
      [ "", "boom", Struct.new(:exitstatus) { def success? = false }.new(2) ]
    }) do
      assert_nil @healer.send(:child_pids, 12_345)
    end

    with_replaced_singleton_method(Open3, :capture3, ->(*_args) { raise Errno::ENOENT }) do
      assert_nil @healer.send(:child_pids, 12_345)
    end

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::ESRCH }) do
      refute @healer.send(:pid_alive?, 12_345)
    end

    with_replaced_singleton_method(Process, :kill, ->(_signal, _pid) { raise Errno::EPERM }) do
      assert @healer.send(:pid_alive?, 12_345)
      assert_nil @healer.send(:terminate_lock_holder, { "pid" => 12_345 })
    end

    assert_nil @healer.send(:terminate_lock_holder, { "pid" => "not-a-pid" })
  end

  def test_terminate_lock_holder_sends_term_then_stops_when_process_exits
    signals = []
    alive_checks = 0

    with_replaced_singleton_method(Process, :kill, lambda { |signal, pid|
      signals << [ signal, pid ]
      true
    }) do
      with_replaced_singleton_method(@healer, :pid_alive?, lambda { |_pid|
        alive_checks += 1
        alive_checks < 2
      }) do
        with_replaced_singleton_method(@healer, :sleep, ->(_seconds) { }) do
          @healer.send(:terminate_lock_holder, { "pid" => 12_345 })
        end
      end
    end

    assert_equal [ [ "TERM", 12_345 ] ], signals
  end

  def test_terminate_lock_holder_escalates_to_kill_after_deadline
    signals = []
    now = Time.utc(2026, 6, 5, 12, 0, 0)
    times = [ now, now + 2 ]

    with_replaced_singleton_method(Time, :now, -> { times.shift || now + 2 }) do
      with_replaced_singleton_method(Process, :kill, lambda { |signal, pid|
        signals << [ signal, pid ]
        true
      }) do
        with_replaced_singleton_method(@healer, :pid_alive?, ->(_pid) { true }) do
          @healer.send(:terminate_lock_holder, { "pid" => 12_345 })
        end
      end
    end

    assert_equal [ [ "TERM", 12_345 ], [ "KILL", 12_345 ] ], signals
  end

  def test_disk_failure_during_heal_does_not_crash_tick
    # Force Markers.set to raise on a row, and confirm the healer logs
    # and continues to the next row (the next row would otherwise heal).
    Dir.mktmpdir do |dir|
      bad_state = File.join(dir, "bad", "task.md")
      good_state = File.join(dir, "good", "task.md")
      FileUtils.mkdir_p(File.dirname(good_state))
      File.write(good_state, "# task\n\n<!-- AGENT_WORKING -->\n")
      # `bad_state`'s directory doesn't exist; Markers.set's ensure_dir
      # will try to mkdir_p, and that succeeds, so we have to force a
      # different failure. Easier: chmod the parent to read-only. But
      # for portability across CI sandboxes we instead stub.
      original = Hive::Markers.method(:set)
      Hive::Markers.define_singleton_method(:set) do |path, *args|
        raise Errno::ENOSPC, "no space left on device" if path == bad_state

        original.call(path, *args)
      end

      begin
        rows = [
          make_row(bad_state, pid_alive: false, project: "p", slug: "bad"),
          make_row(good_state, pid_alive: false, project: "p", slug: "good")
        ]
        heal(rows)

        failures = @logger.events.select { |name, _| name == :marker_heal_failed }
        heals = @logger.events.select { |name, _| name == :marker_healed }
        assert_equal 1, failures.size, "expected exactly one heal failure logged"
        assert_equal "p", failures.first[1][:project]
        assert_equal "bad", failures.first[1][:slug]
        assert_equal 1, heals.size, "good row must still be healed after bad row's failure"
        assert_equal "good", heals.first[1][:slug]
      ensure
        # Restore via explicit &block coercion so the stub doesn't leak
        # to later tests in the same process — relying on Method-as-
        # block coercion is documented but the explicit form is more
        # readable and version-stable.
        Hive::Markers.define_singleton_method(:set, &original)
      end
    end
  end

  # ---- reason=timeout retries ----

  def test_recovers_timeout_once_on_idempotent_stages
    # 5-open-pr / 7-artifacts: the agent did the work (PR already open;
    # artifact.md on disk) but never stamped the marker, so the wait timed out.
    # Clearing the timeout ERROR re-dispatches into the stage's idempotent
    # :complete short-circuit.
    %w[5-open-pr 7-artifacts].each_with_index do |stage, index|
      with_marker_file do |state_file|
        marker_id = "t-#{index}"
        File.write(state_file, "# task\n\n<!-- ERROR reason=timeout marker_id=#{marker_id} timeout_sec=1800 -->\n")
        pre_clear_mtime = NOW - 4242 - index
        row = make_row(
          state_file,
          pid_alive: nil,
          mtime: pre_clear_mtime,
          stage: stage,
          marker: "error",
          marker_attrs: { "reason" => "timeout", "marker_id" => marker_id },
          action: "error",
          live_task_lock: false
        )

        heal([ row ])

        heal_event = @logger.events.reverse.find { |e| e[0] == :marker_healed }
        refute_nil heal_event, "#{stage} timeout must log marker_healed"
        assert_equal "stage_timeout", heal_event[1][:reason]
        assert_equal "timeout", heal_event[1][:marker_reason]
        assert_equal stage, heal_event[1][:stage]
        assert_equal 1, heal_event[1][:attempts]
        assert_nil heal_event[1][:max_attempts], "timeout retries never exhaust"
        assert Hive::Markers.current(state_file).none?,
               "#{stage} timeout ERROR should clear so the daemon re-dispatches the stage"
      end
    end
    assert_empty @request_queue.requests,
                 "open_pr/artifacts re-enter via the markerless edit-resume path; only 3-plan requeues"
  end

  def test_timeout_outside_idempotent_stages_retries_after_cooldown
    %w[3-plan 4-execute 8-finalize 6-review].each do |stage|
      with_marker_file do |state_file|
        File.write(state_file, "# task\n\n<!-- ERROR reason=timeout marker_id=t -->\n")
        row = make_row(
          state_file,
          pid_alive: nil,
          mtime: NOW - Hive::AgentLimit.retry_cooldown_sec - 1,
          stage: stage,
          marker: "error",
          marker_attrs: { "reason" => "timeout", "marker_id" => "t" },
          action: "error",
          live_task_lock: false
        )

        heal([ row ])

        assert(@logger.events.any? { |name, _| name == :marker_healed },
               "#{stage} timeout must retry after the shared cooldown")
        refute_match(/ERROR reason=timeout/, File.read(state_file))
      end
      @logger = FakeLogger.new
      @healer = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300, request_queue: @request_queue
      )
    end
  end

  def test_timeout_retries_beyond_legacy_single_retry_cap
    with_marker_file do |state_file|
      row = make_row(
        state_file,
        pid_alive: nil,
        stage: "5-open-pr",
        marker: "error",
        marker_attrs: { "reason" => "timeout", "marker_id" => "t" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=timeout marker_id=t -->\n")
      heal([ row ])
      refute_match(/ERROR/, File.read(state_file), "first timeout heals")

      File.write(state_file, "# task\n\n<!-- ERROR reason=timeout marker_id=t -->\n")
      heal([ row ])

      refute_match(/ERROR reason=timeout/, File.read(state_file),
                   "a second timeout remains retryable")
      assert_equal 2, @logger.events.count { |name, _| name == :marker_healed }
      assert_empty @logger.events.select { |name, _| name == :marker_heal_exhausted }
    end
  end

  def test_timeout_fresh_marker_ids_remain_retryable
    with_marker_file do |state_file|
      first = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "timeout", "marker_id" => "t-a" },
        action: "error",
        live_task_lock: false
      )
      second = make_row(
        state_file,
        pid_alive: nil,
        stage: "7-artifacts",
        marker: "error",
        marker_attrs: { "reason" => "timeout", "marker_id" => "t-b" },
        action: "error",
        live_task_lock: false
      )

      File.write(state_file, "# task\n\n<!-- ERROR reason=timeout marker_id=t-a -->\n")
      heal([ first ])
      refute_match(/ERROR/, File.read(state_file))

      File.write(state_file, "# task\n\n<!-- ERROR reason=timeout marker_id=t-b -->\n")
      heal([ second ])

      refute_match(/ERROR reason=timeout marker_id=t-b/, File.read(state_file),
                   "a fresh timeout marker id remains retryable")
      assert_equal 2, @logger.events.count { |name, _| name == :marker_healed }
      assert_empty @logger.events.select { |name, _| name == :marker_heal_exhausted }
    end
  end

  # --- all_failed reviewers auto-retry (non-limit total reviewer crash) ---

  def make_review_error_row(state_file, reason:, phase:, pass: "1", attrs: {})
    make_row(
      state_file,
      pid_alive: nil,
      stage: "6-review",
      marker: "review_error",
      marker_attrs: { "phase" => phase, "reason" => reason, "pass" => pass }.merge(attrs),
      action: "recover_review",
      live_task_lock: false
    )
  end

  def test_auto_recovers_review_error_fix_failed_when_claude_stop_hook_did_not_signal
    with_marker_file do |state_file|
      message = "claude stop hook did not signal completion"
      File.write(
        state_file,
        "# task\n\n<!-- REVIEW_ERROR phase=fix reason=fix_failed pass=1 message=\"#{message}\" -->\n"
      )
      row = make_review_error_row(
        state_file,
        reason: "fix_failed",
        phase: "fix",
        attrs: { "message" => message }
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected stop-hook fix auto-recovery, got: #{@logger.events.inspect}"
      assert_equal "fix_claude_stop_hook", heal_event[1][:reason]
      assert_equal 1, heal_event[1][:attempts]
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_auto_recovers_review_error_all_failed
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=all_failed pass=1 -->\n")
      row = make_review_error_row(state_file, reason: "all_failed", phase: "reviewers")

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected all_failed auto-recovery event, got: #{@logger.events.inspect}"
      assert_equal "reviewer_all_failed", heal_event[1][:reason]
      refute_match(/REVIEW_ERROR/, File.read(state_file),
                   "a non-limit all_failed must clear so the daemon re-dispatches review")
    end
  end

  def test_review_all_failed_auto_recovery_is_unbounded
    with_marker_file do |state_file|
      3.times do
        File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=all_failed pass=1 -->\n")
        heal([ make_review_error_row(state_file, reason: "all_failed", phase: "reviewers") ])
        assert Hive::Markers.current(state_file).none?, "each attempt within budget clears the marker"
      end
      assert_equal 3, @logger.events.count { |name, _| name == :marker_healed }

      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=reviewers reason=all_failed pass=1 -->\n")
      heal([ make_review_error_row(state_file, reason: "all_failed", phase: "reviewers") ])

      assert Hive::Markers.current(state_file).none?,
             "the 4th all_failed remains retryable"
      assert_equal 4, @logger.events.count { |name, _| name == :marker_healed }
      assert_empty @logger.events.select { |name, _| name == :marker_heal_exhausted }
    end
  end

  # --- fix-phase auto-commit scope/sign failures auto-retry ---

  def test_auto_recovers_review_error_fix_auto_commit_scope_failed
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=fix reason=fix_auto_commit_scope_failed pass=2 -->\n")
      row = make_review_error_row(state_file, reason: "fix_auto_commit_scope_failed", phase: "fix", pass: "2")

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected fix scope auto-recovery, got: #{@logger.events.inspect}"
      assert_equal "fix_auto_commit_retry", heal_event[1][:reason]
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_review_fix_status_check_failed_retries_after_cooldown
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- REVIEW_ERROR phase=fix reason=fix_status_check_failed pass=2 -->\n")
      row = make_review_error_row(state_file, reason: "fix_status_check_failed", phase: "fix", pass: "2")

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed },
             "git-level/integrity fix reasons retry after cooldown"
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_auto_recovers_review_error_fix_failed_when_claude_stop_hook_did_not_signal
    with_marker_file do |state_file|
      message = "claude stop hook did not signal completion"
      File.write(
        state_file,
        "# task\n\n<!-- REVIEW_ERROR phase=fix reason=fix_failed pass=1 message=\"#{message}\" -->\n"
      )
      row = make_review_error_row(
        state_file,
        reason: "fix_failed",
        phase: "fix",
        attrs: { "message" => message }
      )

      heal([ row ])

      heal_event = @logger.events.find { |name, _| name == :marker_healed }
      assert heal_event, "expected stop-hook fix auto-recovery, got: #{@logger.events.inspect}"
      assert_equal "fix_claude_stop_hook", heal_event[1][:reason]
      assert_equal 1, heal_event[1][:attempts]
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  def test_plain_review_fix_failed_retries_after_cooldown
    with_marker_file do |state_file|
      File.write(
        state_file,
        "# task\n\n<!-- REVIEW_ERROR phase=fix reason=fix_failed pass=1 message=\"agent exited 1\" -->\n"
      )
      row = make_review_error_row(
        state_file,
        reason: "fix_failed",
        phase: "fix",
        attrs: { "message" => "agent exited 1" }
      )

      heal([ row ])

      assert @logger.events.any? { |name, _| name == :marker_healed },
             "generic fix_failed must retry after cooldown"
      refute_match(/REVIEW_ERROR/, File.read(state_file))
    end
  end

  # --- ensure_clean_on_exit_failed ERROR auto-retry ---

  def test_auto_recovers_error_ensure_clean_on_exit_failed
    %w[4-execute 6-review 8-finalize].each do |stage|
      with_marker_file do |state_file|
        File.write(state_file, "# task\n\n<!-- ERROR reason=ensure_clean_on_exit_failed -->\n")
        row = make_row(
          state_file, pid_alive: nil, stage: stage,
          marker: "error", marker_attrs: { "reason" => "ensure_clean_on_exit_failed" },
          action: "error", live_task_lock: false
        )

        heal([ row ])

        heal_event = @logger.events.find { |name, _| name == :marker_healed }
        assert heal_event, "#{stage} ensure_clean_on_exit_failed should auto-recover, got: #{@logger.events.inspect}"
        assert_equal "clean_exit_residue", heal_event[1][:reason]
        assert Hive::Markers.current(state_file).none?,
               "#{stage} clean-exit residue must clear so the stage re-runs CleanExit"
      end
      @logger = FakeLogger.new
      @healer = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300, request_queue: @request_queue
      )
    end
  end

  def test_ensure_clean_on_exit_failed_auto_recovery_is_unbounded
    with_marker_file do |state_file|
      attrs = { "reason" => "ensure_clean_on_exit_failed" }
      3.times do
        File.write(state_file, "# task\n\n<!-- ERROR reason=ensure_clean_on_exit_failed -->\n")
        heal([ make_row(state_file, pid_alive: nil, stage: "6-review", marker: "error",
                        marker_attrs: attrs, action: "error", live_task_lock: false) ])
        assert Hive::Markers.current(state_file).none?
      end

      File.write(state_file, "# task\n\n<!-- ERROR reason=ensure_clean_on_exit_failed -->\n")
      heal([ make_row(state_file, pid_alive: nil, stage: "6-review", marker: "error",
                      marker_attrs: attrs, action: "error", live_task_lock: false) ])

      assert Hive::Markers.current(state_file).none?,
             "the 4th attempt remains retryable"
      assert_equal 4, @logger.events.count { |name, _| name == :marker_healed }
      assert_empty @logger.events.select { |name, _| name == :marker_heal_exhausted }
    end
  end

  def test_legacy_marker_healing_does_not_rediscover_lease_backed_attempt_loss
    with_marker_file do |state_file|
      File.write(state_file, "# task\n\n<!-- ERROR reason=attempt_lost -->\n")
      row = make_row(
        state_file, pid_alive: nil, marker: "error",
        marker_attrs: { "reason" => "attempt_lost" }, live_task_lock: false
      )

      heal([ row ])

      assert_equal :error, Hive::Markers.current(state_file).name
      refute @logger.events.any? { |name, _attrs| name == :marker_healed }
    end
  end

  def test_attempt_loss_marker_retries_after_its_successor_terminally_fails
    with_marker_file do |state_file|
      marker_attrs = {
        "reason" => "attempt_lost",
        "attempt_id" => "lost-1",
        "marker_id" => "loss-marker"
      }
      File.write(
        state_file,
        "# task\n\n<!-- ERROR reason=attempt_lost attempt_id=lost-1 marker_id=loss-marker -->\n"
      )
      records = [
        attempt_record("lost-1", state: "lost"),
        attempt_record(
          "successor-1", state: "terminal", outcome: "failed",
          predecessor_attempt_id: "lost-1"
        )
      ]
      @healer = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300,
        request_queue: @request_queue,
        attempt_store: FakeAttemptStore.new(records),
        lost_outcome_store: FakeLostOutcomeStore.new(
          "lost-1" => {
            "status" => "successor_dispatched",
            "successor_attempt_id" => "successor-1"
          }
        )
      )
      row = make_row(
        state_file, pid_alive: nil, marker: "error",
        marker_attrs: marker_attrs, live_task_lock: false
      )

      heal([ row ])

      assert Hive::Markers.current(state_file).none?,
             "a failed durable successor must release the compatibility loss marker"
      event = @logger.events.find { |name, _attrs| name == :marker_healed }
      refute_nil event
      assert_equal "attempt_loss_successor_failed", event[1].fetch(:reason)
    end
  end

  def test_attempt_loss_marker_stays_while_its_successor_is_live_or_succeeded
    %w[running succeeded].each do |successor_state|
      with_marker_file do |state_file|
        marker_attrs = {
          "reason" => "attempt_lost",
          "attempt_id" => "lost-1",
          "marker_id" => "loss-marker"
        }
        File.write(
          state_file,
          "# task\n\n<!-- ERROR reason=attempt_lost attempt_id=lost-1 marker_id=loss-marker -->\n"
        )
        state = successor_state == "running" ? "running" : "terminal"
        outcome = successor_state == "succeeded" ? "succeeded" : nil
        records = [
          attempt_record("lost-1", state: "lost"),
          attempt_record(
            "successor-1", state: state, outcome: outcome,
            predecessor_attempt_id: "lost-1"
          )
        ]
        @healer = Hive::Daemon::StaleAgentHealer.new(
          controller: @controller, logger: @logger, grace_sec: 300,
          request_queue: @request_queue,
          attempt_store: FakeAttemptStore.new(records),
          lost_outcome_store: FakeLostOutcomeStore.new(
            "lost-1" => {
              "status" => "successor_dispatched",
              "successor_attempt_id" => "successor-1"
            }
          )
        )
        row = make_row(
          state_file, pid_alive: nil, marker: "error",
          marker_attrs: marker_attrs, live_task_lock: false
        )

        heal([ row ])

        assert_equal :error, Hive::Markers.current(state_file).name,
                     "#{successor_state} successor must retain the compatibility marker"
      end
    end
  end

  def test_attempt_loss_marker_retries_after_lost_successor_chain_terminally_fails
    with_marker_file do |state_file|
      marker_attrs = {
        "reason" => "attempt_lost",
        "attempt_id" => "lost-1",
        "marker_id" => "loss-marker"
      }
      File.write(
        state_file,
        "# task\n\n<!-- ERROR reason=attempt_lost attempt_id=lost-1 marker_id=loss-marker -->\n"
      )
      records = [
        attempt_record("lost-1", state: "lost"),
        attempt_record(
          "lost-2", state: "lost",
          predecessor_attempt_id: "lost-1"
        ),
        attempt_record(
          "successor-2", state: "terminal", outcome: "failed",
          predecessor_attempt_id: "lost-2"
        )
      ]
      @healer = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300,
        request_queue: @request_queue,
        attempt_store: FakeAttemptStore.new(records),
        lost_outcome_store: FakeLostOutcomeStore.new(
          "lost-1" => {
            "status" => "successor_dispatched",
            "successor_attempt_id" => "lost-2"
          },
          "lost-2" => {
            "status" => "successor_dispatched",
            "successor_attempt_id" => "successor-2"
          }
        )
      )
      row = make_row(
        state_file, pid_alive: nil, marker: "error",
        marker_attrs: marker_attrs, live_task_lock: false
      )

      heal([ row ])

      assert Hive::Markers.current(state_file).none?
      event = @logger.events.find { |name, _attrs| name == :marker_healed }
      assert_equal "attempt_loss_successor_failed", event[1].fetch(:reason)
    end
  end

  def test_attempt_loss_marker_stays_when_lineage_lookup_raises
    with_marker_file do |state_file|
      marker_attrs = {
        "reason" => "attempt_lost",
        "attempt_id" => "lost-1",
        "marker_id" => "loss-marker"
      }
      File.write(
        state_file,
        "# task\n\n<!-- ERROR reason=attempt_lost attempt_id=lost-1 marker_id=loss-marker -->\n"
      )
      attempt_store = Object.new
      attempt_store.define_singleton_method(:fetch) { |_attempt_id| raise "synthetic read failure" }
      @healer = Hive::Daemon::StaleAgentHealer.new(
        controller: @controller, logger: @logger, grace_sec: 300,
        request_queue: @request_queue,
        attempt_store: attempt_store,
        lost_outcome_store: FakeLostOutcomeStore.new({})
      )
      row = make_row(
        state_file, pid_alive: nil, marker: "error",
        marker_attrs: marker_attrs, live_task_lock: false
      )

      heal([ row ])

      assert_equal :error, Hive::Markers.current(state_file).name
      refute @logger.events.any? { |name, _attrs| name == :marker_healed }
    end
  end

  def attempt_record(attempt_id, state:, outcome: nil, predecessor_attempt_id: nil)
    AttemptRecord.new(
      attempt_id: attempt_id,
      state: state,
      outcome: outcome,
      predecessor_attempt_id: predecessor_attempt_id,
      project: "p",
      task_slug: "s",
      task_generation: "generation-1"
    )
  end
end
