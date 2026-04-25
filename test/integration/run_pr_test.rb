require "test_helper"
require "hive/commands/init"
require "hive/commands/run"

class RunPrTest < Minitest::Test
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
       HIVE_FAKE_GH_PR_EXISTS HIVE_FAKE_GH_CREATE_EXIT
       HIVE_FAKE_GH_LOG_DIR].each { |k| ENV.delete(k) }
  end

  def setup_pr_task(dir)
    capture_io do
      Hive::Commands::Init.new(dir).call
    end
    slug = "fix-bug-260424-aaaa"
    pr_dir = File.join(dir, ".hive-state", "stages", "5-pr", slug)
    FileUtils.mkdir_p(pr_dir)
    File.write(File.join(pr_dir, "plan.md"), "plan content")
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
    File.write(File.join(pr_dir, "worktree.yml"),
               { "path" => worktree_path, "branch" => slug }.to_yaml)
    [ pr_dir, worktree_path ]
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
        pr_dir, worktree_path = setup_pr_task(dir)
        stub_push(worktree_path)
        ENV["HIVE_FAKE_GH_PR_EXISTS"] = "1"
        capture_io { Hive::Commands::Run.new(pr_dir).call }
        pr_md = File.read(File.join(pr_dir, "pr.md"))
        assert_includes pr_md, "https://example.com/pr/1"
        assert_includes pr_md, "<!-- COMPLETE pr_url=https://example.com/pr/1 idempotent=true -->"
      end
    end
  end

  def test_existing_pr_lookup_runs_in_worktree
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        pr_dir, worktree_path = setup_pr_task(dir)
        stub_push(worktree_path)
        log_dir = Dir.mktmpdir("fake-gh-log")
        ENV["HIVE_FAKE_GH_LOG_DIR"] = log_dir
        ENV["HIVE_FAKE_GH_PR_EXISTS"] = "1"

        Dir.chdir("/") do
          capture_io { Hive::Commands::Run.new(pr_dir).call }
        end

        argv_log = File.read(File.join(log_dir, "fake-gh-argv.log"))
        pr_list_call = argv_log.split("---").find { |entry| entry.include?("arg=list") }
        assert pr_list_call, "expected fake gh to receive a pr list call"
        assert_includes pr_list_call, "cwd=#{worktree_path}\n"
      ensure
        FileUtils.rm_rf(log_dir) if log_dir
      end
    end
  end

  def test_pr_runner_invokes_agent_when_pr_missing
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        pr_dir, worktree_path = setup_pr_task(dir)
        stub_push(worktree_path)
        pr_md = File.join(pr_dir, "pr.md")
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ---
          pr_url: https://example.com/pr/9
          ---

          ## Summary
          fix

          <!-- COMPLETE pr_url=https://example.com/pr/9 -->
        MD
        capture_io { Hive::Commands::Run.new(pr_dir).call }
        assert_equal :complete, Hive::Markers.current(pr_md).name
      end
    end
  end

  def test_pr_runner_aborts_if_no_worktree_pointer
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        capture_io { Hive::Commands::Init.new(dir).call }
        slug = "no-pointer-260424-aaaa"
        pr_dir = File.join(dir, ".hive-state", "stages", "5-pr", slug)
        FileUtils.mkdir_p(pr_dir)
        _, err, status = with_captured_exit { Hive::Commands::Run.new(pr_dir).call }
        assert_equal 1, status
        assert_includes err, "no worktree pointer"
      end
    end
  end
end
