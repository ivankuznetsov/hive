require "test_helper"
require "tmpdir"
require "fileutils"
require "hive/commands/bench_submit"

# Unit test for `hive bench submit`. The extractor, PR opener, and secret
# preflight are seams, so no real gh/extract/network is touched; the test
# proves the orchestration: resolve the 9-done task, preflight, extract, PR.
class BenchSubmitCommandTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("bench-submit")
    @bench = File.join(@root, "hive-bench")
    @proj = File.join(@root, "demo")
    FileUtils.mkdir_p(@bench)
    @done = File.join(@proj, ".hive-state", "stages", "9-done", "fix-thing-260601-aa11")
    FileUtils.mkdir_p(@done)
    init_proj_git
    write_done_artifacts
    @calls = {}
  end

  def init_proj_git
    system("git", "init", "-q", @proj, exception: true)
    system("git", "-C", @proj, "remote", "add", "origin", "https://github.com/ivankuznetsov/demo.git", exception: true)
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def write_done_artifacts
    File.write(File.join(@done, "worktree.yml"), "execute_base_head: abc123\n")
    File.write(File.join(@done, "pr.md"), "---\npr_number: 42\n---\nbody\n")
    File.write(File.join(@done, "plan.md"), "# Plan\ndo the thing\n")
  end

  def projects = [ { "name" => "demo", "path" => @proj } ]

  def stub_extractor
    lambda do |task_dir:, repo:, repo_path:, out_dir:|
      @calls[:extract] = { task_dir: task_dir, repo: repo, repo_path: repo_path, out_dir: out_dir }
      File.join(out_dir, "fix-thing-260601-aa11")
    end
  end

  def stub_pr
    lambda do |bench_path:, entry_dir:, slug:|
      @calls[:pr] = { bench_path: bench_path, entry_dir: entry_dir, slug: slug }
      "https://github.com/ivankuznetsov/hive-bench/pull/7"
    end
  end

  def build(**overrides)
    Hive::Commands::BenchSubmit.new(
      "fix-thing-260601-aa11", bench_path: @bench, projects: projects, repo_path: @proj,
      extractor: stub_extractor, pr_opener: stub_pr,
      secret_preflight: ->(_paths) { [] }, **overrides
    )
  end

  def test_happy_path_extracts_and_opens_pr
    capture_io { @result = build.call }

    assert_equal @done, @calls[:extract][:task_dir]
    assert_equal "ivankuznetsov/demo", @calls[:extract][:repo], "source repo derived from origin"
    assert_equal File.join(@bench, "corpus"), @calls[:extract][:out_dir]
    assert_equal "fix-thing-260601-aa11", @calls[:pr][:slug]
    assert_equal "https://github.com/ivankuznetsov/hive-bench/pull/7", @result
  end

  def test_aborts_when_secret_found_before_pr
    cmd = build(secret_preflight: ->(_paths) { [ "github token in plan.md:3" ] })
    err = assert_raises(Hive::Commands::BenchSubmit::UsageError) { cmd.call }
    assert_match(/secret/, err.message)
    assert_nil @calls[:pr], "no PR may be opened when a secret is found"
  end

  def test_aborts_when_task_missing_pr_md
    FileUtils.rm_f(File.join(@done, "pr.md"))
    err = assert_raises(Hive::Commands::BenchSubmit::UsageError) { build.call }
    assert_match(/pr\.md/, err.message)
    assert_nil @calls[:extract]
  end

  def test_aborts_when_task_missing_worktree_yml
    FileUtils.rm_f(File.join(@done, "worktree.yml"))
    err = assert_raises(Hive::Commands::BenchSubmit::UsageError) { build.call }
    assert_match(/worktree\.yml/, err.message)
  end

  def test_unknown_slug_is_usage_error
    cmd = Hive::Commands::BenchSubmit.new("nope-260601-zz99", bench_path: @bench, projects: projects,
                                          extractor: stub_extractor, pr_opener: stub_pr, secret_preflight: ->(_p) { [] })
    err = assert_raises(Hive::Commands::BenchSubmit::UsageError) { cmd.call }
    assert_match(/no completed/, err.message)
  end

  def test_missing_bench_checkout_is_usage_error
    cmd = build(bench_path: File.join(@root, "absent"))
    err = assert_raises(Hive::Commands::BenchSubmit::UsageError) { cmd.call }
    assert_match(/hive-bench checkout not found/, err.message)
  end
end
