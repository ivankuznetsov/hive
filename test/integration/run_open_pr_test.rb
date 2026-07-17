require "test_helper"
require "hive/commands/init"
require "hive/commands/run"

class RunOpenPrTest < Minitest::Test
  include HiveTestHelper

  def setup
    @prev_path = ENV["PATH"]
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_CLAUDE_FIXTURE
    @gh_dir = Dir.mktmpdir("fake-gh-bin")
    File.symlink(FAKE_GH_FIXTURE, File.join(@gh_dir, "gh"))
    ENV["PATH"] = "#{@gh_dir}:#{@prev_path}"
    @gh_log_dir = Dir.mktmpdir("fake-gh-log")
    ENV["HIVE_FAKE_GH_LOG_DIR"] = @gh_log_dir
  end

  def teardown
    ENV["PATH"] = @prev_path
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    FileUtils.rm_rf(@gh_dir) if @gh_dir
    FileUtils.rm_rf(@gh_log_dir) if @gh_log_dir
    Array(@worktree_paths).each { |p| FileUtils.rm_rf(p) }
    %w[
      HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
      HIVE_FAKE_GH_PR_EXISTS HIVE_FAKE_GH_AUTH_EXIT HIVE_FAKE_GH_LOG_DIR
        HIVE_FAKE_GH_PR_BODY HIVE_FAKE_GH_PR_STATE
        HIVE_FAKE_GH_PR_ISDRAFT HIVE_FAKE_GH_READY_STDERR
        HIVE_FAKE_GH_PR_EXISTS_FILE HIVE_FAKE_GH_PR_EXISTS_URL HIVE_FAKE_GH_PR_EXISTS_NUMBER
        HIVE_FAKE_GH_HEAD_REF_OID
      ].each { |k| ENV.delete(k) }
    end

    def test_existing_non_draft_pr_records_state_and_finalize_skips_ready
      with_tmp_global_config do
        with_tmp_git_repo do |dir|
          task_dir, worktree_path = setup_open_pr_task(dir)
          stub_push(worktree_path)
          slug = File.basename(task_dir)
          run!("git", "-C", worktree_path, "push", "-u", "origin", slug, "--quiet")
          ENV["HIVE_FAKE_GH_PR_EXISTS"] = "1"
          ENV["HIVE_FAKE_GH_PR_ISDRAFT"] = "false"
          # PR #138 fix #146: pin fake-gh's headRefOid to local HEAD so
          # the already-open short-circuit triggers under the new filter.
          ENV["HIVE_FAKE_GH_HEAD_REF_OID"] = run!("git", "-C", worktree_path, "rev-parse", "HEAD").strip

          capture_io { Hive::Commands::Run.new(task_dir).call }
          pr_md = File.join(task_dir, "pr.md")
          assert_includes File.read(pr_md),
                          "<!-- COMPLETE pr_url=https://example.com/pr/1 is_draft=false idempotent=true -->"

          finalize_dir = File.join(dir, ".hive-state", "stages", "8-finalize", slug)
          FileUtils.mkdir_p(File.dirname(finalize_dir))
          FileUtils.mv(task_dir, finalize_dir)
          pr_md = File.join(finalize_dir, "pr.md")
          ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
          ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
	          ---
	          pr_url: https://example.com/pr/1
	          pr_number: 1
	          ---

	          ## Summary
	          final body

	          <!-- COMPLETE pr_url=https://example.com/pr/1 is_draft=false -->
          MD

          with_finalize_attempt(task_folder: finalize_dir) do
            capture_io { Hive::Commands::Run.new(finalize_dir).call }
          end
          log = gh_argv_log
          refute_match(/arg=ready\n/, log,
                       "finalize must not call `gh pr ready` when gh reports the PR is already ready")
        end
      end
    end

  # Wire fake-gh to flip its `pr list` result from "[]" to "[<pr>]"
  # AFTER fake-claude runs — proxy for `gh pr create`'s side effect.
  # validate_complete_marker re-runs `gh pr list` post-spawn and
  # requires the URL to match.
  def arm_post_agent_pr_exists(url:, number:)
    flag_file = Dir::Tmpname.create("pr-exists-flag") { }
    ENV["HIVE_FAKE_GH_PR_EXISTS_FILE"] = flag_file
    ENV["HIVE_FAKE_GH_PR_EXISTS_URL"] = url
    ENV["HIVE_FAKE_GH_PR_EXISTS_NUMBER"] = number.to_s
    Array(@worktree_paths) << flag_file
    flag_file
  end

  def gh_argv_log
    path = File.join(@gh_log_dir, "fake-gh-argv.log")
    File.exist?(path) ? File.read(path) : ""
  end

  def setup_open_pr_task(dir)
    capture_io { Hive::Commands::Init.new(dir).call }
    set_project_claude_mode(dir, "headless")
    slug = "fix-bug-260424-aaaa"
    task_dir = File.join(dir, ".hive-state", "stages", "5-open-pr", slug)
    FileUtils.mkdir_p(task_dir)
    File.write(File.join(task_dir, "plan.md"), "plan content")
    File.write(File.join(task_dir, "task.md"), "## Execute Output\nimplemented\n")
    worktree_path = Dir.mktmpdir("wt-#{slug}-")
    @worktree_paths ||= []
    @worktree_paths << worktree_path
    run!("git", "-C", worktree_path, "init", "-b", slug, "--quiet")
    run!("git", "-C", worktree_path, "config", "user.email", "t@t")
    run!("git", "-C", worktree_path, "config", "user.name", "t")
    run!("git", "-C", worktree_path, "config", "commit.gpgsign", "false")
    File.write(File.join(worktree_path, "f"), "x")
    run!("git", "-C", worktree_path, "add", ".")
    run!("git", "-C", worktree_path, "commit", "-m", "wt", "--quiet")
    File.write(File.join(task_dir, "worktree.yml"),
               { "path" => worktree_path, "branch" => slug }.to_yaml)
    [ task_dir, worktree_path ]
  end

  def stub_push(worktree_path)
    bare = "#{worktree_path}-remote.git"
    @worktree_paths << bare
    run!("git", "init", "--bare", bare, "--quiet")
    run!("git", "-C", worktree_path, "remote", "add", "origin", bare)
    bare
  end

  def test_existing_pr_short_circuits_without_agent
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path = setup_open_pr_task(dir)
        stub_push(worktree_path)
        ENV["HIVE_FAKE_GH_PR_EXISTS"] = "1"
        # PR #138 fix #146: open-pr now requires headRefOid to match the
        # local HEAD before adopting an OPEN PR as already-open. Pin
        # fake-gh's reported headRefOid to the worktree's current HEAD
        # so the idempotent short-circuit still triggers.
        ENV["HIVE_FAKE_GH_HEAD_REF_OID"] = run!("git", "-C", worktree_path, "rev-parse", "HEAD").strip
        # Set a tripwire content the fake-claude WOULD write if invoked —
        # the test then asserts pr.md does NOT have it.
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = File.join(task_dir, "pr.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "AGENT-WAS-INVOKED-TRIPWIRE\n"

        capture_io { Hive::Commands::Run.new(task_dir).call }
        pr_md = File.read(File.join(task_dir, "pr.md"))
        assert_includes pr_md, "https://example.com/pr/1"
        assert_includes pr_md, "<!-- COMPLETE pr_url=https://example.com/pr/1 is_draft=true idempotent=true -->"
        # Tightened (round-1 finding): assert the agent was NOT
        # invoked — otherwise a regression that double-runs the
        # idempotent path would pass.
        refute_match(/AGENT-WAS-INVOKED-TRIPWIRE/, pr_md,
                     "idempotent path must not invoke the agent")
      end
    end
  end

  def test_open_pr_runner_invokes_agent_when_pr_missing
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path = setup_open_pr_task(dir)
        stub_push(worktree_path)
        pr_md = File.join(task_dir, "pr.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ---
          pr_url: https://example.com/pr/9
          pr_number: 9
          ---

          ## Summary
          fix

          <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=true -->
        MD
        # validate_complete_marker re-runs `gh pr list` after the
        # agent and requires the URL to match. Arm fake-gh to report
        # the PR once fake-claude has run.
        arm_post_agent_pr_exists(url: "https://example.com/pr/9", number: 9)
          capture_io { Hive::Commands::Run.new(task_dir).call }
          assert_equal :complete, Hive::Markers.current(pr_md).name
        end
      end
    end

  def test_open_pr_success_without_complete_marker_lands_error
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path = setup_open_pr_task(dir)
        stub_push(worktree_path)
        pr_md = File.join(task_dir, "pr.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = "agent wrote a body but no marker\n"

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "open_pr_marker_missing_complete", marker.attrs["reason"]
      end
    end
  end

  # Marker validation (round-1 finding): a malformed agent COMPLETE
  # marker (missing pr_url, or pointing at a URL that does not exist
  # on GitHub) must surface as ERROR right here, not silently advance
  # into 6-review where the failure would re-emerge as a confusing
  # `gh pr comment` error against a non-existent PR.
  def test_open_pr_marker_pr_url_mismatch_lands_error
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path = setup_open_pr_task(dir)
        stub_push(worktree_path)
        pr_md = File.join(task_dir, "pr.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ---
          pr_url: https://example.com/pr/FAKE
          pr_number: 42
          ---

          <!-- COMPLETE pr_url=https://example.com/pr/FAKE is_draft=true -->
        MD
        # NO arm_post_agent_pr_exists: simulate an agent that wrote
        # a marker but never actually called `gh pr create`.

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "open_pr_url_mismatch", marker.attrs["reason"]
      end
    end
  end

  def test_gh_auth_failure_exits_one
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path = setup_open_pr_task(dir)
        stub_push(worktree_path)
        ENV["HIVE_FAKE_GH_AUTH_EXIT"] = "1"
        _out, err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }
        assert_equal 1, status
        assert_includes err, "gh not authenticated"
        refute File.exist?(File.join(task_dir, "pr.md"))
      end
    end
  end

  # AC2 verification: open_pr must push the branch to origin BEFORE
  # spawning the agent. Without push reachability, `gh pr create`
  # would fail downstream. Regression guard: a future refactor that
  # drops Hive::Gh.push_branch! from OpenPr.run! would silently let
  # the agent attempt `gh pr create` against a non-existent remote
  # branch.
  def test_open_pr_pushes_branch_before_agent_spawn
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path = setup_open_pr_task(dir)
        bare = stub_push(worktree_path)
        pr_md = File.join(task_dir, "pr.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ---
          pr_url: https://example.com/pr/9
          pr_number: 9
          ---

          <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=true -->
        MD
        arm_post_agent_pr_exists(url: "https://example.com/pr/9", number: 9)

        capture_io { Hive::Commands::Run.new(task_dir).call }

        slug = File.basename(task_dir)
        # The bare remote must now have the slug branch as a ref —
        # proof that push_branch! ran.
        out = `git -C #{bare.shellescape} rev-parse refs/heads/#{slug.shellescape} 2>&1`
        assert $CHILD_STATUS.success?,
               "bare origin must have ref refs/heads/#{slug} after open-pr; got: #{out}"
      end
    end
  end

  # Push-failure exit-1 path (plan U2): without a remote, push_branch!
  # exits 1 and pr.md is never created.
  def test_open_pr_push_failure_exits_one
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path = setup_open_pr_task(dir)
        # no remote configured -> push fails
        _out, err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }
        assert_equal 1, status, "push failure must exit 1"
        assert_match(/git push failed/, err)
        refute File.exist?(File.join(task_dir, "pr.md")),
               "pr.md must not exist when push failed before agent spawn"
      end
    end
  end

  # No-worktree-pointer precondition (replaced from deleted Stages::Pr test):
  # without worktree.yml, the runner must exit 1 with a useful message.
  def test_open_pr_no_worktree_pointer_exits_one
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path = setup_open_pr_task(dir)
        FileUtils.rm_f(File.join(task_dir, "worktree.yml"))

        _out, err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }
        assert_equal 1, status
        assert_match(/no worktree pointer/, err)
        assert_match(/4-execute/, err)
      end
    end
  end

  # R4 / SECURITY.md P0 invariant: when the agent-authored pr.md or
  # the remote PR body contains a credential pattern, open-pr lands
  # ERROR reason=secret_in_pr_body and scrubs the leaked draft (no
  # COMPLETE marker, no advance to 6-review). A regression in
  # SecretPatterns.scan or scan_pr_for_secrets would silently disable
  # the security gate without this test.
  def test_open_pr_secret_in_pr_body_lands_error
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path = setup_open_pr_task(dir)
        stub_push(worktree_path)
        pr_md = File.join(task_dir, "pr.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
        # Agent writes a body containing an Anthropic key pattern.
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ---
          pr_url: https://example.com/pr/9
          pr_number: 9
          ---

          ## Summary
          api_key sk-ant-#{"a" * 30}

          <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=true -->
        MD
        arm_post_agent_pr_exists(url: "https://example.com/pr/9", number: 9)

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }
        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "secret_in_pr_body", marker.attrs["reason"]
        # Remediation invoked: `gh pr edit ... --body [redacted]` and
        # `gh pr close <url>`. Argv log should contain both.
        log = gh_argv_log
        assert_match(/arg=edit\n.*arg=https:\/\/example\.com\/pr\/9/m, log,
                     "must scrub leaked PR body with gh pr edit")
        assert_match(/arg=close\n.*arg=https:\/\/example\.com\/pr\/9/m, log,
                     "must close leaked draft PR")
      end
    end
  end
end
