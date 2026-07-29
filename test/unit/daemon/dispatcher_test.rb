require "test_helper"
require "hive/attempts/reconciler"
require "fileutils"
require "tmpdir"
require "hive/markers"
require "hive/task_meta"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/dispatch_baselines"
require "hive/daemon/logger"

# Pin Dispatcher#tick logic with mocked collaborators. The point of
# these tests is the routing decisions: which Policy outcome maps to
# which Logger event, which dispatches consume capacity, which rows
# fall through to the merge watcher.
class HiveDaemonDispatcherTest < Minitest::Test
  include HiveTestHelper

  T0 = Time.utc(2026, 5, 6, 12, 0, 0)

  Row = Hive::Daemon::StatusConsumer::Row
  ChildExit = Hive::Daemon::ChildSupervisor::ChildExit

  def setup
    @row_dirs = []
  end

  def teardown
    Array(@row_dirs).each { |dir| FileUtils.rm_rf(dir) }
  end

  # ── fakes ─────────────────────────────────────────────────────────────

  class FakeStatusConsumer
    attr_reader :fetch_count
    attr_writer :next_result

    def initialize
      @fetch_count = 0
    end

    def fetch
      @fetch_count += 1
      @next_result || Hive::Daemon::StatusConsumer::Result.new(ok: true, rows: [], error: nil)
    end
  end

  class FakeSupervisor
    attr_reader :spawned, :next_pid
    attr_accessor :next_exits, :shutdown_exits, :identity, :terminate_result, :spawn_error,
                  :shutdown_proof
    def initialize
      @spawned = []
      @next_pid = 100
      @next_exits = []
      @shutdown_exits = []
      @identity = { process_start_time: "start", pgid: 100 }
      @terminate_result = true
      @shutdown_proof = { drained: true, child_inventory: [] }
    end

    def spawn(command_string:, project:, slug:, stage:,
              log_state_path: nil, state_file_path: nil, dry_run: nil,
              request_id: nil, dispatch_token: nil)
      raise spawn_error if spawn_error

      pid = @next_pid
      @next_pid += 1
      @spawned << {
        pid: pid, command: command_string, project: project, slug: slug,
        stage: stage, state_file_path: state_file_path, dry_run: dry_run,
        request_id: request_id, log_state_path: log_state_path,
        dispatch_token: dispatch_token
      }
      pid
    end

    def reap_all(now: Time.now)
      out = @next_exits
      @next_exits = []
      out
    end

    def reap_dry_run(now: Time.now)
      []
    end

    def terminate_all(grace_sec: 600)
      @shutdown_exits
    end

    def update_timeouts(default_timeout_sec:, verb_timeouts:, kill_grace_sec:)
      @timeouts = { default_timeout_sec: default_timeout_sec,
                    verb_timeouts: verb_timeouts, kill_grace_sec: kill_grace_sec }
    end

    # #252: the dispatcher now calls this unconditionally each tick (the
    # `respond_to?` seam was removed); the real ChildSupervisor returns the
    # list of timeout actions taken, the fake has no children to time out.
    def enforce_timeouts(now:)
      []
    end

    def in_flight_count
      @spawned.size
    end

    def process_identity(_pid)
      @identity
    end

    def terminate_child(pid, grace_sec: 2)
      @terminated ||= []
      @terminated << pid
      terminate_result
    end

    attr_reader :terminated
  end

  class FakeMergeWatcher
    attr_reader :observed, :tick_projects, :observed_projects
    attr_accessor :next_results, :observe_error, :tick_error,
                  :recovery_blocked
    def initialize
      @observed = []
      @next_results = []
    end

    def observe(rows, now:, projects: nil)
      raise observe_error if observe_error

      @observed << { rows: rows, now: now }
      @observed_projects = projects
      []
    end

    def tick(now:, projects: nil)
      raise tick_error if tick_error

      @tick_projects = projects
      out = @next_results
      @next_results = []
      out
    end

    def recovery_blocked?(project:, slug:)
      recovery_blocked == true
    end
  end

  class FakePatrolScheduler
    attr_accessor :next_dispatches, :events
    attr_reader :completed, :cancelled, :reserved

    def initialize
      @next_dispatches = []
      @completed = []
      @cancelled = []
      @reserved = []
      @events = []
    end

    def tick(now:)
      out = @next_dispatches
      @next_dispatches = []
      out
    end

    def complete(project:, exit_code:, envelope: nil, now:)
      completion = {
        project: project,
        exit_code: exit_code,
        now: now
      }
      completion[:envelope] = envelope if envelope
      @completed << completion
    end

    def cancel(project:)
      @cancelled << project
    end

    def reserve(candidate, now:)
      @reserved << { candidate: candidate, now: now }
      candidate
    end

    def drain_events
      drained = events.dup
      events.clear
      drained
    end
  end

  class FakeRefactorPatrolScheduler
    attr_accessor :attach_error, :events, :completion_status, :reserve_error
    attr_reader :reserved, :spawned_calls, :cancelled, :completed

    def initialize
      @reserved = []
      @spawned_calls = []
      @cancelled = []
      @completed = []
      @events = []
      @completion_status = :closed
    end

    def drain_events
      drained = events.dup
      events.clear
      drained
    end

    def reserve(candidate, now:)
      raise reserve_error if reserve_error

      @reserved << [ candidate, now ]
      candidate.merge(
        command: "hive refactor-patrol p1 --job-manifest /tmp/job.json --json",
        dispatch_token: { kind: :architecture_patrol, job_id: candidate.fetch(:job_id), owner: "daemon", generation: 1 }
      )
    end

    def spawned(dispatch, pid:, process_start_time:, pgid:, now:)
      raise attach_error if attach_error

      @spawned_calls << { dispatch: dispatch, pid: pid, process_start_time: process_start_time, pgid: pgid, now: now }
    end

    def cancel(dispatch, reason:, now:)
      @cancelled << { dispatch: dispatch, reason: reason, now: now }
    end

    def complete(dispatch_token:, exit_code:, envelope:, now:)
      @completed << { dispatch_token: dispatch_token, exit_code: exit_code, envelope: envelope, now: now }
      {
        status: completion_status, job_id: dispatch_token.fetch(:job_id), pr_number: 7,
        pr_url: "https://github.com/acme/demo/pull/7",
        accepted_count: 0, flagged_count: 0, suppressed_count: 0
      }
    end
  end

  class FakePatrolArbiter
    attr_accessor :items, :commit_error, :candidate_error
    attr_reader :committed

    def initialize(items)
      @items = items
      @committed = []
    end

    def candidates(now:)
      raise candidate_error if candidate_error

      items
    end

    def commit(candidate, now:)
      raise commit_error if commit_error

      @committed << { candidate: candidate, now: now }
    end
  end

  class FakeAnswerDigestScheduler
    attr_accessor :next_dispatches
    attr_reader :completed

    def initialize
      @next_dispatches = []
      @completed = []
    end

    def tick(now:)
      out = @next_dispatches
      @next_dispatches = []
      out
    end

    def complete(date:, exit_code:, envelope:, now:)
      completion = { date: date, exit_code: exit_code, now: now }
      completion[:envelope] = envelope if envelope
      @completed << completion
    end

    def cancel(date:)
      @cancelled ||= []
      @cancelled << date
    end

    attr_reader :cancelled, :reconfigured

    def reconfigure(enabled:, hour:)
      @reconfigured ||= []
      @reconfigured << { enabled: enabled, hour: hour }
    end
  end

  class FakeDisplayNameBackfiller
    def backfill(_rows, now:)
    end
  end

  class FakeRecoveryCoordinator
    attr_reader :resumes, :deferred, :marked
    attr_accessor :defer_error

    def initialize(status: "blocked")
      @status = status
      @resumes = []
      @deferred = []
      @marked = []
      @defer_error = nil
    end

    def assessment(row, now:)
      {
        due: true,
        retry_at: now,
        safe: true,
        safety_reason: "safe"
      }
    end

    def resume(request:, row:, now: nil)
      @resumes << { request: request, row: row, now: now }
      Hive::Daemon::RecoveryCoordinator::Receipt.new(
        status: @status,
        request_id: request.request_id,
        attempt_id: nil,
        phase: request.recovery["phase"],
        failure_origin: request.recovery["failure_origin"],
        next_eligible_at: request.recovery["next_eligible_at"],
        owner: "operator",
        reason: @status == "blocked" ? "generation_conflict" : nil,
        remediation: @status == "blocked" ? "refresh status" : nil,
        retry_count: nil,
        provider_hint: nil
      )
    end

    def defer_dispatch_failure(request, now:)
      raise defer_error if defer_error

      @deferred << { request: request, now: now }
      Hive::Daemon::RecoveryCoordinator::Receipt.new(
        status: "cooldown",
        request_id: request.request_id,
        attempt_id: nil,
        phase: request.recovery["phase"],
        failure_origin: request.recovery["failure_origin"],
        next_eligible_at: (now + 3_600).iso8601(6),
        owner: "scheduler",
        reason: nil,
        remediation: nil,
        retry_count: request.recovery["retry_count"],
        provider_hint: nil
      )
    end

    def mark_dispatched(request, **attributes)
      @marked << { request: request, **attributes }
    end
  end

  class FakeModuleTick
    attr_reader :ticks

    def initialize(results: [], error: nil)
      @results = results
      @error = error
      @ticks = []
    end

    def tick(now:)
      @ticks << now
      raise @error if @error

      @results
    end
  end

  # ── construction helpers ───────────────────────────────────────────────

  def make_dispatcher(rows: [], dry_run: false, with_merge_watcher: false,
                      with_patrol_scheduler: false, project_enabled: true,
                      dispatch_state: nil, status_result: nil,
                      dispatch_request_state_home: nil, dispatch_result_state_home: nil,
                      with_answer_digest_scheduler: false,
                      refactor_patrol_merge_reconciler: nil,
                      refactor_patrol_scheduler: nil, patrol_arbiter: nil,
                      attempt_dispatcher: nil, attempt_reconciler: nil,
                      operational_snapshot: nil, module_runtime: nil,
                      module_migration_coordinator: nil,
                      recovery_coordinator: nil)
    config = {
      "daemon" => {
        "edit_debounce_sec" => 30,
        "poll_interval_sec" => 30,
        "shutdown_grace_sec" => 60
      }
    }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100,
      dispatch_state: dispatch_state
    )
    supervisor = FakeSupervisor.new
    status = FakeStatusConsumer.new
    # Mirror what StatusConsumer emits in production: a `projects` list derived
    # from the rows being returned. Without this the dispatcher's prune scope
    # is empty and prune_dispatch_baselines never drops anything — making the
    # prune-on-tick path effectively dead in any test that relies on the
    # default `status_result`.
    projects_for_rows = rows.map(&:project).uniq.map do |name|
      Hive::Daemon::StatusConsumer::ProjectInfo.new(name: name, legacy_stage_dirs: [])
    end
    status.next_result = status_result ||
                         Hive::Daemon::StatusConsumer::Result.new(
                           ok: true, rows: rows, projects: projects_for_rows, error: nil
                         )
    logger = StubLogger.new
    merge_watcher = with_merge_watcher ? FakeMergeWatcher.new : nil
    patrol_scheduler = with_patrol_scheduler ? FakePatrolScheduler.new : nil
    answer_digest_scheduler = with_answer_digest_scheduler ? FakeAnswerDigestScheduler.new : nil

    dispatcher = Hive::Daemon::Dispatcher.new(
      config: config,
      controller: controller,
      supervisor: supervisor,
      status_consumer: status,
      logger: logger,
      merge_watcher: merge_watcher,
      refactor_patrol_merge_reconciler: refactor_patrol_merge_reconciler,
      patrol_scheduler: patrol_scheduler,
      refactor_patrol_scheduler: refactor_patrol_scheduler,
      patrol_arbiter: patrol_arbiter,
      answer_digest_scheduler: answer_digest_scheduler,
      dry_run: dry_run,
      dispatch_request_state_home: dispatch_request_state_home,
      dispatch_result_state_home: dispatch_result_state_home,
      attempt_dispatcher: attempt_dispatcher,
      attempt_reconciler: attempt_reconciler,
      operational_snapshot: operational_snapshot,
      module_runtime: module_runtime,
      module_migration_coordinator: module_migration_coordinator,
      recovery_coordinator: recovery_coordinator
    )
    # Generic dispatcher tests exercise routing, not the detached production
    # name generator. Rows intentionally omit display names in many fixtures;
    # leaving the real collaborator installed launches `hive generate-name`
    # subprocesses that are unrelated to those assertions. Dedicated
    # DisplayNameBackfiller tests cover its implementation, while the wiring
    # and defensive-rescue tests below replace this fake explicitly.
    dispatcher.instance_variable_set(:@display_name_backfiller, FakeDisplayNameBackfiller.new)
    # Bypass the Hive::Config.find_project / Config.load lookup chain
    # for unit tests — stub the predicate directly.
    dispatcher.define_singleton_method(:project_enabled?) { |_| project_enabled }
    [
      dispatcher, supervisor, controller, logger, merge_watcher, patrol_scheduler,
      answer_digest_scheduler
    ]
  end

  def test_recovery_request_is_resumed_by_the_shared_coordinator_before_dispatch
    coordinator = FakeRecoveryCoordinator.new(status: "blocked")
    dispatcher, supervisor, = make_dispatcher(
      rows: [], recovery_coordinator: coordinator
    )
    recovery = {
      "phase" => "admitted",
      "observed_marker_generation" => "a" * 64,
      "expected_marker_attrs" => { "reason" => "timeout", "marker_id" => "m1" },
      "canonical_task_folder" => "/tmp/s1",
      "expected_post_clear_progress_fingerprint" => "b" * 64,
      "dispatch_generation" => "c" * 64,
      "failure_origin" => "timeout",
      "next_eligible_at" => T0.iso8601(6),
      "owner" => "scheduler",
      "blocked_reason" => nil,
      "blocked_remediation" => nil
    }
    request = Hive::Daemon::DispatchRequestQueue::Request.new(
      request_id: "recovery-1", created_at: T0, project: "p1", slug: "s1",
      argv: %w[hive run s1 --stage 4-execute --project p1 --json],
      requestor: "web", chat_id: nil, update_id: nil, trigger: "recovery",
      task_generation: "c" * 64, predecessor_attempt_id: nil,
      inherited_outputs: [], task_id: 1, expected_stage: "4-execute",
      expected_marker_name: "error", expected_marker_id: "m1",
      recovery: recovery, schema_version: 4, path: nil
    )
    observed = row(
      stage: "4-execute", marker: "error", action: "error",
      marker_attrs: { "reason" => "timeout", "marker_id" => "m1" }
    )

    with_replaced_singleton_method(
      Hive::Config,
      :find_project,
      ->(_name) { { "name" => "p1", "path" => "/tmp/p1" } }
    ) do
      dispatcher.send(:process_dispatch_request_iteration, request, now: T0, rows: [ observed ])
    end

    assert_equal 1, coordinator.resumes.size
    assert_empty supervisor.spawned
  end

  def test_recovery_request_waits_when_the_status_observation_is_missing
    coordinator = FakeRecoveryCoordinator.new(status: "queued")
    dispatcher, supervisor, _controller, logger = make_dispatcher(
      rows: [], recovery_coordinator: coordinator
    )
    request = Q::Request.new(
      request_id: "recovery-missing-row",
      created_at: T0,
      project: "p1",
      slug: "s1",
      argv: %w[hive run s1 --stage 4-execute --project p1 --json],
      requestor: "web",
      trigger: "recovery",
      recovery: dispatcher_recovery
    )

    with_replaced_singleton_method(
      Hive::Config, :find_project,
      ->(_name) { { "name" => "p1", "path" => "/tmp/p1" } }
    ) do
      dispatcher.send(
        :process_dispatch_request_iteration, request, now: T0, rows: []
      )
    end

    assert_empty coordinator.resumes
    assert_empty supervisor.spawned
    assert logger.events.any? { |name, attributes|
      name == :dispatch_request_blocked &&
        attributes[:reason] == "recovery_observation_unavailable"
    }
  end

  def test_recovery_dispatch_failure_pacing_is_best_effort
    coordinator = FakeRecoveryCoordinator.new(status: "queued")
    coordinator.defer_error = IOError.new("queue rewrite failed")
    dispatcher, _supervisor, _controller, logger = make_dispatcher(
      recovery_coordinator: coordinator
    )
    request = Q::Request.new(
      request_id: "recovery-pacing-failure",
      recovery: dispatcher_recovery(phase: "cleared")
    )

    assert_nil dispatcher.send(
      :defer_recovery_after_dispatch_failure, request, now: T0
    )
    assert logger.events.any? { |name, attributes|
      name == :fatal &&
        attributes[:message].include?("recovery dispatch pacing failed") &&
        attributes[:request_id] == request.request_id
    }
  end


  def test_module_migration_and_runtime_results_are_logged_while_idle_is_silent
    migration = FakeModuleTick.new(results: [ { project: "p1", status: :shadowing, blockers: {} } ])
    runtime = FakeModuleTick.new(results: [
      { project: "idle", status: :idle, decisions: 0, schedules: 0, reason: nil },
      { project: "p1", status: :ok, decisions: 1, schedules: 1, reason: nil }
    ])
    dispatcher, _supervisor, _controller, logger = make_dispatcher(
      module_runtime: runtime, module_migration_coordinator: migration
    )

    dispatcher.tick(now: T0)

    assert_equal [ T0 ], migration.ticks
    assert_equal [ T0 ], runtime.ticks
    assert logger.events.any? { |name, attrs| name == :module_migration && attrs[:project] == "p1" }
    module_events = logger.events.select { |name, _attrs| name == :module_runtime }
    assert_equal [ "p1" ], module_events.map { |_name, attrs| attrs.fetch(:project) }
  end

  def test_module_collaborator_failures_are_isolated_and_later_tick_work_continues
    migration = FakeModuleTick.new(error: IOError.new("migration disk full"))
    runtime = FakeModuleTick.new(error: RuntimeError.new("runtime failed"))
    dispatcher, supervisor, _controller, logger = make_dispatcher(
      rows: [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ],
      module_runtime: runtime, module_migration_coordinator: migration
    )

    dispatcher.tick(now: T0)

    messages = logger.events.filter_map do |name, attrs|
      attrs[:message] if name == :fatal
    end
    assert messages.any? { |message| message.include?("module migration raised") }
    assert messages.any? { |message| message.include?("module runtime raised") }
    assert_equal 1, supervisor.spawned.size
  end


  def test_architecture_patrol_spawn_attaches_fence_then_commits_arbiter_and_routes_completion
    architecture = FakeRefactorPatrolScheduler.new
    candidate = {
      project: "p1", patrol_kind: :architecture, job_id: "job-7",
      pr_number: 7, pr_url: "https://github.com/acme/demo/pull/7",
      slug: "refactor-patrol-job-7", stage: "refactor-patrol",
      state_file_mtime: nil, state_file_path: nil, hive_state_path: "/tmp/state"
    }
    arbiter = FakePatrolArbiter.new([ candidate ])
    dispatcher, supervisor, _controller, logger = make_dispatcher(
      refactor_patrol_scheduler: architecture, patrol_arbiter: arbiter
    )

    dispatcher.tick(now: T0)

    assert_equal 1, architecture.spawned_calls.size
    assert_equal 1, arbiter.committed.size
    token = supervisor.spawned.first.fetch(:dispatch_token)
    assert_equal "job-7", token.fetch(:job_id)
    assert logger.events.any? { |name, _attrs| name == :architecture_patrol_opened }

    supervisor.next_exits = [
      ChildExit.new(
        pid: supervisor.spawned.first.fetch(:pid), exit_code: 0,
        project: "p1", slug: "refactor-patrol-job-7", stage: "refactor-patrol",
        command: supervisor.spawned.first.fetch(:command), started_at: T0,
        finished_at: T0 + 1, json_envelope: { "ok" => true }, dispatch_token: token
      )
    ]
    arbiter.items = []
    dispatcher.tick(now: T0 + 1)

    assert_equal 1, architecture.completed.size
    closed = logger.events.find { |name, _attrs| name == :architecture_patrol_closed }
    assert_equal "job-7", closed.last.fetch(:job_id)
    assert_equal 7, closed.last.fetch(:pr_number)
  end

  def test_architecture_identity_failure_terminates_child_before_claim_release
    architecture = FakeRefactorPatrolScheduler.new
    candidate = {
      project: "p1", patrol_kind: :architecture, job_id: "job-7", pr_number: 7,
      pr_url: "url", slug: "refactor-patrol-job-7", stage: "refactor-patrol",
      state_file_mtime: nil, state_file_path: nil, hive_state_path: "/tmp/state"
    }
    arbiter = FakePatrolArbiter.new([ candidate ])
    dispatcher, supervisor = make_dispatcher(
      refactor_patrol_scheduler: architecture, patrol_arbiter: arbiter
    )
    supervisor.identity = nil

    dispatcher.tick(now: T0)

    assert_equal [ 100 ], supervisor.terminated
    assert_equal "unverified_child_identity", architecture.cancelled.first.fetch(:reason)
    assert_empty arbiter.committed
  end

  def test_arbiter_commit_error_does_not_cancel_valid_running_architecture_child
    architecture = FakeRefactorPatrolScheduler.new
    candidate = {
      project: "p1", patrol_kind: :architecture, job_id: "job-7", pr_number: 7,
      pr_url: "url", slug: "refactor-patrol-job-7", stage: "refactor-patrol",
      state_file_mtime: nil, state_file_path: nil, hive_state_path: "/tmp/state"
    }
    arbiter = FakePatrolArbiter.new([ candidate ])
    arbiter.commit_error = IOError.new("disk full")
    dispatcher, _supervisor, controller, logger = make_dispatcher(
      refactor_patrol_scheduler: architecture, patrol_arbiter: arbiter
    )

    dispatcher.tick(now: T0)

    assert_empty architecture.cancelled
    assert controller.running_task?(project: "p1", slug: "refactor-patrol-job-7")
    assert logger.events.any? { |name, attrs| name == :fatal && attrs[:message].include?("arbiter commit") }
  end

  def test_corrupt_arbiter_state_is_visible_and_does_not_crash_tick
    architecture = FakeRefactorPatrolScheduler.new
    arbiter = FakePatrolArbiter.new([])
    arbiter.candidate_error = Hive::Daemon::PatrolArbiter::StateError.new("newer schema")
    dispatcher, supervisor, _controller, logger = make_dispatcher(
      refactor_patrol_scheduler: architecture, patrol_arbiter: arbiter
    )

    dispatcher.tick(now: T0)

    assert_empty supervisor.spawned
    assert logger.events.any? do |name, attrs|
      name == :architecture_patrol_blocked && attrs[:reason] == "arbiter_state_error"
    end
  end

  def test_architecture_claim_attach_failure_terminates_child_before_release
    architecture = FakeRefactorPatrolScheduler.new
    architecture.attach_error = IOError.new("fsync failed")
    candidate = {
      project: "p1", patrol_kind: :architecture, job_id: "job-7", pr_number: 7,
      pr_url: "url", slug: "refactor-patrol-job-7", stage: "refactor-patrol",
      state_file_mtime: nil, state_file_path: nil, hive_state_path: "/tmp/state"
    }
    arbiter = FakePatrolArbiter.new([ candidate ])
    dispatcher, supervisor = make_dispatcher(
      refactor_patrol_scheduler: architecture, patrol_arbiter: arbiter
    )

    dispatcher.tick(now: T0)

    assert_equal [ 100 ], supervisor.terminated
    assert_equal "claim_attach_failed", architecture.cancelled.first.fetch(:reason)
    assert_empty arbiter.committed
  end

  def test_refactor_patrol_merge_reconciler_runs_intake_without_dispatching_jobs
    reconciler = Struct.new(:calls) do
      def tick(now:)
        calls << now
        [ { project: "p1", status: :blocked, enqueued_prs: [], reason: "pagination failed" } ]
      end
    end.new([])
    dispatcher, supervisor, _controller, logger = make_dispatcher(
      rows: [],
      refactor_patrol_merge_reconciler: reconciler
    )

    dispatcher.tick(now: T0)

    assert_equal [ T0 ], reconciler.calls
    assert_empty supervisor.spawned, "U5 intake must not schedule or execute architecture jobs"
    event = logger.events.find { |name, attrs| name == :blocked && attrs[:action] == "refactor_patrol_intake" }
    assert event
    assert_equal "pagination failed", event.last.fetch(:reason)
  end

  def test_scheduler_block_events_are_forwarded_without_internal_status_field
    architecture = FakeRefactorPatrolScheduler.new
    architecture.events << {
      status: :blocked, project: "p1", job_id: "job-7", reason: "duplicate_registration"
    }
    dispatcher, _supervisor, _controller, logger = make_dispatcher(
      refactor_patrol_scheduler: architecture,
      patrol_arbiter: FakePatrolArbiter.new([])
    )

    dispatcher.tick(now: T0)

    name, attrs = logger.events.find { |event_name, _| event_name == :architecture_patrol_blocked }
    assert_equal :architecture_patrol_blocked, name
    assert_equal "duplicate_registration", attrs.fetch(:reason)
    refute attrs.key?(:status)
  end

  def test_architecture_completion_routes_progress_and_retry_events
    [ [ :classified, :architecture_patrol_progress ], [ :retry, :architecture_patrol_blocked ] ].each do |status, expected_event|
      architecture = FakeRefactorPatrolScheduler.new
      architecture.completion_status = status
      candidate = {
        project: "p1", patrol_kind: :architecture, job_id: "job-7",
        pr_number: 7, pr_url: "url", slug: "refactor-patrol-job-7",
        stage: "refactor-patrol", state_file_mtime: nil,
        state_file_path: nil, hive_state_path: "/tmp/state"
      }
      arbiter = FakePatrolArbiter.new([ candidate ])
      dispatcher, supervisor, _controller, logger = make_dispatcher(
        refactor_patrol_scheduler: architecture, patrol_arbiter: arbiter
      )
      dispatcher.tick(now: T0)
      token = supervisor.spawned.fetch(0).fetch(:dispatch_token)
      supervisor.next_exits = [
        ChildExit.new(
          pid: 100, exit_code: status == :retry ? 1 : 0,
          project: "p1", slug: "refactor-patrol-job-7", stage: "refactor-patrol",
          command: supervisor.spawned.fetch(0).fetch(:command), started_at: T0,
          finished_at: T0 + 1, json_envelope: nil, dispatch_token: token
        )
      ]
      arbiter.items = []

      dispatcher.tick(now: T0 + 1)

      assert logger.events.any? { |name, attrs| name == expected_event && attrs[:status] == status }
    end
  end

  def test_merge_reconciler_logs_seeded_and_nonempty_catch_up_results
    reconciler = Struct.new(:results) do
      def tick(now:)
        results
      end
    end.new([
      { project: "p1", status: :seeded, enqueued_prs: [], reason: nil },
      { project: "p1", status: :ok, enqueued_prs: [], reason: nil },
      { project: "p2", status: :ok, enqueued_prs: [ 7, 8 ], reason: nil }
    ])
    dispatcher, _supervisor, _controller, logger = make_dispatcher(
      refactor_patrol_merge_reconciler: reconciler
    )

    dispatcher.tick(now: T0)

    assert logger.events.any? do |name, attrs|
      name == :skipped && attrs[:action] == "refactor_patrol_intake" && attrs[:reason] == "baseline_seeded"
    end
    catch_up = logger.events.find do |name, attrs|
      name == :architecture_patrol_progress && attrs[:source] == "catch_up"
    end
    assert_equal [ 7, 8 ], catch_up.last.fetch(:enqueued_prs)
  end

  def test_merge_reconciler_failure_is_isolated_as_fatal
    reconciler = Object.new
    reconciler.define_singleton_method(:tick) { |**| raise IOError, "GitHub unavailable" }
    dispatcher, _supervisor, _controller, logger = make_dispatcher(
      refactor_patrol_merge_reconciler: reconciler
    )

    dispatcher.tick(now: T0)

    assert logger.events.any? do |name, attrs|
      name == :fatal && attrs[:message].include?("merge reconciliation failed: IOError: GitHub unavailable")
    end
  end

  def test_arbiter_reserves_ordinary_patrol_before_spawn
    candidate = {
      project: "p1", patrol_kind: :ordinary, slug: "patrol-p1", stage: "patrol",
      command: "hive patrol p1", state_file_mtime: nil, state_file_path: nil,
      hive_state_path: "/tmp/state"
    }
    arbiter = FakePatrolArbiter.new([ candidate ])
    dispatcher, supervisor, _controller, _logger, _watcher, patrol = make_dispatcher(
      with_patrol_scheduler: true, patrol_arbiter: arbiter
    )

    dispatcher.tick(now: T0)

    assert_equal candidate, patrol.reserved.fetch(0).fetch(:candidate)
    assert_equal "hive patrol p1", supervisor.spawned.fetch(0).fetch(:command)
  end

  def test_patrol_dispatch_rechecks_migration_ownership_at_spawn_boundary
    dispatcher, _supervisor, _controller, logger = make_dispatcher
    candidate = {
      project: "p1", patrol_kind: :architecture,
      slug: "refactor-patrol-job-7", stage: "refactor-patrol",
      migration_entry: {
        "path" => "/tmp/project", "hive_state_path" => "/tmp/project/.hive-state"
      }
    }
    observed = []
    blocked = lambda do |project_root, module_name, authority:, hive_state_path:, &block|
      observed << [ project_root, module_name, authority, hive_state_path ]
      block.call(false)
    end
    with_replaced_singleton_method(
      Hive::Modules::Migration::Patrols, :with_admission, blocked
    ) do
      dispatcher.send(:dispatch_patrol_with_gates, candidate, now: T0)
    end
    assert_equal(
      [
        "/tmp/project", "architecture-patrol", :legacy,
        "/tmp/project/.hive-state"
      ],
      observed.fetch(0)
    )
    assert logger.events.any? do |name, attributes|
      name == :skipped &&
        attributes[:reason] == "migration_ownership_changed"
    end

    admitted = []
    dispatcher.define_singleton_method(:dispatch_patrol_with_admission) do |value, now:|
      admitted << [ value, now ]
    end
    allowed = lambda do |*_args, **_kwargs, &block|
      block.call(true)
    end
    with_replaced_singleton_method(
      Hive::Modules::Migration::Patrols, :with_admission, allowed
    ) do
      dispatcher.send(:dispatch_patrol_with_gates, candidate, now: T0)
    end
    assert_equal [ [ candidate, T0 ] ], admitted
  end

  def test_patrol_config_exit_backs_off_without_dropping_project
    dispatcher, supervisor, controller, logger, _watcher, patrol = make_dispatcher(
      rows: [], with_patrol_scheduler: true
    )
    supervisor.next_exits = [
      ChildExit.new(
        pid: 123, exit_code: Hive::ExitCodes::CONFIG,
        project: "p1", slug: "patrol", stage: Hive::Daemon::PatrolScheduler::PATROL_STAGE,
        command: "hive patrol p1 --json", state_file_path: nil,
        started_at: T0 - 5, finished_at: T0,
        json_envelope: { "ok" => false, "error_kind" => "config" }
      )
    ]
    controller.record_dispatch(
      pid: 123, project: "p1", slug: "patrol",
      stage: Hive::Daemon::PatrolScheduler::PATROL_STAGE,
      command: "hive patrol p1 --json", started_at: T0 - 5,
      state_file_mtime: nil, kind: :patrol_scan
    )

    dispatcher.tick(now: T0)

    refute controller.project_dropped?("p1")
    refute logger.events.any? { |name, attrs| name == :project_dropped && attrs[:project] == "p1" }
    assert_equal(
      [
        {
          project: "p1",
          exit_code: Hive::ExitCodes::CONFIG,
          envelope: { "ok" => false, "error_kind" => "config" },
          now: T0
        }
      ],
      patrol.completed
    )
  end

  def test_unverified_architecture_child_claim_is_preserved_if_termination_cannot_be_proved
    architecture = FakeRefactorPatrolScheduler.new
    candidate = {
      project: "p1", patrol_kind: :architecture, job_id: "job-7", pr_number: 7,
      pr_url: "url", slug: "refactor-patrol-job-7", stage: "refactor-patrol",
      state_file_mtime: nil, state_file_path: nil, hive_state_path: "/tmp/state"
    }
    dispatcher, supervisor, _controller, logger = make_dispatcher(
      refactor_patrol_scheduler: architecture,
      patrol_arbiter: FakePatrolArbiter.new([ candidate ])
    )
    supervisor.identity = nil
    supervisor.terminate_result = false

    dispatcher.tick(now: T0)

    assert_empty architecture.cancelled
    assert logger.events.any? do |name, attrs|
      name == :fatal && attrs[:message].include?("cannot resolve or terminate architecture patrol child identity")
    end
  end

  def test_claim_attach_failure_preserves_claim_if_child_termination_cannot_be_proved
    architecture = FakeRefactorPatrolScheduler.new
    architecture.attach_error = IOError.new("fsync failed")
    candidate = {
      project: "p1", patrol_kind: :architecture, job_id: "job-7", pr_number: 7,
      pr_url: "url", slug: "refactor-patrol-job-7", stage: "refactor-patrol",
      state_file_mtime: nil, state_file_path: nil, hive_state_path: "/tmp/state"
    }
    dispatcher, supervisor, _controller, logger = make_dispatcher(
      refactor_patrol_scheduler: architecture,
      patrol_arbiter: FakePatrolArbiter.new([ candidate ])
    )
    supervisor.terminate_result = false

    dispatcher.tick(now: T0)

    assert_empty architecture.cancelled
    assert logger.events.any? do |name, attrs|
      name == :fatal && attrs[:message].include?("cannot terminate architecture patrol child after claim attach failure")
    end
  end

  def test_reservation_block_is_logged_without_attempting_spawn
    architecture = FakeRefactorPatrolScheduler.new
    architecture.reserve_error = Hive::Daemon::RefactorPatrolScheduler::ReservationBlocked.new(
      "repository_identity_drift", { "expected" => "acme/demo" }
    )
    candidate = {
      project: "p1", patrol_kind: :architecture, job_id: "job-7", pr_number: 7,
      pr_url: "url", slug: "refactor-patrol-job-7", stage: "refactor-patrol"
    }
    dispatcher, supervisor, _controller, logger = make_dispatcher(
      refactor_patrol_scheduler: architecture,
      patrol_arbiter: FakePatrolArbiter.new([ candidate ])
    )

    dispatcher.tick(now: T0)

    assert_empty supervisor.spawned
    event = logger.events.find do |name, attrs|
      name == :architecture_patrol_blocked && attrs[:reason] == "repository_identity_drift"
    end
    assert_equal({ "expected" => "acme/demo" }, event.last.fetch(:evidence))
  end

  def test_architecture_spawn_error_releases_reserved_claim
    architecture = FakeRefactorPatrolScheduler.new
    candidate = {
      project: "p1", patrol_kind: :architecture, job_id: "job-7", pr_number: 7,
      pr_url: "url", slug: "refactor-patrol-job-7", stage: "refactor-patrol",
      state_file_mtime: nil, state_file_path: nil, hive_state_path: "/tmp/state"
    }
    dispatcher, supervisor, _controller, logger = make_dispatcher(
      refactor_patrol_scheduler: architecture,
      patrol_arbiter: FakePatrolArbiter.new([ candidate ])
    )
    supervisor.spawn_error = Errno::EAGAIN.new("fork unavailable")

    dispatcher.tick(now: T0)

    assert_equal "dispatch_error", architecture.cancelled.fetch(0).fetch(:reason)
    assert logger.events.any? { |name, attrs| name == :fatal && attrs[:message].include?("patrol dispatch error") }
  end

  class StubLogger
    attr_reader :events
    def initialize; @events = []; end
    def event(name, **attrs); @events << [ name, attrs ]; end
    def close; end
  end

  class FakeOperationalSnapshot
    attr_reader :calls

    def initialize(fail_on: [], error: Errno::ENOSPC.new("snapshot publication"))
      @fail_on = Array(fail_on).map(&:to_sym)
      @error = error
      @calls = []
    end

    def begin_tick(**attributes)
      record(:begin_tick, attributes)
    end

    def observe(row, **attributes)
      record(:observe, attributes.merge(project: row.project, slug: row.slug))
    end

    def fail(**attributes)
      record(:fail, attributes)
    end

    def complete(**attributes)
      record(:complete, attributes)
    end

    def shutdown(**attributes)
      record(:shutdown, attributes)
    end

    def reconfigure(**attributes)
      record(:reconfigure, attributes)
    end

    private

    def record(method, attributes)
      raise @error if @fail_on.include?(method)

      @calls << [ method, attributes ]
      true
    end
  end

  def row(project: "p1", slug: "s1", stage: "1-inbox", marker: "waiting",
          action: "ready_to_brainstorm", command: "hive brainstorm s1",
          mtime: T0 - 600, claude_pid_alive: nil, live_task_lock: nil,
          state_file: nil, folder: nil, marker_attrs: {},
          depends_on: nil, blocked_by: nil, dependency_stage: nil,
          blocked: false, workflow: nil, admission_error: nil,
          attempt_id: nil, task_generation: nil, id: 1)
    folder ||= make_existing_row_folder(project: project, stage: stage, slug: slug)
    Row.new(
      project: project, slug: slug, id: id, stage: stage, workflow: workflow, marker: marker,
      folder: folder,
      state_file: state_file || File.join(folder, "idea.md"),
      state_file_mtime: mtime, action: action,
      suggested_command: command, claude_pid_alive: claude_pid_alive,
      live_task_lock: live_task_lock, marker_attrs: marker_attrs,
      depends_on: depends_on, blocked_by: blocked_by,
      dependency_stage: dependency_stage, blocked: blocked,
      admission_error: admission_error,
      attempt_id: attempt_id, task_generation: task_generation
    )
  end

  def make_existing_row_folder(project:, stage:, slug:)
    root = Dir.mktmpdir([ "hive-dispatcher-row", project, stage, slug ].join("-"))
    @row_dirs << root
    root
  end

  # ── core dispatch flow ────────────────────────────────────────────────

  def test_operational_snapshot_publishes_started_disposition_and_revalidated_complete
    observed = row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm")
    snapshot = FakeOperationalSnapshot.new
    with_tmp_dir do |state_home|
      dispatcher, = make_dispatcher(
        rows: [ observed ], operational_snapshot: snapshot,
        dispatch_request_state_home: state_home
      )
      completed_at = T0 + 5
      dispatcher.define_singleton_method(:operational_snapshot_now) { completed_at }

      dispatcher.tick(now: T0)

      assert_equal %i[begin_tick observe complete], snapshot.calls.map(&:first)
      assert_equal "dispatched", snapshot.calls[1][1].fetch(:decision).to_s
      complete = snapshot.calls.last.last
      assert_equal [ observed ], complete.fetch(:initial_rows)
      assert_equal [ observed ], complete.fetch(:final_rows)
      assert_equal "current", complete.dig(:queue, "status")
      assert_equal completed_at, complete.fetch(:now)
    end
  end

  def test_durable_dispatch_publishes_the_actual_admission_outcome
    attempt = Struct.new(:attempt_id, :task_generation, :state)
                    .new("attempt-1", "generation-1", "running")
    admissions = [
      [ :accepted, nil, :dispatched, "scheduler" ],
      [ :existing_live, nil, :in_flight, "agent" ],
      [ :terminal_replay, nil, :attempt_terminal_replay, "hive" ],
      [ :deferred, "capacity", :attempt_capacity, "scheduler" ],
      [ :deferred, "attempt_lost", :attempt_lost, "hive" ],
      [ :deferred, "launch_handoff_failed", :launch_handoff_failed, "hive" ],
      [ :deferred, "invalid_predecessor", :invalid_predecessor, "hive" ]
    ]
    results = admissions.map do |status, reason, _outcome, _owner|
      Hive::Attempts::DispatchResult.new(
        status: status, attempt: status == :deferred ? nil : attempt,
        receipt: nil, attach_descriptor: nil, reason: reason
      )
    end
    attempt_dispatcher = Object.new
    attempt_dispatcher.define_singleton_method(:dispatch_request) do |*_args, **_options|
      results.shift
    end
    snapshot = FakeOperationalSnapshot.new
    dispatcher, = make_dispatcher(
      rows: [], attempt_dispatcher: attempt_dispatcher,
      operational_snapshot: snapshot
    )
    observed = row(
      stage: "4-execute", action: "ready_to_run",
      command: "hive run s1 --json"
    )

    admissions.each do |_status, _reason, expected_outcome, expected_owner|
      outcome = dispatcher.send(:dispatch_or_block, observed, now: T0)
      assert_equal expected_outcome, outcome
      dispatcher.send(:observe_dispatch_outcome, observed, outcome)
      disposition = snapshot.calls.last.last
      assert_equal expected_outcome, disposition.fetch(:decision)
      assert_equal expected_owner, disposition.fetch(:owner)
    end
  end

  def test_handled_status_failure_publishes_failed_without_authoritative_tasks
    snapshot = FakeOperationalSnapshot.new
    failed = Hive::Daemon::StatusConsumer::Result.new(
      ok: false, rows: [], projects: [], error: "status failed"
    )
    dispatcher, = make_dispatcher(status_result: failed, operational_snapshot: snapshot)

    dispatcher.tick(now: T0)

    assert_equal %i[begin_tick fail], snapshot.calls.map(&:first)
    assert_equal "status_failure", snapshot.calls.last.last.fetch(:reason)
  end

  def test_snapshot_publication_failures_are_advisory_and_dispatch_continues
    errors = [
      Errno::ENOSPC.new("full"), Errno::EROFS.new("read-only"),
      Errno::EACCES.new("denied"), IOError.new("rename/fsync failed")
    ]
    errors.each_with_index do |error, index|
      observed = row(
        slug: "snapshot-#{index}", action: "ready_to_plan",
        command: "hive plan snapshot-#{index} --from 2-brainstorm"
      )
      snapshot = FakeOperationalSnapshot.new(
        fail_on: %i[begin_tick observe complete fail], error: error
      )
      with_tmp_dir do |state_home|
        dispatcher, supervisor, _controller, logger = make_dispatcher(
          rows: [ observed ], operational_snapshot: snapshot,
          dispatch_request_state_home: state_home
        )

        dispatcher.tick(now: T0)

        assert_equal 1, supervisor.spawned.size
        failures = logger.events.select { |name, _attrs| name == :operational_snapshot_publish_failed }
        assert_operator failures.size, :>=, 3
        assert failures.all? { |_name, attrs| attrs.fetch(:error).include?(error.class.name) }
      end
    end
  end

  def test_legacy_layout_row_publishes_operator_disposition_without_dispatch
    snapshot = FakeOperationalSnapshot.new
    dispatcher, supervisor = make_dispatcher(rows: [], operational_snapshot: snapshot)
    dispatcher.instance_variable_set(:@legacy_layout_projects, { "p1" => true })
    observed = row

    dispatcher.send(:handle_row, observed, now: T0)

    assert_empty supervisor.spawned
    disposition = snapshot.calls.last.last
    assert_equal :legacy_layout, disposition.fetch(:decision)
    assert_equal "operator", disposition.fetch(:owner)
  end

  def test_error_retry_publishes_scheduler_owned_cooldown_disposition
    snapshot = FakeOperationalSnapshot.new
    dispatcher, supervisor = make_dispatcher(rows: [], operational_snapshot: snapshot)
    observed = row(marker: "review_error", action: "recover_review")

    dispatcher.send(:handle_row, observed, now: T0)

    assert_empty supervisor.spawned
    disposition = snapshot.calls.last.last
    assert_equal :retry_cooldown, disposition.fetch(:decision)
    assert_equal "scheduler", disposition.fetch(:owner)
    assert_equal (T0 - 600 + Hive::AgentLimit.retry_cooldown_sec).iso8601(6),
                 disposition.fetch(:retry_at)
    assert_equal false, disposition.fetch(:retry_due)
    assert_equal true, disposition.fetch(:retry_safe)
  end

  def test_error_retry_with_live_task_lock_publishes_agent_owned_in_flight_disposition
    snapshot = FakeOperationalSnapshot.new
    dispatcher, supervisor = make_dispatcher(rows: [], operational_snapshot: snapshot)
    observed = row(
      marker: "error",
      action: "error",
      live_task_lock: true,
      marker_attrs: { "reason" => "agent_orphaned" }
    )

    dispatcher.send(:handle_row, observed, now: T0)

    assert_empty supervisor.spawned
    disposition = snapshot.calls.last.last
    assert_equal :retry_in_flight, disposition.fetch(:decision)
    assert_equal "agent", disposition.fetch(:owner)
    assert_equal true, disposition.fetch(:retry_safe)
  end

  def test_error_retry_publishes_safety_block_instead_of_false_scheduler_ownership
    snapshot = FakeOperationalSnapshot.new
    dispatcher, supervisor = make_dispatcher(rows: [], operational_snapshot: snapshot)
    folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "answered")
    state_file = File.join(folder, "brainstorm.md")
    File.write(state_file, "### Q1. Continue?\n### A1.\nNo; keep this answer.\n")
    observed = row(
      slug: "answered",
      stage: "2-brainstorm",
      marker: "error",
      action: "error",
      folder: folder,
      state_file: state_file,
      marker_attrs: { "reason" => "agent_failed" },
      mtime: T0 - Hive::AgentLimit.retry_cooldown_sec - 1
    )

    dispatcher.send(:handle_row, observed, now: T0)

    assert_empty supervisor.spawned
    disposition = snapshot.calls.last.last
    assert_equal :retry_safety_blocked, disposition.fetch(:decision)
    assert_equal "operator", disposition.fetch(:owner)
    assert_equal true, disposition.fetch(:retry_due)
    assert_equal false, disposition.fetch(:retry_safe)
    assert_includes disposition.fetch(:safety_reason), "answers present"
  end

  def test_unknown_durable_admission_results_defer_safely
    dispatcher, = make_dispatcher
    deferred = Hive::Attempts::DispatchResult.new(
      status: :deferred, attempt: nil, receipt: nil, attach_descriptor: nil, reason: "future_reason"
    )
    future = deferred.with(status: :future_status, reason: nil)

    assert_equal :attempt_deferred, dispatcher.send(:dispatch_outcome, deferred)
    assert_equal :attempt_deferred, dispatcher.send(:dispatch_outcome, future)
  end

  def test_dispatch_outcome_dispositions_cover_scheduler_and_unknown_states
    snapshot = FakeOperationalSnapshot.new
    dispatcher, = make_dispatcher(operational_snapshot: snapshot)
    observed = row
    expected = {
      attempt_deferred: [ "hive", "durable attempt admission was deferred" ],
      daily_cap: [ "scheduler", "project daily dispatch budget is exhausted" ],
      cooldown: [ "scheduler", "task is inside its scheduler cooldown" ],
      quarantined: [ "operator", "task is quarantined after repeated transient failures" ],
      project_dropped: [ "operator", "project was dropped from this daemon generation" ],
      future_outcome: [ "unknown", "dispatch outcome is not recognized" ]
    }

    expected.each do |outcome, (owner, reason)|
      dispatcher.send(:observe_dispatch_outcome, observed, outcome)
      disposition = snapshot.calls.last.last
      assert_equal owner, disposition.fetch(:owner), outcome
      assert_equal reason, disposition.fetch(:reason), outcome
    end
  end

  def test_operational_snapshot_revalidation_and_assembly_failures_publish_failed_state
    snapshot = FakeOperationalSnapshot.new
    failed = Hive::Daemon::StatusConsumer::Result.new(
      ok: false, rows: [], projects: [], error: "revalidation failed"
    )
    dispatcher, = make_dispatcher(status_result: failed, operational_snapshot: snapshot)

    dispatcher.send(:publish_complete_operational_snapshot, initial_rows: [], now: T0)

    assert_equal :fail, snapshot.calls.last.first
    assert_equal "revalidation_status_failure", snapshot.calls.last.last.fetch(:reason)

    snapshot = FakeOperationalSnapshot.new
    dispatcher, _supervisor, _controller, logger = make_dispatcher(operational_snapshot: snapshot)
    status = dispatcher.instance_variable_get(:@status_consumer)
    status.define_singleton_method(:fetch) { raise IOError, "status assembly failed" }

    dispatcher.send(:publish_complete_operational_snapshot, initial_rows: [], now: T0)

    assert_equal "snapshot_assembly_failure", snapshot.calls.last.last.fetch(:reason)
    assert logger.events.any? { |name, attrs|
      name == :operational_snapshot_publish_failed && attrs.fetch(:phase) == "complete"
    }
  end

  def test_operational_snapshot_failure_logging_never_breaks_dispatcher
    dispatcher, = make_dispatcher
    logger = Object.new
    logger.define_singleton_method(:event) { |*| raise IOError, "logger unavailable" }
    dispatcher.instance_variable_set(:@logger, logger)

    assert_nil dispatcher.send(
      :log_operational_snapshot_failure, phase: "complete", error: IOError.new("snapshot unavailable")
    )
  end

  def test_operational_queue_snapshot_counts_malformed_entries_and_degrades_on_failure
    dispatcher, = make_dispatcher
    pending = Struct.new(:created_at).new(T0 - 5)
    pending_reader = lambda do |state_home:, bad_handler:|
      bad_handler.call(path: File.join(state_home.to_s, "bad-pending.json"))
      [ pending ]
    end
    claimed_reader = lambda do |state_home:, bad_handler:|
      bad_handler.call(path: File.join(state_home.to_s, "bad-claimed.json"))
      [ Object.new ]
    end

    snapshot = with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue, :pending, pending_reader
    ) do
      with_replaced_singleton_method(
        Hive::Daemon::DispatchRequestQueue, :claimed, claimed_reader
      ) do
        dispatcher.send(:operational_queue_snapshot, now: T0)
      end
    end

    assert_equal "current", snapshot.fetch("status")
    assert_equal 2, snapshot.fetch("malformed")
    assert_equal 5, snapshot.fetch("oldest_pending_age_sec")

    unavailable = with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue, :pending, ->(**) { raise Errno::EACCES, "queue denied" }
    ) do
      dispatcher.send(:operational_queue_snapshot, now: T0)
    end
    assert_equal "unavailable", unavailable.fetch("status")
    assert_match(/Errno::EACCES/, unavailable.fetch("reason"))
  end

  def test_queue_and_recovery_projections_share_one_directory_scan
    dispatcher, = make_dispatcher
    calls = Hash.new(0)
    pending_reader = lambda do |state_home:, bad_handler:|
      calls[:pending] += 1
      []
    end
    claimed_reader = lambda do |state_home:, bad_handler:|
      calls[:claimed] += 1
      []
    end

    with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue, :pending, pending_reader
    ) do
      with_replaced_singleton_method(
        Hive::Daemon::DispatchRequestQueue, :claimed, claimed_reader
      ) do
        queue_state = dispatcher.send(:operational_queue_state)
        dispatcher.send(
          :operational_queue_snapshot, now: T0, queue_state: queue_state
        )
        dispatcher.send(
          :operational_recovery_snapshot, queue_state: queue_state
        )
      end
    end

    assert_equal({ pending: 1, claimed: 1 }, calls)
  end

  def test_recovery_projection_degrades_when_the_shared_queue_scan_failed
    dispatcher, _supervisor, _controller, logger = make_dispatcher
    state = Hive::Daemon::Dispatcher::OperationalQueueState.new(
      pending: [], claimed: [], malformed: 0,
      error: IOError.new("queue unreadable")
    )

    assert_equal(
      [],
      dispatcher.send(:durable_recovery_receipts, queue_state: state)
    )
    assert logger.events.any? { |name, attributes|
      name == :fatal &&
        attributes[:message].include?("recovery lifecycle projection") &&
        attributes[:message].include?("queue unreadable")
    }
  end

  def test_recovery_lifecycle_survives_restart_without_redispatch_or_log_loop
    Dir.mktmpdir("hive-recovery-lifecycle") do |state_home|
      recovery = {
        "phase" => "admitted",
        "observed_marker_generation" => "a" * 64,
        "expected_marker_attrs" => { "reason" => "timeout", "marker_id" => "marker-1" },
        "canonical_task_folder" => "/tmp/recovery-task",
        "expected_post_clear_progress_fingerprint" => "b" * 64,
        "dispatch_generation" => "c" * 64,
        "failure_origin" => "timeout",
        "next_eligible_at" => T0.iso8601(6),
        "owner" => "scheduler",
        "blocked_reason" => nil,
        "blocked_remediation" => nil
      }
      Q.write_request!(
        project: "p1",
        slug: "recovery-task",
        argv: %w[hive run recovery-task --stage 4-execute --project p1 --json],
        requestor: "healer",
        trigger: "recovery",
        request_id: "recovery-restart",
        task_generation: "c" * 64,
        expected_stage: "4-execute",
        expected_marker_name: "error",
        expected_marker_id: "marker-1",
        recovery: recovery,
        state_home: state_home,
        now: T0
      )

      queued_dispatcher, = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      queued = queued_dispatcher.send(:durable_recovery_receipts).fetch(0)
      assert_equal "queued", queued.dig("receipt", "status")
      assert_equal "admitted", queued.dig("receipt", "phase")

      assert Q.update_recovery!(
        "recovery-restart",
        expected_phase: "admitted",
        changes: { "phase" => "cleared" },
        state_home: state_home
      )
      Q.claim(
        "recovery-restart",
        pid: nil,
        attempt_id: "attempt-1",
        task_generation: "c" * 64,
        state_home: state_home,
        now: T0 + 1
      )
      assert Q.update_recovery!(
        "recovery-restart",
        expected_phase: "cleared",
        changes: { "phase" => "dispatched", "attempt_id" => "attempt-1" },
        state_home: state_home
      )

      running_dispatcher, = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      running = running_dispatcher.send(:durable_recovery_receipts).fetch(0)
      assert_equal "running", running.dig("receipt", "status")
      assert_equal "attempt-1", running.dig("receipt", "attempt_id")

      assert Q.update_recovery!(
        "recovery-restart",
        expected_phase: "dispatched",
        changes: {
          "phase" => "terminal",
          "terminal_outcome" => "succeeded",
          "terminal_at" => (T0 + 2).iso8601(6)
        },
        state_home: state_home
      )
      fetches = 0
      reconciler = Object.new
      reconciler.define_singleton_method(:fetch) do |_attempt_id|
        fetches += 1
        raise "terminal recovery should not be reconciled twice"
      end
      terminal_dispatcher, _supervisor, _controller, logger = make_dispatcher(
        rows: [],
        dispatch_request_state_home: state_home,
        attempt_reconciler: reconciler
      )
      terminal_dispatcher.send(:recover_dispatch_claims, now: T0 + 3)
      terminal = terminal_dispatcher.send(:durable_recovery_receipts).fetch(0)
      assert_equal "terminal", terminal.dig("receipt", "status")
      assert_equal "terminal", terminal.dig("receipt", "phase")
      assert_equal "succeeded", terminal.dig("receipt", "terminal_outcome")
      assert_equal (T0 + 2).iso8601(6), terminal.dig("receipt", "terminal_at")
      assert_equal "none", terminal.dig("receipt", "owner")

      terminal_dispatcher.send(:process_dispatch_requests, now: T0 + 3, rows: [])
      terminal_dispatcher.send(:reconcile_attempt_deliveries, now: T0 + 3)

      assert_equal 0, fetches
      assert_empty Q.pending(state_home: state_home)
      refute_nil Q.fetch("recovery-restart", state_home: state_home)
      refute logger.events.any? { |name, _attrs|
        %i[
          dispatch_request_observed dispatch_request_blocked
          dispatch_request_completed dispatch_request_dispatched
        ].include?(name)
      }
    end
  end

  def test_recovery_lifecycle_projection_keeps_healthy_receipts_when_one_request_raises
    recovery = {
      "phase" => "admitted",
      "observed_marker_generation" => "a" * 64,
      "expected_marker_attrs" => { "reason" => "timeout" },
      "canonical_task_folder" => "/tmp/recovery-task",
      "expected_post_clear_progress_fingerprint" => "b" * 64,
      "dispatch_generation" => "c" * 64,
      "failure_origin" => "timeout",
      "next_eligible_at" => T0.iso8601(6),
      "owner" => "scheduler",
      "blocked_reason" => nil,
      "blocked_remediation" => nil
    }
    requests = %w[broken healthy].map do |slug|
      Hive::Daemon::DispatchRequestQueue::Request.new(
        request_id: "recovery-#{slug}", created_at: T0, project: "p1", slug: slug,
        argv: [ "hive", "run", slug ], requestor: "healer", trigger: "recovery",
        expected_stage: "4-execute", expected_marker_name: "error",
        recovery: recovery
      )
    end
    coordinator = Object.new
    coordinator.define_singleton_method(:receipt_for_request) do |request|
      raise IOError, "one corrupt lifecycle" if request.slug == "broken"

      Hive::Daemon::RecoveryCoordinator::Receipt.new(
        status: "queued", request_id: request.request_id, attempt_id: nil,
        phase: "admitted", failure_origin: "timeout",
        next_eligible_at: T0.iso8601(6), owner: "scheduler", reason: nil,
        remediation: nil, retry_count: nil, provider_hint: nil
      )
    end
    dispatcher, _supervisor, _controller, logger = make_dispatcher(
      recovery_coordinator: coordinator
    )

    receipts = with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue, :pending, ->(**) { requests }
    ) do
      with_replaced_singleton_method(
        Hive::Daemon::DispatchRequestQueue, :claimed, ->(**) { [] }
      ) do
        dispatcher.send(:durable_recovery_receipts)
      end
    end

    assert_equal [ "healthy" ], receipts.map { |entry| entry.fetch("slug") }
    assert logger.events.any? { |name, attrs|
      name == :fatal &&
        attrs[:request_id] == "recovery-broken" &&
        attrs[:message].include?("one corrupt lifecycle")
    }
  end

  def test_advance_action_dispatches_workflow_verb
    rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    with_tmp_dir do |state_home|
      with_replaced_singleton_method(Hive::Paths, :state_home, -> { state_home }) do
        dispatcher.tick(now: T0)
      end
      assert_equal state_home, sup.spawned.first[:log_state_path]
    end
    assert_equal 1, sup.spawned.size
    assert_equal "hive plan s1 --from 2-brainstorm", sup.spawned.first[:command]
    assert events_include?(logger, :dispatched)
  end

  # A generic-workflow row (`workflow: "research"`, `action: "ready_to_run"`)
  # must dispatch `hive run` on first sight through the real tick loop — the
  # generic dispatch path was previously only asserted via direct CLI calls,
  # never observed firing through `Dispatcher#tick`/`ConcurrencyController`.
  def test_generic_workflow_ready_to_run_dispatches_through_real_tick
    rows = [ row(slug: "g1", stage: "2-gather", workflow: "research",
                 action: "ready_to_run", command: "hive run g1") ]
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size, "a generic ready_to_run row must dispatch on first sight"
    assert_equal "hive run g1", sup.spawned.first[:command]
    assert events_include?(logger, :dispatched)
    # First-sight dispatch records a [project,slug] baseline so a markerless
    # re-classification next tick is braked rather than re-spawned.
    refute_nil ctrl.last_dispatched_state_file_mtime_for(project: "p1", slug: "g1")
  end

  # The generic stall scenario: a `ready_to_run` row whose state file has NOT
  # advanced past the recorded dispatch baseline (the agent exited 0 without a
  # WAITING/COMPLETE marker). The real tick must surface it as
  # `:markerless_stalled` and NOT re-spawn — proving the
  # handle_row → :markerless_stalled wiring end-to-end.
  def test_generic_ready_to_run_unchanged_mtime_is_markerless_stalled_not_respawned
    rows = [ row(slug: "g1", stage: "2-gather", workflow: "research",
                 action: "ready_to_run", command: "hive run g1",
                 marker: "none", mtime: T0 - 600) ]
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
    # Baseline equal to the row's mtime ⇒ no progress since the last dispatch.
    ctrl.observe_state_file_mtime(project: "p1", slug: "g1", mtime: T0 - 600)

    dispatcher.tick(now: T0)

    assert_empty sup.spawned, "an unchanged markerless generic run must not re-dispatch"
    stalled = logger.events.find { |(n, _)| n == :markerless_stalled }
    refute_nil stalled, "the stall must be surfaced explicitly, not as a silent skip"
    assert_equal "agent_exited_without_marker", stalled[1][:reason]
    refute events_include?(logger, :dispatched)
  end

  # High #1 regression: after a generic `hive approve` moves a task into a
  # non-coding dir (research's `2-gather`), the post-completion refresh must
  # locate it through the runtime union (`Workflows.all_stage_dirs`), NOT the
  # coding-only `Stages::DIRS` — otherwise the moved task's [project,slug]
  # mtime baseline goes stale and its fresh stage mis-debounces or stalls.
  def test_find_post_advance_state_file_locates_generic_non_coding_dir
    dispatcher, = make_dispatcher
    Dir.mktmpdir("hive-post-advance") do |hive_state|
      slug = "gen-1"
      gather_dir = File.join(hive_state, "stages", "2-gather", slug)
      FileUtils.mkdir_p(gather_dir)
      notes = File.join(gather_dir, "notes.md")
      File.write(notes, "# notes\n<!-- COMPLETE -->\n")

      # Pre-fix behavior: with no workflow registering `2-gather`, the dir is
      # outside the union and the coding-only scan can't see it.
      assert_nil dispatcher.send(:find_post_advance_state_file, hive_state, slug),
                 "a dir outside every registered workflow's union must not resolve"

      # research's gather stage IS `2-gather`; once registered, the union scan
      # finds the moved file — the exact fix for the daemon advance stall.
      with_registered_workflow(research_workflow) do
        assert_equal notes,
                     dispatcher.send(:find_post_advance_state_file, hive_state, slug),
                     "the post-advance scan must locate the generic non-coding stage dir"
      end
    end
  end

  def test_blocked_dependency_row_does_not_dispatch
    rows = [
      row(
        action: "ready_to_plan",
        command: "hive plan s1 --from 2-brainstorm",
        depends_on: "base-task",
        blocked_by: "base-task",
        dependency_stage: "7-artifacts",
        blocked: true
      )
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)

    dispatcher.tick(now: T0)

    assert_empty sup.spawned
    event = logger.events.find { |name, attrs| name == :blocked && attrs[:reason] == "dependency_unmet" }
    refute_nil event
    attrs = event.last
    assert_equal "base-task", attrs[:depends_on]
    assert_equal "base-task", attrs[:blocked_by]
    assert_equal "7-artifacts", attrs[:dependency_stage]
    assert_equal false, attrs[:unresolved],
                 "a resolved prerequisite (blocked_by present) is a real below-gate wait, not unresolved"
  end

  # An unresolved block (mistyped/unknown depends_on → blocked_by nil) must
  # still gate dispatch AND carry unresolved:true, so an operator can tell a
  # config error apart from a genuine waiting-on-prerequisite block. The
  # dispatcher derives `unresolved` from blocked_by presence — pin it here so
  # a regression hardcoding/dropping the field is caught.
  def test_unresolved_dependency_row_logs_unresolved_true_and_does_not_dispatch
    rows = [
      row(
        action: "ready_to_plan",
        command: "hive plan s1 --from 2-brainstorm",
        depends_on: "typo-task",
        blocked_by: nil,
        dependency_stage: nil,
        blocked: true
      )
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)

    dispatcher.tick(now: T0)

    assert_empty sup.spawned
    event = logger.events.find { |name, attrs| name == :blocked && attrs[:reason] == "dependency_unmet" }
    refute_nil event
    attrs = event.last
    assert_equal "typo-task", attrs[:depends_on]
    assert_nil attrs[:blocked_by]
    assert_equal true, attrs[:unresolved],
                 "a blocked row with no identified prerequisite must be flagged unresolved"
  end

  # Single-source-of-truth invariant (plan decision #2): the daemon trusts the
  # status JSON's `blocked` flag VERBATIM and never re-derives the gate
  # threshold itself. This synthetic row sets blocked:true while carrying a
  # dependency_stage PAST the gate (8-finalize) — a state a naive
  # re-derivation ("prereq is past the gate ⇒ unblocked") would dispatch. The
  # dispatcher must still hold, proving no second threshold comparison crept
  # in. Holds only by construction today; this guard pins it.
  def test_dispatcher_reads_blocked_verbatim_and_never_rederives_threshold
    rows = [
      row(
        action: "ready_to_develop",
        command: "hive develop s1 --from 3-plan",
        depends_on: "base-task",
        blocked_by: "base-task",
        dependency_stage: "8-finalize",
        blocked: true
      )
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)

    dispatcher.tick(now: T0)

    assert_empty sup.spawned,
                 "blocked:true must hold dispatch even when dependency_stage is past the gate"
    event = logger.events.find { |name, attrs| name == :blocked && attrs[:reason] == "dependency_unmet" }
    refute_nil event,
               "the dispatcher must emit :blocked reason=dependency_unmet straight from the blocked flag"
  end

  def test_reload_config_reconfigures_concurrency_limits_in_place
    dispatcher, _sup, controller, logger, _mw = make_dispatcher
    controller.record_dispatch(
      pid: 123,
      project: "hive-bench",
      slug: "existing-run",
      stage: "2-generate",
      command: "hive run existing-run",
      started_at: T0,
      state_file_mtime: T0 - 1
    )
    assert_equal :ok,
                 controller.can_dispatch?(project: "hive-bench", slug: "next-run", now: T0)

    new_cfg = Hive::Config::DEFAULTS.fetch("daemon").merge(
      "max_concurrent_runs" => 2,
      "max_concurrent_per_project" => 1,
      "max_runs_per_day_per_project" => 7,
      "max_concurrent_patrol_scans" => 2
    )
    with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { new_cfg }) do
      dispatcher.send(:reload_config!)
    end

    assert_same controller, dispatcher.controller,
                "reload must retain the controller's in-flight state"
    assert_equal 2, controller.max_concurrent_runs
    assert_equal 1, controller.max_concurrent_per_project
    assert_equal 7, controller.max_runs_per_day_per_project
    assert_equal 2, controller.max_concurrent_patrol_scans
    assert_equal :project_cap,
                 controller.can_dispatch?(project: "hive-bench", slug: "next-run", now: T0),
                 "the reloaded per-project cap must apply immediately"
    reload_event = logger.events.find { |name, _attrs| name == :config_reloaded }
    assert_equal(
      {
        max_concurrent_runs: 2,
        max_concurrent_per_project: 1,
        max_runs_per_day_per_project: 7,
        max_concurrent_patrol_scans: 2
      },
      reload_event&.last,
      "the reload event must expose the effective limits to machine consumers"
    )
  end

  def test_reload_config_reconfigures_operational_snapshot_validity
    snapshot = FakeOperationalSnapshot.new
    dispatcher, = make_dispatcher(rows: [], operational_snapshot: snapshot)
    new_cfg = Hive::Config::DEFAULTS.fetch("daemon").merge("poll_interval_sec" => 45)

    with_replaced_singleton_method(Hive::Config, :load_global_daemon, -> { new_cfg }) do
      dispatcher.send(:reload_config!)
    end

    assert_includes snapshot.calls, [ :reconfigure, { poll_interval_sec: 45 } ]
  end

  def test_answer_digest_scheduler_dispatches_global_answer_digest_without_project_gate
    dispatcher, sup, _ctrl, logger, _mw, _patrol, answer_digest = make_dispatcher(
      rows: [],
      project_enabled: false,
      with_answer_digest_scheduler: true
    )
    answer_digest.next_dispatches = [
      {
        project: "answer_digest",
        slug: "2026-06-13",
        stage: "answer_digest",
        command: "hive answer-digest --date 2026-06-13 --json",
        state_file_mtime: nil,
        state_file_path: nil,
        hive_state_path: nil
      }
    ]

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size
    assert_equal "hive answer-digest --date 2026-06-13 --json", sup.spawned.first[:command]
    assert_equal "answer_digest", sup.spawned.first[:stage]
    event = logger.events.find { |name, _attrs| name == :dispatched }
    assert_equal "answer_digest", event.last.fetch(:trigger)
    refute logger.events.any? { |name, attrs| name == :skipped && attrs[:action] == "answer_digest" },
           "global answer digest must bypass the per-project enable gate"
  end

  def test_answer_digest_dispatch_blocked_when_one_is_in_flight
    dispatcher, sup, ctrl, logger, _mw, _patrol, answer_digest = make_dispatcher(
      rows: [], with_answer_digest_scheduler: true
    )
    ctrl.record_dispatch(
      pid: 999, project: "answer_digest", slug: "2026-06-13", stage: "answer_digest",
      command: "hive answer-digest --date 2026-06-13 --json", started_at: T0 - 5,
      state_file_mtime: nil, kind: :digest
    )
    answer_digest.next_dispatches = [
      {
        project: "answer_digest",
        slug: "2026-06-13",
        stage: "answer_digest",
        command: "hive answer-digest --date 2026-06-13 --json",
        state_file_mtime: nil,
        state_file_path: nil,
        hive_state_path: nil
      }
    ]

    dispatcher.tick(now: T0)

    assert_empty sup.spawned
    assert_equal [ "2026-06-13" ], answer_digest.cancelled
    assert logger.events.any? { |name, attrs| name == :blocked && attrs[:action] == "answer_digest" }
  end

  def test_answer_digest_scheduler_completes_on_answer_digest_child_exit
    dispatcher, sup, = make_dispatcher(rows: [], with_answer_digest_scheduler: true)
    answer_digest = dispatcher.instance_variable_get(:@answer_digest_scheduler)
    sup.next_exits = [
      ChildExit.new(
        pid: 123,
        exit_code: 0,
        project: "answer_digest",
        slug: "2026-06-13",
        stage: "answer_digest",
        command: "hive answer-digest --date 2026-06-13 --json",
        state_file_path: nil,
        started_at: T0 - 5,
        finished_at: T0,
        json_envelope: nil
      )
    ]

    dispatcher.tick(now: T0)

    assert_equal [ { date: "2026-06-13", exit_code: 0, now: T0 } ], answer_digest.completed
  end

  def test_answer_digest_scheduler_tick_raise_is_isolated_as_a_fatal_event
    dispatcher, sup, _ctrl, logger, = make_dispatcher(rows: [], with_answer_digest_scheduler: true)
    raising = Object.new
    raising.define_singleton_method(:tick) { |now:| raise IOError, "ENOSPC on answer digest state" }
    dispatcher.instance_variable_set(:@answer_digest_scheduler, raising)

    dispatcher.tick(now: T0)

    assert_empty sup.spawned
    event = logger.events.find { |name, _| name == :fatal }
    refute_nil event
    assert_match(/answer_digest_scheduler\.tick raised/, event.last.fetch(:message))
  end

  # The fatal-dedup (@digest_scheduler_fatal_signatures) is the whole point of
  # the "dedup scheduler fatals" refactor: a persistently-raising scheduler
  # must log :fatal once (not every ~30s tick), a clean run must re-arm the
  # dedup, and a distinct fault must re-log. Mirrors the sibling
  # brainstorm-parse dedup test. Without this, a regression that never re-arms
  # (silent forever) or never dedups (per-poll :fatal spam) ships green.
  def test_answer_digest_scheduler_tick_fatal_is_deduped_and_rearms
    dispatcher, sup, _ctrl, logger, = make_dispatcher(rows: [], with_answer_digest_scheduler: true)
    controllable = Object.new
    controllable.define_singleton_method(:error=) { |e| @error = e }
    controllable.define_singleton_method(:tick) { |now:| raise @error if @error; [] }
    dispatcher.instance_variable_set(:@answer_digest_scheduler, controllable)

    tick_fatals = lambda do
      logger.events.count do |name, attrs|
        name == :fatal && attrs[:message].to_s.include?("answer_digest_scheduler.tick")
      end
    end

    # Same fault across three ticks logs :fatal exactly once.
    controllable.error = IOError.new("ENOSPC on answer digest state")
    3.times { dispatcher.tick(now: T0) }
    assert_empty sup.spawned
    assert_equal 1, tick_fatals.call,
                 "a persistent scheduler fault must log :fatal once across ticks, not every poll"

    # A clean tick clears the dedup so a later recurrence of the SAME fault re-logs.
    controllable.error = nil
    dispatcher.tick(now: T0)
    controllable.error = IOError.new("ENOSPC on answer digest state")
    dispatcher.tick(now: T0)
    assert_equal 2, tick_fatals.call,
                 "a clean run must re-arm the dedup so the same fault re-logs afterward"

    # A distinct fault signature re-logs even while the prior one was deduped.
    controllable.error = IOError.new("EROFS on answer digest state")
    dispatcher.tick(now: T0)
    assert_equal 3, tick_fatals.call,
                 "a distinct fault signature must re-log rather than be swallowed by the dedup"
  end

  def test_answer_digest_scheduler_complete_raise_is_isolated_as_a_fatal_event
    dispatcher, sup, _ctrl, logger, = make_dispatcher(rows: [], with_answer_digest_scheduler: true)
    raising = Object.new
    raising.define_singleton_method(:complete) do |date:, exit_code:, envelope:, now:|
      raise IOError, "EROFS on cursor write"
    end
    dispatcher.instance_variable_set(:@answer_digest_scheduler, raising)
    sup.next_exits = [
      ChildExit.new(
        pid: 123, exit_code: 0,
        project: "answer_digest", slug: "2026-06-13", stage: "answer_digest",
        command: "hive answer-digest --date 2026-06-13 --json",
        state_file_path: nil, started_at: T0 - 5, finished_at: T0, json_envelope: nil
      )
    ]

    dispatcher.tick(now: T0)

    event = logger.events.find { |name, _| name == :fatal }
    refute_nil event
    assert_match(/answer_digest_scheduler\.complete raised/, event.last.fetch(:message))
  end

  def test_answer_digest_config_exit_does_not_drop_phantom_project
    dispatcher, _sup, ctrl, logger, _mw, _patrol, answer_digest = make_dispatcher(
      rows: [], with_answer_digest_scheduler: true
    )
    sup = dispatcher.instance_variable_get(:@supervisor)
    sup.next_exits = [
      ChildExit.new(
        pid: 123, exit_code: Hive::ExitCodes::CONFIG,
        project: "answer_digest", slug: "2026-06-13", stage: "answer_digest",
        command: "hive answer-digest --date 2026-06-13 --json",
        state_file_path: nil, started_at: T0 - 5, finished_at: T0, json_envelope: nil
      )
    ]

    dispatcher.tick(now: T0)

    refute ctrl.project_dropped?("answer_digest")
    refute logger.events.any? { |name, attrs| name == :project_dropped && attrs[:project] == "answer_digest" }
    assert_equal [ { date: "2026-06-13", exit_code: Hive::ExitCodes::CONFIG, now: T0 } ],
                 answer_digest.completed
  end

  def test_answer_digest_dispatch_spawn_error_records_failed_completion
    dispatcher, sup, _ctrl, logger, _mw, _patrol, answer_digest = make_dispatcher(
      rows: [], with_answer_digest_scheduler: true
    )
    answer_digest.next_dispatches = [
      {
        project: "answer_digest", slug: "2026-06-13", stage: "answer_digest",
        command: "hive answer-digest --date 2026-06-13 --json",
        state_file_mtime: nil, state_file_path: nil, hive_state_path: nil
      }
    ]
    sup.define_singleton_method(:spawn) { |**_| raise Errno::EAGAIN, "fork failed" }

    dispatcher.tick(now: T0)

    assert_equal [ { date: "2026-06-13", exit_code: 1, now: T0 } ], answer_digest.completed
    assert logger.events.any? do |name, attrs|
      name == :fatal && attrs[:message].to_s.include?("answer_digest dispatch error")
    end
  end

  def test_reload_config_reconfigures_answer_digest_scheduler
    dispatcher, _sup, _ctrl, _logger, _mw, _patrol, answer_digest = make_dispatcher(
      rows: [], with_answer_digest_scheduler: true
    )
    original_answer = Hive::Config.method(:load_global_answer_digest_block)
    Hive::Config.define_singleton_method(:load_global_answer_digest_block) do
      { "enabled" => true, "hour" => 11 }
    end
    begin
      dispatcher.send(:reload_config!)
    ensure
      Hive::Config.define_singleton_method(:load_global_answer_digest_block, &original_answer)
    end

    assert_equal({ enabled: true, hour: 11 }, answer_digest.reconfigured&.last)
  end

  def test_dispatches_later_pipeline_stages_first
    # Rows supplied in pipeline order; the dispatcher must flip them so the
    # task closest to done (8-finalize) claims a slot before earlier-stage
    # work (6-review), draining the pipeline rather than starving it.
    rows = [
      row(slug: "rev", stage: "6-review", action: "ready_to_plan", command: "hive run rev"),
      row(slug: "art", stage: "7-artifacts", action: "ready_to_plan", command: "hive run art"),
      row(slug: "fin", stage: "8-finalize", action: "ready_to_plan", command: "hive run fin")
    ]
    dispatcher, sup, = make_dispatcher(rows: rows)

    dispatcher.tick(now: T0)

    assert_equal %w[8-finalize 7-artifacts 6-review], sup.spawned.map { |s| s[:stage] },
                 "tasks closer to the end of the pipeline must dispatch first"
  end

  def test_dispatch_priority_order_is_later_stage_first_and_stable
    rows = [
      row(slug: "a", stage: "2-brainstorm"),
      row(slug: "b", stage: "7-artifacts"),
      row(slug: "c", stage: "6-review"),
      row(slug: "d", stage: "7-artifacts"),
      row(slug: "e", stage: "9-done")
    ]
    dispatcher, = make_dispatcher

    ordered = dispatcher.send(:dispatch_priority_order, rows)

    assert_equal %w[9-done 7-artifacts 7-artifacts 6-review 2-brainstorm],
                 ordered.map(&:stage), "later stages first"
    assert_equal %w[b d], ordered.select { |r| r.stage == "7-artifacts" }.map(&:slug),
                 "stable within a stage — original status order preserved"
  end

  def test_advance_action_skips_when_task_folder_vanished_after_snapshot
    missing = File.join(Dir.tmpdir, "hive-dispatcher-missing-#{Process.pid}-#{rand(1_000_000)}")
    FileUtils.rm_rf(missing)
    rows = [
      row(action: "ready_to_plan",
          command: "hive plan s1 --from 2-brainstorm",
          folder: missing)
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size, "stale snapshot row must not spawn after drop removed the folder"
    # No :dispatched event should fire — Policy.decide ran but the
    # vanished-folder guard suppresses the spawn AFTER the decision.
    refute events_include?(logger, :dispatched),
           "vanished-folder row must not produce a :dispatched log event"
    skipped = logger.events.find { |(name, attrs)| name == :skipped && attrs[:reason] == "folder_missing" }
    refute_nil skipped, "must log :skipped reason: folder_missing"
    assert_equal "s1", skipped[1][:slug]
  end

  # Nil/empty row.folder is a different signal (malformed snapshot)
  # than a folder that vanished between snapshot and dispatch. The
  # dispatcher distinguishes the two so operators reading daemon.log
  # can tell "drop just ran" apart from "the snapshot is broken".
  def test_advance_action_skips_with_distinct_reason_when_row_folder_nil
    folder_dir = make_existing_row_folder(project: "p1", stage: "1-inbox", slug: "s1")
    raw_row = Row.new(
      project: "p1", slug: "s1", stage: "1-inbox", marker: "waiting",
      folder: nil,
      state_file: File.join(folder_dir, "idea.md"),
      state_file_mtime: T0 - 600, action: "ready_to_plan",
      suggested_command: "hive plan s1 --from 2-brainstorm",
      claude_pid_alive: nil
    )
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: [ raw_row ])

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size, "nil-folder row must not spawn"
    skipped = logger.events.find { |(name, attrs)| name == :skipped && attrs[:reason] == "folder_missing_nil" }
    refute_nil skipped,
               "nil row.folder must log :skipped reason: folder_missing_nil (distinct from folder_missing)"
    assert_equal "s1", skipped[1][:slug]
  end

  def test_disabled_project_is_skipped
    rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows, project_enabled: false)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size
    refute events_include?(logger, :dispatched)
  end

  # PR-40 follow-up #2: the @enabled_cache must clear at the start of
  # each tick so a `daemon.enabled: false` edit in the project's YAML
  # takes effect on the next poll. Previously the cache persisted for
  # the daemon's lifetime and only SIGHUP cleared it — meaning a
  # disable could be silently ignored for hours.
  def test_enable_cache_clears_at_start_of_each_tick
    rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
    dispatcher, sup, _ctrl, _logger, _mw = make_dispatcher(rows: rows, project_enabled: true)

    # Pre-seed the cache as if a previous tick saw the project enabled.
    dispatcher.instance_variable_get(:@enabled_cache)["p1"] = true
    # Now redefine project_enabled? to return false from THIS point on
    # (simulates the operator editing the YAML to disable the project).
    dispatcher.define_singleton_method(:project_enabled?) { |_| false }

    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size,
                 "tick must re-resolve enable status — stale cache cannot keep dispatch alive"
  end

  def test_recover_stale_action_is_skipped_with_log
    rows = [ row(action: "recover_review", marker: "review_error", stage: "6-review",
                 command: nil) ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size
    skipped = logger.events.find { |(n, _)| n == :skipped }
    refute_nil skipped, "recover_stale row must produce a :skipped event"
  end

  def test_archive_action_routes_to_merge_watcher
    rows = [ row(stage: "8-finalize", action: "ready_to_archive",
                 command: "hive archive s1 --from 8-finalize") ]
    dispatcher, sup, _ctrl, _logger, mw = make_dispatcher(rows: rows, with_merge_watcher: true)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size, "archive must NOT spawn directly"
    assert_equal rows, mw.observed.first.fetch(:rows)
    assert_equal [ "p1" ], mw.tick_projects
  end

  def test_admission_error_remains_observed_and_never_spawns
    error = Hive::DependencyAdmission::AdmissionError.new(
      reason_code: "dependency_repository_mismatch",
      offending_ref: "data:base",
      safe_correction: "Re-enroll the intended repository."
    )
    rows = [ row(stage: "8-finalize", action: "admission_error", command: nil,
                 blocked: true, admission_error: error) ]
    dispatcher, sup, _ctrl, logger, mw = make_dispatcher(rows: rows, with_merge_watcher: true)
    dispatcher.tick(now: T0)

    assert_empty sup.spawned
    assert_equal rows, mw.observed.first.fetch(:rows)
    assert_equal [ "p1" ], mw.tick_projects
    event = logger.events.find { |name, attrs| name == :blocked && attrs[:reason] == "admission_error" }
    refute_nil event
    assert_equal "dependency_repository_mismatch", event[1][:reason_code]
    assert_equal "data:base", event[1][:offending_ref]
  end

  def test_finalize_recoverable_error_routes_to_merge_watcher
    rows = [
      row(stage: "8-finalize", marker: "error",
          marker_attrs: { "reason" => "git_status_failed" },
          action: "error", command: nil)
    ]
    dispatcher, sup, _ctrl, logger, mw = make_dispatcher(rows: rows, with_merge_watcher: true)

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size
    assert_equal rows, mw.observed.first.fetch(:rows)
    refute logger.events.any? { |name, _attrs| name == :dispatched }
  end

  def test_merge_reconciliation_fences_provider_recovery
    observed = row(
      stage: "6-review",
      marker: "review_error",
      action: "recover_review",
      command: "hive run s1 --stage 6-review --json"
    )
    dispatcher, supervisor, _controller, logger, merge_watcher =
      make_dispatcher(rows: [ observed ], with_merge_watcher: true)
    merge_watcher.recovery_blocked = true
    healed_rows = []
    healer = Object.new
    healer.define_singleton_method(:heal_attempt_losses) { |*_args, **_kwargs| [] }
    healer.define_singleton_method(:heal) do |rows, **_kwargs|
      healed_rows << rows
      []
    end
    dispatcher.instance_variable_set(:@stale_agent_healer, healer)

    dispatcher.tick(now: T0)

    assert_equal [ [] ], healed_rows
    assert_empty supervisor.spawned
    assert logger.events.any? { |name, attributes|
      name == :skipped &&
        attributes[:slug] == observed.slug &&
        attributes[:reason] == "merge_reconciliation_pending"
    }
  end

  def test_merged_pr_archive_is_logged_from_the_durable_reconciler
    rows = [ row(stage: "8-finalize", action: "ready_to_archive") ]
    dispatcher, sup, _ctrl, logger, mw = make_dispatcher(
      rows: rows, with_merge_watcher: true
    )
    mw.next_results = [ { project: "p1", slug: "s1", status: :archived } ]
    dispatcher.tick(now: T0)
    assert_empty sup.spawned
    completed = logger.events.find do |name, attrs|
      name == :completed && attrs[:action] == "archive_merged_task"
    end
    refute_nil completed
    assert_equal "archived", completed[1][:reason]
  end

  def test_merge_reconciliation_logs_observation_blocks_and_nonterminal_remote_states
    rows = [ row(stage: "8-finalize", action: "ready_to_archive") ]
    dispatcher, _supervisor, _controller, logger, watcher =
      make_dispatcher(rows: rows, with_merge_watcher: true)
    watcher.define_singleton_method(:observe) do |*, **|
      [
        {
          status: :blocked,
          project: "p1",
          reason: "candidate identity is ambiguous"
        }
      ]
    end
    watcher.next_results = [
      { project: "p1", slug: "open", status: :open },
      { project: "p1", slug: "closed", status: :closed_unmerged },
      { project: "p1", slug: "dry", status: :dry_run }
    ]

    dispatcher.tick(now: T0)

    assert logger.events.any? do |name, attrs|
      name == :blocked &&
        attrs[:action] == "observe" &&
        attrs[:reason] == "candidate identity is ambiguous"
    end
    assert logger.events.any? do |name, attrs|
      name == :skipped && attrs[:slug] == "open" &&
        attrs[:reason] == "pull_request_open"
    end
    assert logger.events.any? do |name, attrs|
      name == :blocked && attrs[:slug] == "closed" &&
        attrs[:reason] == "pull_request_closed_unmerged"
    end
    assert logger.events.any? do |name, attrs|
      name == :skipped && attrs[:slug] == "dry" &&
        attrs[:reason] == "dry_run"
    end
  end

  def test_merge_reconciliation_recovery_guard_fails_closed
    observed = row(
      stage: "6-review",
      marker: "review_error",
      action: "recover_review",
      command: "hive run s1 --stage 6-review --json"
    )
    dispatcher, supervisor, _controller, logger, watcher =
      make_dispatcher(rows: [ observed ], with_merge_watcher: true)
    watcher.define_singleton_method(:recovery_blocked?) do |**|
      raise IOError, "ledger unreadable"
    end

    dispatcher.tick(now: T0)

    assert_empty supervisor.spawned
    assert logger.events.any? do |name, attrs|
      name == :blocked &&
        attrs[:action] == "recovery_guard" &&
        attrs[:reason].include?("ledger unreadable")
    end
  end

  def test_merge_reconciliation_failures_remain_visible_without_drop
    rows = [ row(stage: "6-review", action: "error") ]
    dispatcher, _sup, _ctrl, logger, mw = make_dispatcher(
      rows: rows, with_merge_watcher: true
    )
    mw.next_results = [ {
      project: "p1", slug: "s1", status: :failed, reason: "gh api failed"
    } ]

    dispatcher.tick(now: T0)

    event = logger.events.find do |name, attrs|
      name == :blocked && attrs[:action] == "archive_merged_task"
    end
    refute_nil event
    assert_equal "gh api failed", event[1][:reason]
  end

  def test_merge_reconciliation_skips_disabled_project
    rows = [ row(stage: "8-finalize", action: "ready_to_archive") ]
    dispatcher, sup, _ctrl, logger, mw = make_dispatcher(
      rows: rows, with_merge_watcher: true, project_enabled: false
    )
    dispatcher.tick(now: T0)
    assert_empty sup.spawned
    assert_empty mw.observed.first.fetch(:rows)
    assert_empty mw.tick_projects
    refute(logger.events.any? do |name, attrs|
      name == :completed && attrs[:action] == "archive_merged_task"
    end)
  end

  def test_merge_reconciliation_skips_legacy_layout
    rows = [ row(stage: "8-finalize", action: "ready_to_archive") ]
    dispatcher, sup, _ctrl, logger, mw = make_dispatcher(
      rows: rows, with_merge_watcher: true
    )
    legacy_project = Hive::Daemon::StatusConsumer::ProjectInfo.new(
      name: "p1",
      legacy_stage_dirs: [ { "stage_dir" => "7-finalize", "task_count" => 1 } ]
    )
    dispatcher.instance_variable_get(:@status_consumer).next_result =
      Hive::Daemon::StatusConsumer::Result.new(
        ok: true, rows: rows, projects: [ legacy_project ], error: nil
      )
    dispatcher.tick(now: T0)
    assert_empty sup.spawned
    assert_empty mw.observed.first.fetch(:rows)
    assert_empty mw.tick_projects
    refute(logger.events.any? do |name, attrs|
      name == :completed && attrs[:action] == "archive_merged_task"
    end)
  end

  def test_merge_reconciliation_does_not_consume_provider_capacity
    rows = [ row(stage: "8-finalize", action: "ready_to_archive") ]
    dispatcher, sup, ctrl, logger, mw = make_dispatcher(
      rows: rows, with_merge_watcher: true
    )
    ctrl.instance_variable_set(:@max_concurrent_runs, 1)
    ctrl.record_dispatch(
      pid: 999, project: "px", slug: "running",
      stage: "6-review", command: "hive run", started_at: T0,
      state_file_mtime: T0 - 60
    )

    mw.next_results = [ { project: "p1", slug: "s1", status: :archived } ]
    dispatcher.tick(now: T0)
    assert_empty sup.spawned
    assert(logger.events.any? do |name, attrs|
      name == :completed && attrs[:action] == "archive_merged_task"
    end)
  end

  def test_patrol_scheduler_dispatches_through_supervisor
    dispatcher, sup, _ctrl, logger, _mw, patrol = make_dispatcher(
      rows: [], with_patrol_scheduler: true
    )
    patrol.next_dispatches = [ {
      project: "p1", slug: "patrol", stage: "patrol",
      command: "hive patrol p1 --json",
      state_file_mtime: nil, state_file_path: nil, hive_state_path: "/tmp/state"
    } ]

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size
    assert_equal "hive patrol p1 --json", sup.spawned.first[:command]
    assert_equal "patrol", sup.spawned.first[:stage]
    event = logger.events.find { |(name, attrs)| name == :dispatched && attrs[:trigger] == "patrol" }
    refute_nil event
  end

  def test_patrol_recovery_diagnostics_are_forwarded_to_the_daemon_log
    dispatcher, _sup, _ctrl, logger, _mw, patrol = make_dispatcher(
      rows: [], with_patrol_scheduler: true
    )
    patrol.events << {
      status: :blocked,
      project: "p1",
      occurrence_id: "occ-1",
      recovery: "occurrence_outbox_projection",
      blocker: "recovery_failed",
      retry_count: 1,
      retry_in_sec: 60,
      retry_at: (T0 + 60).utc.iso8601
    }

    dispatcher.tick(now: T0)

    event = logger.events.find do |name, attrs|
      name == :patrol_recovery_blocked &&
        attrs[:occurrence_id] == "occ-1"
    end
    refute_nil event
    refute event.last.key?(:status)
    assert_equal 60, event.last.fetch(:retry_in_sec)
  end

  def test_patrol_dispatch_skips_when_project_disabled
    dispatcher, sup, _ctrl, logger, _mw, patrol = make_dispatcher(
      rows: [], with_patrol_scheduler: true, project_enabled: false
    )
    patrol.next_dispatches = [ {
      project: "p1", slug: "patrol", stage: "patrol",
      command: "hive patrol p1 --json", state_file_mtime: nil,
      state_file_path: nil, hive_state_path: nil
    } ]

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size
    skipped = logger.events.find { |(name, attrs)| name == :skipped && attrs[:action] == "patrol" }
    refute_nil skipped
    assert_equal "project_disabled", skipped[1][:reason]
    assert_includes patrol.cancelled, "p1",
                    "a gated patrol must release the scheduler's pending marker or the project wedges forever"
  end

  def test_patrol_scan_not_blocked_by_full_task_cap
    dispatcher, sup, ctrl, _logger, _mw, patrol = make_dispatcher(
      rows: [], with_patrol_scheduler: true
    )
    # Fill the TASK cap with a task-kind run.
    ctrl.instance_variable_set(:@max_concurrent_runs, 1)
    ctrl.record_dispatch(pid: 999, project: "p1", slug: "running", stage: "6-review",
                         command: "hive review running", started_at: T0,
                         state_file_mtime: T0 - 60, kind: :task)
    patrol.next_dispatches = [ {
      project: "p1", slug: "patrol", stage: "patrol",
      command: "hive patrol p1 --json", state_file_mtime: nil,
      state_file_path: nil, hive_state_path: nil
    } ]

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size,
                 "a patrol scan runs on its own budget and is not blocked by a full task cap"
    assert_equal "hive patrol p1 --json", sup.spawned.first[:command]
  end

  def test_patrol_scan_blocked_when_its_own_budget_is_full
    dispatcher, sup, ctrl, logger, _mw, patrol = make_dispatcher(
      rows: [], with_patrol_scheduler: true
    )
    # Fill the PER-PROJECT patrol-scan budget (default 1) for p1 with a
    # running scan, then attempt a SECOND scan for the SAME project.
    ctrl.record_dispatch(pid: 999, project: "p1", slug: "patrol-running", stage: "patrol",
                         command: "hive patrol p1 --json", started_at: T0,
                         state_file_mtime: nil, kind: :patrol_scan)
    patrol.next_dispatches = [ {
      project: "p1", slug: "patrol", stage: "patrol",
      command: "hive patrol p1 --json", state_file_mtime: nil,
      state_file_path: nil, hive_state_path: nil
    } ]

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size
    blocked = logger.events.find { |(name, attrs)| name == :blocked && attrs[:action] == "patrol" }
    refute_nil blocked
    assert_equal "patrol_scan_cap", blocked[1][:reason]
    assert_includes patrol.cancelled, "p1",
                    "a budget-gated patrol must release its pending marker so it retries when the scan budget frees"
  end

  # Per-project patrol-scan cap: a running scan for one project must NOT
  # block a scan for a DIFFERENT project — projects patrol in parallel.
  def test_patrol_scan_for_other_project_not_blocked_by_running_scan
    dispatcher, sup, ctrl, _logger, _mw, patrol = make_dispatcher(
      rows: [], with_patrol_scheduler: true
    )
    ctrl.record_dispatch(pid: 999, project: "p1", slug: "patrol-running", stage: "patrol",
                         command: "hive patrol p1 --json", started_at: T0,
                         state_file_mtime: nil, kind: :patrol_scan)
    patrol.next_dispatches = [ {
      project: "p2", slug: "patrol", stage: "patrol",
      command: "hive patrol p2 --json", state_file_mtime: nil,
      state_file_path: nil, hive_state_path: nil
    } ]

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size,
                 "a different project's scan must dispatch while p1's scan runs"
    assert_equal "hive patrol p2 --json", sup.spawned.first[:command]
  end

  def test_patrol_dispatch_skips_legacy_layout_project
    legacy_project = Hive::Daemon::StatusConsumer::ProjectInfo.new(
      name: "p1",
      legacy_stage_dirs: [ "1-inbox" ]
    )
    status_result = Hive::Daemon::StatusConsumer::Result.new(
      ok: true,
      rows: [],
      projects: [ legacy_project ],
      error: nil
    )
    dispatcher, sup, _ctrl, logger, _mw, patrol = make_dispatcher(
      rows: [], with_patrol_scheduler: true, status_result: status_result
    )
    patrol.next_dispatches = [ {
      project: "p1", slug: "patrol", stage: "patrol",
      command: "hive patrol p1 --json", state_file_mtime: nil,
      state_file_path: nil, hive_state_path: nil
    } ]

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size
    skipped = logger.events.find { |(name, attrs)| name == :skipped && attrs[:action] == "patrol" }
    refute_nil skipped
    assert_equal "legacy_layout_detected", skipped[1][:reason]
    assert_includes patrol.cancelled, "p1"
  end

  def test_patrol_dispatch_spawn_error_completes_scheduler_with_failure
    dispatcher, sup, _ctrl, logger, _mw, patrol = make_dispatcher(
      rows: [], with_patrol_scheduler: true
    )
    def sup.spawn(**)
      raise RuntimeError, "spawn failed"
    end
    patrol.next_dispatches = [ {
      project: "p1", slug: "patrol", stage: "patrol",
      command: "hive patrol p1 --json", state_file_mtime: nil,
      state_file_path: nil, hive_state_path: nil
    } ]

    dispatcher.tick(now: T0)

    assert_equal [ { project: "p1", exit_code: 1, now: T0 } ], patrol.completed
    fatal = logger.events.find { |(name, attrs)| name == :fatal && attrs[:slug] == "patrol" }
    refute_nil fatal
  end

  def test_patrol_completion_is_reported_to_scheduler
    config = { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100
    )
    supervisor = FakeSupervisor.new
    def supervisor.reap_all(now: Time.now)
      return [] if @reaped

      @reaped = true
      [ ChildExit.new(pid: 901, exit_code: 0, project: "p1", slug: "patrol",
                      stage: "patrol", command: "hive patrol p1 --json",
                      started_at: T0, finished_at: now, json_envelope: nil) ]
    end
    controller.record_dispatch(pid: 901, project: "p1", slug: "patrol", stage: "patrol",
                               command: "hive patrol p1 --json", started_at: T0,
                               state_file_mtime: nil)
    status = FakeStatusConsumer.new
    logger = StubLogger.new
    patrol = FakePatrolScheduler.new
    dispatcher = Hive::Daemon::Dispatcher.new(
      config: config, controller: controller, supervisor: supervisor,
      status_consumer: status, logger: logger, patrol_scheduler: patrol
    )

    dispatcher.tick(now: T0 + 10)

    assert_equal [ { project: "p1", exit_code: 0, now: T0 + 10 } ], patrol.completed
  end

  def test_edit_action_within_debounce_after_baseline_logs_debouncing
    # With a baseline already recorded (i.e. NOT first sight), a fresh
    # edit within the debounce window logs :debouncing and does not
    # dispatch.
    rows = [ row(action: "needs_input", marker: "waiting",
                 command: "hive brainstorm s1 --from 2-brainstorm",
                 mtime: T0 - 5) ]
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
    ctrl.observe_state_file_mtime(project: "p1", slug: "s1", mtime: T0 - 600)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size
    assert events_include?(logger, :debouncing)
  end

  def test_edit_action_first_sight_records_baseline_does_not_dispatch
    # PR-40 review P1 #1: first sight of `kind: edit` cannot tell if
    # the file has fresh user edits or just the agent's WAITING write.
    # Skip + seed the controller with the current mtime so the next
    # tick has a baseline. A subsequent tick where mtime moves past
    # the baseline triggers the actual dispatch.
    rows = [ row(action: "needs_input", marker: "waiting",
                 command: "hive brainstorm s1 --from 2-brainstorm",
                 mtime: T0 - 600) ]
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.tick(now: T0)
    assert_equal 0, sup.spawned.size, "first-sight kind: edit must not dispatch"
    # Baseline got recorded
    refute_nil ctrl.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
    # Logged as :skipped with reason: baseline_recorded
    skipped = logger.events.find { |(n, a)| n == :skipped && a[:reason] == "baseline_recorded" }
    refute_nil skipped, "must log :skipped reason: baseline_recorded"
  end

  def test_blocked_first_sight_edit_resume_still_records_baseline
    # A first-sight edit-resume row that is ALSO dependency-blocked must
    # still seed its mtime baseline (the `:record_baseline` arm passes
    # through the dependency gate, which only intercepts the terminal
    # `:dispatch`). Otherwise the row would never get a baseline and could
    # never resume once the block clears.
    rows = [ row(action: "needs_input", marker: "waiting",
                 command: "hive brainstorm s1 --from 2-brainstorm",
                 mtime: T0 - 600,
                 depends_on: "base-task", blocked_by: "base-task",
                 dependency_stage: "7-artifacts", blocked: true) ]
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size, "a blocked first-sight row must not dispatch"
    refute_nil ctrl.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1"),
               "the blocked first-sight row must still seed its mtime baseline"
    skipped = logger.events.find { |(n, a)| n == :skipped && a[:reason] == "baseline_recorded" }
    refute_nil skipped, "must log :skipped reason: baseline_recorded even when blocked"
  end

  def test_plan_needs_input_first_sight_dispatches_without_baseline
    # End-to-end fix for PR #83's P0: the production command for a
    # `plan_waiting` row is `hive plan ...` (per TaskAction; see the
    # `plan_waiting` entry in lib/hive/task_action.rb). The daemon
    # rewrites it to `hive develop ...` AND flips the `:waiting`
    # marker to `:complete` before dispatch so the workflow verb's
    # terminal-marker gate (VALID_TERMINAL_MARKERS) accepts the
    # advance. Both steps live in Hive::Daemon::PlanApproval.
    Dir.mktmpdir("dispatcher-plan-approval") do |dir|
      state_file = File.join(dir, "plan.md")
      File.write(state_file, "# plan\n\n<!-- WAITING -->\n")

      rows = [ row(stage: "3-plan", action: "needs_input", marker: "waiting",
                   command: "hive plan s1 --from 3-plan",
                   mtime: T0 - 600, state_file: state_file) ]
      dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
      dispatcher.tick(now: T0)

      # Dispatched the rewritten command (develop, not plan).
      assert_equal 1, sup.spawned.size
      assert_equal "hive develop s1 --from 3-plan", sup.spawned.first[:command],
                   "PlanApproval must rewrite `hive plan ...` to `hive develop ...`"

      # Marker flipped to :complete on disk so `hive develop --from
      # 3-plan` will be accepted by VALID_TERMINAL_MARKERS on the
      # spawned child.
      assert_equal :complete, Hive::Markers.current(state_file).name,
                   "plan-approval auto-dispatch must flip :waiting → :complete"

      # Baseline mtime recorded so subsequent ticks have something
      # to compare against (and don't re-record a baseline).
      assert_equal T0 - 600,
                   ctrl.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
      refute logger.events.any? { |(n, a)| n == :skipped && a[:reason] == "baseline_recorded" }

      # Audit event fired with the trigger field set so log readers
      # can distinguish plan-approval dispatches from advance-action
      # dispatches without re-implementing Policy.decide.
      assert events_include?(logger, :dispatched)
      dispatched_event = logger.events.find { |(n, _a)| n == :dispatched }
      assert_equal "plan_approval", dispatched_event[1][:trigger]
    end
  end

  def test_plan_needs_input_skips_when_marker_is_not_waiting_or_complete
    # PlanApproval.prepare raises NotApprovable for any marker that
    # isn't :waiting or :complete (e.g., :error). The dispatcher must
    # log :skipped and NOT spawn — the workflow verb's WrongStage
    # check would refuse the advance anyway, but failing in Policy is
    # noisier than failing in PlanApproval, so we route to :skip
    # before dispatch.
    Dir.mktmpdir("dispatcher-plan-approval-error") do |dir|
      state_file = File.join(dir, "plan.md")
      File.write(state_file, "# plan\n\n<!-- ERROR reason=plan_failed -->\n")

      rows = [ row(stage: "3-plan", action: "needs_input", marker: "waiting",
                   command: "hive plan s1 --from 3-plan",
                   mtime: T0 - 600, state_file: state_file) ]
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
      dispatcher.tick(now: T0)

      assert_equal 0, sup.spawned.size, "must not spawn when marker isn't :waiting/:complete"
      skip_event = logger.events.find do |(n, a)|
        n == :skipped && a[:reason].to_s.start_with?("plan_approval_invalid")
      end
      refute_nil skip_event,
                 "must log :skipped reason: plan_approval_invalid (got events: #{logger.events.map(&:first).inspect})"
    end
  end

  def test_plan_needs_input_with_malformed_command_skips
    # If the suggested_command is not a well-formed `hive plan ...`
    # invocation (e.g., a stale TaskAction emission or a malformed
    # status JSON row), PlanApproval raises ArgumentError; dispatcher
    # routes to :skip with a reason field instead of spawning a
    # garbage subprocess.
    Dir.mktmpdir("dispatcher-plan-approval-malformed") do |dir|
      state_file = File.join(dir, "plan.md")
      File.write(state_file, "# plan\n\n<!-- WAITING -->\n")

      rows = [ row(stage: "3-plan", action: "needs_input", marker: "waiting",
                   command: "hive review s1 --from 3-plan",
                   mtime: T0 - 600, state_file: state_file) ]
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
      dispatcher.tick(now: T0)

      assert_equal 0, sup.spawned.size
      skip_event = logger.events.find do |(n, a)|
        n == :skipped && a[:reason].to_s.start_with?("plan_approval_invalid")
      end
      refute_nil skip_event
      # Marker NOT flipped — malformed command must leave the
      # marker at :waiting so an operator can inspect.
      assert_equal :waiting, Hive::Markers.current(state_file).name,
                   "malformed command must not flip the marker"
    end
  end

  def test_edit_action_after_baseline_user_edit_dispatches
    rows = [ row(action: "needs_input", marker: "waiting",
                 command: "hive brainstorm s1 --from 2-brainstorm",
                 mtime: T0 - 60) ]
    dispatcher, sup, ctrl, _logger, _mw = make_dispatcher(rows: rows)
    # Pretend a previous tick recorded an older baseline
    ctrl.observe_state_file_mtime(project: "p1", slug: "s1", mtime: T0 - 600)
    dispatcher.tick(now: T0)
    assert_equal 1, sup.spawned.size
  end

  # ── concurrency cap respected ─────────────────────────────────────────

  def test_global_cap_blocks_third_dispatch
    rows = [
      row(slug: "s1", action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm"),
      row(slug: "s2", action: "ready_to_plan", command: "hive plan s2 --from 2-brainstorm"),
      row(slug: "s3", action: "ready_to_plan", command: "hive plan s3 --from 2-brainstorm")
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    # Override controller cap
    dispatcher.controller.instance_variable_set(:@max_concurrent_runs, 2)

    dispatcher.tick(now: T0)
    assert_equal 2, sup.spawned.size
    blocked = logger.events.find { |(n, attrs)| n == :blocked && attrs[:slug] == "s3" }
    refute_nil blocked, "third dispatch must be :blocked when global cap = 2"
    assert_equal "global_cap", blocked[1][:reason]
  end

  def test_status_active_agent_row_counts_toward_project_cap
    rows = [
      row(slug: "running", stage: "6-review", marker: "review_working",
          action: "agent_running", command: nil, claude_pid_alive: true),
      row(slug: "ready", action: "ready_to_plan",
          command: "hive plan ready --from 2-brainstorm")
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.controller.instance_variable_set(:@max_concurrent_per_project, 1)

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size
    blocked = logger.events.find { |(n, attrs)| n == :blocked && attrs[:slug] == "ready" }
    refute_nil blocked, "ready row must block while an active agent is already running"
    assert_equal "project_cap", blocked[1][:reason]
  end

  def test_agent_running_rows_from_prior_daemon_count_toward_global_cap
    rows = [
      row(slug: "already-running", action: "agent_running", command: nil, mtime: T0 - 60),
      row(slug: "ready", action: "ready_to_plan", command: "hive plan ready --from 2-brainstorm")
    ]
    rows.first.claude_pid_alive = true
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
    ctrl.instance_variable_set(:@max_concurrent_runs, 1)

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size
    blocked = logger.events.find { |(n, attrs)| n == :blocked && attrs[:slug] == "ready" }
    refute_nil blocked, "visible running agents must consume capacity after daemon restart"
    assert_equal "global_cap", blocked[1][:reason]
  end

  # Issue #144: a row whose only liveness signal is `live_task_lock`
  # (runner is in the pre-claude_pid window — auto-rebase or other
  # pre-stage work) must consume capacity, otherwise the daemon will
  # dispatch more work and breach the global cap.
  def test_live_task_lock_only_row_counts_toward_global_cap
    rows = [
      row(slug: "rebasing", action: "agent_running", command: nil, mtime: T0 - 60,
          claude_pid_alive: nil, live_task_lock: true),
      row(slug: "ready", action: "ready_to_plan", command: "hive plan ready --from 2-brainstorm")
    ]
    dispatcher, sup, ctrl, logger, _mw = make_dispatcher(rows: rows)
    ctrl.instance_variable_set(:@max_concurrent_runs, 1)

    dispatcher.tick(now: T0)

    assert_equal 0, sup.spawned.size
    blocked = logger.events.find { |(n, attrs)| n == :blocked && attrs[:slug] == "ready" }
    refute_nil blocked, "live_task_lock=true row must consume a global cap slot"
    assert_equal "global_cap", blocked[1][:reason]
  end

  def test_needs_input_rows_do_not_count_toward_project_cap
    rows = [
      row(slug: "waiting", stage: "2-brainstorm", action: "needs_input",
          command: "hive brainstorm waiting --from 2-brainstorm"),
      row(slug: "ready", action: "ready_to_plan",
          command: "hive plan ready --from 2-brainstorm")
    ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    dispatcher.controller.instance_variable_set(:@max_concurrent_per_project, 1)

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size
    assert_equal "ready", sup.spawned.first[:slug]
    refute logger.events.any? { |(n, attrs)| n == :blocked && attrs[:slug] == "ready" }
  end

  def test_status_agent_row_for_daemon_child_is_not_double_counted
    rows = [
      row(slug: "running", stage: "6-review", marker: "review_working",
          action: "agent_running", command: nil, claude_pid_alive: true),
      row(slug: "ready", action: "ready_to_plan",
          command: "hive plan ready --from 2-brainstorm")
    ]
    dispatcher, sup, ctrl, _logger, _mw = make_dispatcher(rows: rows)
    dispatcher.controller.instance_variable_set(:@max_concurrent_runs, 2)
    ctrl.record_dispatch(
      pid: 999, project: "p1", slug: "running",
      stage: "6-review", command: "hive review running",
      started_at: T0, state_file_mtime: T0 - 60
    )

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size,
                 "the status row for a daemon-owned child must not consume a second slot"
    assert_equal "ready", sup.spawned.first[:slug]
  end

  def test_stale_agent_running_row_does_not_consume_capacity
    rows = [
      row(slug: "stale", action: "agent_running", command: nil, mtime: T0 - 60),
      row(slug: "ready", action: "ready_to_plan", command: "hive plan ready --from 2-brainstorm")
    ]
    rows.first.claude_pid_alive = false
    dispatcher, sup, ctrl, _logger, _mw = make_dispatcher(rows: rows)
    ctrl.instance_variable_set(:@max_concurrent_runs, 1)

    dispatcher.tick(now: T0)

    assert_equal 1, sup.spawned.size
    assert_equal "ready", sup.spawned.first[:slug]
  end

  # ── status failure ────────────────────────────────────────────────────

  def test_status_failure_logs_and_returns_no_dispatches
    config = { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100
    )
    supervisor = FakeSupervisor.new
    status = FakeStatusConsumer.new
    status.next_result = Hive::Daemon::StatusConsumer::Result.new(
      ok: false, rows: [], error: "hive status crashed"
    )
    logger = StubLogger.new

    dispatcher = Hive::Daemon::Dispatcher.new(
      config: config, controller: controller, supervisor: supervisor,
      status_consumer: status, logger: logger
    )
    dispatcher.tick(now: T0)
    assert_equal 0, supervisor.spawned.size
    assert events_include?(logger, :status_failure)
  end

  # A forward schema-version skew (newer binary, daemon not restarted) is
  # tolerated: the consumer returns ok=true with a non-fatal `warning`,
  # the tick proceeds and dispatches, and the dispatcher logs the warning
  # once (under the neutral :status_warning event — the channel also carries
  # status-stderr breadcrumbs, so the name is deliberately not skew-specific)
  # instead of crashing the tick.
  def test_forward_schema_skew_warning_is_logged_and_tick_proceeds
    rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows)
    project = Hive::Daemon::StatusConsumer::ProjectInfo.new(name: "p1", legacy_stage_dirs: [])
    dispatcher.instance_variable_get(:@status_consumer).next_result =
      Hive::Daemon::StatusConsumer::Result.new(
        ok: true, rows: rows, projects: [ project ], error: nil,
        warning: "envelope schema v99 is newer than this process (v3); parsing best-effort. " \
                 "Restart the hive daemon to pick up the new schema."
      )
    dispatcher.tick(now: T0)
    assert_equal 1, sup.spawned.size, "forward-skew tick must still dispatch"
    assert events_include?(logger, :status_warning)
  end

  # ── dry run ───────────────────────────────────────────────────────────

  def test_dry_run_passes_flag_to_supervisor
    rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: rows, dry_run: true)
    dispatcher.tick(now: T0)
    assert_equal 1, sup.spawned.size
    assert_equal true, sup.spawned.first[:dry_run]
    assert events_include?(logger, :dry_run)
  end

  # ── child exit handling ───────────────────────────────────────────────

  def test_child_exit_records_completion_and_logs
    config = { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100
    )
    supervisor = FakeSupervisor.new
    # Override reap to return one fake completion
    def supervisor.reap_all(now: Time.now)
      return [] if @reaped
      @reaped = true
      [ ChildExit.new(pid: 999, exit_code: 0, project: "p1", slug: "s1",
                      stage: "6-review", command: "hive run s1",
                      started_at: T0, finished_at: now, json_envelope: nil) ]
    end
    status = FakeStatusConsumer.new
    logger = StubLogger.new

    # Pre-record the dispatch so the controller has something to clear
    controller.record_dispatch(pid: 999, project: "p1", slug: "s1",
                               stage: "6-review", command: "hive run s1",
                               started_at: T0, state_file_mtime: T0 - 60)

    dispatcher = Hive::Daemon::Dispatcher.new(
      config: config, controller: controller, supervisor: supervisor,
      status_consumer: status, logger: logger
    )
    dispatcher.tick(now: T0 + 100)
    assert events_include?(logger, :child_exited)
    assert_equal 0, controller.in_flight_count, "completed child must clear running entry"
  end

  def test_config_exit_drops_project
    config = { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } }
    controller = Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100
    )
    supervisor = FakeSupervisor.new
    def supervisor.reap_all(now: Time.now)
      return [] if @reaped
      @reaped = true
      [ ChildExit.new(pid: 999, exit_code: Hive::ExitCodes::CONFIG, project: "p1",
                      slug: "s1", stage: "6-review", command: "hive run s1",
                      started_at: Time.now, finished_at: now, json_envelope: nil) ]
    end
    controller.record_dispatch(pid: 999, project: "p1", slug: "s1",
                               stage: "6-review", command: "hive run s1",
                               started_at: Time.now, state_file_mtime: Time.now - 60)
    status = FakeStatusConsumer.new
    logger = StubLogger.new

    dispatcher = Hive::Daemon::Dispatcher.new(
      config: config, controller: controller, supervisor: supervisor,
      status_consumer: status, logger: logger
    )
    dispatcher.tick(now: T0)
    assert controller.project_dropped?("p1")
    assert events_include?(logger, :project_dropped)
  end

  def test_admission_error_config_exit_does_not_drop_unrelated_project_work
    dispatcher, _sup, controller, logger, _mw = make_dispatcher(rows: [])
    exit_entry = ChildExit.new(
      pid: 999, exit_code: Hive::ExitCodes::CONFIG, project: "p1", slug: "held",
      stage: "4-execute", command: "hive run held --json", started_at: T0 - 1,
      finished_at: T0, json_envelope: { "ok" => false, "error_kind" => "admission_error" }
    )
    dispatcher.supervisor.define_singleton_method(:reap_all) do |now:|
      next [] if @admission_reaped

      @admission_reaped = true
      [ exit_entry ]
    end

    dispatcher.tick(now: T0)

    refute controller.project_dropped?("p1")
    refute logger.events.any? { |name, attrs| name == :project_dropped && attrs[:project] == "p1" }
  end

  # ── stale-agent healer integration ────────────────────────────────────

  def test_dispatcher_tick_heals_dead_pid_agent_working_marker_on_disk
    # End-to-end wiring test: dispatcher#tick must invoke the real
    # StaleAgentHealer with the tick's frozen `now` and the current
    # legacy_layout_projects set. Plant a real on-disk task.md with
    # AGENT_WORKING and an attached-but-dead pid; assert the marker
    # is rewritten on the same tick that processed it.
    Dir.mktmpdir("dispatcher-healer-integration") do |tmpdir|
      state_file = File.join(tmpdir, "task.md")
      File.write(state_file, "# task\n\n<!-- AGENT_WORKING pid=99999999 -->\n")

      stale_row = row(
        project: "p1", slug: "stale-1", stage: "4-execute",
        marker: "agent_working", action: "error", # post-U4 status produces this
        state_file: state_file,
        mtime: T0 - 1000,
        claude_pid_alive: false
      )
      dispatcher, _sup, _ctrl, logger, _mw = make_dispatcher(rows: [ stale_row ])
      dispatcher.tick(now: T0)

      assert events_include?(logger, :marker_healed),
             "dispatcher#tick must invoke the real healer; events=#{logger.events.inspect}"
      heal_attrs = logger.events.find { |(n, _)| n == :marker_healed }[1]
      assert_equal "agent_died", heal_attrs[:reason]
      assert_match(/ERROR\s+reason=agent_died/, File.read(state_file),
                   "healer must rewrite the on-disk marker, not just log")
    end
  end

  def test_dispatcher_tick_skips_healing_for_legacy_layout_projects
    Dir.mktmpdir("dispatcher-healer-legacy") do |tmpdir|
      state_file = File.join(tmpdir, "task.md")
      File.write(state_file, "# task\n\n<!-- AGENT_WORKING pid=99999999 -->\n")
      stale_row = row(
        project: "legacy-proj", slug: "stale-1", stage: "4-execute",
        marker: "agent_working", action: "error",
        state_file: state_file, mtime: T0 - 1000, claude_pid_alive: false
      )
      legacy_project = Hive::Daemon::StatusConsumer::ProjectInfo.new(
        name: "legacy-proj",
        legacy_stage_dirs: [ { "stage_dir" => "1-input", "task_count" => 1 } ]
      )

      config = { "daemon" => { "edit_debounce_sec" => 30, "poll_interval_sec" => 30 } }
      controller = Hive::Daemon::ConcurrencyController.new(
        max_concurrent_runs: 5, max_concurrent_per_project: 5,
        max_runs_per_day_per_project: 100
      )
      supervisor = FakeSupervisor.new
      status = FakeStatusConsumer.new
      status.next_result = Hive::Daemon::StatusConsumer::Result.new(
        ok: true, rows: [ stale_row ], projects: [ legacy_project ], error: nil
      )
      logger = StubLogger.new
      dispatcher = Hive::Daemon::Dispatcher.new(
        config: config, controller: controller, supervisor: supervisor,
        status_consumer: status, logger: logger
      )

      dispatcher.tick(now: T0)

      refute events_include?(logger, :marker_healed),
             "half-migrated projects must be excluded from healing; events=#{logger.events.inspect}"
      assert_match(/AGENT_WORKING/, File.read(state_file),
                   "marker on disk must be untouched when project is half-migrated")
    end
  end

  def test_dispatcher_outer_rescue_logs_fatal_and_continues_per_row_dispatch
    # If the healer itself raises (a bug, not a per-row disk failure),
    # the dispatcher's outer rescue must log :fatal and let the rest of
    # the tick proceed — so a future healer bug doesn't trigger
    # systemd's StartLimitBurst cap by failing every tick.
    advance_row = row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm")
    dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(rows: [ advance_row ])
    # Stub the dispatcher's healer instance to raise on heal.
    healer = dispatcher.instance_variable_get(:@stale_agent_healer)
    def healer.heal(*, **)
      raise NoMethodError, "simulated healer bug"
    end

    dispatcher.tick(now: T0)

    fatal = logger.events.find { |(n, _)| n == :fatal }
    assert fatal, "outer rescue must log :fatal when healer raises; events=#{logger.events.inspect}"
    assert_includes fatal[1][:message], "stale_agent_healer raised"
    assert_equal 1, sup.spawned.size,
                 "per-row dispatch must still run after healer crash to avoid StartLimitBurst flapping"
  end

  def test_dispatcher_runs_single_universal_healer_before_dispatch
    advance_row = row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm")
    dispatcher, sup, _ctrl, _logger, _mw = make_dispatcher(rows: [ advance_row ])
    order = []
    stale = Object.new
    stale.define_singleton_method(:heal) { |*_args, **_kwargs| order << :stale }
    dispatcher.instance_variable_set(:@stale_agent_healer, stale)

    dispatcher.tick(now: T0)

    assert_equal [ :stale ], order
    assert_equal 1, sup.spawned.size, "dispatch must run after the healer slot"
  end

  def test_boot_healer_uses_the_live_per_project_retry_gate
    dispatcher, = make_dispatcher(project_enabled: false)
    healer = dispatcher.instance_variable_get(:@stale_agent_healer)
    gate = healer.instance_variable_get(:@project_auto_retry_enabled)

    assert_equal false, gate.call("disabled-project")
  end

  def test_reload_config_rebuilds_healer_with_new_grace_sec
    dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
    original_healer = dispatcher.instance_variable_get(:@stale_agent_healer)
    refute_nil original_healer, "dispatcher must construct a healer at boot"

    # Stub Config.load_global_daemon to return a new grace, then reload.
    # `Hive::Config` is a module_function-defined module, so its
    # methods live on the singleton class. Save the original and
    # restore via `define_singleton_method(..., &original)` rather
    # than `remove_method` — the latter would delete the real
    # implementation and break every later test that loads config.
    new_cfg = { "agent_marker_grace_sec" => 60, "edit_debounce_sec" => 30 }
    original = Hive::Config.method(:load_global_daemon)
    Hive::Config.define_singleton_method(:load_global_daemon) { new_cfg }
    begin
      dispatcher.send(:reload_config!)
    ensure
      Hive::Config.define_singleton_method(:load_global_daemon, &original)
    end

    rebuilt = dispatcher.instance_variable_get(:@stale_agent_healer)
    refute_same original_healer, rebuilt,
                "reload_config! must rebuild the healer so new daemon.agent_marker_grace_sec binds"
    assert_equal 60, rebuilt.instance_variable_get(:@grace_sec),
                 "rebuilt healer must carry the reloaded grace value"
    gate = rebuilt.instance_variable_get(:@project_auto_retry_enabled)
    assert_equal true, gate.call("enabled-project"),
                 "the rebuilt healer must retain the live per-project gate"
  end

  def test_reload_config_applies_auto_retry_kill_switch_to_universal_healer
    dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
    original_healer = dispatcher.instance_variable_get(:@stale_agent_healer)

    new_cfg = {
      "agent_marker_grace_sec" => 60,
      "edit_debounce_sec" => 30,
      "auto_retry" => { "enabled" => false }
    }
    original = Hive::Config.method(:load_global_daemon)
    Hive::Config.define_singleton_method(:load_global_daemon) { new_cfg }
    begin
      dispatcher.send(:reload_config!)
    ensure
      Hive::Config.define_singleton_method(:load_global_daemon, &original)
    end

    rebuilt = dispatcher.instance_variable_get(:@stale_agent_healer)
    refute_same original_healer, rebuilt,
                "reload_config! must rebuild the universal healer"
    assert_equal false, rebuilt.auto_retry_enabled?
  end

def test_run_forever_reloads_ticks_and_shuts_down_cleanly
  dispatcher, supervisor, _ctrl, logger, _mw = make_dispatcher
  ticks = 0
  reloads = 0
  sleeps = []

  dispatcher.define_singleton_method(:install_signal_handlers!) { true }
  dispatcher.define_singleton_method(:reload_config!) { reloads += 1 }
  dispatcher.define_singleton_method(:interruptible_sleep) { |seconds| sleeps << seconds }
  dispatcher.define_singleton_method(:tick) do |now: Time.now|
    ticks += 1
    request_reload! if ticks == 1
    request_shutdown! if ticks == 2
  end

  dispatcher.run_forever

  assert_equal 2, ticks
  assert_equal 1, reloads
  assert_equal [ 1, 1 ], sleeps
  assert events_include?(logger, :dispatcher_started)
  assert events_include?(logger, :dispatcher_stopping)
  assert_equal 0, supervisor.spawned.size
end

def test_shutdown_acknowledgement_records_closed_admission_and_child_inventory
  snapshot = FakeOperationalSnapshot.new
  dispatcher, supervisor = make_dispatcher(operational_snapshot: snapshot)
  supervisor.shutdown_proof = {
    drained: true,
    child_inventory: [ { pid: 88, pgid: 88, start_time: "child-start" } ]
  }

  dispatcher.send(:publish_shutdown_acknowledgement, now: T0)

  method, payload = snapshot.calls.last
  assert_equal :shutdown, method
  assert_equal true, payload.fetch(:admission_closed)
  assert_equal true, payload.fetch(:drained)
  assert_equal [ 88 ], payload.fetch(:child_inventory).map { |entry| entry.fetch(:pid) }
end

def test_run_forever_routes_shutdown_child_exit_through_architecture_completion
  architecture = FakeRefactorPatrolScheduler.new
  architecture.completion_status = :retry
  dispatcher, supervisor, _ctrl, logger = make_dispatcher(
    refactor_patrol_scheduler: architecture
  )
  token = {
    kind: :architecture_patrol, phase: :discovery,
    job_id: "job-7", owner: "daemon", generation: 1
  }
  supervisor.shutdown_exits = [
    ChildExit.new(
      pid: 100, exit_code: nil, project: "p1",
      slug: "refactor-patrol-job-7", stage: "refactor-patrol",
      command: "hive refactor-patrol p1", started_at: T0,
      finished_at: T0 + 1, json_envelope: nil, dispatch_token: token
    )
  ]

  dispatcher.define_singleton_method(:install_signal_handlers!) { true }
  dispatcher.define_singleton_method(:tick) { |now:| request_shutdown! }
  dispatcher.define_singleton_method(:interruptible_sleep) { |_seconds| nil }

  dispatcher.run_forever

  assert_equal 1, architecture.completed.size
  assert_nil architecture.completed.first.fetch(:exit_code)
  assert_equal token, architecture.completed.first.fetch(:dispatch_token)
  assert logger.events.any? { |name, attrs|
    name == :architecture_patrol_blocked && attrs[:job_id] == "job-7"
  }
end

def test_run_forever_marks_signal_reaped_terminal_recovery_failed
  Dir.mktmpdir("hive-shutdown-recovery") do |state_home|
    recovery = dispatcher_recovery(phase: "dispatched").merge(
      "attempt_id" => "attempt-shutdown"
    )
    Q.write_request!(
      project: "p1", slug: "s1", argv: %w[hive run s1 --json],
      requestor: "daemon", trigger: "recovery",
      request_id: "recovery-shutdown", recovery: recovery,
      state_home: state_home, now: T0
    )
    coordinator = FakeRecoveryCoordinator.new(status: "queued")
    dispatcher, supervisor, = make_dispatcher(
      dispatch_request_state_home: state_home,
      recovery_coordinator: coordinator
    )
    supervisor.shutdown_exits = [
      ChildExit.new(
        pid: 101, exit_code: nil, project: "p1", slug: "s1",
        stage: "4-execute", command: "hive run s1 --json",
        started_at: T0, finished_at: T0 + 1, json_envelope: nil,
        request_id: "recovery-shutdown"
      )
    ]
    dispatcher.define_singleton_method(:install_signal_handlers!) { true }
    dispatcher.define_singleton_method(:tick) { |now:| request_shutdown! }
    dispatcher.define_singleton_method(:interruptible_sleep) { |_seconds| nil }

    dispatcher.run_forever

    marked = coordinator.marked.fetch(0)
    assert_equal "attempt-shutdown", marked.fetch(:attempt_id)
    assert_equal true, marked.fetch(:terminal)
    assert_equal "failed", marked.fetch(:outcome)
  end
end

def test_run_forever_escalates_to_full_tick_when_cheap_probe_detects_change
  # Drive the fast-poll escalation branch in run_forever (dispatcher.rb
  # 323-324): on a fast poll where no full tick is due, a cheap probe
  # that detects a change must run a full `tick`. The full tick is
  # observable via the real per-row dispatch spawning a child.
  rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
  dispatcher, supervisor, _ctrl, logger, _mw = make_dispatcher(rows: rows)

  dispatcher.define_singleton_method(:install_signal_handlers!) { true }
  dispatcher.define_singleton_method(:recover_dispatch_claims) { |now:| nil }

  # No full tick is due on this iteration; the cheap probe says a change
  # was detected, so the elsif branch must fire a full tick.
  dispatcher.define_singleton_method(:full_tick_due?) { |_now| false }
  probe_calls = 0
  dispatcher.define_singleton_method(:cheap_probe_requires_full_tick?) do |now:|
    probe_calls += 1
    true
  end
  # Stop after the single escalated tick so the loop terminates.
  dispatcher.define_singleton_method(:interruptible_sleep) do |_seconds|
    request_shutdown!
  end

  dispatcher.run_forever

  assert_equal 1, probe_calls, "the cheap probe must be consulted on the fast-poll iteration"
  assert_equal 1, supervisor.spawned.size,
               "a cheap probe detecting a change must escalate to a full tick that dispatches"
  assert_equal "hive plan s1 --from 2-brainstorm", supervisor.spawned.first[:command]
  assert events_include?(logger, :dispatched)
end

def test_run_forever_skips_escalated_tick_when_shutdown_requested_mid_probe
  # The escalated tick is guarded by `unless @shutdown || @reload`
  # (dispatcher.rb 324): if shutdown is requested while the cheap probe
  # runs, the full tick must NOT fire.
  rows = [ row(action: "ready_to_plan", command: "hive plan s1 --from 2-brainstorm") ]
  dispatcher, supervisor, _ctrl, _logger, _mw = make_dispatcher(rows: rows)

  dispatcher.define_singleton_method(:install_signal_handlers!) { true }
  dispatcher.define_singleton_method(:recover_dispatch_claims) { |now:| nil }
  dispatcher.define_singleton_method(:full_tick_due?) { |_now| false }
  dispatcher.define_singleton_method(:cheap_probe_requires_full_tick?) do |now:|
    # Simulate a shutdown signal landing while the probe runs.
    request_shutdown!
    true
  end
  dispatcher.define_singleton_method(:interruptible_sleep) { |_seconds| nil }

  dispatcher.run_forever

  assert_equal 0, supervisor.spawned.size,
               "shutdown mid-probe must suppress the escalated full tick"
end

def test_fast_probe_does_not_fetch_status_when_idle_and_mtimes_unchanged
  folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "s1")
  state_file = File.join(folder, "brainstorm.md")
  File.write(state_file, "WAITING\n")
  status_row = row(
    stage: "2-brainstorm", action: "needs_input", command: "hive brainstorm s1",
    folder: folder, state_file: state_file, mtime: File.mtime(state_file)
  )
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher(rows: [ status_row ])
  status = dispatcher.instance_variable_get(:@status_consumer)

  dispatcher.tick(now: T0)
  assert_equal 1, status.fetch_count

  refute dispatcher.send(:cheap_probe_requires_full_tick?, now: T0 + 1)
  assert_equal 1, status.fetch_count, "fast probe must not run the expensive status scan"
