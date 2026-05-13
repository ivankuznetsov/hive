require "test_helper"
require "hive/commands/init"
require "hive/commands/run"

class RunFinalizeTest < Minitest::Test
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
    %w[HIVE_FAKE_CLAUDE_WRITE_FILE HIVE_FAKE_CLAUDE_WRITE_CONTENT].each { |k| ENV.delete(k) }
  end

  def setup_finalize_task(dir)
    capture_io { Hive::Commands::Init.new(dir).call }
    slug = "fix-bug-260424-aaaa"
    task_dir = File.join(dir, ".hive-state", "stages", "7-finalize", slug)
    FileUtils.mkdir_p(task_dir)
    File.write(File.join(task_dir, "plan.md"), "plan content")
    FileUtils.mkdir_p(File.join(task_dir, "reviews"))
    File.write(File.join(task_dir, "reviews", "codex-01.md"), "- [x] fixed\n")
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
    bare = "#{worktree_path}-remote.git"
    @worktree_paths << bare
    run!("git", "init", "--bare", bare, "--quiet")
    run!("git", "-C", worktree_path, "remote", "add", "origin", bare)
    run!("git", "-C", worktree_path, "push", "-u", "origin", slug, "--quiet")
    File.write(File.join(task_dir, "worktree.yml"),
               { "path" => worktree_path, "branch" => slug }.to_yaml)
    pr_md = File.join(task_dir, "pr.md")
    File.write(pr_md, <<~MD)
      ---
      pr_url: https://example.com/pr/9
      pr_number: 9
      ---

      ## Summary
      draft

      <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=true -->
    MD
    [ task_dir, worktree_path, pr_md ]
  end

  def test_finalize_writes_summary_after_agent_completion
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, pr_md = setup_finalize_task(dir)
        ENV["HIVE_FAKE_CLAUDE_WRITE_FILE"] = pr_md
        ENV["HIVE_FAKE_CLAUDE_WRITE_CONTENT"] = <<~MD
          ---
          pr_url: https://example.com/pr/9
          pr_number: 9
          ---

          ## Summary
          final

          <!-- COMPLETE pr_url=https://example.com/pr/9 is_draft=false -->
        MD

        capture_io { Hive::Commands::Run.new(task_dir).call }

        assert_equal :complete, Hive::Markers.current(pr_md).name
        assert File.exist?(File.join(task_dir, "summary.md"))
        assert_includes File.read(File.join(task_dir, "summary.md")), "https://example.com/pr/9"
      end
    end
  end

  def test_finalize_dirty_worktree_sets_error
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, worktree_path, pr_md = setup_finalize_task(dir)
        File.write(File.join(worktree_path, "dirty"), "x")

        _out, _err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }

        assert_equal Hive::ExitCodes::TASK_IN_ERROR, status
        marker = Hive::Markers.current(pr_md)
        assert_equal :error, marker.name
        assert_equal "dirty_worktree", marker.attrs["reason"]
      end
    end
  end

  def test_finalize_requires_pr_md
    with_tmp_global_config do
      with_tmp_git_repo do |dir|
        task_dir, _worktree_path, _pr_md = setup_finalize_task(dir)
        FileUtils.rm_f(File.join(task_dir, "pr.md"))

        _out, err, status = with_captured_exit { Hive::Commands::Run.new(task_dir).call }

        assert_equal 1, status
        assert_includes err, "finalize entered without 5-open-pr"
      end
    end
  end
end
