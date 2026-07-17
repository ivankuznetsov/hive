require "test_helper"
require "hive/commands/init"
require "hive/commands/new"
require "hive/commands/stage_action"

class RunStageActionTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    @prev_codex_bin = ENV["HIVE_CODEX_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    ENV["HIVE_CODEX_BIN"] = FAKE_BIN
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    ENV["HIVE_CODEX_BIN"] = @prev_codex_bin
    %w[
      HIVE_FAKE_CLAUDE_WRITE_FILE
      HIVE_FAKE_CLAUDE_WRITE_CONTENT
      HIVE_FAKE_CLAUDE_COMMIT_FILE
      HIVE_FAKE_CLAUDE_COMMIT_CONTENT
      HIVE_FAKE_CLAUDE_COMMIT_MESSAGE
    ].each { |k| ENV.delete(k) }
  end

  def seed_inbox(dir, text = "stage action probe")
    capture_io do
      Hive::Commands::Init.new(dir).call
      set_project_claude_mode(dir, "headless")
      Hive::Commands::New.new(File.basename(dir), text).call
    end
    inbox = Dir[File.join(dir, ".hive-state", "stages", "1-inbox", "*")].first
    [ inbox, File.basename(inbox) ]
  end

  def with_fake_gh_state(state)
    Dir.mktmpdir do |dir|
      gh = File.join(dir, "gh")
      File.write(gh, <<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        abort "unexpected gh argv: \#{ARGV.inspect}" unless ARGV == %w[pr view https://github.com/example/repo/pull/42 --json state]
        puts JSON.generate("state" => #{state.inspect})
      RUBY
      FileUtils.chmod(0o755, gh)
      with_env("PATH" => "#{dir}:#{ENV.fetch('PATH', '')}") { yield }
    end
  end

  def write_merged_finalization(folder, slug)
    coordinates = {
      "job_id" => "job-1", "repository" => "github.com/example/repo", "pr_number" => 42,
      "pr_url" => "https://github.com/example/repo/pull/42", "head_sha" => "a" * 40,
      "head_generation" => 1, "finalize_attempt_id" => "attempt-1"
    }
    base = {
      occurred_at: "2026-07-17T17:00:00.000000Z", observed_at: "2026-07-17T17:00:00.000000Z",
      task: { "id" => "42", "slug" => slug }, workflow: "coding", stage: "8-finalize",
      attempt_id: "attempt-1", task_generation: 1, ownership_generation: "owner-1",
      evidence: [], provenance: { "source" => "test" }
    }
    events = [
      Hive::TaskJournal::Envelope.authoritative(base.merge(
        event_type: "finalized", event_id: "finalized", reason: "handoff",
        producer: { "kind" => "finalize_attempt", "attempt_id" => "attempt-1" }, payload: coordinates
      )),
      Hive::TaskJournal::Envelope.authoritative(base.merge(
        event_type: "merged", event_id: "merged", reason: "merged",
        producer: { "kind" => "babysitter_job", "job_id" => "job-1", "claim_fence" => 1 },
        payload: coordinates.merge("merged_at" => "2026-07-17T17:00:00Z")
      ))
    ]
    File.write(File.join(folder, "events.jsonl"), events.map { |event| JSON.generate(event) }.join("\n") + "\n")
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

  def test_from_resolves_stage_but_admission_holds_duplicate_slug_identity
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

        _, err, status = with_captured_exit do
          Hive::Commands::StageAction.new("plan", slug, from: "plan").call
        end

        assert_equal Hive::ExitCodes::CONFIG, status
        assert_includes err, "dependency_validation_failed"
        assert File.directory?(brainstorm), "existing brainstorm task must not move"
        assert_equal :waiting, Hive::Markers.current(File.join(plan, "plan.md")).name
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
        done = File.join(dir, ".hive-state", "stages", "9-done", slug)
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
        done = File.join(dir, ".hive-state", "stages", "9-done", slug)
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

  def test_archive_rejects_live_github_merged_error_recovery_shortcut
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        finalize = File.join(dir, ".hive-state", "stages", "8-finalize", slug)
        FileUtils.mkdir_p(File.dirname(finalize))
        FileUtils.mv(inbox, finalize)
        File.write(File.join(finalize, "pr.md"), <<~MD)
          ---
          pr_url: https://github.com/example/repo/pull/42
          ---

          <!-- ERROR reason=git_status_failed -->
        MD

        _out, err, status = with_fake_gh_state("MERGED") do
          with_captured_exit do
            Hive::Commands::StageAction.new("archive", slug).call
          end
        end

        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_includes err, "archive_ready"
        assert File.directory?(finalize)
      end
    end
  end

  def test_archive_rejects_mismatched_merged_error_recovery_reason
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        finalize = File.join(dir, ".hive-state", "stages", "8-finalize", slug)
        FileUtils.mkdir_p(File.dirname(finalize))
        FileUtils.mv(inbox, finalize)
        File.write(File.join(finalize, "pr.md"), <<~MD)
          ---
          pr_url: https://github.com/example/repo/pull/42
          ---

          <!-- ERROR reason=git_status_failed -->
        MD

        _out, err, status = with_captured_exit do
          Hive::Commands::StageAction.new("archive", slug).call
        end

        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_includes err, "archive_ready"
        assert File.directory?(finalize)
      end
    end
  end

  def test_archive_rejects_matching_recovery_reason_when_pr_is_open
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        finalize = File.join(dir, ".hive-state", "stages", "8-finalize", slug)
        FileUtils.mkdir_p(File.dirname(finalize))
        FileUtils.mv(inbox, finalize)
        File.write(File.join(finalize, "pr.md"), <<~MD)
          ---
          pr_url: https://github.com/example/repo/pull/42
          ---

          <!-- ERROR reason=git_status_failed -->
        MD

        out = err = nil
        status = nil
        with_fake_gh_state("OPEN") do
          out, err, status = with_captured_exit do
            Hive::Commands::StageAction.new("archive", slug).call
          end
        end

        assert_equal Hive::ExitCodes::WRONG_STAGE, status
        assert_empty out
        assert_includes err, "archive_ready"
        assert File.directory?(finalize)
      end
    end
  end

  def test_archive_reconciles_current_merged_journal_evidence_without_github
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        finalize = File.join(dir, ".hive-state", "stages", "8-finalize", slug)
        FileUtils.mkdir_p(File.dirname(finalize))
        FileUtils.mv(inbox, finalize)
        File.write(File.join(finalize, "pr.md"), <<~MD)
          ---
          pr_url: https://github.com/example/repo/pull/42
          ---

          <!-- COMPLETE pr_url=https://github.com/example/repo/pull/42 is_draft=false -->
        MD
        write_merged_finalization(finalize, slug)

        capture_io { Hive::Commands::StageAction.new("archive", slug).call }

        done = File.join(dir, ".hive-state", "stages", "9-done", slug)
        assert File.directory?(done)
        records = Hive::TaskProjection.read_journal(File.join(done, "events.jsonl"))
        assert_equal 1, records.count { |record| record["event_type"] == "archive_ready" }
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
        assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-stage-action"), payload["schema_version"]
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

  # ── develop / open-pr / review verbs ──────────────────────────────────

  def test_open_pr_moves_execute_complete_to_open_pr_and_runs
    # `hive open-pr <slug>` advances a 4-execute task with the
    # EXECUTE_COMPLETE terminal marker into 5-open-pr and enters the
    # open-pr runner.
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        execute = File.join(dir, ".hive-state", "stages", "4-execute", slug)
        FileUtils.mkdir_p(File.dirname(execute))
        FileUtils.mv(inbox, execute)
        File.write(File.join(execute, "plan.md"), "# Plan\n<!-- COMPLETE -->\n")
        File.write(File.join(execute, "task.md"), "# task\n<!-- EXECUTE_COMPLETE -->\n")
        open_pr = File.join(dir, ".hive-state", "stages", "5-open-pr", slug)

        out, err, status = with_captured_exit do
          Hive::Commands::StageAction.new("open-pr", slug).call
        end

        assert File.directory?(open_pr), "open-pr must promote 4-execute → 5-open-pr"
        refute File.directory?(execute), "source 4-execute folder must be gone after promote"

        # The 5-open-pr runner needs a worktree.yml to make progress;
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

  def test_review_moves_open_pr_complete_to_review_and_runs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        open_pr = File.join(dir, ".hive-state", "stages", "5-open-pr", slug)
        FileUtils.mkdir_p(File.dirname(open_pr))
        FileUtils.mv(inbox, open_pr)
        File.write(File.join(open_pr, "task.md"), "# task\n")
        File.write(File.join(open_pr, "pr.md"), <<~MD)
          ---
          pr_url: https://example.com/pr/42
          ---
          <!-- COMPLETE pr_url=https://example.com/pr/42 is_draft=true -->
        MD
        review = File.join(dir, ".hive-state", "stages", "6-review", slug)

        out, err, status = with_captured_exit do
          Hive::Commands::StageAction.new("review", slug).call
        end

        assert File.directory?(review), "review must promote 5-open-pr → 6-review"
        refute File.directory?(open_pr), "source 5-open-pr folder must be gone after promote"
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

  def test_artifacts_moves_review_complete_to_artifacts_and_runs
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        review = File.join(dir, ".hive-state", "stages", "6-review", slug)
        FileUtils.mkdir_p(File.dirname(review))
        FileUtils.mv(inbox, review)
        File.write(File.join(review, "task.md"), "# task\n<!-- REVIEW_COMPLETE pass=1 browser=skipped -->\n")
        artifacts = File.join(dir, ".hive-state", "stages", "7-artifacts", slug)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(artifacts, "artifact.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "# Artifacts\nNo extra artifacts.\n<!-- COMPLETE -->\n"

        capture_io { Hive::Commands::StageAction.new("artifacts", slug).call }

        assert File.directory?(artifacts), "artifacts must promote 6-review -> 7-artifacts"
        refute File.directory?(review), "source 6-review folder must be gone after promote"
        assert_equal :complete, Hive::Markers.current(File.join(artifacts, "artifact.md")).name
      end
    end
  end

  def test_artifacts_at_target_marks_markerless_artifact_complete
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        inbox, slug = seed_inbox(dir)
        artifacts = File.join(dir, ".hive-state", "stages", "7-artifacts", slug)
        FileUtils.mkdir_p(File.dirname(artifacts))
        FileUtils.mv(inbox, artifacts)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(artifacts, "artifact.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "# Artifacts\nNo extra artifacts.\n<!-- COMPLETE -->\n"

        capture_io { Hive::Commands::StageAction.new("artifacts", slug, from: "7-artifacts").call }

        assert_equal :complete, Hive::Markers.current(File.join(artifacts, "artifact.md")).name
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