end

def test_fast_probe_requests_full_tick_when_tracked_state_file_mtime_changes
  folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "s1")
  state_file = File.join(folder, "brainstorm.md")
  File.write(state_file, "WAITING\n")
  status_row = row(
    stage: "2-brainstorm", action: "needs_input", command: "hive brainstorm s1",
    folder: folder, state_file: state_file, mtime: File.mtime(state_file)
  )
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher(rows: [ status_row ])
  status = dispatcher.instance_variable_get(:@status_consumer)

  dispatcher.tick(now: T0)
  File.utime(Time.now + 5, Time.now + 5, state_file)

  assert dispatcher.send(:cheap_probe_requires_full_tick?, now: T0 + 1)
  assert_equal 1, status.fetch_count, "mtime probe should request a full tick without fetching itself"
end

def test_fast_probe_reaps_child_exit_before_requesting_full_tick
  dispatcher, sup, controller, logger, _mw = make_dispatcher(rows: [])
  dispatch_time = T0 - 10
  controller.record_dispatch(
    pid: 123, project: "p1", slug: "s1", stage: "4-execute",
    command: "hive develop s1", started_at: dispatch_time, state_file_mtime: nil
  )
  exited = ChildExit.new(
    pid: 123, exit_code: Hive::ExitCodes::SUCCESS, project: "p1", slug: "s1",
    stage: "4-execute", command: "hive develop s1", state_file_path: nil,
    started_at: dispatch_time, finished_at: T0, json_envelope: nil, request_id: nil
  )
  sup.define_singleton_method(:reap_all) { |now:| [ exited ] }
  status = dispatcher.instance_variable_get(:@status_consumer)

  assert dispatcher.send(:cheap_probe_requires_full_tick?, now: T0)
  assert_equal 0, controller.in_flight_count
  assert_equal 0, status.fetch_count
  assert events_include?(logger, :child_exited)
