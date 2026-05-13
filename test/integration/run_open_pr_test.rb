require "test_helper"
require "hive/commands/init"
require "hive/commands/run"

class RunOpenPrTest < Minitest::Test
  include HiveTestHelper

  FAKE_CLAUDE = File.expand_path("../fixtures/fake-claude", __dir__)
  FAKE_GH = File.expand_path("../fixtures/fake-gh", __dir__)

  def setup
    @prev_path = ENV["PATH"]
    @prev_bin = ENV["HIVE_CLAUDE_BIN"]
    ENV["HIVE_CLAUDE_BIN"] = FAKE_CLAUDE
    @gh_dir = Dir.mktmpdir("fake-gh-bin")
    File.symlink(FAKE_GH, File.join(@gh_dir, "gh"))
    ENV["PATH"] = "#{@gh_dir}:#{@prev_path}"
  end

  def teardown
    ENV["PATH"] = @prev_path
    ENV["HIVE_CLAUDE_BIN"] = @prev_bin
    FileUtils.rm_rf(@gh_dir) if @gh_dir
    Array(@worktree_paths).each { |p| FileUtils.rm_rf(p) }
    %w[HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT
       HIVE_FAKE_GH_PR_EXISTS HIVE_FAKE_GH_AUTH_EXIT HIVE_FAKE_GH_LOG_DIR].each { |k| ENV.delete(k) }
  end

  def setup_open_pr_task(dir)
    capture_io { Hive::Commands::Init.new(dir).call }
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
  end

  def test_existing_pr_short_circuits_without_agent
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path = setup_open_pr_task(dir)
        stub_push(worktree_path)
        ENV["HIVE_FAKE_GH_PR_EXISTS"] = "1"
        capture_io { Hive::Commands::Run.new(task_dir).call }
        pr_md = File.read(File.join(task_dir, "pr.md"))
        assert_includes pr_md, "https://example.com/pr/1"
        assert_includes pr_md, "<!-- COMPLETE pr_url=https://example.com/pr/1 is_draft=true idempotent=true -->"
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
        capture_io { Hive::Commands::Run.new(task_dir).call }
        assert_equal :complete, Hive::Markers.current(pr_md).name
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
end
