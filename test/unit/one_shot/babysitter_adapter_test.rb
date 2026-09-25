require "test_helper"
require "json_schemer"
require "hive/one_shot/babysitter_adapter"

class OneShotBabysitterAdapterTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 9, 23, 12)

  class Guard
    def synchronize = yield
  end

  class RefusingGuard
    def synchronize
      owner = { "kind" => "daemon", "pid" => 42, "process_identity" => "boot:42" }
      raise Hive::OneShot::ProjectGuard::OwnershipError.new(
        "owned", code: "daemon_owned", owner: owner
      )
    end
  end

  class Tick
    attr_reader :arguments

    def initialize(summary)
      @summary = summary
    end

    def run(*arguments, **keywords)
      @arguments = [ arguments, keywords ]
      @summary
    end
  end

  class CodedError < StandardError
    def code = "coded_failure"
    def exit_code = Hive::ExitCodes::CONFIG
  end

  def test_reports_capacity_ci_operator_and_retry_readiness
    with_tmp_dir do |dir|
      tick = Tick.new(summary(
        pr(1, :capacity_deferred), pr(2, :success), pr(3, :give_up),
        pr(4, :failure)
      ))
      result = adapter(dir, tick: tick).call

      assert_equal [ "babysitter:pr:1" ], ids(result, "runnable_now")
      assert_equal [ "babysitter:pr:2", "babysitter:pr:4", "babysitter:poll" ],
                   ids(result, "waiting_external")
      assert_equal [ "babysitter:pr:3" ], ids(result, "waiting_operator")
      assert_equal "pr_changed",
                   result.to_h.dig("pending", "waiting_external", 0, "condition", "kind")
      assert_equal %w[success give_up failure],
                   result.to_h.fetch("ran").map { |row| row.fetch("outcome") }
      assert_equal NOW.iso8601(6), result.to_h.fetch("next_due_at")
      assert_schema(result)
    end
  end

  def test_dry_run_only_observes_and_leaves_eligible_pr_runnable
    with_tmp_dir do |dir|
      tick = Tick.new(summary(pr(9, :eligible)))
      result = adapter(dir, tick: tick, dry_run: true).call

      assert_empty result.to_h.fetch("ran")
      assert_equal [ "babysitter:pr:9" ], ids(result, "runnable_now")
      assert tick.arguments.last.fetch(:observe_only)
      refute File.exist?(File.join(dir, ".hive-state", "scheduler", "checkpoint.json"))
    end
  end

  def test_observation_failure_withholds_readiness
    with_tmp_dir do |dir|
      tick = Tick.new(summary.merge(
        error: { code: "github_observation_failed", message: "offline" }
      ))
      result = adapter(dir, tick: tick).call

      assert_equal "error", result.to_h.fetch("status")
      assert_nil result.to_h.fetch("pending")
      refute result.safe_to_stop?
    end
  end

  def test_main_daemon_ownership_refuses_before_github_observation
    with_tmp_dir do |dir|
      tick = Tick.new(summary)
      result = adapter(dir, tick: tick, main_guard: RefusingGuard.new).call

      assert_equal "refused", result.to_h.fetch("status")
      assert_equal "daemon_owned", result.to_h.dig("error", "code")
      assert_nil tick.arguments
    end
  end

  def test_ineligible_project_is_idle_without_polling
    with_tmp_dir do |dir|
      tick = Tick.new(summary)
      result = adapter(
        dir, tick: tick,
        config: Hive::Config.deep_dup(Hive::Config::DEFAULTS)
      ).call

      assert_equal "ok", result.to_h.fetch("status")
      assert_empty result.to_h.fetch("ran")
      assert_nil tick.arguments
    end
  end

  def test_pipeline_and_attempt_ownership_become_external_wakes
    with_tmp_dir do |dir|
      result = adapter(
        dir, tick: Tick.new(summary(pr(5, :pipeline_owned), pr(6, :inflight)))
      ).call

      kinds = result.to_h.dig("pending", "waiting_external").filter_map do |item|
        item.dig("condition", "kind") unless item["id"] == "babysitter:poll"
      end
      assert_equal %w[task_changed attempt_completed], kinds
    end
  end

  def test_unexpected_tick_errors_preserve_typed_exit_information
    with_tmp_dir do |dir|
      tick = Object.new
      tick.define_singleton_method(:run) { |*| raise CodedError, "broken" }
      result = adapter(dir, tick: tick).call

      assert_equal "coded_failure", result.to_h.dig("error", "code")
      assert_equal Hive::ExitCodes::CONFIG, result.exit_code
    end
  end

  def test_default_guards_and_config_loader_are_constructed
    with_tmp_dir do |dir|
      state = File.join(dir, ".hive-state")
      FileUtils.mkdir_p(state)
      instance = Hive::OneShot::BabysitterAdapter.new(
        entry: {
          "name" => "demo", "path" => dir, "hive_state_path" => state,
          "repository_identity" => "github.com/acme/demo"
        }, tick: Tick.new(summary)
      )

      assert_instance_of Hive::OneShot::ProjectGuard,
                         instance.instance_variable_get(:@main_guard)
      assert_instance_of Hive::OneShot::ProjectGuard,
                         instance.instance_variable_get(:@babysitter_guard)
      assert_instance_of Hash, instance.instance_variable_get(:@config_loader).call(dir)
    end
  end

  private

  def adapter(dir, tick:, dry_run: false, main_guard: Guard.new, config: nil)
    state = File.join(dir, ".hive-state")
    FileUtils.mkdir_p(state)
    Hive::OneShot::BabysitterAdapter.new(
      entry: {
        "name" => "demo", "path" => dir, "hive_state_path" => state,
        "repository_identity" => "github.com/acme/demo"
      },
      dry_run: dry_run, tick: tick, main_guard: main_guard,
      babysitter_guard: Guard.new, clock: -> { NOW },
      config_loader: ->(*) {
        config || Hive::Config.deep_merge(
          Hive::Config.deep_dup(Hive::Config::DEFAULTS),
          "babysitter" => { "enabled" => true, "interval" => "10m" }
        )
      }
    )
  end

  def summary(*prs)
    {
      total: prs.size, fixed: 0, untouched: 0, needs_human: 0,
      prs: prs, error: nil, interrupted: false
    }
  end

  def pr(number, outcome)
    { number: number, outcome: outcome, head_sha: "a" * 40 }
  end

  def ids(result, bucket)
    result.to_h.dig("pending", bucket).map { |row| row.fetch("id") }
  end

  def assert_schema(result)
    schema = JSONSchemer.schema(
      JSON.parse(File.read(Hive::Schemas.schema_path("hive-one-shot")))
    )
    errors = schema.validate(result.to_h).to_a
    assert_empty errors, errors.inspect
  end
end
