require "test_helper"
require "hive/stages/base"
require "hive/task"
require "hive/markers"
require "hive/worktree"

# `Hive::Stages::Base.with_stage_events` enforces the stage-exit clean-
# worktree invariant on the whitelisted worktree-owning stages.  These
# tests exercise the hook directly with a real worktree + task folder
# and a stub runner that simulates a stage agent leaving residue.
class HiveStagesBaseCleanExitHookTest < Minitest::Test
  include HiveTestHelper

  def setup
    @cfg = deep_dup_default_cfg
  end

  def make_task_and_worktree(stage_dir)
    root = Dir.mktmpdir("hive-task")
    slug = "demo-260528-aaaa"
    task_folder = File.join(root, ".hive-state", "stages", stage_dir, slug)
    FileUtils.mkdir_p(task_folder)
    File.write(File.join(task_folder, "task.md"), "<!-- AGENT_WORKING -->\n")

    worktree = Dir.mktmpdir("hive-wt")
    init_git(worktree)
    File.write(
      File.join(task_folder, "worktree.yml"),
      { "path" => worktree, "branch" => slug }.to_yaml
    )
    [ root, Hive::Task.new(task_folder), worktree ]
  end

  def init_git(worktree_path)
    run!("git", "-C", worktree_path, "init", "-b", "demo", "--quiet")
    run!("git", "-C", worktree_path, "config", "user.email", "t@example.com")
    run!("git", "-C", worktree_path, "config", "user.name", "T")
    run!("git", "-C", worktree_path, "config", "commit.gpgsign", "false")
    File.write(File.join(worktree_path, "seed.txt"), "seed\n")
    run!("git", "-C", worktree_path, "add", ".")
    run!("git", "-C", worktree_path, "commit", "-m", "seed", "--quiet")
  end

  def teardown
    Array(@dirs_to_clean).each { |d| FileUtils.rm_rf(d) }
  end

  def remember(*dirs)
    @dirs_to_clean ||= []
    @dirs_to_clean.concat(dirs)
  end

  def test_with_stage_events_auto_commits_in_scope_residue_on_worktree_owning_stage
    root, task, worktree = make_task_and_worktree("6-review")
    remember(root, worktree)

    Hive::Stages::Base.with_stage_events(task, cfg: @cfg) do
      # Stage runner does its work and writes a terminal marker, but
      # leaves a wiki/ edit dirty in the worktree on the way out — the
      # exact regression class the plan describes.
      FileUtils.mkdir_p(File.join(worktree, "wiki"))
      File.write(File.join(worktree, "wiki", "page.md"), "edits\n")
      Hive::Markers.set(task.state_file, :review_complete, attempts: 1)
    end

    subject = `git -C #{worktree} log -1 --pretty=%s`.strip
    body = `git -C #{worktree} log -1 --pretty=%B`
    assert_equal "chore(6-review): commit residual worktree changes", subject
    assert_match(/Hive-Auto-Commit-Reason: stage_exit/, body)
    assert_match(/Hive-Stage: 6-review/, body)

    porcelain = `git -C #{worktree} status --porcelain`
    assert porcelain.empty?, "stage-exit hook must clear residue"

    # And the runner's own terminal marker survives — auto-committed
    # residue is not an error.
    marker = Hive::Markers.current(task.state_file)
    assert_equal :review_complete, marker.name
  end

  def test_with_stage_events_marks_error_on_scope_violation
    root, task, worktree = make_task_and_worktree("6-review")
    remember(root, worktree)

    Hive::Stages::Base.with_stage_events(task, cfg: @cfg) do
      # `unrelated/path.txt` matches no allowed_paths in the default
      # scope-check, so CleanExit returns :scope_violation. The runner
      # itself thinks it succeeded (it wrote :review_complete), but
      # the hook MUST overwrite that with the typed :error.
      FileUtils.mkdir_p(File.join(worktree, "unrelated"))
      File.write(File.join(worktree, "unrelated", "path.txt"), "x\n")
      Hive::Markers.set(task.state_file, :review_complete, attempts: 1)
    end

    marker = Hive::Markers.current(task.state_file)
    assert_equal :error, marker.name
    assert_equal "ensure_clean_on_exit_failed", marker.attrs["reason"]
    assert_includes marker.attrs["residue_paths"].to_s, "unrelated/path.txt"
  end

  def test_with_stage_events_does_not_downgrade_existing_error_marker
    root, task, worktree = make_task_and_worktree("6-review")
    remember(root, worktree)

    Hive::Stages::Base.with_stage_events(task, cfg: @cfg) do
      FileUtils.mkdir_p(File.join(worktree, "unrelated"))
      File.write(File.join(worktree, "unrelated", "path.txt"), "x\n")
      # The runner itself already raised an error of its own — the
      # diagnostic value of that error must NOT be lost just because
      # there's residue too.
      Hive::Markers.set(task.state_file, :error, reason: "agent_crashed",
                        detail: "the agent itself failed first")
    end

    marker = Hive::Markers.current(task.state_file)
    assert_equal :error, marker.name
    assert_equal "agent_crashed", marker.attrs["reason"],
                 "an existing :error marker MUST NOT be overwritten by ensure_clean_on_exit_failed"
  end

  def test_with_stage_events_skips_invariant_on_non_worktree_stage
    root, task, worktree = make_task_and_worktree("3-plan")
    remember(root, worktree)

    Hive::Stages::Base.with_stage_events(task, cfg: @cfg) do
      # An out-of-scope residue would have failed loudly under a
      # worktree-owning stage; here it must be ignored.
      FileUtils.mkdir_p(File.join(worktree, "unrelated"))
      File.write(File.join(worktree, "unrelated", "path.txt"), "x\n")
      Hive::Markers.set(task.state_file, :complete)
    end

    marker = Hive::Markers.current(task.state_file)
    assert_equal :complete, marker.name,
                 "non-worktree-owning stages must not be touched by the invariant"
  end

  def test_with_stage_events_disabled_by_config_flag
    root, task, worktree = make_task_and_worktree("6-review")
    remember(root, worktree)

    cfg = deep_dup_default_cfg
    cfg["stages"] ||= {}
    cfg["stages"]["ensure_clean_on_exit"] = false

    Hive::Stages::Base.with_stage_events(task, cfg: cfg) do
      FileUtils.mkdir_p(File.join(worktree, "unrelated"))
      File.write(File.join(worktree, "unrelated", "path.txt"), "x\n")
      Hive::Markers.set(task.state_file, :review_complete, attempts: 1)
    end

    marker = Hive::Markers.current(task.state_file)
    assert_equal :review_complete, marker.name,
                 "stages.ensure_clean_on_exit=false must opt the entire invariant out"
  end

  def test_with_stage_events_without_cfg_is_a_no_op
    root, task, worktree = make_task_and_worktree("6-review")
    remember(root, worktree)

    # Callers that haven't been migrated to pass `cfg:` keep their
    # historic behaviour — the hook does nothing.
    Hive::Stages::Base.with_stage_events(task) do
      FileUtils.mkdir_p(File.join(worktree, "unrelated"))
      File.write(File.join(worktree, "unrelated", "path.txt"), "x\n")
      Hive::Markers.set(task.state_file, :review_complete, attempts: 1)
    end

    marker = Hive::Markers.current(task.state_file)
    assert_equal :review_complete, marker.name
  end

  # 4-execute's mid-pass `:execute_waiting reason=dirty_worktree`
  # pause is an intentional "operator decide" semantic — the runner
  # itself wrote that marker after inspecting the worktree. The
  # invariant must not double-process it (plan §"Non-goals" calls
  # this out explicitly).
  def test_with_stage_events_does_not_overwrite_intentional_pause_marker
    root, task, worktree = make_task_and_worktree("4-execute")
    remember(root, worktree)

    Hive::Stages::Base.with_stage_events(task, cfg: @cfg) do
      File.write(File.join(worktree, "dirty.txt"), "x\n")
      Hive::Markers.set(task.state_file, :execute_waiting, reason: "dirty_worktree")
    end

    marker = Hive::Markers.current(task.state_file)
    assert_equal :execute_waiting, marker.name,
                 "an intentional pause marker must not be overwritten by the invariant"
    assert_equal "dirty_worktree", marker.attrs["reason"]
  end

  # `:review_waiting` is the 6-review counterpart: when the review
  # orchestrator surfaces escalations awaiting human edit, it writes
  # `<!-- REVIEW_WAITING escalations=N pass=NN -->`. The runner expects
  # the operator to inspect the worktree (and possibly leave residue),
  # so the clean-exit invariant must NOT overwrite it.
  def test_with_stage_events_does_not_overwrite_review_waiting_pause_marker
    root, task, worktree = make_task_and_worktree("6-review")
    remember(root, worktree)

    Hive::Stages::Base.with_stage_events(task, cfg: @cfg) do
      FileUtils.mkdir_p(File.join(worktree, "unrelated"))
      File.write(File.join(worktree, "unrelated", "dirty.txt"), "x\n")
      Hive::Markers.set(task.state_file, :review_waiting, escalations: 2, pass: "01")
    end

    marker = Hive::Markers.current(task.state_file)
    assert_equal :review_waiting, marker.name,
                 ":review_waiting must not be overwritten by the invariant"
    assert_equal "2", marker.attrs["escalations"]
  end

  # When CleanExit overwrites the stage's marker to
  # `:error reason=ensure_clean_on_exit_failed`, the stage's own
  # `result[:commit]` (e.g. "review_complete") is now lying: the
  # hive-state commit `commands/run.rb#commit_after` writes would
  # advertise a success that didn't happen. `with_stage_events` MUST
  # rewrite `result[:commit]` to match the actual outcome.
  def test_with_stage_events_clears_stale_commit_when_marker_overwritten
    root, task, worktree = make_task_and_worktree("6-review")
    remember(root, worktree)

    result = Hive::Stages::Base.with_stage_events(task, cfg: @cfg) do
      FileUtils.mkdir_p(File.join(worktree, "unrelated"))
      File.write(File.join(worktree, "unrelated", "path.txt"), "x\n")
      Hive::Markers.set(task.state_file, :review_complete, attempts: 1)
      { commit: "review_complete", status: :complete }
    end

    assert_equal :error, Hive::Markers.current(task.state_file).name
    assert_equal "ensure_clean_on_exit_failed",
                 Hive::Markers.current(task.state_file).attrs["reason"]
    assert_equal "ensure_clean_on_exit_failed", result[:commit],
                 "result[:commit] must reflect the overwritten outcome so commit_after writes the right hive-state commit"
    assert_equal :error, result[:status]
  end

  # `Hive::ConfigError` (e.g. invalid `sign_policy`) is a programmer/
  # operator misconfiguration, not a transient I/O blip — the generic
  # `rescue StandardError` warn-and-continue path would silently
  # swallow it, hiding the bad config from the operator. The dedicated
  # rescue must surface it as `:error reason=ensure_clean_on_exit_failed`.
  def test_with_stage_events_surfaces_config_error_as_clean_exit_failure
    root, task, worktree = make_task_and_worktree("6-review")
    remember(root, worktree)

    # Bad sign_policy fed through cfg; CleanExit calls
    # AutoCommit.auto_commit_sign_policy_for which raises ConfigError.
    cfg = deep_dup_default_cfg
    cfg.dig("review", "fix", "auto_commit")["sign_policy"] = "totally_invalid"

    Hive::Stages::Base.with_stage_events(task, cfg: cfg) do
      # Any dirty worktree triggers CleanExit (so we hit
      # auto_commit_sign_policy_for); the residue itself is irrelevant.
      FileUtils.mkdir_p(File.join(worktree, "wiki"))
      File.write(File.join(worktree, "wiki", "page.md"), "edits\n")
      Hive::Markers.set(task.state_file, :review_complete, attempts: 1)
    end

    marker = Hive::Markers.current(task.state_file)
    assert_equal :error, marker.name
    assert_equal "ensure_clean_on_exit_failed", marker.attrs["reason"]
    assert_match(/invalid sign_policy config/, marker.attrs["detail"].to_s)
  end

  # The clean / auto_committed branch must leave the stage's own
  # `result[:commit]` alone — only the overwrite branch mutates.
  def test_with_stage_events_preserves_result_commit_when_auto_committing
    root, task, worktree = make_task_and_worktree("6-review")
    remember(root, worktree)

    result = Hive::Stages::Base.with_stage_events(task, cfg: @cfg) do
      FileUtils.mkdir_p(File.join(worktree, "wiki"))
      File.write(File.join(worktree, "wiki", "page.md"), "edits\n")
      Hive::Markers.set(task.state_file, :review_complete, attempts: 1)
      { commit: "review_complete", status: :complete }
    end

    assert_equal "review_complete", result[:commit],
                 "result[:commit] must be preserved when CleanExit auto-commits residue"
    assert_equal :complete, result[:status]
  end

  private

  def deep_dup_default_cfg
    require "yaml"
    YAML.unsafe_load(YAML.dump(Hive::Config::DEFAULTS))
  end
end
