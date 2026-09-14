# frozen_string_literal: true

require "test_helper"
require "fileutils"

# The bench harness is packaged (templates/builtins/bench/runtime/harness) and
# linted/lint-excluded there, but its planner/executor Pipeline is scored logic:
# these tests load it from its packaged home and pin the cell statuses it emits.
module BenchHarness
  HARNESS_ROOT = File.expand_path("../../../templates/builtins/bench/runtime/harness", __dir__)
end
$LOAD_PATH.unshift(BenchHarness::HARNESS_ROOT) unless $LOAD_PATH.include?(BenchHarness::HARNESS_ROOT)
require "lib/pipeline"

class BenchHarnessPipelineTest < Minitest::Test
  PROFILE = Struct.new(:model)

  def setup
    super
    @out_dir = Dir.mktmpdir("bench-pipeline-test")
    @entry = {
      "task_id" => "t1",
      "checkout_source" => "/tmp/fake-source",
      "source" => { "base_commit" => "abc123" },
      "entry_dir" => @out_dir
    }
    @planner = PROFILE.new("planner-1")
    @executor = PROFILE.new("executor-1")
    # Stub restorer: no real git — the pipeline only needs restore to create the
    # work tree and diff to return a non-empty patch for the executor phase.
    @restorer = Object.new
    def @restorer.restore(source:, base_commit:, into:)
      FileUtils.mkdir_p(into)
    end
    def @restorer.diff(work_dir:, base_commit:)
      "diff --git a/f b/f\n+++ b/f\n@@ -0,0 +1 @@\n+change\n"
    end
  end

  def teardown
    FileUtils.rm_rf(@out_dir)
    super
  end

  def test_pipeline_generates_a_scored_cell_when_the_planner_and_executor_succeed
    cell = pipeline(plan_status: :ok).call(entry: @entry, planner: @planner, executor: @executor,
                                           pair_id: "planner-1->executor-1", out_dir: @out_dir)

    assert_equal "generated", cell.status
    assert_path_exists cell.diff_path
  end

  # Root-cause guard: planner success was inferred solely from provider-limit
  # text and plan-file emptiness. A planner killed at the wall clock (or exiting
  # non-zero) can still leave a non-empty HIVE_BENCH_PLAN.md behind — that
  # partial plan must never reach the executor and get scored as "generated".
  def test_planner_timeout_with_a_written_plan_does_not_reach_the_executor
    executed = false
    cell = pipeline(plan_status: :timeout,
                    exec_spawn: ->(_p) { executed = true; spawn_result(:ok) })
          .call(entry: @entry, planner: @planner, executor: @executor,
                pair_id: "planner-1->executor-1", out_dir: @out_dir)

    assert_equal "plan_failed", cell.status
    assert_nil cell.diff_path
    assert_equal "planner timed out", cell.reason
    refute executed, "executor must not run from a plan an unfinished planner left behind"
  end

  def test_planner_non_zero_exit_with_a_written_plan_does_not_reach_the_executor
    cell = pipeline(plan_status: :error).call(entry: @entry, planner: @planner, executor: @executor,
                                              pair_id: "planner-1->executor-1", out_dir: @out_dir)

    assert_equal "plan_failed", cell.status
    assert_nil cell.diff_path
    assert_equal "planner exited non-zero", cell.reason
  end

  def test_planner_timeout_without_a_plan_still_fails_the_plan
    cell = pipeline(plan_status: :timeout, write_plan: false)
          .call(entry: @entry, planner: @planner, executor: @executor,
                pair_id: "planner-1->executor-1", out_dir: @out_dir)

    assert_equal "plan_failed", cell.status
    assert_nil cell.diff_path
  end

  def test_planner_provider_limit_still_parks_the_cell
    cell = pipeline(plan_status: :ok, plan_stream: "You've hit your usage limit.")
          .call(entry: @entry, planner: @planner, executor: @executor,
                pair_id: "planner-1->executor-1", out_dir: @out_dir)

    assert_equal "limit_hit", cell.status
    assert_equal "planner hit a provider limit", cell.reason
  end

  private

  # plan_spawn writes the plan file the way the real isolation runner does (the
  # agent writes it into its work tree) and returns the given spawn status.
  def pipeline(plan_status:, write_plan: true, plan_stream: "", exec_spawn: nil)
    plan_spawn = lambda do |profile:, prompt:, cwd:|
      if write_plan
        FileUtils.mkdir_p(cwd)
        File.write(File.join(cwd, HiveBench::IsolationExec::PLAN_OUTPUT_FILE),
                   "1. implement the thing\n2. test the thing\n")
      end
      spawn_result(plan_status, stdout: plan_stream)
    end
    exec_spawn ||= ->(_p) { spawn_result(:ok) }

    HiveBench::Pipeline.new(plan_spawn: plan_spawn, exec_spawn: exec_spawn,
                            restorer: @restorer, clock: -> { Time.at(0) })
  end

  def spawn_result(status, stdout: "")
    { stdout: stdout, stderr: "", status: status, model: "m", usage: {} }
  end
end
