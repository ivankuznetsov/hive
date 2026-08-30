require "test_helper"
require "hive/stages/review"

class ReviewCiGatesTest < Minitest::Test
  include HiveTestHelper

  Task = Struct.new(:folder, :state_file, :slug, keyword_init: true)

  def result(status, attempts: 1, output: nil, error: nil, limit: nil)
    Hive::Stages::Review::CiFix::Result.new(
      status: status, attempts: attempts, last_output: output,
      error_message: error, limit_text: limit
    )
  end

  def guardrail_result
    match = Hive::Stages::Review::FixGuardrail::Match.new(
      pattern_name: "ci_workflow_edit", file: ".github/workflows/ci.yml",
      line: 1, snippet: "name: changed", severity: :high,
      match_sha256: "a" * 64
    )
    Hive::Stages::Review::FixGuardrail::Result.new(
      status: :tripped, matches: [ match ], waived_matches: []
    )
  end

  def with_fixture
    with_tmp_git_repo do |repo|
      folder = File.join(repo, ".hive-state", "stages", "6-review", "gate-task")
      FileUtils.mkdir_p(File.join(folder, "reviews"))
      state_file = File.join(folder, "task.md")
      File.write(state_file, "task\n")
      task = Task.new(folder: folder, state_file: state_file, slug: "gate-task")
      ctx = Hive::Stages::Review::Context.new(
        worktree_path: repo, task_folder: folder, default_branch: "master", pass: 1
      )
      cfg = {
        "review" => {
          "ci" => { "max_attempts" => 1 },
          "fix" => { "guardrail" => { "enabled" => true } }
        },
        "timeout_sec" => { "review_ci" => 5 }
      }
      yield(repo, task, ctx, cfg)
    end
  end

  def with_ci_results(local:, remote:)
    with_replaced_singleton_method(
      Hive::Stages::Review::CiFix, :run!, ->(**) { local.call }
    ) do
      with_replaced_singleton_method(
        Hive::Stages::Review::RemoteCi, :run!, ->(**) { remote.call }
      ) do
        yield
      end
    end
  end

  def test_run_ci_gates_runs_local_then_hosted_and_accepts_an_unchanged_head
    with_fixture do |_repo, task, ctx, cfg|
      calls = []
      local = -> { calls << :local; result(:green) }
      remote = -> { calls << :remote; result(:skipped, attempts: 0) }

      terminal = with_ci_results(local: local, remote: remote) do
        Hive::Stages::Review.run_ci_gates(
          task, cfg, ctx,
          started_at: Time.now, max_wall_clock_sec: 60, pass: 1
        )
      end

      assert_nil terminal
      assert_equal %i[local remote], calls
    end
  end

  def test_run_ci_gates_scans_a_safe_repair_after_both_gates
    with_fixture do |repo, task, ctx, cfg|
      local = lambda do
        FileUtils.mkdir_p(File.join(repo, "lib"))
        File.write(File.join(repo, "lib", "repair.rb"), "REPAIRED = true\n")
        run!("git", "-C", repo, "add", "lib/repair.rb")
        run!("git", "-C", repo, "commit", "-m", "repair", "--quiet")
        result(:green)
      end
      remote = -> { result(:green) }

      terminal = with_ci_results(local: local, remote: remote) do
        Hive::Stages::Review.run_ci_gates(
          task, cfg, ctx,
          started_at: Time.now, max_wall_clock_sec: 60, pass: 1
        )
      end

      assert_nil terminal
    end
  end

  def test_run_ci_gates_parks_a_risky_repair_on_the_shared_guardrail
    with_fixture do |repo, task, ctx, cfg|
      local = lambda do
        FileUtils.mkdir_p(File.join(repo, ".github", "workflows"))
        File.write(File.join(repo, ".github", "workflows", "ci.yml"), "name: changed\n")
        run!("git", "-C", repo, "add", ".github/workflows/ci.yml")
        run!("git", "-C", repo, "commit", "-m", "risky repair", "--quiet")
        result(:green)
      end
      remote = -> { result(:skipped, attempts: 0) }

      terminal = with_ci_results(local: local, remote: remote) do
        Hive::Stages::Review.run_ci_gates(
          task, cfg, ctx,
          started_at: Time.now, max_wall_clock_sec: 60, pass: 2
        )
      end

      assert_equal :review_waiting, terminal.fetch(:status)
      marker = Hive::Markers.current(task.state_file)
      assert_equal :review_waiting, marker.name
      assert_equal "ci", marker.attrs.fetch("source")
      assert_equal "combined", marker.attrs.fetch("gate")
      assert File.file?(File.join(task.folder, "reviews", "fix-guardrail-02.md"))
    end
  end

  def test_run_ci_gates_enforces_the_outer_wall_clock_after_a_gate
    with_fixture do |_repo, task, ctx, cfg|
      terminal = with_ci_results(
        local: -> { result(:green) }, remote: -> { flunk "remote gate must not start" }
      ) do
        Hive::Stages::Review.run_ci_gates(
          task, cfg, ctx,
          started_at: Time.now - 10, max_wall_clock_sec: 1, pass: 3
        )
      end

      assert_equal :review_stale, terminal.fetch(:status)
      assert_equal "wall_clock", Hive::Markers.current(task.state_file).attrs.fetch("reason")
    end
  end

  def test_ci_terminal_result_maps_stale_limit_error_and_unknown_states
    with_fixture do |_repo, task, ctx, _cfg|
      stale = Hive::Stages::Review.ci_terminal_result(
        task, result(:stale, attempts: 3, output: "still red"),
        gate: "github", pass: 1, ctx: ctx
      )
      assert_equal :review_ci_stale, stale.fetch(:status)
      assert_includes File.read(File.join(task.folder, "reviews", "ci-blocked.md")), "GitHub CI"

      limited = Hive::Stages::Review.ci_terminal_result(
        task, result(:error, error: "quota", limit: "resets tomorrow"),
        gate: "local", pass: 2, ctx: ctx
      )
      assert_equal :review_error, limited.fetch(:status)
      assert_equal "limits_reached", Hive::Markers.current(task.state_file).attrs.fetch("reason")

      errored = Hive::Stages::Review.ci_terminal_result(
        task, result(:error, error: "binary missing"),
        gate: "github", pass: 3, ctx: ctx
      )
      assert_equal "ci_unrunnable", Hive::Markers.current(task.state_file).attrs.fetch("reason")
      assert_equal :review_error, errored.fetch(:status)

      unexpected = Hive::Stages::Review.ci_terminal_result(
        task, result(:mystery), gate: "local", pass: 4, ctx: ctx
      )
      assert_equal :review_error, unexpected.fetch(:status)
      assert_equal "ci_unexpected", Hive::Markers.current(task.state_file).attrs.fetch("reason")

      assert_nil Hive::Stages::Review.ci_terminal_result(
        task, result(:skipped, attempts: 0), gate: "local", pass: 5, ctx: ctx
      )
      assert_nil Hive::Stages::Review.ci_terminal_result(
        task, result(:green), gate: "github", pass: 5, ctx: ctx
      )
    end
  end

  def test_ci_terminal_result_maps_remote_guardrail_to_review_waiting
    with_fixture do |_repo, task, ctx, _cfg|
      remote = Hive::Stages::Review::RemoteCi::Result.new(
        status: :guardrail, attempts: 1, last_output: nil,
        error_message: "blocked", limit_text: nil,
        guardrail: guardrail_result
      )

      terminal = Hive::Stages::Review.ci_terminal_result(
        task, remote, gate: "github", pass: 1, ctx: ctx
      )

      assert_equal :review_waiting, terminal.fetch(:status)
      marker = Hive::Markers.current(task.state_file)
      assert_equal "fix_guardrail", marker.attrs.fetch("reason")
      assert_equal "github", marker.attrs.fetch("gate")
    end
  end
end
