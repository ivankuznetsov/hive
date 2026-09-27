require "test_helper"
require "json_schemer"
require "hive/one_shot/architecture_patrol_adapter"
require "hive/one_shot/patrol_adapter"
require "hive/commands/patrol"
require "hive/commands/refactor_patrol"

class OneShotPatrolAdaptersTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 9, 23, 12)

  class Guard
    def synchronize = yield
  end

  class RefusingGuard
    def synchronize
      raise Hive::OneShot::ProjectGuard::OwnershipError.new(
        "owned", code: "daemon_owned", owner: { "kind" => "daemon", "pid" => 42 }
      )
    end
  end

  class InterruptingGuard
    def synchronize = raise Interrupt, "stopping"
  end

  class Liveness
    def initialize(safe = true) = @safe = safe
    def safe_to_stop? = @safe
  end

  class Executor
    attr_reader :commands

    def initialize(exit_code: 0, envelope: { "schema_version" => 4 })
      @execution = Hive::OneShot::ProcessExecutor::Execution.new(
        exit_code: exit_code, envelope: envelope
      )
      @commands = []
    end

    def call(command, on_spawn: nil)
      @commands << command
      on_spawn&.call(Process.pid)
      @execution
    end
  end

  class FailingExecutor
    def call(*) = raise("execution failed")
  end

  class InterruptingExecutor
    def call(*) = raise Interrupt, "stopping"
  end

  class PatrolScheduler
    attr_reader :completed, :candidate_calls

    def initialize
      @candidate_calls = []
    end

    def candidates(**arguments)
      @candidate_calls << arguments
      [ { project: "demo", entry: {}, command: "hive patrol demo --json" } ]
    end

    def reserve(candidate, **) = candidate

    def complete(**attributes)
      @completed = attributes
    end

    def readiness(**)
      [ {
        "bucket" => "waiting_external", "id" => "patrol:scan",
        "component" => "patrol", "reason" => "cadence",
        "next_check_at" => NOW + 600,
        "condition" => {
          "kind" => "time_due", "project" => "demo",
          "deadline" => (NOW + 600).iso8601(6)
        }
      } ]
    end
  end

  class DryRunPatrolScheduler < PatrolScheduler
    def readiness(**)
      [ {
        "bucket" => "runnable_now", "id" => "patrol:scan",
        "component" => "patrol", "reason" => "due",
        "next_check_at" => nil, "condition" => nil
      } ]
    end
  end

  class ArchitectureScheduler
    attr_reader :completed, :cancelled, :spawned_call, :candidate_calls, :readiness_calls
    attr_accessor :events

    def initialize
      @events = []
      @candidate_calls = []
      @readiness_calls = []
    end

    def candidates(**arguments)
      @candidate_calls << arguments
      return [] if @completed

      [ {
        project: "demo", job_id: "job-1", action_phase: :discovery,
        command: "hive refactor-patrol demo --json", dispatch_token: { job_id: "job-1" }
      } ]
    end

    def reserve(candidate, **) = candidate
    def spawned(*args, **kwargs) = @spawned_call = [ args, kwargs ]

    def cancel(*args, **kwargs) = @cancelled = [ args, kwargs ]

    def complete(**attributes)
      @completed = attributes
      { status: :classified }
    end

    def readiness(**arguments)
      @readiness_calls << arguments
      Array(arguments[:candidates]).map do |candidate|
        {
          "bucket" => "runnable_now",
          "id" => "architecture:discovery:#{candidate.fetch(:job_id)}",
          "component" => "architecture_patrol", "reason" => "eligible",
          "next_check_at" => nil, "condition" => nil
        }
      end
    end
    def drain_events = events
  end

  class IdleArchitectureScheduler < ArchitectureScheduler
    def candidates(**arguments)
      @candidate_calls << arguments
      []
    end
  end

  class EventClearingArchitectureScheduler < IdleArchitectureScheduler
    def readiness(candidates: nil, **arguments)
      events.clear if candidates.nil?
      super(candidates: candidates, **arguments)
    end
  end

  class Reconciler
    def tick(**)
      [ { project: "demo", status: :complete, enqueued_prs: [ 7 ] } ]
    end
  end

  class ResultReconciler
    def initialize(result)
      @result = result
    end

    def tick(**) = [ @result ]
  end

  def test_patrol_runs_one_reserved_scan_then_projects_cadence
    with_tmp_dir do |dir|
      scheduler = PatrolScheduler.new
      executor = Executor.new(envelope: { "schema" => "hive-patrol" })
      result = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, executor: executor,
        guard: Guard.new, liveness: Liveness.new, clock: -> { NOW }
      ).call

      assert_equal "ok", result.to_h.fetch("status")
      assert_equal [ "hive patrol demo --json" ], executor.commands
      assert_equal 0, scheduler.completed.fetch(:exit_code)
      assert_equal "completed", result.to_h.dig("ran", 0, "outcome")
      assert_equal (NOW + 600).iso8601(6), result.to_h.fetch("next_due_at")
      assert_schema(result)
    end
  end

  def test_patrol_dry_run_observes_without_reserving
    with_tmp_dir do |dir|
      scheduler = DryRunPatrolScheduler.new
      result = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, executor: Executor.new,
        guard: Guard.new, liveness: Liveness.new, dry_run: true, clock: -> { NOW }
      ).call

      assert_empty result.to_h.fetch("ran")
      assert_nil scheduler.completed
      assert_equal [ "patrol:scan" ],
                   result.to_h.dig("pending", "runnable_now").map { |item| item.fetch("id") }
    end
  end

  def test_patrol_and_architecture_honor_persisted_project_drop
    with_tmp_dir do |dir|
      state = Hive::OneShot::ScheduleState.new(state_root: File.join(dir, ".hive-state"))
      state.update("dispatch", now: NOW) do
        {
          "cooldowns" => [], "transient_failures" => {},
          "quarantined" => [], "dropped" => true
        }
      end

      patrol_executor = Executor.new
      patrol = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: PatrolScheduler.new, executor: patrol_executor,
        guard: Guard.new, liveness: Liveness.new, clock: -> { NOW }
      ).call
      architecture_executor = Executor.new
      architecture = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: ArchitectureScheduler.new,
        reconciler: Reconciler.new, executor: architecture_executor,
        guard: Guard.new, liveness: Liveness.new, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call

      assert_empty patrol_executor.commands
      assert_empty architecture_executor.commands
      [ patrol, architecture ].each do |result|
        assert_empty result.to_h.dig("pending", "runnable_now")
        assert_equal "project_dropped",
                     result.to_h.dig("pending", "waiting_operator", 0, "reason")
      end
    end
  end

  def test_patrol_admission_projects_transient_capacity_without_rewriting_other_waits
    with_tmp_dir do |dir|
      admission = Hive::OneShot::PatrolAdmission.new(entry: entry(dir))
      waiting = {
        "bucket" => "waiting_operator", "id" => "patrol:operator",
        "reason" => "manual", "next_check_at" => nil,
        "condition" => { "kind" => "operator_action", "project" => "demo" }
      }
      items = admission.apply(
        [ item("runnable_now"), waiting ], gate: :patrol_scan_cap, now: NOW
      )

      projected = items.first
      assert_equal "waiting_external", projected.fetch("bucket")
      assert_equal "patrol_scan_cap", projected.fetch("reason")
      assert_equal (NOW + 30).iso8601(6), projected.fetch("next_check_at").iso8601(6)
      assert_equal waiting, items.last
    end
  end

  def test_patrol_and_architecture_withhold_stop_safety_for_live_project_workers
    with_tmp_dir do |dir|
      patrol = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: PatrolScheduler.new, executor: Executor.new,
        guard: Guard.new, liveness: Liveness.new(false), dry_run: true,
        clock: -> { NOW }
      ).call
      architecture = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: IdleArchitectureScheduler.new,
        reconciler: Reconciler.new, guard: Guard.new,
        liveness: Liveness.new(false), dry_run: true, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call

      refute patrol.safe_to_stop?
      refute architecture.safe_to_stop?
    end
  end

  def test_architecture_runs_intake_and_one_durable_candidate
    with_tmp_dir do |dir|
      scheduler = ArchitectureScheduler.new
      result = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, reconciler: Reconciler.new,
        executor: Executor.new, guard: Guard.new, liveness: Liveness.new, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call

      assert_equal %w[merge_intake discovery], result.to_h.fetch("ran").map { |row| row["action"] }
      assert_equal "job-1", scheduler.completed.dig(:dispatch_token, :job_id)
      refute_nil scheduler.spawned_call
      assert_equal "recurring_intake",
                   result.to_h.dig("pending", "waiting_external", 0, "reason")
      assert_equal 2, scheduler.candidate_calls.size
      assert_empty scheduler.readiness_calls.first.fetch(:candidates)
      assert_empty result.to_h.dig("pending", "runnable_now")
      assert_schema(result)
    end
  end

  def test_architecture_recomputes_readiness_after_classification_creates_post_merge_work
    with_tmp_dir do |dir|
      scheduler = ArchitectureScheduler.new
      calls = 0
      scheduler.define_singleton_method(:candidates) do |**arguments|
        @candidate_calls << arguments
        calls += 1
        phase = calls == 1 ? :classification : :post_merge
        [ {
          project: "demo", job_id: "job-1", action_phase: phase,
          command: "hive refactor-patrol demo --json", dispatch_token: { job_id: "job-1" }
        } ]
      end
      result = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, reconciler: Reconciler.new,
        executor: Executor.new, guard: Guard.new, liveness: Liveness.new,
        clock: -> { NOW }, config_loader: ->(*) { enabled_config }
      ).call

      assert_equal [ "architecture:discovery:job-1" ],
                   result.to_h.dig("pending", "runnable_now").map { |item| item.fetch("id") }
      assert_equal :post_merge,
                   scheduler.readiness_calls.first.fetch(:candidates).first.fetch(:action_phase)
    end
  end

  def test_patrol_reports_ownership_and_execution_failures
    with_tmp_dir do |dir|
      refused = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: (refused_scheduler = PatrolScheduler.new),
        executor: (refused_executor = Executor.new), guard: RefusingGuard.new,
        clock: -> { NOW }
      ).call
      assert_equal "daemon_owned", refused.to_h.dig("error", "code")
      assert_empty refused_scheduler.candidate_calls
      assert_empty refused_executor.commands

      scheduler = PatrolScheduler.new
      failed = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, executor: FailingExecutor.new,
        guard: Guard.new, liveness: Liveness.new, clock: -> { NOW }
      ).call
      assert_equal "runtime_error", failed.to_h.dig("error", "code")
      assert_equal 1, scheduler.completed.fetch(:exit_code)
    end
  end

  def test_patrol_and_architecture_interruptions_become_unsafe_results
    with_tmp_dir do |dir|
      patrol = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: PatrolScheduler.new,
        guard: InterruptingGuard.new, clock: -> { NOW }
      ).call
      architecture = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: ArchitectureScheduler.new,
        reconciler: Reconciler.new, guard: InterruptingGuard.new,
        clock: -> { NOW }, config_loader: ->(*) { enabled_config }
      ).call

      [ patrol, architecture ].each do |result|
        assert_equal "error", result.to_h.fetch("status")
        assert_equal "interrupted", result.to_h.dig("error", "code")
        refute result.safe_to_stop?
        assert_schema(result)
      end
    end
  end

  def test_interrupting_reserved_scans_are_settled_before_reporting_interruption
    with_tmp_dir do |dir|
      patrol_scheduler = PatrolScheduler.new
      patrol = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: patrol_scheduler, executor: InterruptingExecutor.new,
        guard: Guard.new, liveness: Liveness.new, clock: -> { NOW }
      ).call
      architecture_scheduler = ArchitectureScheduler.new
      architecture = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: architecture_scheduler, reconciler: Reconciler.new,
        executor: InterruptingExecutor.new, guard: Guard.new, liveness: Liveness.new,
        clock: -> { NOW }, config_loader: ->(*) { enabled_config }
      ).call

      assert_equal "interrupted", patrol.to_h.dig("error", "code")
      assert_equal 1, patrol_scheduler.completed.fetch(:exit_code)
      assert_equal "interrupted", architecture.to_h.dig("error", "code")
      refute_nil architecture_scheduler.cancelled
    end
  end

  def test_architecture_projects_intake_states_events_and_failures
    with_tmp_dir do |dir|
      scheduler = IdleArchitectureScheduler.new
      scheduler.events = [ { job_id: "blocked", reason: "operator_needed" } ]
      partial = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler,
        reconciler: ResultReconciler.new(project: "demo", status: :partial),
        executor: Executor.new, guard: Guard.new, liveness: Liveness.new,
        dry_run: true, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call
      assert_equal 1, partial.to_h.dig("pending", "runnable_now").size
      assert_equal 1, partial.to_h.dig("pending", "waiting_operator").size

      backoff = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: ArchitectureScheduler.new,
        reconciler: ResultReconciler.new(
          project: "demo", status: :backoff, retry_at: NOW + 60
        ),
        executor: Executor.new, guard: Guard.new, liveness: Liveness.new,
        dry_run: true, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call
      assert_equal "backoff", backoff.to_h.dig("pending", "waiting_external", 0, "reason")

      blocked = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: ArchitectureScheduler.new,
        reconciler: ResultReconciler.new(
          project: "demo", status: :blocked, reason: "offline", error: "network"
        ),
        guard: Guard.new, liveness: Liveness.new, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call
      assert_equal "network", blocked.to_h.dig("error", "details", "error")

      refused = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: ArchitectureScheduler.new, reconciler: Reconciler.new,
        guard: RefusingGuard.new, clock: -> { NOW }, config_loader: ->(*) { enabled_config }
      ).call
      assert_equal "refused", refused.to_h.fetch("status")

      failing_scheduler = ArchitectureScheduler.new
      failed = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: failing_scheduler, reconciler: Reconciler.new,
        executor: FailingExecutor.new, guard: Guard.new, liveness: Liveness.new,
        clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call
      assert_equal "observation_failed", failed.to_h.dig("error", "code")
      refute_nil failing_scheduler.cancelled
    end
  end

  def test_architecture_treats_blocked_scheduler_events_as_observation_failure
    with_tmp_dir do |dir|
      scheduler = EventClearingArchitectureScheduler.new
      scheduler.events = [
        { status: :blocked, reason: "recovery_state_unavailable", error: "offline" }
      ]
      result = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, reconciler: Reconciler.new,
        guard: Guard.new, liveness: Liveness.new, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call

      assert_equal "error", result.to_h.fetch("status")
      assert_equal "observation_failed", result.to_h.dig("error", "code")
      assert_nil result.to_h.fetch("pending")
      refute result.safe_to_stop?
      assert_schema(result)
      assert_equal 1, scheduler.candidate_calls.size
      assert_equal [], scheduler.readiness_calls.first.fetch(:candidates)
    end
  end

  def test_architecture_event_ids_are_unique_for_same_reason
    with_tmp_dir do |dir|
      scheduler = IdleArchitectureScheduler.new
      scheduler.events = [
        { status: :waiting, batch_id: "batch-1", reason: "operator_needed" },
        { status: :waiting, batch_id: "batch-2", reason: "operator_needed" }
      ]
      result = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, reconciler: Reconciler.new,
        guard: Guard.new, liveness: Liveness.new, dry_run: true, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call

      ids = result.to_h.dig("pending", "waiting_operator").map { |item| item.fetch("id") }
      assert_equal ids.uniq, ids
      assert_equal 2, ids.size
      assert_schema(result)
    end
  end

  def test_architecture_uses_configured_interval_without_persisting_advisory_intake_deadline
    with_tmp_dir do |dir|
      times = [ NOW, NOW + 2, NOW + 7 ]
      result = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: IdleArchitectureScheduler.new,
        reconciler: Reconciler.new, guard: Guard.new, liveness: Liveness.new,
        clock: -> { times.shift || (NOW + 7) }, poll_interval_sec: 900,
        config_loader: ->(*) { enabled_config }
      ).call

      deadline = (NOW + 907).iso8601(6)
      assert_equal deadline, result.to_h.dig("pending", "waiting_external", 0, "next_check_at")
      refute File.exist?(File.join(dir, ".hive-state", "scheduler", "checkpoint.json"))
    end
  end


  def test_architecture_ownership_refuses_before_intake_or_scheduler_work
    with_tmp_dir do |dir|
      scheduler = ArchitectureScheduler.new
      executor = Executor.new
      reconciler = Object.new
      reconciler.define_singleton_method(:tick) { |**| raise "must not run" }
      result = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, reconciler: reconciler,
        executor: executor, guard: RefusingGuard.new, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call

      assert_equal "daemon_owned", result.to_h.dig("error", "code")
      assert_empty scheduler.candidate_calls
      assert_empty executor.commands
    end
  end

  def test_default_adapters_construct_their_scheduler_dependencies
    with_tmp_dir do |dir|
      patrol = Hive::OneShot::PatrolAdapter.new(entry: entry(dir))
      architecture = Hive::OneShot::ArchitecturePatrolAdapter.new(entry: entry(dir))

      assert_instance_of Hive::Daemon::PatrolScheduler,
                         patrol.instance_variable_get(:@scheduler)
      assert_instance_of Hive::Daemon::RefactorPatrolScheduler,
                         architecture.instance_variable_get(:@scheduler)
      assert_instance_of Time, patrol.instance_variable_get(:@clock).call
      assert_equal [ entry(dir) ],
                   patrol.instance_variable_get(:@scheduler).instance_variable_get(:@registry).call
      assert_instance_of Time, architecture.instance_variable_get(:@clock).call
      assert_instance_of Hash, architecture.instance_variable_get(:@config_loader).call(dir)
    end
  end

  def test_commands_emit_only_the_shared_one_shot_envelope
    with_tmp_dir do |dir|
      project = entry(dir)
      result = Hive::OneShot::Result.ok(
        component: :patrol, project: "demo", started_at: NOW, finished_at: NOW,
        ran: [], items: [], safe_to_stop: true
      )
      adapter = Struct.new(:result) { def call = result }.new(result)
      factory = ->(actual) { assert_equal project, actual; adapter }

      patrol_out, = capture_io do
        assert_same result, Hive::Commands::Patrol.new(
          "demo", once: true, project_entry: project, one_shot_factory: factory
        ).call
      end
      architecture_out, = capture_io do
        assert_same result, Hive::Commands::RefactorPatrol.new(
          "demo", once: true, project_entry: project, one_shot_factory: factory
        ).call
      end

      assert_equal result.to_h, JSON.parse(patrol_out)
      assert_equal result.to_h, JSON.parse(architecture_out)
    end
  end

  def test_commands_build_default_one_shot_adapters
    with_tmp_dir do |dir|
      project = entry(dir)
      result = Hive::OneShot::Result.ok(
        component: :patrol, project: "demo", started_at: NOW, finished_at: NOW,
        ran: [], items: [], safe_to_stop: true
      )
      adapter = Struct.new(:result) { def call = result }.new(result)
      patrol_arguments = nil

      with_replaced_singleton_method(
        Hive::OneShot::PatrolAdapter, :new,
        lambda { |**arguments| patrol_arguments = arguments; adapter }
      ) do
        capture_io do
          Hive::Commands::Patrol.new(
            "demo", once: true, dry_run: true, project_entry: project
          ).call
        end
      end
      assert_equal project, patrol_arguments.fetch(:entry)
      assert patrol_arguments.fetch(:dry_run)
      architecture_arguments = nil
      with_replaced_singleton_method(
        Hive::OneShot::ArchitecturePatrolAdapter, :new,
        lambda { |**arguments| architecture_arguments = arguments; adapter }
      ) do
        capture_io do
          Hive::Commands::RefactorPatrol.new(
            "demo", once: true, dry_run: true, project_entry: project
          ).call
        end
      end
      assert_equal project, architecture_arguments.fetch(:entry)
      assert architecture_arguments.fetch(:dry_run)
    end
  end

  private

  def entry(dir)
    FileUtils.mkdir_p(File.join(dir, ".hive-state"))
    {
      "name" => "demo", "path" => dir, "hive_state_path" => File.join(dir, ".hive-state"),
      "project_id" => "demo-id", "registration_id" => "demo-registration"
    }
  end

  def item(bucket)
    {
      "bucket" => bucket, "id" => "patrol:scan", "reason" => "eligible",
      "next_check_at" => nil, "condition" => nil
    }
  end

  def enabled_config
    Hive::Config.deep_merge(
      Hive::Config.deep_dup(Hive::Config::DEFAULTS),
      "daemon" => { "enabled" => true },
      "refactor_patrol" => { "enabled" => true }
    )
  end

  def assert_schema(result)
    schema = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-one-shot")))
    )
    errors = schema.validate(result.to_h).to_a
    assert_empty errors, errors.inspect
  end
end
