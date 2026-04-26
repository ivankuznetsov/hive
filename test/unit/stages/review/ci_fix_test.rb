require "test_helper"
require "hive/stages/review/ci_fix"
require "hive/reviewers"
require "hive/agent_profiles"

# Direct coverage for the CI-fix loop. Uses tiny bash scripts as the
# CI command (deterministic exit codes, optional output) and fake-claude
# for the fix agent (writes a marker file that flips the next CI run
# to green).
class CiFixTest < Minitest::Test
  include HiveTestHelper

  FAKE_BIN = File.expand_path("../../../fixtures/fake-claude", __dir__)

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_BIN
    Hive::AgentProfile.reset_version_cache!
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    %w[HIVE_FAKE_CLAUDE_OUTPUT HIVE_FAKE_CLAUDE_EXIT
       HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
       HIVE_FAKE_CLAUDE_LOG_DIR].each { |k| ENV.delete(k) }
    Hive::AgentProfile.reset_version_cache!
  end

  def with_ci_dir
    with_tmp_dir do |dir|
      task_folder = File.join(dir, ".hive-state", "stages", "5-review", "ci-test-task")
      FileUtils.mkdir_p(File.join(task_folder, "reviews"))
      FileUtils.mkdir_p(File.join(task_folder, "logs"))
      yield(dir, task_folder)
    end
  end

  def make_ctx(worktree, task_folder, pass: 1)
    Hive::Reviewers::Context.new(
      worktree_path: worktree,
      task_folder: task_folder,
      default_branch: "main",
      pass: pass
    )
  end

  def write_ci_script(dir, body, name: "fake-ci")
    path = File.join(dir, name)
    File.write(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def cfg_with(command, overrides = {})
    base = {
      "review" => {
        "ci" => {
          "command" => command,
          "max_attempts" => 3,
          "agent" => "claude",
          "prompt_template" => "ci_fix_prompt.md.erb"
        }
      },
      "budget_usd" => { "review_ci" => 5 },
      "timeout_sec" => { "review_ci" => 5 }
    }
    deep_merge(base, overrides)
  end

  def deep_merge(base, over)
    base.merge(over) do |_k, b, o|
      b.is_a?(Hash) && o.is_a?(Hash) ? deep_merge(b, o) : o
    end
  end

  # --- skipped ----------------------------------------------------------

  def test_returns_skipped_when_command_is_nil
    with_ci_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      result = Hive::Stages::Review::CiFix.run!(cfg: cfg_with(nil), ctx: ctx)

      assert_equal :skipped, result.status
      assert_equal 0, result.attempts
      assert_nil result.last_output
    end
  end

  def test_returns_skipped_when_command_is_empty_string
    with_ci_dir do |dir, task_folder|
      ctx = make_ctx(dir, task_folder)
      result = Hive::Stages::Review::CiFix.run!(cfg: cfg_with("   "), ctx: ctx)

      assert_equal :skipped, result.status
    end
  end

  # --- green on first attempt ------------------------------------------

  def test_returns_green_when_ci_succeeds_first_attempt
    with_ci_dir do |dir, task_folder|
      ci = write_ci_script(dir, %(echo "all green"; exit 0))
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir

      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg_with(ci),
        ctx: make_ctx(dir, task_folder)
      )

      assert_equal :green, result.status
      assert_equal 1, result.attempts
      assert_includes result.last_output, "all green"

      # No fix-agent spawn happened (fake-claude only logs argv when invoked).
      argv_log = File.join(log_dir, "fake-claude-argv.log")
      refute File.exist?(argv_log), "fix agent must not be spawned when CI is green on attempt 1"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # --- green after fix --------------------------------------------------

  def test_returns_green_after_fix_agent_recovers_failing_ci
    with_ci_dir do |dir, task_folder|
      marker = File.join(dir, ".ci-fixed")
      ci = write_ci_script(dir, <<~SH.strip)
        if [ -f "#{marker}" ]; then
          echo "passing now"
          exit 0
        else
          echo "tests failed: missing #{marker}" >&2
          exit 1
        fi
      SH

      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = marker
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "fix landed\n"

      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg_with(ci),
        ctx: make_ctx(dir, task_folder)
      )

      assert_equal :green, result.status
      assert_equal 2, result.attempts, "CI should be green on the second attempt after the fix agent runs"
      assert File.exist?(marker), "fix agent should have created the marker file"
    end
  end

  def test_returns_error_when_fix_agent_leaves_uncommitted_changes
    with_tmp_dir do |task_root|
      with_tmp_git_repo do |worktree|
        task_folder = File.join(task_root, ".hive-state", "stages", "5-review", "ci-dirty")
        FileUtils.mkdir_p(File.join(task_folder, "reviews"))
        File.write(File.join(task_folder, "task.md"), "<!-- REVIEW_WORKING phase=ci pass=1 -->\n")
        File.write(File.join(task_folder, "plan.md"), "plan\n")
        File.write(File.join(task_folder, "worktree.yml"), { "path" => worktree }.to_yaml)

        dirty_file = File.join(worktree, "dirty.txt")
        ci = write_ci_script(task_root, "echo fail >&2\nexit 1")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = dirty_file
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "uncommitted\n"

        result = Hive::Stages::Review::CiFix.run!(
          cfg: cfg_with(ci),
          ctx: make_ctx(worktree, task_folder)
        )

        assert_equal :error, result.status
        assert_match(/uncommitted worktree changes/, result.error_message)
      end
    end
  end

  def test_returns_error_when_fix_agent_tampers_with_protected_task_files
    with_tmp_dir do |task_root|
      with_tmp_git_repo do |worktree|
        task_folder = File.join(task_root, ".hive-state", "stages", "5-review", "ci-tamper")
        FileUtils.mkdir_p(File.join(task_folder, "reviews"))
        task_md = File.join(task_folder, "task.md")
        File.write(task_md, "<!-- REVIEW_WORKING phase=ci pass=1 -->\n")
        File.write(File.join(task_folder, "plan.md"), "plan\n")
        File.write(File.join(task_folder, "worktree.yml"), { "path" => worktree }.to_yaml)

        ci = write_ci_script(task_root, "echo fail >&2\nexit 1")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = task_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "<!-- REVIEW_COMPLETE -->\n"

        result = Hive::Stages::Review::CiFix.run!(
          cfg: cfg_with(ci),
          ctx: make_ctx(worktree, task_folder)
        )

        assert_equal :error, result.status
        assert_match(/protected files/, result.error_message)
        assert_match(/task\.md/, result.error_message)
      end
    end
  end

  # --- capped → :stale --------------------------------------------------

  def test_returns_stale_when_max_attempts_reached
    with_ci_dir do |dir, task_folder|
      ci = write_ci_script(dir, %(echo "always fails" >&2; exit 7))
      cfg = cfg_with(ci, "review" => { "ci" => { "max_attempts" => 2 } })

      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg,
        ctx: make_ctx(dir, task_folder)
      )

      assert_equal :stale, result.status
      assert_equal 2, result.attempts
      assert_includes result.last_output, "always fails"
    end
  end

  # --- command not found ------------------------------------------------

  def test_returns_error_when_ci_command_does_not_exist
    with_ci_dir do |dir, task_folder|
      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg_with([ "/nonexistent/bin/ci" ]),
        ctx: make_ctx(dir, task_folder)
      )

      assert_equal :error, result.status
      assert_match(/not runnable/, result.error_message)
    end
  end

  # --- output cleaning --------------------------------------------------

  def test_ansi_color_codes_stripped_from_captured_output
    with_ci_dir do |dir, task_folder|
      # Emit ANSI red text + "FAILED" then exit 1
      ci = write_ci_script(dir, <<~SH.strip)
        printf '\\033[31m\\033[1mtest FAILED\\033[0m\\n'
        exit 1
      SH

      cfg = cfg_with(ci, "review" => { "ci" => { "max_attempts" => 1 } })
      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg,
        ctx: make_ctx(dir, task_folder)
      )

      assert_equal :stale, result.status
      assert_includes result.last_output, "test FAILED"
      refute_includes result.last_output, "\e[", "ANSI escape sequences must be stripped"
      refute_includes result.last_output, "\033[", "ANSI escape sequences must be stripped (octal form)"
    end
  end

  def test_long_output_is_tail_truncated
    with_ci_dir do |dir, task_folder|
      # Emit 1000 lines of output, fail.
      ci = write_ci_script(dir, <<~SH.strip)
        for i in $(seq 1 1000); do echo "line $i"; done
        exit 1
      SH

      cfg = cfg_with(ci,
                     "review" => { "ci" => { "max_attempts" => 1, "tail_lines" => 50 } })
      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg,
        ctx: make_ctx(dir, task_folder)
      )

      assert_equal :stale, result.status
      lines = result.last_output.lines
      # Truncation header + 50 trailing lines.
      assert_operator lines.size, :<=, 51,
                      "tail_lines=50 must keep at most 51 lines (header + 50)"
      assert_match(/950 earlier lines truncated/, result.last_output)
      assert_includes result.last_output, "line 1000", "must keep the most recent line"
      refute_includes result.last_output, "line 1\n", "must drop early lines"
    end
  end

  # --- mixed stdout + stderr capture ------------------------------------

  def test_captures_both_stdout_and_stderr
    with_ci_dir do |dir, task_folder|
      ci = write_ci_script(dir, <<~SH.strip)
        echo "stdout-marker"
        echo "stderr-marker" >&2
        exit 1
      SH

      cfg = cfg_with(ci, "review" => { "ci" => { "max_attempts" => 1 } })
      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg,
        ctx: make_ctx(dir, task_folder)
      )

      assert_equal :stale, result.status
      assert_includes result.last_output, "stdout-marker"
      assert_includes result.last_output, "stderr-marker"
    end
  end

  # --- PE1: prompt_template path-escape is ConfigError -----------------

  def test_path_escape_in_ci_prompt_template_raises_config_error
    with_ci_dir do |dir, task_folder|
      # max_attempts=2 so the fix-agent spawn (which uses prompt_template)
      # is reached after the first failing CI.
      ci = write_ci_script(dir, %(echo fail >&2; exit 1))
      cfg = cfg_with(ci, "review" => { "ci" => { "max_attempts" => 2, "prompt_template" => "../../../etc/passwd" } })

      assert_raises(Hive::ConfigError) do
        Hive::Stages::Review::CiFix.run!(
          cfg: cfg,
          ctx: make_ctx(dir, task_folder)
        )
      end
    end
  end

  # --- DP2: wall-clock cap short-circuits between attempts -------------

  def test_wall_clock_exceeded_short_circuits_after_first_attempt
    with_ci_dir do |dir, task_folder|
      # Always-failing CI; max_attempts high enough to enter the loop.
      ci = write_ci_script(dir, %(echo "fail" >&2; exit 7))
      cfg = cfg_with(ci, "review" => { "ci" => { "max_attempts" => 5 } })

      # Pretend we entered the loop one hour ago with a 10-second cap —
      # the second attempt's wall-clock check trips before run_ci_once.
      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg,
        ctx: make_ctx(dir, task_folder),
        started_at: Time.now - 3600,
        max_wall_clock_sec: 10
      )

      assert_equal :stale, result.status
      assert_equal 1, result.attempts,
                   "loop must short-circuit after the first attempt and not retry"
      assert_equal "wall_clock_exceeded", result.error_message
    end
  end

  # --- per-process timeout + byte-cap during read -----------------------

  def test_ci_command_timeout_returns_error
    with_ci_dir do |dir, task_folder|
      # CI script that sleeps well beyond the timeout the cfg sets.
      ci = write_ci_script(dir, %(echo started; sleep 30; echo never_printed))
      cfg = cfg_with(ci,
                     "review" => { "ci" => { "max_attempts" => 1 } },
                     "timeout_sec" => { "review_ci" => 2 })

      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg,
        ctx: make_ctx(dir, task_folder)
      )

      assert_equal :error, result.status
      assert_match(/timed out/, result.error_message)
    end
  end

  def test_ci_output_byte_cap_during_read
    with_ci_dir do |dir, task_folder|
      # 1 MB cap configured; emit ~3 MB. The reader must stop appending
      # once the cap is hit so we never hold the full stream in memory.
      ci = write_ci_script(dir, <<~SH.strip)
        for i in $(seq 1 3000); do
          # 1 KB per line so 3000 lines = ~3 MB
          printf 'X%.0s' {1..1023}
          echo
        done
        exit 1
      SH

      cfg = cfg_with(ci,
                     "review" => { "ci" => { "max_attempts" => 1, "max_log_bytes" => 1024 * 1024, "tail_lines" => 100_000 } },
                     "timeout_sec" => { "review_ci" => 30 })

      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg,
        ctx: make_ctx(dir, task_folder)
      )

      assert_equal :stale, result.status
      # last_output may include the truncation header from clean_output;
      # what matters is that the captured text is bounded by max_log_bytes.
      # The header itself adds < 1 KB, so 1 MB + 1 KB is a safe upper bound.
      assert_operator result.last_output.bytesize, :<=, 1024 * 1024 + 1024,
                      "last_output must respect the byte cap during read"
    end
  end

  # --- captured output reaches agent prompt -----------------------------

  def test_captured_output_is_passed_to_fix_agent_via_user_supplied_wrapper
    with_ci_dir do |dir, task_folder|
      marker = File.join(dir, ".ci-fixed")
      ci = write_ci_script(dir, <<~SH.strip)
        if [ -f "#{marker}" ]; then
          exit 0
        else
          echo "UNIQUE_FAILURE_TOKEN_42" >&2
          exit 1
        fi
      SH

      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = marker
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "fix\n"

      result = Hive::Stages::Review::CiFix.run!(
        cfg: cfg_with(ci),
        ctx: make_ctx(dir, task_folder)
      )

      assert_equal :green, result.status
      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv, "UNIQUE_FAILURE_TOKEN_42",
                      "fix agent must receive the captured failure log"
      assert_match(/<user_supplied_[0-9a-f]{16}/, argv,
                   "captured CI output must be wrapped in the per-spawn nonce")
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end
end
