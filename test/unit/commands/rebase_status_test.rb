require "test_helper"
require "hive/commands/rebase_status"
require "hive/git_ops"
require "json"

# Unit tests for the read-only `hive rebase-status` verb (AGENT-O3
# from PR #69 review). The command's job is to mirror the guard
# ladder in Hive::Rebase.perform without ever calling git fetch,
# so we stub Hive::GitOps + the task resolver and drive each state
# explicitly.
class HiveCommandsRebaseStatusTest < Minitest::Test
  include HiveTestHelper

  FakeTask = Struct.new(:slug, :stage_name, :folder, :worktree_path, :project_root)

  def make_task(worktree:, dir: nil)
    project_root = dir || Dir.mktmpdir("rebase-status-proj")
    folder = File.join(project_root, ".hive-state", "stages", "4-execute", "demo-260514-aaaa")
    FileUtils.mkdir_p(folder)
    FakeTask.new("demo-260514-aaaa", "4-execute", folder, worktree, project_root)
  end

  class FakeGit
    attr_accessor :rebase_in_progress_value, :dirty_value, :detached_value,
                  :commits_behind_value, :default_branch_value

    def initialize
      @rebase_in_progress_value = false
      @dirty_value = false
      @detached_value = false
      @commits_behind_value = 0
      @default_branch_value = "main"
    end

    def rebase_in_progress?; @rebase_in_progress_value; end
    def dirty?; @dirty_value; end
    def detached_head?; @detached_value; end
    def commits_behind(_ref); @commits_behind_value; end
    def default_branch; @default_branch_value; end

    # Ensure tests fail loudly if rebase-status ever calls fetch.
    def fetch_default_branch(_ref)
      raise "rebase-status must never invoke git fetch"
    end
  end

  def stub_gitops!(git)
    original = Hive::GitOps.singleton_class.instance_method(:new)
    Hive::GitOps.define_singleton_method(:new) { |_path| git }
    begin
      yield
    ensure
      Hive::GitOps.singleton_class.define_method(:new, original)
    end
  end

  def stub_resolver!(task)
    original = Hive::TaskResolver.instance_method(:resolve)
    Hive::TaskResolver.define_method(:resolve) { task }
    begin
      yield
    ensure
      Hive::TaskResolver.define_method(:resolve, original)
    end
  end

  def stub_config!(cfg)
    original = Hive::Config.singleton_class.instance_method(:load)
    Hive::Config.define_singleton_method(:load) { |_root| cfg }
    begin
      yield
    ensure
      Hive::Config.singleton_class.define_method(:load, original)
    end
  end

  def run_status(task:, cfg:, git:, json: false)
    out, _err = capture_io do
      stub_resolver!(task) do
        stub_config!(cfg) do
          stub_gitops!(git) do
            Hive::Commands::RebaseStatus.new(task.slug, json: json).call
          end
        end
      end
    end
    out
  end

  # ---- text output, one state per test ----

  def test_disabled_via_config
    task = make_task(worktree: Dir.mktmpdir("wt"))
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => false } }, git: FakeGit.new)
    assert_match(/auto-rebase DISABLED/, out)
  end

  def test_no_worktree_when_path_nil
    task = FakeTask.new("demo-260514-aaaa", "2-brainstorm", Dir.mktmpdir("f"), nil, Dir.mktmpdir("p"))
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => true } }, git: FakeGit.new)
    assert_match(/no worktree at this stage/, out)
  end

  def test_no_worktree_when_directory_missing
    task = make_task(worktree: "/nonexistent/path/abcdef")
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => true } }, git: FakeGit.new)
    assert_match(/no worktree at this stage/, out)
  end

  def test_pre_existing_rebase
    wt = Dir.mktmpdir("wt")
    task = make_task(worktree: wt)
    git = FakeGit.new; git.rebase_in_progress_value = true
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => true } }, git: git)
    assert_match(/pre-existing rebase state/, out)
    assert_match(/rebase --abort/, out)
  end

  def test_dirty_worktree
    wt = Dir.mktmpdir("wt")
    task = make_task(worktree: wt)
    git = FakeGit.new; git.dirty_value = true
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => true } }, git: git)
    assert_match(/worktree dirty/, out)
  end

  def test_detached_head
    wt = Dir.mktmpdir("wt")
    task = make_task(worktree: wt)
    git = FakeGit.new; git.detached_value = true
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => true } }, git: git)
    assert_match(/detached HEAD/, out)
  end

  def test_no_default_branch
    wt = Dir.mktmpdir("wt")
    task = make_task(worktree: wt)
    git = FakeGit.new; git.default_branch_value = nil
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => true } }, git: git)
    assert_match(/could not resolve default branch/, out)
  end

  def test_no_drift
    wt = Dir.mktmpdir("wt")
    task = make_task(worktree: wt)
    git = FakeGit.new; git.commits_behind_value = 0
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => true } }, git: git)
    assert_match(/0 commits behind/, out)
  end

  def test_would_rebase
    wt = Dir.mktmpdir("wt")
    task = make_task(worktree: wt)
    git = FakeGit.new; git.commits_behind_value = 5
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => true } }, git: git)
    assert_match(/5 commits behind origin\/main/, out)
    assert_match(/next `hive run` would attempt rebase/, out)
  end

  # ---- JSON envelope shape ----

  def test_json_envelope_would_rebase
    wt = Dir.mktmpdir("wt")
    task = make_task(worktree: wt)
    git = FakeGit.new; git.commits_behind_value = 3
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => true } }, git: git, json: true)
    payload = JSON.parse(out)
    assert_equal "hive-rebase-status", payload["schema"]
    assert_equal "would_rebase", payload["state"]
    assert_equal true, payload["would_rebase"]
    assert_equal 3, payload["commits_behind"]
    assert_equal "main", payload["default_branch"]
    assert_equal task.slug, payload["slug"]
    assert_equal task.stage_name, payload["stage"]
  end

  def test_json_envelope_disabled
    task = make_task(worktree: Dir.mktmpdir("wt"))
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => false } }, git: FakeGit.new, json: true)
    payload = JSON.parse(out)
    assert_equal "disabled", payload["state"]
    assert_equal false, payload["would_rebase"]
  end

  # ---- read-only invariant ----

  def test_never_calls_fetch_even_when_rebase_would_run
    # FakeGit#fetch_default_branch raises. Reaching `would_rebase`
    # without that explosion proves the verb skipped the fetch.
    wt = Dir.mktmpdir("wt")
    task = make_task(worktree: wt)
    git = FakeGit.new; git.commits_behind_value = 7
    out = run_status(task: task, cfg: { "rebase" => { "enabled" => true } }, git: git)
    assert_match(/7 commits behind/, out)
  end
end
