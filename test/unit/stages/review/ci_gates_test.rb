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
      assert_equal "local", marker.attrs.fetch("gate")
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

  def with_review_state(**values)
    review = Hive::Stages::Review
    previous = values.to_h { |key, _| [ key, [ review.instance_variable_defined?("@#{key}"), review.instance_variable_get("@#{key}") ] ] }
    values.each { |key, value| review.instance_variable_set("@#{key}", value) }
    yield
  ensure
    previous.each do |key, (defined, value)|
      defined ? review.instance_variable_set("@#{key}", value) : review.remove_instance_variable("@#{key}")
    end
  end

  def test_completion_gate_rejects_movement_after_the_verified_review
    with_fixture do |repo, task, ctx, cfg|
      before = Hive::Stages::Review.git_head(repo)
      run!("git", "-C", repo, "commit", "--allow-empty", "-qm", "concurrent edit")
      with_review_state(verify_mode: true, reviewed_head: before) do
        gate = Hive::Stages::Review.completion_ci_gate(task, cfg, ctx, before,
          started_at: Time.now, max_wall_clock_sec: 60)
        assert_equal :review_error, gate.terminal[:status]
        assert_nil gate.head
        refute gate.repaired
        assert_equal "verification_head_moved", Hive::Markers.current(task.state_file).attrs["reason"]
      end
    end
  end

  def test_withheld_publication_cannot_leave_a_complete_marker
    with_fixture do |repo, task, ctx, cfg|
      head = Hive::Stages::Review.git_head(repo)
      File.write(File.join(task.folder, "pr.md"), "---\npr_url: https://github.com/acme/app/pull/42\n---\n")
      Hive::Markers.set(task.state_file, :review_complete)
      publisher = Struct.new(:evidence).new({ "publication" => "unpublished" })
      with_review_state(admissible_head: head, publication_attempt_head: head,
        review_publisher: publisher, withheld_reason: "guardrail_approval_required") do
        terminal = Hive::Stages::Review.publish_review_head(task: task, cfg: cfg, ctx: ctx)
        assert_equal :review_error, terminal[:status]
        marker = Hive::Markers.current(task.state_file)
        assert_equal "review_publication_withheld", marker.attrs["reason"]
        assert_equal "guardrail_approval_required", marker.attrs["publication_reason"]
      end
    end
  end

  def test_hosted_ci_admission_records_the_repaired_head_before_publication
    with_fixture do |repo, task, ctx, cfg|
      test_case = self
      green = result(:green)
      remote = lambda do |admit_head:, **|
        test_case.run!("git", "-C", repo, "commit", "--allow-empty", "-qm", "CI repair")
        admit_head.call(Hive::Stages::Review.git_head(repo))
        test_case.assert_includes File.read(File.join(task.folder, "reviews", "fix-success-01.md")), "kind=ci_repaired"
        green
      end
      with_review_state(admissible_head: nil, withheld_reason: "fix_guardrail_receipt_required") do
        with_replaced_singleton_method(Hive::Stages::Review::CiFix, :run!, ->(**) { green }) do
          with_replaced_singleton_method(Hive::Stages::Review::RemoteCi, :run!, remote) do
            assert_nil Hive::Stages::Review.run_ci_gates(task, cfg, ctx,
              started_at: Time.now, max_wall_clock_sec: 60, pass: 1)
          end
        end
        assert_equal Hive::Stages::Review.git_head(repo), Hive::Stages::Review.instance_variable_get(:@admissible_head)
        assert_nil Hive::Stages::Review.instance_variable_get(:@withheld_reason)
      end
    end
  end

  def test_final_combined_guardrail_catches_movement_after_both_ci_observations
    with_fixture do |repo, task, ctx, cfg|
      test_case = self
      original = Hive::Stages::Review.method(:git_head)
      reads = 0
      head = lambda do |path|
        reads += 1
        if reads == 4
          FileUtils.mkdir_p(File.join(repo, ".github", "workflows"))
          File.write(File.join(repo, ".github", "workflows", "ci.yml"), "name: concurrent\n")
          test_case.run!("git", "-C", repo, "add", ".github/workflows/ci.yml")
          test_case.run!("git", "-C", repo, "commit", "-qm", "concurrent workflow edit")
        end
        original.call(path)
      end
      with_replaced_singleton_method(Hive::Stages::Review, :git_head, head) do
        terminal = with_ci_results(local: -> { result(:green) }, remote: -> { result(:green) }) do
          Hive::Stages::Review.run_ci_gates(task, cfg, ctx,
            started_at: Time.now, max_wall_clock_sec: 60, pass: 1)
        end
        assert_equal :review_waiting, terminal[:status]
        assert_equal "combined", Hive::Markers.current(task.state_file).attrs["gate"]
      end
    end
  end
end