end

def test_request_methods_flip_lifecycle_flags
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher

  dispatcher.request_reload!
  dispatcher.request_shutdown!

  assert_equal true, dispatcher.instance_variable_get(:@reload)
  assert_equal true, dispatcher.instance_variable_get(:@shutdown)
end

def test_install_signal_handlers_sets_shutdown_and_reload_flags
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
  old_handlers = {}
  %w[TERM INT HUP].each { |signal| old_handlers[signal] = Signal.trap(signal, "IGNORE") }

  begin
    dispatcher.send(:install_signal_handlers!)
    Process.kill("HUP", Process.pid)
    sleep 0.01
    assert_equal true, dispatcher.instance_variable_get(:@reload)

    dispatcher.instance_variable_set(:@shutdown, false)
    Process.kill("INT", Process.pid)
    sleep 0.01
    assert_equal true, dispatcher.instance_variable_get(:@shutdown)

    dispatcher.instance_variable_set(:@shutdown, false)
    Process.kill("TERM", Process.pid)
    sleep 0.01
    assert_equal true, dispatcher.instance_variable_get(:@shutdown)
  ensure
    old_handlers.each { |signal, handler| Signal.trap(signal, handler) }
  end
end

def test_refresh_post_completion_mtime_records_existing_state_file
  dispatcher, _sup, ctrl, _logger, _mw = make_dispatcher

  Dir.mktmpdir("dispatcher-completion-mtime") do |dir|
    state_file = File.join(dir, "task.md")
    File.write(state_file, "# task\n")
    File.utime(T0 - 10, T0 - 10, state_file)
    child = ChildExit.new(
      pid: 999, exit_code: 0, project: "p1", slug: "s1", stage: "6-review",
      command: "hive review s1", state_file_path: state_file,
      started_at: T0 - 100, finished_at: T0, json_envelope: nil
    )

    dispatcher.send(:refresh_post_completion_mtime, child)

    assert_equal File.mtime(state_file),
                 ctrl.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1")
  end
