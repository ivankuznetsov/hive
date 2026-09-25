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

  class PatrolScheduler
    attr_reader :completed

    def candidates(**)
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

  class ArchitectureScheduler
    attr_reader :completed, :cancelled, :spawned_call
    attr_accessor :events

    def initialize
      @events = []
    end

    def candidates(**)
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

    def readiness(**) = []
    def drain_events = events
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
        guard: Guard.new, clock: -> { NOW }
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
      scheduler = PatrolScheduler.new
      result = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, executor: Executor.new,
        guard: Guard.new, dry_run: true, clock: -> { NOW }
      ).call

      assert_empty result.to_h.fetch("ran")
      assert_nil scheduler.completed
    end
  end

  def test_architecture_runs_intake_and_one_durable_candidate
    with_tmp_dir do |dir|
      scheduler = ArchitectureScheduler.new
      result = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, reconciler: Reconciler.new,
        executor: Executor.new, guard: Guard.new, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call

      assert_equal %w[merge_intake discovery], result.to_h.fetch("ran").map { |row| row["action"] }
      assert_equal "job-1", scheduler.completed.dig(:dispatch_token, :job_id)
      refute_nil scheduler.spawned_call
      assert_equal "recurring_intake",
                   result.to_h.dig("pending", "waiting_external", 0, "reason")
      assert_schema(result)
    end
  end

  def test_patrol_reports_ownership_and_execution_failures
    with_tmp_dir do |dir|
      refused = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: PatrolScheduler.new, guard: RefusingGuard.new,
        clock: -> { NOW }
      ).call
      assert_equal "daemon_owned", refused.to_h.dig("error", "code")

      scheduler = PatrolScheduler.new
      failed = Hive::OneShot::PatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler, executor: FailingExecutor.new,
        guard: Guard.new, clock: -> { NOW }
      ).call
      assert_equal "runtime_error", failed.to_h.dig("error", "code")
      assert_equal 1, scheduler.completed.fetch(:exit_code)
    end
  end

  def test_architecture_projects_intake_states_events_and_failures
    with_tmp_dir do |dir|
      scheduler = ArchitectureScheduler.new
      scheduler.events = [ { job_id: "blocked", reason: "operator_needed" } ]
      partial = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: scheduler,
        reconciler: ResultReconciler.new(project: "demo", status: :partial),
        executor: Executor.new, guard: Guard.new, dry_run: true, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call
      assert_equal 1, partial.to_h.dig("pending", "runnable_now").size
      assert_equal 1, partial.to_h.dig("pending", "waiting_operator").size

      backoff = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: ArchitectureScheduler.new,
        reconciler: ResultReconciler.new(
          project: "demo", status: :backoff, retry_at: NOW + 60
        ),
        executor: Executor.new, guard: Guard.new, dry_run: true, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call
      assert_equal "backoff", backoff.to_h.dig("pending", "waiting_external", 0, "reason")

      blocked = Hive::OneShot::ArchitecturePatrolAdapter.new(
        entry: entry(dir), scheduler: ArchitectureScheduler.new,
        reconciler: ResultReconciler.new(
          project: "demo", status: :blocked, reason: "offline", error: "network"
        ),
        guard: Guard.new, clock: -> { NOW }, config_loader: ->(*) { enabled_config }
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
        executor: FailingExecutor.new, guard: Guard.new, clock: -> { NOW },
        config_loader: ->(*) { enabled_config }
      ).call
      assert_equal "observation_failed", failed.to_h.dig("error", "code")
      refute_nil failing_scheduler.cancelled
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
