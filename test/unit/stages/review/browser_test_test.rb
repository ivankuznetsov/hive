require "test_helper"
require "json"
require "hive/stages/review/browser_test"
require "hive/reviewers"
require "hive/agent_profiles"

# Direct coverage for the optional browser-test phase. Uses fake-claude
# (HIVE_FAKE_CLAUDE_WRITE_FILE/CONTENT) to simulate the agent's
# JSON-result write per attempt.
class BrowserTestTest < Minitest::Test
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
       HIVE_FAKE_CLAUDE_LOG_DIR HIVE_FAKE_CLAUDE_VERSION].each { |k| ENV.delete(k) }
    Hive::AgentProfile.reset_version_cache!
  end

  def with_browser_dir(pass: 1)
    with_tmp_dir do |dir|
      task_folder = File.join(dir, ".hive-state", "stages", "5-review", "browser-test-task")
      FileUtils.mkdir_p(File.join(task_folder, "reviews"))
      FileUtils.mkdir_p(File.join(task_folder, "logs"))
      ctx = Hive::Reviewers::Context.new(
        worktree_path: dir,
        task_folder: task_folder,
        default_branch: "main",
        pass: pass
      )
      yield(dir, task_folder, ctx)
    end
  end

  def cfg_with(overrides = {})
    base = {
      "review" => {
        "browser_test" => {
          "enabled" => true,
          "agent" => "claude",
          "max_attempts" => 2,
          "prompt_template" => "browser_test_prompt.md.erb"
        }
      },
      "budget_usd" => { "review_browser" => 5 },
      "timeout_sec" => { "review_browser" => 5 }
    }
    deep_merge(base, overrides)
  end

  def deep_merge(base, over)
    base.merge(over) do |_k, b, o|
      b.is_a?(Hash) && o.is_a?(Hash) ? deep_merge(b, o) : o
    end
  end

  # --- skipped path ----------------------------------------------------

  def test_returns_skipped_when_disabled
    with_browser_dir do |_dir, _task_folder, ctx|
      cfg = cfg_with("review" => { "browser_test" => { "enabled" => false } })
      result = Hive::Stages::Review::BrowserTest.run!(cfg: cfg, ctx: ctx)

      assert_equal :skipped, result.status
      assert_equal 0, result.attempts
      assert_nil result.summary
    end
  end

  # --- happy paths -----------------------------------------------------

  def test_returns_passed_when_first_attempt_succeeds
    with_browser_dir do |_dir, task_folder, ctx|
      result_path = File.join(task_folder, "reviews", "browser-result-01-01.json")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = result_path
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = JSON.generate(
        status: "passed",
        summary: "all 12 flows green",
        details: "",
        duration_sec: 47.3
      )

      result = Hive::Stages::Review::BrowserTest.run!(cfg: cfg_with, ctx: ctx)

      assert_equal :passed, result.status
      assert_equal 1, result.attempts
      assert_equal "all 12 flows green", result.summary
      refute File.exist?(File.join(task_folder, "reviews", "browser-blocked-01.md"))
    end
  end

  def test_returns_passed_when_second_attempt_succeeds_after_first_fails
    with_browser_dir do |dir, task_folder, ctx|
      attempt_count_file = File.join(dir, ".browser-attempts")
      File.write(attempt_count_file, "0")

      script = File.join(dir, "flaky-fake-claude")
      File.write(script, <<~SH)
        #!/usr/bin/env bash
        if [[ "${1:-}" == "--version" ]]; then
          echo "2.1.118 (Claude Code)"
          exit 0
        fi
        attempts=$(cat "#{attempt_count_file}")
        attempts=$((attempts + 1))
        echo "$attempts" > "#{attempt_count_file}"
        if [ "$attempts" = "1" ]; then
          # First attempt: write a "failed" JSON.
          cat > "#{task_folder}/reviews/browser-result-01-01.json" <<'JSON'
        {"status":"failed","summary":"flow A timed out","details":"timeout at 30s","duration_sec":30.0}
        JSON
        else
          # Second attempt: write a "passed" JSON.
          cat > "#{task_folder}/reviews/browser-result-01-02.json" <<'JSON'
        {"status":"passed","summary":"all flows green on retry","details":"","duration_sec":42.0}
        JSON
        fi
        exit 0
      SH
      File.chmod(0o755, script)
      ENV["HIVE_CLAUDE_BIN"] = script

      result = Hive::Stages::Review::BrowserTest.run!(cfg: cfg_with, ctx: ctx)

      assert_equal :passed, result.status
      assert_equal 2, result.attempts
      assert_equal "all flows green on retry", result.summary
    end
  end

  # --- soft-warn path --------------------------------------------------

  def test_returns_warned_when_all_attempts_fail
    with_browser_dir do |dir, task_folder, ctx|
      script = File.join(dir, "always-fail-fake-claude")
      File.write(script, <<~SH)
        #!/usr/bin/env bash
        if [[ "${1:-}" == "--version" ]]; then
          echo "2.1.118 (Claude Code)"
          exit 0
        fi
        # Detect the attempt number from the result_path that the prompt
        # asks the agent to write. Easiest: derive from existing files.
        if [ ! -f "#{task_folder}/reviews/browser-result-01-01.json" ]; then
          target="#{task_folder}/reviews/browser-result-01-01.json"
          summary="login flow timeout (attempt 1)"
        else
          target="#{task_folder}/reviews/browser-result-01-02.json"
          summary="login flow timeout (attempt 2)"
        fi
        cat > "$target" <<JSON
        {"status":"failed","summary":"$summary","details":"timeout at 30s\\nscreenshot: /tmp/login-fail.png","duration_sec":30.0}
        JSON
        exit 0
      SH
      File.chmod(0o755, script)
      ENV["HIVE_CLAUDE_BIN"] = script

      result = Hive::Stages::Review::BrowserTest.run!(cfg: cfg_with, ctx: ctx)

      assert_equal :warned, result.status
      assert_equal 2, result.attempts

      blocked = File.join(task_folder, "reviews", "browser-blocked-01.md")
      assert File.exist?(blocked), "browser-blocked-NN.md must be written on cap"
      content = File.read(blocked)
      assert_includes content, "Browser test blocked"
      assert_includes content, "Attempt 1"
      assert_includes content, "Attempt 2"
      assert_includes content, "login flow timeout (attempt 1)"
      assert_includes content, "login flow timeout (attempt 2)"
      assert_includes content, "screenshot: /tmp/login-fail.png"
    end
  end

  # --- malformed result handling ---------------------------------------

  def test_missing_json_result_counts_as_failed_attempt
    with_browser_dir do |dir, task_folder, ctx|
      # Fake-claude exits 0 but writes nothing — every attempt produces no JSON.
      result = Hive::Stages::Review::BrowserTest.run!(cfg: cfg_with, ctx: ctx)

      # All max_attempts (2) consumed → :warned.
      assert_equal :warned, result.status
      assert_equal 2, result.attempts

      blocked = File.read(File.join(task_folder, "reviews", "browser-blocked-01.md"))
      # Either "produced no result file" (empty file expected_output check),
      # or "agent spawn failed" (output_file_exists missing). Both are
      # acceptable representations of "no JSON" for the user-facing log.
      assert_match(/no result file|spawn failed|missing or empty/i, blocked)
    end
  end

  def test_unparseable_json_counts_as_failed_attempt
    with_browser_dir do |dir, task_folder, ctx|
      script = File.join(dir, "garbage-json-fake-claude")
      File.write(script, <<~SH)
        #!/usr/bin/env bash
        if [[ "${1:-}" == "--version" ]]; then
          echo "2.1.118 (Claude Code)"
          exit 0
        fi
        if [ ! -f "#{task_folder}/reviews/browser-result-01-01.json" ]; then
          target="#{task_folder}/reviews/browser-result-01-01.json"
        else
          target="#{task_folder}/reviews/browser-result-01-02.json"
        fi
        echo "{this is not valid JSON" > "$target"
        exit 0
      SH
      File.chmod(0o755, script)
      ENV["HIVE_CLAUDE_BIN"] = script

      result = Hive::Stages::Review::BrowserTest.run!(cfg: cfg_with, ctx: ctx)

      assert_equal :warned, result.status
      blocked_path = File.join(task_folder, "reviews", "browser-blocked-01.md")
      assert File.exist?(blocked_path)
      blocked = File.read(blocked_path)
      assert_match(/unparseable JSON|spawn failed|missing or empty/i, blocked)
    end
  end

  # --- prompt content --------------------------------------------------

  def test_prompt_invokes_ce_test_browser_skill_via_profile_syntax
    with_browser_dir do |_dir, task_folder, ctx|
      result_path = File.join(task_folder, "reviews", "browser-result-01-01.json")
      ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = result_path
      ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = JSON.generate(
        status: "passed", summary: "ok", details: "", duration_sec: 1.0
      )
      log_dir = Dir.mktmpdir("fake-claude-argv")
      ENV["HIVE_FAKE_CLAUDE_LOG_DIR"] = log_dir

      Hive::Stages::Review::BrowserTest.run!(cfg: cfg_with, ctx: ctx)

      argv = File.read(File.join(log_dir, "fake-claude-argv.log"))
      assert_includes argv, "/ce-test-browser",
                      "claude profile must render skill_invocation as `/ce-test-browser`"
      assert_includes argv, result_path,
                      "prompt must tell the agent where to write the JSON result"
    ensure
      FileUtils.rm_rf(log_dir) if log_dir
    end
  end

  # --- result-path layout ----------------------------------------------

  def test_result_path_includes_pass_and_attempt_zero_padded
    with_browser_dir(pass: 3) do |_dir, task_folder, ctx|
      assert_equal File.join(task_folder, "reviews", "browser-result-03-02.json"),
                   Hive::Stages::Review::BrowserTest.browser_result_path(ctx, 2)
      assert_equal File.join(task_folder, "reviews", "browser-blocked-03.md"),
                   Hive::Stages::Review::BrowserTest.browser_blocked_path(ctx)
    end
  end
end