end

def test_success_completion_then_followup_tick_does_not_redispatch_same_stage
  # Plan Unit 1 end-to-end scenario: simulate a SUCCESS where the
  # post-completion mtime refresh has run, then assert the next
  # decision does NOT re-dispatch the same completed stage. This is the
  # single regression that stands in for the deleted SUCCESS cooldown.
  # Its two halves are proven separately elsewhere — the refresh bumps
  # the baseline (test_refresh_post_completion_mtime_records_existing_state_file)
  # and the baseline gates the edit decision (the baseline_recorded /
  # observe_state_file_mtime tests) — here they run as one flow.
  folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "s1")
  state_file = File.join(folder, "brainstorm.md")
  File.write(state_file, "## Round 1\n\n<!-- WAITING -->\n")
  # The agent's post-completion write left the mtime at this value.
  agent_write = T0 - 1
  File.utime(agent_write, agent_write, state_file)

  edit_row = row(
    stage: "2-brainstorm", action: "needs_input", marker: "waiting",
    command: "hive brainstorm s1 --from 2-brainstorm",
    mtime: File.mtime(state_file), state_file: state_file, folder: folder
  )
  dispatcher, sup, ctrl, _logger, _mw = make_dispatcher(rows: [ edit_row ])
  status = dispatcher.instance_variable_get(:@status_consumer)

  # The daemon dispatched a runner for this stage on an earlier tick;
  # seed the in-flight entry with a STALE baseline (pre-agent-write).
  ctrl.record_dispatch(
    pid: 999, project: "p1", slug: "s1", stage: "2-brainstorm",
    command: "hive brainstorm s1 --from 2-brainstorm",
    started_at: T0 - 100, state_file_mtime: T0 - 600
  )

  # Tick 1 reaps the SUCCESS child. refresh_post_completion_mtime bumps
  # the baseline from the stale T0-600 to the file's CURRENT
  # (post-completion) mtime.
  reaped = false
  sup.define_singleton_method(:reap_all) do |now:|
    next [] if reaped

    reaped = true
    [ ChildExit.new(pid: 999, exit_code: Hive::ExitCodes::SUCCESS,
                    project: "p1", slug: "s1", stage: "2-brainstorm",
                    command: "hive brainstorm s1 --from 2-brainstorm",
                    state_file_path: state_file, started_at: T0 - 100,
                    finished_at: T0, json_envelope: nil) ]
  end
  dispatcher.tick(now: T0)

  assert_equal File.mtime(state_file).to_i,
               ctrl.last_dispatched_state_file_mtime_for(project: "p1", slug: "s1").to_i,
               "post-completion refresh must seed the baseline to the agent's last write"
  spawned_after_reap = sup.spawned.size

  # Tick 2 (the follow-up): same row, mtime unchanged. Policy sees
  # mtime == baseline → :skip. The already-completed stage is NOT
  # re-dispatched.
  status.next_result = Hive::Daemon::StatusConsumer::Result.new(
    ok: true, rows: [ edit_row ],
    projects: [ Hive::Daemon::StatusConsumer::ProjectInfo.new(name: "p1", legacy_stage_dirs: []) ],
    error: nil
  )
  dispatcher.tick(now: T0 + 1)

  assert_equal spawned_after_reap, sup.spawned.size,
               "follow-up tick must NOT re-dispatch the just-completed stage"
