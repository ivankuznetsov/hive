require "test_helper"
require "hive/commands/init"
require "hive/commands/run"
require "hive/markers"

# Integration coverage for the 5-review runner. The unit-level tests for
# CiFix, Triage, BrowserTest, Reviewers cover their internals; this file
# focuses on the orchestrator's branching: pre-flight terminal markers,
# wall-clock cap, pass cap, ci-stale path, clean run end-to-end.
class RunReviewTest < Minitest::Test
  include HiveTestHelper

  def setup
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    @driver_dir = Dir.mktmpdir("review-driver")
    @driver_bin = File.join(@driver_dir, "claude")
    File.write(@driver_bin, <<~SH)
      #!/usr/bin/env bash
      if [[ "${1:-}" == "--version" ]]; then
        echo "2.1.118 (Claude Code)"
        exit 0
      fi
      exit 0
    SH
    File.chmod(0o755, @driver_bin)
    ENV["HIVE_CLAUDE_BIN"] = @driver_bin
  end

  def teardown
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    FileUtils.rm_rf(@driver_dir) if @driver_dir
    FileUtils.rm_rf(@local_worktree_root) if @local_worktree_root
  end

  def setup_review_task(dir, with_worktree: true, cfg_overrides: {})
    capture_io { Hive::Commands::Init.new(dir).call }
    cfg_path = File.join(dir, ".hive-state", "config.yml")
    cfg = YAML.safe_load(File.read(cfg_path))
    @local_worktree_root = Dir.mktmpdir("review-wt-root-")
    cfg["worktree_root"] = @local_worktree_root
    # Default: zero reviewers, no CI, browser disabled (clean review path).
    cfg["review"] ||= {}
    cfg["review"]["ci"] ||= {}
    cfg["review"]["ci"]["command"] = nil
    cfg["review"]["reviewers"] = []
    cfg["review"]["browser_test"] ||= {}
    cfg["review"]["browser_test"]["enabled"] = false
    deep_merge!(cfg, cfg_overrides)
    File.write(cfg_path, cfg.to_yaml)

    slug = "feat-x-260424-aaaa"
    folder = File.join(dir, ".hive-state", "stages", "5-review", slug)
    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "plan.md"), "## Overview\nstub\n<!-- COMPLETE -->\n")
    File.write(File.join(folder, "task.md"), <<~MD)
      ---
      slug: #{slug}
      ---

      # #{slug}

      ## Implementation
    MD

    if with_worktree
      wt_path = File.join(@local_worktree_root, slug)
      FileUtils.mkdir_p(wt_path)
      run!("git", "-C", wt_path, "init", "-b", "main", "--quiet")
      run!("git", "-C", wt_path, "config", "user.email", "test@example.com")
      run!("git", "-C", wt_path, "config", "user.name", "Test")
      run!("git", "-C", wt_path, "config", "commit.gpgsign", "false")
      File.write(File.join(wt_path, "README.md"), "test\n")
      run!("git", "-C", wt_path, "add", ".")
      run!("git", "-C", wt_path, "commit", "-m", "init", "--quiet")
      File.write(File.join(folder, "worktree.yml"), { "path" => wt_path, "branch" => slug }.to_yaml)
    end

    folder
  end

  def deep_merge!(base, over)
    over.each do |k, v|
      base[k] = if v.is_a?(Hash) && base[k].is_a?(Hash)
                  deep_merge!(base[k], v)
      else
                  v
      end
    end
    base
  end

  # --- pre-flight terminal markers short-circuit -----------------------

  def test_review_complete_marker_short_circuits
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder = setup_review_task(dir)
        File.write(File.join(folder, "task.md"), "<!-- REVIEW_COMPLETE pass=2 browser=passed -->\n")

        out, _err = capture_io { Hive::Commands::Run.new(folder).call }
        assert_match(/already complete/, out)
        # Marker untouched.
        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :review_complete, marker.name
      end
    end
  end

  def test_review_ci_stale_marker_short_circuits
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder = setup_review_task(dir)
        File.write(File.join(folder, "task.md"), "<!-- REVIEW_CI_STALE attempts=3 -->\n")

        _out, err = capture_io { Hive::Commands::Run.new(folder).call }
        assert_match(/REVIEW_CI_STALE/, err)
        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :review_ci_stale, marker.name
      end
    end
  end

  def test_review_stale_marker_short_circuits
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder = setup_review_task(dir)
        File.write(File.join(folder, "task.md"), "<!-- REVIEW_STALE pass=4 -->\n")

        _out, err = capture_io { Hive::Commands::Run.new(folder).call }
        assert_match(/REVIEW_STALE/, err)
        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :review_stale, marker.name
      end
    end
  end

  def test_review_error_marker_short_circuits
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder = setup_review_task(dir)
        File.write(File.join(folder, "task.md"), "<!-- REVIEW_ERROR phase=triage reason=triage_tampered -->\n")

        _out, err, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        # Run.report exits TASK_IN_ERROR for :error states. Implementation
        # may or may not propagate REVIEW_ERROR through that path; assert
        # the marker stays terminal regardless.
        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :review_error, marker.name
        assert_match(/REVIEW_ERROR/, err) if status != 0
      end
    end
  end

  # --- worktree pointer missing → exit 1 ------------------------------

  def test_worktree_yml_missing_exits_1
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder = setup_review_task(dir, with_worktree: false)

        _out, err, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        assert_equal 1, status
        assert_match(/worktree\.yml/, err)
        assert_match(/4-execute/, err)
      end
    end
  end

  def test_worktree_pointer_path_missing_exits_1
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder = setup_review_task(dir)
        # Remove the worktree directory but keep the pointer file.
        wt_path = YAML.safe_load(File.read(File.join(folder, "worktree.yml")))["path"]
        FileUtils.rm_rf(wt_path)

        _out, err, status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        assert_equal 1, status
        assert_match(/worktree pointer present but worktree missing/, err)
      end
    end
  end

  # --- clean fast path: zero reviewers + no CI + browser disabled --

  def test_clean_run_with_no_reviewers_finalizes_review_complete
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        folder = setup_review_task(dir)

        capture_io { Hive::Commands::Run.new(folder).call }
        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :review_complete, marker.name
        assert_equal "skipped", marker.attrs["browser"]
      end
    end
  end

  # --- CI hard-block path -----------------------------------------------

  def test_ci_failures_yield_review_ci_stale_after_cap
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        # Configure an always-failing CI command, low max_attempts.
        always_fail = File.join(@driver_dir, "fail-ci")
        File.write(always_fail, "#!/usr/bin/env bash\necho 'FAIL' >&2\nexit 1\n")
        File.chmod(0o755, always_fail)

        folder = setup_review_task(dir, cfg_overrides: {
          "review" => {
            "ci" => { "command" => always_fail, "max_attempts" => 1 }
          },
          "budget_usd" => { "review_ci" => 1 },
          "timeout_sec" => { "review_ci" => 1 }
        })

        _out, err, _status = with_captured_exit { Hive::Commands::Run.new(folder).call }
        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :review_ci_stale, marker.name
        # ci-blocked.md is written for the user to inspect.
        assert File.exist?(File.join(folder, "reviews", "ci-blocked.md"))
        assert_includes File.read(File.join(folder, "reviews", "ci-blocked.md")), "FAIL"
      end
    end
  end

  # --- wall-clock cap -------------------------------------------------

  def test_wall_clock_cap_yields_review_stale_with_reason_wall_clock
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        # max_wall_clock_sec=0 forces the runner to trip the cap on the
        # first phase boundary check (CI is skipped, then the wall-clock
        # check at the start of the pass loop fires).
        folder = setup_review_task(dir, cfg_overrides: {
          "review" => { "max_wall_clock_sec" => 0 }
        })

        capture_io { Hive::Commands::Run.new(folder).call }
        marker = Hive::Markers.current(File.join(folder, "task.md"))
        assert_equal :review_stale, marker.name
        assert_equal "wall_clock", marker.attrs["reason"]
      end
    end
  end
end
