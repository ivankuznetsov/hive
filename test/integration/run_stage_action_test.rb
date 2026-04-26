require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/stage_action"

class RunStageActionTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT].each { |k| ENV.delete(k) }
  end

  def seed_inbox(dir, text = "stage action probe")
    capture_io do
      Hive::Commands::Init.new(dir).call
      Hive::Commands::New.new(File.basename(dir), text).call
    end
    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    [ inbox, File.basename(inbox) ]
  end

  def test_brainstorm_moves_inbox_to_brainstorm_and_runs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        _inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(brainstorm, "brainstorm.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Round 1\n<!-- WAITING -->\n"

        capture_io { Hive::Commands::StageAction.new("brainstorm", slug).call }

        assert File.directory?(brainstorm)
        assert_equal :waiting, Hive::Markers.current(File.join(brainstorm, "brainstorm.md")).name
      end
    end
  end

  def test_plan_moves_complete_brainstorm_to_plan_and_runs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "## Requirements\n<!-- COMPLETE -->\n")
        plan = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(plan, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Plan\n<!-- COMPLETE -->\n"

        capture_io { Hive::Commands::StageAction.new("plan", slug).call }

        assert File.directory?(plan)
        assert_equal :complete, Hive::Markers.current(File.join(plan, "plan.md")).name
      end
    end
  end

  def test_plan_refuses_waiting_brainstorm
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "## Round 1\n<!-- WAITING -->\n")

        _out, err, status = with_captured_exit { Hive::Commands::StageAction.new("plan", slug).call }

        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_includes err, "finish the current stage first"
      end
    end
  end

  def test_from_disambiguates_same_slug_stage_collision
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        plan = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(brainstorm)
        FileUtils.mkdir_p(plan)
        FileUtils.rm_rf(inbox)
        File.write(File.join(brainstorm, "brainstorm.md"), "## Requirements\n<!-- COMPLETE -->\n")
        File.write(File.join(plan, "plan.md"), "## Existing\n<!-- WAITING -->\n")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(plan, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Updated\n<!-- COMPLETE -->\n"

        capture_io { Hive::Commands::StageAction.new("plan", slug, from: "plan").call }

        assert File.directory?(brainstorm), "existing brainstorm task must not move"
        assert_equal :complete, Hive::Markers.current(File.join(plan, "plan.md")).name
      end
    end
  end

  # ── --from retry-after-success idempotency ─────────────────────────────

  def test_from_retry_after_success_raises_wrong_stage_not_invalid_path
    # `hive plan slug --from 2-brainstorm` succeeds → task at 3-plan.
    # A retry with the same --from must surface WRONG_STAGE (4), not
    # "no task folder" (64). Mirror Approve's idempotency rescue.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "## Requirements\n<!-- COMPLETE -->\n")
        plan = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(plan, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Plan\n<!-- WAITING -->\n"

        capture_io { Hive::Commands::StageAction.new("plan", slug, from: "2-brainstorm").call }
        assert File.directory?(plan)

        _out, err, status = with_captured_exit do
          Hive::Commands::StageAction.new("plan", slug, from: "2-brainstorm").call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status,
                     "retry must surface WRONG_STAGE (4), not InvalidTaskPath (64)"
        assert_includes err, "is at 3-plan but --from expected 2-brainstorm"
      end
    end
  end

  # ── archive idempotency ────────────────────────────────────────────────

  def test_archive_on_already_archived_task_is_noop
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        done = File.join(dir, ".hive-state", "stages", "7-done", slug)
        FileUtils.mkdir_p(File.dirname(done))
        FileUtils.mv(inbox, done)
        # task.md is the state file for done stage.
        File.write(File.join(done, "task.md"), "## archived\n<!-- COMPLETE -->\n")

        log_before = `git -C #{File.join(dir, ".hive-state")} log --oneline`.lines.size

        out, _err = capture_io { Hive::Commands::StageAction.new("archive", slug).call }
        assert_includes out, "noop"

        log_after = `git -C #{File.join(dir, ".hive-state")} log --oneline`.lines.size
        assert_equal log_before, log_after,
                     "archive on an already-archived task must not write a new commit"
      end
    end
  end

  def test_archive_noop_in_json_emits_phase_noop
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        done = File.join(dir, ".hive-state", "stages", "7-done", slug)
        FileUtils.mkdir_p(File.dirname(done))
        FileUtils.mv(inbox, done)
        File.write(File.join(done, "task.md"), "## archived\n<!-- COMPLETE -->\n")

        out, _err = capture_io { Hive::Commands::StageAction.new("archive", slug, json: true).call }
        payload = JSON.parse(out)
        assert_equal "hive-stage-action", payload["schema"]
        assert_equal "archive", payload["verb"]
        assert_equal "noop", payload["phase"]
        assert payload["noop"]
        assert_equal "already_archived", payload["reason"]
      end
    end
  end

  # ── JSON envelope error path ───────────────────────────────────────────

  def test_json_error_envelope_on_wrong_stage_under_json_mode
    # Workflow verbs in --json mode must emit a structured error
    # envelope on failure, not bare stderr text or mixed prose+JSON.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "## Round 1\n<!-- WAITING -->\n")

        out, _err, status = with_captured_exit do
          Hive::Commands::StageAction.new("plan", slug, json: true).call
        end
        assert_equal Hive::ExitCodes::WRONG_STAGE, status

        payload = JSON.parse(out)
        assert_equal "hive-stage-action", payload["schema"]
        assert_equal 1, payload["schema_version"]
        assert_equal false, payload["ok"]
        assert_equal "plan", payload["verb"]
        assert_equal "wrong_stage", payload["error_kind"]
        assert_equal Hive::ExitCodes::WRONG_STAGE, payload["exit_code"]
      end
    end
  end

  def test_json_success_envelope_promoted_and_ran_phase
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        brainstorm = File.join(dir, ".hive-state", "stages", "2-brainstorm", slug)
        FileUtils.mkdir_p(File.dirname(brainstorm))
        FileUtils.mv(inbox, brainstorm)
        File.write(File.join(brainstorm, "brainstorm.md"), "## Requirements\n<!-- COMPLETE -->\n")
        plan = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(plan, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Plan\n<!-- WAITING -->\n"

        out, _err = capture_io { Hive::Commands::StageAction.new("plan", slug, json: true).call }

        # Single parseable JSON document — no Approve prose mixed in.
        assert_equal 1, out.lines.count, "JSON output must be a single line"
        payload = JSON.parse(out)

        assert_equal "hive-stage-action", payload["schema"]
        assert_equal "plan", payload["verb"]
        assert_equal "promoted_and_ran", payload["phase"]
        refute payload["noop"]
        assert_equal "2-brainstorm", payload["from_stage_dir"]
        assert_equal "3-plan", payload["to_stage_dir"]
        assert_equal "waiting", payload["marker_after"]
        assert_equal "needs_input", payload["next_action"]["key"]
      end
    end
  end

  def test_json_success_envelope_at_target_phase_ran
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        plan = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(plan))
        FileUtils.mv(inbox, plan)
        File.write(File.join(plan, "plan.md"), "## Plan\n<!-- WAITING -->\n")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(plan, "plan.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "## Plan\n<!-- COMPLETE -->\n"

        out, _err = capture_io { Hive::Commands::StageAction.new("plan", slug, json: true).call }
        payload = JSON.parse(out)
        assert_equal "ran", payload["phase"], "task already at target → run-only branch"
        assert_equal "3-plan", payload["to_stage_dir"]
        assert_equal "ready_to_develop", payload["next_action"]["key"]
      end
    end
  end

  # ── develop / pr verbs ─────────────────────────────────────────────────

  def test_review_moves_execute_complete_to_review_and_runs
    # The new `hive review <slug>` workflow verb advances a 4-execute
    # task with the EXECUTE_COMPLETE terminal marker into 5-review and
    # runs the review-stage agent. The integration check is "did the
    # move happen and did the runner reach 5-review", regardless of
    # whether the (heavy) review loop finished cleanly in the test
    # sandbox.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        execute = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(File.dirname(execute))
        FileUtils.mv(inbox, execute)
        File.write(File.join(execute, "plan.md"), "# Plan\n<!-- COMPLETE -->\n")
        File.write(File.join(execute, "task.md"), "# task\n<!-- EXECUTE_COMPLETE -->\n")
        review = File.join(dir, ".hive-state", "stages", "5-review", slug)

        out, err, status = with_captured_exit do
          Hive::Commands::StageAction.new("review", slug).call
        end

        assert File.directory?(review), "review must promote 4-execute → 5-review"
        refute File.directory?(execute), "source 4-execute folder must be gone after promote"

        # The 5-review runner needs a worktree.yml to make progress;
        # since we didn't seed one (the test focuses on the move +
        # entry into the runner), the runner exits 1 in pre-flight.
        # Allow that exit alongside successful completions so the test
        # is robust to runner internals shifting.
        assert_includes [
          Hive::ExitCodes::SUCCESS,
          Hive::ExitCodes::GENERIC,
          Hive::ExitCodes::SOFTWARE,
          Hive::ExitCodes::TASK_IN_ERROR
        ], status,
                        "exit must be 0/1/3/70 depending on runner outcome; got #{status}, err=#{err.inspect}, out=#{out.inspect}"
      end
    end
  end

  def test_develop_moves_complete_plan_to_execute_and_runs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        plan = File.join(dir, ".hive-state", "stages", "3-plan", slug)
        FileUtils.mkdir_p(File.dirname(plan))
        FileUtils.mv(inbox, plan)
        File.write(File.join(plan, "plan.md"), "## Plan\n<!-- COMPLETE -->\n")
        execute = File.join(dir, ".hive-state", "stages", "4-execute", slug)

        # Execute stage initialises task.md and spawns implementer +
        # reviewer agents — heavier path than brainstorm/plan. The
        # fixture writes nothing; Execute's own initialisation handles
        # task.md creation. The integration check is "did the move
        # happen" rather than "did the agent finish a full round".
        out, err, status = with_captured_exit do
          Hive::Commands::StageAction.new("develop", slug).call
        end

        # Allow either success (full implementer round completed) OR
        # SOFTWARE-class exit if the fake-claude harness can't fully
        # play through Execute's worktree machinery in the test sandbox.
        # The contract under test is: the move happened and the task
        # is at 4-execute, regardless of agent outcome.
        assert File.directory?(execute), "develop must promote 3-plan → 4-execute"
        assert_includes [ Hive::ExitCodes::SUCCESS, Hive::ExitCodes::SOFTWARE,
                          Hive::ExitCodes::TASK_IN_ERROR ], status,
                        "exit must be 0/3/70 depending on whether agent fully completed; got #{status}, err=#{err.inspect}, out=#{out.inspect}"
      end
    end
  end
end