end

def test_terminal_replay_refreshes_edit_baseline_but_keeps_later_edits_eligible
  observed_mtime = T0 - 60
  edit_row = row(
    stage: "6-review", action: "needs_input", marker: "review_waiting",
    command: "hive review s1 --from 6-review", mtime: observed_mtime
  )
  attempt = Struct.new(:attempt_id, :task_generation, :state)
                  .new("attempt-terminal", "generation-terminal", "terminal")
  admissions = 0
  attempt_dispatcher = Object.new
  attempt_dispatcher.define_singleton_method(:dispatch_request) do |*_args, **_options|
    admissions += 1
    Hive::Attempts::DispatchResult.new(
      status: :terminal_replay, attempt: attempt, receipt: nil,
      attach_descriptor: nil, reason: nil
    )
  end
  dispatcher, _supervisor, controller, logger = make_dispatcher(
    rows: [ edit_row ], attempt_dispatcher: attempt_dispatcher
  )
  status = dispatcher.instance_variable_get(:@status_consumer)
  controller.observe_state_file_mtime(
    project: "p1", slug: "s1", mtime: T0 - 600
  )

  dispatcher.tick(now: T0)
  dispatcher.tick(now: T0 + 30)

  assert_equal 1, admissions,
               "an unchanged successful generation must not be replayed every daemon tick"
  assert_equal observed_mtime,
               controller.last_dispatched_state_file_mtime_for(
                 project: "p1", slug: "s1"
               )
  assert_equal 1, logger.events.count { |name, _attrs| name == :attempt_terminal_replay }

  later_edit = edit_row.dup
  later_edit.state_file_mtime = T0 + 60
  status.next_result = Hive::Daemon::StatusConsumer::Result.new(
    ok: true, rows: [ later_edit ],
    projects: [ Hive::Daemon::StatusConsumer::ProjectInfo.new(name: "p1", legacy_stage_dirs: []) ],
    error: nil
  )
  dispatcher.tick(now: T0 + 120)

  assert_equal 2, admissions, "a genuinely newer edit must remain eligible"
end

def test_reaped_success_dispatches_successor_within_2s_wall_budget
  # Plan Unit 2: pin the ≤2s end-to-end latency bound as a single test
  # with an injected clock. The bound is composed of (a) the fast-poll
  # probe detecting the child exit within one fast_poll_sec, and (b) the
  # triggered full tick reaping the SUCCESS and dispatching its
  # successor in the SAME tick (zero extra wall). fast_poll_sec defaults
  # to 1, so the worst case is one sleep (~1s) plus a same-instant
  # dispatch — comfortably inside 2s.
  fast_poll_sec = 1
  t_exit = T0

  # A row ready to advance to its successor stage. When the predecessor
  # child exits, the fast-probe-triggered tick dispatches this.
  successor = row(stage: "2-brainstorm", action: "ready_to_plan",
                  command: "hive plan s1 --from 2-brainstorm")
  dispatcher, sup, ctrl, _logger, _mw = make_dispatcher(rows: [ successor ])

  # Predecessor in-flight; its SUCCESS exit is queued for the next reap.
  ctrl.record_dispatch(pid: 777, project: "p1", slug: "s1",
                       stage: "2-brainstorm", command: "hive brainstorm s1",
                       started_at: t_exit - 100, state_file_mtime: nil)
  reaped = false
  sup.define_singleton_method(:reap_all) do |now:|
    next [] if reaped

    reaped = true
    [ ChildExit.new(pid: 777, exit_code: Hive::ExitCodes::SUCCESS,
                    project: "p1", slug: "s1", stage: "2-brainstorm",
                    command: "hive brainstorm s1", state_file_path: nil,
                    started_at: t_exit - 100, finished_at: now, json_envelope: nil) ]
  end

  # Injected clock: the worst-case probe fires one fast_poll_sec after
  # the child exits (the loop had just slept when the exit landed).
  t_probe = t_exit + fast_poll_sec
  assert dispatcher.send(:cheap_probe_requires_full_tick?, now: t_probe),
         "child-exit must trip the cheap probe within one fast-poll tick"

  # The probe trips a full tick at the same instant; it dispatches the
  # successor stage.
  t_dispatch = t_probe
  dispatcher.tick(now: t_dispatch)

  assert_equal 1, sup.spawned.size, "the reaped SUCCESS must dispatch its successor"
  assert_operator (t_dispatch - t_exit), :<=, 2.0,
                  "end-to-end child-exit→successor-dispatch must stay within the 2s wall budget"
end

def test_resolve_post_completion_path_finds_advanced_stage_state_file
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher

  Dir.mktmpdir("dispatcher-post-advance") do |dir|
    hive_state_path = File.join(dir, ".hive-state")
    slug_dir = File.join(hive_state_path, "stages", "6-review", "s1")
    FileUtils.mkdir_p(slug_dir)
    older = File.join(slug_dir, "old.md")
    newer = File.join(slug_dir, "review.md")
    File.write(older, "old\n")
    File.write(newer, "new\n")
    File.utime(T0 - 20, T0 - 20, older)
    File.utime(T0 - 10, T0 - 10, newer)
    child = ChildExit.new(
      pid: 999, exit_code: 0, project: "p1", slug: "s1", stage: "4-execute",
      command: "hive develop s1", state_file_path: File.join(dir, "missing.md"),
      started_at: T0 - 100, finished_at: T0, json_envelope: nil
    )

    with_replaced_singleton_method(Hive::Config, :find_project, ->(_project) { { "hive_state_path" => hive_state_path } }) do
      assert_equal newer, dispatcher.send(:resolve_post_completion_path, child)
    end
  end
end

def test_find_post_advance_state_file_handles_missing_and_empty_layouts
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher

  Dir.mktmpdir("dispatcher-empty-post-advance") do |dir|
    hive_state_path = File.join(dir, ".hive-state")
    FileUtils.mkdir_p(File.join(hive_state_path, "stages", "6-review", "s1"))

    assert_nil dispatcher.send(:find_post_advance_state_file, nil, "s1")
    assert_nil dispatcher.send(:find_post_advance_state_file, hive_state_path, "s1")
  end
end

def test_dry_run_reaps_pseudo_children_and_logs_completion
  dispatcher, _sup, ctrl, logger, _mw = make_dispatcher(rows: [], dry_run: true)
  child = ChildExit.new(
    pid: -1, exit_code: 0, project: "p1", slug: "s1", stage: "3-plan",
    command: "hive plan s1", state_file_path: nil,
    started_at: T0, finished_at: T0, json_envelope: nil
  )
  dispatcher.supervisor.define_singleton_method(:reap_dry_run) { |now:| [ child ] }
  ctrl.record_dispatch(pid: -1, project: "p1", slug: "s1", stage: "3-plan",
                       command: "hive plan s1", started_at: T0, state_file_mtime: T0 - 60)

  dispatcher.tick(now: T0)

  assert_equal 0, ctrl.in_flight_count
  event = logger.events.find { |(name, attrs)| name == :child_exited && attrs[:dry_run] == true }
  refute_nil event
end

def test_dry_run_reap_completes_answer_digest_so_scheduler_unwedges
  dispatcher, _sup, _ctrl, _logger, _mw, _patrol, answer_digest = make_dispatcher(
    rows: [], dry_run: true, with_answer_digest_scheduler: true
  )
  child = ChildExit.new(
    pid: -1, exit_code: 0, project: "answer_digest", slug: "2026-06-13", stage: "answer_digest",
    command: "hive answer-digest --date 2026-06-13 --json", state_file_path: nil,
    started_at: T0, finished_at: T0, json_envelope: nil
  )
  dispatcher.supervisor.define_singleton_method(:reap_dry_run) { |now:| [ child ] }

  dispatcher.tick(now: T0)

  assert_equal [ { date: "2026-06-13", exit_code: 0, now: T0 } ], answer_digest.completed
end

def test_dry_run_answer_digest_complete_raise_is_isolated_as_a_fatal_event
  dispatcher, _sup, ctrl, logger, _mw, _patrol, answer_digest = make_dispatcher(
    rows: [], dry_run: true, with_answer_digest_scheduler: true
  )
  child = ChildExit.new(
    pid: -1, exit_code: 1, project: "answer_digest", slug: "2026-06-13", stage: "answer_digest",
    command: "hive answer-digest --date 2026-06-13 --json", state_file_path: nil,
    started_at: T0, finished_at: T0, json_envelope: nil
  )
  dispatcher.supervisor.define_singleton_method(:reap_dry_run) { |now:| [ child ] }
  ctrl.record_dispatch(pid: -1, project: "answer_digest", slug: "2026-06-13", stage: "answer_digest",
                       command: "hive answer-digest --date 2026-06-13 --json",
                       started_at: T0, state_file_mtime: T0 - 60, kind: :digest)
  answer_digest.define_singleton_method(:complete) { |**| raise "disk full" }

  dispatcher.tick(now: T0)

  assert_equal 0, ctrl.in_flight_count
  fatal = logger.events.find do |(name, attrs)|
    name == :fatal &&
      attrs[:message].include?("answer_digest_scheduler.complete raised: RuntimeError: disk full")
  end
  refute_nil fatal
  refute_nil logger.events.find { |(name, attrs)| name == :child_exited && attrs[:dry_run] == true }
end

def test_merge_reconciliation_exceptions_are_logged_as_fatal
  rows = [ row(stage: "8-finalize", action: "ready_to_archive") ]
  dispatcher, _sup, _ctrl, logger, mw = make_dispatcher(
    rows: rows, with_merge_watcher: true
  )
  mw.tick_error = RuntimeError.new("registry unavailable")

  dispatcher.tick(now: T0)

  fatal = logger.events.find do |name, attrs|
    name == :fatal && attrs[:message].include?("task merge reconciliation failed")
  end
  refute_nil fatal
  assert_includes fatal[1][:message], "registry unavailable"
end

def test_project_enabled_reads_project_config_and_caches_result
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
  dispatcher.singleton_class.send(:remove_method, :project_enabled?)
  load_calls = []

  with_replaced_singleton_method(Hive::Config, :find_project, ->(_project) { { "path" => "/tmp/project" } }) do
    with_replaced_singleton_method(Hive::Config, :load, lambda { |path|
      load_calls << path
      { "daemon" => { "enabled" => true } }
    }) do
      assert_equal true, dispatcher.send(:project_enabled?, "p1")
      assert_equal true, dispatcher.send(:project_enabled?, "p1")
    end
  end

  assert_equal [ "/tmp/project" ], load_calls
end

