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
      @execution
    end
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
    attr_reader :completed

    def candidates(**)
      [ {
        project: "demo", job_id: "job-1", action_phase: :discovery,
        command: "hive refactor-patrol demo --json", dispatch_token: { job_id: "job-1" }
      } ]
    end

    def reserve(candidate, **) = candidate
    def spawned(*) = nil

    def complete(**attributes)
      @completed = attributes
      { status: :classified }
    end

    def readiness(**) = []
    def drain_events = []
  end

  class Reconciler
    def tick(**)
      [ { project: "demo", status: :complete, enqueued_prs: [ 7 ] } ]
    end
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
      assert_equal "recurring_intake",
                   result.to_h.dig("pending", "waiting_external", 0, "reason")
      assert_schema(result)
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
