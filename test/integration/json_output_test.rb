require "test_helper"
require "json"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/run"
require "hive/commands/status"

# Pin the agent-callable JSON contracts emitted by `hive status --json` and
# `hive run --json`. Schema versions are checked explicitly so a future
# breaking change to either payload fails this test instead of silently
# breaking downstream parsers.
class JsonOutputTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT].each { |k| ENV.delete(k) }
  end

  def seed_execute_waiting_task(dir, slug:, reason:, worktree_path: dir)
    execute_dir = File.join(dir, ".hive-state", "stages", "4-execute", slug)
    FileUtils.mkdir_p(execute_dir)
    File.write(File.join(execute_dir, "task.md"), "<!-- EXECUTE_WAITING reason=#{reason} -->\n")
    File.write(File.join(execute_dir, "plan.md"), "# Plan\n")
    File.write(File.join(execute_dir, "worktree.yml"), {
      "path" => worktree_path,
      "branch" => slug
    }.to_yaml)
    execute_dir
  end

  def with_execute_waiting_runner_stub
    require "hive/stages/execute"
    Hive::Stages::Execute.singleton_class.alias_method(:__json_output_orig_run!, :run!)
    Hive::Stages::Execute.define_singleton_method(:run!) { |_task, _cfg| { commit: nil, status: :execute_waiting } }
    yield
  ensure
    if Hive::Stages::Execute.singleton_class.method_defined?(:__json_output_orig_run!)
      Hive::Stages::Execute.singleton_class.alias_method(:run!, :__json_output_orig_run!)
      Hive::Stages::Execute.singleton_class.send(:remove_method, :__json_output_orig_run!)
    end
  end

  def test_status_json_is_a_single_parseable_document_with_schema_header
    with_tmp_global_config do
      out, _err = capture_io { Hive::Commands::Status.new(json: true).call }
      assert_equal 1, out.lines.count, "JSON output must be a single line on stdout (no stray puts)"
      payload = JSON.parse(out)
      assert_equal "hive-status", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_equal [], payload["projects"], "empty registry must surface as projects:[]"
      assert payload["generated_at"].match?(/\A\d{4}-\d{2}-\d{2}T/), "generated_at must be ISO-8601"
    end
  end

  def test_status_json_emits_task_records_with_stable_keys
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        project = File.basename(dir)
        capture_io { Hive::Commands::New.new(project, "json status probe").call }

        out, _err = capture_io { Hive::Commands::Status.new(json: true).call }
        payload = JSON.parse(out)
        proj = payload["projects"].find { |p| p["name"] == project }
        refute_nil proj, "registered project should appear in JSON output"
        task = proj["tasks"].first
        refute_nil task

        %w[stage slug folder state_file marker attrs mtime age_seconds claude_pid claude_pid_alive next_action]
          .each { |k| assert task.key?(k), "JSON task record must include '#{k}'" }
        assert_equal "1-inbox", task["stage"]
        assert_equal "waiting", task["marker"], "fresh idea.md is in WAITING state"
        assert_kind_of Integer, task["age_seconds"]
        assert_nil task["claude_pid"], "no claude_pid until an agent has run"
        assert_nil task["next_action"]
      end
    end
  end

  def test_status_json_execute_waiting_includes_reason_specific_next_action
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        dirty_worktree = File.join(dir, "dirty-worktree")
        FileUtils.mkdir_p(dirty_worktree)
        seed_execute_waiting_task(
          dir,
          slug: "execute-dirty-status-260426-aaaa",
          reason: "dirty_worktree",
          worktree_path: dirty_worktree
        )
        missing_dir = seed_execute_waiting_task(
          dir,
          slug: "execute-missing-status-260426-aaab",
          reason: "missing_research_output"
        )

        out, _err = capture_io { Hive::Commands::Status.new(json: true).call }
        tasks = JSON.parse(out).dig("projects", 0, "tasks").to_h { |task| [ task["slug"], task ] }

        dirty_action = tasks.fetch("execute-dirty-status-260426-aaaa").fetch("next_action")
        assert_equal Hive::Schemas::NextActionKind::EDIT, dirty_action["kind"]
        assert_equal dirty_worktree, dirty_action["target"]
        assert_match(/uncommitted work/, dirty_action["instructions"])

        missing_action = tasks.fetch("execute-missing-status-260426-aaab").fetch("next_action")
        assert_equal Hive::Schemas::NextActionKind::RUN, missing_action["kind"]
        assert_equal missing_dir, missing_action["target"]
        assert_match(/structured final agent message/, missing_action["instructions"])
      end
    end
  end

  def test_run_json_emits_marker_and_next_action
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "json run probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

        # Fake claude writes a WAITING brainstorm.md so report() sees that marker.
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(brainstorm_dir, "brainstorm.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n### Q1.\n### A1.\n<!-- WAITING -->\n"

        out, _err = capture_io { Hive::Commands::Run.new(brainstorm_dir, json: true).call }
        assert_equal 1, out.lines.count, "JSON output must be a single line on stdout (no stray puts)"
        payload = JSON.parse(out)
        assert_equal "hive-run", payload["schema"]
        assert_equal 1, payload["schema_version"]
        assert_equal "brainstorm", payload["stage"]
        assert_equal 2, payload["stage_index"]
        assert_equal slug, payload["slug"]
        assert_equal "waiting", payload["marker"]

        next_action = payload["next_action"]
        refute_nil next_action
        assert_equal "edit", next_action["kind"]
        assert next_action["target"].end_with?("/brainstorm.md")
        assert_equal "hive brainstorm #{slug} --from 2-brainstorm", next_action["rerun_with"],
                     "workflow verbs must include --from for retry idempotency"
      end
    end
  end

  def test_run_json_on_complete_marker_returns_approve_next_action
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "json complete probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(brainstorm_dir, "brainstorm.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Requirements\n- foo\n<!-- COMPLETE -->\n"

        out, _err = capture_io { Hive::Commands::Run.new(brainstorm_dir, json: true).call }
        payload = JSON.parse(out)
        assert_equal "complete", payload["marker"]

        next_action = payload["next_action"]
        assert_equal Hive::Schemas::NextActionKind::APPROVE, next_action["kind"]
        assert_equal slug, next_action["slug"]
        assert_equal "2-brainstorm", next_action["from_stage"]
        assert_equal "3-plan", next_action["to_stage"]
        assert_equal "hive plan #{slug} --from 2-brainstorm", next_action["command"],
                     "workflow verbs must include --from for retry idempotency"
        # Back-compat fields kept for callers that parsed the old MV shape.
        assert next_action["to"].end_with?("3-plan/")
        assert_equal brainstorm_dir, next_action["from"]
      end
    end
  end

  def test_run_json_on_review_complete_marker_returns_approve_next_action
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "review-complete-260426-aaaa"
        review_dir = File.join(dir, ".hive-state", "stages", "5-review", slug)
        FileUtils.mkdir_p(review_dir)
        File.write(File.join(review_dir, "task.md"), "<!-- REVIEW_COMPLETE pass=1 browser=skipped -->\n")

        out, _err = capture_io { Hive::Commands::Run.new(review_dir, json: true).call }
        payload = JSON.parse(out)
        assert_equal "review_complete", payload["marker"]

        next_action = payload["next_action"]
        assert_equal Hive::Schemas::NextActionKind::APPROVE, next_action["kind"]
        assert_equal slug, next_action["slug"]
        assert_equal "5-review", next_action["from_stage"]
        assert_equal "6-pr", next_action["to_stage"]
        assert_equal "hive pr #{slug} --from 5-review", next_action["command"]
      end
    end
  end

  def test_run_json_on_execute_complete_marker_returns_review_approve_next_action
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "execute-complete-260426-aaaa"
        execute_dir = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(execute_dir)
        File.write(File.join(execute_dir, "plan.md"), "# Plan\n")
        File.write(File.join(execute_dir, "task.md"), "<!-- EXECUTE_COMPLETE -->\n")

        out, _err = capture_io { Hive::Commands::Run.new(execute_dir, json: true).call }
        assert_equal 1, out.lines.count, "JSON output must be a single line on stdout (no stray puts)"
        payload = JSON.parse(out)
        assert_equal "execute_complete", payload["marker"]

        next_action = payload["next_action"]
        assert_equal Hive::Schemas::NextActionKind::APPROVE, next_action["kind"]
        assert_equal slug, next_action["slug"]
        assert_equal "4-execute", next_action["from_stage"]
        assert_equal "5-review", next_action["to_stage"]
        assert_equal "hive review #{slug} --from 4-execute", next_action["command"]
      end
    end
  end

  def test_run_json_on_execute_waiting_dirty_worktree_targets_worktree
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "execute-dirty-260426-aaaa"
        execute_dir = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        worktree_path = File.join(dir, "worktree")
        FileUtils.mkdir_p(execute_dir)
        FileUtils.mkdir_p(worktree_path)
        File.write(File.join(execute_dir, "task.md"), "<!-- EXECUTE_WAITING reason=dirty_worktree -->\n")
        File.write(File.join(execute_dir, "worktree.yml"), {
          "path" => worktree_path,
          "branch" => slug
        }.to_yaml)

        require "hive/stages/execute"
        Hive::Stages::Execute.singleton_class.alias_method(:__orig_run!, :run!)
        Hive::Stages::Execute.define_singleton_method(:run!) { |_task, _cfg| { commit: nil, status: :execute_waiting } }

        begin
          out, _err, status = with_captured_exit { Hive::Commands::Run.new(execute_dir, json: true).call }
          assert_equal Hive::ExitCodes::SUCCESS, status

          payload = JSON.parse(out)
          assert_equal "execute_waiting", payload["marker"]
          next_action = payload["next_action"]
          assert_equal Hive::Schemas::NextActionKind::EDIT, next_action["kind"]
          assert_equal worktree_path, next_action["target"]
          assert_match(/uncommitted work/, next_action["instructions"])
        ensure
          Hive::Stages::Execute.singleton_class.alias_method(:run!, :__orig_run!)
          Hive::Stages::Execute.singleton_class.send(:remove_method, :__orig_run!)
        end
      end
    end
  end

  def test_run_json_on_execute_waiting_branch_integrity_targets_worktree
    %w[branch_mismatch head_not_descendant].each do |reason|
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir).call }
          slug = "execute-#{reason.tr('_', '-')}-260426-aaaa"
          worktree_path = File.join(dir, "worktree-#{reason}")
          FileUtils.mkdir_p(worktree_path)
          execute_dir = seed_execute_waiting_task(
            dir,
            slug: slug,
            reason: reason,
            worktree_path: worktree_path
          )

          with_execute_waiting_runner_stub do
            out, _err, status = with_captured_exit { Hive::Commands::Run.new(execute_dir, json: true).call }
            assert_equal Hive::ExitCodes::SUCCESS, status

            next_action = JSON.parse(out)["next_action"]
            assert_equal Hive::Schemas::NextActionKind::EDIT, next_action["kind"]
            assert_equal worktree_path, next_action["target"]
            assert_match(/expected task branch/, next_action["instructions"])
          end
        end
      end
    end
  end

  def test_run_json_on_execute_waiting_no_changes_points_to_plan
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "execute-no-change-260426-aaaa"
        execute_dir = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(execute_dir)
        File.write(File.join(execute_dir, "task.md"), "<!-- EXECUTE_WAITING reason=no_worktree_changes -->\n")
        File.write(File.join(execute_dir, "plan.md"), "# Plan\n")
        File.write(File.join(execute_dir, "worktree.yml"), {
          "path" => dir,
          "branch" => slug
        }.to_yaml)

        require "hive/stages/execute"
        Hive::Stages::Execute.singleton_class.alias_method(:__orig_run!, :run!)
        Hive::Stages::Execute.define_singleton_method(:run!) { |_task, _cfg| { commit: nil, status: :execute_waiting } }

        begin
          out, _err, status = with_captured_exit { Hive::Commands::Run.new(execute_dir, json: true).call }
          assert_equal Hive::ExitCodes::SUCCESS, status

          next_action = JSON.parse(out)["next_action"]
          assert_equal File.join(execute_dir, "plan.md"), next_action["target"]
          assert_match(/execution_mode: research/, next_action["instructions"])
        ensure
          Hive::Stages::Execute.singleton_class.alias_method(:run!, :__orig_run!)
          Hive::Stages::Execute.singleton_class.send(:remove_method, :__orig_run!)
        end
      end
    end
  end

  def test_run_json_on_execute_waiting_missing_research_output_reruns_agent
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "execute-missing-research-260426-aaaa"
        execute_dir = seed_execute_waiting_task(
          dir,
          slug: slug,
          reason: "missing_research_output"
        )

        with_execute_waiting_runner_stub do
          out, _err, status = with_captured_exit { Hive::Commands::Run.new(execute_dir, json: true).call }
          assert_equal Hive::ExitCodes::SUCCESS, status

          next_action = JSON.parse(out)["next_action"]
          assert_equal Hive::Schemas::NextActionKind::RUN, next_action["kind"]
          assert_equal execute_dir, next_action["target"]
          assert_match(/structured final agent message/, next_action["instructions"])
          assert_equal "hive develop #{slug} --from 4-execute", next_action["rerun_with"]
        end
      end
    end
  end

  # Pin the JSON-mode :error contract: a dual signal where the JSON document
  # carries the marker + attrs AND the process exits with TASK_IN_ERROR (3).
  # A future refactor that drops the post-puts raise (or wraps it in a
  # rescue) would silently regress to exit 0; this test catches that.
  def test_run_json_on_error_marker_emits_no_op_and_exits_three
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        capture_io { Hive::Commands::New.new(File.basename(dir), "json error probe").call }
        slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
        brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm_dir))
        FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

        ENV["HIVE_FAKE_CLAUDE_EXIT"] = "1" # forces Agent#handle_exit to set :error

        out, _err, status = with_captured_exit { Hive::Commands::Run.new(brainstorm_dir, json: true).call }
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status,
                     "JSON mode must still exit 3 on :error (the JSON document is emitted before the raise)"

        payload = JSON.parse(out)
        assert_equal "error", payload["marker"]
        assert_equal Hive::Schemas::NextActionKind::NO_OP, payload["next_action"]["kind"]
        assert_equal "exit_code", payload["attrs"]["reason"]
        assert_equal "exit_code", payload["next_action"]["error"]["reason"]
      end
    end
  end

  # ── REVIEW_* next_action coverage ────────────────────────────────────────

  def test_run_json_on_review_waiting_marker_emits_edit_next_action
    # Stub Hive::Stages::Review.run! to a no-op so the seeded
    # REVIEW_WAITING marker survives unchanged into report_json. The
    # contract under test is the next_action mapping, not the runner's
    # ability to reach review_waiting from scratch.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "review-waiting-260426-aaaa"
        review_dir = File.join(dir, ".hive-state", "stages", "5-review", slug)
        FileUtils.mkdir_p(review_dir)
        File.write(File.join(review_dir, "task.md"),
                   "<!-- REVIEW_WAITING escalations=2 pass=1 -->\n")

        require "hive/stages/review"
        Hive::Stages::Review.singleton_class.alias_method(:__orig_run!, :run!)
        Hive::Stages::Review.define_singleton_method(:run!) { |_task, _cfg| { commit: nil, status: :review_waiting } }

        begin
          out, _err, status = with_captured_exit { Hive::Commands::Run.new(review_dir, json: true).call }
          assert_equal Hive::ExitCodes::SUCCESS, status,
                       "review_waiting is a soft pause, not an error — exit 0"

          payload = JSON.parse(out)
          assert_equal "review_waiting", payload["marker"]
          next_action = payload["next_action"]
          assert_equal Hive::Schemas::NextActionKind::EDIT, next_action["kind"]
          assert_equal review_dir, next_action["target"],
                       "edit-target is the task folder for review_waiting"
          assert_match(/hive run/, next_action["rerun_with"],
                       "rerun_with must surface a `hive run` command")
        ensure
          Hive::Stages::Review.singleton_class.alias_method(:run!, :__orig_run!)
          Hive::Stages::Review.singleton_class.send(:remove_method, :__orig_run!)
        end
      end
    end
  end

  def test_run_json_on_review_stale_marker_emits_recover_stale_next_action
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "review-stale-260426-aaaa"
        review_dir = File.join(dir, ".hive-state", "stages", "5-review", slug)
        FileUtils.mkdir_p(review_dir)
        File.write(File.join(review_dir, "task.md"),
                   "<!-- REVIEW_STALE pass=4 -->\n")

        out, _err, _status = with_captured_exit { Hive::Commands::Run.new(review_dir, json: true).call }
        payload = JSON.parse(out)
        assert_equal "review_stale", payload["marker"]
        next_action = payload["next_action"]
        assert_equal Hive::Schemas::NextActionKind::RECOVER_STALE, next_action["kind"]
        assert_equal [ "review_stale" ], next_action["markers_to_clear"]
        refute_empty next_action["instructions"].to_s,
                     "instructions must be non-empty so an agent / human knows how to recover"
      end
    end
  end

  def test_run_json_on_review_ci_stale_marker_emits_recover_stale_next_action
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "review-ci-stale-260426-aaaa"
        review_dir = File.join(dir, ".hive-state", "stages", "5-review", slug)
        FileUtils.mkdir_p(review_dir)
        File.write(File.join(review_dir, "task.md"),
                   "<!-- REVIEW_CI_STALE attempts=3 -->\n")

        out, _err, _status = with_captured_exit { Hive::Commands::Run.new(review_dir, json: true).call }
        payload = JSON.parse(out)
        assert_equal "review_ci_stale", payload["marker"]
        next_action = payload["next_action"]
        assert_equal Hive::Schemas::NextActionKind::RECOVER_STALE, next_action["kind"]
        assert_equal [ "review_ci_stale" ], next_action["markers_to_clear"]
      end
    end
  end

  # Defensive pin: every emitted next_action.kind must be in the closed
  # NextActionKind::ALL set. Drives THREE distinct producer arms (waiting,
  # complete, error) so a typo in any one of them is caught — the round-1
  # version of this test only exercised :waiting.
  def test_every_emitted_next_action_kind_is_in_the_closed_enum
    fixtures = [
      { content: "## Round 1\n<!-- WAITING -->\n",
        env: {},
        expected_kind: Hive::Schemas::NextActionKind::EDIT },
      { content: "## Requirements\n- foo\n<!-- COMPLETE -->\n",
        env: {},
        expected_kind: Hive::Schemas::NextActionKind::APPROVE },
      { content: nil,                       # exit 1 → :error marker
        env: { "HIVE_FAKE_CLAUDE_EXIT" => "1" },
        expected_kind: Hive::Schemas::NextActionKind::NO_OP }
    ]

    fixtures.each_with_index do |fixture, i|
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          capture_io { Hive::Commands::Init.new(dir).call }
          capture_io { Hive::Commands::New.new(File.basename(dir), "kind probe #{i}").call }
          slug = File.basename(Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first)
          brainstorm_dir = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
          FileUtils.mkdir_p(File.dirname(brainstorm_dir))
          FileUtils.mv(File.join(dir, ".hive-state", "stages", "1-inbox", slug), brainstorm_dir)

          fixture[:env].each { |k, v| ENV[k] = v }
          if fixture[:content]
            ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(brainstorm_dir, "brainstorm.md")
            ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = fixture[:content]
          end

          out, _err, _status = with_captured_exit do
            Hive::Commands::Run.new(brainstorm_dir, json: true).call
          end
          payload = JSON.parse(out)
          kind = payload["next_action"]["kind"]
          assert_includes Hive::Schemas::NextActionKind::ALL, kind,
                          "fixture #{i}: kind=#{kind.inspect} is outside the closed NextActionKind enum"
          assert_equal fixture[:expected_kind], kind,
                       "fixture #{i}: producer arm emitted unexpected kind"
        end
      end
    end
  end
end