def test_project_enabled_returns_false_for_missing_or_invalid_project_config
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
  dispatcher.singleton_class.send(:remove_method, :project_enabled?)

  with_replaced_singleton_method(Hive::Config, :find_project, ->(_project) { nil }) do
    assert_equal false, dispatcher.send(:project_enabled?, "missing")
  end

  dispatcher.instance_variable_get(:@enabled_cache).clear
  with_replaced_singleton_method(Hive::Config, :find_project, ->(_project) { { "path" => "/tmp/project" } }) do
    with_replaced_singleton_method(Hive::Config, :load, ->(_path) { raise Hive::ConfigError, "bad config" }) do
      assert_equal false, dispatcher.send(:project_enabled?, "bad")
    end
  end
end

def test_project_enabled_contains_malformed_on_disk_project_config
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
  dispatcher.singleton_class.send(:remove_method, :project_enabled?)

  with_tmp_dir do |project_root|
    config_path = File.join(project_root, ".hive-state", "config.yml")
    FileUtils.mkdir_p(File.dirname(config_path))
    File.write(config_path, "daemon: [\n")

    with_replaced_singleton_method(
      Hive::Config,
      :find_project,
      ->(_project) { { "path" => project_root } }
    ) do
      assert_equal false, dispatcher.send(:project_enabled?, "malformed")
    end
  end
end

def test_project_enabled_contains_unreadable_on_disk_project_config
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
  dispatcher.singleton_class.send(:remove_method, :project_enabled?)

  with_tmp_dir do |project_root|
    config_path = File.join(project_root, ".hive-state", "config.yml")
    FileUtils.mkdir_p(config_path)

    with_replaced_singleton_method(
      Hive::Config,
      :find_project,
      ->(_project) { { "path" => project_root } }
    ) do
      assert_equal false, dispatcher.send(:project_enabled?, "unreadable")
    end
  end
end

def test_reload_config_error_logs_and_keeps_previous_config
  dispatcher, _sup, controller, logger, _mw = make_dispatcher
  original_cfg = dispatcher.instance_variable_get(:@daemon_cfg)
  original_limits = [
    controller.max_concurrent_runs,
    controller.max_concurrent_per_project,
    controller.max_runs_per_day_per_project,
    controller.max_concurrent_patrol_scans
  ]
  controller.record_dispatch(
    pid: 123,
    project: "hive-bench",
    slug: "existing-run",
    stage: "2-generate",
    command: "hive run existing-run",
    started_at: T0,
    state_file_mtime: T0 - 1
  )

  with_replaced_singleton_method(Hive::Config, :load_global_daemon, lambda {
    raise Hive::ConfigError, "daemon.max_concurrent_runs must be an integer; got nil"
  }) do
    dispatcher.send(:reload_config!)
  end

  assert_same original_cfg, dispatcher.instance_variable_get(:@daemon_cfg)
  assert_same controller, dispatcher.controller,
              "an invalid reload must retain the live controller object"
  assert_equal original_limits, [
    controller.max_concurrent_runs,
    controller.max_concurrent_per_project,
    controller.max_runs_per_day_per_project,
    controller.max_concurrent_patrol_scans
  ]
  assert controller.running_task?(project: "hive-bench", slug: "existing-run"),
         "an invalid reload must retain in-flight accounting"
  fatal = logger.events.find { |(name, attrs)| name == :fatal && attrs[:message].include?("config reload failed") }
  refute_nil fatal
  assert_equal true, fatal[1][:keeping_previous]
  assert_includes fatal[1][:message], "max_concurrent_runs"
  refute logger.events.any? { |name, _attrs| name == :config_reloaded },
         "an invalid reload must not emit a success event"
end

def test_late_reload_loader_failure_never_splits_auto_retry_policy
  [ false, true ].each do |previously_enabled|
    dispatcher, _sup, controller, logger, _mw = make_dispatcher
    previous_daemon = {
      "edit_debounce_sec" => 30,
      "auto_retry" => { "enabled" => previously_enabled }
    }
    previous_config = dispatcher.instance_variable_get(:@config)
    previous_config["daemon"] = previous_daemon
    dispatcher.instance_variable_set(:@daemon_cfg, previous_daemon)
    previous_healer = Hive::Daemon::StaleAgentHealer.new(
      controller: controller,
      logger: logger,
      auto_retry_enabled: previously_enabled
    )
    dispatcher.instance_variable_set(:@stale_agent_healer, previous_healer)
    requested_daemon = {
      "edit_debounce_sec" => 45,
      "auto_retry" => { "enabled" => !previously_enabled }
    }

    with_replaced_singleton_method(
      Hive::Config, :load_global_daemon, -> { requested_daemon }
    ) do
      with_replaced_singleton_method(
        Hive::Config, :load_global_update, -> { { "check" => false } }
      ) do
        with_replaced_singleton_method(
          Hive::Config, :load_global_answer_digest_block,
          -> { raise Hive::ConfigError, "answer digest is invalid" }
        ) do
          dispatcher.send(:reload_config!)
        end
      end
    end

    assert_same previous_daemon, dispatcher.instance_variable_get(:@daemon_cfg)
    assert_same previous_config, dispatcher.instance_variable_get(:@config)
    assert_same previous_healer, dispatcher.instance_variable_get(:@stale_agent_healer)
    assert_equal previously_enabled,
                 previous_healer.auto_retry_enabled?,
                 "failed #{previously_enabled ? 'disable' : 'enable'} reload must retain one coherent policy"
    refute logger.events.any? { |name, _attrs| name == :config_reloaded }
    assert logger.events.any? { |name, attrs|
      name == :fatal && attrs[:message].include?("answer digest is invalid")
    }
  end
end

def test_interruptible_sleep_stops_after_shutdown_request
  dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher
  sleeps = []
  dispatcher.define_singleton_method(:sleep) do |seconds|
    sleeps << seconds
    request_shutdown!
  end

  dispatcher.send(:interruptible_sleep, 30)

  assert_equal [ 0.5 ], sleeps
