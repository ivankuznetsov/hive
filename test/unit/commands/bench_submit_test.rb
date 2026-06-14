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

  # --- coverage of the default seams (real git + stub binaries, the hive way) ---

  def with_stub_path(git_body: "exit 0", gh_body: "echo https://github.com/ivankuznetsov/hive-bench/pull/9")
    bin = File.join(@root, "stubbin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "git"), "#!/usr/bin/env bash\n#{git_body}\n")
    File.write(File.join(bin, "gh"), "#!/usr/bin/env bash\n#{gh_body}\n")
    FileUtils.chmod(0o755, File.join(bin, "git"))
    FileUtils.chmod(0o755, File.join(bin, "gh"))
    old = ENV["PATH"]
    ENV["PATH"] = "#{bin}:#{old}"
    yield
  ensure
    ENV["PATH"] = old
  end

  def cmd = Hive::Commands::BenchSubmit.new("fix-thing-260601-aa11", bench_path: @bench, projects: projects)

  def test_local_secret_scan_finds_and_passes
    File.write(File.join(@done, "leak.md"), "token = ghp_#{"a" * 36}\n")
    found = cmd.send(:local_secret_scan, [ File.join(@done, "leak.md"), File.join(@done, "plan.md") ])
    assert(found.any? { |f| f.include?("github token") })
    assert_empty cmd.send(:local_secret_scan, [ File.join(@done, "plan.md") ])
  end

  def test_report_json_and_text
    out_json, = capture_io { Hive::Commands::BenchSubmit.new("s", bench_path: @bench, json: true).send(:report, "/e", "http://pr/1") }
    assert_includes out_json, "\"pr_url\""
    out_txt, = capture_io { cmd.send(:report, "/e", "http://pr/2") }
    assert_includes out_txt, "Submitted"
  end

  def test_run_git_success_and_failure
    repo = File.join(@root, "gitrepo")
    FileUtils.mkdir_p(repo)
    system("git", "init", "-q", repo, exception: true)
    cmd.send(:run_git, repo, "status", "--porcelain") # success, no raise
    assert_raises(Hive::Commands::BenchSubmit::UsageError) { cmd.send(:run_git, repo, "not-a-git-subcommand") }
  end

  def test_extract_via_hive_bench_runs_the_script
    FileUtils.mkdir_p(File.join(@bench, "harness"))
    File.write(File.join(@bench, "harness", "extract.rb"), "exit 0\n")
    entry = cmd.send(:extract_via_hive_bench, task_dir: @done, repo: "o/r", repo_path: @proj, out_dir: File.join(@bench, "corpus"))
    assert_equal File.join(@bench, "corpus", "fix-thing-260601-aa11"), entry
  end

  def test_extract_via_hive_bench_raises_on_failure
    FileUtils.mkdir_p(File.join(@bench, "harness"))
    File.write(File.join(@bench, "harness", "extract.rb"), "warn 'boom'; exit 1\n")
    assert_raises(Hive::Commands::BenchSubmit::UsageError) do
      cmd.send(:extract_via_hive_bench, task_dir: @done, repo: "o/r", repo_path: @proj, out_dir: File.join(@bench, "corpus"))
    end
  end

  def test_extract_via_hive_bench_missing_script
    assert_raises(Hive::Commands::BenchSubmit::UsageError) do
      cmd.send(:extract_via_hive_bench, task_dir: @done, repo: "o/r", repo_path: @proj, out_dir: "/x")
    end
  end

  def test_open_pr_via_gh_with_stub_binaries
    with_stub_path do
      url = cmd.send(:open_pr_via_gh, bench_path: @bench, entry_dir: File.join(@bench, "corpus", "x"), slug: "fix-thing-260601-aa11")
      assert_equal "https://github.com/ivankuznetsov/hive-bench/pull/9", url
    end
  end

  def test_open_pr_via_gh_raises_when_gh_fails
    with_stub_path(gh_body: "exit 1") do
      assert_raises(Hive::Commands::BenchSubmit::UsageError) do
        cmd.send(:open_pr_via_gh, bench_path: @bench, entry_dir: "/e", slug: "fix-thing-260601-aa11")
      end
    end
  end

  def test_source_repo_rejects_non_github_origin
    proj2 = File.join(@root, "proj2")
    system("git", "init", "-q", proj2, exception: true)
    system("git", "-C", proj2, "remote", "add", "origin", "https://gitlab.com/x/y.git", exception: true)
    c = Hive::Commands::BenchSubmit.new("s", bench_path: @bench, projects: [ { "name" => "p2", "path" => proj2 } ])
    assert_raises(Hive::Commands::BenchSubmit::UsageError) { c.send(:source_repo, proj2) }
  end
end