end

  # ── dispatch-baseline persistence across restart ───────────────────────
  # Tests below MUST stay above the `private` declaration further down —
  # Minitest only discovers public test methods. A prior arrangement hid them
  # under `private` and silently ran zero of them (line coverage stayed green
  # via other tests indirectly exercising `prune_dispatch_baselines`, masking
  # the regression these tests pin).

  # The core fix: a needs_input row answered BEFORE a daemon restart must
  # dispatch, not be re-stranded. The pre-restart "ask" baseline is persisted;
  # the live state-file mtime (the user's answer) is newer, so the freshly
  # restarted dispatcher dispatches. Without persistence the reloaded baseline
  # would be nil → first-sight → :record_baseline → skip (the bug).
  def test_pre_restart_answer_dispatches_after_restart_via_persisted_baseline
    Dir.mktmpdir do |dir|
      path = File.join(dir, "baselines.json")
      seed_baseline(path, project: "writero", slug: "add-x", mtime: T0 - 600) # the ask

      answered = row(project: "writero", slug: "add-x", stage: "2-brainstorm",
                     action: "needs_input",
                     command: "hive brainstorm add-x --from 2-brainstorm",
                     mtime: T0 - 40) # user's answer: newer than ask, past 30s debounce
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [ answered ],
        dispatch_state: Hive::Daemon::DispatchBaselines.new(path: path)
      )

      dispatcher.tick(now: T0)

      assert_equal 1, sup.spawned.size, "a pre-restart answer must dispatch, not be re-stranded"
      assert events_include?(logger, :dispatched)
    end
  end

  def test_tick_prunes_baselines_for_tasks_absent_from_status
    Dir.mktmpdir do |dir|
      path = File.join(dir, "baselines.json")
      seed_baseline(path, project: "p", slug: "gone", mtime: T0 - 600)
      seed_baseline(path, project: "p", slug: "present", mtime: T0 - 600)

      present = row(project: "p", slug: "present", stage: "2-brainstorm",
                    action: "needs_input",
                    command: "hive brainstorm present --from 2-brainstorm",
                    mtime: T0 - 600) # equal to baseline → :skip, no re-dispatch
      _dispatcher, _sup, ctrl, _logger, _mw = make_dispatcher(
        rows: [ present ],
        dispatch_state: Hive::Daemon::DispatchBaselines.new(path: path)
      )
      _dispatcher.tick(now: T0)

      assert_nil ctrl.last_dispatched_state_file_mtime_for(project: "p", slug: "gone"),
                 "a task absent from the status scan must be pruned from baselines"
      refute_nil ctrl.last_dispatched_state_file_mtime_for(project: "p", slug: "present"),
                 "a task still present must keep its baseline"
    end
  end

  def test_failed_status_fetch_does_not_prune_baselines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "baselines.json")
      seed_baseline(path, project: "p", slug: "keep", mtime: T0 - 600)

      _dispatcher, _sup, ctrl, _logger, _mw = make_dispatcher(
        dispatch_state: Hive::Daemon::DispatchBaselines.new(path: path),
        status_result: Hive::Daemon::StatusConsumer::Result.new(ok: false, rows: [], error: "boom")
      )
      _dispatcher.tick(now: T0)

      refute_nil ctrl.last_dispatched_state_file_mtime_for(project: "p", slug: "keep"),
                 "a transient status failure must NOT wipe persisted baselines"
    end
  end

  # Per-project errors (`not_initialised`, `missing_project_path`) cause
  # `StatusConsumer` to drop a project from BOTH rows AND projects, even
  # though the overall fetch is `ok: true`. Without a scope guard the prune
  # would silently wipe every baseline for that project on the spot — the
  # exact stranding regression. The dispatcher passes `result.projects` as
  # the scope so an errored project keeps its baselines until it reappears.
  def test_per_project_error_does_not_wipe_that_projects_baselines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "baselines.json")
      seed_baseline(path, project: "writero", slug: "answered", mtime: T0 - 600)
      seed_baseline(path, project: "errored", slug: "answered-too", mtime: T0 - 600)

      writero_row = row(project: "writero", slug: "answered", stage: "2-brainstorm",
                        action: "needs_input",
                        command: "hive brainstorm answered --from 2-brainstorm",
                        mtime: T0 - 600)
      # `errored` project is filtered out of rows AND projects by the consumer
      # — mirror that here.
      result = Hive::Daemon::StatusConsumer::Result.new(
        ok: true, rows: [ writero_row ],
        projects: [ Hive::Daemon::StatusConsumer::ProjectInfo.new(name: "writero", legacy_stage_dirs: []) ],
        error: nil
      )
      _dispatcher, _sup, ctrl, _logger, _mw = make_dispatcher(
        dispatch_state: Hive::Daemon::DispatchBaselines.new(path: path),
        status_result: result
      )
      _dispatcher.tick(now: T0)

      assert_equal T0 - 600,
                   ctrl.last_dispatched_state_file_mtime_for(project: "errored", slug: "answered-too"),
                   "a project absent from result.projects (per-project error) must NOT have its baselines pruned"
      # Sanity: writero/answered's baseline is still there too (mtime == baseline → :skip).
      assert_equal T0 - 600,
                   ctrl.last_dispatched_state_file_mtime_for(project: "writero", slug: "answered")
    end
  end

  # ── dispatch-request queue integration ───────────────────────────────

  Q = Hive::Daemon::DispatchRequestQueue

  def test_attempt_reconciliation_precedes_status_healers_and_admission
    order = []
    capacity = Struct.new(:per_project, :global_count, :daily_counts) do
      def task_reserved?(project:, task_slug:) = false
    end.new({}, 0, {})
    snapshot = Hive::Attempts::ReconciliationSnapshot.new(
      capacity: capacity, attempts: [], lost_attempts: [],
      newly_lost_attempts: [], terminal_attempts: [], invalid_records: []
    )
    reconciler = Object.new
    reconciler.define_singleton_method(:reconcile) { |now:| order << :reconcile; snapshot }
    dispatcher, = make_dispatcher(rows: [], attempt_reconciler: reconciler)
    dispatcher.instance_variable_get(:@status_consumer).define_singleton_method(:fetch) do
      order << :status
      Hive::Daemon::StatusConsumer::Result.new(ok: true, rows: [], projects: [], error: nil)
    end
    dispatcher.instance_variable_get(:@stale_agent_healer)
              .define_singleton_method(:heal) { |*_args, **_kwargs| order << :stale_healer }
    dispatcher.instance_variable_get(:@stale_agent_healer)
              .define_singleton_method(:heal_attempt_losses) { |*_args, **_kwargs| order << :attempt_loss_healer }
    dispatcher.tick(now: T0)

    assert_equal :reconcile, order.first
    assert_operator order.index(:reconcile), :<, order.index(:attempt_loss_healer)
    assert_operator order.index(:attempt_loss_healer), :<, order.index(:status)
    assert_operator order.index(:reconcile), :<, order.index(:status)
    assert_operator order.index(:reconcile), :<, order.index(:stale_healer)
  end

  def test_lease_backed_status_row_is_not_double_counted_as_legacy_capacity
    capacity = Hive::Attempts::CapacitySnapshot.new(
      global_count: 1,
      per_project: { "p1" => 1 },
      per_task: { [ "p1", "demo-task" ] => 1 },
      daily_counts: {},
      reserved_attempt_ids: [ "attempt-1" ],
      invalid_count: 0
    )
    snapshot = Hive::Attempts::ReconciliationSnapshot.new(
      capacity: capacity, attempts: [], lost_attempts: [],
      newly_lost_attempts: [], terminal_attempts: [], invalid_records: []
    )
    reconciler = Object.new
    reconciler.define_singleton_method(:reconcile) { |now:| snapshot }
    task_row = row(
      project: "p1", slug: "demo-task", stage: "4-execute",
      marker: "agent_working", action: Hive::Schemas::TaskActionKind::AGENT_RUNNING,
      live_task_lock: true, attempt_id: "attempt-1", task_generation: "generation-1"
    )
    dispatcher, _supervisor, controller, = make_dispatcher(
      rows: [ task_row ], attempt_reconciler: reconciler
    )

    dispatcher.tick(now: T0)

    assert_equal 1, controller.in_flight_count
  end

  def test_terminal_attempt_receipt_completes_claimed_delivery_without_wait2
    Dir.mktmpdir("hive-attempt-delivery") do |state_home|
      store = Hive::Attempts::Store.new(root: File.join(state_home, "attempts"))
      launching = store.create_launching(
        attempt_id: "attempt-1", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "p1", task_slug: "demo-task",
        intended_stage: "4-execute", task_generation: "generation-1",
        progress_token: "progress", provider: "codex",
        worker_argv: [ "hive", "run", "demo-task" ],
        claim_capability_digest: Hive::Attempts::Capability.digest("c" * 64), starting_revision: nil,
        retry_charge: 0, inherited_outputs: [], launch_timeout_sec: 30, now: T0
      )
      owner = {
        "pid" => 123, "start_fingerprint" => "start",
        "session_id" => 123, "process_group_id" => 123
      }
      claimed = store.claim(
        launching, owner: owner, claim_capability: "c" * 64,
        first_heartbeat_timeout_sec: 30, now: T0
      )
      running = store.first_heartbeat(claimed, stale_sec: 30, now: T0 + 1)
      store.terminalize(
        running, outcome: "succeeded", exit_status: 0,
        final_checkpoint: running.checkpoint, output_references: [],
        log_reference: { "path" => "logs/a.frames", "size" => 0, "sha256" => "0" * 64 },
        now: T0 + 2
      )
      request_id = Q.write_request!(
        project: "p1", slug: "demo-task", argv: %w[hive run demo-task],
        chat_id: 42, request_id: "request-1", state_home: state_home, now: T0
      )
      Q.claim(
        request_id, pid: nil, attempt_id: "attempt-1",
        task_generation: "generation-1", state_home: state_home, now: T0
      )
      identity = Struct.new(:unused) { def status(_owner) = :missing }.new
      reconciler = Hive::Attempts::Reconciler.new(store: store, process_identity: identity)
      dispatcher, supervisor, = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        dispatch_result_state_home: state_home,
        attempt_reconciler: reconciler
      )

      dispatcher.tick(now: T0 + 3)

      assert_empty supervisor.spawned
      assert_empty Q.claimed(state_home: state_home)
      notice = Hive::Daemon::DispatchResultQueue.pending(state_home: state_home).first
      assert_equal "attempt-1", notice.attempt_id
      assert_equal "terminal", notice.attempt_state
      assert_equal "succeeded", notice.receipt["outcome"]
    end
  end

  def test_lost_delivery_claim_follows_its_budgeted_successor
    Dir.mktmpdir("hive-attempt-successor-delivery") do |state_home|
      request_id = Q.write_request!(
        project: "p1", slug: "demo-task", argv: %w[hive run demo-task],
        chat_id: 42, request_id: "request-1", state_home: state_home, now: T0
      )
      Q.claim(
        request_id, pid: nil, attempt_id: "lost-1",
        task_generation: "generation-1", state_home: state_home, now: T0
      )
      outcomes = Object.new
      outcomes.define_singleton_method(:fetch) do |attempt_id|
        next unless attempt_id == "lost-1"

        {
          "attempt_id" => "lost-1", "task_generation" => "generation-1",
          "status" => "successor_dispatched", "successor_attempt_id" => "successor-1"
        }
      end
      dispatcher, = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        dispatch_result_state_home: state_home
      )
      dispatcher.instance_variable_set(:@lost_outcome_store, outcomes)

      dispatcher.send(:reconcile_lost_attempt_deliveries, now: T0 + 1)

      claim = Q.claimed(state_home: state_home).first.claim
      assert_equal "successor-1", claim.fetch("attempt_id")
      assert_equal "generation-1", claim.fetch("task_generation")
      assert_empty Hive::Daemon::DispatchResultQueue.pending(state_home: state_home)
    end
  end

  def test_queue_delivery_delegates_task_ownership_to_attempt_dispatcher
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      attempt = Struct.new(:attempt_id, :task_generation, :state)
                      .new("attempt-1", "generation-1", "launching")
      result = Hive::Attempts::DispatchResult.new(
        status: :accepted, attempt: attempt, receipt: nil,
        attach_descriptor: nil, reason: nil
      )
      calls = []
      attempt_dispatcher = Object.new
      attempt_dispatcher.define_singleton_method(:dispatch_request) do |request, **options|
        calls << [ request, options ]
        result
      end
      dispatcher, supervisor, = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        attempt_dispatcher: attempt_dispatcher
      )
      Q.write_request!(
        project: "p1", slug: "demo-task", argv: %w[hive run demo-task],
        request_id: "request-1", state_home: state_home, now: T0
      )
      request = Q.pending(state_home: state_home).first

      dispatcher.send(:dispatch_request!, request, now: T0)

      assert_equal 1, calls.length
      assert_empty supervisor.spawned
      claim_path = Dir.glob(File.join(state_home, "dispatch_requests", "*.claim")).first
      claim = JSON.parse(File.read(claim_path))
      assert_equal "attempt-1", claim["attempt_id"]
      assert_equal "generation-1", claim["task_generation"]
    end
  end

  def test_recovery_attempt_dispatch_marks_each_admission_result_and_logs_its_event
    expectations = {
      existing_live: :dispatch_request_attached,
      terminal_replay: :dispatch_request_terminal_replay,
      blocked: :dispatch_request_blocked
    }

    expectations.each do |status, expected_event|
      Dir.mktmpdir("hive-recovery-attempt-dispatch") do |state_home|
        attempt = Struct.new(:attempt_id, :task_generation, :state).new(
          "attempt-#{status}", "generation-#{status}", "launching"
        )
        result = Hive::Attempts::DispatchResult.new(
          status: status,
          attempt: attempt,
          receipt: status == :terminal_replay ?
            { "outcome" => "succeeded" } : nil,
          attach_descriptor: nil,
          reason: status == :blocked ? "admission blocked" : nil
        )
        attempt_dispatcher = Object.new
        attempt_dispatcher.define_singleton_method(:dispatch_request) do |*_args, **_kwargs|
          result
        end
        coordinator = FakeRecoveryCoordinator.new(status: "queued")
        dispatcher, _supervisor, _controller, logger = make_dispatcher(
          rows: [],
          dispatch_request_state_home: state_home,
          attempt_dispatcher: attempt_dispatcher,
          recovery_coordinator: coordinator
        )
        Q.write_request!(
          project: "p1",
          slug: "recovery-task",
          argv: %w[hive run recovery-task --stage 4-execute --project p1 --json],
          requestor: "healer",
          trigger: "recovery",
          request_id: "recovery-#{status}",
          task_generation: "c" * 64,
          task_id: 817,
          expected_stage: "4-execute",
          expected_marker_name: "error",
          expected_marker_id: "marker-1",
          recovery: dispatcher_recovery(phase: "cleared"),
          state_home: state_home,
          now: T0
        )
        request = Q.pending(state_home: state_home).fetch(0)

        assert_same result, dispatcher.send(:dispatch_request!, request, now: T0)

        marked = coordinator.marked.fetch(0)
        assert_equal "attempt-#{status}", marked.fetch(:attempt_id)
        assert_equal(status == :terminal_replay, marked.fetch(:terminal))
        assert logger.events.any? { |name, attributes|
          name == expected_event &&
            attributes[:request_id] == "recovery-#{status}"
        }
      end
    end
  end

  def test_attempt_reconciliation_failure_stops_tick_before_status
    reconciler = Object.new
    reconciler.define_singleton_method(:reconcile) { |now:| raise "lease store unavailable" }
    dispatcher, _supervisor, _controller, logger = make_dispatcher(
      rows: [], attempt_reconciler: reconciler
    )
    status_called = false
    dispatcher.instance_variable_get(:@status_consumer).define_singleton_method(:fetch) do
      status_called = true
      raise "status must not run"
    end

    dispatcher.tick(now: T0)

    refute status_called
    assert logger.events.any? { |name, attrs|
      name == :tick_end && attrs[:action] == "attempt_reconciliation_failed"
    }
    assert logger.events.any? { |name, attrs|
      name == :fatal && attrs[:message].include?("lease store unavailable")
    }
  end

  def test_deferred_attempt_delivery_releases_claim_for_later_retry
    Dir.mktmpdir("hive-dispatch-deferred") do |state_home|
      result = Hive::Attempts::DispatchResult.new(
        status: :deferred, attempt: nil, receipt: nil,
        attach_descriptor: nil, reason: "capacity"
      )
      attempt_dispatcher = Object.new
      attempt_dispatcher.define_singleton_method(:dispatch_request) { |*_args, **_kwargs| result }
      dispatcher, _supervisor, _controller, logger = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        attempt_dispatcher: attempt_dispatcher
      )
      Q.write_request!(
        project: "p1", slug: "demo-task", argv: %w[hive run demo-task],
        request_id: "request-deferred", state_home: state_home, now: T0
      )
      request = Q.pending(state_home: state_home).first

      assert_same result, dispatcher.send(:dispatch_request!, request, now: T0)
      assert_equal [ "request-deferred" ], Q.pending(state_home: state_home).map(&:request_id)
      assert_empty Q.claimed(state_home: state_home)
      assert logger.events.any? { |name, attrs|
        name == :dispatch_request_blocked && attrs[:reason] == "capacity"
      }
    end
  end

  def test_deferred_recovery_delivery_advances_hourly_pacing_before_releasing_claim
    Dir.mktmpdir("hive-recovery-deferred") do |state_home|
      result = Hive::Attempts::DispatchResult.new(
        status: :deferred, attempt: nil, receipt: nil,
        attach_descriptor: nil, reason: "launch_handoff_failed"
      )
      attempt_dispatcher = Object.new
      attempt_dispatcher.define_singleton_method(:dispatch_request) { |*_args, **_kwargs| result }
      coordinator = FakeRecoveryCoordinator.new(status: "queued")
      dispatcher, = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        attempt_dispatcher: attempt_dispatcher,
        recovery_coordinator: coordinator
      )
      recovery = {
        "phase" => "cleared",
        "observed_marker_generation" => "a" * 64,
        "expected_marker_attrs" => {
          "reason" => "timeout", "marker_id" => "marker-1"
        },
        "canonical_task_folder" => "/tmp/recovery-task",
        "expected_post_clear_progress_fingerprint" => "b" * 64,
        "dispatch_generation" => "c" * 64,
        "failure_origin" => "timeout",
        "next_eligible_at" => T0.iso8601(6),
        "owner" => "scheduler",
        "blocked_reason" => nil,
        "blocked_remediation" => nil,
        "retry_count" => 1
      }
      Q.write_request!(
        project: "p1", slug: "recovery-task",
        argv: %w[hive run recovery-task --stage 4-execute --project p1 --json],
        requestor: "healer", trigger: "recovery",
        request_id: "recovery-deferred",
        task_generation: "c" * 64, task_id: 817,
        expected_stage: "4-execute", expected_marker_name: "error",
        expected_marker_id: "marker-1", recovery: recovery,
        state_home: state_home, now: T0
      )
      request = Q.pending(state_home: state_home).fetch(0)

      assert_same result, dispatcher.send(:dispatch_request!, request, now: T0)

      assert_equal [ T0 ], coordinator.deferred.map { |entry| entry.fetch(:now) }
      assert_equal [ "recovery-deferred" ],
                   Q.pending(state_home: state_home).map(&:request_id)
      assert_empty Q.claimed(state_home: state_home)
    end
  end

  def test_terminal_recovery_pruning_runs_at_most_hourly
    dispatcher, = make_dispatcher
    calls = []
    replacement = lambda do |state_home:, now:|
      calls << [ state_home, now ]
      0
    end

    with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue,
      :prune_terminal_recoveries,
      replacement
    ) do
      dispatcher.send(:prune_terminal_recovery_receipts, now: T0)
      dispatcher.send(:prune_terminal_recovery_receipts, now: T0 + 30)
      dispatcher.send(:prune_terminal_recovery_receipts, now: T0 + 3_600)
    end

    assert_equal [ T0, T0 + 3_600 ], calls.map(&:last)
  end

  def test_terminal_recovery_pruning_failure_is_logged_and_swallowed
    dispatcher, _supervisor, _controller, logger = make_dispatcher

    with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue,
      :prune_terminal_recoveries,
      ->(**_kwargs) { raise IOError, "retention store unavailable" }
    ) do
      dispatcher.send(:prune_terminal_recovery_receipts, now: T0)
    end

    assert logger.events.any? { |name, attributes|
      name == :fatal &&
        attributes[:message].include?("prune terminal recovery receipts") &&
        attributes[:message].include?("retention store unavailable")
    }
  end

  def test_attempt_claim_update_failure_is_raised_for_retry_and_repair
    attempt = Struct.new(:attempt_id, :task_generation).new("attempt-1", "generation-1")
    result = Struct.new(:attempt).new(attempt)
    request = Struct.new(:request_id).new("request-1")
    dispatcher, _supervisor, _controller, logger = make_dispatcher(rows: [])
    with_replaced_singleton_method(Q, :update_claim, ->(*_args, **_kwargs) { raise Errno::EACCES }) do
      assert_raises(Errno::EACCES) do
        dispatcher.send(:update_dispatch_request_attempt_claim, request, result: result, now: T0)
      end
    end
    refute logger.events.any? { |name, _attrs| name == :fatal }
  end

  def test_restart_claim_recovery_repairs_nil_preclaim_from_attempt_request_id
    Dir.mktmpdir("hive-dispatch-repair-claim") do |state_home|
      request_id = Q.write_request!(
        project: "p1", slug: "demo-task", argv: %w[hive run demo-task],
        request_id: "request-repair", state_home: state_home, now: T0
      )
      Q.claim(request_id, pid: nil, state_home: state_home, now: T0)
      attempt = Struct.new(:attempt_id, :task_generation)
                      .new("attempt-1", "generation-1")
      reconciler = Object.new
      reconciler.define_singleton_method(:find_by_request_id) { |_id| attempt }
      reconciler.define_singleton_method(:fetch) { |_id| attempt }
      dispatcher, = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        attempt_reconciler: reconciler
      )

      dispatcher.send(:recover_dispatch_claims, now: T0 + 10)

      delivery = Q.claimed(state_home: state_home).fetch(0)
      assert_equal "attempt-1", delivery.claim.fetch("attempt_id")
      assert_equal "generation-1", delivery.claim.fetch("task_generation")
    end
  end

  def test_restart_claim_recovery_adopts_matching_attempt_reference
    Dir.mktmpdir("hive-dispatch-adopt-claim") do |state_home|
      request_id = Q.write_request!(
        project: "p1", slug: "demo-task", argv: %w[hive run demo-task],
        request_id: "request-adopt", state_home: state_home, now: T0
      )
      Q.claim(
        request_id, pid: nil, attempt_id: "attempt-1",
        task_generation: "generation-1", state_home: state_home, now: T0
      )
      attempt = Struct.new(:task_generation).new("generation-1")
      reconciler = Object.new
      reconciler.define_singleton_method(:fetch) { |_id| attempt }
      dispatcher, = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        attempt_reconciler: reconciler
      )

      dispatcher.send(:recover_dispatch_claims, now: T0 + 10)
      assert_equal 1, Q.claimed(state_home: state_home).size
    end
  end

  def test_failed_terminal_receipt_discards_sequence_before_completion
    request = Q::Request.new(
      request_id: "request-failed", created_at: T0, project: "p1", slug: "demo-task",
      argv: %w[hive run demo-task], requestor: "daemon", chat_id: nil
    )
    delivery = Q::ClaimedDelivery.new(
      request: request, claim: { "attempt_id" => "attempt-failed" }, path: "/claim"
    )
    receipt = { "exit_status" => 7, "outcome" => "failed" }
    attempt = Struct.new(:attempt_id, :task_generation, :state, :receipt)
                    .new("attempt-failed", "generation-1", "terminal", receipt)
    reconciler = Object.new
    reconciler.define_singleton_method(:fetch) { |_id| attempt }
    dispatcher, = make_dispatcher(rows: [], attempt_reconciler: reconciler)
    discarded = []
    removed = []
    with_replaced_singleton_method(Q, :claimed, ->(**_kwargs) { [ delivery ] }) do
      with_replaced_singleton_method(Q, :discard_sequence, lambda { |request_id, **_kwargs|
        discarded << request_id
      }) do
        with_replaced_singleton_method(Q, :remove, lambda { |request_id, **_kwargs|
          removed << request_id
        }) do
          dispatcher.send(:reconcile_attempt_deliveries, now: T0)
        end
      end
    end
    assert_equal [ "request-failed" ], discarded
    assert_equal [ "request-failed" ], removed
  end

  def test_terminal_attempt_reconciliation_closes_the_durable_recovery_receipt
    request = Q::Request.new(
      request_id: "recovery-terminal",
      created_at: T0,
      project: "p1",
      slug: "recovery-task",
      argv: %w[hive run recovery-task],
      requestor: "daemon",
      chat_id: nil,
      recovery: dispatcher_recovery(phase: "dispatched")
    )
    delivery = Q::ClaimedDelivery.new(
      request: request,
      claim: { "attempt_id" => "attempt-terminal" },
      path: "/claim"
    )
    receipt = { "exit_status" => 7, "outcome" => "failed" }
    attempt = Struct.new(:attempt_id, :task_generation, :state, :receipt).new(
      "attempt-terminal", "generation-1", "terminal", receipt
    )
    reconciler = Object.new
    reconciler.define_singleton_method(:fetch) { |_id| attempt }
    coordinator = FakeRecoveryCoordinator.new(status: "queued")
    dispatcher, = make_dispatcher(
      rows: [],
      attempt_reconciler: reconciler,
      recovery_coordinator: coordinator
    )

    with_replaced_singleton_method(Q, :claimed, ->(**_kwargs) { [ delivery ] }) do
      with_replaced_singleton_method(Q, :discard_sequence, ->(*_args, **_kwargs) { }) do
        dispatcher.send(:reconcile_attempt_deliveries, now: T0)
      end
    end

    marked = coordinator.marked.fetch(0)
    assert_equal "attempt-terminal", marked.fetch(:attempt_id)
    assert_equal true, marked.fetch(:terminal)
    assert_equal "failed", marked.fetch(:outcome)
  end

  def test_legacy_manual_lost_delivery_remains_claimed_for_successor_recovery
    Dir.mktmpdir("hive-attempt-manual-delivery") do |state_home|
      request_id = Q.write_request!(
        project: "p1", slug: "demo-task", argv: %w[hive run demo-task],
        chat_id: 42, update_id: 9, request_id: "request-manual",
        state_home: state_home, now: T0
      )
      Q.claim(
        request_id, pid: nil, attempt_id: "lost-1",
        task_generation: "generation-1", state_home: state_home, now: T0
      )
      outcomes = Object.new
      outcomes.define_singleton_method(:fetch) do |_attempt_id|
        {
          "attempt_id" => "lost-1", "task_generation" => "generation-1",
          "status" => "manual"
        }
      end
      dispatcher, _supervisor, _controller, logger = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        dispatch_result_state_home: state_home
      )
      dispatcher.instance_variable_set(:@lost_outcome_store, outcomes)

      dispatcher.send(:reconcile_lost_attempt_deliveries, now: T0 + 1)

      assert_equal 1, Q.claimed(state_home: state_home).size
      assert_empty Hive::Daemon::DispatchResultQueue.pending(state_home: state_home)
      refute logger.events.any? { |name, _attrs| name == :dispatch_request_completed }
    end
  end

  def test_durable_auto_dispatch_logs_all_admission_outcomes_and_charges_only_new_starts
    attempt = Struct.new(:attempt_id, :task_generation, :state)
                    .new("attempt-1", "generation-1", "launching")
    statuses = [ :accepted, :existing_live, :terminal_replay, :deferred ]
    calls = []
    attempt_dispatcher = Object.new
    attempt_dispatcher.define_singleton_method(:dispatch_request) do |request, **options|
      status = statuses.shift
      calls << [ request, options ]
      Hive::Attempts::DispatchResult.new(
        status: status, attempt: (status == :deferred ? nil : attempt), receipt: nil,
        attach_descriptor: nil, reason: (status == :deferred ? "capacity" : nil)
      )
    end
    dispatcher, supervisor, _controller, logger = make_dispatcher(
      rows: [], attempt_dispatcher: attempt_dispatcher
    )
    results = 4.times.map do |index|
      dispatcher.send(
        :dispatch_command, "hive run demo-task", project: "p1", slug: "demo-task",
        stage: "4-execute", state_file_mtime: nil, state_file_path: nil,
        now: T0 + index, request_id: "request-#{index}"
      )
    end

    assert_equal %i[accepted existing_live terminal_replay deferred], results.map(&:status)
    assert_equal 4, calls.size
    assert_empty supervisor.spawned
    assert_equal 1, dispatcher.instance_variable_get(:@dispatched_today)
    assert_equal %i[attempt_accepted attempt_duplicate attempt_terminal_replay attempt_capacity_deferred],
                 logger.events.map(&:first).grep(/attempt_/)
    dispatched = logger.events.select { |name, _attrs| name == :dispatched }
    assert_equal 1, dispatched.size

    unknown = Hive::Attempts::DispatchResult.new(
      status: :unknown, attempt: nil, receipt: nil, attach_descriptor: nil, reason: nil
    )
    assert_nil dispatcher.send(:log_attempt_admission, unknown)
  end

  def write_request_file(dir, slug:, request_id:, created_at: T0, argv: nil, project: "p1",
                         requestor: "bot", trigger: "answer_complete")
    argv ||= [ "hive", "run", slug, "--json" ]
    path = File.join(Q.directory(state_home: dir), Q.filename_for(created_at: created_at, request_id: request_id))
    payload = {
      "schema" => "hive-dispatch-request",
      "schema_version" => Q::SCHEMA_VERSION,
      "request_id" => request_id,
      "created_at" => created_at.utc.iso8601(6),
      "project" => project,
      "slug" => slug,
      "argv" => argv,
      "requestor" => requestor,
      "chat_id" => 42,
      "update_id" => 99,
      "trigger" => trigger,
      "task_generation" => nil,
      "predecessor_attempt_id" => nil,
      "inherited_outputs" => [],
      "recovery" => nil
    }
    File.write(path, JSON.generate(payload))
    path
  end

  def stub_find_project!(dispatcher, project_name)
    Hive::Config.singleton_class.alias_method(:__orig_find_project, :find_project) unless Hive::Config.singleton_class.method_defined?(:__orig_find_project)
    Hive::Config.define_singleton_method(:find_project) do |name|
      name == project_name ? { "name" => project_name, "path" => "/tmp/nonexistent", "hive_state_path" => "/tmp/nonexistent/.hive-state" } : nil
    end
    dispatcher
  end

  def restore_find_project!
    if Hive::Config.singleton_class.method_defined?(:__orig_find_project)
      Hive::Config.define_singleton_method(:find_project, Hive::Config.method(:__orig_find_project))
    end
  end

  def test_dispatch_request_observed_logged_and_dispatched
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "R1")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        observed = logger.events.find { |(n, _)| n == :dispatch_request_observed }
        dispatched = logger.events.find { |(n, _)| n == :dispatch_request_dispatched }
        refute_nil observed
        refute_nil dispatched
        assert_equal "R1", observed[1][:request_id]
        assert_equal 1, sup.spawned.size
        assert_equal "hive run s1 --json", sup.spawned.first[:command]
        assert_equal "R1", sup.spawned.first[:request_id]
        assert_equal Hive::Paths.state_home, sup.spawned.first[:log_state_path]
      ensure
        restore_find_project!
      end
    end
  end

  def test_dispatch_request_honors_dependency_wait_without_consuming_request
    held = row(
      project: "p1", slug: "held", stage: "4-execute", action: "ready_to_run",
      command: "hive run held --json", depends_on: "base", blocked_by: "base",
      dependency_stage: "7-artifacts", blocked: true
    )
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, supervisor, _controller, logger, _watcher = make_dispatcher(
        rows: [ held ], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "held", request_id: "DEPWAIT")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        blocked = logger.events.find do |name, attrs|
          name == :dispatch_request_blocked && attrs[:request_id] == "DEPWAIT"
        end
        assert_equal "dependency_unmet", blocked[1][:reason]
        assert_equal "base", blocked[1][:blocked_by]
        assert_empty supervisor.spawned
        assert_equal 1, Q.pending(state_home: state_home).size
      ensure
        restore_find_project!
      end
    end
  end

  def test_dispatch_request_honors_admission_error_but_allows_marker_repair
    error = Hive::DependencyAdmission::AdmissionError.new(
      reason_code: "dependency_cycle", offending_ref: "p1:held -> p1:held",
      safe_correction: "Break the cycle."
    )
    held = row(
      project: "p1", slug: "held", stage: "4-execute", action: "admission_error",
      command: nil, blocked: true, admission_error: error
    )
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, supervisor, _controller, logger, _watcher = make_dispatcher(
        rows: [ held ], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "held", request_id: "ADMISSION")
      write_request_file(
        state_home, slug: "held", request_id: "REPAIR",
        argv: [ "hive", "markers", "clear", "held", "--json" ]
      )
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        blocked = logger.events.find do |name, attrs|
          name == :dispatch_request_blocked && attrs[:request_id] == "ADMISSION"
        end
        assert_equal "admission_error", blocked[1][:reason]
        assert_equal "dependency_cycle", blocked[1][:reason_code]
        assert_equal [ "hive markers clear held --json" ], supervisor.spawned.map { |item| item[:command] }
        assert_equal [ "ADMISSION" ], Q.pending(state_home: state_home).map(&:request_id)
      ensure
        restore_find_project!
      end
    end
  end

  # C3: a dispatched request is claimed (renamed to .claimed) so a second
  # tick never re-observes or re-dispatches it (at-most-once).
  def test_dispatch_request_claimed_after_dispatch_and_not_redispatched
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, _logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      json_path = write_request_file(state_home, slug: "s1", request_id: "R1")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)
        assert_equal 1, sup.spawned.size
        refute File.exist?(json_path), "request file must be claimed (renamed) after dispatch"
        assert File.exist?("#{json_path}#{Q::CLAIMED_SUFFIX}"), "a .claimed file must exist"
        assert_empty Q.pending(state_home: state_home),
                     "claimed request must be invisible to pending"

        # A second tick must NOT spawn again.
        dispatcher.tick(now: T0 + 60)
        assert_equal 1, sup.spawned.size, "claimed request must not be re-dispatched"
      ensure
        restore_find_project!
      end
    end
  end

  # ADV-1: a request-driven completion writes a result notice carrying
  # the originating chat_id for the bot to relay.
  def test_reap_writes_dispatch_result_notice_on_request_failure
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        dispatch_result_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "RF1")
      exited = ChildExit.new(
        pid: 555, exit_code: 4, project: "p1", slug: "s1", stage: nil,
        command: "hive markers clear s1", state_file_path: nil,
        started_at: T0, finished_at: T0, json_envelope: nil, request_id: "RF1"
      )
      sup.define_singleton_method(:reap_all) { |now:| [ exited ] }

      dispatcher.send(:reap_completed, now: T0 + 1)

      notices = Hive::Daemon::DispatchResultQueue.pending(state_home: state_home)
      assert_equal 1, notices.size
      assert_equal 42, notices.first.chat_id, "chat_id is recovered from the request file"
      assert_equal 4, notices.first.exit_code
      assert(logger.events.any? { |(n, _)| n == :dispatch_result_written })
    end
  end

  def test_reap_writes_dispatch_result_notice_on_request_success
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, _logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        dispatch_result_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "OK1")
      exited = ChildExit.new(
        pid: 556, exit_code: 0, project: "p1", slug: "s1", stage: nil,
        command: "hive review s1", state_file_path: nil,
        started_at: T0, finished_at: T0, json_envelope: nil, request_id: "OK1"
      )
      sup.define_singleton_method(:reap_all) { |now:| [ exited ] }

      dispatcher.send(:reap_completed, now: T0 + 1)
      notices = Hive::Daemon::DispatchResultQueue.pending(state_home: state_home)
      assert_equal 1, notices.size
      assert_equal 42, notices.first.chat_id, "chat_id is recovered from the request file"
      assert_equal 0, notices.first.exit_code
    end
  end

  def test_reap_promotes_sequence_only_after_success
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, _logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        dispatch_result_state_home: state_home
      )
      write_request_file(
        state_home,
        slug: "s1",
        request_id: "SEQ1",
        argv: [ "hive", "markers", "clear", "s1", "--json" ]
      )
      Q.write_sequence!(
        "SEQ1",
        remaining_argvs: [ [ "hive", "review", "s1", "--from", "6-review", "--json" ] ],
        state_home: state_home
      )
      exited = ChildExit.new(
        pid: 558, exit_code: 0, project: "p1", slug: "s1", stage: nil,
        command: "hive markers clear s1 --json", state_file_path: nil,
        started_at: T0, finished_at: T0, json_envelope: nil, request_id: "SEQ1"
      )
      sup.define_singleton_method(:reap_all) { |now:| [ exited ] }

      dispatcher.send(:reap_completed, now: T0 + 1)

      pending = Q.pending(state_home: state_home)
      assert_equal 1, pending.size
      assert_equal [ "hive", "review", "s1", "--from", "6-review", "--json" ],
                   pending.first.argv
      refute_equal "SEQ1", pending.first.request_id
      assert_empty Hive::Daemon::DispatchResultQueue.pending(state_home: state_home),
                   "an intermediate sequence step must not notify until the promoted command finishes"
      assert_empty Dir.glob(File.join(Q.directory(state_home: state_home), "SEQ1*")),
                   "the consumed sequence sidecar must be removed"
    end
  end

  def test_reap_discards_sequence_after_failure
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, _logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        dispatch_result_state_home: state_home
      )
      write_request_file(
        state_home,
        slug: "s1",
        request_id: "SEQF",
        argv: [ "hive", "markers", "clear", "s1", "--json" ]
      )
      Q.write_sequence!(
        "SEQF",
        remaining_argvs: [ [ "hive", "review", "s1", "--from", "6-review", "--json" ] ],
        state_home: state_home
      )
      exited = ChildExit.new(
        pid: 559, exit_code: 1, project: "p1", slug: "s1", stage: nil,
        command: "hive markers clear s1 --json", state_file_path: nil,
        started_at: T0, finished_at: T0, json_envelope: nil, request_id: "SEQF"
      )
      sup.define_singleton_method(:reap_all) { |now:| [ exited ] }

      dispatcher.send(:reap_completed, now: T0 + 1)

      assert_empty Q.pending(state_home: state_home),
                   "a retry must not be enqueued when the marker clear command failed"
      assert_equal 1, Hive::Daemon::DispatchResultQueue.pending(state_home: state_home).size,
                   "a failed sequence step must still notify the originating chat"
      assert_empty Dir.glob(File.join(Q.directory(state_home: state_home), "SEQF*")),
                   "the failed sequence sidecar must be discarded"
    end
  end

  def test_dispatch_request_releases_claim_when_spawn_raises
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, _logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "RFAIL")
      sup.define_singleton_method(:spawn) { |**_kwargs| raise "spawn failed" }
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)
        assert_equal [ "RFAIL" ], Q.pending(state_home: state_home).map(&:request_id)
      ensure
        restore_find_project!
      end
    end
  end

  def test_update_dispatch_request_claim_logs_helper_errors
    dispatcher, _sup, _ctrl, logger, _mw = make_dispatcher
    entry = Hive::Daemon::DispatchRequestQueue::Request.new(
      path: "/tmp/request.json", request_id: "R1", created_at: T0,
      project: "hive", slug: "task", argv: [ "hive", "run", "task" ],
      requestor: "bot", chat_id: 42, update_id: 12, trigger: "test"
    )

    with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue, :update_claim, ->(*, **_kwargs) { raise "claim write failed" }
    ) do
      dispatcher.send(:update_dispatch_request_claim, entry, pid: 123, now: T0)
    end

    assert(logger.events.any? { |(name, attrs)|
      name == :fatal && attrs[:message].include?("update_dispatch_request_claim raised")
    })
  end

  def test_promote_dispatch_sequence_logs_helper_errors
    dispatcher, _sup, _ctrl, logger, _mw = make_dispatcher
    entry = ChildExit.new(
      pid: 555, exit_code: 0, project: "p1", slug: "s1", stage: nil,
      command: "hive markers clear s1", state_file_path: nil,
      started_at: T0, finished_at: T0, json_envelope: nil, request_id: "SEQERR"
    )

    result = with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue, :promote_sequence, ->(*, **_kwargs) { raise "promote failed" }
    ) do
      dispatcher.send(:promote_dispatch_sequence, entry, nil, now: T0)
    end

    assert(logger.events.any? { |(name, attrs)|
      name == :fatal && attrs[:message].include?("promote_dispatch_sequence raised")
    })
    assert_equal :promotion_failed, result,
                 "a raised promotion must return a truthy sentinel so the caller suppresses the false success notice"
  end

  def test_discard_sequence_after_failure_swallows_errors
    dispatcher, _sup, _ctrl, logger, _mw = make_dispatcher
    entry = ChildExit.new(
      pid: 561, exit_code: 0, project: "p1", slug: "s1", stage: nil,
      command: "hive markers clear s1", state_file_path: nil,
      started_at: T0, finished_at: T0, json_envelope: nil, request_id: "SEQDISC"
    )

    with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue, :discard_sequence, ->(*, **_kwargs) { raise "rm failed" }
    ) do
      dispatcher.send(:discard_sequence_after_failure, entry)
    end

    assert(logger.events.any? { |(name, attrs)|
      name == :fatal && attrs[:message].include?("discard_sequence_after_failure raised")
    })
  end

  def test_notify_dispatch_failure_swallows_write_errors
    dispatcher, _sup, _ctrl, logger, _mw = make_dispatcher
    entry = ChildExit.new(
      pid: 562, exit_code: 0, project: "p1", slug: "s1", stage: nil,
      command: "hive markers clear s1", state_file_path: nil,
      started_at: T0, finished_at: T0, json_envelope: nil, request_id: "SEQNOTIFY"
    )

    with_replaced_singleton_method(
      Hive::Daemon::DispatchResultQueue, :write!, ->(*, **_kwargs) { raise "write failed" }
    ) do
      dispatcher.send(:notify_dispatch_failure, entry, { chat_id: 42 }, now: T0, reason: "boom")
    end

    assert(logger.events.any? { |(name, attrs)|
      name == :fatal && attrs[:message].include?("notify_dispatch_failure raised")
    })
  end

  def test_reap_suppresses_success_and_discards_sequence_when_promotion_raises
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, _logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        dispatch_result_state_home: state_home
      )
      write_request_file(
        state_home,
        slug: "s1",
        request_id: "SEQRAISE",
        argv: [ "hive", "markers", "clear", "s1", "--json" ]
      )
      Q.write_sequence!(
        "SEQRAISE",
        remaining_argvs: [ [ "hive", "review", "s1", "--from", "6-review", "--json" ] ],
        state_home: state_home
      )
      exited = ChildExit.new(
        pid: 560, exit_code: 0, project: "p1", slug: "s1", stage: nil,
        command: "hive markers clear s1 --json", state_file_path: nil,
        started_at: T0, finished_at: T0, json_envelope: nil, request_id: "SEQRAISE"
      )
      sup.define_singleton_method(:reap_all) { |now:| [ exited ] }

      with_replaced_singleton_method(
        Hive::Daemon::DispatchRequestQueue, :promote_sequence, ->(*, **_kwargs) { raise "disk error" }
      ) do
        dispatcher.send(:reap_completed, now: T0 + 1)
      end

      assert_empty Dir.glob(File.join(Q.directory(state_home: state_home), "SEQRAISE*")),
                   "the orphaned sequence sidecar must be discarded when promotion raises"

      notices = Hive::Daemon::DispatchResultQueue.pending(state_home: state_home)
      assert_equal 1, notices.size,
                   "a raised promotion must surface a failure notice, not a false success and not silence"
      refute_equal 0, notices.first.exit_code,
                   "the surfaced notice must carry a non-zero exit code so the bot renders a failure, not a success"
    end
  end

  # #4: a signal-killed child (R-02 timeout) has a nil exit_code; the reap
  # guard must treat nil as a failure and still write an ADV-1 notice.
  def test_reap_writes_notice_on_nil_exit_signal_kill
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, _logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        dispatch_result_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "KILL1")
      exited = ChildExit.new(
        pid: 557, exit_code: nil, project: "p1", slug: "s1", stage: nil,
        command: "hive review s1", state_file_path: nil,
        started_at: T0, finished_at: T0, json_envelope: nil, request_id: "KILL1"
      )
      sup.define_singleton_method(:reap_all) { |now:| [ exited ] }

      dispatcher.send(:reap_completed, now: T0 + 1)
      notices = Hive::Daemon::DispatchResultQueue.pending(state_home: state_home)
      assert_equal 1, notices.size, "a timeout/signal kill (nil exit) must still notify"
      assert_nil notices.first.exit_code
    end
  end

  # #5: claim expiry is sized to the run budget, not the 600s request window.
  def test_claim_expiry_sec_sizes_to_child_timeout_budget
    dispatcher, = make_dispatcher
    # No child_timeout_sec in config → falls back to the queue's generous default.
    assert_equal Hive::Daemon::DispatchRequestQueue::CLAIM_EXPIRY_SEC,
                 dispatcher.send(:claim_expiry_sec)

    dispatcher.instance_variable_set(:@daemon_cfg,
                                     { "child_timeout_sec" => 100, "child_kill_grace_sec" => 30 })
    dispatcher.instance_variable_set(:@poll_interval_sec, 30)
    # 100 (timeout) + 30 (grace) + 60 (2 poll intervals) + 600 (margin)
    assert_equal 790, dispatcher.send(:claim_expiry_sec)
  end

  # #6: the daemon prunes stale dispatch-result notices each tick.
  def test_prune_dispatch_results_removes_stale
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, = make_dispatcher(rows: [], dispatch_result_state_home: state_home)
      Hive::Daemon::DispatchResultQueue.write!(
        chat_id: 1, project: "p1", slug: "old", request_id: "r", exit_code: 1,
        command: "hive review old", state_home: state_home, now: T0 - 7200
      )
      dispatcher.send(:prune_dispatch_results, now: T0)
      assert_empty Hive::Daemon::DispatchResultQueue.pending(state_home: state_home)
    end
  end

  def test_prune_dispatch_results_swallows_errors
    dispatcher, _sup, _ctrl, logger = make_dispatcher
    with_replaced_singleton_method(
      Hive::Daemon::DispatchResultQueue, :prune_expired, ->(**_kw) { raise "boom" }
    ) do
      dispatcher.send(:prune_dispatch_results, now: T0)
    end
    assert(logger.events.any? { |(n, a)| n == :fatal && a[:message].to_s.include?("prune_dispatch_results") })
  end

  def test_process_alive_predicate_branches
    dispatcher, = make_dispatcher
    assert dispatcher.send(:process_alive?, Process.pid), "our own pid is alive"
    refute dispatcher.send(:process_alive?, 2**30), "an unused pid is not alive"
    with_replaced_singleton_method(Process, :kill, ->(_sig, _pid) { raise Errno::EPERM, "no perm" }) do
      assert dispatcher.send(:process_alive?, 1),
             "EPERM means the process exists but we may not signal it → alive"
    end
  end

  def test_recover_dispatch_claims_alive_lambda_paths
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, = make_dispatcher(rows: [], dispatch_request_state_home: state_home)
      # #260: pin the live start_time so the PID-reuse removal is asserted
      # unconditionally. The real `process_start_time(Process.pid)` returns
      # nil on /proc-less platforms (macOS CI, stripped containers), which
      # made the lambda treat the mismatch as "unverifiable → kept" and the
      # killme01 assertion was previously skipped behind `if live`.
      with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { "100" }) do
        # Owner alive + start_time matches → kept.
        write_request_file(state_home, slug: "s1", request_id: "keepme01")
        Q.claim("keepme01", pid: Process.pid, process_start_time: "100", now: T0, state_home: state_home)
        # Owner alive + start_time recorded nil → unverifiable → kept.
        write_request_file(state_home, slug: "s2", request_id: "nilstart")
        Q.claim("nilstart", pid: Process.pid, process_start_time: nil, now: T0, state_home: state_home)
        # Owner alive + start_time mismatch → PID reused → removed.
        write_request_file(state_home, slug: "s3", request_id: "killme01")
        Q.claim("killme01", pid: Process.pid, process_start_time: "999",
                now: T0, state_home: state_home)

        dispatcher.send(:recover_dispatch_claims, now: T0 + 5)
      end

      remaining = Dir.glob(File.join(state_home, "dispatch_requests", "*#{Q::CLAIMED_SUFFIX}"))
                     .map { |p| File.read(p) }.join
      assert_includes remaining, "keepme01", "matching start_time claim is kept"
      assert_includes remaining, "nilstart", "nil-start-time claim is kept (unverifiable)"
      refute_includes remaining, "killme01", "mismatched start_time (PID reused) claim is removed"
    end
  end

  def test_recover_dispatch_claims_swallows_errors
    dispatcher, _sup, _ctrl, logger = make_dispatcher
    with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue, :recover_claims,
      ->(**_kw) { raise "boom" }
    ) do
      dispatcher.send(:recover_dispatch_claims, now: T0)
    end
    # Not raising isn't enough (#261): prove the rescue logged :fatal with
    # the failing method name, like the other *_swallows_errors tests.
    assert(logger.events.any? { |(n, a)| n == :fatal && a[:message].to_s.include?("recover_dispatch_claims") },
           "the swallowed error must surface as a :fatal log event")
  end

  def test_preclaim_dispatch_request_raises_on_claim_failure
    dispatcher, = make_dispatcher
    req = Hive::Daemon::DispatchRequestQueue::Request.new(
      request_id: "X", created_at: T0, project: "p1", slug: "s1",
      argv: [ "hive", "run", "s1" ], requestor: "bot", chat_id: nil,
      update_id: nil, trigger: "", path: nil
    )
    with_replaced_singleton_method(
      Hive::Daemon::DispatchRequestQueue, :claim, ->(*_a, **_kw) { raise "boom" }
    ) do
      assert_raises(RuntimeError) do
        dispatcher.send(:preclaim_dispatch_request, req, now: T0)
      end
    end
  end

  def test_enforce_child_timeouts_swallows_errors
    dispatcher, sup, _ctrl, logger = make_dispatcher
    sup.define_singleton_method(:enforce_timeouts) { |now:| raise "boom" }
    dispatcher.send(:enforce_child_timeouts, now: T0)
    assert(logger.events.any? { |(n, a)| n == :fatal && a[:message].to_s.include?("enforce_child_timeouts") })
  end

  def test_notify_dispatch_result_swallows_write_errors
    dispatcher, _sup, _ctrl, logger = make_dispatcher
    entry = ChildExit.new(
      pid: 1, exit_code: 4, project: "p1", slug: "s1", stage: nil,
      command: "hive review s1", state_file_path: nil, started_at: T0,
      finished_at: T0, json_envelope: nil, request_id: "R1"
    )
    with_replaced_singleton_method(
      Hive::Daemon::DispatchResultQueue, :write!, ->(**_kw) { raise "disk full" }
    ) do
      dispatcher.send(:notify_dispatch_result, entry, { chat_id: 42 }, now: T0)
    end
    assert(logger.events.any? { |(n, a)| n == :fatal && a[:message].to_s.include?("notify_dispatch_result") })
  end

  # #251: result notices go to the dedicated dispatch_result_state_home,
  # not the (separately injectable) request home — so a test sandboxing
  # only the request queue can't silently write results where the bot,
  # reading the real result home, never sees them.
  def test_notify_dispatch_result_writes_to_dispatch_result_state_home
    Dir.mktmpdir("hive-result-home") do |result_home|
      Dir.mktmpdir("hive-request-home") do |request_home|
        dispatcher, = make_dispatcher(
          dispatch_request_state_home: request_home,
          dispatch_result_state_home: result_home
        )
        entry = ChildExit.new(
          pid: 1, exit_code: 4, project: "p1", slug: "s1", stage: nil,
          command: "hive review s1", state_file_path: nil, started_at: T0,
          finished_at: T0, json_envelope: nil, request_id: "R1"
        )
        dispatcher.send(:notify_dispatch_result, entry, { chat_id: 42 }, now: T0)

        assert_equal 1, Dir.glob(File.join(result_home, "dispatch_results", "*.json")).length,
                     "the result notice must land in the dispatch_result_state_home"
        assert_empty Dir.glob(File.join(request_home, "dispatch_results", "*.json")),
                     "no notice may leak into the dispatch_request_state_home"
      end
    end
  end

  # C3: startup recovery removes a claim whose owning process is gone,
  # without re-dispatching (logs :dispatch_request_recovered).
  def test_recover_dispatch_claims_cleans_dead_owner_claim
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, _sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "R9")
      # Claim with a PID that is virtually guaranteed dead.
      Q.claim("R9", pid: 2**30, process_start_time: "123",
              now: T0, state_home: state_home)

      dispatcher.send(:recover_dispatch_claims, now: T0 + 5)

      recovered = logger.events.find { |(n, _)| n == :dispatch_request_recovered }
      refute_nil recovered, "a removed claim must log :dispatch_request_recovered"
      assert_equal "owner_gone", recovered[1][:reason]
      assert_empty Q.pending(state_home: state_home)
      assert_empty Dir.glob(File.join(state_home, "dispatch_requests", "*"))
    end
  end

  def test_dispatch_request_rejected_when_argv_not_allowlisted
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "BAD",
                         argv: [ "hive", "doctor" ])
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        rejected = logger.events.find { |(n, attrs)| n == :dispatch_request_rejected && attrs[:request_id] == "BAD" }
        refute_nil rejected
        assert_equal "invalid_argv", rejected[1][:reason]
        assert_empty sup.spawned
        assert_empty Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
      ensure
        restore_find_project!
      end
    end
  end

  def test_dispatch_request_rejected_when_project_unknown
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "RX", project: "unknown-proj")
      # No stub for find_project ⇒ returns nil
      Hive::Config.singleton_class.alias_method(:__orig_find_project, :find_project) unless Hive::Config.singleton_class.method_defined?(:__orig_find_project)
      Hive::Config.define_singleton_method(:find_project) { |_| nil }
      begin
        dispatcher.tick(now: T0)

        rejected = logger.events.find { |(n, attrs)| n == :dispatch_request_rejected && attrs[:request_id] == "RX" }
        refute_nil rejected
        assert_equal "unknown_project", rejected[1][:reason]
        assert_empty sup.spawned
      ensure
        restore_find_project!
      end
    end
  end

  def test_v4_recovery_stays_queued_when_project_is_temporarily_unknown
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      recovery = {
        "phase" => "admitted",
        "observed_marker_generation" => "a" * 64,
        "expected_marker_attrs" => { "reason" => "timeout", "marker_id" => "marker-1" },
        "canonical_task_folder" => "/tmp/recovery-task",
        "expected_post_clear_progress_fingerprint" => "b" * 64,
        "dispatch_generation" => "c" * 64,
        "failure_origin" => "timeout",
        "next_eligible_at" => T0.iso8601(6),
        "owner" => "scheduler",
        "blocked_reason" => nil,
        "blocked_remediation" => nil
      }
      Q.write_request!(
        project: "temporarily-missing",
        slug: "recovery-task",
        argv: %w[hive run recovery-task --stage 4-execute --project temporarily-missing --json],
        requestor: "web",
        trigger: "recovery",
        request_id: "RECOVERY-MISSING",
        task_generation: "c" * 64,
        task_id: 817,
        expected_stage: "4-execute",
        expected_marker_name: "error",
        expected_marker_id: "marker-1",
        recovery: recovery,
        state_home: state_home,
        now: T0
      )
      with_replaced_singleton_method(Hive::Config, :find_project, ->(_name) { nil }) do
        dispatcher.tick(now: T0)
      end

      blocked = logger.events.find do |(name, attrs)|
        name == :dispatch_request_blocked && attrs[:request_id] == "RECOVERY-MISSING"
      end
      refute_nil blocked
      assert_equal "unknown_project", blocked[1][:reason]
      assert_empty sup.spawned
      assert_equal [ "RECOVERY-MISSING" ],
                   Q.pending(state_home: state_home).map(&:request_id)
    end
  end

  # The web "Repair daemon" button enqueues under the __global__ sentinel.
  # The consumer must special-case it (not reject as unknown_project) and
  # dispatch `hive daemon install --force` even though no project is registered.
  def test_global_maintenance_repair_dispatches_without_registered_project
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "daemon-repair", request_id: "REP",
                         project: Q::GLOBAL_MAINTENANCE_PROJECT,
                         argv: %w[hive daemon install --force], trigger: "web_daemon_repair")

      dispatcher.tick(now: T0)

      refute logger.events.any? { |(n, a)| n == :dispatch_request_rejected && a[:request_id] == "REP" },
             "global maintenance request must not be rejected as unknown_project"
      assert sup.spawned.any? { |f| f[:command].include?("daemon install --force") },
             "the repair command must actually be dispatched"
    end
  end

  def test_global_maintenance_rejects_argv_outside_allowlist
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      # An allowlisted verb that passes valid_argv? (a `daemon` verb outside the
      # maintenance allowlist is already rejected as invalid_argv upstream, so use
      # a non-daemon read verb) but is NOT in GLOBAL_MAINTENANCE_ARGVS: it reaches
      # process_global_maintenance_request and must be refused there, not dispatched.
      write_request_file(state_home, slug: "global-maint", request_id: "REPX",
                         project: Q::GLOBAL_MAINTENANCE_PROJECT,
                         argv: %w[hive markers clear global-maint], trigger: "web_daemon_repair")

      dispatcher.tick(now: T0)

      rejected = logger.events.find { |(n, a)| n == :dispatch_request_rejected && a[:request_id] == "REPX" }
      refute_nil rejected
      assert_equal "disallowed_global_request", rejected[1][:reason]
      assert_empty sup.spawned
    end
  end

  # A valid global-maintenance argv (in GLOBAL_MAINTENANCE_ARGVS) that is
  # ALREADY in flight for the same (__global__, slug) must be blocked
  # reason=in_flight — not dispatched a second time. Exercises the
  # running_task? guard in process_global_maintenance_request.
  def test_global_maintenance_blocked_when_repair_already_in_flight
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      # Pre-seed an in-flight repair for the SAME (__global__, daemon-repair).
      ctrl.record_dispatch(pid: 8888, project: Q::GLOBAL_MAINTENANCE_PROJECT,
                           slug: "daemon-repair", stage: nil,
                           command: "hive daemon install --force", started_at: T0,
                           state_file_mtime: nil)
      write_request_file(state_home, slug: "daemon-repair", request_id: "REPDUP",
                         project: Q::GLOBAL_MAINTENANCE_PROJECT,
                         argv: %w[hive daemon install --force], trigger: "web_daemon_repair")

      dispatcher.tick(now: T0)

      blocked = logger.events.find { |(n, a)| n == :dispatch_request_blocked && a[:request_id] == "REPDUP" }
      refute_nil blocked, "an already-in-flight global repair must log blocked, not re-dispatch"
      assert_equal "in_flight", blocked[1][:reason]
      # Only the pre-seeded slot exists; the duplicate request must NOT spawn.
      assert_empty sup.spawned, "the duplicate repair request must not spawn a second install"
      # The request file stays on disk for a later tick once the slot frees.
      files = Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
      assert_equal 1, files.size, "a blocked request must remain queued for the next tick"
    end
  end

  def test_dispatch_request_blocked_when_in_flight_for_same_slug
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      # Pre-seed an in-flight slot for (p1, s1)
      ctrl.record_dispatch(pid: 7777, project: "p1", slug: "s1", stage: nil,
                           command: "hive run s1", started_at: T0,
                           state_file_mtime: nil)
      write_request_file(state_home, slug: "s1", request_id: "DEF")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        blocked = logger.events.find { |(n, _)| n == :dispatch_request_blocked }
        refute_nil blocked
        assert_equal "in_flight", blocked[1][:reason]
        # The request file MUST remain on disk for the next tick.
        files = Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
        assert_equal 1, files.size
        # Sup must NOT have spawned this request (only the pre-seeded slot exists).
        assert_empty sup.spawned
      ensure
        restore_find_project!
      end
    end
  end

  # C4 from PR #241 ce-code-review: process_dispatch_requests must
  # gate on project_enabled? so a disabled project's queued requests
  # don't dispatch. Mirrors handle_row's project_enabled? gate.
  def test_dispatch_request_blocked_when_project_is_disabled
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "DISABLED")
      stub_find_project!(dispatcher, "p1")
      # Force the project to look disabled.
      dispatcher.define_singleton_method(:project_enabled?) { |_| false }
      begin
        dispatcher.tick(now: T0)
        dispatcher.tick(now: T0 + 60)

        blocked = logger.events.find do |(n, attrs)|
          n == :dispatch_request_blocked && attrs[:request_id] == "DISABLED"
        end
        refute_nil blocked, ":dispatch_request_blocked must fire for a disabled project"
        assert_equal "project_disabled", blocked[1][:reason]
        assert_equal 1, logger.events.count { |name, attrs|
          name == :dispatch_request_blocked && attrs[:request_id] == "DISABLED"
        }, "an unchanged durable block must not append another log entry every poll"
        assert_equal 1, logger.events.count { |name, attrs|
          name == :dispatch_request_observed && attrs[:request_id] == "DISABLED"
        }, "an unchanged request observation must not append another log entry every poll"
        # Request file stays on disk for retry once project is re-enabled.
        files = Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
        assert_equal 1, files.size,
                     "disabled-project block must NOT remove the request file"
        assert_empty sup.spawned
      ensure
        restore_find_project!
      end
    end
  end

  # R-01 from PR #241 ce-code-review: a spawn failure (Errno::EAGAIN
  # under fork-exhaustion, or any other StandardError raised by
  # dispatch_request!) must not abort the rest of the pending queue.
  # The failure is logged and the request file is left on disk for
  # the next tick to retry.
  def test_dispatch_request_spawn_failure_logs_and_does_not_abort_subsequent_iterations
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      # Two requests for different slugs in the same tick. The first
      # raises on dispatch; the second must still be processed.
      write_request_file(state_home, slug: "s1", request_id: "FAIL1",
                          created_at: T0)
      write_request_file(state_home, slug: "s2", request_id: "OK2",
                          created_at: T0 + 1)
      stub_find_project!(dispatcher, "p1")

      # Make dispatch_request! raise the FIRST time and succeed after.
      original = dispatcher.method(:dispatch_request!)
      call_count = 0
      dispatcher.define_singleton_method(:dispatch_request!) do |req, now:|
        call_count += 1
        raise Errno::EAGAIN, "fork: Resource temporarily unavailable" if call_count == 1

        original.call(req, now: now)
      end

      begin
        dispatcher.tick(now: T0)

        # First request → logged as rejected, file left on disk.
        failed = logger.events.find do |(n, attrs)|
          n == :dispatch_request_rejected && attrs[:request_id] == "FAIL1"
        end
        refute_nil failed,
                   "spawn failure must surface as :dispatch_request_rejected"
        assert_match(/spawn_failure: Errno::EAGAIN/, failed[1][:reason])
        # File NOT removed — next tick retries.
        files_after = Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
        assert(files_after.any? { |p| p.include?("FAIL1") },
               "FAIL1 file must remain for retry")

        # Second request still dispatched despite the first's failure.
        assert(sup.spawned.any? { |entry| entry[:request_id] == "OK2" },
               "subsequent request must dispatch even after a prior iteration raised")
      ensure
        restore_find_project!
      end
    end
  end

  def test_malformed_request_file_routes_through_bad_handler
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      # Write a syntactically broken JSON file directly into the
      # queue dir so DispatchRequestQueue.pending routes it through
      # the bad_handler the dispatcher injects (which logs +
      # unlinks).
      dir = Q.directory(state_home: state_home)
      File.write(File.join(dir, "20260528T180000000000-BAD.json"), "{not json")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        rejected = logger.events.find { |(n, attrs)|
          n == :dispatch_request_rejected && attrs[:reason] == "malformed_json"
        }
        refute_nil rejected,
                   ":dispatch_request_rejected reason=malformed_json must fire from the queue's bad_handler"
        assert_empty sup.spawned
        # The bad_handler must unlink the file so the queue doesn't
        # re-process it on every tick.
        assert_empty Dir.glob(File.join(dir, "*.json")),
                     "malformed files must be unlinked once the bad_handler logs them"
      ensure
        restore_find_project!
      end
    end
  end

  def test_dispatch_request_expired_removed_without_dispatch
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home
      )
      # Created 11 minutes before "now"
      ancient = T0 - (11 * 60)
      write_request_file(state_home, slug: "s1", request_id: "OLD", created_at: ancient)
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        expired = logger.events.find { |(n, _)| n == :dispatch_request_expired }
        refute_nil expired, "a 11-min-old request must be reaped before dispatch"
        assert_empty sup.spawned
        files = Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
        assert_empty files, "expired requests must be unlinked from the queue dir"
      ensure
        restore_find_project!
      end
    end
  end

  def test_per_slug_in_flight_gate_within_one_tick_blocks_same_slug_row_dispatch
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      # A row exists for the same slug as the queued request. The
      # request scan fires first and `record_dispatch`'s the controller.
      # When the row scan later sees the same slug, `dispatch_or_block`
      # must consult the controller and refuse rather than spawn a
      # second child against the same task.
      row_for_same_slug = row(slug: "s1", action: "ready_to_plan",
                              command: "hive plan s1 --from 2-brainstorm")
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [ row_for_same_slug ], dispatch_request_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "FIRST")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)

        # Exactly one spawn — for the request — not two.
        assert_equal 1, sup.spawned.size,
                     "per-slug in-flight gate must keep the row scan from double-spawning"
        assert_equal "FIRST", sup.spawned.first[:request_id]
        blocked = logger.events.find { |(n, attrs)| n == :blocked && attrs[:reason] == "in_flight" }
        refute_nil blocked, "row scan must log :blocked reason=in_flight when slug is already running"
      ensure
        restore_find_project!
      end
    end
  end

  def test_dispatch_request_completed_logs_on_child_reap
    Dir.mktmpdir("hive-dispatch-queue") do |state_home|
      dispatcher, sup, _ctrl, logger, _mw = make_dispatcher(
        rows: [], dispatch_request_state_home: state_home,
        dispatch_result_state_home: state_home
      )
      write_request_file(state_home, slug: "s1", request_id: "REQ-X")
      stub_find_project!(dispatcher, "p1")
      begin
        dispatcher.tick(now: T0)
        spawned_pid = sup.spawned.first[:pid]
        sup.define_singleton_method(:reap_all) do |now: Time.now|
          [
            ChildExit.new(
              pid: spawned_pid, exit_code: 0, project: "p1", slug: "s1", stage: nil,
              command: "hive run s1 --json", state_file_path: nil,
              started_at: T0, finished_at: now, json_envelope: nil,
              request_id: "REQ-X"
            )
          ]
        end

        dispatcher.tick(now: T0 + 60)

        completed = logger.events.find { |(n, _)| n == :dispatch_request_completed }
        refute_nil completed
        assert_equal "REQ-X", completed[1][:request_id]
        assert_equal 1, Hive::Daemon::DispatchResultQueue.pending(state_home: state_home).size
        # The file MUST have been unlinked.
        files = Dir.glob(File.join(Q.directory(state_home: state_home), "*.json"))
        assert_empty files
      ensure
        restore_find_project!
      end
    end
  end

  # ── brainstorm answers-pending gate ───────────────────────────────────

  def test_handle_row_holds_brainstorm_resume_while_answers_pending
    dispatcher, supervisor, controller, logger = make_dispatcher
    folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "s1")
    bpath = File.join(folder, "brainstorm.md")
    File.write(bpath, "## Round 1\n### Q1.\nWhat?\n### A1.\n\n### Q2.\nWhy?\n### A2.\nyes\n")
    # Seed a baseline so decide_edit would otherwise dispatch (mtime newer).
    controller.observe_state_file_mtime(project: "p1", slug: "s1", mtime: T0 - 600)
    r = row(action: "needs_input", stage: "2-brainstorm",
            command: "hive brainstorm s1 --from 2-brainstorm",
            state_file: bpath, mtime: T0 - 60, folder: folder)

    dispatcher.send(:handle_row, r, now: T0)

    assert_empty supervisor.spawned,
                 "must NOT resume the brainstorm while Q1 is unanswered"
    assert(logger.events.any? { |(n, a)| n == :skipped && a[:reason] == "answers_pending" },
           "the hold must be logged as :skipped reason=answers_pending")
  end

  def test_handle_row_resumes_brainstorm_once_all_answered
    dispatcher, supervisor, controller, = make_dispatcher
    folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "s1")
    bpath = File.join(folder, "brainstorm.md")
    File.write(bpath, "## Round 1\n### Q1.\nWhat?\n### A1.\nbecause\n### Q2.\nWhy?\n### A2.\nyes\n")
    controller.observe_state_file_mtime(project: "p1", slug: "s1", mtime: T0 - 600)
    r = row(action: "needs_input", stage: "2-brainstorm",
            command: "hive brainstorm s1 --from 2-brainstorm",
            state_file: bpath, mtime: T0 - 60, folder: folder)

    dispatcher.send(:handle_row, r, now: T0)

    assert_equal 1, supervisor.spawned.size,
                 "resumes once every question is answered"
  end

  def test_brainstorm_answers_pending_predicate_branches
    dispatcher, = make_dispatcher
    folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "s1")
    pending = File.join(folder, "brainstorm.md")
    File.write(pending, "## Round 1\n### Q1.\nWhat?\n### A1.\n\n")
    done = File.join(folder, "done.md")
    File.write(done, "## Round 1\n### Q1.\nWhat?\n### A1.\nanswered\n")

    assert dispatcher.send(:brainstorm_answers_pending?,
                           row(action: "needs_input", stage: "2-brainstorm",
                               state_file: pending, folder: folder))
    refute dispatcher.send(:brainstorm_answers_pending?,
                           row(action: "needs_input", stage: "2-brainstorm",
                               state_file: done, folder: folder))
    # Not a brainstorm stage → no Q&A, never pending.
    refute dispatcher.send(:brainstorm_answers_pending?,
                           row(action: "needs_input", stage: "6-review",
                               state_file: pending, folder: folder))
    # A NON-coding workflow that reuses the 2-brainstorm dir has no coding
    # Q&A answer flow → never pending (it must take the generic path, not be
    # held as answers_pending).
    refute dispatcher.send(:brainstorm_answers_pending?,
                           row(action: "needs_input", stage: "2-brainstorm",
                               workflow: "research",
                               state_file: pending, folder: folder))
    # Not a needs_input row.
    refute dispatcher.send(:brainstorm_answers_pending?,
                           row(action: "ready_to_brainstorm", stage: "2-brainstorm",
                               state_file: pending, folder: folder))
    # Missing file → not pending.
    refute dispatcher.send(:brainstorm_answers_pending?,
                           row(action: "needs_input", stage: "2-brainstorm",
                               state_file: "/no/such/brainstorm.md", folder: folder))
  end

  def test_brainstorm_answers_pending_fails_open_on_parse_error
    dispatcher, _supervisor, _controller, logger = make_dispatcher
    folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "s1")
    bpath = File.join(folder, "brainstorm.md")
    File.write(bpath, "## Round 1\n### Q1.\nWhat?\n### A1.\n\n")
    r = row(action: "needs_input", stage: "2-brainstorm", state_file: bpath, folder: folder)

    with_replaced_singleton_method(Hive::BrainstormParser, :parse, ->(*) { raise "boom" }) do
      refute dispatcher.send(:brainstorm_answers_pending?, r),
             "a parse error must fail OPEN (false) so a malformed file can't strand the task"
    end
    assert(logger.events.any? { |(n, a)| n == :fatal && a[:message].to_s.include?("brainstorm_answers_pending") })
  end

  # #5: end-to-end — on a parse error the daemon must actually RESUME
  # (re-run the agent to self-heal), not just have the predicate return
  # false. Seed a baseline so Policy reaches :dispatch.
  def test_handle_row_resumes_brainstorm_on_parse_error
    dispatcher, supervisor, controller, = make_dispatcher
    folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "s1")
    bpath = File.join(folder, "brainstorm.md")
    File.write(bpath, "## Round 1\n### Q1.\nWhat?\n### A1.\n\n")
    controller.observe_state_file_mtime(project: "p1", slug: "s1", mtime: T0 - 600)
    r = row(action: "needs_input", stage: "2-brainstorm",
            command: "hive brainstorm s1 --from 2-brainstorm",
            state_file: bpath, mtime: T0 - 60, folder: folder)

    with_replaced_singleton_method(Hive::BrainstormParser, :parse, ->(*) { raise "boom" }) do
      dispatcher.send(:handle_row, r, now: T0)
    end
    assert_equal 1, supervisor.spawned.size,
                 "fail-open must let the daemon resume (re-run the agent) rather than strand"
  end

  # #1: a persistent parse error logs :fatal only once per (project, slug)
  # — not on every ~30s tick — and re-arms after a successful parse.
  def test_brainstorm_parse_error_log_is_deduped_per_slug
    dispatcher, _supervisor, _controller, logger = make_dispatcher
    folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "s1")
    bpath = File.join(folder, "brainstorm.md")
    File.write(bpath, "## Round 1\n### Q1.\nWhat?\n### A1.\n\n")
    r = row(action: "needs_input", stage: "2-brainstorm", state_file: bpath, folder: folder)

    with_replaced_singleton_method(Hive::BrainstormParser, :parse, ->(*) { raise "boom" }) do
      3.times { dispatcher.send(:brainstorm_answers_pending?, r) }
    end
    fatals = logger.events.count { |(n, a)| n == :fatal && a[:slug] == "s1" }
    assert_equal 1, fatals, "three failing ticks must log :fatal once, not three times"

    # A successful parse clears the flag so a later recurrence logs again.
    dispatcher.send(:brainstorm_answers_pending?, r)
    with_replaced_singleton_method(Hive::BrainstormParser, :parse, ->(*) { raise "boom" }) do
      dispatcher.send(:brainstorm_answers_pending?, r)
    end
    assert_equal 2, logger.events.count { |(n, a)| n == :fatal && a[:slug] == "s1" },
                 "the dedup re-arms after a successful parse"
  end

  def test_brainstorm_answers_pending_multi_round_and_edge_files
    dispatcher, = make_dispatcher
    folder = make_existing_row_folder(project: "p1", stage: "2-brainstorm", slug: "s1")

    # Round 1 fully answered, Round 2 still open → pending.
    multi = File.join(folder, "multi.md")
    File.write(multi, "## Round 1\n### Q1.\nA?\n### A1.\nyes\n## Round 2\n### Q2.\nB?\n### A2.\n\n")
    assert dispatcher.send(:brainstorm_answers_pending?,
                           row(action: "needs_input", stage: "2-brainstorm",
                               state_file: multi, folder: folder))

    # A `### Q` with NO `### A` slot at all → still unanswered → held
    # (documents the no-fillable-slot case; recovery is operator/bot side).
    noslot = File.join(folder, "noslot.md")
    File.write(noslot, "## Round 1\n### Q1.\nA?\n")
    assert dispatcher.send(:brainstorm_answers_pending?,
                           row(action: "needs_input", stage: "2-brainstorm",
                               state_file: noslot, folder: folder))

    # Zero parseable questions (empty / header drift) → fail OPEN (resume
    # to re-run the agent); the bot can't answer it either.
    zeroq = File.join(folder, "zeroq.md")
    File.write(zeroq, "## Round 1\nno questions here\n")
    refute dispatcher.send(:brainstorm_answers_pending?,
                           row(action: "needs_input", stage: "2-brainstorm",
                               state_file: zeroq, folder: folder))
  end

  # ── R-02: child-timeout enforcement + logging ─────────────────────────

  def test_enforce_child_timeouts_logs_one_event_per_action
    dispatcher, supervisor, _controller, logger = make_dispatcher
    action = Hive::Daemon::ChildSupervisor::TimeoutAction.new(
      pid: 4321, project: "p1", slug: "s1", stage: "6-review",
      command: "hive review s1", action: :term, elapsed_sec: 7300, timeout_sec: 7200
    )
    supervisor.define_singleton_method(:enforce_timeouts) { |now:| [ action ] }

    dispatcher.send(:enforce_child_timeouts, now: T0)

    timeouts = logger.events.select { |(name, _)| name == :child_timeout }
    assert_equal 1, timeouts.size
    attrs = timeouts.first.last
    assert_equal 4321, attrs[:pid]
    assert_equal "term", attrs[:action]
    assert_equal 7300, attrs[:elapsed_sec]
    assert_equal 7200, attrs[:timeout_sec]
  end

  def test_safe_mtime_returns_nil_when_mtime_raises_on_existing_path
    # dispatcher.rb 566: File.exist? can race File.mtime — the file may
    # vanish (or otherwise error) between the existence check and the
    # stat. The rescue must degrade to nil rather than propagate.
    dispatcher, _sup, _ctrl, _logger, _mw = make_dispatcher

    Dir.mktmpdir("dispatcher-safe-mtime") do |dir|
      path = File.join(dir, "vanishing.md")
      File.write(path, "x\n")
      with_replaced_singleton_method(File, :mtime, lambda { |arg|
        raise Errno::ENOENT, arg if arg == path

        File.stat(arg).mtime
      }) do
        assert_nil dispatcher.send(:safe_mtime, path),
                   "safe_mtime must return nil when File.mtime raises after File.exist? passed"
      end
    end
  end

  def test_enforce_child_timeouts_noop_when_supervisor_lacks_method
    dispatcher, _supervisor, _controller, logger = make_dispatcher
    # FakeSupervisor does not define enforce_timeouts — the guard must
    # keep this a silent no-op rather than raising.
    dispatcher.send(:enforce_child_timeouts, now: T0)
    refute events_include?(logger, :child_timeout)
  end

  # Wiring check: a tick must drive the display-name backfiller over the
  # status rows. We swap in a backfiller with a fake spawn so no real
  # `hive generate-name` subprocess is started, and assert the missing-
  # name row produces a display_name_backfill event without disturbing
  # the rest of the tick.
  def test_tick_invokes_display_name_backfiller
    folder = make_existing_row_folder(project: "p1", stage: "4-execute", slug: "s1")
    Hive::TaskMeta.write(folder, id: 1, slug: "s1", display_name: nil)
    rows = [ row(action: "working", marker: "agent_working", command: nil,
                 folder: folder, claude_pid_alive: true) ]
    dispatcher, _sup, _ctrl, logger = make_dispatcher(rows: rows)

    spawned = []
    backfiller = Hive::Daemon::DisplayNameBackfiller.new(
      logger: dispatcher.instance_variable_get(:@logger),
      dry_run: false,
      spawn: ->(f) { spawned << f; Process.pid }
    )
    dispatcher.instance_variable_set(:@display_name_backfiller, backfiller)

    dispatcher.tick(now: T0)

    assert_equal [ folder ], spawned,
                 "tick must drive the backfiller to spawn generate-name for the unnamed task"
    assert events_include?(logger, :display_name_backfill),
           "tick must emit a display_name_backfill event"
    refute events_include?(logger, :fatal),
           "backfiller wiring must not crash the tick"
  end

  # dispatcher.rb 239: a backfiller that raises must be caught by the
  # tick's defensive rescue so a backfiller bug can't crash the tick (and
  # trip the unit's restart-loop cap). The error is surfaced as :fatal.
  def test_tick_survives_display_name_backfiller_raising
    folder = make_existing_row_folder(project: "p1", stage: "4-execute", slug: "s1")
    rows = [ row(action: "working", marker: "agent_working", command: nil,
                 folder: folder, claude_pid_alive: true) ]
    dispatcher, _sup, _ctrl, logger = make_dispatcher(rows: rows)

    exploding = Object.new
    def exploding.backfill(*); raise "backfiller boom"; end
    dispatcher.instance_variable_set(:@display_name_backfiller, exploding)

    dispatcher.tick(now: T0)

    fatal = logger.events.find do |(n, a)|
      n == :fatal && a[:message].to_s.include?("display_name_backfiller raised")
    end
    refute_nil fatal, "a raising backfiller must be caught and logged as :fatal"
    assert_includes fatal[1][:message], "backfiller boom"
  end

  # Wiring check: a tick must drive the task-id backfiller over the status
  # rows. We swap in a backfiller with a fake allocate/commit so no real
  # counter or git commit happens, and assert the missing-id row gets an id
  # and a task_id_backfill event without disturbing the rest of the tick.
  def test_tick_invokes_task_id_backfiller
    folder = make_existing_row_folder(project: "p1", stage: "4-execute", slug: "s1")
    Hive::TaskMeta.write(folder, id: nil, slug: "s1", display_name: "Name")
    rows = [ row(action: "working", marker: "agent_working", command: nil,
                 folder: folder, claude_pid_alive: true) ]
    dispatcher, _sup, _ctrl, logger = make_dispatcher(rows: rows)

    backfiller = Hive::Daemon::TaskIdBackfiller.new(
      logger: dispatcher.instance_variable_get(:@logger),
      dry_run: false,
      allocate: -> { 999 },
      commit: ->(_row) { true }
    )
    dispatcher.instance_variable_set(:@task_id_backfiller, backfiller)

    dispatcher.tick(now: T0)

    assert_equal 999, Hive::TaskMeta.read(folder)[:id],
                 "tick must drive the backfiller to assign an id to the id-less task"
    assert events_include?(logger, :task_id_backfill),
           "tick must emit a task_id_backfill event"
    refute events_include?(logger, :fatal),
           "backfiller wiring must not crash the tick"
  end

  # A task-id backfiller that raises must be caught by the tick's defensive
  # rescue so a backfiller bug can't crash the tick (and trip the unit's
  # restart-loop cap). The error is surfaced as :fatal.
  def test_tick_survives_task_id_backfiller_raising
    folder = make_existing_row_folder(project: "p1", stage: "4-execute", slug: "s1")
    rows = [ row(action: "working", marker: "agent_working", command: nil,
                 folder: folder, claude_pid_alive: true) ]
    dispatcher, _sup, _ctrl, logger = make_dispatcher(rows: rows)

    exploding = Object.new
    def exploding.backfill(*); raise "id backfiller boom"; end
    dispatcher.instance_variable_set(:@task_id_backfiller, exploding)

    dispatcher.tick(now: T0)

    fatal = logger.events.find do |(n, a)|
      n == :fatal && a[:message].to_s.include?("task_id_backfiller raised")
    end
    refute_nil fatal, "a raising id backfiller must be caught and logged as :fatal"
    assert_includes fatal[1][:message], "id backfiller boom"
  end

  private

  def dispatcher_recovery(phase: "admitted")
    {
      "phase" => phase,
      "observed_marker_generation" => "a" * 64,
      "expected_marker_attrs" => {
        "reason" => "timeout", "marker_id" => "marker-1"
      },
      "canonical_task_folder" => "/tmp/recovery-task",
      "expected_post_clear_progress_fingerprint" => "b" * 64,
      "dispatch_generation" => "c" * 64,
      "failure_origin" => "timeout",
      "next_eligible_at" => T0.iso8601(6),
      "owner" => phase == "dispatched" ? "agent" : "scheduler",
      "blocked_reason" => nil,
      "blocked_remediation" => nil,
      "retry_count" => 1
    }
  end

  def events_include?(logger, name)
    logger.events.any? { |(n, _)| n == name }
  end

  def seed_baseline(path, project:, slug:, mtime:)
    Hive::Daemon::ConcurrencyController.new(
      max_concurrent_runs: 5, max_concurrent_per_project: 5,
      max_runs_per_day_per_project: 100,
      dispatch_state: Hive::Daemon::DispatchBaselines.new(path: path)
    ).observe_state_file_mtime(project: project, slug: slug, mtime: mtime)
  end
end
